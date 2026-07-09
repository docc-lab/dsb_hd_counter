#!/usr/bin/env python3
"""
Robust intrinsic latency-vs-arrival-rate analysis for a Stage-1 curve run.

Why this exists
---------------
The in-pod windowed sampler occasionally stalls the service (~hundreds of ms),
which shows up as `context canceled` errors AND inflates the interceptor
service-time in the small fraction of 100ms windows where a stall lands. The
default aggregation (curve_aggregate.py -> curve.csv) uses a request-weighted
MEAN across all active windows, so those few poisoned windows leak into the
curve. This tool instead REJECTS the contaminated windows and reports how many
there were, giving the intrinsic (unperturbed) service-time vs arrival rate.

Y-axis = interceptor processing_time (instrumentation), NOT ghz e2e latency.

Method (per level / arrival-rate bin)
-------------------------------------
Active windows = timing_window.request_count > 0 and timestamp in [start,end].
A window is flagged CONTAMINATED if its p99 service time exceeds
    median(window p99) + K * 1.4826 * MAD(window p99)          (default K=5)
i.e. a robust outlier vs the level's own windows. From the CLEAN windows:
    arrival_rps  = median of window arrival_rps_1s
    svc_p50_us   = median across windows of window p50   (robust central svc time)
    svc_p90_us   = median across windows of window p90   (robust tail proxy)
    svc_p99_us   = median across windows of window p99
Also prints the RAW request-weighted-mean p50 (what curve.csv uses) and the
contaminated-window count/fraction so you can see exactly how much noise was
removed. Percentiles are per-window stats (no pooled raw durations exist), so
p90/p99 are tail proxies, not globally-pooled percentiles.

Usage:  curve_stats.py <exp_dir> [--k 5] [--csv out.csv]
"""
import csv, glob, json, os, re, sys, statistics as st


def to_epoch(ts):
    if not ts:
        return None
    s = ts.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    s = re.sub(r"(\.\d{6})\d+", r"\1", s)
    try:
        from datetime import datetime
        return datetime.fromisoformat(s).timestamp()
    except Exception:
        return None


def med(xs):
    return st.median(xs) if xs else 0.0


def mad(xs):
    if not xs:
        return 0.0
    m = st.median(xs)
    return st.median([abs(x - m) for x in xs])


def window(s):
    tw = s.get("timing_window") or {}
    pt = tw.get("processing_time") or {}
    return {
        "arr": tw.get("arrival_rps_1s") or 0.0,
        "rc": tw.get("request_count") or 0,
        "cnt": pt.get("count") or 0,
        "mean": (pt.get("mean_ns") or 0) / 1000.0,
        "p50": (pt.get("p50_ns") or 0) / 1000.0,
        "p90": (pt.get("p90_ns") or 0) / 1000.0,
        "p99": (pt.get("p99_ns") or 0) / 1000.0,
        "ts": to_epoch(s.get("timestamp")),
    }


def main():
    args = [a for a in sys.argv[1:]]
    K = 5.0
    csv_out = None
    if "--k" in args:
        i = args.index("--k"); K = float(args[i + 1]); del args[i:i + 2]
    if "--csv" in args:
        i = args.index("--csv"); csv_out = args[i + 1]; del args[i:i + 2]
    if not args:
        sys.exit("usage: curve_stats.py <exp_dir> [--k 5] [--csv out.csv]")
    exp = args[0]

    raws = glob.glob(os.path.join(exp, "raw", "windowed", "*", "run_data_full_raw.json"))
    if not raws:
        raws = glob.glob(os.path.join(exp, "raw", "windowed", "*", "run_data_iter*_raw.json"))
    if not raws:
        sys.exit("no run_data under %s/raw/windowed/*/" % exp)
    samples = (json.load(open(raws[0])).get("samples")) or []
    levels = list(csv.DictReader(open(os.path.join(exp, "saturation", "levels.csv"))))

    W = [window(s) for s in samples]
    W = [w for w in W if w["rc"] > 0 and w["ts"] is not None]

    hdr = ("target  arr_rps  svc_p50  svc_p90  svc_p99   raw_p50  windows  bad  bad%")
    print(hdr); print("-" * len(hdr))
    rows = []
    for lv in levels:
        try:
            s0 = float(lv["measure_start"]); s1 = float(lv["measure_end"])
        except Exception:
            continue
        if s1 - s0 < 5:        # skip aborted/1s levels
            continue
        wl = [w for w in W if s0 <= w["ts"] <= s1]
        if not wl:
            continue
        p99s = [w["p99"] for w in wl]
        thr = med(p99s) + K * 1.4826 * mad(p99s)
        clean = [w for w in wl if w["p99"] <= thr] or wl
        bad = len(wl) - len(clean)
        arr = med([w["arr"] for w in clean])
        p50 = med([w["p50"] for w in clean])
        p90 = med([w["p90"] for w in clean])
        p99 = med([w["p99"] for w in clean])
        num = sum(w["p50"] * w["cnt"] for w in wl); den = sum(w["cnt"] for w in wl)
        raw_p50 = num / den if den else 0.0
        badpct = 100.0 * bad / len(wl)
        print("%-6s  %7.1f  %7.1f  %7.1f  %7.1f   %7.1f  %7d  %3d  %4.1f"
              % (lv["target_rps"], arr, p50, p90, p99, raw_p50, len(wl), bad, badpct))
        rows.append([lv["target_rps"], "%.1f" % arr, "%.1f" % p50, "%.1f" % p90,
                     "%.1f" % p99, "%.1f" % raw_p50, len(wl), bad, "%.1f" % badpct])

    if csv_out:
        with open(csv_out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["target_rps", "arrival_rps", "svc_p50_us", "svc_p90_us",
                        "svc_p99_us", "raw_mean_p50_us", "windows", "bad_windows", "bad_pct"])
            w.writerows(rows)
        print("\nwrote %s" % csv_out)


if __name__ == "__main__":
    main()
