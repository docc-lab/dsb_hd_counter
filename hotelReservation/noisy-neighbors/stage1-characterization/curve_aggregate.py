#!/usr/bin/env python3
"""
Aggregate ONE RPS level's windowed samples into a curve.csv fragment.

Usage: curve_aggregate.py <run_data.json> [start_epoch] [end_epoch]

Selects the level's "active" windows: samples whose absolute `timestamp`
falls in [start_epoch, end_epoch] (epoch seconds; either may be empty to
leave that side unbounded) AND whose timing_window.request_count > 0 -- so
the idle warmup/cooldown around the measured ghz window never dilutes the
numbers. Slicing is done here (in Python, on the sample timestamp) rather
than in bash via `date -d` + run_start/offset_ms, which depended on jq and
GNU date being present and parsing RFC3339Nano.

Prints one CSV line:
  arrival_rps_mean,arrival_rps_p50,arrival_rps_p99,
  svc_mean_us,svc_p50_us,svc_p90_us,svc_p99_us,ipc,llc_mpki,
  freq_mhz,freq_util_pct,active_windows,total_requests

Arrival rate is the interceptor's trailing-1s sliding window
(timing_window.arrival_rps_1s). Service-time columns are request-weighted
means of the per-window processing_time stats (no pooled raw durations are
available when slicing one shared run_data), so svc_p99_us is a
request-weighted mean of window p99s -- a tail proxy, not a global p99.
"""
import json
import re
import sys
from datetime import datetime


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


def main():
    try:
        path = sys.argv[1]
        start_epoch = float(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] != "" else None
        end_epoch = float(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] != "" else None
        with open(path) as f:
            d = json.load(f)
    except Exception:
        print("0,0,0,0,0,0,0,0,0,0,0,0,0")
        return

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

    samples = d.get("samples") or []
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

    print("%.2f,%.2f,%.2f,%.1f,%.1f,%.1f,%.1f,%.3f,%.2f,%.0f,%.1f,%d,%d" % (
        mean(arr), pct(arr, 0.5), pct(arr, 0.99),
        svc_mean, svc_p50, svc_p90, svc_p99, ipc, llc_mpki,
        freq_mhz, freq_util, len(active), total_req))


if __name__ == "__main__":
    main()
