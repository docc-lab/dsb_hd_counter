#!/usr/bin/env python3
"""motiv2_report.py -- cores-to-SLO comparison of the motivation pass-2 cells.

Reads every cell directory under the given roots (data/motiv2/<cell>/
stage3eval_*/runs/run_1, as laid out by run-motiv2.sh) and prints, per
cell:

  victim instance   processing p50/p90 and total p50/p90, count-weighted
                    means of the per-100 ms-window percentiles over p1
                    (2-20 s) and over the ARMED BURSTS (80-90, 100-110,
                    120-130 s), and the armed/p1 ratios;
  service           the same latency pooled over the victim AND its overflow
                    replicas (run_data-overflow-*.json), i.e. what the
                    frontend's traffic saw, with the request share per replica;
  e2e               wrk2 hotelReservation p50/p90/p99 and achieved rps over
                    the whole run (single block);
  cores             mean cores (cgroup usage_usec / wall time) in the armed
                    bursts for the victim pod, the overflow pods and the
                    aggressor pods on the target node, from
                    mitigation/cpu_usage.csv joined with pod_uids_*.txt; plus
                    busy fraction of CPU groups (victim 18-20 / siblings 2-4 /
                    replica threads 21-29 / the rest of the node);
  neighbor          aggressor wrk2 burst throughput and p50, armed/disarmed
                    (p3 bursts / p2 bursts, same run);
  actions           controller actions (hc apply/restore, horizontal steps)
                    with the first one's offset from ARM.

Then the SLO table: for each cell, whether the armed-burst victim ratios
meet --slo-proc (processing p90 armed/p1) and --slo-total (service total p90
armed/p1), next to the cores the arm consumed.

  python3 tools/motiv2_report.py data/motiv2 [--csv out.csv] [--slo-proc 1.2 --slo-total 1.5]
  python3 tools/motiv2_report.py data/motiv2 --phase-cores    # add p1/p2 core columns
"""
import argparse
import csv
import datetime
import glob
import json
import math
import os
import re
import statistics as st
import sys

P1 = [(2, 20)]
P2B = [(20, 30), (40, 50), (60, 70)]       # overwritten from --burst-s/--period/--steady in main()
P3B = [(80, 90), (100, 110), (120, 130)]
CPU_GROUPS = {"victim 18-20": [18, 19, 20], "siblings 2-4": [2, 3, 4],
              "replica 21-29": list(range(21, 30)), "rest": [0, 1] + list(range(5, 14)) + [16, 17],
              "daemons 14,15": [14, 15]}


def ts_epoch(s):
    s = re.sub(r"\.(\d+)", lambda m: "." + (m.group(1) + "000000")[:6], s).replace("Z", "+00:00")
    return datetime.datetime.fromisoformat(s).timestamp()


def in_any(t, spans):
    return any(lo <= t < hi for lo, hi in spans)


def wmean(vals, wts):
    den = sum(wts)
    return sum(v * w for v, w in zip(vals, wts)) / den if den else float("nan")


def load_run(path):
    """-> list of (t_rel_s, request_count, proc_p50, proc_p90, tot_p50, tot_p90) in ms/us."""
    j = json.load(open(path))
    out = []
    for s in j.get("samples", []):
        tw = s.get("timing_window") or {}
        n = tw.get("request_count", 0)
        if not n:
            continue
        pt, tt = tw.get("processing_time") or {}, tw.get("total_time") or {}
        out.append((ts_epoch(s["timestamp"]), n, pt.get("p50_ns", 0) / 1e3, pt.get("p90_ns", 0) / 1e3,
                    tt.get("p50_ns", 0) / 1e6, tt.get("p90_ns", 0) / 1e6))
    return out


def lat_stats(rows, t0, spans):
    sel = [r for r in rows if in_any(r[0] - t0, spans)]
    if not sel:
        return dict(n=0, proc50=float("nan"), proc90=float("nan"), tot50=float("nan"), tot90=float("nan"))
    w = [r[1] for r in sel]
    return dict(n=sum(w), proc50=wmean([r[2] for r in sel], w), proc90=wmean([r[3] for r in sel], w),
                tot50=wmean([r[4] for r in sel], w), tot90=wmean([r[5] for r in sel], w))


def parse_wrk2_blocks(path):
    """wrk2 driver output -> list of dict(kind, t, rps, p50, p90, p99 ms, n)."""
    blocks, cur = [], None
    if not os.path.isfile(path):
        return blocks
    for line in open(path, errors="replace"):
        m = re.match(r"--- (BURST|IDLE|shape=\S+).*?@\s*(\S+)", line)
        if m:
            cur = dict(kind=m.group(1) if m.group(1) in ("BURST", "IDLE") else "RUN", t=ts_epoch(m.group(2)),
                       rps=float("nan"), p50=float("nan"), p90=float("nan"), p99=float("nan"), n=0)
            blocks.append(cur)
            continue
        if cur is None:
            continue
        m = re.match(r"\s*(50|90|99)\.000%\s+([\d.]+)(us|ms|s)\b", line)
        if m:
            v = float(m.group(2)) * {"us": 1e-3, "ms": 1, "s": 1e3}[m.group(3)]
            cur["p" + m.group(1)] = v
        m = re.match(r"Requests/sec:\s+([\d.]+)", line)
        if m:
            cur["rps"] = float(m.group(1))
        m = re.match(r"\s*(\d+) requests in", line)
        if m:
            cur["n"] = int(m.group(1))
    return blocks


def aggr_ratio(blocks, t0, armed_rel):
    p2 = [b for b in blocks if b["kind"] == "BURST" and 20 <= b["t"] - t0 < armed_rel]
    p3 = [b for b in blocks if b["kind"] == "BURST" and b["t"] - t0 >= armed_rel]
    if not p2 or not p3:
        return float("nan"), float("nan"), p2, p3
    r = st.mean(b["rps"] for b in p3) / st.mean(b["rps"] for b in p2)
    l = st.mean(b["p50"] for b in p3) / st.mean(b["p50"] for b in p2)
    return r, l, p2, p3


def load_uids(mdir):
    uids = {}
    for f in ("pod_uids_end.txt", "pod_uids_p3.txt"):
        p = os.path.join(mdir, f)
        if not os.path.isfile(p):
            continue
        for line in open(p):
            parts = line.split()
            if len(parts) >= 4:
                uids.setdefault(parts[0], (parts[1], parts[2], parts[3]))
    return uids


def pod_class(ns, name):
    if ns == "default" and name.startswith("search-overflow-"):
        return "overflow"
    if ns == "default" and name.startswith("search-"):
        return "victim"
    if ns.startswith("aggressor-"):
        return "aggressor"
    return "other"


def cpu_usage(mdir, t0, spans, target_node, path=None):
    """-> (cores by pod class, busy fraction by CPU group) over the spans."""
    p = path or os.path.join(mdir, "cpu_usage.csv")
    if not os.path.isfile(p):
        return {}, {}
    uids = load_uids(mdir)
    per_key = {}
    for row in csv.DictReader(open(p)):
        t = int(row["unix_ms"]) / 1e3 - t0
        if not in_any(t, spans):
            continue
        per_key.setdefault(row["key"], []).append((t, int(row["a"]), int(row["b"])))
    cores, busy = {}, {}
    for key, rows in per_key.items():
        rows.sort()
        if len(rows) < 2:
            continue
        # sum deltas inside each contiguous span (skip gaps > 3 s)
        da = db = dt = 0.0
        for (t1, a1, b1), (t2, a2, b2) in zip(rows, rows[1:]):
            if t2 - t1 > 3:
                continue
            da += a2 - a1
            db += b2 - b1
            dt += t2 - t1
        if dt <= 0:
            continue
        if key.startswith("cpu"):
            busy[int(key[3:])] = da / db if db else float("nan")
        else:
            uid = key[4:]
            ns, name, node = uids.get(uid, ("?", uid[:8], "?"))
            if node != target_node and node != "?":
                cls = pod_class(ns, name) + "@" + node
            else:
                cls = pod_class(ns, name)
            cores[cls] = cores.get(cls, 0.0) + da / 1e6 / dt
    groups = {g: st.mean(busy[c] for c in cpus if c in busy) if any(c in busy for c in cpus) else float("nan")
              for g, cpus in CPU_GROUPS.items()}
    return cores, groups


def actions(mdir):
    out = []
    for f in glob.glob(os.path.join(mdir, "*.ctrl.log")):
        for line in open(f, errors="replace"):
            if '"msg":"formula: hc apply"' in line or '"msg":"formula: hc restore"' in line \
                    or '"msg":"formula: horizontal step"' in line:
                try:
                    j = json.loads(line)
                except ValueError:
                    continue
                out.append((ts_epoch(j["time"]), j["msg"].replace("formula: ", ""), j.get("n")))
    return sorted(out)


def analyse_cell(cell_dir, args):
    runs = sorted(glob.glob(os.path.join(cell_dir, "stage3eval_*", "runs", "run_1")))
    if not runs:
        return None
    run = runs[-1]
    mdir = os.path.join(run, "mitigation")
    cell = os.path.basename(cell_dir.rstrip("/\\"))
    try:
        t0 = int(open(os.path.join(run, "started_epoch_ns.txt")).read()) / 1e9
    except OSError:
        return None
    armed = t0 + args.arm
    af = os.path.join(run, "armed_epoch_ns.txt")
    if os.path.isfile(af):
        armed = int(open(af).read()) / 1e9
    armed_rel = armed - t0
    p3b = [(armed_rel + (a - args.arm), armed_rel + (b - args.arm)) for a, b in P3B] if args.bursts_from_arm else P3B
    r = dict(cell=cell, arm=open(os.path.join(mdir, "arm.txt")).read().strip() if os.path.isfile(os.path.join(mdir, "arm.txt")) else "?",
             placement=open(os.path.join(cell_dir, "placement.txt")).read().strip() if os.path.isfile(os.path.join(cell_dir, "placement.txt")) else "")
    vic = load_run(os.path.join(run, "run_data.json"))
    ovf = {os.path.basename(f)[len("run_data-overflow-"):-5]: load_run(f)
           for f in glob.glob(os.path.join(run, "run_data-overflow-*.json"))}
    v1, v3 = lat_stats(vic, t0, P1), lat_stats(vic, t0, p3b)
    pooled = vic + [row for rows in ovf.values() for row in rows]
    s1, s3 = lat_stats(pooled, t0, P1), lat_stats(pooled, t0, p3b)
    r.update(v_proc50_p1=v1["proc50"], v_proc50_p3=v3["proc50"], v_proc90_p1=v1["proc90"], v_proc90_p3=v3["proc90"],
             v_tot50_p1=v1["tot50"], v_tot50_p3=v3["tot50"], v_tot90_p1=v1["tot90"], v_tot90_p3=v3["tot90"],
             s_tot50_p3=s3["tot50"], s_tot90_p3=s3["tot90"], s_proc90_p3=s3["proc90"],
             v_req_p3=v3["n"], s_req_p3=s3["n"], replicas_seen=len(ovf))
    for k in ("proc50", "proc90", "tot50", "tot90"):
        r["v_" + k + "_ratio"] = r["v_%s_p3" % k] / r["v_%s_p1" % k] if r["v_%s_p1" % k] else float("nan")
    r["s_tot90_ratio"] = s3["tot90"] / v1["tot90"] if v1["tot90"] else float("nan")
    r["s_proc90_ratio"] = s3["proc90"] / v1["proc90"] if v1["proc90"] else float("nan")
    r["ovf_req_share_p3"] = (s3["n"] - v3["n"]) / s3["n"] if s3["n"] else 0.0
    # e2e (whole run, single block)
    hr = parse_wrk2_blocks(os.path.join(run, "wrk2", "hotelReservation.txt"))
    if hr:
        r.update(e2e_rps=hr[0]["rps"], e2e_p50=hr[0]["p50"], e2e_p90=hr[0]["p90"], e2e_p99=hr[0]["p99"])
    # overload scenarios: the extra driver (from t=20 s) carries most of the traffic
    hx = parse_wrk2_blocks(os.path.join(run, "wrk2", "hotelReservation-extra.txt"))
    if hx:
        r.update(e2ex_rps=hx[0]["rps"], e2ex_p50=hx[0]["p50"], e2ex_p90=hx[0]["p90"], e2ex_p99=hx[0]["p99"])
    # neighbours
    for tb, tag in (("socialNetwork", "sn"), ("sockshop", "ss")):
        rr, ll, _, _ = aggr_ratio(parse_wrk2_blocks(os.path.join(run, "wrk2", tb + ".txt")), t0, armed_rel)
        r[tag + "_rps_ratio"], r[tag + "_p50_ratio"] = rr, ll
    # cores
    cores3, busy3 = cpu_usage(mdir, t0, p3b, args.target_node)
    r.update(c_victim=cores3.get("victim", float("nan")), c_overflow=sum(v for k, v in cores3.items() if k.startswith("overflow")),
             c_aggr=cores3.get("aggressor", float("nan")), c_other=cores3.get("other", float("nan")))
    r["c_overflow_offnode"] = sum(v for k, v in cores3.items() if k.startswith("overflow@"))
    # replicas on another node: run-motiv2.sh leaves that node's sampler file in the cell dir
    for f in glob.glob(os.path.join(cell_dir, "cpu_usage-*.csv")):
        node = os.path.basename(f)[len("cpu_usage-"):-4]
        c_other, _ = cpu_usage(mdir, t0, p3b, node, path=f)
        r["c_overflow_offnode"] += sum(v for k, v in c_other.items() if k.startswith("overflow"))
        r["c_other_node_total"] = sum(c_other.values())
    for g, v in busy3.items():
        r["busy_" + g.split()[0]] = v
    if args.phase_cores:
        for tag, spans in (("p1", P1), ("p2b", P2B)):
            c, b = cpu_usage(mdir, t0, spans, args.target_node)
            r["c_victim_" + tag] = c.get("victim", float("nan"))
            r["c_aggr_" + tag] = c.get("aggressor", float("nan"))
            r["busy_siblings_" + tag] = b.get("siblings 2-4", float("nan"))
    # actions
    acts = actions(mdir)
    r["n_actions"] = len(acts)
    r["first_action_s"] = (acts[0][0] - armed) if acts else float("nan")
    r["max_n"] = max([a[2] for a in acts if a[2] is not None], default=0)
    return r


def fmt(v, nd=2):
    if isinstance(v, float):
        return "nan" if math.isnan(v) else f"{v:.{nd}f}"
    return str(v)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("roots", nargs="+")
    ap.add_argument("--arm", type=float, default=80.0)
    ap.add_argument("--target-node", default="node-4")
    ap.add_argument("--bursts-from-arm", action="store_true", help="armed bursts at ARM+0/20/40 instead of fixed 80/100/120")
    ap.add_argument("--slo-proc", type=float, default=1.2, help="SLO: victim processing p90 armed/p1 <= this")
    ap.add_argument("--slo-total", type=float, default=1.5, help="SLO: service total p90 armed/p1 <= this")
    ap.add_argument("--phase-cores", action="store_true")
    ap.add_argument("--burst-s", type=float, default=10.0, help="aggressor burst length (window = [start, start+burst))")
    ap.add_argument("--period", type=float, default=20.0, help="burst period (bursts start at 20, 20+period, ...)")
    ap.add_argument("--steady", action="store_true", help="steady contention: p2 = 30-80 s, armed = ARM+10 .. 140 s")
    ap.add_argument("--csv")
    args = ap.parse_args()
    global P2B, P3B
    if args.steady:
        P2B, P3B = [(30, 80)], [(args.arm + 10, 140)]
    else:
        starts = [20 + i * args.period for i in range(int(120 / args.period) + 1) if 20 + i * args.period < 140]
        P2B = [(t, t + args.burst_s) for t in starts if t < args.arm]
        P3B = [(t, t + args.burst_s) for t in starts if t >= args.arm]

    rows = []
    for root in args.roots:
        cells = [root] if glob.glob(os.path.join(root, "stage3eval_*")) else sorted(glob.glob(os.path.join(root, "*")))
        for c in cells:
            if os.path.isdir(c):
                r = analyse_cell(c, args)
                if r:
                    rows.append(r)
    if not rows:
        sys.exit("no cells found")

    print("== victim instance (armed bursts / p1) and service-level pooled over replicas")
    print(f"{'cell':22s} {'proc50':>7s} {'proc90':>7s} {'tot50':>6s} {'tot90':>6s} | {'svc tot90':>9s} {'svc proc90':>10s} {'ovf share':>9s} | {'e2e p50':>8s} {'e2e p99':>8s} {'rps':>6s}")
    for r in rows:
        print(f"{r['cell']:22s} {fmt(r['v_proc50_ratio']):>7s} {fmt(r['v_proc90_ratio']):>7s} {fmt(r['v_tot50_ratio']):>6s} {fmt(r['v_tot90_ratio']):>6s} | "
              f"{fmt(r['s_tot90_ratio']):>9s} {fmt(r['s_proc90_ratio']):>10s} {fmt(r['ovf_req_share_p3']):>9s} | "
              f"{fmt(r.get('e2e_p50', float('nan')), 1):>8s} {fmt(r.get('e2e_p99', float('nan')), 0):>8s} {fmt(r.get('e2e_rps', float('nan')), 0):>6s}")
    print("\n== absolute p1 -> armed bursts (victim instance): proc p90 us, total p90 ms")
    for r in rows:
        print(f"{r['cell']:22s} proc90 {fmt(r['v_proc90_p1'], 1)} -> {fmt(r['v_proc90_p3'], 1)} us   tot90 {fmt(r['v_tot90_p1'], 1)} -> {fmt(r['v_tot90_p3'], 1)} ms   "
              f"svc tot90 {fmt(r['s_tot90_p3'], 1)} ms   replicas seen {r['replicas_seen']}  actions {r['n_actions']} (first {fmt(r['first_action_s'], 1)} s after ARM, max n {r['max_n']})"
              + (f"   extra driver e2e p50/p90/p99 {fmt(r['e2ex_p50'], 1)}/{fmt(r['e2ex_p90'], 1)}/{fmt(r['e2ex_p99'], 1)} ms at {fmt(r['e2ex_rps'], 0)} rps" if 'e2ex_rps' in r else ""))
    print("\n== cores in the armed bursts (mean cores = cgroup cpu time / wall) and CPU-group busy fraction")
    print(f"{'cell':22s} {'victim':>6s} {'overflow':>8s} {'ovf@other':>9s} {'aggr':>6s} | {'busy vic':>8s} {'sibl':>6s} {'rest':>6s} {'21-29':>6s} | {'SN rps':>6s} {'SS rps':>6s} {'SS p50':>6s}")
    for r in rows:
        print(f"{r['cell']:22s} {fmt(r['c_victim']):>6s} {fmt(r['c_overflow']):>8s} {fmt(r['c_overflow_offnode']):>9s} {fmt(r['c_aggr']):>6s} | "
              f"{fmt(r.get('busy_victim', float('nan'))):>8s} {fmt(r.get('busy_siblings', float('nan'))):>6s} {fmt(r.get('busy_rest', float('nan'))):>6s} {fmt(r.get('busy_replica', float('nan'))):>6s} | "
              f"{fmt(r['sn_rps_ratio']):>6s} {fmt(r['ss_rps_ratio']):>6s} {fmt(r['ss_p50_ratio']):>6s}")
    print(f"\n== SLO table: processing p90 ratio <= {args.slo_proc} (mechanism), service total p90 ratio <= {args.slo_total} (symptom)")
    print(f"{'cell':22s} {'proc SLO':>8s} {'total SLO':>9s} {'victim+replica cores':>20s} {'aggr cores':>10s} {'SS rps kept':>11s}")
    for r in rows:
        ok_p = r["v_proc90_ratio"] <= args.slo_proc
        ok_t = r["s_tot90_ratio"] <= args.slo_total
        print(f"{r['cell']:22s} {('yes' if ok_p else 'no'):>8s} {('yes' if ok_t else 'no'):>9s} "
              f"{fmt(r['c_victim'] + r['c_overflow'] + r['c_overflow_offnode']):>20s} {fmt(r['c_aggr']):>10s} {fmt(r['ss_rps_ratio']):>11s}")
    if args.csv:
        keys = sorted({k for r in rows for k in r})
        with open(args.csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=keys)
            w.writeheader()
            w.writerows(rows)
        print(f"\nwrote {args.csv}")


if __name__ == "__main__":
    main()
