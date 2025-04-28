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

static int initialized = 0;
static int leader_fd = -1;
static int instructions_fd = -1;
static int l1_misses_fd = -1;
static char result_buffer[256];
static char error_buffer[256];

static long perf_event_open(struct perf_event_attr *hw_event, pid_t pid,
                            int cpu, int group_fd, unsigned long flags) {
    return syscall(__NR_perf_event_open, hw_event, pid, cpu, group_fd, flags);
}

int perf_start() {
    if (!initialized) {
        struct perf_event_attr pe = {0};

        int cpu = sched_getcpu();

        // Leader: cycles
        pe.type = PERF_TYPE_HARDWARE;
        pe.size = sizeof(struct perf_event_attr);
        pe.config = PERF_COUNT_HW_CPU_CYCLES;
        pe.disabled = 1;
        pe.exclude_kernel = 1;
        pe.exclude_hv = 1;

        leader_fd = perf_event_open(&pe, 0, cpu, -1, PERF_FLAG_FD_CLOEXEC);
        if (leader_fd == -1) {
            perror("perf_event_open (cycles)");
            return -1;
        }

        // Instructions
        pe.disabled = 0;
        pe.config = PERF_COUNT_HW_INSTRUCTIONS;
        instructions_fd = perf_event_open(&pe, 0, cpu, leader_fd, PERF_FLAG_FD_CLOEXEC);
        if (instructions_fd == -1) {
            perror("perf_event_open (instructions)");
            close(leader_fd);
            return -1;
        }

        // L1 cache misses
        pe.type = PERF_TYPE_HW_CACHE;
        pe.config = PERF_COUNT_HW_CACHE_L1D |
                    (PERF_COUNT_HW_CACHE_OP_READ << 8) |
                    (PERF_COUNT_HW_CACHE_RESULT_MISS << 16);
        l1_misses_fd = perf_event_open(&pe, 0, cpu, leader_fd, PERF_FLAG_FD_CLOEXEC);
        if (l1_misses_fd == -1) {
            perror("perf_event_open (l1_misses)");
            close(leader_fd);
            close(instructions_fd);
            return -1;
        }

        initialized = 1;
    }

    // Reset and enable only if already initialized
    ioctl(leader_fd, PERF_EVENT_IOC_RESET, 0);
    ioctl(leader_fd, PERF_EVENT_IOC_ENABLE, 0);
    return 0;
}

const char* perf_stop() {
    if (!initialized) return "not_initialized";

    ioctl(leader_fd, PERF_EVENT_IOC_DISABLE, 0);

    long long cycles = -1, instructions = -1, l1_misses = -1;
    int bytes_read = read(leader_fd, &cycles, sizeof(long long));
    read(instructions_fd, &instructions, sizeof(long long));
    read(l1_misses_fd, &l1_misses, sizeof(long long));

    if (bytes_read == -1) {
        snprintf(error_buffer, sizeof(error_buffer), "read failed: %s", strerror(errno));
        return error_buffer;
    }

    snprintf(result_buffer, sizeof(result_buffer),
             "cycles=%lld, instructions=%lld, l1_misses=%lld",
             cycles, instructions, l1_misses);

    close(leader_fd);
    close(instructions_fd);
    close(l1_misses_fd);

    leader_fd = instructions_fd = l1_misses_fd = -1;

    return result_buffer;
}
