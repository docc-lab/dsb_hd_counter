#!/usr/bin/env python3
"""motiv3_report.py -- per-cell numbers for the motivation pass 3 (run-motiv3.sh output).

Windows are data-driven: the aggressor bursts come from the SN driver's BURST blocks
(wrk2/socialNetwork.txt) and the burst length from config-as-run.yaml; the enable time
from armed_epoch_ns.txt. Per cell and per scope (victim instance / service = victim +
replicas pooled, count-weighted means of the 100 ms window quantiles):

  p1      quiet phase (2 s .. first burst - 1 s, or 2-20 s for the steady config)
  p2b     bursts before the mitigation is enabled
  p3b     bursts after it ("during bursts")
  p3all   the whole enabled phase (enable + 10 s .. end), bursts included ("overall")
  ovl     steady overload window (enable + 10 s .. end) for the intrinsic config

Columns: handler (processing_time) p50/p90/p95/p99 us, total p50/p90/p95/p99 ms (p95 interpolated
log-linearly between the recorded per-window p90 and p99), request
counts, replica request share, cores (victim, replicas on node-3, aggressors on node-4,
HC burner, HC cores lent from the balancer log) in p1 / p3b / p3all, node-3 busy
fraction of the replica threads and of the dial's siblings.

  python3 tools/motiv3_report.py data/motiv3 [data/motiv3-t2 ...] --csv out.csv
  python3 tools/motiv3_report.py data/motiv3-int --steady --csv out.csv
"""
import argparse
import csv
import glob
import io
import json
import os
import re
import sys
import tarfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import motiv2_report as R  # noqa: E402

QUANT = ("proc50", "proc90", "proc95", "proc99", "tot50", "tot90", "tot95", "tot99")
P95_EXP = (0.95 - 0.90) / (0.99 - 0.90)   # position of p95 between the recorded p90 and p99
NODE3_REPLICA_THREADS = list(range(18, 30))
NODE3_SIBLINGS = list(range(2, 14))
if os.environ.get("MOTIV_LAYOUT") == "c6320":   # Clemson c6320 (2026-11-10): replicas on even ids 4-26, dial on their siblings 32-54
    NODE3_REPLICA_THREADS = list(range(4, 28, 2))
    NODE3_SIBLINGS = list(range(32, 56, 2))


def balancer_lent(mdir, t0):
    """(t_rel, cores lent) per second from hc-balancer.tgz, anchored at the controller's
    'hc: balancer started' log_dir epoch (same as motiv2_plot.balancer_lent)."""
    tgz = os.path.join(mdir, "hc-balancer.tgz")
    if not os.path.isfile(tgz):
        return []
    start = None
    for f in glob.glob(os.path.join(mdir, "*.ctrl.log")):
        for line in open(f, errors="replace"):
            if '"msg":"hc: balancer started"' in line:
                m = re.search(r'"log_dir":"[^"]*/(\d{13})"', line)
                if m:
                    start = int(m.group(1)) / 1e3 - t0
                    break
        if start is not None:
            break
    if start is None:
        return []
    t = tarfile.open(tgz)
    names = [n for n in t.getnames() if n.endswith("balancer.log")]
    if not names:
        return []
    rows = []
    for line in io.TextIOWrapper(t.extractfile(names[0]), errors="replace"):
        p = line.strip().split(",")
        if len(p) < 10 or not p[0].isdigit():
            continue
        rows.append((int(p[0]) + int(p[1]) / 1e9, int(p[9])))
    if not rows:
        return []
    mono0 = rows[0][0]
    out = []
    for (ta, va), (tb, _) in zip(rows, rows[1:]):
        out.append((ta - mono0 + start, tb - ta, va))   # (t_rel, hold time, value)
    return out


def lent_mean(rows, spans):
    num = den = 0.0
    for t, dt, v in rows:
        if R.in_any(t, spans):
            num += v * dt
            den += dt
    return num / den if den else float("nan")


def bursts_from_driver(run, t0):
    blocks = R.parse_wrk2_blocks(os.path.join(run, "wrk2", "socialNetwork.txt"))
    cfg = open(os.path.join(run, "mitigation", "config-as-run.yaml"), errors="replace").read() \
        if os.path.isfile(os.path.join(run, "mitigation", "config-as-run.yaml")) else ""
    m = re.search(r"burst_s:\s*(\d+)", cfg)
    burst_s = float(m.group(1)) if m else 6.0
    return [(b["t"] - t0, b["t"] - t0 + burst_s) for b in blocks if b["kind"] == "BURST"], burst_s


def p95_interp(p90, p99):
    """The sampler records p90 and p99 per 100 ms window but no p95: interpolate log-linearly
    between the two (CDF linear in log latency), the conservative choice for a heavy tail
    (linear-in-latency interpolation would put p95 further towards p99)."""
    if p90 <= 0 or p99 <= 0:
        return float("nan")
    return p90 * (p99 / p90) ** P95_EXP


def stats(rows, t0, spans):
    s = R.lat_stats(rows, t0, spans)
    out = {k: s[k] for k in QUANT if k in s}
    sel = [r for r in rows if R.in_any(r[0] - t0, spans)]
    w = [r[1] for r in sel]
    # load_run rows: (t, n, proc50, proc90, tot50, tot90, proc99, tot99)
    out["proc95"] = R.wmean([p95_interp(r[3], r[6]) for r in sel], w) if sel else float("nan")
    out["tot95"] = R.wmean([p95_interp(r[5], r[7]) for r in sel], w) if sel else float("nan")
    return out, s["n"]


def pod_class(ns, name):
    if ns == "default" and name.startswith("hc-secondary-burner"):
        return "burner"
    if ns == "default" and name.startswith("node3-load"):
        return "dial"
    return R.pod_class(ns, name)


def cores_in(mdir, t0, spans, target_node, path=None):
    """cores by class over spans (victim / overflow / aggressor / burner / dial / other),
    plus per-CPU busy fractions."""
    p = path or os.path.join(mdir, "cpu_usage.csv")
    if not os.path.isfile(p):
        return {}, {}
    uids = R.load_uids(mdir)
    per_key = {}
    for row in csv.DictReader(open(p)):
        t = int(row["unix_ms"]) / 1e3 - t0
        if not R.in_any(t, spans):
            continue
        per_key.setdefault(row["key"], []).append((t, int(row["a"]), int(row["b"])))
    cores, busy = {}, {}
    for key, rows in per_key.items():
        rows.sort()
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
            cls = pod_class(ns, name)
            cores[cls] = cores.get(cls, 0.0) + da / 1e6 / dt
    return cores, busy


def analyse_cell(cell_dir, args):
    runs = sorted(glob.glob(os.path.join(cell_dir, "stage3eval_*", "runs", "run_1")))
    if not runs:
        return None
    run = runs[-1]
    mdir = os.path.join(run, "mitigation")
    cell = os.path.basename(cell_dir.rstrip("/\\"))
    t0 = int(open(os.path.join(run, "started_epoch_ns.txt")).read()) / 1e9
    af = os.path.join(run, "armed_epoch_ns.txt")
    if not os.path.isfile(af):
        af = os.path.join(mdir, "armed_epoch_ns.txt")
    arm_rel = (int(open(af).read()) / 1e9 - t0) if os.path.isfile(af) else float(args.arm)
    rd = lambda n, d="": open(os.path.join(cell_dir, n)).read().strip() if os.path.isfile(os.path.join(cell_dir, n)) else d
    r = dict(cell=cell, sweep=os.path.basename(os.path.dirname(cell_dir.rstrip("/\\"))),
             arm=rd("../" + "x", "") or (open(os.path.join(mdir, "arm.txt")).read().strip() if os.path.isfile(os.path.join(mdir, "arm.txt")) else "?"),
             load=rd("load.txt", "quiet"), placement=rd("placement.txt", ""), arm_rel=arm_rel)
    vic = R.load_run(os.path.join(run, "run_data.json"))
    ovf = [row for f in glob.glob(os.path.join(run, "run_data-overflow-*.json")) for row in R.load_run(f)]
    r["replicas_seen"] = len(glob.glob(os.path.join(run, "run_data-overflow-*.json")))
    end = args.duration
    if args.steady:
        windows = dict(p1=[(2, 20)], ovl=[(arm_rel + 10 if arm_rel > 20 else 30, end)])
        bursts = []
    else:
        bursts, burst_s = bursts_from_driver(run, t0)
        r["burst_s"] = burst_s
        p2b = [(a, b) for a, b in bursts if b <= arm_rel]
        p3b = [(a, b) for a, b in bursts if a >= arm_rel]
        first = min([a for a, _ in bursts], default=30)
        # p3gap = the enabled phase outside the bursts (same span as p3all minus the bursts):
        # the steady level the bursts are to be compared against (replicas exist here,
        # unlike in p1).
        p3gap, lo = [], arm_rel + 10
        for a, b in p3b:
            if a > lo:
                p3gap.append((lo, a))
            lo = b
        if end > lo:
            p3gap.append((lo, end))
        windows = dict(p1=[(2, first - 1)], p2b=p2b, p3b=p3b, p3gap=p3gap, p3all=[(arm_rel + 10, end)],
                       p2all=[(first - 1, arm_rel)])
        r["n_bursts_p2"], r["n_bursts_p3"] = len(p2b), len(p3b)
    r["windows"] = {k: v for k, v in windows.items()}
    for w, spans in windows.items():
        if not spans:
            continue
        sv, nv = stats(vic, t0, spans)
        ss, ns = stats(vic + ovf, t0, spans)
        for q in QUANT:
            r["v_%s_%s" % (q, w)] = sv[q]
            r["s_%s_%s" % (q, w)] = ss[q]
        r["n_v_" + w], r["n_s_" + w] = nv, ns
        r["share_v_" + w] = nv / ns if ns else float("nan")
        # cores
        c, busy = cores_in(mdir, t0, spans, args.target_node)
        r["c_victim_" + w] = c.get("victim", float("nan"))
        r["c_aggr_" + w] = c.get("aggressor", float("nan"))
        r["c_burner_" + w] = c.get("burner", 0.0)
        r["c_ovf_node4_" + w] = c.get("overflow", 0.0)
        r["busy_sib_" + w] = R.st.mean([busy[k] for k in (2, 3) if k in busy]) if any(k in busy for k in (2, 3)) else float("nan")
        r["busy_vic_" + w] = R.st.mean([busy[k] for k in (18, 19) if k in busy]) if any(k in busy for k in (18, 19)) else float("nan")
        c3 = {}
        for f in glob.glob(os.path.join(cell_dir, "cpu_usage-*.csv")):
            c3, busy3 = cores_in(mdir, t0, spans, "node-3", path=f)
            r["busy_n3_rep_" + w] = R.st.mean([busy3[k] for k in NODE3_REPLICA_THREADS if k in busy3]) if any(k in busy3 for k in NODE3_REPLICA_THREADS) else float("nan")
            r["busy_n3_sib_" + w] = R.st.mean([busy3[k] for k in NODE3_SIBLINGS if k in busy3]) if any(k in busy3 for k in NODE3_SIBLINGS) else float("nan")
        r["c_ovf_node3_" + w] = c3.get("overflow", 0.0)
        r["c_dial_" + w] = c3.get("dial", 0.0)
        r["lent_" + w] = lent_mean(balancer_lent(mdir, t0), spans)
    # ratios of interest
    for scope in ("v", "s"):
        for q in QUANT:
            for w in ("p2b", "p3b", "p3gap", "p3all", "ovl"):
                a, b = r.get("%s_%s_%s" % (scope, q, w)), r.get("%s_%s_p1" % (scope, q))
                if a is not None and b:
                    r["%s_%s_%s_ratio" % (scope, q, w)] = a / b
    acts = R.actions(mdir)
    r["n_actions"] = len(acts)
    r["first_action_s"] = (acts[0][0] - (t0 + arm_rel)) if acts else float("nan")
    r["max_n"] = max([a[2] for a in acts if a[2] is not None], default=0)
    hr = R.parse_wrk2_blocks(os.path.join(run, "wrk2", "hotelReservation.txt"))
    if hr:
        r.update(e2e_rps=hr[0]["rps"], e2e_p50=hr[0]["p50"], e2e_p90=hr[0]["p90"], e2e_p99=hr[0]["p99"])
    hx = R.parse_wrk2_blocks(os.path.join(run, "wrk2", "hotelReservation-extra.txt"))
    if hx:
        r.update(e2ex_rps=hx[0]["rps"], e2ex_p50=hx[0]["p50"], e2ex_p90=hx[0]["p90"], e2ex_p99=hx[0]["p99"])
    for tb, tag in (("socialNetwork", "sn"), ("sockshop", "ss")):
        rr, ll, _, _ = R.aggr_ratio(R.parse_wrk2_blocks(os.path.join(run, "wrk2", tb + ".txt")), t0, arm_rel)
        r[tag + "_rps_ratio"], r[tag + "_p50_ratio"] = rr, ll
    return r


def f(v, nd=2):
    return R.fmt(v, nd) if v is not None else "-"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("roots", nargs="+")
    ap.add_argument("--arm", type=float, default=120.0, help="fallback enable offset when armed_epoch_ns.txt is missing")
    ap.add_argument("--duration", type=float, default=260.0)
    ap.add_argument("--steady", action="store_true", help="intrinsic config: p1 = 2-20 s, ovl = 30-140 s")
    ap.add_argument("--target-node", default="node-4")
    ap.add_argument("--csv")
    args = ap.parse_args()
    if args.steady and args.duration == 260.0:
        args.duration = 140.0
    rows = []
    for root in args.roots:
        cells = [root] if glob.glob(os.path.join(root, "stage3eval_*")) else sorted(glob.glob(os.path.join(root, "*")))
        for c in cells:
            if os.path.isdir(c):
                try:
                    r = analyse_cell(c, args)
                except Exception as e:  # noqa: BLE001
                    print("skip %s: %s" % (c, e), file=sys.stderr)
                    r = None
                if r:
                    rows.append(r)
    if not rows:
        sys.exit("no cells found")
    if args.steady:
        print("== intrinsic: service total p50 / handler p50 (ms / us), p1 -> overload; cores in p1 and overload")
        print(f"{'cell':20s} {'tot50 p1->ovl':>16s} {'ratio':>6s} {'proc50 p1->ovl':>16s} | {'victim':>6s} {'repl n3':>7s} {'burner':>6s} {'lent p1':>7s} {'lent ovl':>8s} | {'e2e-extra p50/p99':>18s}")
        for r in rows:
            print(f"{r['cell']:20s} {f(r.get('s_tot50_p1'), 2):>7s}->{f(r.get('s_tot50_ovl'), 2):>7s} {f(r.get('s_tot50_ovl_ratio')):>6s} "
                  f"{f(r.get('v_proc50_p1'), 1):>7s}->{f(r.get('v_proc50_ovl'), 1):>7s} | {f(r.get('c_victim_ovl')):>6s} {f(r.get('c_ovf_node3_ovl')):>7s} "
                  f"{f(r.get('c_burner_ovl')):>6s} {f(r.get('lent_p1')):>7s} {f(r.get('lent_ovl')):>8s} | {f(r.get('e2ex_p50'), 1):>8s}/{f(r.get('e2ex_p99'), 0):>8s}")
    else:
        print("== extrinsic: SERVICE-level handler p50 / p90 / p95 (us; p95 interpolated between the recorded p90 and p99) in quiet (p1), during enabled bursts (p3b), overall p3")
        print(f"{'cell':20s} {'p1 50/90/95':>16s} | {'p3b 50/90/95':>16s} {'ratio':>14s} | {'p3all 50/90/95':>16s} {'ratio':>14s} | {'vic share':>9s} {'n3 busy sib':>11s}")
        for r in rows:
            g = lambda s, w: "%s/%s/%s" % (f(r.get(f"{s}_proc50_{w}"), 0), f(r.get(f"{s}_proc90_{w}"), 0), f(r.get(f"{s}_proc95_{w}"), 0))
            rr = lambda w: "%s/%s/%s" % (f(r.get(f"s_proc50_{w}_ratio")), f(r.get(f"s_proc90_{w}_ratio")), f(r.get(f"s_proc95_{w}_ratio")))
            print(f"{r['cell']:20s} {g('s', 'p1'):>16s} | {g('s', 'p3b'):>16s} {rr('p3b'):>14s} | {g('s', 'p3all'):>16s} {rr('p3all'):>14s} | "
                  f"{f(r.get('share_v_p3b')):>9s} {f(r.get('busy_n3_sib_p3b')):>11s}")
        print("\n== victim instance handler p90 / total p90 in p3b (ratio vs p1); cores in p3b: victim, replicas (node-3), aggressors, HC lent; replicas, actions")
        for r in rows:
            print(f"{r['cell']:20s} vic proc90 {f(r.get('v_proc90_p3b_ratio'))}x tot90 {f(r.get('v_tot90_p3b_ratio'))}x | svc tot90 {f(r.get('s_tot90_p3b_ratio'))}x tot99 {f(r.get('s_tot99_p3b_ratio'))}x | "
                  f"cores vic {f(r.get('c_victim_p3b'))} repl {f(r.get('c_ovf_node3_p3b'))} aggr {f(r.get('c_aggr_p3b'), 1)} lent {f(r.get('lent_p3b'))} | "
                  f"replicas {r['replicas_seen']} actions {r['n_actions']} first {f(r.get('first_action_s'), 1)} s | bursts p2/p3 {r.get('n_bursts_p2')}/{r.get('n_bursts_p3')}")
    if args.csv:
        keys = sorted({k for r in rows for k in r if k != "windows"})
        with open(args.csv, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=keys, extrasaction="ignore")
            w.writeheader()
            for r in rows:
                w.writerow({k: r.get(k, "") for k in keys})
        print("wrote", args.csv)


if __name__ == "__main__":
    main()
