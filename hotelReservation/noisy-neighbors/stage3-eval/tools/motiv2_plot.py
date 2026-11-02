#!/usr/bin/env python3
"""motiv2_plot.py -- figures for the motivation pass 2 (cores needed for the same SLO).

Inputs: the sweep directories written by run-motiv2.sh (one sub-dir per cell,
each with stage3eval_*/runs/run_1/{run_data.json, run_data-overflow-*.json,
mitigation/*}) and the per-sweep report.csv written by motiv2_report.py --csv
(only for the consumed-cores rows).

  python3 tools/motiv2_plot.py --root C:/tmp/motiv2/data --out simple-mitigation-1/simulation/results/2026-11-motiv2-sm110p

Conventions (user, 2026-11-02): raw numbers on every axis (handler p90 in us,
service total p90 in ms, cores); per cell two bars -- quiet (p1) and under
contention with the mitigation (p3 window) -- with the p3/p1 ratio written on
the second bar; repeated trials collapse to one bar with a min-max error
bar; one SLO line (--slo, default 1.5x of the quiet p1 mean) at its absolute
value; the MIXED scenario and the cores-vs-SLO scatter are not plotted.

Figures (png + pdf):
  motiv2_bars      A (extrinsic bursts) and B (intrinsic steady): per cell the quiet (p1) and the
                   under-contention-with-mitigation (p3 window) latency, over the cores consumed meanwhile;
                   rep6 cells from data/motiv2-uncap are appended when present
  motiv2_ts_ext    one column per cell, two rows: handler p90; cores consumed by victim + replicas (+ the
                   victim cores HC lends to the aggressors, from the balancer log)
  motiv2_ts_int    one column per cell, two rows: service total p90; cores consumed by victim + replicas
  (--only ts_mixed still renders the MIXED time series)
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

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.lines import Line2D
from matplotlib.patches import Patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import motiv2_report as R  # noqa: E402

C_NONE, C_HC, C_REP, C_BOTH = "#777777", "#0077BB", "#EE7733", "#009988"
C_VIC, C_SIB, C_QUIET, C_P2 = "#000000", "#CC3311", "#d9d9d9", "#9e9e9e"
PLACE_LABEL = {"samecores": "same cores", "othercores": "other cores", "othernode": "other node"}
TICK_LABEL = {"samecores": "same\ncores", "othercores": "other\ncores", "othernode": "other\nnode"}
P1 = [(2, 20)]
BURST_P2 = [(20, 30), (40, 50), (60, 70)]
BURST_P3 = [(80, 90), (100, 110), (120, 130)]
STEADY_P2 = [(30, 80)]
STEADY_P3 = [(90, 140)]


def family(arm):
    if arm == "none":
        return "none", C_NONE
    if arm.startswith("hcrep"):
        return "hc + replicas", C_BOTH
    if arm.startswith("hc"):
        return "harvesting", C_HC
    return "replication", C_REP


def split_cell(cell):
    """'rep3-othercores' -> ('rep3', 'othercores'); 'hc-bang' -> ('hc-bang', '')."""
    arm, _, place = cell.rpartition("-")
    return (arm, place) if place in PLACE_LABEL else (cell, "")


def label(cell):
    arm, place = split_cell(cell)
    return arm + ("\n" + TICK_LABEL[place] if place else "")


def _num(v):
    try:
        return float(v)
    except ValueError:
        return v


def read_report(root, sweep):
    with open(os.path.join(root, sweep, "report.csv")) as f:
        return {r["cell"]: {k: _num(v) for k, v in r.items()} for r in csv.DictReader(f)}


def cores(r):
    return r["c_victim"], r.get("c_overflow", 0.0) or 0.0, r.get("c_overflow_offnode", 0.0) or 0.0


def run_dir(cell_dir):
    return sorted(glob.glob(os.path.join(cell_dir, "stage3eval_*", "runs", "run_1")))[-1]


def phase_lat(cell_dir, p2, p3):
    """Victim handler p90 (us) and service total p90 (ms, pooled over replicas) in p1 / p2 / p3."""
    run = run_dir(cell_dir)
    t0 = int(open(os.path.join(run, "started_epoch_ns.txt")).read()) / 1e9
    vic = R.load_run(os.path.join(run, "run_data.json"))
    ovf = [row for f in glob.glob(os.path.join(run, "run_data-overflow-*.json")) for row in R.load_run(f)]
    out = {}
    for tag, spans in (("p1", P1), ("p2", p2), ("p3", p3)):
        out["h_" + tag] = R.lat_stats(vic, t0, spans)["proc90"]
        st = R.lat_stats(vic + ovf, t0, spans)
        out["t_" + tag] = st["tot90"]
        out["t50_" + tag] = st["tot50"]
    return out


# ----------------------------------------------------------------------------- bars
def _two_bars(ax, cells, trials, key, unit, slo, log=False):
    """Per cell: quiet (p1, light grey) and mitigated (p3 window, mitigation colour;
    mean over trials, min-max error bar, p3/p1 ratio written above)."""
    w = 0.38
    x = np.arange(len(cells))
    base = np.mean([t[c][key + "_p1"] for t in trials for c in cells if c in t])
    top = 0
    for i, c in enumerate(cells):
        col = family(split_cell(c)[0])[1]
        q = [t[c][key + "_p1"] for t in trials if c in t]
        v = [t[c][key + "_p3"] for t in trials if c in t]
        m, lo, hi = np.mean(v), np.min(v), np.max(v)
        ax.bar(x[i] - w / 2, np.mean(q), w, color=C_QUIET, edgecolor="#777777", lw=0.5)
        ax.bar(x[i] + w / 2, m, w, color=col, yerr=[[m - lo], [hi - m]] if hi > lo else None,
               capsize=2.5, error_kw=dict(lw=0.9, ecolor="k"))
        ax.text(x[i] + w / 2, hi * (1.07 if log else 1) + (0 if log else 0.015 * base), "%.2fx" % (m / base),
                ha="center", va="bottom", fontsize=7.5)
        top = max(top, hi)
    ax.axhline(slo * base, color="k", ls="--", lw=1)
    ax.text(len(cells) - 0.45, slo * base, "SLO %.1fx quiet = %.3g %s" % (slo, slo * base, unit),
            ha="right", va="bottom", fontsize=7.5)
    if log:
        ax.set_yscale("log")
        ax.set_ylim(base * 0.45, top * 1.7)
    else:
        ax.set_ylim(0, top * 1.12)
    ax.set_xticks(x)
    ax.set_xticklabels([label(c) for c in cells], fontsize=8)


HC_PRIMARY_CORES = 3   # HC_VICTIM_CPULIST=18,19,20: the physical cores HC reserves for the victim
SUB = dict(fontsize=7.5, color="#555555")


def title2(ax, main, sub):
    """Concise panel title; the setup detail as a smaller second line."""
    ax.set_title(main, fontsize=10.5, loc="left", pad=16)
    ax.text(0, 1.01, sub, transform=ax.transAxes, ha="left", va="bottom", **SUB)


def suptitle2(fig, main, sub, y=0.985):
    fig.suptitle(main, fontsize=12, y=y)
    fig.text(0.5, y - 0.035, sub, ha="center", va="top", **SUB)


def ylabel2(ax, main, sub):
    """Concise axis label; the measurement detail as a small note inside the axes."""
    ax.set_ylabel(main, fontsize=9.5)
    ax.text(0.01, 0.985, sub, transform=ax.transAxes, ha="left", va="top", **SUB)


def hc_lent(root, sweep, cell, spans):
    """Mean number of the victim's cores the HC balancer lends to the aggressors over the
    spans, for one trial (nan without a balancer log)."""
    d = os.path.join(root, sweep, cell)
    if not os.path.isdir(d):
        return float("nan")
    run = run_dir(d)
    t0 = int(open(os.path.join(run, "started_epoch_ns.txt")).read()) / 1e9
    t, v = balancer_lent(os.path.join(run, "mitigation"), t0)
    if not len(t):
        return float("nan")
    sel = np.array([R.in_any(x, spans) for x in t])
    return v[sel].mean() if sel.any() else float("nan")


def _cores_panel(ax, cells, reps, root=None, sweeps=(), spans=()):
    """Stacked cores per cell: victim consumed; replicas consumed (node-4 / node-3);
    for the HC cells the cores HC reserves for the victim but leaves idle
    (HC_PRIMARY_CORES - lent to the aggressors - used by the victim)."""
    x = np.arange(len(cells))
    is_hc = lambda c: split_cell(c)[0].startswith("hc")

    def per_trial(c):
        """(victim, replicas node-4, replicas node-3, HC reserved idle, lent) per trial."""
        rows = []
        for sw in sweeps:
            r = reps.get(sw)
            if r is None or c not in r:
                continue
            v, o, on = cores(r[c])
            if split_cell(c)[1].startswith("othernode") and on == 0:
                continue   # other-node replicas not sampled in this trial (sweep A trial 1 had no node-3 sampler)
            idle, lent = 0.0, float("nan")
            if is_hc(c) and root is not None:
                lent = hc_lent(root, sw, c, spans)
                if not np.isnan(lent):
                    idle = max(0.0, HC_PRIMARY_CORES - lent - v)
            rows.append((v, o, on, idle, lent))
        return np.array(rows) if rows else None

    ref = per_trial("none")
    ref_tot = ref[:, :4].sum(axis=1).mean() if ref is not None else float("nan")
    top = 0
    for i, c in enumerate(cells):
        t = per_trial(c)
        if t is None:
            continue
        v, o, on, idle = t[:, :4].mean(axis=0)
        tots = t[:, :4].sum(axis=1)
        m, lo, hi = tots.mean(), tots.min(), tots.max()
        ax.bar(x[i], v, 0.6, color="#444444")
        ax.bar(x[i], idle, 0.6, bottom=v, color=C_HC, alpha=0.55)
        ax.bar(x[i], o, 0.6, bottom=v + idle, color=C_REP)
        ax.bar(x[i], on, 0.6, bottom=v + idle + o, color=C_REP, hatch="//", edgecolor="white")
        if hi > lo:
            ax.errorbar(x[i], m, yerr=[[m - lo], [hi - m]], fmt="none", ecolor="k", lw=0.9, capsize=2.5, zorder=4)
        if idle > 0:
            ax.text(x[i], v + idle / 2, "lent\n%.1f" % np.nanmean(t[:, 4]), ha="center", va="center", fontsize=6.5, color="white")
        ax.text(x[i], hi + 0.04, "%.2f\n(%.1fx)" % (m, m / ref_tot), ha="center", va="bottom", fontsize=7)
        top = max(top, hi)
    ax.set_xticks(x)
    ax.set_xticklabels([label(c) for c in cells], fontsize=8)
    ax.set_ylim(0, max(3.4, top * 1.25))


def _trials(root, sweeps, cells, p2, p3):
    out = []
    for sw in sweeps:
        d = {c: phase_lat(os.path.join(root, sw, c), p2, p3) for c in cells if os.path.isdir(os.path.join(root, sw, c))}
        if d:
            out.append(d)
    return out


def _reports(root, sweeps):
    return {sw: read_report(root, sw) for sw in sweeps if os.path.isfile(os.path.join(root, sw, "report.csv"))}


def fig_bars(root, out, slo=1.5):
    # hc-iso (hc-hold + HC's internal idle-core target) is excluded (user, 2026-11-02)
    cells_a = ["none", "hc-bang", "hc-hold"] + ["rep%d-%s" % (k, p) for k in (1, 2, 3)
                                                          for p in ("samecores", "othercores", "othernode")]
    # uncapped replication cells (N_MAX=6, data/motiv2-uncap), if they have been run
    cells_a += [c for c in ("rep6-othercores", "rep6-othernodewide") if os.path.isdir(os.path.join(root, "motiv2-uncap", c))]
    cells_i = ["none", "hc-hold", "rep1f-othercores", "rep1f-othernode", "rep2f-othercores", "rep2f-othernode",
               "rep3f-othercores", "rep3f-othernode", "rep3f-samecores"]
    sweeps_a = ("motiv2", "motiv2-t2", "motiv2-uncap")
    trials_a = _trials(root, sweeps_a, cells_a, BURST_P2, BURST_P3)
    sweeps_i = ("motiv2-int", "motiv2-int-t2")
    trials_i = _trials(root, sweeps_i, cells_i, STEADY_P2, STEADY_P3)
    rep_a, rep_i = _reports(root, sweeps_a), _reports(root, sweeps_i)

    fig, axes = plt.subplots(2, 2, figsize=(17, 7.8), sharex="col",
                             gridspec_kw=dict(height_ratios=[2.3, 1.2], width_ratios=[len(cells_a), 9]))
    _two_bars(axes[0, 0], cells_a, trials_a, "h", "us", slo)
    ylabel2(axes[0, 0], "handler p90 (us)", "victim instance, mitigation-enabled bursts; ratio = vs quiet")
    title2(axes[0, 0], "A. Extrinsic bursts",
           "3-P victim on threads 18-20, SN/SS aggressor bursts 10 s on / 10 s off; mean of 2 trials, error bar = min-max")
    _cores_panel(axes[1, 0], cells_a, rep_a, root, sweeps_a, BURST_P3)
    ylabel2(axes[1, 0], "cores taken", "consumed + reserved idle, mitigation-enabled window; mean, min-max; (x) = vs none")
    _two_bars(axes[0, 1], cells_i, trials_i, "t50", "ms", slo, log=True)
    ylabel2(axes[0, 1], "service total p50 (ms, log)", "pooled over victim + replicas; ratio = vs quiet")
    title2(axes[0, 1], "B. Intrinsic steady",
           "1-P victim on thread 18, 11000 rps offered from t = 20 s, no aggressors; %d trial%s"
           % (len(trials_i), "s, error bar = min-max" if len(trials_i) > 1 else ""))
    ylabel2(axes[1, 1], "", "")
    _cores_panel(axes[1, 1], cells_i, rep_i, root, sweeps_i, STEADY_P3)
    fig.legend(handles=[Patch(facecolor=C_QUIET, edgecolor="#777777", label="quiet (p1, 0-20 s)"),
                        Patch(color=C_NONE, label="under contention: no mitigation"),
                        Patch(color=C_HC, label="under contention: harvesting (HC)"),
                        Patch(color=C_REP, label="under contention: replication"),
                        Line2D([], [], color="k", ls="--", label="SLO"),
                        Patch(color="#444444", label="cores: victim"),
                        Patch(color=C_HC, alpha=0.55, label="cores: reserved for the victim by HC, idle (3 - lent - used)"),
                        Patch(facecolor=C_REP, label="cores: replicas on node-4"),
                        Patch(facecolor=C_REP, hatch="//", edgecolor="white", label="cores: replicas on node-3")],
               loc="lower center", ncol=5, fontsize=8.5, frameon=False, bbox_to_anchor=(0.5, -0.03))
    suptitle2(fig, "Latency and cores taken per mitigation",
              "sm110p, SMT on, 2.4 GHz, July layout; per cell: quiet (p1) vs under contention with the mitigation enabled (p3)")
    fig.tight_layout(rect=(0, 0.05, 1, 0.94))
    save(fig, out, "motiv2_bars")


# ----------------------------------------------------------------------------- time series
def balancer_lent(mdir, t0):
    """Victim cores lent to the aggressors by the HC balancer, per second, from
    hc-balancer.tgz/balancer.log (CoresAllocatedToSecondary, CLOCK_MONOTONIC stamps);
    the first row is anchored at the controller's 'hc: balancer started' epoch (log_dir name)."""
    tgz = os.path.join(mdir, "hc-balancer.tgz")
    if not os.path.isfile(tgz):
        return np.array([]), np.array([])
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
        return np.array([]), np.array([])
    t = tarfile.open(tgz)
    name = [n for n in t.getnames() if n.endswith("balancer.log")][0]
    rows = []
    for line in io.TextIOWrapper(t.extractfile(name), errors="replace"):
        p = line.strip().split(",")
        if len(p) < 10 or not p[0].isdigit():
            continue
        rows.append((int(p[0]) + int(p[1]) / 1e9, int(p[9])))
    if not rows:
        return np.array([]), np.array([])
    mono0 = rows[0][0]
    ts = np.array([r[0] - mono0 + start for r in rows])
    val = np.array([r[1] for r in rows], float)
    # time-weighted per-second mean (the allocation holds until the next rebalance)
    grid = np.arange(ts[0], ts[-1], 0.01)
    v = val[np.clip(np.searchsorted(ts, grid, side="right") - 1, 0, len(val) - 1)]
    sec = np.floor(grid)
    us = np.unique(sec)
    return us + 0.5, np.array([v[sec == s].mean() for s in us])


def load_cell(cell_dir, target_node="node-4"):
    run = run_dir(cell_dir)
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
    _, out["ts50"] = per_sec(vic + ovf, 4)
    sc_t, sc_e = [], []
    for f in glob.glob(os.path.join(mdir, "*.scores.csv")):
        for r in csv.DictReader(open(f)):
            try:
                sc_t.append(int(r["unix_ms"]) / 1e3 - t0); sc_e.append(float(r["e_iso"]))
            except (KeyError, ValueError):
                pass
    o = np.argsort(sc_t)
    out["sc_t"], out["sc_e"] = np.array(sc_t)[o], np.array(sc_e)[o]
    out["lent_t"], out["lent"] = balancer_lent(mdir, t0)
    uids = R.load_uids(mdir)
    per_key = {}
    p = os.path.join(mdir, "cpu_usage.csv")
    if os.path.isfile(p):
        for row in csv.DictReader(open(p)):
            per_key.setdefault(row["key"], []).append((int(row["unix_ms"]) / 1e3 - t0, int(row["a"]), int(row["b"])))
    for f in glob.glob(os.path.join(cell_dir, "cpu_usage-*.csv")):
        for row in csv.DictReader(open(f)):
            per_key.setdefault(row["key"] + "@other", []).append((int(row["unix_ms"]) / 1e3 - t0, int(row["a"]), int(row["b"])))
    busy, cls_cores = {}, {}
    for key, rows in per_key.items():
        rows.sort()
        if key.startswith("cpu") and "@" not in key:
            t = np.array([(a[0] + b[0]) / 2 for a, b in zip(rows, rows[1:])])
            fr = np.array([(b[1] - a[1]) / max(b[2] - a[2], 1) for a, b in zip(rows, rows[1:])])
            busy[int(key[3:])] = (t, fr)
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
    out["cores"] = {k: (np.array(sorted(v)) + 0.5, np.array([v[s] for s in sorted(v)])) for k, v in cls_cores.items()}
    # victim + all replicas, per second, on the victim's second grid; a replica class
    # (node-3 sampler) that misses a second is linearly interpolated, not counted as 0
    vic_secs = sorted(cls_cores.get("victim", {}))
    grid = np.array(vic_secs, float)
    tot = np.zeros(len(grid))
    for k, d in cls_cores.items():
        if (k.startswith("victim") or k.startswith("overflow")) and d:
            ks = np.array(sorted(d), float)
            vs = np.array([d[s] for s in sorted(d)])
            tot += np.where((grid >= ks[0]) & (grid <= ks[-1]), np.interp(grid, ks, vs), 0.0)
    out["svc_t"] = grid + 0.5
    out["svc"] = tot
    return out


def shade_bursts(ax, arm, burst=10, idle=10, start=20, end=140):
    t = start
    while t < end:
        ax.axvspan(t, min(t + burst, end), color="#bbbbbb", alpha=0.25, lw=0)
        t += burst + idle
    ax.axvline(arm, color="k", ls="--", lw=0.8)


def ts_common(fig, extra):
    h = [Line2D([], [], color=C_NONE, lw=2, label="no mitigation"), Line2D([], [], color=C_HC, lw=2, label="harvesting (HC)"),
         Line2D([], [], color=C_REP, lw=2, label="replication"),
         Patch(facecolor="#bbbbbb", alpha=0.5, label="contention on"), Line2D([], [], color="k", ls="--", lw=1, label="mitigation enabled (80 s)")]
    fig.legend(handles=h + list(extra), loc="lower center", ncol=min(5 + len(extra), 6), fontsize=8.5, frameon=False,
               bbox_to_anchor=(0.5, -0.005))


TS_STYLE = {  # cell -> (colour, short title)
    "none": (C_NONE, "no mitigation"),
    "hc-hold": (C_HC, "harvesting (HC, enabled at 80 s)"),
    "rep3-othercores": (C_REP, "replication: 3 replicas, other cores of node-4"),
    "rep3-othernode": (C_REP, "replication: 3 replicas on node-3"),
    "rep6-othernodewide": (C_REP, "replication: up to 6 replicas on node-3"),
    "rep6-othercores": (C_REP, "replication: up to 6 replicas, node-4 threads 21-29"),
    "rep1f-othercores": (C_REP, "replication: 1 replica, other cores of node-4"),
    "rep1f-othernode": (C_REP, "replication: 1 replica on node-3"),
}


def _ts_cells(root, sweep, cells):
    out = {}
    for c in cells:
        d = os.path.join(root, sweep, c)
        if not os.path.isdir(d) and c.startswith("rep6"):
            d = os.path.join(root, "motiv2-uncap", c)
        if os.path.isdir(d):
            out[c] = load_cell(d)
    return out


def _ts_grid(data, title, lat_key, lat_label, lat_ylim, lat_log, shade, cores_ylim, out, name, legend_extra):
    # title = (main, setup line); lat_label = (main, measurement note)
    """One column per cell, two rows: latency on top, cores consumed by victim + replicas
    below (plus the victim cores HC lends to the aggressors, dashed blue, where HC ran)."""
    cells = list(data)
    fig, axes = plt.subplots(2, len(cells), figsize=(3.6 * len(cells), 5.6), sharex=True, sharey="row")
    axes = np.atleast_2d(axes)
    for j, c in enumerate(cells):
        d = data[c]
        col, ttl = TS_STYLE[c]
        for ax in axes[:, j]:
            shade(ax, d["arm"])
        axes[0, j].plot(d[lat_key[0]], d[lat_key[1]], color=col, lw=1.2)
        axes[0, j].set_title(ttl, fontsize=9)
        axes[1, j].plot(d["svc_t"], d["svc"], color=col, lw=1.3)
        if len(d["lent"]):
            # reserved idle = HC's 3 cores - lent to the aggressors - used by the victim;
            # total taken = used + reserved idle (= 3 - lent)
            used = np.interp(d["lent_t"], d["svc_t"], d["svc"])
            idle = np.clip(HC_PRIMARY_CORES - d["lent"] - used, 0, None)
            axes[1, j].plot(d["lent_t"], idle, color=C_HC, ls="--", lw=1.2)
            axes[1, j].plot(d["lent_t"], used + idle, color=C_HC, lw=2.2, alpha=0.45)
        axes[1, j].set_xlabel("time (s)")
    if lat_log:
        axes[0, 0].set_yscale("log")
    ylabel2(axes[0, 0], *lat_label)
    axes[0, 0].set_ylim(*lat_ylim)
    ylabel2(axes[1, 0], "cores", "consumed by victim + replicas, per second")
    axes[1, 0].set_ylim(*cores_ylim)
    axes[0, 0].set_xlim(-5, 145)
    h = [Line2D([], [], color=C_NONE, lw=2, label="no mitigation"), Line2D([], [], color=C_HC, lw=2, label="harvesting (HC)"),
         Line2D([], [], color=C_REP, lw=2, label="replication"),
         Line2D([], [], color=C_HC, ls="--", lw=1.2, label="HC: cores reserved for the victim but idle (3 - lent - used)"),
         Line2D([], [], color=C_HC, lw=2.2, alpha=0.45, label="HC: total cores taken = used (solid) + reserved idle (dashed)"),
         Line2D([], [], color="k", ls="--", lw=1, label="mitigation enabled (80 s)")] + legend_extra
    fig.legend(handles=h, loc="lower center", ncol=6, fontsize=8.5, frameon=False, bbox_to_anchor=(0.5, -0.01))
    suptitle2(fig, *title)
    fig.tight_layout(rect=(0, 0.07, 1, 0.92))
    save(fig, out, name)


def fig_ts_ext(root, out, cells=("none", "hc-hold", "rep3-othercores", "rep3-othernode", "rep6-othernodewide")):
    data = _ts_cells(root, "motiv2-t2", cells)
    _ts_grid(data, ("Extrinsic bursts: handler latency and cores over time",
                    "3-P victim on threads 18-20, SN/SS aggressor bursts 10 s on / 10 s off (shaded), mitigation enabled at 80 s; sweep A trial 2"),
             ("t_h", "h90"), ("handler p90 (us)", "victim instance, 1 s count-weighted"), (0, 110), False, shade_bursts, (0, 4.2),
             out, "motiv2_ts_ext", [Patch(facecolor="#bbbbbb", alpha=0.5, label="aggressor burst")])


def _shade_int(ax, arm):
    ax.axvspan(20, 140, color="#bbbbbb", alpha=0.2, lw=0)
    ax.axvline(arm, color="k", ls="--", lw=0.8)


def fig_ts_int(root, out, cells=("none", "hc-hold", "rep1f-othercores", "rep1f-othernode")):
    data = _ts_cells(root, "motiv2-int", cells)
    _ts_grid(data, ("Intrinsic steady: service latency and cores over time",
                    "1-P victim on thread 18, 800 rps + 10200 rps extra from t = 20 s (shaded), no aggressors, mitigation enabled at 80 s"),
             ("t_ts", "ts50"), ("service total p50 (ms, log)", "pooled over victim + replicas, 1 s count-weighted"), (2, 30), True, _shade_int, (0, 2.2),
             out, "motiv2_ts_int", [Patch(facecolor="#bbbbbb", alpha=0.5, label="11000 rps offered")])


def fig_ts_mixed(root, out, cells=("none", "hc-hold", "rep3f-othernode", "hcrep3-othernode")):
    data = {c: load_cell(os.path.join(root, "motiv2-mixed", c)) for c in cells}
    fig, axes = plt.subplots(3, len(cells), figsize=(3.7 * len(cells), 7.6), sharex=True, sharey="row")
    for j, c in enumerate(cells):
        d = data[c]
        col = family(split_cell(c)[0])[1]
        ax = axes[0, j]; shade_bursts(ax, d["arm"])
        ax.plot(d["t_h"], d["h90"], color=col, lw=1.1); ax.set_title(c, fontsize=10)
        ax = axes[1, j]; shade_bursts(ax, d["arm"])
        ax.plot(d["t_ts"], d["ts90"], color=col, lw=1.2); ax.set_yscale("log")
        ax = axes[2, j]; shade_bursts(ax, d["arm"])
        ax.plot(d["sib_t"], d["sib"], color=C_SIB, lw=1.1)
        ax.set_xlabel("time (s)")
    axes[0, 0].set_ylabel("victim handler p90 (us)"); axes[0, 0].set_ylim(0, 90)
    axes[1, 0].set_ylabel("service total p90 (ms, log)"); axes[2, 0].set_ylabel("siblings 2-4 busy fraction"); axes[2, 0].set_ylim(0, 1.0)
    axes[0, 0].set_xlim(-5, 145)
    ts_common(fig, [Line2D([], [], color=C_SIB, label="siblings busy"), Line2D([], [], color=C_BOTH, lw=2, label="HC + replicas")])
    fig.suptitle("MIXED (1-P overload + 10 s bursts)", fontsize=11)
    fig.tight_layout(rect=(0, 0.07, 1, 0.96))
    save(fig, out, "motiv2_ts_mixed")


def save(fig, out, name):
    os.makedirs(out, exist_ok=True)
    fig.savefig(os.path.join(out, name + ".png"), dpi=150, bbox_inches="tight")
    fig.savefig(os.path.join(out, name + ".pdf"), bbox_inches="tight")
    plt.close(fig)
    print("wrote", os.path.join(out, name + ".png"))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", required=True, help="dir holding motiv2/ motiv2-t2/ motiv2-int/ (motiv2-mixed/)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--slo", type=float, default=1.5, help="SLO line as a multiple of the quiet (p1) mean")
    ap.add_argument("--only", default="", help="comma list of figure names (bars,ts_ext,ts_int,ts_mixed)")
    a = ap.parse_args()
    figs = dict(bars=lambda r, o: fig_bars(r, o, a.slo), ts_ext=fig_ts_ext, ts_int=fig_ts_int, ts_mixed=fig_ts_mixed)
    for k in (a.only.split(",") if a.only else ("bars", "ts_ext", "ts_int")):
        figs[k](a.root, a.out)


if __name__ == "__main__":
    main()
