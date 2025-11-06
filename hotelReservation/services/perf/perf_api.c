#define _GNU_SOURCE
#include "perf_api.h"
#include <linux/perf_event.h>
#include <asm/unistd.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <sched.h>

// Thread-local buffers for results
_Thread_local static char result_buffer[2048];

// Global (shared across threads) - configuration is set once at init
static int initialized_events = 0;
static struct perf_event_attr event_attrs[MAX_PERF_EVENTS];
static char event_names[MAX_PERF_EVENTS][64];
static int num_configured_events = 0;
static char global_config[256] = "";

static long perf_event_open(struct perf_event_attr *hw_event, pid_t pid,
                            int cpu, int group_fd, unsigned long flags) {
    return syscall(__NR_perf_event_open, hw_event, pid, cpu, group_fd, flags);
}

// Parse event name and configure perf_event_attr
static int parse_event_config(const char* event_name, struct perf_event_attr* pe) {
    memset(pe, 0, sizeof(struct perf_event_attr));
    pe->size = sizeof(struct perf_event_attr);
    pe->disabled = 1;
    pe->exclude_kernel = 1;
    pe->exclude_hv = 1;
    pe->read_format = PERF_FORMAT_GROUP;

    if (strcmp(event_name, "cycles") == 0) {
        pe->type = PERF_TYPE_HARDWARE;
        pe->config = PERF_COUNT_HW_CPU_CYCLES;
        return 0;
    }
    if (strcmp(event_name, "instructions") == 0) {
        pe->type = PERF_TYPE_HARDWARE;
        pe->config = PERF_COUNT_HW_INSTRUCTIONS;
        return 0;
    }
    if (strcmp(event_name, "cache_references") == 0) {
        pe->type = PERF_TYPE_HARDWARE;
        pe->config = PERF_COUNT_HW_CACHE_REFERENCES;
        return 0;
    }
    if (strcmp(event_name, "cache_misses") == 0) {
        pe->type = PERF_TYPE_HARDWARE;
        pe->config = PERF_COUNT_HW_CACHE_MISSES;
        return 0;
    }
    if (strcmp(event_name, "branch_instructions") == 0) {
        pe->type = PERF_TYPE_HARDWARE;
        pe->config = PERF_COUNT_HW_BRANCH_INSTRUCTIONS;
        return 0;
    }
    if (strcmp(event_name, "branch_misses") == 0) {
        pe->type = PERF_TYPE_HARDWARE;
        pe->config = PERF_COUNT_HW_BRANCH_MISSES;
        return 0;
    }
    if (strcmp(event_name, "bus_cycles") == 0) {
        pe->type = PERF_TYPE_HARDWARE;
        pe->config = PERF_COUNT_HW_BUS_CYCLES;
        return 0;
    }
    if (strcmp(event_name, "l1_misses") == 0 || strcmp(event_name, "l1_dcache_load_misses") == 0) {
        pe->type = PERF_TYPE_HW_CACHE;
        pe->config = PERF_COUNT_HW_CACHE_L1D |
                    (PERF_COUNT_HW_CACHE_OP_READ << 8) |
                    (PERF_COUNT_HW_CACHE_RESULT_MISS << 16);
        return 0;
    }
    if (strcmp(event_name, "l1_loads") == 0 || strcmp(event_name, "l1_dcache_loads") == 0) {
        pe->type = PERF_TYPE_HW_CACHE;
        pe->config = PERF_COUNT_HW_CACHE_L1D |
                    (PERF_COUNT_HW_CACHE_OP_READ << 8) |
                    (PERF_COUNT_HW_CACHE_RESULT_ACCESS << 16);
        return 0;
    }
    if (strcmp(event_name, "llc_loads") == 0 || strcmp(event_name, "llc_load") == 0) {
        pe->type = PERF_TYPE_HW_CACHE;
        pe->config = PERF_COUNT_HW_CACHE_LL |
                    (PERF_COUNT_HW_CACHE_OP_READ << 8) |
                    (PERF_COUNT_HW_CACHE_RESULT_ACCESS << 16);
        return 0;
    }
    if (strcmp(event_name, "llc_load_misses") == 0 || strcmp(event_name, "llc_misses") == 0) {
        pe->type = PERF_TYPE_HW_CACHE;
        pe->config = PERF_COUNT_HW_CACHE_LL |
                    (PERF_COUNT_HW_CACHE_OP_READ << 8) |
                    (PERF_COUNT_HW_CACHE_RESULT_MISS << 16);
        return 0;
    }
    if (strcmp(event_name, "context_switches") == 0 || strcmp(event_name, "cs") == 0) {
        pe->type = PERF_TYPE_SOFTWARE;
        pe->config = PERF_COUNT_SW_CONTEXT_SWITCHES;
        pe->exclude_kernel = 0; // Context switches happen in kernel
        return 0;
    }
    if (strcmp(event_name, "page_faults") == 0 || strcmp(event_name, "faults") == 0) {
        pe->type = PERF_TYPE_SOFTWARE;
        pe->config = PERF_COUNT_SW_PAGE_FAULTS;
        pe->exclude_kernel = 0;
        return 0;
    }
    if (strcmp(event_name, "cpu_migrations") == 0 || strcmp(event_name, "migrations") == 0) {
        pe->type = PERF_TYPE_SOFTWARE;
        pe->config = PERF_COUNT_SW_CPU_MIGRATIONS;
        return 0;
    }

    return -1; // Unknown event
}

// Parse configuration string and set up events
int perf_init(const char* config) {
    const char* actual_config = config;
    
    if (config == NULL || strlen(config) == 0) {
        // Default: cycles, instructions, l1_misses
        actual_config = "cycles,instructions,l1_misses";
    }

    // Store config for later reference
    strncpy(global_config, actual_config, sizeof(global_config) - 1);
    global_config[sizeof(global_config) - 1] = '\0';

    // Predefined sets
    if (strcmp(actual_config, "basic") == 0) {
        actual_config = "cycles,instructions,cache_references,cache_misses";
    } else if (strcmp(actual_config, "cpu") == 0) {
        actual_config = "cycles,instructions,branch_instructions,branch_misses";
    } else if (strcmp(actual_config, "memory") == 0) {
        actual_config = "cache_references,cache_misses,l1_loads,l1_misses,llc_loads,llc_load_misses";
    } else if (strcmp(actual_config, "scheduling") == 0) {
        actual_config = "context_switches,cpu_migrations,page_faults";
    } else if (strcmp(actual_config, "bandwidth") == 0) {
        actual_config = "cycles,instructions,cache_references,cache_misses,bus_cycles";
    } else if (strcmp(actual_config, "interference") == 0) {
        actual_config = "cycles,instructions,cache_misses,context_switches,page_faults,l1_misses";
    }

    // Parse comma-separated event list
    char* config_copy = strdup(actual_config);
    if (config_copy == NULL) {
        return -1;
    }

    num_configured_events = 0;
    char* token = strtok(config_copy, ",");
    
    while (token != NULL && num_configured_events < MAX_PERF_EVENTS) {
        // Trim whitespace
        while (*token == ' ' || *token == '\t') token++;
        char* end = token + strlen(token) - 1;
        while (end > token && (*end == ' ' || *end == '\t')) {
            *end = '\0';
            end--;
        }

        if (parse_event_config(token, &event_attrs[num_configured_events]) == 0) {
            snprintf(event_names[num_configured_events], sizeof(event_names[num_configured_events]), "%s", token);
            num_configured_events++;
        }
        token = strtok(NULL, ",");
    }

    free(config_copy);
    initialized_events = (num_configured_events > 0) ? 1 : 0;
    return (num_configured_events > 0) ? 0 : -1;
}

struct perf_handles perf_start() {
    struct perf_handles handles = {0};
    handles.leader_fd = -1;
    handles.num_events = 0;

    if (!initialized_events || num_configured_events == 0) {
        fprintf(stderr, "perf_start: not initialized (initialized=%d, num_events=%d)\n", 
                initialized_events, num_configured_events);
        return handles;
    }

    int cpu = sched_getcpu();
    if (cpu < 0) {
        fprintf(stderr, "perf_start: sched_getcpu() failed: %s\n", strerror(errno));
        return handles;
    }

    // First event is the leader
    if (num_configured_events > 0) {
        handles.leader_fd = perf_event_open(&event_attrs[0], 0, cpu, -1, PERF_FLAG_FD_CLOEXEC);
        if (handles.leader_fd == -1) {
            // Log detailed error to stderr for debugging
            fprintf(stderr, "perf_event_open failed for event '%s' on cpu %d: %s (errno=%d)\n", 
                    event_names[0], cpu, strerror(errno), errno);
            return handles;
        }
        snprintf(handles.event_names[0], sizeof(handles.event_names[0]), "%s", event_names[0]);
        handles.event_fds[0] = handles.leader_fd;
        handles.num_events = 1;
    }

    // Add remaining events to the group
    for (int i = 1; i < num_configured_events; i++) {
        int fd = perf_event_open(&event_attrs[i], 0, cpu, handles.leader_fd, PERF_FLAG_FD_CLOEXEC);
        if (fd == -1) {
            // Close already opened fds
            for (int j = 0; j < handles.num_events; j++) {
                close(handles.event_fds[j]);
            }
            handles.leader_fd = -1;
            handles.num_events = 0;
            return handles;
        }
        handles.event_fds[handles.num_events] = fd;
        snprintf(handles.event_names[handles.num_events], sizeof(handles.event_names[handles.num_events]), "%s", event_names[i]);
        handles.num_events++;
    }

    // Reset and enable
    if (handles.leader_fd >= 0) {
        ioctl(handles.leader_fd, PERF_EVENT_IOC_RESET, 0);
        ioctl(handles.leader_fd, PERF_EVENT_IOC_ENABLE, 0);
    }

    return handles;
}

// Read current counter values without stopping
struct perf_values perf_read(struct perf_handles* handles) {
    struct perf_values values = {0};
    
    if (handles == NULL || handles->leader_fd < 0 || handles->num_events == 0) {
        return values;
    }

    values.num_events = handles->num_events;
    
    // Read all counters
    for (int i = 0; i < handles->num_events; i++) {
        values.values[i] = -1;
        int bytes_read = read(handles->event_fds[i], &values.values[i], sizeof(long long));
        if (bytes_read != sizeof(long long)) {
            values.values[i] = -1;
        }
        snprintf(values.event_names[i], sizeof(values.event_names[i]), "%s", handles->event_names[i]);
    }

    return values;
}

// Pause counters and return current values
struct perf_values perf_pause(struct perf_handles* handles) {
    struct perf_values values = perf_read(handles);
    
    if (handles != NULL && handles->leader_fd >= 0) {
        ioctl(handles->leader_fd, PERF_EVENT_IOC_DISABLE, 0);
    }
    
    return values;
}

// Resume counters from paused state
struct perf_handles perf_resume(struct perf_handles* handles) {
    if (handles != NULL && handles->leader_fd >= 0) {
        // Don't reset - just enable to continue counting
        ioctl(handles->leader_fd, PERF_EVENT_IOC_ENABLE, 0);
    }
    
    return *handles;
}

// Stop counters and return final values
struct perf_values perf_stop(struct perf_handles* handles) {
    struct perf_values values = {0};
    
    if (handles == NULL || handles->leader_fd < 0 || handles->num_events == 0) {
        return values;
    }

    ioctl(handles->leader_fd, PERF_EVENT_IOC_DISABLE, 0);

    // Read all counters
    values.num_events = handles->num_events;
    for (int i = 0; i < handles->num_events; i++) {
        values.values[i] = -1;
        int bytes_read = read(handles->event_fds[i], &values.values[i], sizeof(long long));
        if (bytes_read != sizeof(long long)) {
            values.values[i] = -1;
        }
        snprintf(values.event_names[i], sizeof(values.event_names[i]), "%s", handles->event_names[i]);
    }

    // Close file descriptors
    for (int i = 0; i < handles->num_events; i++) {
        close(handles->event_fds[i]);
    }

    handles->leader_fd = -1;
    handles->num_events = 0;

    return values;
}

// Format perf values as JSON string
const char* perf_values_to_json(struct perf_values* values) {
    if (values == NULL || values->num_events == 0) {
        snprintf(result_buffer, sizeof(result_buffer), "{}");
        return result_buffer;
    }

    result_buffer[0] = '\0';
    strcat(result_buffer, "{");
    for (int i = 0; i < values->num_events; i++) {
        if (i > 0) strcat(result_buffer, ",");
        char value_str[64];
        snprintf(value_str, sizeof(value_str), "\"%s\":%lld", values->event_names[i], values->values[i]);
        strcat(result_buffer, value_str);
    }
    strcat(result_buffer, "}");

    return result_buffer;
}

// Calculate delta between two perf_values
struct perf_values perf_delta(struct perf_values* start, struct perf_values* end) {
    struct perf_values delta = {0};
    
    if (start == NULL || end == NULL || start->num_events != end->num_events) {
        return delta;
    }

    delta.num_events = start->num_events;
    for (int i = 0; i < start->num_events; i++) {
        // Calculate delta (end - start)
        if (start->values[i] >= 0 && end->values[i] >= 0) {
            delta.values[i] = end->values[i] - start->values[i];
        } else {
            delta.values[i] = -1;
        }
        snprintf(delta.event_names[i], sizeof(delta.event_names[i]), "%s", start->event_names[i]);
    }

    return delta;
}

void perf_cleanup() {
    initialized_events = 0;
    num_configured_events = 0;
}
