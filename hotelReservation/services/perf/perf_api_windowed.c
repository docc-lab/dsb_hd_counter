#define _GNU_SOURCE
#include "perf_api_windowed.h"
#include <linux/perf_event.h>
#include <asm/unistd.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sched.h>

// Perf event syscall wrapper
static long perf_event_open(struct perf_event_attr *hw_event, pid_t pid,
                            int cpu, int group_fd, unsigned long flags) {
    return syscall(__NR_perf_event_open, hw_event, pid, cpu, group_fd, flags);
}

// Supported event configurations
static const perf_event_config_t event_configs[] = {
    // Hardware events
    {"cycles", PERF_TYPE_HARDWARE, PERF_COUNT_HW_CPU_CYCLES},
    {"instructions", PERF_TYPE_HARDWARE, PERF_COUNT_HW_INSTRUCTIONS},
    {"cache-references", PERF_TYPE_HARDWARE, PERF_COUNT_HW_CACHE_REFERENCES},
    {"cache-misses", PERF_TYPE_HARDWARE, PERF_COUNT_HW_CACHE_MISSES},
    {"branch-instructions", PERF_TYPE_HARDWARE, PERF_COUNT_HW_BRANCH_INSTRUCTIONS},
    {"branch-misses", PERF_TYPE_HARDWARE, PERF_COUNT_HW_BRANCH_MISSES},
    {"bus-cycles", PERF_TYPE_HARDWARE, PERF_COUNT_HW_BUS_CYCLES},
    {"stalled-cycles-frontend", PERF_TYPE_HARDWARE, PERF_COUNT_HW_STALLED_CYCLES_FRONTEND},
    {"stalled-cycles-backend", PERF_TYPE_HARDWARE, PERF_COUNT_HW_STALLED_CYCLES_BACKEND},
    
    // Cache events
    {"l1-misses", PERF_TYPE_HW_CACHE, 
        PERF_COUNT_HW_CACHE_L1D | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16)},
    {"llc-misses", PERF_TYPE_HW_CACHE,
        PERF_COUNT_HW_CACHE_LL | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16)},
    {"llc-references", PERF_TYPE_HW_CACHE,
        PERF_COUNT_HW_CACHE_LL | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_ACCESS << 16)},
    {"dtlb-misses", PERF_TYPE_HW_CACHE,
        PERF_COUNT_HW_CACHE_DTLB | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16)},
    {"itlb-misses", PERF_TYPE_HW_CACHE,
        PERF_COUNT_HW_CACHE_ITLB | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16)},
    
    // Software events
    {"context-switches", PERF_TYPE_SOFTWARE, PERF_COUNT_SW_CONTEXT_SWITCHES},
    {"cpu-migrations", PERF_TYPE_SOFTWARE, PERF_COUNT_SW_CPU_MIGRATIONS},
    {"page-faults", PERF_TYPE_SOFTWARE, PERF_COUNT_SW_PAGE_FAULTS},
    {"minor-faults", PERF_TYPE_SOFTWARE, PERF_COUNT_SW_PAGE_FAULTS_MIN},
    {"major-faults", PERF_TYPE_SOFTWARE, PERF_COUNT_SW_PAGE_FAULTS_MAJ},
};

static const int num_event_configs = sizeof(event_configs) / sizeof(event_configs[0]);

// Find event config by name
static const perf_event_config_t* find_event_config(const char* name) {
    for (int i = 0; i < num_event_configs; i++) {
        if (strcmp(event_configs[i].name, name) == 0) {
            return &event_configs[i];
        }
    }
    return NULL;
}

// Parse comma-separated event names
static int parse_event_names(const char* event_names_str, char** event_names_out, int max_events) {
    if (!event_names_str || !event_names_out) return 0;
    
    char* str_copy = strdup(event_names_str);
    if (!str_copy) return 0;
    
    int count = 0;
    char* token = strtok(str_copy, ",");
    
    while (token != NULL && count < max_events) {
        // Trim whitespace
        while (*token == ' ' || *token == '\t') token++;
        char* end = token + strlen(token) - 1;
        while (end > token && (*end == ' ' || *end == '\t')) end--;
        *(end + 1) = '\0';
        
        event_names_out[count] = strdup(token);
        if (!event_names_out[count]) {
            // Cleanup on error
            for (int i = 0; i < count; i++) {
                free(event_names_out[i]);
            }
            free(str_copy);
            return 0;
        }
        count++;
        token = strtok(NULL, ",");
    }
    
    free(str_copy);
    return count;
}

perf_window_handle_t* perf_window_init(const char* event_names_str, int cpu) {
    perf_window_handle_t* handle = (perf_window_handle_t*)calloc(1, sizeof(perf_window_handle_t));
    if (!handle) {
        fprintf(stderr, "Failed to allocate handle\n");
        return NULL;
    }
    
    // Initialize all fds to -1
    for (int i = 0; i < MAX_EVENTS; i++) {
        handle->event_fds[i] = -1;
        handle->event_names[i] = NULL;
        handle->last_values[i] = 0;
    }
    
    // Determine CPU
    if (cpu < 0) {
        cpu = sched_getcpu();
        if (cpu < 0) {
            cpu = -1; // Monitor all CPUs for this thread
        }
    }
    handle->cpu = cpu;
    
    // Parse event names
    char* event_names[MAX_EVENTS];
    handle->event_count = parse_event_names(event_names_str, event_names, MAX_EVENTS);
    if (handle->event_count == 0) {
        fprintf(stderr, "Failed to parse event names: %s\n", event_names_str);
        free(handle);
        return NULL;
    }
    
    // Store event names in handle
    for (int i = 0; i < handle->event_count; i++) {
        handle->event_names[i] = event_names[i];
    }
    
    // Open perf events
    struct perf_event_attr pe = {0};
    pe.size = sizeof(struct perf_event_attr);
    pe.disabled = 1;
    pe.exclude_kernel = 1;
    pe.exclude_hv = 1;
    pe.inherit = 1;  // Count events from child threads/processes
    
    int group_fd = -1;
    
    for (int i = 0; i < handle->event_count; i++) {
        const perf_event_config_t* config = find_event_config(handle->event_names[i]);
        if (!config) {
            fprintf(stderr, "Unknown event: %s\n", handle->event_names[i]);
            perf_window_cleanup(handle);
            return NULL;
        }
        
        pe.type = config->type;
        pe.config = config->config;
        
        // First event is the group leader
        if (i == 0) {
            pe.disabled = 1;
        } else {
            pe.disabled = 0;
        }
        
        // Open event (monitor current thread/process: pid=0)
        int fd = perf_event_open(&pe, 0, handle->cpu, group_fd, PERF_FLAG_FD_CLOEXEC);
        if (fd == -1) {
            fprintf(stderr, "Failed to open perf event %s: %s (type=%u, config=%llu)\n", 
                    handle->event_names[i], strerror(errno), pe.type, pe.config);
            perf_window_cleanup(handle);
            return NULL;
        }
        
        handle->event_fds[i] = fd;
        
        // First fd is the group leader
        if (i == 0) {
            group_fd = fd;
        }
    }
    
    // Enable all counters (group leader enables all)
    if (ioctl(handle->event_fds[0], PERF_EVENT_IOC_RESET, 0) == -1) {
        fprintf(stderr, "Failed to reset counters: %s\n", strerror(errno));
        perf_window_cleanup(handle);
        return NULL;
    }
    
    if (ioctl(handle->event_fds[0], PERF_EVENT_IOC_ENABLE, 0) == -1) {
        fprintf(stderr, "Failed to enable counters: %s\n", strerror(errno));
        perf_window_cleanup(handle);
        return NULL;
    }
    
    handle->initialized = 1;
    
    fprintf(stderr, "Initialized windowed perf sampling with %d events on CPU %d\n", 
            handle->event_count, handle->cpu);
    
    return handle;
}

int perf_window_sample(perf_window_handle_t* handle, 
                       uint64_t* values_out, 
                       uint64_t* deltas_out) {
    if (!handle || !handle->initialized) {
        return -1;
    }
    
    if (!values_out) {
        return -1;
    }
    
    // Read all counters
    for (int i = 0; i < handle->event_count; i++) {
        uint64_t value = 0;
        ssize_t bytes_read = read(handle->event_fds[i], &value, sizeof(value));
        
        if (bytes_read != sizeof(value)) {
            fprintf(stderr, "Failed to read counter %s: %s\n", 
                    handle->event_names[i], strerror(errno));
            return -1;
        }
        
        values_out[i] = value;
        
        // Calculate delta if requested
        if (deltas_out) {
            if (handle->last_values[i] == 0) {
                // First sample, delta is same as value
                deltas_out[i] = value;
            } else {
                // Delta is difference from last sample
                deltas_out[i] = value - handle->last_values[i];
            }
        }
        
        // Update last value
        handle->last_values[i] = value;
    }
    
    return 0;
}

int perf_window_reset(perf_window_handle_t* handle) {
    if (!handle || !handle->initialized) {
        return -1;
    }
    
    // Reset all counters
    if (ioctl(handle->event_fds[0], PERF_EVENT_IOC_RESET, 0) == -1) {
        fprintf(stderr, "Failed to reset counters: %s\n", strerror(errno));
        return -1;
    }
    
    // Reset last values
    for (int i = 0; i < handle->event_count; i++) {
        handle->last_values[i] = 0;
    }
    
    return 0;
}

const char* perf_window_get_event_name(perf_window_handle_t* handle, int index) {
    if (!handle || index < 0 || index >= handle->event_count) {
        return NULL;
    }
    return handle->event_names[index];
}

void perf_window_cleanup(perf_window_handle_t* handle) {
    if (!handle) return;
    
    // Close all file descriptors
    for (int i = 0; i < handle->event_count; i++) {
        if (handle->event_fds[i] >= 0) {
            close(handle->event_fds[i]);
        }
        if (handle->event_names[i]) {
            free(handle->event_names[i]);
        }
    }
    
    free(handle);
}

