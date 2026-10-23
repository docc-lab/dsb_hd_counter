#!/usr/bin/env python3
"""run_data_phases.py -- per-run p1 vs p2 latency shift straight from run_data.json.

For each stage3eval_* dir given (or found under the given sweep dirs), print
the median per-window p50/p90 of processing_time and total_time in p1
(0-20 s after started_epoch_ns) and p2 (25-80 s), the p2/p1 ratio, how much
of the run the capture covers, and the perf event set the victim sampled.

Use it to answer "does <section> react to this contention?" without the
scorer in the loop (the scorer's k/section only affect scores.csv; the
predictor's labels are computed offline from these same fields).

  python3 tools/run_data_phases.py data/sweep-none data/probe-*
  python3 tools/run_data_phases.py --p2 25:140 data/collect-*   # whole contention window
"""
import argparse
import datetime
import glob
import json
import re
import os
import statistics as st
import sys


def ts_epoch(s):
    # Go prints 1-9 fractional digits (trailing zeros dropped); fromisoformat
    # before 3.11 accepts exactly 3 or 6 -> normalise to 6.
    s = re.sub(r"\.(\d+)", lambda m: "." + (m.group(1) + "000000")[:6], s).replace("Z", "+00:00")
    return datetime.datetime.fromisoformat(s).timestamp()


def run_dirs(paths):
    for p in paths:
        if os.path.isfile(os.path.join(p, "input.yaml")):
            yield p
        else:
            yield from sorted(glob.glob(os.path.join(p, "stage3eval_*")))


def cfg_name(d):
    try:
        for line in open(os.path.join(d, "input.yaml")):
            if line.strip().startswith("name:"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return os.path.basename(d)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--p1", default="0:20", help="p1 window, seconds after t0 (lo:hi)")
    ap.add_argument("--p2", default="25:80", help="p2 window, seconds after t0 (lo:hi)")
    args = ap.parse_args()
    p1 = tuple(map(float, args.p1.split(":")))
    p2 = tuple(map(float, args.p2.split(":")))

    events = None
    for d in run_dirs(args.paths):
        run = os.path.join(d, "runs", "run_1")
        name = cfg_name(d)
        try:
            j = json.load(open(os.path.join(run, "run_data.json")))
            t0 = int(open(os.path.join(run, "started_epoch_ns.txt")).read()) / 1e9
            t1 = int(open(os.path.join(run, "ended_epoch_ns.txt")).read()) / 1e9
        except Exception as e:  # noqa: BLE001
            print(f"{name}: skipped ({e})")
            continue
        events = j.get("perf_events")
        rows = []
        for s in j["samples"]:
            tw = s.get("timing_window") or {}
            if not tw or tw.get("request_count", 0) == 0:
                continue
            rows.append((ts_epoch(s["timestamp"]) - t0, tw))
        last = max((r[0] for r in rows), default=-1)

        def agg(win, sec, key):
            v = [r[1][sec][key] for r in rows if win[0] <= r[0] < win[1] and r[1].get(sec)]
            return st.median(v) / 1e6 if v else float("nan")

        out = [f"{name:32s}", f"cov {last:4.0f}/{t1 - t0:3.0f}s"]
        for sec in ("processing_time", "total_time"):
            a50, b50 = agg(p1, sec, "p50_ns"), agg(p2, sec, "p50_ns")
            a90, b90 = agg(p1, sec, "p90_ns"), agg(p2, sec, "p90_ns")
            out.append(
                f"{sec[:4]} p50 {a50:6.3f}->{b50:6.3f} ms ({b50 / a50:4.2f}x)"
                f"  p90 {a90:6.3f}->{b90:6.3f} ({b90 / a90:4.2f}x)"
            )
        print(" | ".join(out))
    if events is not None:
        print("perf_events:", ",".join(events))
        need = {"LLC-loads", "LLC-load-misses", "dTLB-loads", "cycles", "ref-cycles", "instructions",
                "branch-instructions", "branch-misses", "dTLB-load-misses", "page-faults"}
        missing = sorted(need - set(events))
        if missing:
            print("MISSING predictor events:", ",".join(missing), file=sys.stderr)


if __name__ == "__main__":
    main()
