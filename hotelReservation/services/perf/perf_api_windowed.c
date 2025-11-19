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
    
    // Cache events - L1
    {"l1-misses", PERF_TYPE_HW_CACHE, 
        PERF_COUNT_HW_CACHE_L1D | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16)},
    {"l1-references", PERF_TYPE_HW_CACHE, 
        PERF_COUNT_HW_CACHE_L1D | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_ACCESS << 16)},
    {"l1i-misses", PERF_TYPE_HW_CACHE, 
        PERF_COUNT_HW_CACHE_L1I | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16)},
    
    // Cache events - L2 (note: not all CPUs support L2 separately, may alias to LL)
    {"l2-misses", PERF_TYPE_HW_CACHE,
        PERF_COUNT_HW_CACHE_LL | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16)},
    {"l2-references", PERF_TYPE_HW_CACHE,
        PERF_COUNT_HW_CACHE_LL | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_ACCESS << 16)},
    
    // Cache events - LLC (Last Level Cache)
    {"llc-misses", PERF_TYPE_HW_CACHE,
        PERF_COUNT_HW_CACHE_LL | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16)},
    {"llc-references", PERF_TYPE_HW_CACHE,
        PERF_COUNT_HW_CACHE_LL | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_ACCESS << 16)},
    
    // TLB events - Data TLB
    {"dtlb-misses", PERF_TYPE_HW_CACHE,
        PERF_COUNT_HW_CACHE_DTLB | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16)},
    {"dtlb-references", PERF_TYPE_HW_CACHE,
        PERF_COUNT_HW_CACHE_DTLB | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_ACCESS << 16)},
    {"dtlb-write-misses", PERF_TYPE_HW_CACHE,
        PERF_COUNT_HW_CACHE_DTLB | (PERF_COUNT_HW_CACHE_OP_WRITE << 8) | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16)},
    
    // TLB events - Instruction TLB
    {"itlb-misses", PERF_TYPE_HW_CACHE,
        PERF_COUNT_HW_CACHE_ITLB | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16)},
    {"itlb-references", PERF_TYPE_HW_CACHE,
        PERF_COUNT_HW_CACHE_ITLB | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_ACCESS << 16)},
    
    // Software events - context and scheduling
    {"context-switches", PERF_TYPE_SOFTWARE, PERF_COUNT_SW_CONTEXT_SWITCHES},
    {"cpu-migrations", PERF_TYPE_SOFTWARE, PERF_COUNT_SW_CPU_MIGRATIONS},
    
    // Software events - memory/paging
    {"page-faults", PERF_TYPE_SOFTWARE, PERF_COUNT_SW_PAGE_FAULTS},
    {"minor-faults", PERF_TYPE_SOFTWARE, PERF_COUNT_SW_PAGE_FAULTS_MIN},
    {"major-faults", PERF_TYPE_SOFTWARE, PERF_COUNT_SW_PAGE_FAULTS_MAJ},
    
    // Software events - task scheduling and alignment
    {"task-clock", PERF_TYPE_SOFTWARE, PERF_COUNT_SW_TASK_CLOCK},
    {"alignment-faults", PERF_TYPE_SOFTWARE, PERF_COUNT_SW_ALIGNMENT_FAULTS},
    {"emulation-faults", PERF_TYPE_SOFTWARE, PERF_COUNT_SW_EMULATION_FAULTS},
    
    // Node events (for NUMA-aware systems) - BPF and dummy events
    {"bpf-output", PERF_TYPE_SOFTWARE, PERF_COUNT_SW_BPF_OUTPUT},
    
    // Hardware cache prefetch events
    {"l1-prefetch-misses", PERF_TYPE_HW_CACHE,
        PERF_COUNT_HW_CACHE_L1D | (PERF_COUNT_HW_CACHE_OP_PREFETCH << 8) | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16)},
    {"llc-prefetch-misses", PERF_TYPE_HW_CACHE,
        PERF_COUNT_HW_CACHE_LL | (PERF_COUNT_HW_CACHE_OP_PREFETCH << 8) | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16)},
    
    // Node/NUMA events - requires PMU support
    {"node-loads", PERF_TYPE_HW_CACHE,
        PERF_COUNT_HW_CACHE_NODE | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_ACCESS << 16)},
    {"node-load-misses", PERF_TYPE_HW_CACHE,
        PERF_COUNT_HW_CACHE_NODE | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16)},
    {"node-stores", PERF_TYPE_HW_CACHE,
        PERF_COUNT_HW_CACHE_NODE | (PERF_COUNT_HW_CACHE_OP_WRITE << 8) | (PERF_COUNT_HW_CACHE_RESULT_ACCESS << 16)},
    {"node-store-misses", PERF_TYPE_HW_CACHE,
        PERF_COUNT_HW_CACHE_NODE | (PERF_COUNT_HW_CACHE_OP_WRITE << 8) | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16)},
    
    // Intel-specific RAW events (for DRAM bandwidth monitoring on Intel CPUs)
    // These event codes are for Intel Skylake/Cascade Lake - may need adjustment for other CPUs
    // UNC_M_CAS_COUNT.RD - DRAM read requests (Uncore Memory Controller)
    {"dram-reads", PERF_TYPE_RAW, 0x0304},  // Event 0x04, Umask 0x03
    // UNC_M_CAS_COUNT.WR - DRAM write requests
    {"dram-writes", PERF_TYPE_RAW, 0x0C04}, // Event 0x04, Umask 0x0C
    
    // Memory load/store instructions retired (architectural events)
    {"mem-loads", PERF_TYPE_RAW, 0x01CD},   // MEM_TRANS_RETIRED.LOAD_LATENCY (approximate)
    {"mem-stores", PERF_TYPE_RAW, 0x02CD},  // MEM_TRANS_RETIRED.STORE_LATENCY (approximate)
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

// Parse CPU set string "0,1,2" into array
static int parse_cpu_set(const char* cpu_set_str, int* cpus_out, int max_cpus) {
    if (!cpu_set_str || strcmp(cpu_set_str, "-1") == 0) {
        // Monitor all CPUs - use -1 as single entry
        cpus_out[0] = -1;
        return 1;
    }
    
    int count = 0;
    char* str_copy = strdup(cpu_set_str);
    char* token = strtok(str_copy, ",");
    
    while (token && count < max_cpus) {
        cpus_out[count++] = atoi(token);
        token = strtok(NULL, ",");
    }
    
    free(str_copy);
    return count;
}

perf_window_handle_t* perf_window_init(const char* event_names_str, const char* cpu_set) {
    perf_window_handle_t* handle = (perf_window_handle_t*)calloc(1, sizeof(perf_window_handle_t));
    if (!handle) {
        fprintf(stderr, "Failed to allocate handle\n");
        return NULL;
    }
    
    // Initialize all fds to -1
    for (int i = 0; i < MAX_EVENTS; i++) {
        for (int j = 0; j < MAX_CPUS; j++) {
            handle->event_fds[i][j] = -1;
        }
        handle->event_names[i] = NULL;
        handle->last_values[i] = 0;
    }
    
    // Parse CPU set
    handle->cpu_count = parse_cpu_set(cpu_set, handle->cpus, MAX_CPUS);
    if (handle->cpu_count == 0) {
        fprintf(stderr, "Failed to parse CPU set: %s\n", cpu_set);
        free(handle);
        return NULL;
    }
    
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
    
    // Open perf events for each CPU in the set
    struct perf_event_attr pe = {0};
    pe.size = sizeof(struct perf_event_attr);
    pe.disabled = 1;
    pe.exclude_kernel = 1;
    pe.exclude_hv = 1;
    pe.inherit = 1;  // Count events from child threads
    // Note: NOT using read_format flags to keep simple uint64 reads
    
    // Simplified approach for Go multi-threaded programs:
    // Use pid=-1 (all processes) + cpu=specific to count ALL activity on those CPUs
    // This captures victim service + noisy neighbor + system on the pinned CPUs
    int group_fd = -1;
    
    for (int event_idx = 0; event_idx < handle->event_count; event_idx++) {
        const perf_event_config_t* config = find_event_config(handle->event_names[event_idx]);
        if (!config) {
            fprintf(stderr, "Unknown event: %s\n", handle->event_names[event_idx]);
            perf_window_cleanup(handle);
            return NULL;
        }
        
        pe.type = config->type;
        pe.config = config->config;
        pe.disabled = (event_idx == 0) ? 1 : 0;
        
        // For multi-CPU: aggregate across all CPUs in the set
        for (int cpu_idx = 0; cpu_idx < handle->cpu_count; cpu_idx++) {
            int target_cpu = handle->cpus[cpu_idx];
            int cpu_group_fd = (event_idx == 0) ? -1 : handle->event_fds[0][cpu_idx];
            
            // pid=-1: count ALL processes/threads on this CPU
            // cpu=target: specific CPU
            // This counts total CPU activity (victim + contention)
            int fd = perf_event_open(&pe, -1, target_cpu, cpu_group_fd, PERF_FLAG_FD_CLOEXEC);
            if (fd == -1) {
                fprintf(stderr, "Failed to open perf event %s on CPU %d: %s\n", 
                        handle->event_names[event_idx], target_cpu, strerror(errno));
                perf_window_cleanup(handle);
                return NULL;
            }
            
            handle->event_fds[event_idx][cpu_idx] = fd;
        }
    }
    
    // Enable all counters (enable first CPU's group leader enables all)
    for (int cpu_idx = 0; cpu_idx < handle->cpu_count; cpu_idx++) {
        if (ioctl(handle->event_fds[0][cpu_idx], PERF_EVENT_IOC_RESET, 0) == -1) {
            fprintf(stderr, "Warning: Failed to reset counters for CPU %d: %s\n", 
                    handle->cpus[cpu_idx], strerror(errno));
        }
        
        if (ioctl(handle->event_fds[0][cpu_idx], PERF_EVENT_IOC_ENABLE, 0) == -1) {
            fprintf(stderr, "Warning: Failed to enable counters for CPU %d: %s\n", 
                    handle->cpus[cpu_idx], strerror(errno));
        }
    }
    
    handle->initialized = 1;
    
    // Print initialization message
    if (handle->cpu_count == 1 && handle->cpus[0] == -1) {
        fprintf(stderr, "Initialized windowed perf sampling with %d events on ALL CPUs (pid=-1, system-wide)\n", 
                handle->event_count);
    } else {
        fprintf(stderr, "Initialized windowed perf sampling with %d events on %d CPUs (pid=-1, system-wide): ", 
                handle->event_count, handle->cpu_count);
        for (int i = 0; i < handle->cpu_count; i++) {
            fprintf(stderr, "%d%s", handle->cpus[i], (i < handle->cpu_count-1) ? "," : "\n");
        }
    }
    
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
    
    // Aggregate counters across all CPUs
    for (int event_idx = 0; event_idx < handle->event_count; event_idx++) {
        uint64_t total_value = 0;
        int read_errors = 0;
        
        // Read counter from each CPU and aggregate
        for (int cpu_idx = 0; cpu_idx < handle->cpu_count; cpu_idx++) {
            uint64_t value = 0;
            int fd = handle->event_fds[event_idx][cpu_idx];
            
            if (fd < 0) {
                continue; // Skip invalid FD
            }
            
            // Read counter value (with proper error handling)
            ssize_t bytes_read = read(fd, &value, sizeof(value));
            
            if (bytes_read < 0) {
                fprintf(stderr, "Warning: read() failed for event %s on CPU %d (fd=%d): %s\n", 
                        handle->event_names[event_idx], handle->cpus[cpu_idx], fd, strerror(errno));
                read_errors++;
                continue;
            }
            
            if (bytes_read != sizeof(value)) {
                fprintf(stderr, "Warning: partial read for event %s on CPU %d: got %zd bytes, expected %zu\n",
                        handle->event_names[event_idx], handle->cpus[cpu_idx], bytes_read, sizeof(value));
                read_errors++;
                continue;
            }
            
            // Accumulate value from this CPU
            total_value += value;
        }
        
        // If all CPUs failed to read, return error
        if (read_errors == handle->cpu_count) {
            fprintf(stderr, "Error: All CPUs failed to read event %s\n", handle->event_names[event_idx]);
            return -1;
        }
        
        // Store aggregated value
        values_out[event_idx] = total_value;
        
        // Calculate delta if requested
        if (deltas_out) {
            if (handle->last_values[event_idx] == 0) {
                // First sample, delta is same as value
                deltas_out[event_idx] = total_value;
            } else {
                // Delta is difference from last aggregated sample
                deltas_out[event_idx] = total_value - handle->last_values[event_idx];
            }
        }
        
        // Update last aggregated value
        handle->last_values[event_idx] = total_value;
    }
    
    return 0;
}

int perf_window_reset(perf_window_handle_t* handle) {
    if (!handle || !handle->initialized) {
        return -1;
    }
    
    // Reset all counters for all CPUs
    for (int cpu_idx = 0; cpu_idx < handle->cpu_count; cpu_idx++) {
        if (handle->event_fds[0][cpu_idx] >= 0) {
            if (ioctl(handle->event_fds[0][cpu_idx], PERF_EVENT_IOC_RESET, 0) == -1) {
                fprintf(stderr, "Warning: Failed to reset counters for CPU %d: %s\n", 
                        handle->cpus[cpu_idx], strerror(errno));
            }
        }
    }
    
    // Reset last aggregated values
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
    
    // Close all file descriptors (all events, all CPUs)
    for (int event_idx = 0; event_idx < MAX_EVENTS; event_idx++) {
        for (int cpu_idx = 0; cpu_idx < MAX_CPUS; cpu_idx++) {
            if (handle->event_fds[event_idx][cpu_idx] >= 0) {
                close(handle->event_fds[event_idx][cpu_idx]);
            }
        }
        if (handle->event_names[event_idx]) {
            free(handle->event_names[event_idx]);
        }
    }
    
    free(handle);
}

