#!/usr/bin/env python3
"""motiv3_plot.py -- figures for the motivation pass 3 (10 % bursts, replicas on a
controlled node-3, 2-P victim; see run-motiv3.sh).

  python3 tools/motiv3_plot.py --root C:/tmp/motiv3/data --out simulation/results/2026-11-motiv3-sm110p

Figures (png + pdf):
  motiv3_bars   extrinsic (default cells none, hc-hold, reactive rep3 / rep6): SERVICE-level handler p50 / p90 / p95 (pooled over victim +
                replicas) per cell, four bars: quiet (p1), enabled between the bursts,
                during the enabled bursts, overall enabled phase; rows p50 and p95 by default
                (--panels), replication cells of the medium node-3 condition by default (--loads),
                none and hc-hold as the non-replication cells (--arms); repeated trials -> mean with min-max error bar;
                bottom row: cores taken during the bursts (victim, HC reserved idle,
                replicas on node-3). Cells: none, hc-bang, hc-hold, then rep1f/3f/6f
                under each node-3 condition (quiet / medium / contended).
  motiv3_cdf    extrinsic: approximate CDFs of the service-level handler latency during
                the enabled bursts (mixture of the per-window quantile sets, count
                weighted) for a few cells, plus the quiet reference.
  motiv3_ts     extrinsic time series (trial 1; none, hc-hold, reactive rep3 / rep6): service handler
                p95 per second, cores consumed per second (victim, replicas, HC lent), replicas serving.
  motiv3_int    intrinsic: service total p50 quiet vs overload per cell, cores taken
                (victim, replicas, burner, HC lent written), and the hc-int time series
                (victim cores, cores lent, total p50).
Conventions as motiv2_plot.py (raw numbers, ratio text, "enabled", no arm/armed).
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
from matplotlib.lines import Line2D
from matplotlib.patches import Patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import motiv2_report as R   # noqa: E402
import motiv3_report as R3  # noqa: E402
from motiv2_plot import (C_NONE, C_HC, C_REP, C_QUIET, SUB, title2, suptitle2, ylabel2, save,  # noqa: E402
                         balancer_lent)

HC_PRIMARY_CORES = 2        # HC_VICTIM_CPULIST=18,19
LOADS = ("quiet", "medium", "contended")
LOAD_LABEL = {"quiet": "node-3 quiet", "medium": "node-3 medium (50 % siblings)", "contended": "node-3 contended (100 % siblings)"}
C_ALL = "#f4b183"           # overall-phase bar for replication (lighter)
C_ALL_HC = "#9ecae1"
C_ALL_NONE = "#bbbbbb"
C_VICTIM = "#7b4fa6"       # cores consumed by the victim instance (purple)
C_LAT = "#222222"          # latency curves in the time-series panels (distinct from every cores colour)
C_TOTAL = "#111111"        # total cores of a mitigation (victim + replicas, or victim + lent), dash-dot


def slo_label(ax, y, slo, x=0.995, dy=0.02, fontsize=7.5, ha="right"):
    """Write 'SLO (<slo>x quiet)' just above the dashed SLO line, at the right edge of the axes."""
    import matplotlib.transforms as mtransforms
    tr = mtransforms.blended_transform_factory(ax.transAxes, ax.transData)
    ax.text(x, y, "SLO (%gx quiet)" % slo, transform=tr, ha=ha, va="bottom", fontsize=fontsize, color="k",
            bbox=dict(facecolor="white", edgecolor="none", alpha=0.7, pad=0.8))


def series_sum(base, *others):
    """(t, v) of `base` plus every other (t, v) series interpolated onto base's time grid (0 outside)."""
    t, v = np.asarray(base[0], float), np.asarray(base[1], float)
    for ot, ov in others:
        if len(ot):
            v = v + np.interp(t, np.asarray(ot, float), np.asarray(ov, float), left=0.0, right=0.0)
    return t, v
# machine text in the subtitles (--machine sm110p | c6320): description, victim threads, hc-grow's shared pair
MACHINES = {"sm110p": ("sm110p, SMT on, 2.4 GHz", "18,19", "20,21", "16000"), "c6320": ("c6320 (2x E5-2683 v3), SMT on, 2.0 GHz", "4,6", "8,10", "8000")}
MACHINE, VTHREADS, GROW_THREADS, INT_RPS = MACHINES["sm110p"]   # ..., offered rps of the intrinsic overload
VP = 2                        # victim Ps in the intrinsic figure (--onep: 1 P on one thread, hc-grow1 = 1 own + 1 shared)
GROW_CELL = "hc-grow-quiet"   # the harvesting cell of the intrinsic figure (hc-grow1-quiet with --onep)
BS_N = chr(10)              # newline inside label strings


def family_color(arm):
    if arm == "none":
        return C_NONE, C_ALL_NONE
    if arm.startswith("hc"):
        return C_HC, C_ALL_HC
    return C_REP, C_ALL


def split(cell):
    """'rep3f-contended' -> ('rep3f', 'contended'); 'none-quiet' -> ('none', 'quiet'); a group prefix ("ext4:") is dropped."""
    cell = cell.split(":", 1)[1] if ":" in cell else cell
    arm, _, load = cell.rpartition("-")
    return (arm, load) if load in LOADS else (cell, "quiet")


def load_rows(root, sweeps, steady=False):
    """{cell: [row per trial]} via motiv3_report.analyse_cell."""
    class A:
        pass
    args = A(); args.arm = 2.0 if steady else 120.0; args.duration = 140.0 if steady else 260.0
    args.steady = steady; args.target_node = "node-4"
    out = {}
    for sw in sweeps:
        for d in sorted(glob.glob(os.path.join(root, sw, "*"))):
            if not os.path.isdir(d) or not glob.glob(os.path.join(d, "stage3eval_*")):
                continue
            try:
                r = R3.analyse_cell(d, args)
            except Exception as e:  # noqa: BLE001
                print("skip", d, e, file=sys.stderr)
                continue
            if not r:
                continue
            need = "s_proc50_ovl" if steady else "s_proc50_p3b"
            if r.get(need) is None:
                print("skip %s: no enabled window (%s missing; enable never happened?)" % (d, need), file=sys.stderr)
                continue
            out.setdefault(os.path.basename(d), []).append(r)
    return out


def _bar3(ax, cells, rows, key, unit, slo, labels, log=False, win=("p3gap", "p3b", "p3all")):
    """Per cell: quiet (p1), enabled between the bursts (win[0]), during the bursts (win[1]),
    overall enabled phase (win[2]); mean over trials, min-max."""
    w = 0.2
    x = np.arange(len(cells))
    base = np.mean([r["s_%s_p1" % key] for c in cells for r in rows.get(c, [])])
    top = 0
    for i, c in enumerate(cells):
        rs = rows.get(c, [])
        if not rs:
            continue
        col, col2 = family_color(split(c)[0])
        q = np.mean([r["s_%s_p1" % key] for r in rs])
        ax.bar(x[i] - 1.5 * w, q, w, color=C_QUIET, edgecolor="#777777", lw=0.5)
        for j, (wn, cc, hollow) in enumerate(((win[0], col, True), (win[1], col, False), (win[2], col2, False))):
            v = [r["s_%s_%s" % (key, wn)] for r in rs if r.get("s_%s_%s" % (key, wn)) is not None]
            if not v:
                continue
            m, lo, hi = np.mean(v), np.min(v), np.max(v)
            if hollow:   # enabled, between the bursts: outline only (the steady level the bursts add to)
                ax.bar(x[i] + (j - 0.5) * w, m, w, facecolor="white", edgecolor=cc, lw=1.3,
                       yerr=[[m - lo], [hi - m]] if hi > lo else None, capsize=2, error_kw=dict(lw=0.8, ecolor="k"))
            else:
                ax.bar(x[i] + (j - 0.5) * w, m, w, color=cc,
                       yerr=[[m - lo], [hi - m]] if hi > lo else None, capsize=2, error_kw=dict(lw=0.8, ecolor="k"))
            ax.text(x[i] + (j - 0.5) * w, hi * (1.06 if log else 1) + (0 if log else 0.012 * base), "%.2fx" % (m / base),
                    ha="center", va="bottom", fontsize=6, rotation=90)
            top = max(top, hi)
    ax.axhline(slo * base, color="k", ls="--", lw=1); slo_label(ax, slo * base, slo)
    if log:
        ax.set_yscale("log"); ax.set_ylim(base * 0.5, top * 2.6)
    else:
        ax.set_ylim(0, top * 1.4)
    ax.set_xticks(x); ax.set_xticklabels(labels, fontsize=8)
    return base


def _cores(ax, cells, rows, labels, win="p3b"):
    """Consumed cores (cgroup CPU time / wall time) in the window: victim + replicas on node-3."""
    x = np.arange(len(cells))
    ref = rows.get("none-quiet") or rows.get("none") or []
    ref_tot = np.mean([r["c_victim_" + win] for r in ref]) if ref else float("nan")
    top = 0
    for i, c in enumerate(cells):
        rs = rows.get(c, [])
        if not rs:
            continue
        arm = split(c)[0]
        v = np.mean([r["c_victim_" + win] for r in rs])
        on = np.mean([r.get("c_ovf_node3_" + win, 0.0) for r in rs])
        tots = [r["c_victim_" + win] + r.get("c_ovf_node3_" + win, 0.0) for r in rs]
        m, lo, hi = np.mean(tots), np.min(tots), np.max(tots)
        ax.bar(x[i], v, 0.6, color=C_VICTIM)
        ax.bar(x[i], on, 0.6, bottom=v, color=C_REP, hatch="//", edgecolor="white")
        lent = np.nanmean([r.get("lent_" + win, float("nan")) for r in rs]) if arm.startswith("hc") else float("nan")
        extra = ""
        if not np.isnan(lent) and lent > 0:   # victim-thread CPU used by the aggressors (HC lends it): not part of the service total
            ax.bar(x[i], lent, 0.6, bottom=v + on, color=C_HC, alpha=0.55)
            extra = BS_N + "+%.1f lent, used" % lent + BS_N + "by aggressors"
        if hi > lo:
            ax.errorbar(x[i], m, yerr=[[m - lo], [hi - m]], fmt="none", ecolor="k", lw=0.8, capsize=2, zorder=4)
        ax.text(x[i], max(hi, m + (0 if np.isnan(lent) else lent)) + 0.04, "%.2f\n(%.1fx)%s" % (m, m / ref_tot, extra), ha="center", va="bottom", fontsize=6.5)
        top = max(top, hi + (0 if np.isnan(lent) else lent))
    ax.set_xticks(x); ax.set_xticklabels(labels, fontsize=8)
    ax.set_ylim(0, max(2.2, top * 1.35))


def _alloc(ax, cells, rows, labels, win="p3b", victim_limit=2.0, replica_limit=2.0):
    """Allocated cores (CPU limits held by the service): the victim's limit in every arm, plus
    one limit per replica; for HC the part of the victim's pool lent to the aggressors is shown
    separately (the victim's exclusive allocation shrinks by it)."""
    x = np.arange(len(cells))
    top = 0
    for i, c in enumerate(cells):
        rs = rows.get(c, [])
        if not rs:
            continue
        arm = split(c)[0]
        n_rep = np.mean([int(r["replicas_seen"]) for r in rs]) if arm.startswith("rep") else 0
        lent = np.nanmean([r.get("lent_" + win, float("nan")) for r in rs]) if arm.startswith("hc") else 0.0
        lent = 0.0 if np.isnan(lent) else lent
        vic = victim_limit - lent
        ax.bar(x[i], vic, 0.6, color=C_VICTIM)
        if lent > 0:
            ax.bar(x[i], lent, 0.6, bottom=vic, color=C_HC, alpha=0.55)
        rep = n_rep * replica_limit
        if rep > 0:
            ax.bar(x[i], rep, 0.6, bottom=victim_limit, color=C_REP, hatch="//", edgecolor="white")
        total = vic + rep
        txt = "%.1f\n(%.1fx)" % (total, total / victim_limit) + (("\n%.1f lent" % lent) if lent > 0 else "")
        ax.text(x[i], max(victim_limit, total) + 0.15, txt, ha="center", va="bottom", fontsize=6.5)
        top = max(top, victim_limit + rep)
    ax.set_xticks(x); ax.set_xticklabels(labels, fontsize=8)
    ax.set_ylim(0, top * 1.25)


EXT4_SWEEPS = ("motiv3-grow-ext", "motiv3-grow-ext-t2")   # 4-thread victim cells (extrinsic); keyed "ext4:<cell>"
EXT4_CELLS = [("none-quiet", "none\n4 threads"), ("hc-grow-ext-quiet", "harvesting\n2 + 2 shared")]


def fig_bars(root, out, sweeps, slo=1.5, loads=("medium",), panels=("proc50", "proc95"), arms=("none", "hc-hold"), rep_arms=("rep3p", "rep6p"), alloc=False):
    """loads: node-3 conditions of the replication cells to show (user 2026-11-09: medium only;
    pass --loads quiet,medium,contended for the full set); panels: latency quantile rows;
    arms: the non-replication cells (user 2026-11-09: no hc-bang; --arms none,hc-bang,hc-hold for all);
    rep_arms: replication arms, default the REACTIVE pass-2 trigger arms rep3, rep6 (user 2026-11-09: the
    forced / pre-provisioned rep<k>f cells are "off what I have in mind"; --rep-arms rep1f,rep3f,rep6f,rep3,rep6 shows all)."""
    rows = load_rows(root, sweeps)
    cells = ["%s-quiet" % a for a in arms] + ["%s-%s" % (a, l) for l in loads for a in rep_arms]
    cells = [c for c in cells if c in rows]
    ext4 = load_rows(root, EXT4_SWEEPS)
    ext4_labels = {}
    for c, lbl in EXT4_CELLS:
        if c in ext4:
            rows["ext4:" + c] = ext4[c]; cells.append("ext4:" + c); ext4_labels["ext4:" + c] = lbl
    one_load = len(loads) == 1
    labels = []
    for c in cells:
        if c in ext4_labels:
            labels.append(ext4_labels[c]); continue
        arm, load = split(c)
        n = sorted({int(r["replicas_seen"]) for r in rows[c]})
        # forced arms: replicas reached; reactive (scale-in) arms: the cap (pods come and go)
        reached = "" if not arm.startswith("rep") else (("%d" % n[0] if len(n) == 1 else "%d-%d" % (n[0], n[-1])) if arm.endswith("f") else "cap %s" % arm.strip("rep").rstrip("fp"))
        mixed = any(a.endswith("f") for a in rep_arms) and any(not a.endswith("f") for a in rep_arms)
        kind = "" if not (arm.startswith("rep") and mixed) else (BS_N + "pre-prov." if arm.endswith("f") else BS_N + "reactive")
        labels.append(("harvesting" if arm.startswith("hc") else arm.replace("f", "")) + kind + ((BS_N + ("reached %s" % reached if arm.endswith("f") else reached)) if reached else "")
                      + ((BS_N + load) if arm.startswith("rep") and not one_load else ""))
    n_tr = max(len(v) for v in rows.values())
    n_cores_rows = 2 if alloc else 1
    fig, axes = plt.subplots(len(panels) + n_cores_rows, 1, figsize=(max(9, 1.15 * len(cells) + 2), 3.3 * len(panels) + 2.6 * n_cores_rows + 0.4), sharex=True,
                             gridspec_kw=dict(height_ratios=[1.6] * len(panels) + [1.1] * n_cores_rows))
    for ax, key in zip(axes, panels):
        unit = "us"
        base = _bar3(ax, cells, rows, key, unit, slo, labels, log=False)
        ylabel2(ax, "handler %s (us)" % key[4:].join(["p", ""]),
                "pooled over instances; ratio vs quiet; dashed = SLO %.1fx quiet (%.3g %s)" % (slo, slo * base, unit))
    cond = "; replicas on node-3"
    title2(axes[0], "Extrinsic bursts",
           "bursts 6 s on / 54 s off (10 %% of the time)%s; %d trial%s, min-max" % (cond, n_tr, "s" if n_tr > 1 else ""))
    if alloc:   # user 2026-11-09: off by default (--alloc)
        _alloc(axes[-2], cells, rows, labels)
        ylabel2(axes[-2], "cores allocated", "CPU limits: victim 2 + 2 per replica; (x) = vs none")
    _cores(axes[-1], cells, rows, labels)
    ylabel2(axes[-1], "cores consumed", "during the bursts; (x) = vs none; blue = victim threads used by the aggressors (harvesting)")
    # group brackets for the node-3 condition (only when several conditions are shown)
    if not one_load:
        for load in loads:
            idx = [i for i, c in enumerate(cells) if split(c)[1] == load and split(c)[0].startswith("rep")]
            if idx:
                axes[-1].annotate(LOAD_LABEL[load], xy=((idx[0] + idx[-1]) / 2, -0.32), xycoords=("data", "axes fraction"),
                                  ha="center", va="top", fontsize=8, color="#333333")
    lat = [Patch(facecolor=C_QUIET, edgecolor="#777777", label="quiet"),
           Patch(facecolor="white", edgecolor=C_REP, lw=1.3, label="enabled, between bursts"),
           Patch(color=C_REP, label="enabled, during bursts"),
           Patch(color=C_ALL, label="enabled, overall"),
           Line2D([], [], color="k", ls="--", label="SLO %gx quiet" % slo)]
    cores = [Patch(color=C_VICTIM, label="victim"), Patch(color=C_HC, alpha=0.55, label="lent to aggressors (harvesting)"),
             Patch(facecolor=C_REP, hatch="//", edgecolor="white", label="replicas on node-3")]
    l1 = fig.legend(handles=lat, title="latency (bar colour = arm)", loc="lower left", ncol=3, fontsize=8, title_fontsize=8,
                    frameon=False, bbox_to_anchor=(0.02, -0.005))
    l1._legend_box.align = "left"
    l2 = fig.legend(handles=cores, title="cores (bottom row%s)" % ("s" if alloc else ""), loc="lower right", ncol=1, fontsize=8, title_fontsize=8,
                    frameon=False, bbox_to_anchor=(0.98, -0.005))
    l2._legend_box.align = "left"
    suptitle2(fig, "Service latency and cores per mitigation",
              "victim: search service; machine: %s; harvesting (enabled at 120 s); replication (score trigger, +1 replica per 2 s)" % MACHINE)
    fig.tight_layout(rect=(0, 0.11 if len(panels) < 3 else 0.07, 1, 0.93))
    save(fig, out, "motiv3_bars")


# ----------------------------------------------------------------------------- CDF
QKEYS = [("min_ns", 0.0), ("p50_ns", 0.5), ("p60_ns", 0.6), ("p70_ns", 0.7), ("p75_ns", 0.75), ("p80_ns", 0.8),
         ("p90_ns", 0.9), ("p99_ns", 0.99), ("max_ns", 1.0)]


def window_quantiles(run, t0, spans, section="processing_time"):
    """[(count, [(latency_us, F)...])] for every 100 ms window of every instance inside spans."""
    out = []
    for f in [os.path.join(run, "run_data.json")] + glob.glob(os.path.join(run, "run_data-overflow-*.json")):
        d = json.load(open(f))
        for s in d.get("samples", []):
            tw = s.get("timing_window") or {}
            n = tw.get("request_count", 0)
            if not n or not R.in_any(R.ts_epoch(s["timestamp"]) - t0, spans):
                continue
            q = tw.get(section) or {}
            pts = [(q.get(k, 0) / 1e3, F) for k, F in QKEYS if q.get(k, 0)]
            if len(pts) >= 3:
                out.append((n, pts))
    return out


def mixture_cdf(wq, grid):
    tot = sum(n for n, _ in wq)
    F = np.zeros(len(grid))
    for n, pts in wq:
        xs = np.array([p[0] for p in pts]); ys = np.array([p[1] for p in pts])
        F += n * np.interp(grid, xs, ys, left=0.0, right=1.0)
    return F / tot if tot else F


def fig_cdf(root, out, sweeps, cells=("none-quiet", "hc-hold-quiet", ["rep3p-quiet", "rep3f-quiet"])):
    class A:
        pass
    args = A(); args.arm = 120.0; args.duration = 260.0; args.steady = False; args.target_node = "node-4"
    grid = np.linspace(10, 400, 800)
    fig, ax = plt.subplots(figsize=(7.2, 4.6))
    # style by arm (line style = replica count), darker orange for a contended node-3
    styles = {"none": (C_NONE, "-"), "hc-hold": (C_HC, "-"), "hc-bang": (C_HC, ":"), "rep1": (C_REP, ":"), "rep3": (C_REP, "--"), "rep6": (C_REP, "-")}
    quiet = None
    for e in cells:
        d = None
        for c in (e if isinstance(e, list) else [e]):   # a list = alternatives, first available wins
            for sw in sweeps:
                if os.path.isdir(os.path.join(root, sw, c)):
                    d = os.path.join(root, sw, c); break
            if d is not None:
                break
        if d is None:
            continue
        r = R3.analyse_cell(d, args)
        run = sorted(glob.glob(os.path.join(d, "stage3eval_*", "runs", "run_1")))[-1]
        t0 = int(open(os.path.join(run, "started_epoch_ns.txt")).read()) / 1e9
        F = mixture_cdf(window_quantiles(run, t0, r["windows"]["p3b"]), grid)
        col, ls = styles.get(split(c)[0].rstrip("fp"), (C_REP, "-"))   # rep3 / rep3f / rep3p share a style
        if split(c)[1] == "contended":
            col = "#a63603"
        arm, load = split(c)
        if arm.startswith("hc"):
            lbl = "harvesting"
        elif not arm.startswith("rep"):
            lbl = arm
        else:
            lbl = "replication (%s, %s node)" % ("reactive" if arm.endswith("p") else "pre-provisioned", "medium-load" if load == "medium" else load)
        if load == "quiet" and split(c)[0].startswith("rep"):
            ls = "-."
        ax.plot(grid, F, color=col, ls=ls, lw=1.6, label=lbl)
        if quiet is None:
            quiet = mixture_cdf(window_quantiles(run, t0, r["windows"]["p1"]), grid)
    if quiet is not None:
        ax.plot(grid, quiet, color=C_QUIET, lw=2.2, label="quiet", zorder=0)
    ax.set_xscale("log"); ax.set_xlim(15, 400); ax.set_ylim(0, 1.0)
    ax.set_yticks([0, 0.25, 0.5, 0.75, 0.9, 0.99]); ax.set_yticklabels(["0", "0.25", "0.50", "0.75", "0.90", "0.99"])
    ax.grid(alpha=0.3, which="both")
    ylabel2(ax, "fraction of requests", "mixture of per-window quantiles")
    ax.set_xlabel("handler latency (us, log)")
    title2(ax, "Handler latency during the bursts", "service level, trial 1")
    ax.legend(fontsize=8, frameon=False, loc="lower right")
    fig.tight_layout()
    save(fig, out, "motiv3_cdf")


# ----------------------------------------------------------------------------- intrinsic
INT_CELLS = [  # (sweep group, cell dir, label, arm key, Primary pool threads)
    ("int", "none-quiet", "no mitigation", "none", 2),
    # ("int", "hc-int-quiet", "harvesting\n2 threads", "hc", 2),   # dropped (user 2026-11-09)
    ("grow", "hc-grow-quiet", "harvesting", "hc", 4),
    ("int", "rep1f-quiet", "replication", "rep1f", 2),
    # ("grow", "none-quiet", "none\n4 threads", "none", 4),   # 4-core reference dropped (user 2026-11-09)
]


def _int_ts(ax3, d, pool):
    """Panel B: victim total p50, cores lent to the burner and victim cores used, one run."""
    run = sorted(glob.glob(os.path.join(d, "stage3eval_*", "runs", "run_1")))[-1]
    mdir = os.path.join(run, "mitigation")
    t0 = int(open(os.path.join(run, "started_epoch_ns.txt")).read()) / 1e9
    vic = R.load_run(os.path.join(run, "run_data.json"))
    b = {}
    for r in vic:
        b.setdefault(int(r[0] - t0), []).append(r)
    ts = sorted(b)
    p50 = [R.wmean([r[4] for r in b[s]], [r[1] for r in b[s]]) for s in ts]
    ax3.plot(np.array(ts) + 0.5, p50, color=C_LAT, lw=1.3, label="victim total p50 (ms)")
    ax3.set_yscale("log"); ax3.set_ylim(1.5, 60); ax3.set_xlim(-5, 145)
    ax3.axvspan(20, 140, color="#bbbbbb", alpha=0.2, lw=0)
    ax3b = ax3.twinx()
    lt, lv = balancer_lent(mdir, t0)
    if len(lt):
        ax3b.plot(lt, lv, color="#0077BB", ls="--", lw=1.4, label="cores lent to the burner")
    per = {}
    p = os.path.join(mdir, "cpu_usage.csv")
    uids = R.load_uids(mdir)
    if os.path.isfile(p):
        rowsv = [(int(r["unix_ms"]) / 1e3 - t0, int(r["a"])) for r in csv.DictReader(open(p))
                 if r["key"].startswith("pod:") and R.pod_class(*uids.get(r["key"][4:], ("?", "?", "?"))[:2]) == "victim"]
        rowsv.sort()
        for (ta, a), (tb, bb) in zip(rowsv, rowsv[1:]):
            if 0 < tb - ta <= 3:
                per[int(ta)] = (bb - a) / 1e6 / (tb - ta)
        ks = sorted(per)
        ax3b.plot(np.array(ks) + 0.5, [per[k] for k in ks], color=C_VICTIM, lw=1.2, label="victim cores used")
        if len(lt):
            ax3b.plot(*series_sum((np.array(ks) + 0.5, [per[k] for k in ks]), (lt, lv)), color=C_TOTAL, ls="-.", lw=1.1, label="total (victim + lent)")
    ax3b.set_ylim(0, pool + 0.6); ax3b.set_ylabel("cores", fontsize=9.5)
    ax3b.axhline(pool, color="k", ls=":", lw=0.8)
    ax3b.text(-3, pool + 0.05, "Primary pool = %d threads" % pool, ha="left", va="bottom", fontsize=7, color="#333333")
    h1, l1 = ax3.get_legend_handles_labels(); h2, l2 = ax3b.get_legend_handles_labels()
    ax3.legend(h1 + h2 + [Patch(facecolor="#bbbbbb", alpha=0.5, label=INT_RPS + " rps offered")], l1 + l2 + [INT_RPS + " rps offered"],
               fontsize=8, frameon=False, loc="lower center", bbox_to_anchor=(0.5, -0.32), ncol=2)
    ax3.set_xlabel("time (s)")
    ax3.set_ylabel("victim total p50 (ms, log)", fontsize=9.5)
    ax3.text(0.99, 0.985, "HC enabled from t = 2 s", transform=ax3.transAxes, ha="right", va="top", **SUB)



def _int_ts_rep(ax, d):
    """Panel C: service total p50 (victim + replica pooled) and cores (victim, replica) over time, one run."""
    import motiv2_plot as P2
    run = sorted(glob.glob(os.path.join(d, "stage3eval_*", "runs", "run_1")))[-1]
    t0 = int(open(os.path.join(run, "started_epoch_ns.txt")).read()) / 1e9
    vic = R.load_run(os.path.join(run, "run_data.json"))
    ovf = [row for f in glob.glob(os.path.join(run, "run_data-overflow-*.json")) for row in R.load_run(f)]
    b = {}
    for r in vic + ovf:
        b.setdefault(int(r[0] - t0), []).append(r)
    ts = sorted(b)
    p50 = [R.wmean([r[4] for r in b[s]], [r[1] for r in b[s]]) for s in ts]
    ax.plot(np.array(ts) + 0.5, p50, color=C_LAT, lw=1.3, label="service total p50 (ms)")
    ax.set_yscale("log"); ax.set_ylim(1.5, 60); ax.set_xlim(-5, 145)
    ax.axvspan(20, 140, color="#bbbbbb", alpha=0.2, lw=0)
    axb = ax.twinx()
    cores = P2.load_cell(d)["cores"]
    if "victim" in cores:
        axb.plot(*cores["victim"], color=C_VICTIM, lw=1.2, label="victim cores")
    rep = [v for k, v in cores.items() if k.startswith("overflow")]
    if rep:
        g = rep[0][0]
        rsum = (g, sum(np.interp(g, t, v) for t, v in rep))
        axb.plot(*rsum, color=C_REP, lw=1.2, ls="--", label="replica cores")
        if "victim" in cores:
            axb.plot(*series_sum(cores["victim"], rsum), color=C_TOTAL, ls="-.", lw=1.1, label="total (victim + replica)")
    axb.set_ylim(0, 2 * VP + 0.6); axb.set_ylabel("cores", fontsize=9.5)
    h1, l1 = ax.get_legend_handles_labels(); h2, l2 = axb.get_legend_handles_labels()
    ax.legend(h1 + h2 + [Patch(facecolor="#bbbbbb", alpha=0.5, label=INT_RPS + " rps offered")], l1 + l2 + [INT_RPS + " rps offered"],
              fontsize=8, frameon=False, loc="lower center", bbox_to_anchor=(0.5, -0.32), ncol=2)
    ax.set_xlabel("time (s)")
    ax.set_ylabel("service total p50 (ms, log)", fontsize=9.5)


def fig_int(root, out, sweeps, slo=1.5, grow_sweeps=("motiv3-grow", "motiv3-grow-t2")):
    """Intrinsic overload: 2-P cells from `sweeps`, 4-P cells (hc-grow and its 4-core reference) from
    `grow_sweeps`; the latter appear when swept. Bars = service total p50 quiet vs overload; cores =
    consumed in the overload window (victim, replicas, + HC-lent victim-thread CPU used by the burner)."""
    groups = {"int": load_rows(root, sweeps, steady=True), "grow": load_rows(root, grow_sweeps, steady=True)}
    spec = [(g, GROW_CELL if c == "hc-grow-quiet" else c, l, a, p) for g, c, l, a, p in INT_CELLS]
    spec = [(g, c, l, a, p) for g, c, l, a, p in spec if c in groups[g]]
    if not spec:
        print("no intrinsic cells"); return
    labels = [l for _, _, l, _, _ in spec]
    n_tr = max(len(groups[g][c]) for g, c, _, _, _ in spec)
    fig = plt.figure(figsize=(17, 6.6))
    gs = fig.add_gridspec(2, 3, height_ratios=[2, 1.3], width_ratios=[1.0, 0.95, 0.95])
    ax1, ax2, ax3, ax4 = fig.add_subplot(gs[0, 0]), fig.add_subplot(gs[1, 0]), fig.add_subplot(gs[:, 1]), fig.add_subplot(gs[:, 2])
    w = 0.38; x = np.arange(len(spec))
    base = np.mean([r["s_tot50_p1"] for g, c, _, _, _ in spec for r in groups[g][c]])
    top = 0
    for i, (g, c, l, arm, pool) in enumerate(spec):
        rs = groups[g][c]; col, _ = family_color(arm)
        v = [r["s_tot50_ovl"] for r in rs]; m, lo, hi = np.mean(v), np.min(v), np.max(v)
        ax1.bar(x[i] - w / 2, np.mean([r["s_tot50_p1"] for r in rs]), w, color=C_QUIET, edgecolor="#777777", lw=0.5)
        ax1.bar(x[i] + w / 2, m, w, color=col, yerr=[[m - lo], [hi - m]] if hi > lo else None, capsize=2.5, error_kw=dict(lw=0.9, ecolor="k"))
        ax1.text(x[i] + w / 2, hi * 1.07, "%.2fx" % (m / base), ha="center", va="bottom", fontsize=7.5)
        top = max(top, hi)
    ax1.axhline(slo * base, color="k", ls="--", lw=1); slo_label(ax1, slo * base, slo, x=0.01, ha="left")
    ax1.set_yscale("log"); ax1.set_ylim(base * 0.45, top * 1.8); ax1.set_xticks(x); ax1.set_xticklabels(labels, fontsize=8)
    ylabel2(ax1, "service total p50 (ms, log)", "")
    title2(ax1, "A. Steady overload", "%s rps offered; %d trial%s, min-max; number = overload vs quiet" % (INT_RPS, n_tr, "s" if n_tr > 1 else ""))
    top = 0
    for i, (g, c, l, arm, pool) in enumerate(spec):
        rs = groups[g][c]
        if arm.startswith("rep"):
            cap = int(arm.strip("rep").rstrip("fp") or 1)
            budget, note = VP + VP * cap, "%d replica%s" % (cap, "s" if cap > 1 else "")
        else:
            pool = pool * VP // 2
            budget, note = pool, ("%d own + %d shared" % (VP, VP) if pool == 2 * VP else "")
        top = max(top, _budget_bar(ax2, x[i], rs, "ovl", budget, note))
    ax2.set_ylim(0, top * 1.3); ax2.set_xticks(x); ax2.set_xticklabels(labels, fontsize=8)
    ylabel2(ax2, "core budget and its use\nunder overload", "")
    d, pool_ts, which = None, 2, "hc"
    for sw_list, cell, pl, name in ((grow_sweeps, GROW_CELL, 2 * VP, "hc-grow"), (sweeps, "hc-int-quiet", VP, "hc")):
        for sw in sw_list:
            if glob.glob(os.path.join(root, sw, cell, "stage3eval_*")):
                d, pool_ts, which = os.path.join(root, sw, cell), pl, name
                break
        if d:
            break
    if d:
        _int_ts(ax3, d, pool_ts)
        title2(ax3, "B. Harvesting over time (trial 1)", "lent while quiet, reclaimed under overload")
    dr = None
    for sw in sweeps:
        if glob.glob(os.path.join(root, sw, "rep1f-quiet", "stage3eval_*")):
            dr = os.path.join(root, sw, "rep1f-quiet"); break
    if dr:
        _int_ts_rep(ax4, dr)
        title2(ax4, "C. Replication over time (trial 1)", "one replica on node-3 from the start")
    fig.legend(handles=[Patch(facecolor=C_QUIET, edgecolor="#777777", label="quiet (0-20 s)"), Patch(color=C_NONE, label="overload, no mitigation"),
                        Patch(color=C_HC, label="overload, harvesting"), Patch(color=C_REP, label="overload, replication"),
                        Line2D([], [], color="k", ls="--", label="SLO %gx quiet" % slo),
                        Patch(facecolor="white", edgecolor="#444444", label="core budget (outline)"), Patch(color=C_VICTIM, label="used by the victim"),
                        Patch(facecolor=C_REP, hatch="//", edgecolor="white", label="used by the replica"),
                        Patch(facecolor="#9ecae1", edgecolor=C_HC, hatch="xx", label="lent out to the tenant")],
               loc="lower center", ncol=5, fontsize=8, frameon=False, bbox_to_anchor=(0.5, -0.01))
    suptitle2(fig, "Overloaded victim: harvesting vs replication",
              "search victim on thread%s %s, %s; harvesting = the victim may also use thread%s %s, which a best-effort tenant uses while the victim is quiet; replication = one %d-thread replica on node-3"
              % ("" if VP == 1 else "s", VTHREADS, MACHINE, "" if VP == 1 else "s", GROW_THREADS, VP))
    fig.tight_layout(rect=(0, 0.08, 1, 0.94))
    save(fig, out, "motiv3_int")


# ----------------------------------------------------------------------------- time series
TS_TITLE = {"none-quiet": "no mitigation", "hc-hold-quiet": "harvesting", "ext4:hc-grow-ext-quiet": "harvesting, 2 + 2 shared", "ext4:none-quiet": "no mitigation, 4 threads",
            "rep3-medium": "replication, up to 3 (no scale-in)", "rep6-medium": "replication, up to 6 (no scale-in)",
            "rep3p-medium": "replication, up to 3", "rep6p-medium": "replication, up to 6",
            "rep3f-medium": "3 replicas pre-provisioned", "rep6f-medium": "6 replicas pre-provisioned", "hc-bang-quiet": "harvesting (triggered)"}


def ts_load(cell_dir):
    """Per-second series for one run: service handler p90 / p95 (victim + replicas, count-weighted),
    replicas serving, cores (victim, replicas on node-3, HC lent), bursts and enable time."""
    import motiv2_plot as P2
    run = sorted(glob.glob(os.path.join(cell_dir, "stage3eval_*", "runs", "run_1")))[-1]
    t0 = int(open(os.path.join(run, "started_epoch_ns.txt")).read()) / 1e9
    af = os.path.join(run, "armed_epoch_ns.txt")
    arm = int(open(af).read()) / 1e9 - t0 if os.path.isfile(af) else 120.0
    vic = R.load_run(os.path.join(run, "run_data.json"))
    ovf_files = glob.glob(os.path.join(run, "run_data-overflow-*.json"))
    ovf = [(f, row) for f in ovf_files for row in R.load_run(f)]
    bursts, _ = R3.bursts_from_driver(run, t0)
    secs = {}
    for r in vic:
        secs.setdefault(int(r[0] - t0), []).append(r)
    for _, r in ovf:
        secs.setdefault(int(r[0] - t0), []).append(r)
    ts = np.array(sorted(secs), float)
    p90 = np.array([R.wmean([r[3] for r in secs[int(t)]], [r[1] for r in secs[int(t)]]) for t in ts])
    p95 = np.array([R.wmean([R3.p95_interp(r[3], r[6]) for r in secs[int(t)]], [r[1] for r in secs[int(t)]]) for t in ts])
    rep_secs = {}
    for f, r in ovf:
        if r[1] > 0:
            rep_secs.setdefault(int(r[0] - t0), set()).add(f)
    n_rep = np.array([len(rep_secs.get(int(t), ())) for t in ts])
    d = P2.load_cell(cell_dir)
    cores = d["cores"]
    vic_c = cores.get("victim", (np.array([]), np.array([])))
    rep_c = [v for k, v in cores.items() if k.startswith("overflow")]
    if rep_c:   # sum the replica classes on the first one's grid
        g = rep_c[0][0]
        rc = sum(np.interp(g, t, v) for t, v in rep_c)
        rep_c = (g, rc)
    else:
        rep_c = (np.array([]), np.array([]))
    return dict(t=ts + 0.5, p90=p90, p95=p95, n_rep=n_rep, arm=arm, bursts=bursts, vic=vic_c, rep=rep_c,
                lent=(d["lent_t"], d["lent"]))


def fig_ts(root, out, sweeps, cells=("none-quiet", "hc-hold-quiet", "rep3p-medium", "rep6p-medium", "ext4:hc-grow-ext-quiet"), x=(0, 262), slo=1.5):
    data = {}
    for c in cells:
        for sw in (EXT4_SWEEPS if c.startswith("ext4:") else sweeps):
            d = os.path.join(root, sw, c.split(":", 1)[-1])
            if glob.glob(os.path.join(d, "stage3eval_*")):
                data[c] = ts_load(d); data[c]["sweep"] = sw
                break
    cells = [c for c in cells if c in data]
    fig, axes = plt.subplots(3, len(cells), figsize=(4.4 * len(cells), 8.2), sharex=True, sharey="row",
                             gridspec_kw=dict(height_ratios=[1.5, 1.2, 0.9]))
    axes = np.atleast_2d(axes)
    base95 = np.nanmean(np.concatenate([d["p95"][(d["t"] > 2) & (d["t"] < 29)] for d in data.values()]))
    for j, c in enumerate(cells):
        d = data[c]
        col = family_color(split(c)[0])[0]
        for ax in axes[:, j]:
            for a, b in d["bursts"]:
                ax.axvspan(a, b, color="#bbbbbb", alpha=0.35, lw=0)
            ax.axvline(d["arm"], color="k", ls="--", lw=0.8)
        ax = axes[0, j]
        ax.plot(d["t"], d["p95"], color=col, lw=1.0)
        ax.axhline(slo * base95, color="k", ls=":", lw=0.8); slo_label(ax, slo * base95, slo, fontsize=7)
        ax.set_title(TS_TITLE.get(c, c), fontsize=9.5)
        ax = axes[1, j]
        ax.plot(*d["vic"], color=C_VICTIM, lw=1.2, label="victim")
        if len(d["rep"][0]):
            ax.plot(*d["rep"], color=C_REP, lw=1.2, label="replicas on node-3")
        if len(d["lent"][0]):
            ax.plot(*d["lent"], color=C_HC, ls="--", lw=1.2, label="lent to aggressors (harvesting)")
        ax = axes[2, j]
        ax.step(d["t"], d["n_rep"], where="post", color=C_REP, lw=1.3)
        ax.set_xlabel("time (s)")
    ylabel2(axes[0, 0], "service handler p95 (us)", "1 s bins; dotted = %gx quiet" % slo)
    axes[0, 0].set_ylim(0, max(100, 1.1 * np.nanmax([np.nanmax(d["p95"][(d["t"] > 100)]) for d in data.values()])))
    ylabel2(axes[1, 0], "cores consumed", "per second")
    ymax = max([2.3] + [float(np.nanmax(d["lent"][1])) * 1.15 for d in data.values() if len(d["lent"][0])])
    axes[1, 0].set_ylim(0, ymax)
    ylabel2(axes[2, 0], "replicas serving", "")
    axes[2, 0].set_ylim(-0.2, 6.5); axes[2, 0].set_yticks([0, 2, 4, 6])
    axes[0, 0].set_xlim(*x)
    h = [Patch(facecolor="#bbbbbb", alpha=0.6, label="aggressor burst"), Line2D([], [], color="k", ls="--", lw=1, label="mitigation enabled (120 s)"),
         Line2D([], [], color="k", ls=":", lw=1, label="%gx quiet" % slo),
         Line2D([], [], color=C_VICTIM, lw=1.5, label="victim cores"), Line2D([], [], color=C_REP, lw=1.5, label="replica cores / replicas"),
         Line2D([], [], color=C_HC, ls="--", lw=1.5, label="lent to aggressors (harvesting)")]
    fig.legend(handles=h, loc="lower center", ncol=3, fontsize=8.5, frameon=False, bbox_to_anchor=(0.5, -0.005))
    suptitle2(fig, "Extrinsic bursts over time (trial 1)",
              "victim: search service; machine: %s; harvesting (enabled at 120 s); replication (score trigger, +1 replica per 2 s); bursts shaded" % MACHINE)
    fig.tight_layout(rect=(0, 0.07, 1, 0.92))
    save(fig, out, "motiv3_ts")




# ----------------------------------------------------------------------------- intrinsic load sweep (1-P, c6320)
SWEEP_ARMS = [("none-quiet", "no mitigation", "none"), ("hc-grow1-quiet", "harvesting (1 own + 1 shared)", "hc"), ("rep1f-quiet", "replication (1 replica)", "rep")]


def fig_sweep(root, out, sweep="sweep1p", slo=1.5):
    """Intrinsic load sweep: service total p50 under overload (and its ratio to the quiet phase) vs offered
    rps, one line per arm, min-max over trials; cores under overload below. Dirs root/<sweep>/L<rps>-t<trial>/<cell>."""
    import re
    dirs = sorted(glob.glob(os.path.join(root, sweep, "L*-t*")))
    by_load = {}
    for d in dirs:
        m = re.match(r"L(\d+)-t(\d+)$", os.path.basename(d))
        if not m:
            continue
        rows = load_rows(root, [os.path.join(sweep, os.path.basename(d))], steady=True)
        for c, rs in rows.items():
            by_load.setdefault(int(m.group(1)), {}).setdefault(c, []).extend(rs)
    loads = sorted(by_load)
    if not loads:
        print("no sweep cells"); return
    fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(7.2, 9.2), sharex=True, gridspec_kw=dict(height_ratios=[1.5, 1.1, 1.0]))
    for cell, label, arm in SWEEP_ARMS:
        col, _ = family_color(arm)
        xs, p50, lo, hi, rat, rlo, rhi, cores, clo, chi, n = [], [], [], [], [], [], [], [], [], [], []
        for L in loads:
            rs = by_load[L].get(cell)
            if not rs:
                continue
            v = [r["s_tot50_ovl"] for r in rs]; q = [r["s_tot50_p1"] for r in rs]
            rr = [a / b for a, b in zip(v, q)]
            cc = [r["c_victim_ovl"] + r.get("c_ovf_node3_ovl", 0.0) + (0.0 if np.isnan(r.get("lent_ovl", float("nan"))) else r["lent_ovl"]) for r in rs]
            xs.append(L); p50.append(np.mean(v)); lo.append(min(v)); hi.append(max(v))
            rat.append(np.mean(rr)); rlo.append(min(rr)); rhi.append(max(rr))
            cores.append(np.mean(cc)); clo.append(min(cc)); chi.append(max(cc)); n.append(len(rs))
        if not xs:
            continue
        xs = np.array(xs)
        ax1.plot(xs, p50, "-o", color=col, lw=1.6, ms=4, label=label)
        ax1.fill_between(xs, lo, hi, color=col, alpha=0.18, lw=0)
        ax2.plot(xs, rat, "-o", color=col, lw=1.6, ms=4)
        ax2.fill_between(xs, rlo, rhi, color=col, alpha=0.18, lw=0)
        ax3.plot(xs, cores, "-o", color=col, lw=1.6, ms=4)
        ax3.fill_between(xs, clo, chi, color=col, alpha=0.18, lw=0)
    base = np.mean([r["s_tot50_p1"] for L in loads for rs in by_load[L].values() for r in rs])
    ax1.axhline(base, color=C_QUIET, lw=2, zorder=0); ax1.axhline(slo * base, color="k", ls="--", lw=1); slo_label(ax1, slo * base, slo)
    ax1.set_yscale("log"); ylabel2(ax1, "service total p50 under overload (ms, log)", "band = min-max over trials; grey = quiet, dashed = SLO %gx" % slo)
    ax2.axhline(1, color=C_QUIET, lw=2, zorder=0); ax2.axhline(slo, color="k", ls="--", lw=1); slo_label(ax2, slo, slo)
    ylabel2(ax2, "overload / quiet", "")
    ylabel2(ax3, "cores under overload", "victim + replica, or victim + lent")
    ax3.set_xlabel("offered load (rps, 800 base + extra from t = 20 s)")
    ax3.set_xticks(loads); ax3.set_xticklabels([str(L) for L in loads], fontsize=8)
    ax1.legend(fontsize=8.5, frameon=False, loc="lower right")
    ntr = max(len(rs) for L in loads for rs in by_load[L].values())
    suptitle2(fig, "Overloaded victim: harvesting vs replication across the load",
              "search victim on thread%s %s, %s; up to %d trials per point" % ("" if VP == 1 else "s", VTHREADS, MACHINE, ntr))
    fig.tight_layout(rect=(0, 0, 1, 0.94))
    save(fig, out, "motiv3_sweep")

# ----------------------------------------------------------------------------- simplified figures (default)
SIMPLE_CELLS = [  # (key, label) or a list of alternatives, first available wins; "ext4:" keys come from EXT4_SWEEPS
    ("none-quiet", "none"),
    ("hc-hold-quiet", "harvesting"),
    # ("rep3p-medium", "replication\n(reactive,\nmedium-load node)"),   # dropped from the default (user 2026-11-10); --with-medium
    # quiet replica node: the reactive cell (rep3p:quiet) has not been run yet (cluster lost 2026-11-09);
    # until it exists the forced cell stands in, labelled pre-provisioned (applied at 120 s, not triggered)
    [("rep3p-quiet", "replication\n(reactive,\nquiet node)"), ("rep3f-quiet", "replication\n(pre-provisioned,\nquiet node)")],
    # 4-thread cells dropped from the default (user 2026-11-09: not helpful under bursts); see --full
]


def pick_cells(spec, have):
    """Resolve SIMPLE_CELLS-style entries against the available cell keys."""
    out = []
    for e in spec:
        alts = e if isinstance(e, list) else [e]
        for k, l in alts:
            if k in have:
                out.append((k, l)); break
    return out


def _simple_rows(root, sweeps):
    rows = load_rows(root, sweeps)
    ext4 = load_rows(root, EXT4_SWEEPS)
    for c in ext4:
        rows["ext4:" + c] = ext4[c]
    return rows



def _budget_bar(ax, xi, rs, win, budget, replicas_note="", width=0.6, numbers="parts"):
    """One core-budget bar: outline = budget the arm may use; filled from the bottom with the victim's
    use (purple), the replicas' use (orange), the victim-pool cores lent to the tenant (blue hatched);
    the rest is unused budget. Error bars = min-max over trials on the used total and on the lent part."""
    v = [r["c_victim_" + win] for r in rs]
    on = [r.get("c_ovf_node3_" + win, 0.0) for r in rs]
    lent = [r.get("lent_" + win, float("nan")) for r in rs]
    lent = [x for x in lent if not np.isnan(x)]
    vm, om = np.mean(v), np.mean(on)
    used = [a + b for a, b in zip(v, on)]
    ax.bar(xi, budget, width, facecolor="white", edgecolor="#444444", lw=1.0, zorder=1)
    ax.bar(xi, vm, width, color=C_VICTIM, zorder=2)
    ax.bar(xi, om, width, bottom=vm, color=C_REP, hatch="//", edgecolor="white", zorder=2)
    um = vm + om
    if len(used) > 1 and max(used) > min(used):
        ax.errorbar(xi, um, yerr=[[um - min(used)], [max(used) - um]], fmt="none", ecolor="k", lw=0.8, capsize=3, zorder=4)
    top_txt = um
    if lent and np.mean(lent) >= 0.05:   # lent-out part hangs from the TOP of the budget: given away, not harvested (user 2026-11-09)
        lm = np.mean(lent)
        ax.bar(xi, lm, width, bottom=budget - lm, facecolor="#9ecae1", edgecolor=C_HC, hatch="xx", lw=1.0, zorder=2)
        if len(lent) > 1 and max(lent) > min(lent):
            ax.errorbar(xi, budget - lm, yerr=[[max(lent) - lm], [lm - min(lent)]], fmt="none", ecolor=C_HC, lw=0.8, capsize=3, zorder=4)
        ax.text(xi + width / 2 + 0.03, budget - lm / 2, "%.1f lent" % lm, ha="left", va="center", fontsize=7, color=C_HC)
        top_txt = budget
    if numbers == "parts":
        ax.text(xi - width / 2 - 0.03, vm / 2, "%.1f" % vm, ha="right", va="center", fontsize=7, color=C_VICTIM)
        if om > 0.05:
            ax.text(xi - width / 2 - 0.03, vm + om / 2, "%.1f" % om, ha="right", va="center", fontsize=7, color=C_REP)
    else:   # "total": one number for the used cores, left of the stack (for panels whose budget outline dwarfs the use)
        ax.text(xi - width / 2 - 0.03, um, "%.1f" % um, ha="right", va="center", fontsize=7, color="#333333")
    if replicas_note:
        ax.text(xi, budget + 0.08, replicas_note, ha="center", va="bottom", fontsize=7.5)
    return budget


def fig_bars_simple(root, out, sweeps, slo=1.5, key="proc95"):
    rows = _simple_rows(root, sweeps)
    cells = pick_cells(SIMPLE_CELLS, rows)
    n_tr = max(len(rows[k]) for k, _ in cells)
    fig, (ax, axc) = plt.subplots(2, 1, figsize=(1.6 * len(cells) + 2.2, 6.4), sharex=True, gridspec_kw=dict(height_ratios=[1.8, 1.0]))
    x = np.arange(len(cells)); w = 0.36
    base = np.mean([r["s_%s_p1" % key] for k, _ in cells for r in rows[k]])
    top = 0
    for i, (k, lbl) in enumerate(cells):
        rs = rows[k]; col = family_color(split(k)[0])[0]
        for j, (win, hollow) in enumerate((("p3gap", True), ("p3b", False))):
            v = [r["s_%s_%s" % (key, win)] for r in rs if r.get("s_%s_%s" % (key, win)) is not None]
            if not v:
                continue
            m, lo, hi = np.mean(v), np.min(v), np.max(v)
            xx = x[i] + (j - 0.5) * w
            if hollow:
                ax.bar(xx, m, w, facecolor="white", edgecolor=col, lw=1.4, yerr=[[m - lo], [hi - m]] if hi > lo else None, capsize=2, error_kw=dict(lw=0.8, ecolor="k"))
            else:
                ax.bar(xx, m, w, color=col, yerr=[[m - lo], [hi - m]] if hi > lo else None, capsize=2, error_kw=dict(lw=0.8, ecolor="k"))
                ax.text(xx, hi + 0.015 * base, "%.2fx" % (m / base), ha="center", va="bottom", fontsize=8)
            top = max(top, hi)
    ax.axhline(base, color="#888888", ls=":", lw=1.2)
    ax.axhline(slo * base, color="k", ls="--", lw=1.1); slo_label(ax, slo * base, slo, x=0.01, ha="left")
    ax.set_ylim(0, top * 1.25)
    ax.set_ylabel("service handler %s (us)" % key[4:].join(["p", ""]))
    ax.text(0.01, 0.97, "%d trial%s, min-max; number = during bursts vs quiet" % (n_tr, "s" if n_tr > 1 else ""), transform=ax.transAxes, ha="left", va="top", **SUB)
    # core budget per arm and how it is used during the bursts
    top = 0
    for i, (k, lbl) in enumerate(cells):
        rs = rows[k]; arm = split(k)[0]
        if arm.startswith("rep"):
            # outline = the victim's own 2 cores (same as the other arms); the replica allowance is text,
            # an outline of 2 + 2 x cap would dwarf everything else (user 2026-11-09)
            cap = int(arm.strip("rep").rstrip("fp") or 1)
            note = ("+2 cores per replica, cap %d" % cap) if not arm.endswith("f") else ("+2 cores x %d replica%s" % (cap, "s" if cap > 1 else ""))
        else:
            note = ""
        top = max(top, _budget_bar(axc, x[i], rs, "p3b", 2, note))
    axc.set_ylim(0, top * 1.6)
    axc.set_ylabel("core budget and its use\nduring the bursts")
    axc.set_xticks(x); axc.set_xticklabels([l for _, l in cells], fontsize=9)
    h = [Patch(facecolor="white", edgecolor="#555555", lw=1.4, label="between bursts"), Patch(color="#555555", label="during bursts"),
         Line2D([], [], color="#888888", ls=":", lw=1.2, label="quiet"), Line2D([], [], color="k", ls="--", lw=1.1, label="SLO = %gx quiet" % slo),
         Patch(facecolor="white", edgecolor="#444444", label="core budget (outline)"), Patch(color=C_VICTIM, label="used by the victim"),
         Patch(facecolor=C_REP, hatch="//", edgecolor="white", label="used by replicas"),
         Patch(facecolor="#9ecae1", edgecolor=C_HC, hatch="xx", label="lent out to the aggressors")]
    fig.legend(handles=h, loc="lower center", ncol=4, fontsize=8.5, frameon=False, bbox_to_anchor=(0.5, -0.005))
    suptitle2(fig, "Bursty neighbours: what each mitigation buys",
              "search victim on threads %s, %s; bursts 6 s on / 54 s off; harvesting enabled at 120 s; " % (VTHREADS, MACHINE) +
              "reactive replication: score trigger, +1 replica per 2 s" + ("; pre-provisioned: 3 replicas from 120 s" if any(split(k)[0].endswith("f") for k, _ in cells) else ""))
    fig.tight_layout(rect=(0, 0.09, 1, 0.93))
    save(fig, out, "motiv3_bars")


def fig_ts_simple(root, out, sweeps, cells=("none-quiet", "hc-hold-quiet", ["rep3p-quiet", "rep3f-quiet"], "rep6p-quiet"), x=(0, 262), slo=1.5, name="motiv3_ts"):
    # user 2026-11-12: the cap-6 reactive cell as a 4th panel; replication titled by its cap only (one replication style, as in motiv3_eq)
    titles = {"none-quiet": "none", "hc-hold-quiet": "harvesting", "rep3p-medium": "replication, cap 3 (medium-load node)",
              "rep3p-quiet": "replication, cap 3", "rep3f-quiet": "replication, 3 pre-provisioned", "rep6p-quiet": "replication, cap 6",
              "ext4:hc-grow-ext-quiet": "harvesting, 2 + 2 shared"}
    data = {}
    for e in cells:
        for c in (e if isinstance(e, list) else [e]):   # a list = alternatives, first available wins
            for sw in (EXT4_SWEEPS if c.startswith("ext4:") else sweeps):
                d = os.path.join(root, sw, c.split(":", 1)[-1])
                if glob.glob(os.path.join(d, "stage3eval_*")):
                    data[c] = ts_load(d); break
            if c in data:
                break
    cells = [c for e in cells for c in (e if isinstance(e, list) else [e]) if c in data]
    fig, axes = plt.subplots(2, len(cells), figsize=(max(3.9 * len(cells), 6.0), 5.6), sharex=True, sharey="row", squeeze=False, gridspec_kw=dict(height_ratios=[1.4, 1.0]))
    base95 = np.nanmean(np.concatenate([d["p95"][(d["t"] > 2) & (d["t"] < 29)] for d in data.values()]))
    cmax = max([2.3] + [float(np.nanmax(d["lent"][1])) * 1.15 for d in data.values() if len(d["lent"][0])]
               + [float(np.nanmax(series_sum(d["vic"], d["rep"], d["lent"])[1])) * 1.1 for d in data.values() if len(d["rep"][0]) or len(d["lent"][0])])
    for j, c in enumerate(cells):
        d = data[c]; col = family_color(split(c)[0])[0]
        for ax in axes[:, j]:
            for a, b in d["bursts"]:
                ax.axvspan(a, b, color="#bbbbbb", alpha=0.35, lw=0)
            ax.axvline(d["arm"], color="k", ls="--", lw=0.8)
        ax = axes[0, j]
        ax.plot(d["t"], d["p95"], color=C_LAT, lw=1.0)
        ax.axhline(slo * base95, color="k", ls=":", lw=0.8); slo_label(ax, slo * base95, slo, fontsize=7, x=0.01, ha="left")
        ax.set_title(titles.get(c, c), fontsize=10)
        ax = axes[1, j]
        ax.plot(*d["vic"], color=C_VICTIM, lw=1.2)
        if len(d["rep"][0]):
            ax.plot(*d["rep"], color=C_REP, lw=1.2)
        if len(d["lent"][0]):
            ax.plot(*d["lent"], color=C_HC, ls="--", lw=1.2)
        if len(d["rep"][0]) or len(d["lent"][0]):   # total cores the mitigation uses: victim + replicas, or victim + lent (user 2026-11-10)
            ax.plot(*series_sum(d["vic"], d["rep"], d["lent"]), color=C_TOTAL, ls="-.", lw=1.1)
        if d["n_rep"].max() > 0:
            ax2 = ax.twinx()
            ax2.step(d["t"], d["n_rep"], where="post", color="#555555", lw=1.0)
            ax2.set_ylim(0, 6.5); ax2.set_yticks([0, 2, 4, 6])
            if j == len(cells) - 1 or True:
                ax2.set_ylabel("replicas", fontsize=9, color="#555555")
        ax.set_xlabel("time (s)")
    axes[0, 0].set_ylabel("service handler p95 (us)")
    axes[0, 0].set_ylim(0, max(100, 1.1 * np.nanmax([np.nanmax(d["p95"][(d["t"] > 2) & (d["t"] < x[1])]) for d in data.values()])))   # whole trace: no clipped peak
    axes[1, 0].set_ylabel("cores")
    axes[1, 0].set_ylim(0, cmax)
    axes[0, 0].set_xlim(*x)
    h = [Patch(facecolor="#bbbbbb", alpha=0.6, label="aggressor burst"), Line2D([], [], color="k", ls="--", lw=1, label="mitigation enabled (120 s)"),
         Line2D([], [], color="k", ls=":", lw=1, label="SLO = %gx quiet p95" % slo),
         Line2D([], [], color=C_VICTIM, lw=1.5, label="victim cores"), Line2D([], [], color=C_REP, lw=1.5, label="replica cores"),
         Line2D([], [], color=C_HC, ls="--", lw=1.5, label="lent to aggressors"), Line2D([], [], color=C_TOTAL, ls="-.", lw=1.2, label="total cores (victim + replicas, or + lent)"),
         Line2D([], [], color="#555555", lw=1.0, label="replicas serving (right axis)")]
    fig.legend(handles=h, loc="lower center", ncol=4 if len(cells) > 1 else 2, fontsize=8.5, frameon=False, bbox_to_anchor=(0.5, -0.005))
    suptitle2(fig, "Bursty neighbours over time (trial 1)" + ("" if len(cells) > 1 else ": " + titles.get(cells[0], cells[0])),
              "search victim on threads %s, %s; 1 s bins" % (VTHREADS, MACHINE))
    fig.tight_layout(rect=(0, 0.09 if len(cells) > 1 else 0.14, 1, 0.92))
    save(fig, out, name)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--slo", type=float, default=1.5)
    ap.add_argument("--machine", default="sm110p", choices=sorted(MACHINES), help="machine text of the subtitles (victim threads, frequency)")
    ap.add_argument("--ext", default="motiv3,motiv3-t2,motiv3-react,motiv3-react-t2,motiv3-pid,motiv3-pid-t2,motiv3-pidq,motiv3-pidq-t2", help="extrinsic sweep dirs under root (missing dirs are skipped)")
    ap.add_argument("--int", dest="int_", default="motiv3-int,motiv3-int-t2", help="intrinsic sweep dirs under root")
    ap.add_argument("--grow", default="motiv3-grow,motiv3-grow-t2", help="hc-grow (4-thread victim) sweep dirs under root")
    ap.add_argument("--sweep", default="sweep1p", help="dir under root with L<rps>-t<trial> sweep dirs (figure 'sweep', not in the default set)")
    ap.add_argument("--onep", action="store_true", help="intrinsic figure of the 1-P variant (victim thread 4, hc-grow1 = 4 own + 6 shared, 1-P replica; c6320 only)")
    ap.add_argument("--int-rps", default="", help="offered rps text of the intrinsic figure (default per machine / 5000 with --onep)")
    ap.add_argument("--only", default="")
    ap.add_argument("--loads", default="medium", help="node-3 conditions of the replication cells in the bars figure (comma list of quiet,medium,contended)")
    ap.add_argument("--panels", default="proc50,proc95", help="latency rows of the bars figure (comma list of proc50,proc90,proc95,proc99)")
    ap.add_argument("--arms", default="none,hc-hold", help="non-replication cells of the bars figure (comma list of none,hc-bang,hc-hold)")
    ap.add_argument("--rep-arms", default="rep3p,rep6p", help="replication arms of the bars figure: rep<k> = reactive trigger, rep<k>f = forced at the enable")
    ap.add_argument("--alloc", action="store_true", help="add the cores-allocated (CPU limits) row to the bars figure")
    ap.add_argument("--with-medium", action="store_true", help="also show reactive replication on the medium-load node-3 (bars, cdf, ts)")
    ap.add_argument("--full", action="store_true", help="detailed bars / time-series figures (4 bars per cell, p50 row, all cells) instead of the simplified defaults")
    a = ap.parse_args()
    global MACHINE, VTHREADS, GROW_THREADS, INT_RPS, VP, GROW_CELL
    if a.with_medium:   # re-insert the medium-load-node replication cell (dropped from the defaults, user 2026-11-10)
        SIMPLE_CELLS.insert(2, ("rep3p-medium", "replication\n(reactive,\nmedium-load node)"))
        full = ("none-quiet", "hc-hold-quiet", "rep3p-medium", ["rep3p-quiet", "rep3f-quiet"])
        for f in (fig_cdf, fig_ts_simple):
            f.__defaults__ = tuple(full if isinstance(d, tuple) and d and d[0] == "none-quiet" else d for d in f.__defaults__)
    MACHINE, VTHREADS, GROW_THREADS, INT_RPS = MACHINES[a.machine]
    if a.onep:
        VP, GROW_CELL, VTHREADS, GROW_THREADS, INT_RPS = 1, "hc-grow1-quiet", "4", "6", "5000"
    if a.int_rps:
        INT_RPS = a.int_rps
    ext = [s for s in a.ext.split(",") if os.path.isdir(os.path.join(a.root, s))]
    int_ = [s for s in a.int_.split(",") if os.path.isdir(os.path.join(a.root, s))]
    grow = [s for s in a.grow.split(",") if os.path.isdir(os.path.join(a.root, s))]
    figs = dict(bars=lambda: fig_bars(a.root, a.out, ext, a.slo, tuple(a.loads.split(",")), tuple(a.panels.split(",")), tuple(a.arms.split(",")), tuple(a.rep_arms.split(",")), a.alloc) if a.full else fig_bars_simple(a.root, a.out, ext, a.slo), cdf=lambda: fig_cdf(a.root, a.out, ext), ts=lambda: (fig_ts if a.full else fig_ts_simple)(a.root, a.out, ext, slo=a.slo),
                ts6=lambda: fig_ts_simple(a.root, a.out, ext, cells=("rep6p-quiet",), slo=a.slo, name="motiv3_ts_cap6"),
                int=lambda: fig_int(a.root, a.out, int_, a.slo, tuple(grow)), sweep=lambda: fig_sweep(a.root, a.out, a.sweep, a.slo))
    for k in (a.only.split(",") if a.only else ("bars", "cdf", "ts", "int")):
        if k == "sweep":
            figs[k](); continue
        if (k == "int" and not int_) or (k != "int" and not ext):
            print("skip", k, "(no data)"); continue
        figs[k]()


if __name__ == "__main__":
    main()
