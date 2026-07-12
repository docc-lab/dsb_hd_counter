#!/usr/bin/env python3
"""Per-method score-vs-contention curves from an overnight capture sweep.

Joins the sweep log (run dir -> arm) with the replay summary stdout
(per-run steady-state means for every score model), then renders one
small-multiple panel per method: x = contention arm in severity order,
mean +/- std across replicates, individual runs as faint dots.

Usage (on node-0, after the replay loop):
  python3 tools/plot_score_curves.py \
      [--sweep-log /tmp/capture_sweep.log] [--replay /tmp/replay_all.txt] \
      [--out score_curves]        # writes <out>.png and <out>.pdf

Also prints the per-arm mean+/-std table to stdout.
"""
import argparse
import re
import statistics as st
import sys
from collections import defaultdict

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

# -- palette (light surface) ------------------------------------------------
SURFACE = '#fcfcfb'
INK = '#0b0b0b'
INK2 = '#52514e'
MUTED = '#898781'
GRID = '#e1e0d9'
BASELINE = '#c3c2b7'
SERIES = ['#2a78d6', '#1baf7a', '#eda100', '#008300',
          '#4a3aa7', '#e34948', '#e87ba4', '#eb6834']


def parse_sweep_log(path):
    """run dir -> arm, and arm first-seen order."""
    arm_of, order = {}, []
    for line in open(path):
        m = re.search(r'pass \d+: (\S+) -> (data/\S+?)/ ', line)
        if m:
            arm, d = m.group(1), m.group(2)
            arm_of[d] = arm
            if arm not in order:
                order.append(arm)
    return arm_of, order


def parse_replay(path):
    """per run dir: {method: value} of steady-state means."""
    runs = defaultdict(dict)
    cur = None
    for line in open(path):
        if line.startswith('== '):
            cur = line[3:].strip()
            continue
        if cur is None:
            continue
        m = re.match(r'\s+(\w+)\s+\(k=([\d.]+), sigma x[\d.]+\): '
                     r'mean y50=([\d.]+) y90=[\d.]+ ext50=([\d.]+)', line)
        if m:
            name, k, y50, e50 = m.groups()
            runs[cur][f'gordion_{name}'] = float(y50)
            runs[cur].setdefault('ext50', float(e50))
            continue
        m = re.search(r'slowdown_ratio=([\d.]+) \| ci=([\d.]+) \| '
                      r'cpi=([\d.]+) \| rolling_pctl=([\d.]+) \| '
                      r'binary\(frac=1\)=([\d.]+)', line)
        if m:
            for key, v in zip(('slowdown_ratio', 'ci', 'cpi',
                               'rolling_pctl', 'binary'), m.groups()):
                runs[cur][key] = float(v)
    return runs


PANELS = [  # (key, title, fixed 0-1 scale?, reference line at 1.0?)
    ('gordion_kg',     'Gordion y50 (k=0.025)',      True,  False),
    ('gordion_k1',     'Gordion y50 (k=1, saturated)', True, False),
    ('ext50',          'Gordion extrinsic fraction', True,  False),
    ('slowdown_ratio', 'Slowdown Ratio',             False, True),
    ('ci',             'CI (p90 / p50)',             False, False),
    ('cpi',            'CPI',                        False, False),
    ('rolling_pctl',   'Rolling Percentile',         False, True),
    ('binary',         'Binary Classifier (frac on)', True, False),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sweep-log', default='/tmp/capture_sweep.log')
    ap.add_argument('--replay', default='/tmp/replay_all.txt')
    ap.add_argument('--out', default='score_curves')
    args = ap.parse_args()

    arm_of, arms = parse_sweep_log(args.sweep_log)
    runs = parse_replay(args.replay)
    if not runs:
        sys.exit(f'no runs parsed from {args.replay}')

    # arm -> method -> [per-run values]
    vals = {a: defaultdict(list) for a in arms}
    unmapped = 0
    for d, methods in runs.items():
        a = arm_of.get(d)
        if a is None:
            unmapped += 1
            continue
        for k, v in methods.items():
            vals[a][k].append(v)
    if unmapped:
        print(f'warning: {unmapped} replay dirs not found in sweep log',
              file=sys.stderr)

    labels = [re.sub(r'-(mixed|search)-\d+$', '', a) for a in arms]

    # ---- stdout table ----
    keys = [p[0] for p in PANELS]
    print(f'{"arm":<12} n  ' + '  '.join(f'{k:<14}' for k in keys))
    for a, lab in zip(arms, labels):
        n = len(vals[a].get(keys[0], []))
        cells = []
        for k in keys:
            v = vals[a].get(k, [])
            cells.append(f'{st.mean(v):.3f}+/-{st.stdev(v):.3f}'
                         if len(v) > 1 else
                         (f'{v[0]:.3f}         ' if v else '-'))
        print(f'{lab:<12} {n:>2}  ' + '  '.join(f'{c:<14}' for c in cells))

    # ---- figure ----
    plt.rcParams.update({
        'font.family': ['Segoe UI', 'DejaVu Sans', 'sans-serif'],
        'figure.facecolor': SURFACE, 'axes.facecolor': SURFACE,
        'savefig.facecolor': SURFACE,
        'text.color': INK, 'axes.edgecolor': BASELINE,
        'axes.labelcolor': INK2, 'xtick.color': INK2, 'ytick.color': INK2,
    })
    x = range(len(arms))
    fig, axes = plt.subplots(2, 4, figsize=(13.5, 6.4))
    for (key, title, unit01, ref1), color, ax in zip(
            PANELS, SERIES, axes.flat):
        means, stds = [], []
        for i, a in enumerate(arms):
            v = vals[a].get(key, [])
            means.append(st.mean(v) if v else float('nan'))
            stds.append(st.stdev(v) if len(v) > 1 else 0.0)
            ax.scatter([i + (j - len(v) / 2) * 0.02 for j in range(len(v))],
                       v, s=14, color=color, alpha=0.30, linewidths=0,
                       zorder=2)
        if ref1:
            ax.axhline(1.0, color=BASELINE, lw=1, ls=(0, (4, 3)), zorder=1)
        ax.errorbar(x, means, yerr=stds, color=color, lw=2, marker='o',
                    ms=5.5, capsize=2.5, capthick=1.2, elinewidth=1.2,
                    zorder=3)
        ax.set_title(title, fontsize=10.5, color=INK, pad=6)
        if unit01:
            ax.set_ylim(-0.04, 1.06)
        ax.set_xticks(list(x))
        ax.set_xticklabels(labels, rotation=30, ha='right', fontsize=8.5)
        ax.tick_params(axis='y', labelsize=8.5)
        ax.grid(axis='y', color=GRID, lw=0.8)
        ax.set_axisbelow(True)
        for side in ('top', 'right', 'left'):
            ax.spines[side].set_visible(False)
        ax.tick_params(length=0)
    n_per = [len(vals[a].get('gordion_kg', [])) for a in arms]
    fig.suptitle('Steady-state score vs contention level, per scoring method',
                 fontsize=13, color=INK, x=0.02, ha='left')
    fig.text(0.02, 0.935,
             f'{sum(n_per)} runs ({"-".join(map(str, n_per))} per arm), '
             'mean ± std across replicates; dots = individual runs',
             fontsize=9, color=MUTED)
    fig.tight_layout(rect=(0, 0, 1, 0.92))
    for ext in ('png', 'pdf'):
        fig.savefig(f'{args.out}.{ext}', dpi=180)
    print(f'\nwrote {args.out}.png / {args.out}.pdf')


if __name__ == '__main__':
    main()
