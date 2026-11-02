#!/usr/bin/env python3
"""motiv2_plot.py -- figures for the motivation pass 2 (cores needed for the same SLO).

Inputs: the sweep directories written by run-motiv2.sh (one sub-dir per cell,
each with stage3eval_*/runs/run_1/{run_data.json, run_data-overflow-*.json,
mitigation/*}) and the per-sweep report.csv written by motiv2_report.py --csv.

  python3 tools/motiv2_plot.py --root C:/tmp/motiv2/data --out simple-mitigation-1/simulation/results

Figures (png + pdf):
  motiv2_bars.png            per scenario: latency ratio per cell (SLO lines) over consumed cores (stacked victim / replicas)
  motiv2_cores_vs_slo.png    the headline: consumed cores (x) vs the scenario's discriminating latency ratio (y), SLO line
  motiv2_ts_ext.png          sweep A trial 2 time series: handler p90, sibling/victim busy, e_iso + actuator state
  motiv2_ts_int.png          INT time series: service total p90 (pooled), cores per second, handler p90 (blind)
  motiv2_ts_mixed.png        MIXED time series: handler p90, service total p90, sibling busy
"""
import argparse
import csv
import glob
import json
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import motiv2_report as R  # noqa: E402

C_NONE, C_HC, C_REP, C_BOTH = "#777777", "#0077BB", "#EE7733", "#009988"
MARK = {"": "o", "samecores": "o", "othercores": "s", "othernode": "^"}
PLACE_LABEL = {"samecores": "same cores", "othercores": "other cores", "othernode": "other node"}
TICK_LABEL = {"samecores": "same\ncores", "othercores": "other\ncores", "othernode": "other\nnode"}


def family(arm):
    if arm == "none":
        return "none", C_NONE
    if arm.startswith("hcrep"):
        return "hc + replicas", C_BOTH
    if arm.startswith("hc"):
        return "harvesting", C_HC
    return "replication", C_REP


def read_report(root, sweep):
    rows = {}
    with open(os.path.join(root, sweep, "report.csv")) as f:
        for r in csv.DictReader(f):
            rows[r["cell"]] = {k: (float(v) if v not in ("", "nan") and _isnum(v) else v) for k, v in r.items()}
    return rows


def _isnum(s):
    try:
        float(s)
        return True
    except ValueError:
        return False


def cores(r):
    return r["c_victim"], r.get("c_overflow", 0.0) or 0.0, r.get("c_overflow_offnode", 0.0) or 0.0


def split_cell(cell):
    """'rep3-othercores' -> ('rep3', 'othercores'); 'hc-bang' -> ('hc-bang', '')."""
    arm, _, place = cell.rpartition("-")
    return (arm, place) if place in PLACE_LABEL else (cell, "")


def label(cell):
    arm, place = split_cell(cell)
    return arm + ("\n" + TICK_LABEL[place] if place else "")


# ----------------------------------------------------------------------------- bars
def fig_bars(root, out):
    A1, A2 = read_report(root, "motiv2"), read_report(root, "motiv2-t2")
    INT, MIX = read_report(root, "motiv2-int"), read_report(root, "motiv2-mixed")
    cells_a = ["none", "hc-bang", "hc-hold", "hc-iso"] + ["rep%d-%s" % (k, p) for k in (1, 2, 3)
                                                          for p in ("samecores", "othercores", "othernode")]
    cells_i = ["none", "hc-hold", "rep1f-othercores", "rep1f-othernode", "rep2f-othercores", "rep2f-othernode",
               "rep3f-othercores", "rep3f-othernode", "rep3f-samecores"]
    cells_m = ["none", "hc-bang", "hc-hold", "rep3f-othercores", "rep3f-othernode", "hcrep3-othercores", "hcrep3-othernode"]

    fig, axes = plt.subplots(2, 3, figsize=(17, 7.2), sharex="col", gridspec_kw=dict(height_ratios=[2.2, 1.2], width_ratios=[13, 9, 7]))

    # --- A: handler p90 ratio, two trials
    ax = axes[0, 0]
    x = np.arange(len(cells_a))
    for i, c in enumerate(cells_a):
        col = family(c.split("-")[0])[1]
        if c in A1:
            ax.bar(x[i] - 0.2, A1[c]["v_proc90_ratio"], 0.38, color=col, alpha=0.45, edgecolor=col)
        if c in A2:
            ax.bar(x[i] + 0.2, A2[c]["v_proc90_ratio"], 0.38, color=col)
    ax.axhline(1.2, color="k", ls=":", lw=1); ax.axhline(1.5, color="k", ls="--", lw=1)
    ax.text(len(cells_a) - 0.5, 1.21, "1.2x", ha="right", va="bottom", fontsize=8)
    ax.text(len(cells_a) - 0.5, 1.51, "1.5x", ha="right", va="bottom", fontsize=8)
    ax.set_ylabel("handler p90, armed bursts / p1")
    ax.set_title("A. extrinsic 10 s bursts, 3-P victim (light = trial 1, dark = trial 2)", fontsize=10, loc="left")
    ax.set_ylim(0, 3.2)
    ax = axes[1, 0]
    for i, c in enumerate(cells_a):
        r = A2.get(c) or A1.get(c)
        v, o, on = cores(r)
        ax.bar(x[i], v, 0.6, color="#444444")
        ax.bar(x[i], o, 0.6, bottom=v, color=C_REP)
        ax.bar(x[i], on, 0.6, bottom=v + o, color=C_REP, hatch="//", edgecolor="white")
    ax.set_xticks(x); ax.set_xticklabels([label(c) for c in cells_a], fontsize=7.5)
    ax.set_ylabel("consumed cores\n(armed bursts)")

    # --- INT: service total p90 ratio (log)
    ax = axes[0, 1]
    x = np.arange(len(cells_i))
    for i, c in enumerate(cells_i):
        col = family(c.split("-")[0])[1]
        ax.bar(x[i], INT[c]["s_tot90_ratio"], 0.6, color=col)
    ax.set_yscale("log"); ax.axhline(1.5, color="k", ls="--", lw=1); ax.axhline(1.0, color="k", lw=0.5)
    ax.text(len(cells_i) - 0.5, 1.55, "1.5x", ha="right", va="bottom", fontsize=8)
    ax.set_ylabel("service total p90, p3 / p1 (pooled over replicas)")
    ax.set_title("B. intrinsic overload, 1-P victim, 11000 rps (no aggressors)", fontsize=10, loc="left")
    ax.set_ylim(0.4, 20)
    ax = axes[1, 1]
    for i, c in enumerate(cells_i):
        v, o, on = cores(INT[c])
        ax.bar(x[i], v, 0.6, color="#444444"); ax.bar(x[i], o, 0.6, bottom=v, color=C_REP)
        ax.bar(x[i], on, 0.6, bottom=v + o, color=C_REP, hatch="//", edgecolor="white")
    ax.set_xticks(x); ax.set_xticklabels([label(c) for c in cells_i], fontsize=7.5)

    # --- MIXED: handler and total
    ax = axes[0, 2]
    x = np.arange(len(cells_m))
    for i, c in enumerate(cells_m):
        col = family(c.split("-")[0])[1]
        ax.bar(x[i] - 0.2, MIX[c]["v_proc90_ratio"], 0.38, color=col, alpha=0.45, edgecolor=col)
        ax.bar(x[i] + 0.2, MIX[c]["s_tot90_ratio"], 0.38, color=col)
    ax.set_yscale("log"); ax.axhline(1.2, color="k", ls=":", lw=1); ax.axhline(1.5, color="k", ls="--", lw=1)
    ax.axhline(1.0, color="k", lw=0.5)
    ax.text(len(cells_m) - 0.5, 1.21, "1.2x handler", ha="right", va="bottom", fontsize=8)
    ax.text(len(cells_m) - 0.5, 1.55, "1.5x total", ha="right", va="bottom", fontsize=8)
    ax.set_ylabel("ratio to p1 (light = handler p90, dark = service total p90)")
    ax.set_title("C. mixed: 1-P overload + 10 s bursts", fontsize=10, loc="left")
    ax.set_ylim(0.4, 20)
    ax = axes[1, 2]
    for i, c in enumerate(cells_m):
        v, o, on = cores(MIX[c])
        ax.bar(x[i], v, 0.6, color="#444444"); ax.bar(x[i], o, 0.6, bottom=v, color=C_REP)
        ax.bar(x[i], on, 0.6, bottom=v + o, color=C_REP, hatch="//", edgecolor="white")
    ax.set_xticks(x); ax.set_xticklabels([label(c) for c in cells_m], fontsize=7.5)

    from matplotlib.patches import Patch
    fig.legend(handles=[Patch(color=C_NONE, label="no mitigation"), Patch(color=C_HC, label="harvesting (HC)"),
                        Patch(color=C_REP, label="replication"), Patch(color=C_BOTH, label="HC + replicas"),
                        Patch(color="#444444", label="cores: victim"), Patch(facecolor=C_REP, label="cores: replicas on node-4"),
                        Patch(facecolor=C_REP, hatch="//", edgecolor="white", label="cores: replicas on node-3")],
               loc="lower center", ncol=7, fontsize=8.5, frameon=False, bbox_to_anchor=(0.5, -0.01))
    fig.suptitle("Motivation pass 2 (sm110p, July layout): latency vs consumed cores per mitigation and placement", fontsize=11)
    fig.tight_layout(rect=(0, 0.05, 1, 0.97))
    save(fig, out, "motiv2_bars")


# ----------------------------------------------------------------------------- scatter
def fig_scatter(root, out):
    A1, A2 = read_report(root, "motiv2"), read_report(root, "motiv2-t2")
    INT, MIX = read_report(root, "motiv2-int"), read_report(root, "motiv2-mixed")
    panels = [("A. extrinsic bursts: handler p90 ratio (mean of 2 trials)", "v_proc90_ratio", 1.2, 1.5, (A1, A2)),
              ("B. intrinsic overload: service total p90 ratio", "s_tot90_ratio", None, 1.5, (INT,)),
              ("C. mixed: service total p90 ratio (handler ratio in label)", "s_tot90_ratio", None, 1.5, (MIX,))]
    fig, axes = plt.subplots(1, 3, figsize=(16, 4.8))
    for ax, (title, key, slo1, slo2, reps) in zip(axes, panels):
        cells = sorted(set().union(*[set(r) for r in reps]))
        placed = []
        for c in cells:
            rs = [r[c] for r in reps if c in r]
            y = np.mean([r[key] for r in rs])
            xs = np.mean([sum(cores(r)) for r in rs])
            arm, place = split_cell(c)
            fam, col = family(arm)
            ax.scatter(xs, y, s=70, color=col, marker=MARK[place], edgecolor="k", lw=0.5, zorder=3)
            txt = c
            if key == "s_tot90_ratio" and "v_proc90_ratio" in rs[0]:
                txt += "  (h %.2f)" % np.mean([r["v_proc90_ratio"] for r in rs])
            dy = 3 + 9 * sum(1 for (px, py) in placed if abs(px - xs) < 0.12 and abs(np.log(py / y)) < 0.08)
            placed.append((xs, y))
            ax.annotate(txt, (xs, y), textcoords="offset points", xytext=(6, dy), fontsize=6.5)
        if slo1:
            ax.axhline(slo1, color="k", ls=":", lw=1)
        ax.axhline(slo2, color="k", ls="--", lw=1)
        ax.axhline(1.0, color="k", lw=0.5)
        ax.set_yscale("log")
        ax.set_xlabel("consumed cores, victim + replicas (armed window)")
        ax.set_title(title, fontsize=9.5, loc="left")
        ax.grid(alpha=0.3, which="both")
    axes[0].set_ylabel("latency ratio to p1 (log)")
    axes[0].set_ylim(0.8, 3.5); axes[1].set_ylim(0.4, 20); axes[2].set_ylim(0.8, 20)
    from matplotlib.lines import Line2D
    h = [Line2D([], [], marker="o", ls="", color=C_NONE, label="no mitigation"), Line2D([], [], marker="o", ls="", color=C_HC, label="harvesting"),
         Line2D([], [], marker="o", ls="", color=C_REP, label="replication"), Line2D([], [], marker="o", ls="", color=C_BOTH, label="HC + replicas"),
         Line2D([], [], marker="o", ls="", color="w", markeredgecolor="k", label="same cores / none"),
         Line2D([], [], marker="s", ls="", color="w", markeredgecolor="k", label="other cores"),
         Line2D([], [], marker="^", ls="", color="w", markeredgecolor="k", label="other node")]
    fig.legend(handles=h, loc="lower center", ncol=7, fontsize=8.5, frameon=False, bbox_to_anchor=(0.5, -0.02))
    fig.suptitle("Cores needed for the same SLO: dashed = 1.5x, dotted = 1.2x; below the line = SLO met", fontsize=11)
    fig.tight_layout(rect=(0, 0.06, 1, 0.95))
    save(fig, out, "motiv2_cores_vs_slo")


# ----------------------------------------------------------------------------- time series
def load_cell(cell_dir, target_node="node-4"):
    run = sorted(glob.glob(os.path.join(cell_dir, "stage3eval_*", "runs", "run_1")))[-1]
    mdir = os.path.join(run, "mitigation")
    t0 = int(open(os.path.join(run, "started_epoch_ns.txt")).read()) / 1e9
    arm = 80.0
    for p in (os.path.join(run, "armed_epoch_ns.txt"), os.path.join(mdir, "armed_epoch_ns.txt")):
        if os.path.isfile(p):
            arm = int(open(p).read()) / 1e9 - t0
            break
    vic = R.load_run(os.path.join(run, "run_data.json"))
    ovf = [row for f in glob.glob(os.path.join(run, "run_data-overflow-*.json")) for row in R.load_run(f)]

    def per_sec(rows, idx):
        b = {}
        for r in rows:
            b.setdefault(int(r[0] - t0), []).append(r)
        ts = sorted(b)
        return (np.array(ts, float) + 0.5,
                np.array([R.wmean([r[idx] for r in b[s]], [r[1] for r in b[s]]) for s in ts]))

    out = dict(arm=arm, t0=t0)
    out["t_h"], out["h90"] = per_sec(vic, 3)
    out["t_tv"], out["tv90"] = per_sec(vic, 5)
    out["t_ts"], out["ts90"] = per_sec(vic + ovf, 5)
    # scores
    sc_t, sc_e = [], []
    for f in glob.glob(os.path.join(mdir, "*.scores.csv")):
        for r in csv.DictReader(open(f)):
            try:
                sc_t.append(int(r["unix_ms"]) / 1e3 - t0); sc_e.append(float(r["e_iso"]))
            except (KeyError, ValueError):
                pass
    o = np.argsort(sc_t)
    out["sc_t"], out["sc_e"] = np.array(sc_t)[o], np.array(sc_e)[o]
    # actuator state
    hc = [(0.0, 0)]
    reps = [(0.0, 0)]
    for f in glob.glob(os.path.join(mdir, "*.ctrl.log")):
        for line in open(f, errors="replace"):
            if '"formula: hc' not in line and '"reason":"scaled"' not in line:
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            t = R.ts_epoch(e["time"]) - t0
            if e.get("msg") == "formula: hc apply":
                hc.append((t, 1))
            elif e.get("msg") == "formula: hc restore":
                hc.append((t, 0))
            elif e.get("msg") == "action" and e.get("kind") == "horizontal" and e.get("applied"):
                reps.append((t, int((e.get("after") or {}).get("replicas", 0))))
    out["hc"], out["reps"] = sorted(hc), sorted(reps)
    # per-second CPU
    uids = R.load_uids(mdir)
    per_key = {}
    p = os.path.join(mdir, "cpu_usage.csv")
    if os.path.isfile(p):
        for row in csv.DictReader(open(p)):
            per_key.setdefault(row["key"], []).append((int(row["unix_ms"]) / 1e3 - t0, int(row["a"]), int(row["b"])))
    for f in glob.glob(os.path.join(cell_dir, "cpu_usage-*.csv")):
        for row in csv.DictReader(open(f)):
            per_key.setdefault(row["key"] + "@other", []).append((int(row["unix_ms"]) / 1e3 - t0, int(row["a"]), int(row["b"])))
    busy = {}      # cpu -> (t, frac)
    cls_cores = {}  # class -> dict(sec -> cores)
    for key, rows in per_key.items():
        rows.sort()
        if key.startswith("cpu") and "@" not in key:
            cpu = int(key[3:])
            t = np.array([(a[0] + b[0]) / 2 for a, b in zip(rows, rows[1:])])
            fr = np.array([(b[1] - a[1]) / max(b[2] - a[2], 1) for a, b in zip(rows, rows[1:])])
            busy[cpu] = (t, fr)
        elif key.startswith("pod:"):
            uid = key[4:].split("@")[0]
            ns, name, node = uids.get(uid, ("?", uid[:8], "?"))
            cls = R.pod_class(ns, name)
            if key.endswith("@other") or (node not in (target_node, "?")):
                cls += "@other"
            d = cls_cores.setdefault(cls, {})
            for a, b in zip(rows, rows[1:]):
                dt = b[0] - a[0]
                if 0 < dt <= 3:
                    d[int(a[0])] = d.get(int(a[0]), 0.0) + (b[1] - a[1]) / 1e6 / dt
    def grp(cpus):
        ts = [busy[c][0] for c in cpus if c in busy]
        if not ts:
            return np.array([]), np.array([])
        n = min(len(t) for t in ts)
        return ts[0][:n], np.mean([busy[c][1][:n] for c in cpus if c in busy], axis=0)
    out["sib_t"], out["sib"] = grp([2, 3, 4])
    out["vic_t"], out["vic"] = grp([18, 19, 20])
    out["cores"] = {k: (np.array(sorted(v)) + 0.5, np.array([v[s] for s in sorted(v)])) for k, v in cls_cores.items()}
    return out


def shade_bursts(ax, arm, burst=10, idle=10, start=20, end=140):
    t = start
    while t < end:
        ax.axvspan(t, min(t + burst, end), color="#bbbbbb", alpha=0.25, lw=0)
        t += burst + idle
    ax.axvline(arm, color="k", ls="--", lw=0.8)


def step(ax, pts, **kw):
    t = [p[0] for p in pts] + [140]
    v = [p[1] for p in pts] + [pts[-1][1]]
    ax.step(t, v, where="post", **kw)


def fig_ts_ext(root, out):
    cells = ["none", "hc-hold", "hc-bang", "rep3-othercores", "rep3-othernode", "rep3-samecores"]
    data = {c: load_cell(os.path.join(root, "motiv2-t2", c)) for c in cells}
    fig, axes = plt.subplots(3, len(cells), figsize=(3.4 * len(cells), 7.6), sharex=True, sharey="row")
    for j, c in enumerate(cells):
        d = data[c]
        col = family(c.split("-")[0])[1]
        ax = axes[0, j]; shade_bursts(ax, d["arm"])
        ax.plot(d["t_h"], d["h90"], color=col, lw=1)
        ax.set_title(c, fontsize=10)
        ax = axes[1, j]; shade_bursts(ax, d["arm"])
        ax.plot(d["sib_t"], d["sib"], color="#CC3311", lw=1, label="siblings 2-4 busy")
        ax.plot(d["vic_t"], d["vic"], color="#444444", lw=1, label="victim threads 18-20 busy")
        for k, (t, v) in d["cores"].items():
            if k.startswith("overflow"):
                ax.plot(t, v / 3.0, color=C_REP, lw=1, label="replica cores / 3" + (" (node-3)" if "@" in k else ""))
        ax = axes[2, j]; shade_bursts(ax, d["arm"])
        ax.plot(d["sc_t"], d["sc_e"], color="#333333", lw=0.7, label="e_iso")
        ax.axhline(0.15, color="k", ls=":", lw=0.8)
        ax2 = ax.twinx()
        if c.startswith("hc"):
            step(ax2, d["hc"], color=C_HC, lw=1.5, label="HC held")
            ax2.set_ylim(-0.1, 3.3); ax2.set_yticks([0, 1])
        elif c.startswith("rep"):
            step(ax2, d["reps"], color=C_REP, lw=1.5, label="replicas")
            ax2.set_ylim(-0.1, 3.3); ax2.set_yticks([0, 1, 2, 3])
        else:
            ax2.set_yticks([])
        if j == len(cells) - 1:
            ax2.set_ylabel("actuator state")
        ax.set_xlabel("time (s)")
    axes[0, 0].set_ylabel("handler p90 (us)\n1 s, count-weighted")
    axes[1, 0].set_ylabel("busy fraction / cores")
    axes[2, 0].set_ylabel("e_iso (theta 0.15 dotted)")
    axes[0, 0].set_ylim(0, 130); axes[1, 0].set_ylim(0, 1.05); axes[2, 0].set_ylim(-0.05, 0.8)
    axes[1, 0].legend(fontsize=7, loc="upper left")
    axes[1, 3].legend(fontsize=7, loc="upper left")
    axes[0, 0].set_xlim(-5, 145)
    fig.suptitle("Sweep A trial 2 (extrinsic 10 s bursts shaded, ARM dashed): what each mitigation changes", fontsize=11)
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    save(fig, out, "motiv2_ts_ext")


def fig_ts_int(root, out):
    cells = ["none", "hc-hold", "rep1f-othercores", "rep1f-othernode", "rep3f-othercores", "rep3f-samecores"]
    data = {c: load_cell(os.path.join(root, "motiv2-int", c)) for c in cells}
    fig, axes = plt.subplots(3, len(cells), figsize=(3.4 * len(cells), 7.6), sharex=True, sharey="row")
    for j, c in enumerate(cells):
        d = data[c]
        col = family(c.split("-")[0])[1]
        ax = axes[0, j]
        ax.axvspan(20, 140, color="#bbbbbb", alpha=0.2, lw=0); ax.axvline(d["arm"], color="k", ls="--", lw=0.8)
        ax.plot(d["t_tv"], d["tv90"], color="#aaaaaa", lw=0.8, label="victim instance")
        ax.plot(d["t_ts"], d["ts90"], color=col, lw=1.2, label="service (pooled)")
        ax.set_yscale("log"); ax.set_title(c, fontsize=10)
        ax = axes[1, j]
        ax.axvspan(20, 140, color="#bbbbbb", alpha=0.2, lw=0); ax.axvline(d["arm"], color="k", ls="--", lw=0.8)
        tot_t, tot = None, None
        for k, (t, v) in sorted(d["cores"].items()):
            if k.startswith("victim"):
                ax.plot(t, v, color="#444444", lw=1, label="victim")
            elif k.startswith("overflow"):
                ax.plot(t, v, color=C_REP, lw=1, label="replicas" + (" (node-3)" if "@" in k else ""))
        ax = axes[2, j]
        ax.axvspan(20, 140, color="#bbbbbb", alpha=0.2, lw=0); ax.axvline(d["arm"], color="k", ls="--", lw=0.8)
        ax.plot(d["t_h"], d["h90"], color=col, lw=1)
        ax.set_xlabel("time (s)")
    axes[0, 0].set_ylabel("total p90 (ms, log)"); axes[1, 0].set_ylabel("cores (per second)")
    axes[2, 0].set_ylabel("handler p90 (us)"); axes[2, 0].set_ylim(0, 60); axes[1, 0].set_ylim(0, 3.2)
    axes[0, 0].legend(fontsize=7, loc="upper left"); axes[1, 2].legend(fontsize=7, loc="upper left")
    axes[0, 0].set_xlim(-5, 145)
    fig.suptitle("INT (1-P victim, 800 + 10200 rps from t = 20 s shaded, ARM dashed): the overload is invisible to the handler", fontsize=11)
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    save(fig, out, "motiv2_ts_int")


def fig_ts_mixed(root, out):
    cells = ["none", "hc-hold", "rep3f-othercores", "rep3f-othernode", "hcrep3-othercores", "hcrep3-othernode"]
    data = {c: load_cell(os.path.join(root, "motiv2-mixed", c)) for c in cells}
    fig, axes = plt.subplots(3, len(cells), figsize=(3.4 * len(cells), 7.6), sharex=True, sharey="row")
    for j, c in enumerate(cells):
        d = data[c]
        col = family(c.split("-")[0])[1]
        ax = axes[0, j]; shade_bursts(ax, d["arm"])
        ax.plot(d["t_h"], d["h90"], color=col, lw=1); ax.set_title(c, fontsize=10)
        ax = axes[1, j]; shade_bursts(ax, d["arm"])
        ax.plot(d["t_tv"], d["tv90"], color="#aaaaaa", lw=0.8, label="victim instance")
        ax.plot(d["t_ts"], d["ts90"], color=col, lw=1.2, label="service (pooled)")
        ax.set_yscale("log")
        ax = axes[2, j]; shade_bursts(ax, d["arm"])
        ax.plot(d["sib_t"], d["sib"], color="#CC3311", lw=1, label="siblings 2-4 busy")
        for k, (t, v) in d["cores"].items():
            if k.startswith("overflow"):
                ax.plot(t, v / 3.0, color=C_REP, lw=1, label="replica cores / 3" + (" (node-3)" if "@" in k else ""))
        ax.set_xlabel("time (s)")
    axes[0, 0].set_ylabel("handler p90 (us)"); axes[0, 0].set_ylim(0, 90)
    axes[1, 0].set_ylabel("total p90 (ms, log)"); axes[2, 0].set_ylabel("busy fraction / cores"); axes[2, 0].set_ylim(0, 1.05)
    axes[1, 0].legend(fontsize=7, loc="upper left"); axes[2, 2].legend(fontsize=7, loc="upper left")
    axes[0, 0].set_xlim(-5, 145)
    fig.suptitle("MIXED (1-P overload from t = 20 s + 10 s bursts shaded, ARM dashed): harvesting fixes the handler, replication fixes the queue", fontsize=11)
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    save(fig, out, "motiv2_ts_mixed")


def save(fig, out, name):
    os.makedirs(out, exist_ok=True)
    fig.savefig(os.path.join(out, name + ".png"), dpi=150, bbox_inches="tight")
    fig.savefig(os.path.join(out, name + ".pdf"), bbox_inches="tight")
    plt.close(fig)
    print("wrote", os.path.join(out, name + ".png"))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", required=True, help="dir holding motiv2/ motiv2-t2/ motiv2-int/ motiv2-short/ motiv2-mixed/")
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", default="", help="comma list of figure names")
    a = ap.parse_args()
    figs = dict(bars=fig_bars, scatter=fig_scatter, ts_ext=fig_ts_ext, ts_int=fig_ts_int, ts_mixed=fig_ts_mixed)
    for k, fn in figs.items():
        if not a.only or k in a.only.split(","):
            fn(a.root, a.out)


if __name__ == "__main__":
    main()
