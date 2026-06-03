#ifndef MSR_READER_H
#define MSR_READER_H

#include <stdint.h>

/*
 * msr_reader: per-window CPU frequency utilization measurement via MSR reads.
 *
 * Methodology (see hotelReservation/noisy-neighbors/actual-frequency.md):
 *   - actual_freq is computed by the caller from perf cycles/ref-cycles ratio.
 *     We only contribute the system-wide turbo-bin lookup needed to know what
 *     "100%" looks like at this instant.
 *   - active_n  = count(cores with C0 residency over `c0_active_threshold`)
 *                 in the most recent sample window. Read from MSR 0x30A,
 *                 normalized by ΔTSC (MSR 0x10).
 *   - current_max_mhz = turbo_table[active_n - 1], i.e. the per-bin max
 *                       turbo frequency from MSR 0x1AD.
 *   - turbo_table is read once at init, then refreshed every
 *     `refresh_turbo_table_every_n_calls` calls to track thermal-throttle drift.
 *
 * The caller (Go side) attaches actual_freq + tsc_freq + threshold and computes
 * freq_util_pct and turbo_on from the snapshot returned here.
 */

#define MSR_READER_MAX_CORES 256
#define MSR_READER_MAX_TURBO_BINS 256

typedef struct msr_reader_t msr_reader_t;

typedef struct {
    int      ok;              /* 1 if all MSR reads in this tick succeeded */
    int      active_n;        /* number of cores in C0 above threshold this window */
    int      n_cores;         /* total online cores tracked */
    uint32_t current_max_mhz; /* turbo_table[active_n - 1] in MHz */
    uint64_t tsc_delta;       /* ΔTSC across this window (for diagnostics) */
} freq_snapshot_t;

/*
 * Initialize an msr_reader.
 *   c0_active_threshold:               fraction in [0,1], e.g. 0.05 = 5%.
 *   refresh_turbo_table_every_n_calls: re-read MSR 0x1AD this often (>=1).
 *
 * Returns NULL if /dev/cpu/N/msr is not accessible or if MSR 0x1AD is
 * unreadable. The caller is expected to soft-fail and continue without
 * frequency utilization fields when this returns NULL (for example when the
 * 'msr' kernel module is not loaded on the worker node).
 */
msr_reader_t *msr_reader_init(double c0_active_threshold,
                              int    refresh_turbo_table_every_n_calls);

/*
 * Read C0 residency and TSC for every tracked core, compute active_n, and
 * look up current_max_mhz from the turbo table. Populates *out.
 *
 * Returns 0 on success, -1 on hard error. On a per-tick read failure the
 * function still returns 0 but sets out->ok = 0.
 *
 * The first call after init has no previous snapshot to delta against, so it
 * sets out->ok = 0 and primes the internal state. Subsequent calls produce
 * meaningful deltas.
 */
int msr_reader_sample(msr_reader_t *r, freq_snapshot_t *out);

/*
 * Free fds, free memory. Safe to call with NULL.
 */
void msr_reader_free(msr_reader_t *r);

/*
 * Diagnostic accessors (read once after init, e.g. to log to metadata).
 */
int      msr_reader_n_cores(const msr_reader_t *r);
int      msr_reader_n_turbo_bins(const msr_reader_t *r);
uint32_t msr_reader_turbo_max_mhz(const msr_reader_t *r, int active_cores);

#endif /* MSR_READER_H */
