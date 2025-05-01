#ifndef PERF_API_H
#define PERF_API_H

struct perf_handles {
    int leader_fd;
    int instructions_fd;
    int l1_misses_fd;
};

// Start performance counters
struct perf_handles perf_start();

// Stop counters and return a result string like: "cycles=..., instructions=..., l1_misses=..."
const char* perf_stop(int leader_fd, int instructions_fd, int l1_misses_fd);

#endif // PERF_API_H
