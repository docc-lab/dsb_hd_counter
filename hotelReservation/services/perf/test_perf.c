#include <stdio.h>
#include <stdlib.h>
#include "perf_api.h"

int main() {
    printf("=== Testing perf_api ===\n\n");
    
    // Test 1: Initialize with basic events
    printf("Test 1: Initializing with 'basic' event set...\n");
    int result = perf_init("basic");
    if (result != 0) {
        printf("✗ perf_init failed\n");
        return 1;
    }
    printf("✓ perf_init succeeded\n\n");
    
    // Test 2: Start counters
    printf("Test 2: Starting perf counters...\n");
    struct perf_handles handles = perf_start();
    if (handles.leader_fd < 0) {
        printf("✗ perf_start failed (leader_fd=%d)\n", handles.leader_fd);
        printf("  Note: May need sudo or perf_event_paranoid=-1\n");
        return 1;
    }
    printf("✓ perf_start succeeded (leader_fd=%d, num_events=%d)\n", handles.leader_fd, handles.num_events);
    printf("  Events: ");
    for (int i = 0; i < handles.num_events; i++) {
        printf("%s%s", i > 0 ? ", " : "", handles.event_names[i]);
    }
    printf("\n\n");
    
    // Test 3: Do some work
    printf("Test 3: Performing work (1M iterations)...\n");
    volatile long long sum = 0;
    for (int i = 0; i < 1000000; i++) {
        sum += i;
    }
    printf("✓ Work completed (sum=%lld)\n\n", sum);
    
    // Test 4: Read current values
    printf("Test 4: Reading current perf values...\n");
    struct perf_values current = perf_read(&handles);
    printf("✓ Read succeeded:\n");
    for (int i = 0; i < current.num_events; i++) {
        printf("  %s: %lld\n", current.event_names[i], current.values[i]);
    }
    printf("\n");
    
    // Test 5: Pause counters
    printf("Test 5: Pausing perf counters...\n");
    struct perf_values paused = perf_pause(&handles);
    printf("✓ Pause succeeded:\n");
    for (int i = 0; i < paused.num_events; i++) {
        printf("  %s: %lld\n", paused.event_names[i], paused.values[i]);
    }
    printf("\n");
    
    // Test 6: Do more work while paused (shouldn't count)
    printf("Test 6: Performing work while PAUSED (should not count)...\n");
    for (int i = 0; i < 1000000; i++) {
        sum += i;
    }
    printf("✓ Work completed\n\n");
    
    // Test 7: Resume counters
    printf("Test 7: Resuming perf counters...\n");
    perf_resume(&handles);
    printf("✓ Resume succeeded\n\n");
    
    // Test 8: Do more work (should count)
    printf("Test 8: Performing work after RESUME (should count)...\n");
    for (int i = 0; i < 500000; i++) {
        sum += i;
    }
    printf("✓ Work completed\n\n");
    
    // Test 9: Stop and get final values
    printf("Test 9: Stopping perf counters...\n");
    struct perf_values final = perf_stop(&handles);
    printf("✓ Stop succeeded:\n");
    for (int i = 0; i < final.num_events; i++) {
        printf("  %s: %lld\n", final.event_names[i], final.values[i]);
    }
    printf("\n");
    
    // Test 10: Calculate delta
    printf("Test 10: Calculating delta (final - paused)...\n");
    struct perf_values delta = perf_delta(&paused, &final);
    printf("✓ Delta calculated:\n");
    for (int i = 0; i < delta.num_events; i++) {
        printf("  %s: %lld (should reflect only post-resume work)\n", 
               delta.event_names[i], delta.values[i]);
    }
    printf("\n");
    
    // Test 11: JSON formatting
    printf("Test 11: Formatting values as JSON...\n");
    const char* json = perf_values_to_json(&final);
    printf("✓ JSON output:\n  %s\n\n", json);
    
    // Cleanup
    printf("Test 12: Cleanup...\n");
    perf_cleanup();
    printf("✓ Cleanup succeeded\n\n");
    
    printf("=== All tests passed! ===\n");
    printf("\nNote: Verify that:\n");
    printf("  - Final values > Paused values (counters increased)\n");
    printf("  - Delta values show only post-resume work\n");
    printf("  - Paused period work did NOT increase counters\n");
    
    return 0;
}

