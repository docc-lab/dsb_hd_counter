#!/usr/bin/env python3
"""
calibrate_from_stream.py — build the Gordion intrinsic curve (curve.csv)
and baseline config (gordion.json) from InstrumentationStream captures,
so the calibration is measured under EXACTLY the workload the eval runs
(fixing the stage-1-loadgen vs mixed-lua domain mismatch).

Procedure: for each rate level, run the victim with NO aggressors at that
loadgen rate while recording :7901 (record_samples.sh) to a file, then:

  ./calibrate_from_stream.py \
      --level 300:rate_300.ndjson --level 600:rate_600.ndjson \
      --level 1200:rate_1200.ndjson --level 1800:rate_1800.ndjson \
      --level 2400:rate_2400.ndjson --level 3000:rate_3000.ndjson \
      --operating-rps 2400 \
      --out-curve curve.csv --out-config gordion.json

Note: level rates are the LOADGEN (e2e) rates; the curve's rate axis is
the victim's OWN observed arrival rate (mean arrival_rps_1s per level),
which is what the scorer's rate signal indexes at runtime. The loadgen
rate is recorded per row as target_rps for provenance.

Latency domain matches curve_aggregate.py: per-window kcyc = (p_ns /
1000) * actual_freq_mhz / 1000, each window normalized by its own
measured frequency; request-weighted mean across clean windows
(freq.ok, completions > 0), first --trim-s seconds dropped.
"""
import argparse
import json
import statistics as st
import sys


def fget(d, *names, default=None):
    for n in names:
        if n in d:
            return d[n]
    return default


def load_level(path, section, trim_s):
    """Returns (arrival_mean, rows) where rows = list of
    (kcyc50, kcyc90, weight) over clean windows."""
    sec_camel = {
        "processing_time": "processingTime",
        "total_time": "totalTime",
        "blocking_time": "blockingTime",
    }[section]

    windows, t0, tlast = [], None, None
    for lineno, line in enumerate(open(path), 1):
        line = line.strip()
        if not line:
            continue
        try:
            s = json.loads(line)
        except json.JSONDecodeError:
            print(f"WARN: {path}:{lineno}: bad JSON, skipped", file=sys.stderr)
            continue
        ts = int(fget(s, "timestampNs", "timestamp_ns", default=0))
        if t0 is None:
            t0 = ts
        tlast = ts
        if ts - t0 < trim_s * 1e9:
            continue
        tw = fget(s, "timingWindow", "timing_window", default=None) or {}
        sec = fget(tw, sec_camel, section, default=None) or {}
        fq = s.get("freq") or {}
        f = float(fget(fq, "actualFreqMhz", "actual_freq_mhz", default=0) or 0)
        ok = bool(fget(fq, "ok", default=False))
        count = int(fget(sec, "count", default=0) or 0)
        p50 = int(fget(sec, "p50Ns", "p50_ns", default=0) or 0)
        p90 = int(fget(sec, "p90Ns", "p90_ns", default=0) or 0)
        arr = float(fget(tw, "arrivalRps1s", "arrival_rps_1s", default=0) or 0)
        if not ok or f <= 0 or count <= 0 or p50 <= 0:
            continue
        windows.append((p50 / 1000.0 * f / 1000.0,   # kcyc50
                        p90 / 1000.0 * f / 1000.0,   # kcyc90
                        count, arr, f))

    if len(windows) < 30:
        sys.exit(f"{path}: only {len(windows)} clean windows after trim (need >= 30)")
    span_s = (tlast - t0) / 1e9 if t0 is not None else 0
    if span_s > 300:
        sys.exit(f"{path}: capture spans {span_s:.0f}s -- far longer than one recording. "
                 f"This is the orphaned-recorder contamination signature (multiple levels "
                 f"blended into one file); re-record this level with the fixed "
                 f"record_samples.sh and try again.")
    arrival_mean = sum(w[3] for w in windows) / len(windows)
    return arrival_mean, windows


def wmean(pairs):
    num = sum(v * w for v, w in pairs)
    den = sum(w for _, w in pairs)
    return num / den if den else 0.0


def smooth_stream(xs, w):
    """Replay the identical causal Gaussian smoother the Go scorer uses
    (sigma = w/3, partial-kernel renormalization during warm-up)."""
    import math
    if w < 2:
        return list(xs)
    s = w / 3.0
    weights = [math.exp(-(a * a) / (2 * s * s)) for a in range(w)]
    out, buf = [], []
    for x in xs:
        buf.append(x)
        if len(buf) > w:
            buf.pop(0)
        num = den = 0.0
        for age, v in enumerate(reversed(buf)):
            num += weights[age] * v
            den += weights[age]
        out.append(num / den)
    return out


def sigma(xs):
    """Robust spread: MAD x 1.4826 (normal-consistent), stdev fallback."""
    med = st.median(xs)
    mad = st.median([abs(x - med) for x in xs])
    return 1.4826 * mad if mad > 0 else st.stdev(xs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--level", action="append", required=True,
                    metavar="LOADGEN_RPS:NDJSON",
                    help="repeatable; one no-aggressor capture per rate")
    ap.add_argument("--section", default="processing_time",
                    choices=["processing_time", "total_time", "blocking_time"])
    ap.add_argument("--trim-s", type=float, default=15.0)
    ap.add_argument("--operating-rps", type=float, default=2400.0,
                    help="loadgen rate whose capture provides the baseline stats")
    ap.add_argument("--baseline", metavar="NDJSON",
                    help="dedicated capture for the baseline stats (e.g. recorded "
                         "during a harness baseline run, so pod-restart/cache "
                         "conditions match the eval); the curve still comes from "
                         "the --level sweep. Default: the level nearest "
                         "--operating-rps provides the baseline.")
    ap.add_argument("--k", type=float, default=1.0)
    ap.add_argument("--window", type=int, default=30)
    ap.add_argument("--rate-signal", default="arrival_rps_3s",
                    choices=["arrival_rps_1s", "arrival_rps_3s"])
    ap.add_argument("--curve-csv-pod-path", default="/etc/gordion-conf/curve.csv",
                    help="path written INTO gordion.json (where the pod sees the curve)")
    ap.add_argument("--version", default="gordion-v2-streamcal")
    ap.add_argument("--out-curve", default="curve.csv")
    ap.add_argument("--out-config", default="gordion.json")
    args = ap.parse_args()

    levels = []
    for spec in args.level:
        try:
            rps_s, path = spec.split(":", 1)
            loadgen_rps = float(rps_s)
        except ValueError:
            sys.exit(f"bad --level {spec!r}: want LOADGEN_RPS:NDJSON")
        arrival, windows = load_level(path, args.section, args.trim_s)
        # Curve values live in the SAME domain the scorer compares them
        # against: the runtime ext term is (T~ - D)/T~ where T~ is the
        # Gaussian-smoothed stream, so D must be the typical value of
        # that smoothed stream at this rate -- median of the replayed
        # smoothed signal. (A request-weighted MEAN is dominated by rare
        # straggler windows on the skewed p90 stream: it measured ~6x
        # the typical smoothed level, leaving ext90 clamped at 0 until
        # the tail exceeded 6x intrinsic.)
        d50 = st.median(smooth_stream([w[0] for w in windows], args.window))
        d90 = st.median(smooth_stream([w[1] for w in windows], args.window))
        wm50 = wmean([(w[0], w[2]) for w in windows])
        wm90 = wmean([(w[1], w[2]) for w in windows])
        levels.append(dict(loadgen=loadgen_rps, arrival=arrival,
                           d50=d50, d90=d90, wm50=wm50, wm90=wm90,
                           n=len(windows), windows=windows))
        print(f"level loadgen={loadgen_rps:g}: arrival_mean={arrival:.0f} "
              f"d50={d50:.1f} d90={d90:.1f} kcyc (smoothed-median; "
              f"wmean {wm50:.0f}/{wm90:.0f}) over {len(windows)} windows")

    # Curve rows keyed by the victim's OWN arrival rate (what the scorer
    # indexes with); loadgen rate kept as provenance in target_rps... no:
    # the Go reader's default rate column IS target_rps, so put the
    # arrival rate THERE (it must be in the runtime signal's domain) and
    # keep the loadgen rate in its own column.
    levels.sort(key=lambda l: l["arrival"])
    with open(args.out_curve, "w") as f:
        f.write("target_rps,loadgen_rps,arrival_rps_mean,svc_p50_norm_kcyc,svc_p90_norm_kcyc,n_windows\n")
        for l in levels:
            f.write(f"{l['arrival']:.1f},{l['loadgen']:g},{l['arrival']:.1f},"
                    f"{l['d50']:.3f},{l['d90']:.3f},{l['n']}\n")
    print(f"wrote {args.out_curve} ({len(levels)} levels)")

    # Baseline from the operating-rate capture -- computed in the SAME
    # domain the scorer operates in. The runtime tanh compares the
    # baseline against the causally Gaussian-SMOOTHED per-window stream,
    # and smoothing is averaging: for the heavily right-skewed window-p90
    # stream (occasional millisecond straggler windows), the smoothed
    # signal sits near the MEAN, far above the raw median. A raw-median
    # baseline therefore pins y90 at 1 on a perfectly healthy system.
    # Fix: replay the captured stream through the identical smoother and
    # take median + MAD of the SMOOTHED values (smooth_stream / sigma at
    # module level; the curve's D values use the same domain).
    if args.baseline:
        _, base_windows = load_level(args.baseline, args.section, args.trim_s)
        base_src = args.baseline
    else:
        op = min(levels, key=lambda l: abs(l["loadgen"] - args.operating_rps))
        base_windows = op["windows"]
        base_src = f"level loadgen={op['loadgen']:g}"
    k50 = smooth_stream([w[0] for w in base_windows], args.window)
    k90 = smooth_stream([w[1] for w in base_windows], args.window)
    freqs = [w[4] for w in base_windows]
    cfg = {
        "version": args.version,
        "k": args.k,
        "smooth_window": args.window,
        "latency_section": args.section,
        "baseline": {
            "p50_kcyc": round(st.median(k50), 3),
            "p90_kcyc": round(st.median(k90), 3),
            "sigma50_kcyc": round(sigma(k50), 3),
            "sigma90_kcyc": round(sigma(k90), 3),
            "freq_mhz": round(st.median(freqs), 1),
        },
        "curve_csv": args.curve_csv_pod_path,
        "curve_columns": {"rate": "target_rps", "p50": "svc_p50_norm_kcyc",
                          "p90": "svc_p90_norm_kcyc"},
        "rate_signal": args.rate_signal,
        "failure": {"slo_p90_ms": 0, "stall_windows": 5},
        "ablations": {"no_smoothing": False, "no_ext": False,
                      "raw_rate_index": False, "use_current_y50": False},
        "_provenance": {
            "method": "calibrate_from_stream (baseline stats over the smoothed stream)",
            "raw_window_medians": {
                "p50_kcyc": round(st.median([w[0] for w in base_windows]), 1),
                "p90_kcyc": round(st.median([w[1] for w in base_windows]), 1),
            },
            "levels": [{"loadgen": l["loadgen"], "arrival": round(l["arrival"], 1),
                        "d50": round(l["d50"], 1), "d90": round(l["d90"], 1),
                        "wmean_d50": round(l["wm50"], 1), "wmean_d90": round(l["wm90"], 1),
                        "n_windows": l["n"]} for l in levels],
            "baseline_source": base_src,
        },
    }
    with open(args.out_config, "w") as f:
        json.dump(cfg, f, indent=2)
    b = cfg["baseline"]
    print(f"wrote {args.out_config}: baseline p50={b['p50_kcyc']} p90={b['p90_kcyc']} kcyc, "
          f"sigma50={b['sigma50_kcyc']} sigma90={b['sigma90_kcyc']}, f={b['freq_mhz']} MHz "
          f"(baseline from {base_src}, {len(base_windows)} windows)")


if __name__ == "__main__":
    main()
