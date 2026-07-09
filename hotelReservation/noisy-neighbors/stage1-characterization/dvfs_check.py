#!/usr/bin/env python3
"""Verify test A (observational): raw latency tracks 1/freq, cycles do not.

Buckets per-window samples by measured core frequency and prints, per bucket,
the mean raw p50 processing time (us) and the same value converted to
kilocycles (us * MHz / 1000). DVFS is the cause of the left-side latency fall
iff raw us drops across buckets while kcyc stays ~flat within a rate regime.

Usage: python3 dvfs_check.py <run_dir> [service]
  run_dir  experiment dir containing raw/windowed/<service>/run_data_full_raw.json
  service  defaults to "search"
"""
import json
import sys
from collections import defaultdict


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: dvfs_check.py <run_dir> [service]")
    run_dir = sys.argv[1]
    service = sys.argv[2] if len(sys.argv) > 2 else "search"

    path = f"{run_dir}/raw/windowed/{service}/run_data_full_raw.json"
    samples = json.load(open(path))["samples"]

    pts = []
    for s in samples:
        if not s.get("freq", {}).get("ok"):
            continue
        tw = s.get("timing_window") or {}
        if (tw.get("request_count") or 0) <= 5:
            continue
        p50_ns = (tw.get("processing_time") or {}).get("p50_ns")
        if not p50_ns:
            continue
        pts.append((s["freq"]["actual_freq_mhz"], p50_ns / 1000.0))

    if not pts:
        sys.exit(f"no usable windows in {path}")

    buckets = defaultdict(list)
    for f_mhz, us in pts:
        buckets[round(f_mhz / 200) * 200].append((us, us * f_mhz / 1000.0))

    print(f"{len(pts)} windows from {path}")
    print(f"{'freq_bucket':>11}  {'n':>5}  {'raw_p50_us':>10}  {'kcyc':>7}")
    for f in sorted(buckets):
        vals = buckets[f]
        us = sum(x for x, _ in vals) / len(vals)
        kc = sum(k for _, k in vals) / len(vals)
        print(f"{f:>8}MHz  {len(vals):>5}  {us:>10.1f}  {kc:>7.1f}")

    print("\nPASS if raw_p50_us falls ~1/freq down the table while kcyc stays "
          "roughly flat within a rate regime.")


if __name__ == "__main__":
    main()
