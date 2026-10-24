#!/usr/bin/env python3
"""motiv_phases.py -- per-phase and per-burst view of a phased stage-3 run.

For each stage3eval_* dir: victim latency (processing_time / total_time
per-window p50 and p90, medians over the windows) in p1 (victim only),
p2 (contention, disarmed) and p3 (contention, armed), and -- for bursty
aggressor shapes -- over the BURST windows only of p2 and p3, so that a
mitigation that reacts within a burst shows up against the unmitigated
bursts of p2. Also the controller's view (mean/max e_iso and y50 per
phase from scores.csv) and its actions (ctrl.log) as offsets from t0.

  python3 tools/motiv_phases.py data/motiv/*            # bursts 10 s on / 10 s off from t=20
  python3 tools/motiv_phases.py --burst-s 10 --idle-s 20 data/collect-smt/col-ext-heavy-bursty
  python3 tools/motiv_phases.py --no-bursts data/sweep-none/*   # steady configs
"""
import argparse
import datetime
import glob
import json
import os
import re
import statistics as st
import sys


def ts_epoch(s):
    s = re.sub(r"\.(\d+)", lambda m: "." + (m.group(1) + "000000")[:6], s).replace("Z", "+00:00")
    return datetime.datetime.fromisoformat(s).timestamp()


def run_dirs(paths):
    for p in paths:
        if os.path.isfile(os.path.join(p, "input.yaml")):
            yield p
        else:
            for d in sorted(glob.glob(os.path.join(p, "**", "stage3eval_*"), recursive=True)):
                if os.path.isfile(os.path.join(d, "input.yaml")):
                    yield d


def cfg_name(d):
    try:
        for line in open(os.path.join(d, "input.yaml")):
            if line.strip().startswith("name:"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return os.path.basename(d)


def med_ms(rows, sel, sec, key):
    v = [r[1][sec][key] for r in rows if sel(r[0]) and r[1].get(sec)]
    return st.median(v) / 1e6 if v else float("nan")


def in_any(t, spans):
    return any(lo <= t < hi for lo, hi in spans)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--onset", type=float, default=20.0, help="aggressor start (s after t0)")
    ap.add_argument("--arm", type=float, default=80.0, help="ARM point (s after t0; armed_epoch_ns.txt wins)")
    ap.add_argument("--end", type=float, default=140.0)
    ap.add_argument("--burst-s", type=float, default=10.0)
    ap.add_argument("--idle-s", type=float, default=10.0)
    ap.add_argument("--no-bursts", action="store_true", help="steady contention: skip the burst rows")
    ap.add_argument("--actions", action="store_true", help="list every controller action")
    args = ap.parse_args()

    for d in run_dirs(args.paths):
        run = os.path.join(d, "runs", "run_1")
        mdir = os.path.join(run, "mitigation")
        name = cfg_name(d)
        try:
            j = json.load(open(os.path.join(run, "run_data.json")))
            t0 = int(open(os.path.join(run, "started_epoch_ns.txt")).read()) / 1e9
        except Exception as e:  # noqa: BLE001
            print(f"{name}: skipped ({e})")
            continue
        arm_t = args.arm
        try:
            arm_t = int(open(os.path.join(mdir, "armed_epoch_ns.txt")).read()) / 1e9 - t0
        except Exception:  # noqa: BLE001
            pass
        arm = open(os.path.join(mdir, "arm.txt")).read().strip() if os.path.isfile(os.path.join(mdir, "arm.txt")) else "?"
        pool = open(os.path.join(mdir, "aggr_cpuset.txt")).read().strip() if os.path.isfile(os.path.join(mdir, "aggr_cpuset.txt")) else "?"

        rows = []
        for s in j["samples"]:
            tw = s.get("timing_window") or {}
            if not tw or tw.get("request_count", 0) == 0:
                continue
            rows.append((ts_epoch(s["timestamp"]) - t0, tw))

        p1 = (0.0, args.onset)
        p2 = (args.onset, arm_t)
        p3 = (arm_t, args.end)
        phases = [("p1 victim only", lambda t: p1[0] <= t < p1[1]),
                  ("p2 contention, disarmed", lambda t: p2[0] <= t < p2[1]),
                  ("p3 contention, armed", lambda t: p3[0] <= t < p3[1])]
        if not args.no_bursts:
            bursts = []
            t = args.onset
            while t < args.end:
                bursts.append((t, t + args.burst_s))
                t += args.burst_s + args.idle_s
            b2 = [b for b in bursts if b[0] >= p2[0] and b[1] <= p2[1]]
            b3 = [b for b in bursts if b[0] >= p3[0] and b[1] <= p3[1]]
            phases.append(("p2 BURST windows " + ",".join(f"{int(a)}-{int(b)}" for a, b in b2), lambda t, s=b2: in_any(t, s)))
            phases.append(("p3 BURST windows " + ",".join(f"{int(a)}-{int(b)}" for a, b in b3), lambda t, s=b3: in_any(t, s)))

        # controller view
        scores = {}
        for f in glob.glob(os.path.join(mdir, "*.scores.csv")):
            with open(f) as fh:
                hdr = fh.readline().strip().split(",")
                idx = {k: i for i, k in enumerate(hdr)}
                for line in fh:
                    c = line.rstrip("\n").split(",")
                    if len(c) < len(hdr):
                        continue
                    try:
                        t = int(c[idx["unix_ms"]]) / 1e3 - t0
                        scores.setdefault("t", []).append(t)
                        for k in ("e_iso", "y50", "y90", "ext90", "applied_cap"):
                            scores.setdefault(k, []).append(float(c[idx[k]]))
                    except (ValueError, KeyError):
                        continue
        actions = []
        for f in glob.glob(os.path.join(mdir, "*.ctrl.log")):
            for line in open(f, errors="replace"):
                if '"formula: h' not in line and "hc restore" not in line and "hc apply" not in line:
                    continue
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                msg = e.get("msg", "")
                if not (msg.startswith("formula: h") or "hc restore" in msg or "hc apply" in msg):
                    continue
                t = ts_epoch(e["time"]) - t0
                extra = ""
                if "u" in e:
                    extra = f"u={e['u']} n={e['n']} y50={e.get('y50')}"
                elif "e_iso" in e:
                    extra = f"e_iso={e['e_iso']}" + (f" applied={e['applied']}" if "applied" in e else "") + (f" ERR {str(e.get('err'))[:80]}" if "err" in e else "")
                actions.append((t, msg.replace("formula: ", ""), extra))
        actions.sort()

        print(f"== {name}  arm={arm}  pool={pool}  t0+{arm_t:.0f}s armed  windows={len(rows)}")
        print(f"   {'phase':44s} {'proc p50':>9s} {'proc p90':>9s} {'total p50':>10s} {'total p90':>10s} {'e_iso mean/max':>15s} {'y50 mean':>9s}")
        ref = None
        for label, sel in phases:
            pp50 = med_ms(rows, sel, "processing_time", "p50_ns")
            pp90 = med_ms(rows, sel, "processing_time", "p90_ns")
            tp50 = med_ms(rows, sel, "total_time", "p50_ns")
            tp90 = med_ms(rows, sel, "total_time", "p90_ns")
            if ref is None:
                ref = (pp50, pp90, tp50, tp90)
            def fmt(v, r):
                return f"{v:6.3f}" + (f"({v / r:4.2f}x)" if r and r == r else "       ")
            ei = [v for t, v in zip(scores.get("t", []), scores.get("e_iso", [])) if sel(t)]
            y5 = [v for t, v in zip(scores.get("t", []), scores.get("y50", [])) if sel(t)]
            es = f"{st.mean(ei):5.2f}/{max(ei):4.2f}" if ei else "   -   "
            ys = f"{st.mean(y5):5.2f}" if y5 else "  -  "
            print(f"   {label:44s} {fmt(pp50, ref[0]):>9s}  {fmt(pp90, ref[1]):>9s}  {fmt(tp50, ref[2]):>10s}  {fmt(tp90, ref[3]):>10s}  {es:>15s} {ys:>9s}")
        if actions:
            n_apply = sum(1 for a in actions if a[1] == "hc apply")
            n_rest = sum(1 for a in actions if a[1] == "hc restore")
            n_fail = sum(1 for a in actions if "failed" in a[1])
            n_horz = sum(1 for a in actions if a[1] == "horizontal step")
            first = next((a for a in actions if a[0] >= arm_t and a[1] in ("hc apply", "horizontal step")), None)
            print(f"   actions: hc apply={n_apply} restore={n_rest} failed={n_fail} horizontal steps={n_horz}"
                  + (f"; first action after ARM at t0+{first[0]:.1f}s ({first[0] - arm_t:+.1f}s)" if first else ""))
            if args.actions:
                for t, msg, extra in actions:
                    print(f"     t0+{t:6.1f}s  {msg:22s} {extra}")
        print()


if __name__ == "__main__":
    main()
