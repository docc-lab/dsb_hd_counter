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

A window is clean when it has completions and freq.ok. Optionally trim
the first --skip-ms of the run (warm-up).

Usage:
  make_gordion_config.py <run_data.json> --curve-csv /etc/gordion-conf/curve.csv \
      [--section processing_time] [--skip-ms 30000] [--k 1.0] [--window 30] \
      [--version gordion-v1] [--out gordion.json]

The emitted file goes into the per-service ConfigMap:
  kubectl create configmap gordion-search \
      --from-file=gordion.json --from-file=curve.csv
"""
import argparse
import json
import statistics as st
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_data")
    ap.add_argument("--curve-csv", default="/etc/gordion-conf/curve.csv",
                    help="path the POD will see for the stage-1 curve (default %(default)s)")
    ap.add_argument("--section", default="processing_time",
                    choices=["processing_time", "total_time", "blocking_time"])
    ap.add_argument("--skip-ms", type=int, default=30000,
                    help="drop windows with offset_ms below this (warm-up trim)")
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

    t50s, t90s, freqs = [], [], []
    skipped_warmup = skipped_dirty = 0
    for s in samples:
        if (s.get("offset_ms") or 0) < args.skip_ms:
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
