#define _GNU_SOURCE
#include "perf_api.h"

#include <linux/perf_event.h>
#include <asm/unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <sched.h>
#include <string.h>

static int initialized = 0;
static int leader_fd = -1;
static int instructions_fd = -1;
static int l1_misses_fd = -1;

// Static buffer to hold result string
static char result_buffer[256];

static long perf_event_open(struct perf_event_attr *hw_event, pid_t pid,
                            int cpu, int group_fd, unsigned long flags) {
    return syscall(__NR_perf_event_open, hw_event, pid, cpu, group_fd, flags);
}

int perf_start() {
    if (initialized) return 0;

    struct perf_event_attr pe = {0};

    // Setup leader: CPU cycles
    pe.type = PERF_TYPE_HARDWARE;
    pe.size = sizeof(struct perf_event_attr);
    pe.config = PERF_COUNT_HW_CPU_CYCLES;
    pe.disabled = 1;
    pe.exclude_kernel = 1;
    pe.exclude_hv = 1;

    leader_fd = perf_event_open(&pe, 0, -1, -1, 0);
    if (leader_fd == -1) {
        perror("perf_event_open (cycles)");
        return -1;
    }

    pe.disabled = 0;

    // Instructions
    pe.config = PERF_COUNT_HW_INSTRUCTIONS;
    instructions_fd = perf_event_open(&pe, 0, -1, leader_fd, 0);
    if (instructions_fd == -1) {
        perror("perf_event_open (instructions)");
        return -1;
    }

    // L1 data cache misses
    pe.type = PERF_TYPE_HW_CACHE;
    pe.config = PERF_COUNT_HW_CACHE_L1D |
                (PERF_COUNT_HW_CACHE_OP_READ << 8) |
                (PERF_COUNT_HW_CACHE_RESULT_MISS << 16);
    l1_misses_fd = perf_event_open(&pe, 0, -1, leader_fd, 0);
    if (l1_misses_fd == -1) {
        perror("perf_event_open (l1 misses)");
        return -1;
    }

    // Optional: pin to CPU 0
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(0, &set);
    sched_setaffinity(0, sizeof(set), &set);

    // Start measurement
    ioctl(leader_fd, PERF_EVENT_IOC_RESET, 0);
    ioctl(leader_fd, PERF_EVENT_IOC_ENABLE, 0);

    initialized = 1;
    return 0;
}

const char* perf_stop() {
    if (!initialized || leader_fd == -1) {
        snprintf(result_buffer, sizeof(result_buffer), "error=not_initialized");
        return result_buffer;
    }

    ioctl(leader_fd, PERF_EVENT_IOC_DISABLE, 0);

    long long cycles = 0, instructions = 0, l1_misses = 0;
    read(leader_fd, &cycles, sizeof(long long));
    read(instructions_fd, &instructions, sizeof(long long));
    read(l1_misses_fd, &l1_misses, sizeof(long long));

    // Format output string
    snprintf(result_buffer, sizeof(result_buffer),
             "cycles=%lld, instructions=%lld, l1_misses=%lld",
             cycles, instructions, l1_misses);

    // Clean up
    close(leader_fd);
    close(instructions_fd);
    close(l1_misses_fd);

    leader_fd = instructions_fd = l1_misses_fd = -1;

    return result_buffer;
}
