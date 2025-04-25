#ifndef PERF_API_H
#define PERF_API_H

// Start performance counters
int perf_start();

// Stop counters and return a result string like: "cycles=..., instructions=..., l1_misses=..."
const char* perf_stop();

#endif // PERF_API_H
