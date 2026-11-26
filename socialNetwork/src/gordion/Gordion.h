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
// Phase K5 (RESULTS-K 5, the overhead ladder), as in the Go recorder: GORDION_INTERCEPT = full (default: count, slot,
// time) | a comma list of count (arrivals and completions, "nc"), slot (the busy-handler integral, "slot" = ns between
// getContext and the handler's return in the window), time (timers and percentiles; implies count) | off;
// GORDION_READS = comma list of cpu (getrusage), mhz (cpufreq) | none (default both); GORDION_CTL = a file polled once
// per second whose line "intercept=<list> reads=<list>" replaces both (logged as {"event":"ctl"}). With both off the
// flusher only polls the file.
// K5 follow-up (RESULTS-K 5.8), as in the Go recorder: in production mode the timer path records no per-request
// completion. A timed request adds one relaxed atomic increment to a cumulative log-bucket histogram (8 sub-buckets per
// octave, about ±4.5 %); the flusher reads its per-window delta and writes "lat":[n, p50, p90, p99] (ns, timed requests
// only). 1 in GORDION_SAMPLE requests is timed (default 8; the control file's "sample=N" changes it). Every request
// uses the server thread's own ReqState (no allocation), the method index is cached per thread, and the counters are
// fixed arrays of atomics (no lock). GORDION_DIAG=1 (or GORDION_RAW=1) keeps the full per-request stream: every request
// timed, its completion queued under a lock with its thread id, sorted percentiles per window.
// Phase J1 (RESULTS-J 1, the r650 ladder): the per-request counters (arrivals, completions, errors, the slot integral and
// the latency histogram) are per server thread, each thread's block its own cache lines (alignas 64, padded); a thread
// takes a block on its first request (reusing a block freed by an exited thread) and the flusher sums the blocks and
// keeps the previous sums, so no request ever writes a line another thread writes. Before this (image g8) one process-wide
// array of atomics was shared by every thread.
// Phase J2 (RESULTS-J 3): Lat starts at the socket receive timestamp. TServerSocketTS hands out TSocketTS connections with
// SO_TIMESTAMPNS set; TSocketTS::read uses recvmsg and keeps the SCM_TIMESTAMPNS of the last segment it copied in a thread-
// local, which getContext takes as the request's start when it is newer than the thread's previous completion (a request's
// frame arrives in the segment the server thread was blocked on). Without it (no cmsg, or an older stamp) the start is the
// handler entry as before and the request counts in "lat_fb" (fallback). The handler-entry latency keeps its own histogram
// ("lath": [n, p50, p90, p99]) so the two can be compared per window. GORDION_RXTS=0 turns the stamp off (entry only).
#ifndef SOCIAL_NETWORK_MICROSERVICES_GORDION_H
#define SOCIAL_NETWORK_MICROSERVICES_GORDION_H

#include <sched.h>
#include <sys/resource.h>
#include <sys/syscall.h>
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
#include <thrift/transport/TServerSocket.h>
#include <thrift/transport/TSocket.h>
#include <thrift/transport/TTransportException.h>

#include <errno.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <time.h>

namespace gordion {

// J2: the receive timestamp (CLOCK_REALTIME ns, SCM_TIMESTAMPNS) of the last segment this thread read from its connection
inline int64_t &rxTs() {
  static thread_local int64_t t = 0;
  return t;
}

class TSocketTS : public apache::thrift::transport::TSocket {
 public:
  explicit TSocketTS(THRIFT_SOCKET fd) : apache::thrift::transport::TSocket(fd) {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_TIMESTAMPNS, &one, sizeof(one));
  }
  uint32_t read(uint8_t *buf, uint32_t len) override {
    THRIFT_SOCKET fd = getSocketFD();
    if (fd < 0) return apache::thrift::transport::TSocket::read(buf, len);
    struct iovec iov;
    iov.iov_base = buf;
    iov.iov_len = len;
    char ctl[256];
    struct msghdr msg;
    while (true) {
      memset(&msg, 0, sizeof(msg));
      msg.msg_iov = &iov;
      msg.msg_iovlen = 1;
      msg.msg_control = ctl;
      msg.msg_controllen = sizeof(ctl);
      ssize_t r = recvmsg(fd, &msg, 0);
      if (r < 0) {
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return apache::thrift::transport::TSocket::read(buf, len);  // a receive timeout is set: TSocket's poll path
        throw apache::thrift::transport::TTransportException(apache::thrift::transport::TTransportException::UNKNOWN, "recvmsg()", errno);
      }
      if (r == 0) throw apache::thrift::transport::TTransportException(apache::thrift::transport::TTransportException::END_OF_FILE, "No more data to read.");
      for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_TIMESTAMPNS) {
          struct timespec ts;
          memcpy(&ts, CMSG_DATA(c), sizeof(ts));
          rxTs() = (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
        }
      }
      return (uint32_t)r;
    }
  }
};

class TServerSocketTS : public apache::thrift::transport::TServerSocket {
 public:
  TServerSocketTS(const std::string &address, int port) : apache::thrift::transport::TServerSocket(address, port) {}

 protected:
  std::shared_ptr<apache::thrift::transport::TSocket> createSocket(THRIFT_SOCKET client) override {
    return std::make_shared<TSocketTS>(client);
  }
};

inline int64_t nowNs() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

struct ReqState {
  int lite = 7;         // K5: interceptor parts in force when the request began (1 count, 2 slot, 4 time)
  int method = -1;
  int64_t tap = 0;      // getContext
  int64_t start = 0;    // postRead
  int64_t blocked = 0;  // ns blocked on downstream Thrift calls
  int64_t pauseStart = 0;
  int depth = 0;
  bool done = false;
  bool timed = false;   // production mode: one of the 1-in-N timed requests
  bool rx = false;      // J2: tap is the socket receive timestamp (else the handler entry: fallback)
  int64_t entry = 0;    // J2: the handler entry, for the entry-based histogram
  bool pooled = false;  // the server thread's own state (not deleted in freeContext)
  bool inUse = false;
};

struct Completion {
  int method;
  bool err;
  int64_t total, proc, queue;
  int64_t tid;  // Phase G (G5): the kernel thread id that served the request (thread = request on the Thrift servers)
  int64_t end;  // Addendum F: completion time, ns since the epoch (start = end - total); emitted as rawe in microseconds
};

static const int kGMaxMethods = 64;
static const int kGHistBits = 3;
static const int kGHistN = 64 << kGHistBits;

// J1: one server thread's counters, cumulative, written by that thread only (relaxed atomics: the flusher reads them)
struct alignas(64) ThreadCounters {
  std::atomic<int64_t> arrivals[kGMaxMethods];
  std::atomic<int64_t> ncomp[kGMaxMethods];
  std::atomic<int64_t> nerr[kGMaxMethods];
  std::atomic<uint64_t> hist[kGHistN];
  std::atomic<uint64_t> histh[kGHistN];  // J2: the handler-entry latency
  std::atomic<int64_t> fallback{0};      // J2: timed requests without a usable receive stamp
  std::atomic<int64_t> lastEnd{0};       // J2: this thread's last completion (ns)
  std::atomic<int64_t> slotAcc{0};   // -(sum of begin times) + (sum of end times) of this thread's handler intervals
  std::atomic<int64_t> inflight{0};  // 0 or 1 on a TThreadedServer thread
  std::atomic<int> inUse{0};
  char pad[64];
  ThreadCounters() {
    for (auto &a : arrivals) a.store(0, std::memory_order_relaxed);
    for (auto &a : ncomp) a.store(0, std::memory_order_relaxed);
    for (auto &a : nerr) a.store(0, std::memory_order_relaxed);
    for (auto &a : hist) a.store(0, std::memory_order_relaxed);
    for (auto &a : histh) a.store(0, std::memory_order_relaxed);
  }
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
  int Mode() const { return _mode.load(std::memory_order_relaxed); }
  bool Diag() const { return _diag; }

  static const int kMaxMethods = kGMaxMethods;
  static const int kHistBits = kGHistBits;
  static const int kHistN = kGHistN;

  // J1: this thread's counter block (taken on the first request; given back when the thread exits)
  struct TCHolder {
    ThreadCounters *p = nullptr;
    ~TCHolder() {
      if (p) p->inUse.store(0, std::memory_order_release);
    }
  };
  ThreadCounters *tc() {
    static thread_local TCHolder h;
    if (h.p) return h.p;
    std::lock_guard<std::mutex> g(_tmu);
    for (auto &b : _blocks) {
      if (!b->inUse.load(std::memory_order_acquire)) {
        b->inUse.store(1, std::memory_order_release);
        h.p = b.get();
        return h.p;
      }
    }
    _blocks.emplace_back(new ThreadCounters());
    _blocks.back()->inUse.store(1, std::memory_order_release);
    h.p = _blocks.back().get();
    return h.p;
  }

  // the 1-in-N choice, per server thread (no shared counter)
  bool sample() {
    uint32_t n = _sampleN.load(std::memory_order_relaxed);
    static thread_local uint32_t seq = 0;
    return n <= 1 || (++seq % n) == 0;
  }
  static int histIdx(int64_t v) {
    if (v < (1 << kHistBits)) return v < 0 ? 0 : (int)v;
    int e = 63 - __builtin_clzll((uint64_t)v);
    uint64_t sub = ((uint64_t)v >> (e - kHistBits)) & ((1u << kHistBits) - 1);
    return ((e - kHistBits + 1) << kHistBits) | (int)sub;
  }
  static int64_t histMid(int i) {
    if (i < (1 << kHistBits)) return i;
    int e = (i >> kHistBits) + kHistBits - 1;
    int64_t sub = i & ((1 << kHistBits) - 1);
    return (((int64_t)1 << kHistBits) + sub) * ((int64_t)1 << (e - kHistBits)) + ((int64_t)1 << (e - kHistBits)) / 2;
  }
  void histAdd(int64_t v) { tc()->hist[histIdx(v)].fetch_add(1, std::memory_order_relaxed); }
  void histAddH(int64_t v) { tc()->histh[histIdx(v)].fetch_add(1, std::memory_order_relaxed); }
  bool rxEnabled() const { return _rxts; }
  // J2: the request's start: the receive stamp of the segment this thread last read, if it is newer than the thread's last
  // completion (the frame of this request arrived in it); else the handler entry, counted as a fallback
  int64_t startOf(int64_t entry, bool &rx) {
    ThreadCounters *t = tc();
    int64_t ts = rxTs();
    if (_rxts && ts > 0 && ts > t->lastEnd.load(std::memory_order_relaxed) && ts <= entry) {
      rx = true;
      return ts;
    }
    rx = false;
    t->fallback.fetch_add(1, std::memory_order_relaxed);
    return entry;
  }
  void noteEnd(int64_t now) { tc()->lastEnd.store(now, std::memory_order_relaxed); }

  // K5: the switches
  static int parseIntercept(const std::string &v) {
    if (v.empty() || v == "full") return 7;
    int m = 0;
    std::stringstream ss(v);
    std::string p;
    while (std::getline(ss, p, ',')) {
      if (p == "full") m |= 7;
      else if (p == "count") m |= 1;
      else if (p == "slot") m |= 2;
      else if (p == "time") m |= 1 | 4;
    }
    return m;
  }
  static int parseReads(const std::string &v) {
    int m = 0;
    std::stringstream ss(v);
    std::string p;
    while (std::getline(ss, p, ',')) {
      if (p == "all") m |= 3;
      else if (p == "cpu") m |= 1;
      else if (p == "mhz") m |= 2;
    }
    return m;
  }
  void slotBegin() {
    ThreadCounters *t = tc();
    t->inflight.fetch_add(1, std::memory_order_relaxed);
    t->slotAcc.fetch_sub(nowNs(), std::memory_order_relaxed);
  }
  void slotEnd(int64_t now) {
    ThreadCounters *t = tc();
    t->slotAcc.fetch_add(now, std::memory_order_relaxed);
    t->inflight.fetch_sub(1, std::memory_order_relaxed);
  }
  void countCompletion(int i, bool err) {
    if (i < 0 || i >= kMaxMethods) return;
    ThreadCounters *t = tc();
    t->ncomp[i].fetch_add(1, std::memory_order_relaxed);
    if (err) t->nerr[i].fetch_add(1, std::memory_order_relaxed);
  }

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
    const char *dg = std::getenv("GORDION_DIAG");
    _diag = _raw || (dg && std::string(dg) == "1");
    if (const char *v = std::getenv("GORDION_SAMPLE")) {
      int n = atoi(v);
      if (n >= 1) _sampleN.store((uint32_t)n);
    }
    if (const char *v = std::getenv("GORDION_INTERCEPT")) _mode.store(parseIntercept(v));
    if (const char *v = std::getenv("GORDION_READS")) _reads.store(parseReads(v));
    if (const char *v = std::getenv("GORDION_CTL")) _ctl = v;
    if (const char *v = std::getenv("GORDION_RXTS")) _rxts = std::string(v) != "0";
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
    if ((int)_methods.size() >= kMaxMethods) return -1;
    int i = (int)_methods.size();
    _methods.push_back(m);
    _idx[m] = i;
    return i;
  }

  // the method's index; the generated processor passes the same string literal for a method on every call, so the
  // last name seen on this thread answers without the registry's lock
  int methodIndex(const char *fn) {
    static thread_local const char *lastFn = nullptr;
    static thread_local int lastIdx = -1;
    if (fn == lastFn) return lastIdx;
    const char *dot = std::strrchr(fn, '.');
    std::string m = dot ? std::string(dot + 1) : std::string(fn);
    int i;
    {
      std::lock_guard<std::mutex> g(_mu);
      i = idx(m);
    }
    lastFn = fn;
    lastIdx = i;
    return i;
  }

  void arrival(int i) {
    if (i >= 0 && i < kMaxMethods) tc()->arrivals[i].fetch_add(1, std::memory_order_relaxed);
  }

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
    std::vector<int64_t> total, proc, queue, tids, ends;
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
      const std::vector<int64_t> &vals = which == 0 ? b[i].total : (which == 1 ? b[i].proc : (which == 2 ? b[i].queue : (which == 3 ? b[i].tids : b[i].ends)));
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

  // K5: apply the control file's line when it changed
  void pollCtl() {
    std::ifstream f(_ctl);
    if (!f) return;
    std::string line, tok;
    std::getline(f, line);
    while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
    if (line == _ctlLast) return;
    _ctlLast = line;
    std::stringstream ss(line);
    while (ss >> tok) {
      auto eq = tok.find('=');
      if (eq == std::string::npos) continue;
      std::string k = tok.substr(0, eq), v = tok.substr(eq + 1);
      if (k == "intercept") _mode.store(parseIntercept(v));
      else if (k == "reads") _reads.store(parseReads(v));
      else if (k == "sample" && atoi(v.c_str()) >= 1) _sampleN.store((uint32_t)atoi(v.c_str()));
    }
    std::string esc = line;
    std::replace(esc.begin(), esc.end(), '"', '\'');
    std::string sb = "{\"event\":\"ctl\",\"t\":" + std::to_string(nowNs() / 1000000) + ",\"intercept\":" +
                     std::to_string(_mode.load()) + ",\"reads\":" + std::to_string(_reads.load()) + ",\"line\":\"" + esc + "\"}\n";
    std::fputs(sb.c_str(), _f);
    std::fflush(_f);
  }

  void loop() {
    int64_t winNs = (int64_t)_windowMs * 1000000LL;
    int64_t winStart = (nowNs() / winNs) * winNs;
    int64_t lastCtl = 0;
    while (true) {
      if (!_ctl.empty() && nowNs() - lastCtl >= 1000000000LL) {
        pollCtl();
        lastCtl = nowNs();
      }
      if (_mode.load() == 0 && _reads.load() == 0) {  // K5: everything off: the control-file poll only
        std::this_thread::sleep_for(std::chrono::seconds(1));
        winStart = (nowNs() / winNs) * winNs;
        _lastCPU = cpuNs();
        _idleCPU = 0;
        continue;
      }
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
    {
      std::lock_guard<std::mutex> g(_mu);
      methods = _methods;
    }
    int md = _mode.load(), rd = _reads.load();
    // J1: the sums over every thread's block (cumulative), the window = the difference to the previous sums
    int64_t sumArr[kMaxMethods], sumComp[kMaxMethods], sumErr[kMaxMethods], slotSum = 0;
    uint64_t sumHist[kHistN], sumHistH[kHistN];
    int64_t sumFb = 0;
    for (int i = 0; i < kMaxMethods; i++) sumArr[i] = sumComp[i] = sumErr[i] = 0;
    for (int i = 0; i < kHistN; i++) sumHist[i] = sumHistH[i] = 0;
    int64_t tnow = nowNs();
    {
      std::lock_guard<std::mutex> g(_tmu);
      for (auto &blk : _blocks) {
        for (int i = 0; i < kMaxMethods; i++) {
          sumArr[i] += blk->arrivals[i].load(std::memory_order_relaxed);
          sumComp[i] += blk->ncomp[i].load(std::memory_order_relaxed);
          sumErr[i] += blk->nerr[i].load(std::memory_order_relaxed);
        }
        if (md & 4) {
          for (int i = 0; i < kHistN; i++) {
            sumHist[i] += blk->hist[i].load(std::memory_order_relaxed);
            sumHistH[i] += blk->histh[i].load(std::memory_order_relaxed);
          }
          sumFb += blk->fallback.load(std::memory_order_relaxed);
        }
        int64_t infl = blk->inflight.load(std::memory_order_relaxed);
        slotSum += blk->slotAcc.load(std::memory_order_relaxed) + infl * tnow;
      }
    }
    std::vector<int64_t> arr(methods.size(), 0), ncs(methods.size(), 0);
    int64_t arrivals = 0, errs = 0, nc = 0, ec = 0;
    for (size_t i = 0; i < methods.size() && i < (size_t)kMaxMethods; i++) {
      arr[i] = sumArr[i] - _prevArr[i];
      _prevArr[i] = sumArr[i];
      ncs[i] = sumComp[i] - _prevComp[i];
      _prevComp[i] = sumComp[i];
      ec += sumErr[i] - _prevErr[i];
      _prevErr[i] = sumErr[i];
      arrivals += arr[i];
      nc += ncs[i];
    }
    std::vector<Bucket> b(methods.size());
    std::vector<int64_t> allTotal, allProc, allQueue;
    int64_t slotNs = -1;
    if (md & 2) {
      slotNs = slotSum - _prevSlot;
      if (slotNs < 0) slotNs = 0;
    }
    _prevSlot = slotSum;
    for (auto &c : pend) {
      if (c.method < 0 || c.method >= (int)b.size()) continue;
      b[c.method].total.push_back(c.total);
      b[c.method].tids.push_back(c.tid);
      b[c.method].ends.push_back(c.end / 1000);  // Addendum F: microseconds since the epoch
      b[c.method].proc.push_back(c.proc);
      b[c.method].queue.push_back(c.queue);
      if (c.err) b[c.method].errs++;
      allTotal.push_back(c.total);
      allProc.push_back(c.proc);
      allQueue.push_back(c.queue);
      if (c.err) errs++;
    }
    int64_t winNs = (int64_t)_windowMs * 1000000LL;
    if (md != 0 && arrivals == 0 && allTotal.empty() && nc == 0 && slotNs <= 0) {
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
    if ((md & 4) && !_diag) {
      uint64_t d[kHistN], n = 0;
      for (int i = 0; i < kHistN; i++) {
        d[i] = sumHist[i] - _histPrev[i];
        _histPrev[i] = sumHist[i];
        n += d[i];
      }
      int64_t q[3] = {0, 0, 0};
      if (n > 0) {
        uint64_t want[3] = {(n + 1) / 2, (n * 9 + 9) / 10, (n * 99 + 99) / 100}, acc = 0;
        int k = 0;
        for (int i = 0; i < kHistN && k < 3; i++) {
          acc += d[i];
          while (k < 3 && acc >= want[k]) q[k++] = histMid(i);
        }
      }
      sb += ",\"lat\":[" + std::to_string(n) + "," + std::to_string(q[0]) + "," + std::to_string(q[1]) + "," +
            std::to_string(q[2]) + "],\"sample\":" + std::to_string(_sampleN.load());
      // J2: the handler-entry histogram beside it, and the timed requests that fell back to the entry
      uint64_t dh[kHistN], nh = 0;
      for (int i = 0; i < kHistN; i++) {
        dh[i] = sumHistH[i] - _histPrevH[i];
        _histPrevH[i] = sumHistH[i];
        nh += dh[i];
      }
      int64_t qh[3] = {0, 0, 0};
      if (nh > 0) {
        uint64_t want[3] = {(nh + 1) / 2, (nh * 9 + 9) / 10, (nh * 99 + 99) / 100}, acc = 0;
        int k = 0;
        for (int i = 0; i < kHistN && k < 3; i++) {
          acc += dh[i];
          while (k < 3 && acc >= want[k]) qh[k++] = histMid(i);
        }
      }
      sb += ",\"lath\":[" + std::to_string(nh) + "," + std::to_string(qh[0]) + "," + std::to_string(qh[1]) + "," + std::to_string(qh[2]) + "]";
      sb += ",\"lat_fb\":" + std::to_string(sumFb - _prevFb) + ",\"rxts\":" + std::string(_rxts ? "1" : "0");
      _prevFb = sumFb;
    }
    if ((!(md & 4) || !_diag) && (md & 1)) sb += ",\"nc\":" + std::to_string(nc) + ",\"ec\":" + std::to_string(ec);
    if (slotNs >= 0) sb += ",\"slot\":" + std::to_string(slotNs);
    int64_t cpu = (rd & 1) ? cpuNs() : -1;
    if (cpu >= 0) {
      sb += ",\"cpu\":" + std::to_string(cpu - _lastCPU + _idleCPU);
      _lastCPU = cpu;
      _idleCPU = 0;
    }
    double mhz = (rd & 2) ? cpuMHz() : 0;
    if (mhz > 0) sb += ",\"mhz\":" + std::to_string((int64_t)mhz);
    sb += ",\"all\":[";
    writeStats(sb, allTotal, allProc, allQueue);
    sb += ']';
    if (_raw) {
      writeRaw(sb, "raw", b, 0);
      writeRaw(sb, "rawp", b, 1);
      writeRaw(sb, "rawq", b, 2);
      writeRaw(sb, "rawt", b, 3);  // Phase G: thread id per sample, same order as raw
      writeRaw(sb, "rawe", b, 4);  // Addendum F: completion time per sample (us since the epoch), same order as raw
    }
    sb += ",\"ep\":{";
    bool first = true;
    for (size_t i = 0; i < b.size(); i++) {
      if (arr[i] == 0 && b[i].total.empty() && ncs[i] == 0) continue;
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
  std::mutex _cmu;  // pending completions
  std::vector<Completion> _pending;
  int64_t _lastCPU = 0, _idleCPU = 0, _lastFlushNs = 0;
  std::thread _flusher;
  // K5
  std::atomic<int> _mode{7}, _reads{3};
  // J1: the per-thread blocks and the flusher's previous sums
  std::mutex _tmu;
  std::vector<std::unique_ptr<ThreadCounters>> _blocks;
  int64_t _prevArr[kMaxMethods] = {}, _prevComp[kMaxMethods] = {}, _prevErr[kMaxMethods] = {}, _prevSlot = 0;
  std::string _ctl, _ctlLast;
  // K5 follow-up: production mode
  bool _diag = false;
  std::atomic<uint32_t> _sampleN{8};
  uint64_t _histPrev[kHistN] = {};
  uint64_t _histPrevH[kHistN] = {};  // J2
  int64_t _prevFb = 0;               // J2
  bool _rxts = true;                 // J2: GORDION_RXTS=0 turns the receive stamp off
};

// Server-side hook: one ReqState per request, kept in a thread-local for the duration of the
// handler so that BlockedProtocol can attribute downstream call time to it.
class EventHandler : public apache::thrift::TProcessorEventHandler {
 public:
  void *getContext(const char *fn_name, void *) override {
    Recorder &r = Recorder::Get();
    if (!r.Enabled()) return nullptr;
    int md = r.Mode();
    if (md == 0) return nullptr;  // K5: interceptor off
    ReqState *st = state(r.Diag());
    st->lite = md;
    st->method = r.methodIndex(fn_name);
    if (md & 2) r.slotBegin();
    if (md & 1) r.arrival(st->method);
    if (md & 4) {
      st->timed = r.Diag() || r.sample();
      if (st->timed) {
        st->entry = nowNs();
        st->tap = r.startOf(st->entry, st->rx);
        st->start = st->tap;
        cur() = st;
      }
    }
    return st;
  }
  void freeContext(void *ctx, const char *) override {
    ReqState *st = static_cast<ReqState *>(ctx);
    if (!st) return;
    if (!st->done) finish(st, false);
    if (cur() == st) cur() = nullptr;
    if (st->pooled) st->inUse = false;
    else delete st;
  }
  void postRead(void *ctx, const char *, uint32_t) override {
    ReqState *st = static_cast<ReqState *>(ctx);
    if (st && (st->lite & 4) && st->timed && Recorder::Get().Diag()) st->start = nowNs();  // queue: diagnostic only
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
  // the server thread's own state in production mode (one request at a time per TThreadedServer thread); a fresh one
  // if it is somehow still in use, and always in diagnostic mode
  static ReqState *state(bool diag) {
    static thread_local ReqState tl;
    if (!diag && !tl.inUse) {
      tl = ReqState();
      tl.pooled = tl.inUse = true;
      return &tl;
    }
    return new ReqState();
  }

  static void finish(ReqState *st, bool err) {
    st->done = true;
    Recorder &r = Recorder::Get();
    if (!(st->lite & 4) || !r.Diag()) {  // K5: counting / slot only, or production mode: no per-request record
      int64_t now = ((st->lite & 2) || st->timed) ? nowNs() : 0;
      if (st->lite & 2) r.slotEnd(now);
      if (st->lite & 1) r.countCompletion(st->method, err);
      if (st->timed) {
        int64_t lat = now - st->tap - st->blocked;
        r.histAdd(lat < 0 ? 0 : lat);
        int64_t lath = now - st->entry - st->blocked;
        r.histAddH(lath < 0 ? 0 : lath);
        r.noteEnd(now);
      }
      return;
    }
    int64_t now = nowNs();
    if (st->lite & 2) r.slotEnd(now);
    Completion c;
    c.method = st->method;
    c.err = err;
    c.total = now - st->tap;
    c.tid = (int64_t)syscall(SYS_gettid);
    c.end = now;
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
