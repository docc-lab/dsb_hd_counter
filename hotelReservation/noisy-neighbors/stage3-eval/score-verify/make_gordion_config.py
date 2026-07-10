#!/usr/bin/env python3
"""
make_gordion_config.py — generate the gordion.json calibration file for
the in-pod Gordion scorer from a stage-1 NO-STRESSOR baseline run.

Reads a windowed run_data JSON (the data-collector output for the
baseline run at the stage-3 operating point, e.g. search @ 2400 RPS with
no aggressors), computes the frequency-normalized (kcyc) per-window
p50/p90 streams over CLEAN windows, and emits the baseline block:

    p50_kcyc     = median of the window-p50 kcyc stream
    p90_kcyc     = median of the window-p90 kcyc stream
    sigma50_kcyc = stdev  of the window-p50 kcyc stream
    sigma90_kcyc = stdev  of the window-p90 kcyc stream
    freq_mhz     = median actual_freq_mhz over clean windows (fallback f)

kcyc = (p_ns / 1000) * actual_freq_mhz / 1000, each window normalized by
ITS OWN measured frequency — the same recipe curve_aggregate.py uses for
the svc_*_norm_kcyc curve columns, so the baseline and the curve live in
one domain.

A window is clean when it has completions and freq.ok.

Two input shapes are supported:

1. A dedicated no-stressor run (data-collector output): pass the
   run_data JSON alone; --skip-ms trims the warm-up head.
2. A stage-1 CURVE experiment (latency-rate-curve.sh output): one big
   run_data_full_raw.json spans ALL sweep levels, and
   <exp_dir>/saturation/levels.csv records each level's epoch window.
   Pass --levels-csv + --target-rps to slice out the single level
   closest to the operating point (e.g. 2400); mixing levels would
   corrupt the sigma estimates.

Usage:
  # dedicated baseline run:
  make_gordion_config.py <run_data.json> --curve-csv /etc/gordion-conf/curve.csv \
      [--skip-ms 30000] [--out gordion.json]
  # slice one level out of a curve experiment:
  make_gordion_config.py <exp_dir>/raw/windowed/<svc>/run_data_full_raw.json \
      --levels-csv <exp_dir>/saturation/levels.csv --target-rps 2400 \
      --curve-csv /etc/gordion-conf/curve.csv [--out gordion.json]

The emitted file goes into the per-service ConfigMap:
  kubectl create configmap gordion-search \
      --from-file=gordion.json --from-file=curve.csv
"""
import argparse
import csv as csvmod
import json
import re
import statistics as st
import sys
from datetime import datetime, timezone


def to_epoch(ts):
    """RFC3339 timestamp (possibly nanosecond precision, trailing Z)
    -> unix epoch seconds. Mirrors the stage-1 tooling's parsing."""
    s = str(ts).strip().replace("Z", "+00:00")
    # datetime.fromisoformat on older Pythons rejects >6 fractional digits.
    s = re.sub(r"\.(\d{6})\d+", r".\1", s)
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


def pick_level(levels_csv, target_rps):
    """Return (rps, epoch_start, epoch_end) of the levels.csv row whose
    target rps is closest to target_rps. Column layout matches
    curve_aggregate.py::build: level, rps, mstart, mend, ..."""
    best = None
    with open(levels_csv, newline="") as f:
        reader = csvmod.reader(f)
        next(reader, None)  # header
        for row in reader:
            if len(row) < 4 or not row[2] or not row[3]:
                continue
            try:
                rps, s_ep, e_ep = float(row[1]), float(row[2]), float(row[3])
            except ValueError:
                continue
            if best is None or abs(rps - target_rps) < abs(best[0] - target_rps):
                best = (rps, s_ep, e_ep)
    if best is None:
        sys.exit(f"{levels_csv}: no usable level rows (need rps + mstart + mend)")
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_data")
    ap.add_argument("--curve-csv", default="/etc/gordion-conf/curve.csv",
                    help="path the POD will see for the stage-1 curve (default %(default)s); "
                         "written into gordion.json verbatim, NOT read by this script")
    ap.add_argument("--section", default="processing_time",
                    choices=["processing_time", "total_time", "blocking_time"])
    ap.add_argument("--skip-ms", type=int, default=30000,
                    help="dedicated-run mode: drop windows with offset_ms below this")
    ap.add_argument("--levels-csv",
                    help="curve-experiment mode: <exp_dir>/saturation/levels.csv")
    ap.add_argument("--target-rps", type=float, default=2400.0,
                    help="curve-experiment mode: slice the level nearest this rps")
    ap.add_argument("--k", type=float, default=1.0)
    ap.add_argument("--window", type=int, default=30)
    ap.add_argument("--rate-signal", default="arrival_rps_3s",
                    choices=["arrival_rps_1s", "arrival_rps_3s"])
    ap.add_argument("--slo-p90-ms", type=float, default=0.0)
    ap.add_argument("--version", default="gordion-v1")
    ap.add_argument("--out", default="gordion.json")
    args = ap.parse_args()

    data = json.load(open(args.run_data))
    samples = data.get("samples") or []
    if not samples:
        sys.exit(f"{args.run_data}: no samples")

    level_note = None
    if args.levels_csv:
        rps, s_ep, e_ep = pick_level(args.levels_csv, args.target_rps)
        before = len(samples)
        samples = [s for s in samples if s_ep <= to_epoch(s["timestamp"]) <= e_ep]
        level_note = {"level_rps": rps, "epoch_start": s_ep, "epoch_end": e_ep,
                      "sliced": len(samples), "of": before}
        print(f"sliced level rps={rps:g}: {len(samples)}/{before} samples "
              f"in [{s_ep:.0f}, {e_ep:.0f}]")

    t50s, t90s, freqs = [], [], []
    skipped_warmup = skipped_dirty = 0
    for s in samples:
        # offset-based warm-up trim only applies to dedicated runs; a
        # levels.csv slice already bounds the measurement window.
        if not args.levels_csv and (s.get("offset_ms") or 0) < args.skip_ms:
            skipped_warmup += 1
            continue
        tw = s.get("timing_window") or {}
        sec = tw.get(args.section) or {}
        fq = s.get("freq") or {}
        if not fq.get("ok") or not sec.get("count"):
            skipped_dirty += 1
            continue
        f = fq.get("actual_freq_mhz") or 0.0
        if f <= 0:
            skipped_dirty += 1
            continue
        t50s.append((sec.get("p50_ns") or 0) / 1000.0 * f / 1000.0)
        t90s.append((sec.get("p90_ns") or 0) / 1000.0 * f / 1000.0)
        freqs.append(f)

    if len(t50s) < 30:
        sys.exit(f"only {len(t50s)} clean windows (need >=30 for stable sigma); "
                 f"warmup-skipped={skipped_warmup} dirty={skipped_dirty}")

    cfg = {
        "version": args.version,
        "k": args.k,
        "smooth_window": args.window,
        "latency_section": args.section,
        "baseline": {
            "p50_kcyc": round(st.median(t50s), 3),
            "p90_kcyc": round(st.median(t90s), 3),
            "sigma50_kcyc": round(st.stdev(t50s), 3),
            "sigma90_kcyc": round(st.stdev(t90s), 3),
            "freq_mhz": round(st.median(freqs), 1),
        },
        "curve_csv": args.curve_csv,
        "curve_columns": {
            "rate": "target_rps",
            "p50": "svc_p50_norm_kcyc",
            "p90": "svc_p90_norm_kcyc",
        },
        "rate_signal": args.rate_signal,
        "failure": {"slo_p90_ms": args.slo_p90_ms, "stall_windows": 5},
        "ablations": {"no_smoothing": False, "no_ext": False,
                      "raw_rate_index": False, "use_current_y50": False},
        "_provenance": {
            "source_run": args.run_data,
            "level": level_note,
            "clean_windows": len(t50s),
            "skipped_warmup": skipped_warmup,
            "skipped_dirty": skipped_dirty,
            "service": data.get("service_name"),
        },
    }
    with open(args.out, "w") as f:
        json.dump(cfg, f, indent=2)
    b = cfg["baseline"]
    print(f"wrote {args.out}: p50={b['p50_kcyc']} p90={b['p90_kcyc']} kcyc, "
          f"sigma50={b['sigma50_kcyc']} sigma90={b['sigma90_kcyc']}, "
          f"f_b={b['freq_mhz']} MHz over {len(t50s)} clean windows")


if __name__ == "__main__":
    main()
