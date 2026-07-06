#!/usr/bin/env python3
"""Verify tests B and C1: warm-up (constant instr/req, falling cyc/req) and
own-core utilization (busy%%) per sweep level.

Slices the raw windowed samples by the [measure_start,measure_end] epochs in
saturation/levels.csv and prints, per level:
  instr/req   should be ~constant top to bottom (same code path at every rate)
  cyc/req     should fall with rate, mirroring the latency curve's left side
  ipc         should climb as arrivals densify (cache warmth)
  llc-mpki    LLC load misses per kilo-instruction; should fall with rate
  busy%%       cycles / (cores * mean_freq * wall_time); should stay << 100

Usage: python3 warmup_check.py <run_dir> [service] [cores]
  run_dir  experiment dir with saturation/levels.csv and raw/windowed/...
  service  defaults to "search"
  cores    pinned core count for busy%% (defaults to 3, i.e. CPUs 18-20)
"""
import csv
import json
import sys
from datetime import datetime


def to_epoch(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: warmup_check.py <run_dir> [service] [cores]")
    run_dir = sys.argv[1]
    service = sys.argv[2] if len(sys.argv) > 2 else "search"
    cores = int(sys.argv[3]) if len(sys.argv) > 3 else 3

    raw = f"{run_dir}/raw/windowed/{service}/run_data_full_raw.json"
    samples = json.load(open(raw))["samples"]
    for s in samples:
        s["_epoch"] = to_epoch(s["timestamp"])

    print(f"{len(samples)} windows from {raw}  (busy%% assumes {cores} cores)")
    print(f"{'rps':>6}  {'nwin':>5}  {'instr/req':>9}  {'cyc/req':>8}  "
          f"{'ipc':>5}  {'llc-mpki':>8}  {'busy%':>6}")

    for lv in csv.DictReader(open(f"{run_dir}/saturation/levels.csv")):
        s0, s1 = float(lv["measure_start"]), float(lv["measure_end"])
        active = [s for s in samples
                  if (s.get("timing_window", {}).get("request_count") or 0) > 0
                  and s0 <= s["_epoch"] <= s1]
        req = sum(s["timing_window"]["request_count"] for s in active)
        if not req:
            print(f"{lv['target_rps']:>6}  (no active windows)")
            continue

        def pd(key):
            return sum((s.get("perf_deltas") or {}).get(key, 0) for s in active)

        ins, cyc, llc = pd("instructions"), pd("cycles"), pd("LLC-load-misses")
        freqs = [s["freq"]["actual_freq_mhz"] for s in active
                 if s.get("freq", {}).get("ok")]
        # windows are 100ms each; cycles only tick while unhalted, so
        # busy = cycles / (cores * mean_freq * wall_time)
        tsec = len(active) * 0.1
        busy = (cyc / (cores * (sum(freqs) / len(freqs)) * 1e6 * tsec) * 100
                if freqs and tsec else float("nan"))

        print(f"{lv['target_rps']:>6}  {len(active):>5}  "
              f"{ins / req / 1000:>8.1f}k  {cyc / req / 1000:>7.1f}k  "
              f"{ins / cyc:>5.2f}  {llc / ins * 1000:>8.2f}  {busy:>6.1f}")

    print("\nPASS if instr/req is ~constant while cyc/req falls with rate "
          "(ipc climbs, llc-mpki falls), and busy%% stays far below 100 "
          "at every level.")


if __name__ == "__main__":
    main()
