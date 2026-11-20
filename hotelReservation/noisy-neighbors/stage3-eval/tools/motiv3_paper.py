#!/usr/bin/env python3
"""motiv3_paper.py -- paper-style versions of the motivation figures (user's mock designs, 2026-11-12).

  motiv3_eqh_tail, motiv3_eqh_steady   horizontal bars: latency ratio to the run's quiet phase per mitigation at one
                                       budget, min-max over trials, dashed SLO with the "ok" band below it; on the
                                       right a "threads reserved" glyph per row (one square per thread: purple = used
                                       by the victim, orange hatched = used by its replicas, blue hatched = lent out,
                                       faint = reserved but idle) with the numbers in words; title + legend.
  motiv3_ts_rep6                       the cap-6 reactive replication run over the whole trial: p95 / quiet with the
                                       SLO band, the bursts and the enable; replicas serving below; annotated from
                                       the data (first burst after the enable, first replica, the next burst).

  MOTIV_LAYOUT=c6320 python tools/motiv3_paper.py --root C:/tmp/motiv3/data --out <dir>
"""
import argparse
import os
import sys

import numpy as np
import matplotlib.patheffects  # noqa: F401  (plt.matplotlib.patheffects)
from matplotlib.lines import Line2D
from matplotlib.patches import Patch, Rectangle

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import motiv3_plot as P   # noqa: E402
import motiv3_eq as E     # noqa: E402

plt = P.plt
plt.rcParams.update({"font.family": "sans-serif", "font.sans-serif": ["Arial", "Helvetica", "Liberation Sans", "DejaVu Sans"],
                     "pdf.fonttype": 42, "ps.fonttype": 42, "axes.spines.top": False, "axes.spines.right": False})
C_OK = "#eef2ea"          # the band below the SLO
C_OK_X = "#d4e4c6"        # a bit stronger for the single-panel figure (user 2026-11-14: legend swatch too light; 2026-11-16 darker again)
C_OK_EDGE = "#a9bf9a"
C_IDLE_X = "#dcdee4"      # idle / reserved-but-unused cores in eqx and tsx (user 2026-11-14: visible against the green band)
C_IDLE_X_EDGE = "#bfc3cb"
C_ARM = "#c4561d"   # the replication enable: a dark replica orange
C_BURST = "#ece4d6"       # co-tenant bursts in the tsx figure (user 2026-11-14: light sand, not grey like idle, not red)
C_IDLE_FACE = "#f5f5f5"   # a reserved-but-idle thread: faint square
C_IDLE_EDGE = "#d4d4d4"
C_USED_EDGE = "#777777"
C_LENT = "#9ecae1"        # lent-out part (as in the other figures)
C_PHASE_ON = "#fbe3cf"    # phase strip of the time series: mitigation enabled
X = "\u00d7"              # multiplication sign for the ratio ticks
F_AX = dict(fontsize=10.5, fontweight="bold", color="#111111")      # ticks, axis labels, row labels, the ratio numbers
F_SUB = dict(fontsize=9.5, fontweight="bold", color="#333333")       # the two part subtitles
F_DESC = dict(fontsize=8.5, color="#444444")                          # description text (words next to the glyphs, annotations)
F_LEG = dict(fontsize=8.5, labelcolor="#444444")
F_NAME = ["Georgia", "DejaVu Serif"]   # mitigation names in the eqx figure (user 2026-11-14: a different font)                      # legends

# rows of the bar figures: (cell, label, family, budget in threads); tail = victim's own 2 + 2 per replica, steady = own 1 + 1 per replica or shared thread
TAIL_ROWS = [("none-quiet", "no\nmitigation", "none", 2), ("hc-hold-quiet", "harvesting", "hc", 2), ("rep6p-quiet", "replication", "rep", 14)]
STEADY_ROWS = [("none-quiet", "no\nmitigation", "none", 1),
               ("hc-grow1-quiet", "harvesting\n2 threads", "hc", 2), ("rep1f-quiet", "replication\n2 threads", "rep", 2),
               ("hc-grow3-quiet", "harvesting\n4 threads", "hc", 4), ("rep3f-quiet", "replication\n4 threads", "rep", 4)]
COL = {"none": P.C_NONE, "hc": P.C_HC, "rep": P.C_REP}
TITLES = {"tail": "Tail symptom, extrinsic source: 10 % co-tenant bursts", "steady": "Steady symptom, intrinsic source: 3%s overload" % X}


def peak_replicas(root, sweeps, cell):
    """Most replicas serving at the same time after the enable, over all trials (not the distinct pods seen)."""
    peak = 0
    for sw in sweeps:
        d = os.path.join(root, sw, cell)
        if P.glob.glob(os.path.join(d, "stage3eval_*")):
            ts = P.ts_load(d)
            peak = max(peak, int(ts["n_rep"][ts["t"] >= ts["arm"]].max()))
    return peak


def row_stats(rs, key, stat, win):
    k = "s_%s%s" % (key, stat)
    rat = [r[k + "_" + win] / r[k + "_p1"] for r in rs if r.get(k + "_" + win) is not None]
    vic = [r["c_victim_" + win] for r in rs]
    rep = [r.get("c_ovf_node3_" + win, 0.0) for r in rs]
    lent = [v for v in (r.get("lent_" + win, float("nan")) for r in rs) if not np.isnan(v)]
    return E.agg(rat), min(rat), max(rat), E.agg(vic), E.agg(rep), (E.agg(lent) if lent else 0.0)


def _fill(ax, x, y, side, f0, f1, **kw):
    """Fill the [f0, f1] fraction (0..1) of the square at (x, y)."""
    f0, f1 = max(f0, 0.0), min(f1, 1.0)
    if f1 > f0:
        ax.add_patch(Rectangle((x + side * f0, y - side / 2), side * (f1 - f0), side, zorder=3, **kw))


def glyph(ax, y, budget, vic, rep, lent, x0=0.0, per_row=7):
    """One square per reserved thread at row y, wrapped into rows of `per_row` (so 14 threads are as wide as 4),
    filled from the first thread with the victim's cores (purple) then the replicas' (orange, hatched), from the
    last thread backwards with the lent-out cores (blue, hatched); the rest is a faint square."""
    nrows = -(-budget // per_row)
    per_row = -(-budget // nrows)   # balance the rows (8 -> 4 + 4, not 7 + 1)
    side = 0.46 if nrows == 1 else 0.27
    pitch = side * 1.16
    ncols = min(budget, per_row)
    block_h = nrows * pitch - (pitch - side)
    for i in range(budget):
        r, c = divmod(i, per_row)
        x = x0 + c * pitch
        yy = y + block_h / 2 - side / 2 - r * pitch
        used_here = min(max(vic + rep - i, 0.0), 1.0)
        lent_here = min(max(lent - (budget - 1 - i), 0.0), 1.0)
        idle = used_here <= 0 and lent_here <= 0
        ax.add_patch(Rectangle((x, yy - side / 2), side, side, facecolor=C_IDLE_FACE if idle else "white",
                               edgecolor=C_IDLE_EDGE if idle else C_USED_EDGE, lw=0.6 if idle else 0.8, zorder=2))
        _fill(ax, x, yy, side, 0.0, vic - i, facecolor=P.C_VICTIM, edgecolor="none")
        _fill(ax, x, yy, side, vic - i, vic + rep - i, facecolor=P.C_REP, edgecolor="white", hatch="///", lw=0)
        if lent_here > 0:
            _fill(ax, x, yy, side, 1.0 - lent_here, 1.0, facecolor=C_LENT, edgecolor=P.C_HC, hatch="xxx", lw=0.6)
    return x0 + ncols * pitch + 0.12


def fig_eqh(rows_in, spec, key, stat, win, slo, xlabel, name, out, title, log=False, xticks=None, during="during bursts", notes=None):
    rows = [(c, lbl, fam, b) for c, lbl, fam, b in spec if rows_in.get(c)]
    notes = notes or {}
    n = len(rows)
    W, H = 6.6, 0.62 * n + 2.1
    fig = plt.figure(figsize=(W, H))
    bottom = 0.27 if n <= 3 else 0.21
    gs = fig.add_gridspec(1, 2, width_ratios=[1.0, 1.05], wspace=0.05, left=0.17, right=0.99, top=0.81, bottom=bottom)
    ax = fig.add_subplot(gs[0]); axg = fig.add_subplot(gs[1], sharey=ax)
    ys = np.arange(n)[::-1]
    ylim = (-0.6, n - 0.3)
    # glyph axes: same height as the bars, x range chosen so that one data unit is square (rows stay aligned)
    pos = axg.get_position()
    axg.set_xlim(0, (ylim[1] - ylim[0]) * (pos.width * W) / (pos.height * H))
    xmax = 1.0
    for y, (c, lbl, fam, b) in zip(ys, rows):
        m, lo, hi, vic, rep, lent = row_stats(rows_in[c], key, stat, win)
        if log:
            ax.barh(y, m, 0.62, color=COL[fam], zorder=3)
        else:
            ax.barh(y, m - 1.0, 0.62, left=1.0, color=COL[fam], zorder=3)
        if hi > lo:
            ax.errorbar(m, y, xerr=[[m - lo], [hi - m]], fmt="none", ecolor="k", lw=0.9, capsize=3, zorder=4)
        ax.text(hi + (0.02 if not log else hi * 0.14), y, "%.2f%s" % (m, X), va="center", ha="left", zorder=5,
                **F_AX)
        xmax = max(xmax, hi)
        tx = glyph(axg, y, b, vic, rep, lent)
        used = vic + rep
        txt = "%.1f of %d used" % (used, b)
        if rep >= 0.05:
            txt += "\n(%.1f victim + %.1f replicas)" % (vic, rep)
        if c in notes:
            txt += "\n" + notes[c]
        if lent >= 0.05:
            txt += "\n+ %.1f lent" % lent
        axg.text(tx, y, txt, va="center", ha="left", linespacing=1.15, **F_DESC)
    ax.set_yticks(ys); ax.set_yticklabels([r[1] for r in rows], **F_AX)
    ax.tick_params(axis="y", length=0)
    if log:
        ax.set_xscale("log"); ax.set_xlim(1.0, xmax * 1.9)
        ticks = xticks or [1, 2, 4, 8]
    else:
        ax.set_xlim(1.0, 1.0 + (xmax - 1.0) * 1.45)
        ticks = xticks or [1.0, slo, round(1.0 + (xmax - 1.0) * 1.1, 1)]
    ax.set_xticks(ticks); ax.set_xticklabels([("%g%s" if log else "%.1f%s") % (t, X) for t in ticks], **F_AX)
    ax.minorticks_off()
    ax.axvspan(1.0, slo, color=C_OK, zorder=0)
    ax.axvline(slo, color="k", ls="--", lw=1.2, zorder=1)
    ax.text(slo, n - 0.42, "SLO", ha="center", va="bottom", **F_DESC)
    ax.set_ylim(*ylim)
    ax.set_xlabel(xlabel, **F_AX)
    ax.spines["left"].set_visible(False)
    axg.axis("off")
    # part subtitles and the row separators that run from the bars through the glyphs (user 2026-11-12)
    ax.text(0.0, 1.02, "latency vs. SLO", transform=ax.transAxes, ha="left", va="bottom", **F_SUB)
    axg.text(0.0, 1.02, "cores: quota & avg. usage\n%s" % during, transform=axg.transAxes, linespacing=1.15, ha="left", va="bottom", **F_SUB)
    inv = fig.transFigure.inverted()
    xl = inv.transform(ax.transAxes.transform((0, 0)))[0] - 0.14   # include the row labels
    xr = inv.transform(axg.transAxes.transform((1, 0)))[0]
    for k in range(n):   # between the rows and under the last one; none above the top row (the SLO label sits there)
        yf = inv.transform(ax.transData.transform((1.0, k - 0.5)))[1]
        fig.add_artist(Line2D([xl, xr], [yf, yf], transform=fig.transFigure, color="#d9d9d9", lw=0.7, zorder=0))
    fig.suptitle(title, fontsize=11.5, fontweight="bold", x=0.5, ha="center", y=0.975)
    # legends next to what they explain: SLO / band under the bars, the square fills under the glyphs
    ax.legend(handles=[Line2D([], [], color="k", ls="--", lw=1.2, label="SLO (%g%s quiet)" % (slo, X)), Patch(facecolor=C_OK, label="within the SLO")],
              loc="upper center", bbox_to_anchor=(0.5, -0.24 if n <= 3 else -0.15), ncol=1, frameon=False, handlelength=1.6, **F_LEG)
    axg.legend(handles=[Patch(facecolor=P.C_VICTIM, label="used by the victim"), Patch(facecolor=P.C_REP, hatch="///", edgecolor="white", label="used by its replicas"),
                        Patch(facecolor=C_LENT, edgecolor=P.C_HC, hatch="xxx", label="lent out to the co-tenants"),
                        Patch(facecolor=C_IDLE_FACE, edgecolor=C_IDLE_EDGE, label="reserved, idle")],
               loc="upper center", bbox_to_anchor=(0.5, -0.02), ncol=2, frameon=False, handlelength=1.6, columnspacing=1.2, **F_LEG)
    P.save(fig, out, name)


def fig_eqx(rows_in, spec, key, stat, win, slo, xlabel, name, out, x=(66, 115), during="bursts", setup=None):
    """User's design 2026-11-17: one panel, x = absolute latency in the window, y = cores; per mitigation one box of
    the victim's 2 allocated cores (a thin line at each core) at its median latency, filled bottom-up with the CPU
    time used by the victim / by replicas, idle grey, lent-out on top; more allocated cores (replication's replica
    cores) as a vertical ellipsis with a callout; min-max over trials as the whisker under the box; the medians, the
    no-burst p95 and the SLO as x ticks."""
    W, H = 5.6, 3.75   # +0.3 in on top for the title
    fig = plt.figure(figsize=(W, H))
    ax = fig.add_axes([0.115, 0.1997, 0.865, 0.4784])
    stats = {}
    quiet = []
    ntr = []
    for c, lbl, fam, b in spec:
        rs = rows_in.get(c)
        if not rs:
            continue
        k = "s_%s%s" % (key, stat)
        v = [r[k + "_" + win] for r in rs if r.get(k + "_" + win) is not None]
        quiet += [r[k + "_p1"] for r in rs if r.get(k + "_p1")]
        ntr.append(len(v))
        _, _, _, vic, rep, lent = row_stats(rs, key, stat, win)
        stats[c] = (lbl, b, E.agg(v), min(v), max(v), vic, rep, lent)
    q = float(np.median(quiet))
    SHOW = 2                                  # cores drawn per box (the victim's own allocation)
    more = any(s[1] > SHOW for s in stats.values())
    ymin, ymax = -0.45, SHOW + (0.42 if more else 0.12)   # top = the ellipsis (user 2026-11-17: no empty band above)
    ax.set_xlim(*x); ax.set_ylim(ymin, ymax)
    bb = ax.get_position()
    us_per_core = ((x[1] - x[0]) / (bb.width * W)) / ((ymax - ymin) / (bb.height * H))
    bw = 0.6 * us_per_core                    # box width (slim: replication sits next to the SLO line)
    ax.axvspan(x[0], slo * q, color=C_OK_X, zorder=0, lw=0)
    ax.axvline(q, color="#8a8a9a", ls=":", lw=1.4, zorder=1)
    ax.axvline(slo * q, color="k", ls="--", lw=1.6, zorder=1)
    for c, (lbl, b, m, lo, hi, vic, rep, lent) in stats.items():
        n = min(b, SHOW)
        wy = ymin / 2
        ax.errorbar([m], [wy], xerr=[[m - lo], [hi - m]], fmt="o", ms=4, color="#444444", lw=1.2, capsize=3.5, capthick=1.2, zorder=5)
        x0 = m - bw / 2
        # CPU time bottom-up: victim, replicas, idle (grey), lent out on top (blue)
        segs = [(0.0, vic, P.C_VICTIM, "white"), (vic, vic + rep, P.C_REP, "white"),
                (vic + rep, n - lent, C_IDLE_X, None), (n - lent, n, C_LENT, "#163a5a")]
        for f0, f1, fc, tc in segs:
            f0, f1 = max(f0, 0.0), min(f1, n)
            if f1 - f0 < 0.01:
                continue
            ax.add_patch(Rectangle((x0, f0), bw, f1 - f0, facecolor=fc, edgecolor="none", zorder=3))
            if tc and f1 - f0 >= 0.05:
                ax.text(m, (f0 + f1) / 2, "%.1f" % (f1 - f0), ha="center", va="center", fontsize=9, fontweight="bold", color=tc, zorder=6)
        for j in range(1, n):                 # a thin line at each core inside the box
            ax.plot([x0, x0 + bw], [j, j], color="#8a8a8a", lw=0.8, zorder=4)
        ax.add_patch(Rectangle((x0, 0), bw, n, facecolor="none", edgecolor="#3a3a3a", lw=1.4, zorder=4.5))
        if b > n:   # more allocated cores (all idle in the bursts): a vertical ellipsis, called out (user 2026-11-17)
            dy = [n + 0.09, n + 0.19, n + 0.29]
            ax.plot([m] * 3, dy, ls="none", marker="o", ms=3.0, color="#9a9ea8", zorder=5)
            ax.annotate("+%d cores for replicas, idle" % (b - n), (m + 0.15 * us_per_core, dy[2]), xytext=(m + 0.55 * us_per_core, dy[2] + 0.06),
                        ha="left", va="center", fontsize=9.5, color="#555555", zorder=5,
                        arrowprops=dict(arrowstyle="-", lw=0.8, color="#888888", shrinkA=2, shrinkB=0))
        ax.annotate(lbl.replace(chr(10), " ").capitalize(), (m, 0), xycoords=("data", "axes fraction"), xytext=(0, -17), textcoords="offset points",
                    ha="center", va="top", fontsize=10, fontweight="bold", color="#111111", fontfamily=F_NAME, annotation_clip=False)
    # x ticks: the no-burst p95, the SLO and the medians (user mock 2026-11-17)
    ticks = sorted([(q, "%.0f" % q), (slo * q, "%.0f" % (slo * q))] + [(s[2], "%.0f" % s[2]) for s in stats.values()])
    ax.set_xticks([t for t, _ in ticks]); ax.set_xticklabels([l for _, l in ticks])
    for lab in ax.get_xticklabels():
        lab.set_fontsize(F_AX["fontsize"])
    # "SLO" inside the plot at the top of its line; its value is a plain tick (user 2026-11-17)
    ax.text(slo * q - 0.4, ymin + 0.04, "SLO", ha="right", va="bottom", fontsize=10, fontweight="bold", color="#111111", zorder=5)
    ax.annotate("no-burst\np95", (q, 0), xycoords=("data", "axes fraction"), xytext=(0, -17), textcoords="offset points",
                ha="center", va="top", fontsize=8.5, color="#666666", linespacing=1.0, annotation_clip=False)
    yt = list(range(0, SHOW + 1))
    ax.set_yticks(yt); ax.spines["left"].set_bounds(ymin, yt[-1])
    for lab in ax.get_yticklabels():
        lab.set_fontsize(F_AX["fontsize"])
    ax.set_xlabel(xlabel, fontsize=F_AX["fontsize"], color="#111111", labelpad=17)   # room for the names
    ax.set_ylabel("cores", fontsize=F_AX["fontsize"], color="#111111")
    ax.yaxis.set_label_coords(-0.07, (SHOW / 2 - ymin) / (ymax - ymin))
    # legend: Allocation / CPU time / Latency (user mock 2026-11-17)
    nt = min(ntr) if ntr else 0
    eb = ax.errorbar([np.nan], [np.nan], xerr=[[1], [1]], fmt="o", ms=4, color="#444444", lw=1.2, capsize=3.5, capthick=1.2,
                     label="median, min–max of %d trials" % nt)
    _legend_rows(fig, ((0.8805, "Allocation", [Patch(facecolor="white", edgecolor="#3a3a3a", lw=1.2, label="allocated cores"),
                                              Line2D([], [], ls="none", marker=r"$\vdots$", ms=11, color="#9a9ea8", label="more allocated cores")]),
                       (0.8216, "CPU time", [Patch(facecolor=P.C_VICTIM, edgecolor="none", label="used by victim"),
                                            Patch(facecolor=P.C_REP, edgecolor="none", label="used by replicas"),
                                            Patch(facecolor=C_LENT, edgecolor="none", label="lent to aggressors"),
                                            Patch(facecolor=C_IDLE_X, edgecolor="none", label="idle")]),
                       (0.7627, "Latency", [eb, Patch(facecolor=C_OK_X, edgecolor="none", label="within SLO (%g%s no-burst p95)" % (slo, X))])),
                 fontsize=9.5)
    fig.text(0.02, 0.965, "Harvesting (matched) mitigates bursts; replication (mismatched) fails", ha="left", va="center",
             fontsize=11.5, fontweight="bold", color="#111111")   # draft title (user 2026-11-17)
    P.save(fig, out, name)


class _StepKey(Line2D):
    """Legend key for a step outline (the allocated cores over time)."""
    def __init__(self, label):
        super().__init__([], [], color="#3a3a3a", lw=1.3, label=label)


class _StepHandler(plt.matplotlib.legend_handler.HandlerBase):
    def create_artists(self, legend, orig, xd, yd, width, height, fontsize, trans):
        xs = [0, 0.35 * width, 0.35 * width, 0.7 * width, 0.7 * width, width]
        ys = [0.1 * height, 0.1 * height, 0.9 * height, 0.9 * height, 0.45 * height, 0.45 * height]
        return [Line2D([xx - xd for xx in xs], [yy - yd for yy in ys], color=orig.get_color(), lw=orig.get_linewidth(), transform=trans)]


def _legend_rows(fig, rows, x_title=0.02, x_leg=0.175, fontsize=10, handler_map=None):
    """Legend rows on top of a figure, each with a bold row title (shared by eqx and tsx)."""
    lg = dict(frameon=False, handlelength=1.0, handleheight=1.0, handletextpad=0.4, columnspacing=0.9, borderaxespad=0, fontsize=fontsize)
    for yy, title, hs in rows:
        fig.text(x_title, yy, title, ha="left", va="center", fontsize=10.5, fontweight="bold", color="#333333")
        fig.legend(handles=hs, loc="center left", bbox_to_anchor=(x_leg, yy), ncol=len(hs), handler_map=handler_map, **lg)


def fig_tsx(root, sweeps, cell, out, name, x=(0, 262), slo=1.3):
    """User's design 2026-11-14: p95 over time with quiet p95 / SLO / band and the bursts on top; below, cores over
    time: the quota as stacked 2-thread blocks (victim's own 2 + 2 per replica serving), filled with the victim's
    and the replicas' use; one annotation (replicas are not ready until the burst is nearly over)."""
    d = None
    for sw in sweeps:
        cd = os.path.join(root, sw, cell)
        if P.glob.glob(os.path.join(cd, "stage3eval_*")):
            d = P.ts_load(cd); break
    if d is None:
        print("skip", name, "(no", cell, ")"); return
    t, p95, nrep, arm = d["t"], d["p95"], d["n_rep"], d["arm"]
    q = np.nanmean(p95[(t > 2) & (t < 29)])
    sel = (t >= x[0]) & (t <= x[1])
    W, H = 5.6, 4.9   # +0.3 in on top for the title
    fig = plt.figure(figsize=(W, H))
    ax = fig.add_axes([0.12, 0.4506, 0.86, 0.3239])
    axc = fig.add_axes([0.12, 0.1033, 0.86, 0.3192], sharex=ax)
    bursts = [(a, b) for a, b in d["bursts"] if b > x[0] and a < x[1]]
    for a, b in bursts:
        for axx in (ax, axc):
            axx.axvspan(a, b, color=C_BURST, lw=0, zorder=0.5)
    # latency
    ytop = max(150.0, np.nanmax(p95[sel]) * 1.08)
    ylo = 0.8 * q
    ax.axhspan(ylo, slo * q, color=C_OK_X, lw=0, zorder=0)
    ax.axhline(slo * q, color="k", ls="--", lw=1.6, zorder=1)   # no quiet p95 line (user 2026-11-16)
    ax.text(x[1] - 1, slo * q + 0.02 * (ytop - ylo), "SLO %.0f µs" % (slo * q), ha="right", va="bottom", fontsize=10, fontweight="bold", color="#111111", zorder=5)
    ax.plot(t, p95, color="#222222", lw=1.3, zorder=3)
    ax.set_ylim(ylo, ytop)
    ax.yaxis.set_major_locator(plt.matplotlib.ticker.MultipleLocator(30))
    ax.set_ylabel("p95 (µs)", fontsize=F_AX["fontsize"], color="#111111")
    tr = plt.matplotlib.transforms.blended_transform_factory(ax.transData, ax.transAxes)
    if bursts:
        a, b = bursts[0]
        ax.text(a - 1.5, 0.96, "burst", transform=tr, ha="right", va="top", fontsize=10, color="#8c7a5e")
    # the enable: a heavier line, two-line label, and a right arrow "from here on" in both panels (user 2026-11-16)
    trc = plt.matplotlib.transforms.blended_transform_factory(axc.transData, axc.transAxes)
    for axx, tf, ya in ((ax, tr, 0.69), (axc, trc, 0.93)):
        axx.axvline(arm, color=C_ARM, ls="-", lw=1.8, zorder=1)   # solid, replication-orange (user 2026-11-16)
        axx.annotate("", (arm + 18, ya), xytext=(arm, ya), xycoords=tf, textcoords=tf, zorder=5,
                     arrowprops=dict(arrowstyle="-|>", lw=1.4, color=C_ARM, shrinkA=0, shrinkB=0, mutation_scale=11))
    ax.text(arm + 1.5, 0.96, "replication\nenabled", transform=tr, ha="left", va="top", fontsize=10, color=C_ARM, linespacing=1.1)
    plt.setp(ax.get_xticklabels(), visible=False)
    # cores: quota blocks (victim's 2, then 2 per replica serving), the use filled from the bottom
    # one grey area up to the quota, no lines inside (user 2026-11-14)
    axc.fill_between(t, 0, 2 + 2 * nrep, step="mid", facecolor=C_IDLE_X, edgecolor="#3a3a3a", lw=1.2, zorder=1)   # outline = allocated cores
    g = t[t < t.max() - 1]   # the last bin is a partial second (the run stops), drop it
    vic = np.interp(g, *d["vic"]) if len(d["vic"][0]) else np.zeros_like(g)
    rep = np.interp(g, *d["rep"], left=0, right=0) if len(d["rep"][0]) else np.zeros_like(g)
    sm = lambda v: np.convolve(np.pad(v, 1, mode="edge"), np.ones(3) / 3, mode="valid")   # 3 s mean, no dip at the ends
    vic, rep = sm(vic), sm(rep)
    axc.fill_between(g, 0, vic, facecolor=P.C_VICTIM, edgecolor="none", zorder=2)
    axc.fill_between(g, vic, vic + rep, facecolor=P.C_REP, edgecolor="none", zorder=2)
    top = 2 * int(nrep[sel].max()) + 2
    axc.set_ylim(0, max(8, top) + 0.4); axc.set_yticks(range(0, max(8, top) + 1, 2))
    axc.set_ylabel("cores", fontsize=F_AX["fontsize"], color="#111111")
    axc.set_xlabel("time (s)", fontsize=F_AX["fontsize"], color="#111111")
    axc.set_xlim(*x); axc.xaxis.set_major_locator(plt.matplotlib.ticker.MultipleLocator(60))
    for axx in (ax, axc):
        axx.grid(axis="x", color="#e2e2e2", lw=0.8, zorder=0); axx.set_axisbelow(True)
        for lab in axx.get_xticklabels() + axx.get_yticklabels():
            lab.set_fontsize(F_AX["fontsize"])
    first_on = next((tt for tt, nn in zip(t, nrep) if tt >= arm and nn > 0), None)
    if first_on is not None:
        # two lines, no backing box (user 2026-11-14); a thin white halo where the enable line runs behind the text
        an = axc.annotate("replicas ready only\nnear the end of burst", (first_on - 0.5, 3.0), xytext=(first_on - 5, 5.9), ha="right", va="center",
                          fontsize=9.5, color="#333333", linespacing=1.25, zorder=5,
                          arrowprops=dict(arrowstyle="-|>", lw=0.9, color="#555555", shrinkA=0, shrinkB=1, mutation_scale=9))
        an.set_path_effects([plt.matplotlib.patheffects.withStroke(linewidth=3, foreground="white")])
    # burst length and period from the driver log (6 s every 60 s)
    blen = np.median([b - a for a, b in d["bursts"]]) if d["bursts"] else 0
    bper = np.median(np.diff([a for a, _ in d["bursts"]])) if len(d["bursts"]) > 1 else 0
    # same legend format as the tower figure, three rows (user 2026-11-17); the allocation is the dark step outline in
    # the cores panel, so its legend handle is a small step line, not a box
    _legend_rows(fig, [(0.8994, "Load", [Patch(facecolor=C_BURST, label="co-tenant burst (%.0f s every %.0f s)" % (blen, bper))]),
                       (0.8561, "Cores", [_StepKey(label="allocated cores"),
                                         Patch(facecolor=P.C_VICTIM, edgecolor="none", label="used by victim"),
                                         Patch(facecolor=P.C_REP, edgecolor="none", label="used by replicas"),
                                         Patch(facecolor=C_IDLE_X, edgecolor="none", label="idle")]),
                       (0.8131, "Latency", [Line2D([], [], color="k", ls="--", lw=1.6, label="SLO"),
                                           Patch(facecolor=C_OK_X, edgecolor="none", label="within SLO (%g%s no-burst p95)" % (slo, X))])],
                 fontsize=9.5, handler_map={_StepKey: _StepHandler()})
    fig.text(0.02, 0.967, "Zoom-in on replication: replicas arrive too late for bursts", ha="left", va="center",
             fontsize=11.5, fontweight="bold", color="#111111")   # draft title (user 2026-11-17)
    P.save(fig, out, name)


def fig_ts_rep(root, sweeps, cell, out, name, x=(0, 262), slo=1.3):
    d = None
    for sw in sweeps:
        cd = os.path.join(root, sw, cell)
        if P.glob.glob(os.path.join(cd, "stage3eval_*")):
            d = P.ts_load(cd); break
    if d is None:
        print("skip", name, "(no", cell, ")"); return
    t, p95, nrep, arm = d["t"], d["p95"], d["n_rep"], d["arm"]
    base = np.nanmean(p95[(t > 2) & (t < 29)])
    ratio = p95 / base
    fig, (axp, ax, axr) = plt.subplots(3, 1, figsize=(7.4, 4.8), sharex=True, gridspec_kw=dict(height_ratios=[0.16, 1.35, 1.0], hspace=0.22, top=0.9, bottom=0.24, left=0.1, right=0.99))
    bursts = [(a, b) for a, b in d["bursts"] if b > x[0] and a < x[1]]
    # phase strip: no mitigation until the enable, then the mitigation
    axp.axvspan(x[0], arm, color="#e3e3e3", lw=0); axp.axvspan(arm, x[1], color=C_PHASE_ON, lw=0)
    axp.text((x[0] + arm) / 2, 0.5, "no mitigation", ha="center", va="center", fontsize=9, fontweight="bold", color="#444444")
    axp.text((arm + x[1]) / 2, 0.5, "replication enabled (reactive, cap 6)", ha="center", va="center", fontsize=9, fontweight="bold", color="#7a3d0c")
    axp.set_ylim(0, 1); axp.axis("off")
    tr = P.plt.matplotlib.transforms.blended_transform_factory(ax.transData, ax.transAxes)
    for a, b in bursts:
        for axx in (ax, axr):
            axx.axvspan(a, b, color="#dddddd", lw=0, zorder=1)
        ax.text((a + b) / 2, 0.985, "burst", transform=tr, ha="center", va="top", fontsize=8.5, color="#777777")
    sel = (t >= x[0]) & (t <= x[1])
    # absolute p95 (user 2026-11-12), the SLO at slo x this run's quiet p95
    ymax = max(2.12 * base, np.nanmax(p95[sel]) * 1.08)
    ax.axhspan(0, slo * base, color=C_OK, zorder=0)
    ax.axhline(slo * base, color="k", ls="--", lw=1.2, zorder=2)
    ax.text(x[1] - 1, slo * base + 0.04 * base, "SLO (%g%s quiet)" % (slo, X), ha="right", va="bottom", **F_DESC)
    for axx in (axp, ax, axr):
        axx.axvline(arm, color="#555555", ls=":", lw=1.2, zorder=2)
    ax.plot(t, p95, color="#222222", lw=1.3, zorder=3)
    ax.set_ylim(0.75 * base, ymax); ax.set_xlim(*x)
    ax.yaxis.set_major_locator(P.plt.matplotlib.ticker.MaxNLocator(4, integer=True))
    for lab in ax.get_yticklabels():
        lab.set_fontsize(F_AX["fontsize"]); lab.set_fontweight("bold")
    ax.set_ylabel("service p95 (\u00b5s)", **F_AX)
    axr.step(t, nrep, where="post", color=P.C_REP, lw=2.2, zorder=3)
    top = max(2, int(nrep[sel].max()))
    axr.set_ylim(0, top + 2.0); axr.set_yticks(list(range(0, top + 1, 1 if top <= 4 else 2)))   # head-room for the annotations
    axr.set_ylabel("replicas", **F_AX); axr.set_xlabel("time (s)", **F_AX)
    for lab in axr.get_xticklabels() + axr.get_yticklabels():
        lab.set_fontsize(F_AX["fontsize"]); lab.set_fontweight("bold")
    # annotations from the data (user's wording 2026-11-12)
    first_on = next((tt for tt, nn in zip(t, nrep) if tt >= arm and nn > 0), None)
    after = [(a, b) for a, b in bursts if a >= arm]
    if after:
        a, b = after[0]
        w = sel & (t >= a - 1) & (t <= b + 3)
        i = np.nanargmax(np.where(w, ratio, -np.inf))
        ax.annotate("SLO violated, but\nreplicas are too slow", (t[i], p95[i]), xytext=(t[i] + 12, ymax - 0.16 * base), va="top", **F_DESC,
                    arrowprops=dict(arrowstyle="-", lw=0.8, color="k"))
    if first_on is not None:
        axr.annotate("first replica arrives\naround the end of the burst", (first_on, nrep[t == first_on][0]), xytext=(first_on - 7, top + 1.75),
                     va="top", ha="right", arrowprops=dict(arrowstyle="-", lw=0.8, color="k"), **F_DESC)
    if len(after) > 1:
        a2, b2 = after[1]
        n_at = nrep[np.searchsorted(t, a2)]
        axr.annotate("replicas still running happen\nto absorb the next burst", (a2, n_at), xytext=(a2 + 9, top + 1.75), va="top", ha="left", **F_DESC,
                     arrowprops=dict(arrowstyle="-", lw=0.8, color="k"))
    h = [Patch(facecolor="#dddddd", label="co-tenant burst (6 s)"), Line2D([], [], color="#555555", ls=":", lw=1.2, label="replication enabled (%.0f s)" % arm),
         Line2D([], [], color="k", ls="--", lw=1.2, label="SLO (%g%s quiet p95)" % (slo, X)), Patch(facecolor=C_OK, label="within the SLO"),
         Line2D([], [], color=P.C_REP, lw=2.2, label="replicas serving")]
    fig.legend(handles=h, loc="lower center", ncol=3, frameon=False, bbox_to_anchor=(0.5, 0.0), handlelength=1.6, columnspacing=1.4, **F_LEG)
    fig.suptitle("Reactive replication (cap 6) under 10 % co-tenant bursts, trial 1", fontsize=11.5, fontweight="bold", x=0.5, ha="center", y=0.975)
    P.save(fig, out, name)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default="data"); ap.add_argument("--out", default=".")
    ap.add_argument("--tail", default="motiv3-c6320,motiv3-c6320-t2,eq/tail-t1,eq/tail-t2")
    ap.add_argument("--steady", default="eq/steady-t1,eq/steady-t2,eq/steady-t3")
    ap.add_argument("--slo-tail", type=float, default=1.3); ap.add_argument("--slo-steady", type=float, default=2.0)
    ap.add_argument("--tail-key", default="proc"); ap.add_argument("--steady-key", default="tot")
    ap.add_argument("--ts-cell", default="rep6p-quiet"); ap.add_argument("--ts-x", default="0,262")
    ap.add_argument("--machine", default="c6320", choices=list(P.MACHINES))
    ap.add_argument("--agg", default="median", choices=("median", "mean"))
    ap.add_argument("--only", default="", help="comma list of eqh_tail,eqh_steady,eqx_tail,ts,tsx")
    a = ap.parse_args()
    E.AGG = a.agg
    P.MACHINE, P.VTHREADS, P.GROW_THREADS, P.INT_RPS = P.MACHINES[a.machine]
    only = set(a.only.split(",")) if a.only else {"eqh_tail", "eqh_steady", "eqx_tail", "ts", "tsx"}
    tail_sw = [s for s in a.tail.split(",") if s]
    if "eqh_tail" in only:
        # reactive replication: the quota bound is the peak it actually allocated (victim 2 + 2 per concurrent replica), not the cap (user 2026-11-13)
        pk = peak_replicas(a.root, tail_sw, "rep6p-quiet")
        rows_t = [(c, l, f, (2 + 2 * pk) if c == "rep6p-quiet" and pk else b) for c, l, f, b in TAIL_ROWS]
        notes_t = {"rep6p-quiet": "peak %d replicas (cap 6)" % pk} if pk else {}
        fig_eqh(P.load_rows(a.root, tail_sw), rows_t, a.tail_key, "95", "p3b", a.slo_tail,
                "p95 in bursts \u00f7 quiet p95", "motiv3_eqh_tail", a.out, TITLES["tail"], xticks=[1.0, a.slo_tail, 1.6], notes=notes_t)
    if "eqx_tail" in only:
        pk = peak_replicas(a.root, tail_sw, "rep6p-quiet")
        rows_x = [(c, {"none": "no mitigation"}.get(f, l), f, (2 + 2 * pk) if c == "rep6p-quiet" and pk else b) for c, l, f, b in TAIL_ROWS]
        fig_eqx(P.load_rows(a.root, tail_sw), rows_x, a.tail_key, "95", "p3b", a.slo_tail, "p95 latency during aggressors' bursts (\u00b5s)", "motiv3_eqx_tail", a.out,
                setup={c: "%d cores quota%s" % (b, " at peak" if c == "rep6p-quiet" else "") for c, _, _, b in rows_x})
    if "eqh_steady" in only:
        fig_eqh(P.load_rows(a.root, [s for s in a.steady.split(",") if s], steady=True), STEADY_ROWS, a.steady_key, "50", "ovl", a.slo_steady,
                "p50 under overload \u00f7 quiet p50", "motiv3_eqh_steady", a.out, TITLES["steady"], log=True, during="under overload")
    if "ts" in only:
        x0, x1 = (float(v) for v in a.ts_x.split(","))
        fig_ts_rep(a.root, tail_sw, a.ts_cell, a.out, "motiv3_ts_rep6", x=(x0, x1), slo=a.slo_tail)
    if "tsx" in only:
        x0, x1 = (float(v) for v in a.ts_x.split(","))
        fig_tsx(a.root, tail_sw, a.ts_cell, a.out, "motiv3_tsx_rep6", x=(x0, x1), slo=a.slo_tail)


if __name__ == "__main__":
    main()
