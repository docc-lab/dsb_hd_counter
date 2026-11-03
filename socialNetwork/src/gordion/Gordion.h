// Gordion per-endpoint latency recorder for the DeathStarBench SocialNetwork C++ services
// (port of hotelReservation/gordion/recorder.go; Phase C, per-endpoint dictionary).
//
// Attach to a Thrift processor:
//     auto proc = std::make_shared<XServiceProcessor>(handler);
//     proc->setEventHandler(gordion::Init("home-timeline", {"ReadHomeTimeline", "WriteHomeTimeline"}));
// and wrap every outgoing Thrift client protocol with gordion::BlockedProtocol (ThriftClient.h) so
// that the time a request spends blocked on a downstream Thrift call is accounted as "blocked"
// (processing = total - blocked). Redis/Mongo/memcached calls are not Thrift: they count as processing
// unless the handler wraps them in a gordion::Blocked scope (post-storage does, Phase E).
//
// Timing model (one TThreadedServer thread per connection, requests sequential per thread):
//     tap     = getContext (the frame has been read from the socket; the admission queue is before this)
//     start   = postRead (arguments decoded) -> queue  = postRead - tap  (decode + dispatch)
//     return  = preWrite (handler returned)  -> total  = preWrite - tap
//     blocked = sum of [writeMessageBegin .. readMessageEnd] of downstream Thrift calls on the request's thread
//     processing = total - blocked
// Output: one JSON line per window, the same layout as the Go recorder (t, svc, w, a, n, e, drop, cpu, mhz,
// all[15], raw/rawp/rawq (GORDION_RAW=1), ep{name:[a,n,p50,p90,p99,mean,max,pp50,pp90,q50,q90,x50,x90,ns,f50,f90]}),
// no caller stamp (x = 0, ns = 0). Configuration: GORDION_OUT (file path; unset = disabled), GORDION_WINDOW_MS (100),
// GORDION_RAW ("1"), GORDION_DISABLE ("1" = pass-through).
#ifndef SOCIAL_NETWORK_MICROSERVICES_GORDION_H
#define SOCIAL_NETWORK_MICROSERVICES_GORDION_H

#include <sched.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <thrift/TProcessor.h>
#include <thrift/protocol/TProtocolDecorator.h>

namespace gordion {

inline int64_t nowNs() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

struct ReqState {
  int method = -1;
  int64_t tap = 0;      // getContext
  int64_t start = 0;    // postRead
  int64_t blocked = 0;  // ns blocked on downstream Thrift calls
  int64_t pauseStart = 0;
  int depth = 0;
  bool done = false;
};

struct Completion {
  int method;
  bool err;
  int64_t total, proc, queue;
};

// the request being served on this thread (C++14: no inline variables, hence the accessor)
inline ReqState *&cur() {
  static thread_local ReqState *p = nullptr;
  return p;
}

class Recorder {
 public:
  static Recorder &Get() {
    static Recorder r;
    return r;
  }

  bool Enabled() const { return _enabled; }

  void Init(const std::string &service, const std::vector<std::string> &methods) {
    std::lock_guard<std::mutex> g(_mu);
    if (_enabled) return;
    const char *out = std::getenv("GORDION_OUT");
    const char *dis = std::getenv("GORDION_DISABLE");
    if (!out || !*out || (dis && std::string(dis) == "1")) return;
    _service = service;
    const char *w = std::getenv("GORDION_WINDOW_MS");
    _windowMs = (w && *w) ? std::max(10, atoi(w)) : 100;
    const char *raw = std::getenv("GORDION_RAW");
    _raw = raw && std::string(raw) == "1";
    _f = std::fopen(out, "a");
    if (!_f) {
      std::fprintf(stderr, "gordion: cannot open %s\n", out);
      return;
    }
    for (auto &m : methods) idx(m);
    _enabled = true;
    _lastCPU = cpuNs();
    writeStart();
    _flusher = std::thread([this] { loop(); });
    _flusher.detach();
  }

  int idx(const std::string &m) {
    auto it = _idx.find(m);
    if (it != _idx.end()) return it->second;
    int i = (int)_methods.size();
    _methods.push_back(m);
    _idx[m] = i;
    _arrivals.emplace_back(new std::atomic<int64_t>(0));
    return i;
  }

  // called under no lock from the event handler (method registration takes the lock only for new names)
  int methodIndex(const char *fn) {
    const char *dot = std::strrchr(fn, '.');
    std::string m = dot ? std::string(dot + 1) : std::string(fn);
    {
      std::lock_guard<std::mutex> g(_mu);
      return idx(m);
    }
  }

  void arrival(int i) { _arrivals[i]->fetch_add(1, std::memory_order_relaxed); }

  void complete(const Completion &c) {
    std::lock_guard<std::mutex> g(_cmu);
    _pending.push_back(c);
  }

 private:
  Recorder() = default;

  static int64_t cpuNs() {
    struct rusage ru;
    if (getrusage(RUSAGE_SELF, &ru) != 0) return -1;
    return (int64_t)ru.ru_utime.tv_sec * 1000000000LL + (int64_t)ru.ru_utime.tv_usec * 1000LL +
           (int64_t)ru.ru_stime.tv_sec * 1000000000LL + (int64_t)ru.ru_stime.tv_usec * 1000LL;
  }

  // mean current clock (MHz) of the cores in the process's affinity mask: sysfs cpufreq, else
  // /proc/cpuinfo "cpu MHz" (APERF/MPERF based; the only source on kernels without a cpufreq driver)
  static double cpuMHz() {
    cpu_set_t set;
    CPU_ZERO(&set);
    if (sched_getaffinity(0, sizeof(set), &set) != 0) return 0;
    double sum = 0, n = 0;
    for (int c = 0; c < CPU_SETSIZE; c++) {
      if (!CPU_ISSET(c, &set)) continue;
      std::ifstream f("/sys/devices/system/cpu/cpu" + std::to_string(c) + "/cpufreq/scaling_cur_freq");
      double khz;
      if (f && (f >> khz) && khz > 0) {
        sum += khz / 1000;
        n++;
      }
    }
    if (n > 0) return sum / n;
    std::ifstream ci("/proc/cpuinfo");
    std::string line;
    int cpu = -1;
    while (std::getline(ci, line)) {
      auto p = line.find(':');
      if (p == std::string::npos) continue;
      std::string k = line.substr(0, p);
      while (!k.empty() && (k.back() == ' ' || k.back() == '\t')) k.pop_back();
      std::string v = line.substr(p + 1);
      if (k == "processor") {
        cpu = atoi(v.c_str());
      } else if (k == "cpu MHz") {
        if (cpu < 0 || cpu >= CPU_SETSIZE || !CPU_ISSET(cpu, &set)) continue;
        double mhz = atof(v.c_str());
        if (mhz > 0) {
          sum += mhz;
          n++;
        }
      }
    }
    return n > 0 ? sum / n : 0;
  }

  static int64_t pct(const std::vector<int64_t> &sorted, double p) {
    size_t n = sorted.size();
    if (n == 0) return 0;
    double rank = p * (double)(n - 1);
    size_t lo = (size_t)rank, hi = lo + 1;
    if (hi >= n) return sorted[n - 1];
    double frac = rank - (double)lo;
    return sorted[lo] + (int64_t)((double)(sorted[hi] - sorted[lo]) * frac);
  }

  struct Bucket {
    std::vector<int64_t> total, proc, queue;
    int64_t errs = 0;
  };

  static void writeStats(std::string &sb, std::vector<int64_t> total, std::vector<int64_t> proc,
                         std::vector<int64_t> queue) {
    std::sort(total.begin(), total.end());
    std::sort(proc.begin(), proc.end());
    std::sort(queue.begin(), queue.end());
    int64_t sum = 0;
    for (auto v : total) sum += v;
    int64_t n = (int64_t)total.size(), mean = 0, mx = 0;
    if (n > 0) {
      mean = sum / n;
      mx = total[n - 1];
    }
    std::vector<int64_t> vals = {n, pct(total, .5), pct(total, .9), pct(total, .99), mean, mx, pct(proc, .5),
                                 pct(proc, .9), pct(queue, .5), pct(queue, .9), 0, 0, 0, 0, 0};
    for (size_t i = 0; i < vals.size(); i++) {
      if (i) sb += ',';
      sb += std::to_string(vals[i]);
    }
  }

  void writeRaw(std::string &sb, const char *key, const std::vector<Bucket> &b, int which) {
    sb += ",\"";
    sb += key;
    sb += "\":{";
    bool first = true;
    for (size_t i = 0; i < b.size(); i++) {
      const std::vector<int64_t> &vals = which == 0 ? b[i].total : (which == 1 ? b[i].proc : b[i].queue);
      if (vals.empty()) continue;
      if (!first) sb += ',';
      first = false;
      sb += '"';
      sb += _methods[i];
      sb += "\":[";
      for (size_t j = 0; j < vals.size(); j++) {
        if (j) sb += ',';
        sb += std::to_string(vals[j]);
      }
      sb += ']';
    }
    sb += '}';
  }

  void writeStart() {
    std::string sb = "{\"event\":\"start\",\"t\":" + std::to_string(nowNs() / 1000000) + ",\"svc\":\"" + _service +
                     "\",\"w\":" + std::to_string(_windowMs) + ",\"pid\":" + std::to_string(getpid()) + ",\"methods\":[";
    for (size_t i = 0; i < _methods.size(); i++) {
      if (i) sb += ',';
      sb += '"' + _methods[i] + '"';
    }
    sb += "],\"raw\":" + std::string(_raw ? "true" : "false") + ",\"lang\":\"cpp\"}\n";
    std::fputs(sb.c_str(), _f);
    std::fflush(_f);
  }

  void loop() {
    int64_t winNs = (int64_t)_windowMs * 1000000LL;
    int64_t winStart = (nowNs() / winNs) * winNs;
    while (true) {
      int64_t next = winStart + winNs;
      int64_t now = nowNs();
      if (next > now) std::this_thread::sleep_for(std::chrono::nanoseconds(next - now));
      flush(winStart);
      winStart = next;
      // catch up if we fell behind by whole windows (flush each as empty)
      while (nowNs() - winStart > 2 * winNs) {
        flush(winStart);
        winStart += winNs;
      }
    }
  }

  void flush(int64_t winStartNs) {
    std::vector<Completion> pend;
    {
      std::lock_guard<std::mutex> g(_cmu);
      pend.swap(_pending);
    }
    std::vector<std::string> methods;
    std::vector<int64_t> arr;
    {
      std::lock_guard<std::mutex> g(_mu);
      methods = _methods;
      arr.resize(methods.size());
      for (size_t i = 0; i < arr.size(); i++) arr[i] = _arrivals[i]->exchange(0);
    }
    std::vector<Bucket> b(methods.size());
    std::vector<int64_t> allTotal, allProc, allQueue;
    int64_t arrivals = 0, errs = 0;
    for (auto v : arr) arrivals += v;
    for (auto &c : pend) {
      if (c.method < 0 || c.method >= (int)b.size()) continue;
      b[c.method].total.push_back(c.total);
      b[c.method].proc.push_back(c.proc);
      b[c.method].queue.push_back(c.queue);
      if (c.err) b[c.method].errs++;
      allTotal.push_back(c.total);
      allProc.push_back(c.proc);
      allQueue.push_back(c.queue);
      if (c.err) errs++;
    }
    int64_t winNs = (int64_t)_windowMs * 1000000LL;
    if (arrivals == 0 && allTotal.empty()) {
      if ((winStartNs / winNs) % (1000000000LL / winNs) != 0) {
        // idle window: heartbeat once per second only (keeps the CPU baseline measurable)
        int64_t cpu = cpuNs();
        if (cpu >= 0) _idleCPU += cpu - _lastCPU, _lastCPU = cpu;
        return;
      }
    }
    // the window's real length: on a saturated pinned core the flusher thread is scheduled late, so the
    // nominal 100 ms would overstate the arrival rate and the CPU per second of that window
    int64_t nowNsV = nowNs();
    int64_t actualMs = _lastFlushNs > 0 ? (nowNsV - _lastFlushNs + 500000) / 1000000 : _windowMs;
    _lastFlushNs = nowNsV;
    if (actualMs < 1) actualMs = 1;
    std::string sb;
    sb.reserve(256 + 96 * methods.size());
    sb += "{\"t\":" + std::to_string(winStartNs / 1000000) + ",\"svc\":\"" + _service + "\",\"w\":" + std::to_string(actualMs) +
          ",\"a\":" + std::to_string(arrivals) + ",\"n\":" + std::to_string(allTotal.size()) + ",\"e\":" + std::to_string(errs) +
          ",\"drop\":0";
    int64_t cpu = cpuNs();
    if (cpu >= 0) {
      sb += ",\"cpu\":" + std::to_string(cpu - _lastCPU + _idleCPU);
      _lastCPU = cpu;
      _idleCPU = 0;
    }
    double mhz = cpuMHz();
    if (mhz > 0) sb += ",\"mhz\":" + std::to_string((int64_t)mhz);
    sb += ",\"all\":[";
    writeStats(sb, allTotal, allProc, allQueue);
    sb += ']';
    if (_raw) {
      writeRaw(sb, "raw", b, 0);
      writeRaw(sb, "rawp", b, 1);
      writeRaw(sb, "rawq", b, 2);
    }
    sb += ",\"ep\":{";
    bool first = true;
    for (size_t i = 0; i < b.size(); i++) {
      if (arr[i] == 0 && b[i].total.empty()) continue;
      if (!first) sb += ',';
      first = false;
      sb += '"' + methods[i] + "\":[" + std::to_string(arr[i]) + ',';
      writeStats(sb, b[i].total, b[i].proc, b[i].queue);
      sb += ']';
    }
    sb += "}}\n";
    std::fputs(sb.c_str(), _f);
    std::fflush(_f);
  }

  bool _enabled = false;
  bool _raw = false;
  int _windowMs = 100;
  std::string _service;
  std::FILE *_f = nullptr;
  std::mutex _mu;  // methods / arrivals registry
  std::vector<std::string> _methods;
  std::map<std::string, int> _idx;
  std::vector<std::unique_ptr<std::atomic<int64_t>>> _arrivals;
  std::mutex _cmu;  // pending completions
  std::vector<Completion> _pending;
  int64_t _lastCPU = 0, _idleCPU = 0, _lastFlushNs = 0;
  std::thread _flusher;
};

// Server-side hook: one ReqState per request, kept in a thread-local for the duration of the
// handler so that BlockedProtocol can attribute downstream call time to it.
class EventHandler : public apache::thrift::TProcessorEventHandler {
 public:
  void *getContext(const char *fn_name, void *) override {
    Recorder &r = Recorder::Get();
    if (!r.Enabled()) return nullptr;
    ReqState *st = new ReqState();
    st->method = r.methodIndex(fn_name);
    st->tap = nowNs();
    st->start = st->tap;
    r.arrival(st->method);
    cur() = st;
    return st;
  }
  void freeContext(void *ctx, const char *) override {
    ReqState *st = static_cast<ReqState *>(ctx);
    if (!st) return;
    if (!st->done) finish(st, false);
    if (cur() == st) cur() = nullptr;
    delete st;
  }
  void postRead(void *ctx, const char *, uint32_t) override {
    ReqState *st = static_cast<ReqState *>(ctx);
    if (st) st->start = nowNs();
  }
  void preWrite(void *ctx, const char *) override {
    ReqState *st = static_cast<ReqState *>(ctx);
    if (st && !st->done) finish(st, false);
  }
  void handlerError(void *ctx, const char *) override {
    ReqState *st = static_cast<ReqState *>(ctx);
    if (st && !st->done) finish(st, true);
  }

 private:
  static void finish(ReqState *st, bool err) {
    st->done = true;
    int64_t now = nowNs();
    Completion c;
    c.method = st->method;
    c.err = err;
    c.total = now - st->tap;
    c.queue = st->start - st->tap;
    c.proc = c.total - st->blocked;
    if (c.proc < 0) c.proc = 0;
    Recorder::Get().complete(c);
  }
};

inline std::shared_ptr<apache::thrift::TProcessorEventHandler> Init(const std::string &service,
                                                                     const std::vector<std::string> &methods) {
  Recorder::Get().Init(service, methods);
  return std::make_shared<EventHandler>();
}

// Attach the recorder to a generated Thrift processor (returns it, so it can wrap the make_shared call).
template <class P>
std::shared_ptr<P> Attach(std::shared_ptr<P> p, const std::string &service, const std::vector<std::string> &methods) {
  p->setEventHandler(Init(service, methods));
  return p;
}

// Client-side protocol decorator: the request's thread is blocked from the first byte of the
// outgoing message until the reply's message end; the interval is charged to the current request.
class BlockedProtocol : public apache::thrift::protocol::TProtocolDecorator {
 public:
  explicit BlockedProtocol(std::shared_ptr<apache::thrift::protocol::TProtocol> proto)
      : apache::thrift::protocol::TProtocolDecorator(proto) {}

  uint32_t writeMessageBegin_virt(const std::string &name, const apache::thrift::protocol::TMessageType messageType,
                                  const int32_t seqid) override {
    ReqState *st = cur();
    if (st && !st->done && st->depth++ == 0) st->pauseStart = nowNs();
    return apache::thrift::protocol::TProtocolDecorator::writeMessageBegin_virt(name, messageType, seqid);
  }
  uint32_t readMessageEnd_virt() override {
    uint32_t n = apache::thrift::protocol::TProtocolDecorator::readMessageEnd_virt();
    ReqState *st = cur();
    if (st && !st->done && st->depth > 0 && --st->depth == 0 && st->pauseStart > 0) {
      st->blocked += nowNs() - st->pauseStart;
      st->pauseStart = 0;
    }
    return n;
  }
};

// Blocking call made on behalf of the current request that is not a Thrift call (MongoDB, memcached, Redis, a
// future's wait): `{ gordion::Blocked b; <call>; }`. The interval is charged to the request's blocked time exactly
// like a downstream Thrift call (same depth counter, so nesting with BlockedProtocol is safe); processing = total -
// blocked then excludes the datastore wait. The Go equivalent is gordion.Block(ctx).
struct Blocked {
  ReqState *st;
  Blocked() : st(cur()) {
    if (st && !st->done && st->depth++ == 0) st->pauseStart = nowNs();
  }
  ~Blocked() {
    if (st && !st->done && st->depth > 0 && --st->depth == 0 && st->pauseStart > 0) {
      st->blocked += nowNs() - st->pauseStart;
      st->pauseStart = 0;
    }
  }
  Blocked(const Blocked &) = delete;
  Blocked &operator=(const Blocked &) = delete;
};

}  // namespace gordion

#endif  // SOCIAL_NETWORK_MICROSERVICES_GORDION_H
