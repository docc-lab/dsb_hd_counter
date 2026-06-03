/*
 * msr_reader: per-window CPU frequency utilization helper.
 *
 * Reads MSR 0x30A (MSR_CORE_C0_RESIDENCY) per online core and MSR 0x10
 * (TSC) to compute the count of cores above a configurable C0-residency
 * threshold per window. Looks up that count in the turbo ratio table read
 * from MSR 0x1AD (MSR_TURBO_RATIO_LIMIT) to produce current_max_mhz.
 *
 * fds for /dev/cpu/N/msr are opened once at init and reused across calls
 * to keep per-tick overhead well below 1% on typical 64-core systems
 * (matches the budget cited in actual-frequency.md).
 */

#define _GNU_SOURCE
#include "msr_reader.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>

#define MSR_TURBO_RATIO_LIMIT 0x1AD
#define MSR_CORE_C0_RESIDENCY 0x30A
#define MSR_TSC               0x10

#define MSR_BUS_FREQ_MHZ      100  /* Multiplier for turbo ratios on Intel
                                      Core/Xeon since Nehalem. The bus
                                      reference clock is 100 MHz; each byte
                                      in MSR 0x1AD encodes a multiplier of
                                      that. This is correct for all the
                                      Skylake/Cascade Lake/Ice Lake/Sapphire
                                      Rapids hardware we run on. */

struct msr_reader_t {
    int      cores[MSR_READER_MAX_CORES];      /* logical CPU IDs (0..n-1) */
    int      fds[MSR_READER_MAX_CORES];        /* per-core /dev/cpu/N/msr fd */
    int      n_cores;

    uint64_t prev_c0[MSR_READER_MAX_CORES];    /* last C0 residency per core */
    uint64_t prev_tsc;                          /* last TSC (read on cores[0]) */
    int      have_prev;                         /* 0 until first sample primes */

    /* turbo_max_mhz[i] = max turbo MHz when (i+1) cores are active. */
    uint32_t turbo_max_mhz[MSR_READER_MAX_TURBO_BINS];
    int      n_turbo_bins;

    double   c0_threshold;
    int      refresh_every;
    int      calls_since_refresh;
};

/* ---- helpers --------------------------------------------------------- */

static int read_msr(int fd, uint32_t addr, uint64_t *val) {
    if (pread(fd, val, sizeof(*val), (off_t)addr) != (ssize_t)sizeof(*val)) {
        return -1;
    }
    return 0;
}

/*
 * Parse /sys/devices/system/cpu/online which has the form "0-63" or
 * "0,2-5,8". Fills cores[] in order, returns count, or -1 on parse error.
 */
static int parse_online_cpus(int *cores, int max_cores) {
    FILE *f = fopen("/sys/devices/system/cpu/online", "r");
    if (!f) return -1;

    char buf[1024];
    if (!fgets(buf, sizeof(buf), f)) {
        fclose(f);
        return -1;
    }
    fclose(f);

    int n = 0;
    char *p = buf;
    while (*p && n < max_cores) {
        while (*p && (isspace((unsigned char)*p) || *p == ',')) p++;
        if (!*p) break;

        char *end = NULL;
        long start = strtol(p, &end, 10);
        if (end == p) return -1;
        long stop = start;
        if (*end == '-') {
            p = end + 1;
            stop = strtol(p, &end, 10);
        }
        for (long c = start; c <= stop && n < max_cores; c++) {
            cores[n++] = (int)c;
        }
        p = end;
    }
    return n;
}

/*
 * Decode MSR 0x1AD into turbo_max_mhz[bin]. Each of the 8 bytes encodes
 * the max ratio when (byte_index + 1) cores are active. Many CPUs only use
 * the low 8 bytes; we read both halves of the 64-bit MSR for completeness.
 *
 * On client/desktop SKUs and some Xeons MSR 0x1AE extends the table for
 * higher core counts; we don't read it because our cluster is dual-socket
 * server class where 0x1AD covers everything we need. If active_n exceeds
 * the populated bins we clamp to the highest defined ratio.
 */
static int read_turbo_table(int fd, uint32_t *table_out, int max_bins) {
    uint64_t val;
    if (read_msr(fd, MSR_TURBO_RATIO_LIMIT, &val) != 0) return -1;

    int bins = 0;
    for (int i = 0; i < 8 && bins < max_bins; i++) {
        uint8_t ratio = (uint8_t)((val >> (i * 8)) & 0xFFu);
        if (ratio == 0) break;  /* zero terminates the populated list */
        table_out[bins++] = (uint32_t)ratio * (uint32_t)MSR_BUS_FREQ_MHZ;
    }
    return bins;
}

/* ---- public API ------------------------------------------------------ */

msr_reader_t *msr_reader_init(double c0_active_threshold,
                              int    refresh_turbo_table_every_n_calls) {
    if (refresh_turbo_table_every_n_calls < 1) {
        refresh_turbo_table_every_n_calls = 1;
    }
    if (c0_active_threshold < 0.0) c0_active_threshold = 0.0;
    if (c0_active_threshold > 1.0) c0_active_threshold = 1.0;

    msr_reader_t *r = (msr_reader_t *)calloc(1, sizeof(*r));
    if (!r) return NULL;

    r->c0_threshold  = c0_active_threshold;
    r->refresh_every = refresh_turbo_table_every_n_calls;
    for (int i = 0; i < MSR_READER_MAX_CORES; i++) r->fds[i] = -1;

    int n = parse_online_cpus(r->cores, MSR_READER_MAX_CORES);
    if (n <= 0) {
        free(r);
        return NULL;
    }
    r->n_cores = n;

    int opened = 0;
    for (int i = 0; i < n; i++) {
        char path[64];
        snprintf(path, sizeof(path), "/dev/cpu/%d/msr", r->cores[i]);
        r->fds[i] = open(path, O_RDONLY);
        if (r->fds[i] < 0) {
            fprintf(stderr,
                    "msr_reader: open %s failed: %s (need 'modprobe msr' on the host?)\n",
                    path, strerror(errno));
            continue;
        }
        opened++;
    }
    if (opened == 0) {
        msr_reader_free(r);
        return NULL;
    }

    /* Pick the first successfully-opened fd as the canonical fd for
       per-package MSR reads (TSC and turbo table). */
    int canon = -1;
    for (int i = 0; i < n; i++) {
        if (r->fds[i] >= 0) { canon = r->fds[i]; break; }
    }
    if (canon < 0) {
        msr_reader_free(r);
        return NULL;
    }

    int bins = read_turbo_table(canon, r->turbo_max_mhz, MSR_READER_MAX_TURBO_BINS);
    if (bins <= 0) {
        fprintf(stderr,
                "msr_reader: failed to read turbo ratio table (MSR 0x%x)\n",
                MSR_TURBO_RATIO_LIMIT);
        msr_reader_free(r);
        return NULL;
    }
    r->n_turbo_bins = bins;

    return r;
}

void msr_reader_free(msr_reader_t *r) {
    if (!r) return;
    for (int i = 0; i < MSR_READER_MAX_CORES; i++) {
        if (r->fds[i] >= 0) close(r->fds[i]);
    }
    free(r);
}

int msr_reader_n_cores(const msr_reader_t *r) {
    return r ? r->n_cores : 0;
}

int msr_reader_n_turbo_bins(const msr_reader_t *r) {
    return r ? r->n_turbo_bins : 0;
}

uint32_t msr_reader_turbo_max_mhz(const msr_reader_t *r, int active_cores) {
    if (!r || r->n_turbo_bins <= 0) return 0;
    int idx = active_cores - 1;
    if (idx < 0) idx = 0;
    if (idx >= r->n_turbo_bins) idx = r->n_turbo_bins - 1;
    return r->turbo_max_mhz[idx];
}

int msr_reader_sample(msr_reader_t *r, freq_snapshot_t *out) {
    if (!r || !out) return -1;
    memset(out, 0, sizeof(*out));
    out->n_cores = r->n_cores;

    /* Find canonical fd for TSC read. */
    int canon_fd = -1;
    for (int i = 0; i < r->n_cores; i++) {
        if (r->fds[i] >= 0) { canon_fd = r->fds[i]; break; }
    }
    if (canon_fd < 0) {
        out->ok = 0;
        return 0;
    }

    /* Optional periodic turbo table refresh. */
    if (r->have_prev && r->refresh_every > 0) {
        r->calls_since_refresh++;
        if (r->calls_since_refresh >= r->refresh_every) {
            uint32_t fresh[MSR_READER_MAX_TURBO_BINS];
            int bins = read_turbo_table(canon_fd, fresh, MSR_READER_MAX_TURBO_BINS);
            if (bins > 0) {
                memcpy(r->turbo_max_mhz, fresh, sizeof(uint32_t) * (size_t)bins);
                r->n_turbo_bins = bins;
            }
            r->calls_since_refresh = 0;
        }
    }

    uint64_t cur_c0[MSR_READER_MAX_CORES];
    uint64_t cur_tsc = 0;
    int      read_failed = 0;

    if (read_msr(canon_fd, MSR_TSC, &cur_tsc) != 0) {
        read_failed = 1;
    }

    for (int i = 0; i < r->n_cores; i++) {
        cur_c0[i] = 0;
        if (r->fds[i] < 0) {
            read_failed = 1;
            continue;
        }
        if (read_msr(r->fds[i], MSR_CORE_C0_RESIDENCY, &cur_c0[i]) != 0) {
            read_failed = 1;
        }
    }

    if (!r->have_prev) {
        /* Prime state. No delta available yet. */
        memcpy(r->prev_c0, cur_c0, sizeof(uint64_t) * (size_t)r->n_cores);
        r->prev_tsc   = cur_tsc;
        r->have_prev  = 1;
        out->ok       = 0;
        out->tsc_delta = 0;
        return 0;
    }

    uint64_t tsc_delta = (cur_tsc >= r->prev_tsc) ? (cur_tsc - r->prev_tsc) : 0;

    int active_n = 0;
    if (tsc_delta > 0 && !read_failed) {
        for (int i = 0; i < r->n_cores; i++) {
            uint64_t prev = r->prev_c0[i];
            uint64_t cur  = cur_c0[i];
            uint64_t dc0  = (cur >= prev) ? (cur - prev) : 0;
            double busy   = (double)dc0 / (double)tsc_delta;
            if (busy > r->c0_threshold) active_n++;
        }
    }

    /* Persist state for next window. */
    memcpy(r->prev_c0, cur_c0, sizeof(uint64_t) * (size_t)r->n_cores);
    r->prev_tsc = cur_tsc;

    out->tsc_delta       = tsc_delta;
    out->active_n        = active_n;
    out->current_max_mhz = msr_reader_turbo_max_mhz(r,
                                                    active_n > 0 ? active_n : 1);
    out->ok              = (read_failed || tsc_delta == 0) ? 0 : 1;
    return 0;
}
