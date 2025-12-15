#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <x86intrin.h>
#include <sched.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Serialized RDTSC read at start of measurement
static inline uint64_t rdtsc_start(void) {
    unsigned cycles_low, cycles_high;
    __asm__ volatile (
        "cpuid\n\t"  // Serialize
        "rdtsc\n\t"
        "mov %%edx, %0\n\t"
        "mov %%eax, %1\n\t"
        : "=r" (cycles_high), "=r" (cycles_low)
        :: "%rax", "%rbx", "%rcx", "%rdx");
    return ((uint64_t)cycles_high << 32) | cycles_low;
}

// Serialized RDTSC read at end of measurement
static inline uint64_t rdtsc_end(void) {
    unsigned cycles_low, cycles_high;
    __asm__ volatile (
        "rdtscp\n\t"  // Read and serialize
        "mov %%edx, %0\n\t"
        "mov %%eax, %1\n\t"
        "cpuid\n\t"   // Serialize after
        : "=r" (cycles_high), "=r" (cycles_low)
        :: "%rax", "%rbx", "%rcx", "%rdx");
    return ((uint64_t)cycles_high << 32) | cycles_low;
}

// Pin thread to specific CPU core
int pin_to_cpu(int cpu_id) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu_id, &cpuset);
    return pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);
}

// Read CPU frequency from /proc/cpuinfo (in MHz)
double get_cpu_frequency_mhz() {
    FILE *f = fopen("/proc/cpuinfo", "r");
    if (!f) {
        // Try reading nominal frequency from sysfs
        f = fopen("/sys/devices/system/cpu/cpu0/cpufreq/base_frequency", "r");
        if (!f) {
            // Fallback: try reading current frequency
            f = fopen("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", "r");
            if (!f) {
                fprintf(stderr, "Warning: Cannot read CPU frequency, using default 2400 MHz\n");
                return 2400.0;
            }
            uint64_t freq_khz;
            if (fscanf(f, "%lu", &freq_khz) == 1) {
                fclose(f);
                return freq_khz / 1000.0;
            }
            fclose(f);
            return 2400.0;
        }
        uint64_t freq_khz;
        if (fscanf(f, "%lu", &freq_khz) == 1) {
            fclose(f);
            return freq_khz / 1000.0;
        }
        fclose(f);
        return 2400.0;
    }
    
    char line[256];
    double freq_mhz = 2400.0;  // Default fallback
    while (fgets(line, sizeof(line), f)) {
        if (strstr(line, "cpu MHz") || strstr(line, "model name")) {
            char *freq_str = strchr(line, ':');
            if (freq_str) {
                freq_str++;
                // Try to extract frequency
                char *at = strstr(freq_str, "@");
                if (at) {
                    // Format: "... @ 2.40GHz"
                    double ghz;
                    if (sscanf(at + 1, "%lfGHz", &ghz) == 1) {
                        freq_mhz = ghz * 1000.0;
                        break;
                    }
                } else if (strstr(line, "cpu MHz")) {
                    // Format: "cpu MHz : 2400.000"
                    if (sscanf(freq_str, "%lf", &freq_mhz) == 1) {
                        break;
                    }
                }
            }
        }
    }
    fclose(f);
    return freq_mhz;
}

// Calibrate measurement overhead
uint64_t calibrate_overhead() {
    const int samples = 1000;
    uint64_t overhead_sum = 0;
    
    for (int i = 0; i < samples; i++) {
        uint64_t start = rdtsc_start();
        uint64_t end = rdtsc_end();
        overhead_sum += (end - start);
    }
    
    return overhead_sum / samples;
}

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <cpu_id> <timestamp_file>\n", argv[0]);
        fprintf(stderr, "  cpu_id: CPU core to pin to (0-N)\n");
        fprintf(stderr, "  timestamp_file: File to write cycle count to\n");
        return 1;
    }
    
    int cpu_id = atoi(argv[1]);
    const char *output_file = argv[2];
    
    // Pin to specified CPU to avoid migration
    if (pin_to_cpu(cpu_id) != 0) {
        fprintf(stderr, "Warning: Failed to pin to CPU %d, measurements may be inaccurate\n", cpu_id);
    }
    
    // Get CPU frequency
    double freq_mhz = get_cpu_frequency_mhz();
    
    // Calibrate overhead
    uint64_t overhead = calibrate_overhead();
    
    // Read cycle count
    uint64_t cycles = rdtsc_start();
    
    // Write to file: cycles,frequency_mhz,overhead
    FILE *f = fopen(output_file, "w");
    if (!f) {
        fprintf(stderr, "Error: Cannot write to %s\n", output_file);
        return 1;
    }
    
    fprintf(f, "%lu,%0.2f,%lu\n", cycles, freq_mhz, overhead);
    fclose(f);
    
    // Print to stdout as well for logging
    printf("Cycles: %lu\n", cycles);
    printf("CPU Frequency: %.2f MHz\n", freq_mhz);
    printf("Measurement overhead: %lu cycles\n", overhead);
    
    return 0;
}

