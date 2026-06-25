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

curve.csv columns:
  target_rps, arrival_rps_mean, arrival_rps_p50, arrival_rps_p99,
  svc_mean_us, svc_p50_us, svc_p90_us, svc_p99_us, ipc, llc_mpki,
  freq_mhz, freq_util_pct, active_windows, total_requests,
  ghz_actual_rps, ghz_p50_ms, ghz_p90_ms, ghz_p99_ms, ghz_errors, saturated

Service-time columns are request-weighted means of per-window processing_time
stats (no pooled raw durations exist in one shared run_data), so svc_p90/p99
are tail proxies, not globally-pooled percentiles.
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
              "ghz_actual_rps,ghz_p50_ms,ghz_p90_ms,ghz_p99_ms,ghz_errors,saturated")

ZERO_FRAG = "0,0,0,0,0,0,0,0,0,0,0,0,0"


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


def us(ns):
    return (ns or 0) / 1000.0


def to_epoch(ts):
    """Parse a Go RFC3339 / RFC3339Nano timestamp to epoch seconds."""
    if not ts:
        return None
    s = ts.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    # datetime.fromisoformat (<3.11) accepts at most 6 fractional digits.
    s = re.sub(r"(\.\d{6})\d+", r"\1", s)
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
    n = 0
    with open(manifest, newline="") as mf, open(out, "w") as of:
        of.write(CSV_HEADER + "\n")
        reader = csv.reader(mf)
        header_seen = False
        for row in reader:
            if not header_seen:
                header_seen = True
                continue
            if len(row) < 9:
                continue
            level, rps, mstart, mend, actual, p50, p99, err, sat = row[:9]
            try:
                s_ep = float(mstart) if mstart else None
                e_ep = float(mend) if mend else None
            except ValueError:
                s_ep = e_ep = None
            try:
                frag = aggregate(samples, s_ep, e_ep)
            except Exception:
                frag = ZERO_FRAG
            ghz_json = os.path.join(exp_dir, "saturation", "L%s_rps%s.json" % (level, rps))
            ghz_p90 = parse_ghz_pct(ghz_json, 90)
            of.write("%s,%s,%s,%s,%s,%s,%s,%s\n" % (
                rps, frag, actual, p50, ghz_p90, p99, err, sat))
            n += 1

    sys.stderr.write("Rewrote %s (%d levels) from %s\n" % (out, n, os.path.basename(raw)))
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
