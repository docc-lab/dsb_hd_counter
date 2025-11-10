#ifndef PERF_API_WINDOWED_H
#define PERF_API_WINDOWED_H

#include <stdint.h>

#define MAX_EVENTS 16

// Handle for windowed sampling session
typedef struct perf_window_handle {
    int event_fds[MAX_EVENTS];        // File descriptors for all monitored events
    int event_count;                   // Number of active events
    int cpu;                           // CPU pinned to (-1 for any)
    uint64_t last_values[MAX_EVENTS];  // Previous values for delta calculation
    char* event_names[MAX_EVENTS];     // Event name strings (for debugging)
    int initialized;                   // 1 if successfully initialized
} perf_window_handle_t;

// Event name to perf event config mapping
typedef struct perf_event_config {
    const char* name;
    uint32_t type;
    uint64_t config;
} perf_event_config_t;

// Initialize windowed sampling for continuous monitoring
// event_names: comma-separated string like "cycles,instructions,cache-misses"
// cpu: CPU to monitor (-1 for current CPU, 0 for any CPU)
// Returns handle on success, NULL on error
perf_window_handle_t* perf_window_init(const char* event_names_str, int cpu);

// Take a sample (non-destructive read, counters keep running)
// handle: window handle from perf_window_init
// values_out: receives cumulative counter values (must be at least handle->event_count size)
// deltas_out: receives delta since last sample (must be at least handle->event_count size)
// Returns 0 on success, -1 on error
int perf_window_sample(perf_window_handle_t* handle, 
                       uint64_t* values_out, 
                       uint64_t* deltas_out);

// Reset counters at window boundary (optional, for relative measurements)
// Returns 0 on success, -1 on error
int perf_window_reset(perf_window_handle_t* handle);

// Get event name by index
const char* perf_window_get_event_name(perf_window_handle_t* handle, int index);

// Cleanup (stops counters, closes fds, frees memory)
void perf_window_cleanup(perf_window_handle_t* handle);

#endif // PERF_API_WINDOWED_H

