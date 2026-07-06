#!/usr/bin/env python3
"""
Aggregate windowed samples into curve.csv rows.

Two modes:

  curve_aggregate.py <run_data.json> [start_epoch] [end_epoch]
      Print ONE level's 13-field fragment (the per-level interface).

  curve_aggregate.py --build <exp_dir>
      Build the WHOLE curve.csv for a finished experiment in a single pass:
      load <exp_dir>/raw/windowed/<svc>/run_data_full_raw.json ONCE, read
      <exp_dir>/saturation/levels.csv, slice per level in memory, pull
      ghz_p90 from each level's saturation/L<level>_rps<rps>.json, and write
      <exp_dir>/curve.csv. This avoids re-parsing the (large) run_data once
      per level -- for an hours-long run that's the difference between one
      ~seconds load and dozens of them.

A level's "active" windows are samples whose absolute `timestamp` falls in
[start_epoch,end_epoch] AND whose timing_window.request_count > 0 (so the
idle warmup/cooldown never dilutes the numbers). Slicing is done on the
sample timestamp in Python -- no jq / GNU date dependency.

Primary signal = the interceptor's in-pod processing_time (within-service
execution time), NOT ghz's semi-e2e latency. ghz columns are retained for
reference only; the `saturated` verdict is now derived from svc_p99.

Stall rejection
---------------
The in-pod windowed sampler occasionally stalls the service for hundreds of ms
(the `context canceled` errors), which inflates the interceptor service-time in
the small fraction of 100ms windows where a stall lands. --build now REJECTS
those windows per level: a window is contaminated if its p99 exceeds
    median(window p99) + K * 1.4826 * MAD(window p99)   (robust outlier, K=5)
and the svc_* columns are request-weighted means over the CLEAN windows only.
svc_bad_windows / svc_bad_pct report how much was removed so the noise is
visible. Set env CURVE_STALL_K=0 to disable rejection (use all windows).

curve.csv columns:
  target_rps, arrival_rps_mean, arrival_rps_p50, arrival_rps_p99,
  svc_mean_us, svc_p50_us, svc_p90_us, svc_p99_us, ipc, llc_mpki,
  freq_mhz, freq_util_pct, active_windows, total_requests,
  ghz_actual_rps, ghz_p50_ms, ghz_p90_ms, ghz_p99_ms, ghz_errors, saturated,
  svc_bad_windows, svc_bad_pct,
  svc_p50_norm_kcyc, svc_p90_norm_kcyc, svc_p99_norm_kcyc

Service-time columns are request-weighted means of per-window processing_time
stats (no pooled raw durations exist in one shared run_data), so svc_p90/p99
are tail proxies, not globally-pooled percentiles.

Frequency-normalized columns (svc_*_norm_kcyc): normalized latency =
freq x latency, per window -- i.e. service time expressed in KILOCYCLES of
work (us x MHz / 1000), the frequency-invariant measure. This removes the
DVFS effect (governor downclocks idle cores, so raw low-load service time
measures the power policy, not the service). Each window is normalized by ITS
OWN measured actual_freq_mhz before aggregation, so the correction is exact
even mid-governor-ramp. Windows without freq data (freq.ok=false) are
excluded; the column is 0 when none have it. The correction is for clock
speed only: IPC shifts (cache warmth) and memory-bound time are real workload
behavior and are deliberately retained. (Divide by base freq in GHz to read
it back as us-at-base-clock.)

The `saturated` verdict (svc-based): a level is saturated once its svc_p99
crosses SATURATION_P99_THRESHOLD x the intrinsic baseline (the lowest-arrival
level's clean svc_p99). Uses the frequency-NORMALIZED p99 whenever every
served level has freq data (a DVFS-inflated baseline would otherwise loosen
the threshold ~3-4x); falls back to raw svc_p99 otherwise. The last
non-saturated level is the intrinsic knee.
"""
import csv
import glob
import json
import os
import re
import sys
from datetime import datetime

CSV_HEADER = ("target_rps,arrival_rps_mean,arrival_rps_p50,arrival_rps_p99,"
              "svc_mean_us,svc_p50_us,svc_p90_us,svc_p99_us,ipc,llc_mpki,"
              "freq_mhz,freq_util_pct,active_windows,total_requests,"
              "ghz_actual_rps,ghz_p50_ms,ghz_p90_ms,ghz_p99_ms,ghz_errors,saturated,"
              "svc_bad_windows,svc_bad_pct,"
              "svc_p50_norm_kcyc,svc_p90_norm_kcyc,svc_p99_norm_kcyc")

ZERO_FRAG = "0,0,0,0,0,0,0,0,0,0,0,0,0"

# Robust-outlier multiplier for stall-window rejection (median + K*1.4826*MAD
# of per-window p99). Env override; 0 disables rejection.
STALL_K = float(os.environ.get("CURVE_STALL_K", "5") or "5")
# svc_p99 must exceed this multiple of the intrinsic baseline to count as
# saturated. Shares the driver's env var so both sides agree on the threshold.
SAT_P99_THRESHOLD = float(os.environ.get("SATURATION_P99_THRESHOLD", "4") or "4")


def pct(xs, q):
    if not xs:
        return 0.0
    xs = sorted(xs)
    if len(xs) == 1:
        return float(xs[0])
    pos = (len(xs) - 1) * q
    lo = int(pos)
    hi = min(lo + 1, len(xs) - 1)
    frac = pos - lo
    return xs[lo] * (1 - frac) + xs[hi] * frac


def mean(xs):
    return (sum(xs) / len(xs)) if xs else 0.0


def median(xs):
    if not xs:
        return 0.0
    ys = sorted(xs)
    n = len(ys)
    mid = n // 2
    return ys[mid] if n % 2 else (ys[mid - 1] + ys[mid]) / 2.0


def mad(xs):
    """Median absolute deviation (unscaled)."""
    if not xs:
        return 0.0
    m = median(xs)
    return median([abs(x - m) for x in xs])


def us(ns):
    return (ns or 0) / 1000.0


def to_epoch(ts):
    """Parse a Go RFC3339 / RFC3339Nano timestamp to epoch seconds."""
    if not ts:
        return None
    s = ts.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    # Go's RFC3339Nano trims trailing zeros, so the fraction is 1-9 digits;
    # datetime.fromisoformat (<3.11) needs exactly 3 or 6. Normalize to 6.
    s = re.sub(r"\.(\d+)", lambda m: "." + m.group(1)[:6].ljust(6, "0"), s,
               count=1)
    try:
        return datetime.fromisoformat(s).timestamp()
    except Exception:
        return None


def aggregate(samples, start_epoch, end_epoch):
    """Return the 13-field curve fragment string for one level slice."""
    def in_window(s):
        if start_epoch is None and end_epoch is None:
            return True
        te = to_epoch(s.get("timestamp"))
        if te is None:
            return False
        if start_epoch is not None and te < start_epoch:
            return False
        if end_epoch is not None and te > end_epoch:
            return False
        return True

    active = [s for s in samples
              if in_window(s) and s.get("timing_window")
              and (s["timing_window"].get("request_count") or 0) > 0]

    arr = [(s["timing_window"].get("arrival_rps_1s") or 0.0) for s in active]

    def wmean(field):
        num = 0.0
        den = 0
        for s in active:
            ptw = (s["timing_window"].get("processing_time") or {})
            c = ptw.get("count") or 0
            num += (ptw.get(field) or 0) * c
            den += c
        return (num / den) if den else 0.0

    svc_mean = us(wmean("mean_ns"))
    svc_p50 = us(wmean("p50_ns"))
    svc_p90 = us(wmean("p90_ns"))
    svc_p99 = us(wmean("p99_ns"))

    def perf_sum(key):
        return sum((s.get("perf_deltas") or {}).get(key, 0) for s in active)
    instr = perf_sum("instructions")
    cyc = perf_sum("cycles")
    llcm = perf_sum("LLC-load-misses")
    ipc = (instr / cyc) if cyc else 0.0
    llc_mpki = (llcm / instr * 1000.0) if instr else 0.0

    fr = [s["freq"]["actual_freq_mhz"] for s in active if s.get("freq", {}).get("ok")]
    fu = [s["freq"]["freq_util_pct"] for s in active if s.get("freq", {}).get("ok")]
    freq_mhz = mean(fr)
    freq_util = mean(fu)

    total_req = sum((s["timing_window"].get("request_count") or 0) for s in active)

    return "%.2f,%.2f,%.2f,%.1f,%.1f,%.1f,%.1f,%.3f,%.2f,%.0f,%.1f,%d,%d" % (
        mean(arr), pct(arr, 0.5), pct(arr, 0.99),
        svc_mean, svc_p50, svc_p90, svc_p99, ipc, llc_mpki,
        freq_mhz, freq_util, len(active), total_req)


def level_stats(samples, start_epoch, end_epoch):
    """Robust per-level stats for curve.csv (--build path).

    Same active-window rule as aggregate(), but rejects stall-contaminated
    windows before computing the service-time columns: a window whose p99
    processing time is a robust MAD outlier vs the level's own windows is
    dropped (those are the sampler-stall windows). Returns a dict; svc_* are
    request-weighted means over the CLEAN windows only.
    """
    def in_window(s):
        if start_epoch is None and end_epoch is None:
            return True
        te = to_epoch(s.get("timestamp"))
        if te is None:
            return False
        if start_epoch is not None and te < start_epoch:
            return False
        if end_epoch is not None and te > end_epoch:
            return False
        return True

    active = [s for s in samples
              if in_window(s) and s.get("timing_window")
              and (s["timing_window"].get("request_count") or 0) > 0]

    n_active = len(active)
    if n_active == 0:
        return dict(arr_mean=0.0, arr_p50=0.0, arr_p99=0.0, svc_mean=0.0,
                    svc_p50=0.0, svc_p90=0.0, svc_p99=0.0, ipc=0.0, llc_mpki=0.0,
                    freq_mhz=0.0, freq_util=0.0, active_windows=0, total_req=0,
                    bad_windows=0, bad_pct=0.0,
                    svc_p50_fn=0.0, svc_p90_fn=0.0, svc_p99_fn=0.0)

    # Robust stall-window rejection on per-window p99 processing time.
    def win_p99(s):
        return (s["timing_window"].get("processing_time") or {}).get("p99_ns") or 0
    if STALL_K > 0 and n_active >= 4:
        p99s = [win_p99(s) for s in active]
        thr = median(p99s) + STALL_K * 1.4826 * mad(p99s)
        clean = [s for s in active if win_p99(s) <= thr]
        if not clean:                 # all flagged (degenerate) -> keep all
            clean = active
    else:
        clean = active
    bad_windows = n_active - len(clean)

    arr = [(s["timing_window"].get("arrival_rps_1s") or 0.0) for s in clean]

    def wmean(field):
        num = 0.0
        den = 0
        for s in clean:
            ptw = (s["timing_window"].get("processing_time") or {})
            c = ptw.get("count") or 0
            num += (ptw.get(field) or 0) * c
            den += c
        return (num / den) if den else 0.0

    def wmean_fnorm(field):
        """Request-weighted mean of normalized latency = freq x latency,
        i.e. per-window service time in KILOCYCLES (ns * MHz * 1e-6), using
        each window's OWN measured frequency. Frequency-invariant; only
        windows with valid freq data participate."""
        num = 0.0
        den = 0
        for s in clean:
            fr = s.get("freq") or {}
            if not fr.get("ok"):
                continue
            f = fr.get("actual_freq_mhz") or 0.0
            if f <= 0:
                continue
            ptw = (s["timing_window"].get("processing_time") or {})
            c = ptw.get("count") or 0
            num += (ptw.get(field) or 0) * f * 1e-6 * c
            den += c
        return (num / den) if den else 0.0

    # perf / freq use the clean windows too (a stall window's perf deltas are
    # also unrepresentative of steady-state).
    def perf_sum(key):
        return sum((s.get("perf_deltas") or {}).get(key, 0) for s in clean)
    instr = perf_sum("instructions")
    cyc = perf_sum("cycles")
    llcm = perf_sum("LLC-load-misses")
    fr = [s["freq"]["actual_freq_mhz"] for s in clean if s.get("freq", {}).get("ok")]
    fu = [s["freq"]["freq_util_pct"] for s in clean if s.get("freq", {}).get("ok")]

    return dict(
        arr_mean=mean(arr), arr_p50=pct(arr, 0.5), arr_p99=pct(arr, 0.99),
        svc_mean=us(wmean("mean_ns")), svc_p50=us(wmean("p50_ns")),
        svc_p90=us(wmean("p90_ns")), svc_p99=us(wmean("p99_ns")),
        ipc=(instr / cyc) if cyc else 0.0,
        llc_mpki=(llcm / instr * 1000.0) if instr else 0.0,
        freq_mhz=mean(fr), freq_util=mean(fu),
        active_windows=len(clean),
        total_req=sum((s["timing_window"].get("request_count") or 0) for s in clean),
        bad_windows=bad_windows,
        bad_pct=(100.0 * bad_windows / n_active) if n_active else 0.0,
        svc_p50_fn=wmean_fnorm("p50_ns"),   # already kilocycles (ns*MHz*1e-6)
        svc_p90_fn=wmean_fnorm("p90_ns"),
        svc_p99_fn=wmean_fnorm("p99_ns"),
    )


def parse_ghz_pct(path, target_pct):
    """Read a percentile (ms) from a ghz --format json output file."""
    try:
        with open(path) as f:
            text = f.read()
        i = text.find("{")
        data = json.loads(text[i:]) if i >= 0 else {}
        for entry in data.get("latencyDistribution", []) or []:
            if abs(float(entry.get("percentage", -1)) - target_pct) < 0.001:
                return "%.2f" % (float(entry.get("latency", 0)) / 1e6)
    except Exception:
        pass
    return "0"


def build(exp_dir):
    manifest = os.path.join(exp_dir, "saturation", "levels.csv")
    raws = glob.glob(os.path.join(exp_dir, "raw", "windowed", "*", "run_data_full_raw.json"))
    if not os.path.isfile(manifest):
        sys.stderr.write("ERROR: no manifest at %s\n" % manifest)
        return 1
    if not raws:
        sys.stderr.write("ERROR: no run_data_full_raw.json under %s/raw/windowed/*/\n" % exp_dir)
        return 1
    raw = raws[0]

    # Load the (potentially large) run_data ONCE.
    with open(raw) as f:
        samples = (json.load(f).get("samples")) or []

    out = os.path.join(exp_dir, "curve.csv")

    # Pass 1: slice every level and compute robust interceptor stats.
    levels = []
    with open(manifest, newline="") as mf:
        reader = csv.reader(mf)
        header_seen = False
        for row in reader:
            if not header_seen:
                header_seen = True
                continue
            if len(row) < 9:
                continue
            level, rps, mstart, mend, actual, ghz_p50, ghz_p99, err, _sat = row[:9]
            try:
                s_ep = float(mstart) if mstart else None
                e_ep = float(mend) if mend else None
            except ValueError:
                s_ep = e_ep = None
            try:
                st = level_stats(samples, s_ep, e_ep)
            except Exception:
                st = level_stats([], None, None)
            ghz_json = os.path.join(exp_dir, "saturation", "L%s_rps%s.json" % (level, rps))
            ghz_p90 = parse_ghz_pct(ghz_json, 90)
            levels.append(dict(rps=rps, st=st, ghz_actual=actual,
                               ghz_p50=ghz_p50, ghz_p90=ghz_p90, ghz_p99=ghz_p99,
                               ghz_err=err))

    # Baseline = intrinsic (unloaded) svc_p99: the clean svc_p99 of the level
    # with the lowest arrival rate that actually served requests. The knee is
    # the last level whose svc_p99 stays under SAT_P99_THRESHOLD x baseline.
    #
    # Prefer the frequency-NORMALIZED p99 whenever every served level carries
    # freq data: under a stock governor the raw low-load baseline is inflated
    # by DVFS downclocking (measures the power policy, not the service), which
    # would loosen the saturation threshold ~3-4x and push the detected knee
    # right. Falls back to raw svc_p99 when freq data is missing.
    served = [lv for lv in levels if lv["st"]["total_req"] > 0 and lv["st"]["svc_p99"] > 0]
    use_fnorm = bool(served) and all(lv["st"]["svc_p99_fn"] > 0 for lv in served)
    key = "svc_p99_fn" if use_fnorm else "svc_p99"
    baseline = 0.0
    if served:
        baseline = min(served, key=lambda lv: lv["st"]["arr_mean"])["st"][key]

    # Pass 2: write, deriving `saturated` from (normalized) svc_p99 vs baseline.
    n = 0
    with open(out, "w") as of:
        of.write(CSV_HEADER + "\n")
        for lv in levels:
            st = lv["st"]
            sat = "false"
            if baseline > 0 and st[key] > 0 and \
                    st[key] >= SAT_P99_THRESHOLD * baseline:
                sat = "true"
            frag = "%.2f,%.2f,%.2f,%.1f,%.1f,%.1f,%.1f,%.3f,%.2f,%.0f,%.1f,%d,%d" % (
                st["arr_mean"], st["arr_p50"], st["arr_p99"],
                st["svc_mean"], st["svc_p50"], st["svc_p90"], st["svc_p99"],
                st["ipc"], st["llc_mpki"], st["freq_mhz"], st["freq_util"],
                st["active_windows"], st["total_req"])
            of.write("%s,%s,%s,%s,%s,%s,%s,%s,%d,%.1f,%.1f,%.1f,%.1f\n" % (
                lv["rps"], frag, lv["ghz_actual"], lv["ghz_p50"], lv["ghz_p90"],
                lv["ghz_p99"], lv["ghz_err"], sat,
                st["bad_windows"], st["bad_pct"],
                st["svc_p50_fn"], st["svc_p90_fn"], st["svc_p99_fn"]))
            n += 1

    sys.stderr.write(
        "Rewrote %s (%d levels) from %s  [baseline %s=%.1f %s (%s), "
        "sat threshold=%.1fx, stall K=%.1f]\n"
        % (out, n, os.path.basename(raw), key, baseline,
           "kcyc" if use_fnorm else "us",
           "freq-normalized" if use_fnorm else "RAW: no freq data",
           SAT_P99_THRESHOLD, STALL_K))
    return 0


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--build":
        sys.exit(build(sys.argv[2]))

    # Single-level mode (per-level interface).
    try:
        path = sys.argv[1]
        start_epoch = float(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] != "" else None
        end_epoch = float(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] != "" else None
        with open(path) as f:
            samples = (json.load(f).get("samples")) or []
    except Exception:
        print(ZERO_FRAG)
        return
    print(aggregate(samples, start_epoch, end_epoch))


if __name__ == "__main__":
    main()
