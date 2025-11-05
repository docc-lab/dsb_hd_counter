#ifndef PERF_API_H
#define PERF_API_H

#define MAX_PERF_EVENTS 10

struct perf_handles {
    int leader_fd;
    int num_events;
    int event_fds[MAX_PERF_EVENTS];
    char event_names[MAX_PERF_EVENTS][64];
};

struct perf_values {
    int num_events;
    long long values[MAX_PERF_EVENTS];
    char event_names[MAX_PERF_EVENTS][64];
};

// Initialize perf events based on configuration string
// Format: "cycles,instructions,l1_misses" or "basic" or "cpu" etc.
// Returns 0 on success, -1 on error
int perf_init(const char* config);

// Start performance counters
struct perf_handles perf_start();

// Pause counters and return current values (for resuming later)
struct perf_values perf_pause(struct perf_handles* handles);

// Resume counters from paused state
struct perf_handles perf_resume(struct perf_handles* handles);

// Read current counter values without stopping
struct perf_values perf_read(struct perf_handles* handles);

// Stop counters and return final values
struct perf_values perf_stop(struct perf_handles* handles);

// Format perf values as JSON string
const char* perf_values_to_json(struct perf_values* values);

// Calculate delta between two perf_values
struct perf_values perf_delta(struct perf_values* start, struct perf_values* end);

// Cleanup perf resources
void perf_cleanup();

#endif // PERF_API_H
