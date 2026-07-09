#!/usr/bin/env python3
"""
verify_score_tracking.py — check that the published score stream tracks
contention up AND down across a phased aggressor schedule.

Inputs:
  --scores scores.ndjson   from record_scores.sh (one ScoreEvent JSON/line)
  --phases phases.yaml     phase schedule (see below)
  [--plot timeline.png]    optional score timeline with phase shading
  [--trim-s 15]            seconds trimmed from each phase start before
                           computing steady-state stats (score rise/decay
                           transitions belong to the boundary, not the phase)

phases.yaml (YAML or JSON; only `start` is required — a phase ends where
the next begins, the last at `end` or the final event):

    phases:
      - {name: baseline,      start: "2026-07-09T18:00:00Z", rank: 0}
      - {name: moderate-up,   start: "2026-07-09T18:03:00Z", rank: 1}
      - {name: severe,        start: "2026-07-09T18:06:00Z", rank: 2}
      - {name: moderate-down, start: "2026-07-09T18:09:00Z", rank: 1}
      - {name: off,           start: "2026-07-09T18:12:00Z", rank: 0}
    end: "2026-07-09T18:15:00Z"

`rank` encodes expected contention ordering: phase means of y50/y90 must
increase with rank (checked over every rank pair). Timestamps may also
be raw unix seconds.

Checks (each PASS/FAIL, non-zero exit if any FAIL):
  1. monotonicity  — mean y50 & y90 ordered by rank (up AND down legs).
  2. decay         — in the final rank-0 phase the score returns below
                     0.1 within the phase.
  3. extrinsic     — mean ext_pct_50/90 in aggressor phases (rank > 0)
                     exceeds their mean in rank-0 phases (victim load is
                     constant, so degradation must attribute extrinsic).
  4. stream health — no event gap > 10x the median inter-event interval.
  5. prediction    — when prediction_on events exist: Pearson r between
                     y-hat50 (p50_trend_pred) and y50_current, plus the
                     lag (in windows) maximizing cross-correlation
                     (negative lag = the model LEADS the formula).
"""
import argparse
import json
import math
import sys
from datetime import datetime, timezone


# ── input parsing ─────────────────────────────────────────────────────

def parse_ts(v):
    """ISO8601 string or unix seconds -> unix seconds (float)."""
    if isinstance(v, (int, float)):
        return float(v)
    s = str(v).strip().replace("Z", "+00:00")
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


def load_phases(path):
    text = open(path).read()
    try:
        import yaml  # type: ignore
        doc = yaml.safe_load(text)
    except ImportError:
        doc = json.loads(text)
    phases = doc["phases"]
    for p in phases:
        p["start_s"] = parse_ts(p["start"])
    phases.sort(key=lambda p: p["start_s"])
    for i, p in enumerate(phases):
        p["end_s"] = phases[i + 1]["start_s"] if i + 1 < len(phases) else (
            parse_ts(doc["end"]) if "end" in doc else None)
    return phases


def fget(ev, *names, default=0.0):
    """Field access across proto3-JSON camelCase (grpcurl) and
    snake_case; proto3 JSON omits zero-valued fields, hence default."""
    for n in names:
        if n in ev:
            return ev[n]
    return default


def load_events(path):
    events = []
    for lineno, line in enumerate(open(path), 1):
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            print(f"WARN: {path}:{lineno}: bad JSON, skipped", file=sys.stderr)
            continue
        # int64 arrives as a string in proto3 JSON.
        ts_ns = int(fget(ev, "timestampNs", "timestamp_ns", default=0))
        events.append({
            "t": ts_ns / 1e9,
            "p50_pred": float(fget(ev, "p50TrendPred", "p50_trend_pred")),
            "y90": float(fget(ev, "tailTrendLabel", "tail_trend_label")),
            "y50": float(fget(ev, "y50Current", "y50_current")),
            "ext50": float(fget(ev, "extPct50", "ext_pct_50")),
            "ext90": float(fget(ev, "extPct90", "ext_pct_90")),
            "pred_on": bool(fget(ev, "predictionOn", "prediction_on", default=False)),
        })
    events.sort(key=lambda e: e["t"])
    return events


# ── stats helpers ─────────────────────────────────────────────────────

def mean(xs):
    return sum(xs) / len(xs) if xs else float("nan")


def pearson(xs, ys):
    n = len(xs)
    if n < 3:
        return float("nan")
    mx, my = mean(xs), mean(ys)
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    dx = math.sqrt(sum((x - mx) ** 2 for x in xs))
    dy = math.sqrt(sum((y - my) ** 2 for y in ys))
    return num / (dx * dy) if dx > 0 and dy > 0 else float("nan")


def best_lag(pred, cur, max_lag=30):
    """Lag (in samples) maximizing corr(pred[t], cur[t+lag]).
    Positive best lag = the prediction correlates best with the FUTURE
    current score, i.e. the model leads the formula."""
    best = (0, -2.0)
    for lag in range(-max_lag, max_lag + 1):
        if lag >= 0:
            a, b = pred[:len(pred) - lag or None], cur[lag:]
        else:
            a, b = pred[-lag:], cur[:len(cur) + lag]
        if len(a) < 10:
            continue
        r = pearson(a, b)
        if not math.isnan(r) and r > best[1]:
            best = (lag, r)
    return best


# ── main ──────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scores", required=True)
    ap.add_argument("--phases", required=True)
    ap.add_argument("--plot")
    ap.add_argument("--trim-s", type=float, default=15.0)
    ap.add_argument("--decay-threshold", type=float, default=0.1)
    args = ap.parse_args()

    events = load_events(args.scores)
    phases = load_phases(args.phases)
    if not events:
        sys.exit("no events in " + args.scores)

    # Assign events to phases (steady-state slice: trimmed head).
    for p in phases:
        end = p["end_s"] if p["end_s"] is not None else events[-1]["t"] + 1
        p["events"] = [e for e in events if p["start_s"] <= e["t"] < end]
        p["steady"] = [e for e in p["events"] if e["t"] >= p["start_s"] + args.trim_s]

    print(f"{len(events)} events across {len(phases)} phases "
          f"({events[0]['t']:.0f} .. {events[-1]['t']:.0f} unix)")
    print(f"\n{'phase':<15} {'n':>5} {'y50':>7} {'y90':>7} {'p50pred':>8} "
          f"{'ext50':>7} {'ext90':>7} {'pred_on%':>8}")
    for p in phases:
        s = p["steady"]
        if not s:
            print(f"{p['name']:<15} {'0':>5}  (no steady-state events!)")
            continue
        print(f"{p['name']:<15} {len(s):>5} "
              f"{mean([e['y50'] for e in s]):>7.3f} "
              f"{mean([e['y90'] for e in s]):>7.3f} "
              f"{mean([e['p50_pred'] for e in s]):>8.3f} "
              f"{mean([e['ext50'] for e in s]):>7.3f} "
              f"{mean([e['ext90'] for e in s]):>7.3f} "
              f"{100.0 * mean([1.0 if e['pred_on'] else 0.0 for e in s]):>7.1f}%")

    failures = []

    # 1. monotonicity by rank, over every adjacent-in-time phase pair
    #    with differing ranks (covers the up leg AND the down leg).
    ranked = [p for p in phases if "rank" in p and p["steady"]]
    for a, b in zip(ranked, ranked[1:]):
        ya, yb = mean([e["y50"] for e in a["steady"]]), mean([e["y50"] for e in b["steady"]])
        za, zb = mean([e["y90"] for e in a["steady"]]), mean([e["y90"] for e in b["steady"]])
        for label, va, vb in (("y50", ya, yb), ("y90", za, zb)):
            if a["rank"] < b["rank"] and not vb > va:
                failures.append(f"monotonicity: {label} {a['name']}({va:.3f}) !< {b['name']}({vb:.3f})")
            if a["rank"] > b["rank"] and not vb < va:
                failures.append(f"monotonicity: {label} {a['name']}({va:.3f}) !> {b['name']}({vb:.3f})")
    print("\n[1] monotonicity:", "FAIL" if any("monotonicity" in f for f in failures) else "PASS")

    # 2. decay in the final rank-0 phase.
    tail0 = [p for p in ranked if p["rank"] == 0]
    if tail0:
        last = tail0[-1]
        recovered = [e for e in last["events"] if e["y50"] < args.decay_threshold]
        if recovered:
            dt = recovered[0]["t"] - last["start_s"]
            print(f"[2] decay: PASS (y50 < {args.decay_threshold} after {dt:.1f}s of '{last['name']}')")
        else:
            failures.append(f"decay: y50 never dropped below {args.decay_threshold} in '{last['name']}'")
            print("[2] decay: FAIL")

    # 3. extrinsic attribution: aggressor phases vs rank-0 phases.
    agg = [e for p in ranked if p["rank"] > 0 for e in p["steady"]]
    base = [e for p in ranked if p["rank"] == 0 for e in p["steady"]]
    if agg and base:
        for label in ("ext50", "ext90"):
            ma, mb = mean([e[label] for e in agg]), mean([e[label] for e in base])
            ok = ma > mb
            print(f"[3] extrinsic {label}: {'PASS' if ok else 'FAIL'} "
                  f"(aggressor {ma:.3f} vs baseline {mb:.3f})")
            if not ok:
                failures.append(f"extrinsic: {label} aggressor mean {ma:.3f} <= baseline {mb:.3f}")

    # 4. stream health.
    gaps = [b["t"] - a["t"] for a, b in zip(events, events[1:])]
    gaps_sorted = sorted(gaps)
    med = gaps_sorted[len(gaps_sorted) // 2] if gaps_sorted else 0
    worst = max(gaps) if gaps else 0
    ok = med > 0 and worst <= 10 * med
    print(f"[4] stream health: {'PASS' if ok else 'FAIL'} "
          f"(median interval {med * 1000:.0f} ms, worst gap {worst:.2f} s)")
    if not ok:
        failures.append(f"stream: worst gap {worst:.2f}s > 10x median {med:.3f}s")

    # 5. prediction vs formula (only when a model was attached).
    pred_events = [e for e in events if e["pred_on"]]
    if pred_events:
        pred = [e["p50_pred"] for e in pred_events]
        cur = [e["y50"] for e in pred_events]
        r = pearson(pred, cur)
        lag, rlag = best_lag(pred, cur)
        print(f"[5] prediction: r(y-hat50, y50)={r:.3f}; "
              f"best lag {lag:+d} windows (r={rlag:.3f}) "
              f"[positive lag = model leads]")
        if not math.isnan(r) and r < 0.3:
            failures.append(f"prediction: correlation with formula suspiciously low (r={r:.3f})")
    else:
        print("[5] prediction: no prediction_on events (prediction-OFF run)")

    if args.plot:
        plot(events, phases, args.plot)
        print(f"plot -> {args.plot}")

    if failures:
        print("\nFAILURES:")
        for f in failures:
            print("  -", f)
        sys.exit(1)
    print("\nALL CHECKS PASSED")


def plot(events, phases, out):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    t0 = events[0]["t"]
    ts = [(e["t"] - t0) / 60.0 for e in events]
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 7), sharex=True,
                                   gridspec_kw={"height_ratios": [2, 1]})
    ax1.plot(ts, [e["y50"] for e in events], lw=0.9, label="y50 (formula)")
    ax1.plot(ts, [e["y90"] for e in events], lw=0.9, label="y90 (formula)")
    if any(e["pred_on"] for e in events):
        ax1.plot(ts, [e["p50_pred"] if e["pred_on"] else float("nan") for e in events],
                 lw=0.9, ls="--", label="y-hat50 (model)")
    ax1.set_ylabel("contention score")
    ax1.set_ylim(-0.05, 1.05)
    ax1.legend(loc="upper left", fontsize=8)

    ax2.plot(ts, [e["ext50"] for e in events], lw=0.9, label="%ext,50")
    ax2.plot(ts, [e["ext90"] for e in events], lw=0.9, label="%ext,90")
    ax2.set_ylabel("extrinsic share")
    ax2.set_xlabel("minutes")
    ax2.set_ylim(-0.05, 1.05)
    ax2.legend(loc="upper left", fontsize=8)

    maxrank = max((p.get("rank", 0) for p in phases), default=1) or 1
    for p in phases:
        x0 = (p["start_s"] - t0) / 60.0
        x1 = ((p["end_s"] if p["end_s"] is not None else events[-1]["t"]) - t0) / 60.0
        shade = 0.25 * p.get("rank", 0) / maxrank
        for ax in (ax1, ax2):
            ax.axvspan(x0, x1, color="red", alpha=shade, lw=0)
        ax1.text((x0 + x1) / 2, 1.02, p["name"], ha="center", fontsize=7)

    fig.tight_layout()
    fig.savefig(out, dpi=140)


if __name__ == "__main__":
    main()
