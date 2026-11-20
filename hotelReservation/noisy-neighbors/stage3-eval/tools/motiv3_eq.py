#!/usr/bin/env python3
"""motiv3_eq.py -- the evaluation-question figure and table for the motivation experiment (user 2026-11-11).

  EQ1  at the same SLO target per scenario (symptom x source), how much of the degradation do the matched and the
       mismatched mitigation remove?
  EQ2  to reach that SLO, how large a core budget does each need?

One column per scenario (tail extrinsic: p95 in the bursts; steady intrinsic: p50 of the overload), each a ratio to
the run's own quiet phase. Top: latency ratio vs the victim's allocated core budget (threads it may use: own threads
+ replica threads, or own + harvestable threads) per mitigation family, with the SLO line -- where a curve crosses the
line is EQ2, reading vertically at one budget compares the two at the same budget, and the vertical distance from
the unmitigated point is EQ1. Bottom: cores actually consumed (victim + replicas, plus cores lent to the co-tenants
by harvesting). Reactive replication cells are plotted at their cap with hollow markers and the replicas seen.

  python tools/motiv3_eq.py --root C:/tmp/motiv3/data --out <dir> --slo 1.3 \
      --tail motiv3-c6320,motiv3-c6320-t2,eq/tail-t1,eq/tail-t2 --steady eq/steady-t1,eq/steady-t2,eq/steady-t3
"""
import argparse
import csv
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import motiv3_plot as P  # noqa: E402

plt = P.plt
AGG = "median"   # aggregate over trials (--agg); the bars are always min-max


def agg(v):
    return np.median(v) if AGG == "median" else np.mean(v)

# cell -> (family, nominal budget in threads, label); budgets: tail victim 2 threads + 2 per 2-P replica,
# steady victim 1 thread + 1 per 1-P replica or per shared thread
TAIL_CELLS = {
    "none-quiet": ("none", 2, "no mitigation"),
    "hc-hold-quiet": ("hc", 2, "harvesting"),
    "rep1f-quiet": ("rep", 4, "1 replica"), "rep3f-quiet": ("rep", 8, "3 replicas"), "rep6f-quiet": ("rep", 14, "6 replicas"),
    "rep3p-quiet": ("repp", 8, "reactive, cap 3"), "rep6p-quiet": ("repp", 14, "reactive, cap 6"),
}
STEADY_CELLS = {
    "none-quiet": ("none", 1, "no mitigation"),
    "hc-grow1-quiet": ("hc", 2, "1 shared"), "hc-grow2-quiet": ("hc", 3, "2 shared"), "hc-grow3-quiet": ("hc", 4, "3 shared"),
    "rep1f-quiet": ("rep", 2, "1 replica"), "rep2f-quiet": ("rep", 3, "2 replicas"), "rep3f-quiet": ("rep", 4, "3 replicas"), "rep4f-quiet": ("rep", 5, "4 replicas"),
}
FAM = {"none": ("no mitigation", P.C_NONE, "o"), "hc": ("harvesting", P.C_HC, "s"), "rep": ("replication (pre-provisioned)", P.C_REP, "^"),
       "repp": ("replication (reactive)", P.C_REP, "^")}


def points(rows, cells, key, stat, win):
    """[(family, budget, label, ratios[], consumed[], lent[], replicas[])] sorted by budget."""
    out = []
    for cell, (fam, budget, label) in cells.items():
        rs = rows.get(cell, [])
        if not rs:
            continue
        k = "s_%s%s" % (key, stat)
        rat = [r[k + "_" + win] / r[k + "_p1"] for r in rs if r.get(k + "_" + win) is not None]
        con = [r["c_victim_" + win] + r.get("c_ovf_node3_" + win, 0.0) for r in rs]
        lent = [r.get("lent_" + win, float("nan")) for r in rs] if fam == "hc" else [0.0] * len(rs)
        rep = [int(r.get("replicas_seen", 0)) for r in rs]
        out.append((fam, budget, label, rat, con, lent, rep))
    return sorted(out, key=lambda t: (t[0], t[1]))


def crossing(pts, slo):
    """Smallest budget at which the family's mean ratio <= slo (linear interpolation between budgets), or None."""
    xs = [p[1] for p in pts]; ys = [agg(p[3]) for p in pts]
    for i, (x, y) in enumerate(zip(xs, ys)):
        if y <= slo:
            if i == 0:
                return x
            x0, y0 = xs[i - 1], ys[i - 1]
            return x0 + (x - x0) * (y0 - slo) / (y0 - y) if y0 > y else x
    return None


def panel(ax1, ax2, pts, slo, xlabel, title, stat_label, log=False):
    none = [p for p in pts if p[0] == "none"]
    ref = agg(none[0][3]) if none else float("nan")
    xmax = max(p[1] for p in pts) + 1
    for fam in ("hc", "rep", "repp"):
        fp = [p for p in pts if p[0] == fam]
        if not fp:
            continue
        name, col, mk = FAM[fam]
        xs = [p[1] for p in fp]; m = [agg(p[3]) for p in fp]; lo = [min(p[3]) for p in fp]; hi = [max(p[3]) for p in fp]
        hollow = fam == "repp"
        ax1.errorbar(xs, m, yerr=[np.subtract(m, lo), np.subtract(hi, m)], fmt=mk + ("--" if hollow else "-"), color=col, mfc="white" if hollow else col,
                     ms=6, lw=1.5, capsize=2, label=name)
        for p in fp:
            ax1.annotate(p[2] + ("" if fam != "repp" else "\n(%s seen)" % "/".join(str(n) for n in p[6])), (p[1], agg(p[3])),
                         textcoords="offset points", xytext=(0, 9 if fam != "rep" else -16), ha="center", fontsize=6.5, color=col)
        cm = [agg(p[4]) for p in fp]; clo = [min(p[4]) for p in fp]; chi = [max(p[4]) for p in fp]
        ax2.errorbar(xs, cm, yerr=[np.subtract(cm, clo), np.subtract(chi, cm)], fmt=mk + ("--" if hollow else "-"), color=col, mfc="white" if hollow else col, ms=6, lw=1.5, capsize=2)
        if fam == "hc":
            lent = [np.nanmean(p[5]) for p in fp]
            if not all(np.isnan(lent)):
                ax2.plot(xs, np.nan_to_num(lent), ":", color=col, lw=1.2, marker="x", ms=5, label="lent to co-tenants (harvesting)")
    if none:
        p = none[0]
        ax1.errorbar([p[1]], [ref], yerr=[[ref - min(p[3])], [max(p[3]) - ref]], fmt="o", color=P.C_NONE, ms=7, capsize=2, label="no mitigation", zorder=5)
        ax1.annotate("%.2fx" % ref, (p[1], ref), textcoords="offset points", xytext=(8, 0), fontsize=7, va="center")
        ax2.plot([p[1]], [agg(p[4])], "o", color=P.C_NONE, ms=7)
    ax1.axhline(1, color=P.C_QUIET, lw=2, zorder=0)
    ax1.axhline(slo, color="k", ls="--", lw=1); P.slo_label(ax1, slo, slo, x=0.99)
    ax2.plot([0, xmax], [0, xmax], color="#bbbbbb", lw=0.8, ls=":", zorder=0)   # consumed = allocated
    top2 = max(max(p[4]) for p in pts)
    ax2.set_ylim(0, max(top2 * 1.45, 1.0))   # the guide line is clipped, not the bars
    if log:
        ax1.set_yscale("log")
    ax1.set_xlim(0, xmax); ax2.set_xlim(0, xmax)
    ax1.set_title(title, fontsize=9.5)
    P.ylabel2(ax1, stat_label, "ratio to the run's quiet phase; dashed = SLO")
    P.ylabel2(ax2, "cores consumed", "victim + replicas; dotted grey = allocated")
    ax2.set_xlabel(xlabel)
    ax1.legend(fontsize=7, frameon=False, loc="upper right")
    if ax2.get_legend_handles_labels()[0]:
        ax2.legend(fontsize=7, frameon=False, loc="lower right")


# bar layout (user 2026-11-12: follow the motiv3_bars style): cells grouped by equal thread budget, left to right
TAIL_GROUPS_ALL = [(2, ["none-quiet", "hc-hold-quiet"]), (4, ["rep1f-quiet"]), (8, ["rep3f-quiet", "rep3p-quiet"]), (14, ["rep6f-quiet", "rep6p-quiet"])]
STEADY_GROUPS_ALL = [(1, ["none-quiet"]), (2, ["hc-grow1-quiet", "rep1f-quiet"]), (3, ["hc-grow2-quiet", "rep2f-quiet"]),
                     (4, ["hc-grow3-quiet", "rep3f-quiet"]), (5, ["rep4f-quiet"])]
# the paper figure (user 2026-11-12): tail without the pre-provisioned replication cells, steady without the 3- and 5-thread groups
TAIL_GROUPS = [(2, ["none-quiet", "hc-hold-quiet"]), (8, ["rep3p-quiet"]), (14, ["rep6p-quiet"])]
STEADY_GROUPS = [(1, ["none-quiet"]), (2, ["hc-grow1-quiet", "rep1f-quiet"]), (4, ["hc-grow3-quiet", "rep3f-quiet"])]
BAR_LABEL = {"none-quiet": "none", "hc-hold-quiet": "harvesting", "rep1f-quiet": "1 replica", "rep3f-quiet": "3 replicas", "rep6f-quiet": "6 replicas",
             "rep3p-quiet": "replication\ncap 3", "rep6p-quiet": "replication\ncap 6", "hc-grow1-quiet": "harvesting\n1 shared", "hc-grow2-quiet": "harvesting\n2 shared",
             "hc-grow3-quiet": "harvesting\n3 shared", "rep2f-quiet": "2 replicas", "rep4f-quiet": "4 replicas"}


def bar_column(ax, axc, rows, groups, key, stat, win, slo, unit, log, phase_label, gap=0.7, step=1.25, numbers="parts"):
    """One scenario in the motiv3_bars style. Top: quiet bar (grey) + the phase bar (family colour) per cell,
    number = phase / quiet, dashed SLO; bottom: thread budget as an outline, filled with the cores the victim,
    its replicas and (harvesting) the lent-out part actually use. Cells sit in groups of equal budget."""
    import matplotlib.transforms as mtransforms
    k = "s_%s%s" % (key, stat)
    xs, labels, seps, centers, n_tr = [], [], [], [], 0
    x = 0.0; w = 0.38; top = 0.0; ctop = 0.0
    base = agg([r[k + "_p1"] for _, cells in groups for c in cells for r in rows.get(c, [])])
    for budget, cells in groups:
        present = [c for c in cells if rows.get(c)]
        if not present:
            continue
        if xs:
            x += gap; seps.append(x - gap / 2 - step / 2)
        x0 = x
        for c in present:
            rs = rows[c]; n_tr = max(n_tr, len(rs))
            fam = "none" if c.startswith("none") else "hc" if c.startswith("hc") else "rep"
            col = FAM[fam][1]
            reactive = False   # user 2026-11-12: one replication style (solid orange); the reactive cells scale up as the burst starts anyway
            q = [r[k + "_p1"] for r in rs]; v = [r[k + "_" + win] for r in rs if r.get(k + "_" + win) is not None]
            qm = agg(q); m, lo, hi = agg(v), min(v), max(v)
            ax.bar(x - w / 2, qm, w, facecolor=P.C_QUIET, edgecolor="#777777", lw=0.5, zorder=2)
            ax.bar(x + w / 2, m, w, facecolor="white" if reactive else col, edgecolor=col, lw=1.4, zorder=2,
                   yerr=[[m - lo], [hi - m]] if hi > lo else None, capsize=2, error_kw=dict(lw=0.8, ecolor="k"))
            ax.text(x + w / 2, hi * (1.06 if log else 1) + (0 if log else 0.012 * base), "%.2fx" % (m / qm), ha="center", va="bottom", fontsize=8,
                    bbox=dict(facecolor="white", edgecolor="none", alpha=0.75, pad=0.6), zorder=5)
            top = max(top, hi)
            note = ""
            ctop = max(ctop, P._budget_bar(axc, x, rs, win, budget, note, width=0.6, numbers=numbers))
            xs.append(x); labels.append(BAR_LABEL.get(c, c)); x += step
        centers.append(((x0 + x - step) / 2, budget))
    ax.axhline(base, color="#888888", ls=":", lw=1.2)
    ax.axhline(slo * base, color="k", ls="--", lw=1.1); P.slo_label(ax, slo * base, slo, x=0.01, ha="left")
    if log:
        ax.set_yscale("log"); ax.set_ylim(base * 0.4, top * 4.0)
    else:
        ax.set_ylim(0, top * 1.3)
    for s in seps:
        ax.axvline(s, color="#cccccc", lw=0.8, ls=":"); axc.axvline(s, color="#cccccc", lw=0.8, ls=":")
    tr = mtransforms.blended_transform_factory(ax.transData, ax.transAxes)
    for cx, b in centers:   # the budget of each group, along the top of the latency panel
        ax.text(cx, 0.985, "%d thread%s" % (b, "s" if b > 1 else ""), transform=tr, ha="center", va="top", fontsize=8, color="#444444")
    ax.set_ylabel("%s (%s%s)" % (phase_label, unit, ", log" if log else ""))
    axc.set_ylim(0, ctop * 1.3)
    axc.set_xticks(xs); axc.set_xticklabels(labels, fontsize=8)
    axc.set_xlim(-0.7, x - step + 0.7)
    return n_tr


def fig_bars(tail_rows, steady_rows, a):
    tg, sg = (TAIL_GROUPS_ALL, STEADY_GROUPS_ALL) if a.all_cells else (TAIL_GROUPS, STEADY_GROUPS)
    from matplotlib.patches import Patch
    from matplotlib.lines import Line2D
    lat = {"tot": "total", "proc": "processing"}
    ncol = (1 if tail_rows else 0) + (1 if steady_rows else 0)
    fig, axes = plt.subplots(2, ncol, figsize=((6.9 if a.all_cells else 4.9) * ncol + 1.0, 7.0), squeeze=False, sharex="col", gridspec_kw=dict(height_ratios=[1.6, 1.0]))
    j = 0; n_tr = []
    if tail_rows:
        n_tr.append(bar_column(axes[0, j], axes[1, j], tail_rows, tg, a.tail_key, a.tail_stat, "p3b", a.slo_tail, "us", False,
                               "%s p%s in the bursts" % (lat[a.tail_key], a.tail_stat), numbers="total"))
        axes[0, j].set_title("Tail symptom, extrinsic source: 10 % co-tenant bursts", fontsize=10, loc="left")
        axes[1, j].set_ylabel("thread budget and its use\nduring the bursts")
        j += 1
    if steady_rows:
        n_tr.append(bar_column(axes[0, j], axes[1, j], steady_rows, sg, a.steady_key, a.steady_stat, "ovl", a.slo_steady, "ms", True,
                               "%s p%s under overload" % (lat[a.steady_key], a.steady_stat)))
        axes[0, j].set_title("Steady symptom, intrinsic source: 3x overload", fontsize=10, loc="left")
        axes[1, j].set_ylabel("thread budget and its use\nunder overload")
    h = [Patch(facecolor=P.C_QUIET, edgecolor="#777777", label="quiet phase of the run"), Patch(color=P.C_NONE, label="no mitigation"),
         Patch(color=P.C_HC, label="harvesting"), Patch(color=P.C_REP, label="replication"),
         Line2D([], [], color="#888888", ls=":", lw=1.2, label="quiet (column mean)"), Line2D([], [], color="k", ls="--", lw=1.1, label="SLO"),
         Patch(facecolor="white", edgecolor="#444444", label="thread budget (outline)"), Patch(color=P.C_VICTIM, label="used by the victim"),
         Patch(facecolor=P.C_REP, hatch="//", edgecolor="white", label="used by replicas"),
         Patch(facecolor="#9ecae1", edgecolor=P.C_HC, hatch="xx", label="lent out to the co-tenants")]
    fig.legend(handles=h, loc="lower center", ncol=4, fontsize=8.5, frameon=False, bbox_to_anchor=(0.5, -0.005))
    P.suptitle2(fig, "Same SLO, same budget: what harvesting and replication buy in each scenario (SLO tail %gx, steady %gx quiet)" % (a.slo_tail, a.slo_steady),
                "%s; %s over %s trials, bars = min-max; number = phase vs the run's quiet phase; groups = equal thread budget (victim's own + replicas' or shared threads)"
                % (P.MACHINE, AGG, "/".join(str(n) for n in n_tr)))
    fig.tight_layout(rect=(0, 0.09, 1, 0.93))
    return fig


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default="data"); ap.add_argument("--out", default=".")
    ap.add_argument("--tail", default="motiv3-c6320,motiv3-c6320-t2,eq/tail-t1,eq/tail-t2")
    ap.add_argument("--steady", default="eq/steady-t1,eq/steady-t2,eq/steady-t3")
    ap.add_argument("--slo-tail", type=float, default=1.3, help="SLO (x quiet) of the tail cell, same target for both mitigations")
    ap.add_argument("--slo-steady", type=float, default=2.0, help="SLO (x quiet) of the steady cell (the chain itself is busier at 3x load, so ~1.5x is the floor)")
    ap.add_argument("--tail-key", default="proc", choices=("tot", "proc"), help="tail cell: processing time (default; the total includes the downstream services on node-1 that the aggressor chains also load) or total")
    ap.add_argument("--steady-key", default="tot", choices=("tot", "proc"), help="steady cell: total handler time incl. queueing (default) or processing time")
    ap.add_argument("--tail-stat", default="95"); ap.add_argument("--steady-stat", default="50")
    ap.add_argument("--machine", default="c6320", choices=list(P.MACHINES))
    ap.add_argument("--name", default="motiv3_eq")
    ap.add_argument("--all-cells", action="store_true", help="bar figure with every cell (default: the paper subset, see TAIL_GROUPS / STEADY_GROUPS)")
    ap.add_argument("--agg", default="median", choices=("median", "mean"), help="aggregate over trials (default median; one steady trial-1 outlier)")
    a = ap.parse_args()
    global AGG
    AGG = a.agg
    P.MACHINE, P.VTHREADS, P.GROW_THREADS, P.INT_RPS = P.MACHINES[a.machine]
    tail_rows = P.load_rows(a.root, [s for s in a.tail.split(",") if s])
    steady_rows = P.load_rows(a.root, [s for s in a.steady.split(",") if s], steady=True)
    tail = points(tail_rows, TAIL_CELLS, a.tail_key, a.tail_stat, "p3b")
    steady = points(steady_rows, STEADY_CELLS, a.steady_key, a.steady_stat, "ovl")
    if not tail and not steady:
        print("no cells"); return
    # the main figure: bars in the motiv3_bars style (user 2026-11-12); the budget curves go to <name>_curves
    P.save(fig_bars(tail_rows, steady_rows, a), a.out, a.name)
    name0 = a.name; a.name = a.name + "_curves"
    fig, axes = plt.subplots(2, 2, figsize=(9.6, 6.4), sharex="col", gridspec_kw=dict(height_ratios=[1.6, 1]))
    lat = {"tot": "total", "proc": "processing"}
    if tail:
        panel(axes[0, 0], axes[1, 0], tail, a.slo_tail, "allocated threads (victim 2 + 2 per replica)",
              "Tail symptom, extrinsic source: 10 % co-tenant bursts", "service %s p%s in the bursts" % (lat[a.tail_key], a.tail_stat))
    if steady:
        panel(axes[0, 1], axes[1, 1], steady, a.slo_steady, "allocated threads (victim 1 + 1 per replica or shared thread)",
              "Steady symptom, intrinsic source: 3x overload", "service %s p%s under overload" % (lat[a.steady_key], a.steady_stat), log=True)
    P.suptitle2(fig, "Degradation removed and cores needed to meet the SLO (tail %gx, steady %gx quiet)" % (a.slo_tail, a.slo_steady),
                "%s; %s over trials, bars = min-max" % (P.MACHINE, AGG))
    fig.tight_layout(rect=(0, 0, 1, 0.94))
    P.save(fig, a.out, a.name)
    # table
    rows = []
    for scen, pts, slo in (("tail", tail, a.slo_tail), ("steady", steady, a.slo_steady)):
        none = [p for p in pts if p[0] == "none"]; ref = agg(none[0][3]) if none else float("nan")
        for fam in ("hc", "rep", "repp"):
            fp = [p for p in pts if p[0] == fam]
            if fp:
                x = crossing(fp, slo)
                print("%-6s %-28s budget to meet SLO %gx: %s" % (scen, FAM[fam][0], slo, "%.1f threads" % x if x is not None else "not reached (max %d)" % fp[-1][1]))
        for p in pts:
            m = agg(p[3]); removed = (ref - m) / (ref - 1) if ref > 1 else float("nan")
            rows.append(dict(scenario=scen, family=FAM[p[0]][0], cell=p[2], budget=p[1], ratio="%.3f" % m, ratio_min="%.3f" % min(p[3]), ratio_max="%.3f" % max(p[3]),
                             removed="%.2f" % removed, meets_slo=int(m <= slo), consumed="%.2f" % agg(p[4]), lent="%.2f" % np.nanmean(p[5]) if p[0] == "hc" else "",
                             replicas_seen="/".join(str(n) for n in p[6]) if p[0].startswith("rep") else "", trials=len(p[3])))
            print("  %-6s %-30s %-16s budget %2d  ratio %.2fx (%.2f-%.2f)  removed %5.0f%%  consumed %.2f  %s" % (
                scen, FAM[p[0]][0], p[2], p[1], m, min(p[3]), max(p[3]), 100 * removed, agg(p[4]), "meets SLO" if m <= slo else ""))
    with open(os.path.join(a.out, name0 + ".csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)


if __name__ == "__main__":
    main()
