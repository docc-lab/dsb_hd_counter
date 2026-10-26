#!/usr/bin/env python3
"""Recompute the Gordion score columns of stage-3 runs offline from the raw
windowed dump (runs/run_1/run_data.json), under a given calibration.

Why: the score log a run carries (mitigation/<name>.scores.csv) is whatever
ConfigMap the victim pod had at the time. The collect-smt sweep (2026-10-23)
ran under the total_time calibration (k 0.06, w 30), so its score columns
are not comparable with the processing_time runs. run_data.json has every
input the scorer uses (per-window p50/p90 of the chosen section, request
count, arrival_rps_3s, measured frequency), so the score can be replayed
exactly with score-verify/score_replay.py's replay() -- same kcyc
normalisation, hold-last for empty windows, causal Gaussian smoothing,
clamped tanh and curve-based extrinsic split as scorer.go.

Output per run: mitigation/<name>.scores.replay-<tag>.csv with the
controller's scores.csv columns (unix_ms,target,pod,yhat50,y50,y90,ext90,
e_iso,n,applied_cap,ext50,i_horz). yhat50 = y50 (YHAT_FROM_CURRENT=1),
e_iso = y90*ext90, n/applied_cap/i_horz are the observer values (0, 6, 0);
target/pod are copied from the original scores.csv when present.

  python3 tools/rescore_run_data.py --config score-verify/gordion.json \
      --curve score-verify/curve.csv --tag proc data/collect-smt
"""
import argparse
import csv
import glob
import json
import os
import sys
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'score-verify'))
from score_replay import load_curve, replay  # noqa: E402


def iso_ns(s):
    # "2026-10-23T19:31:04.651055551Z" -> ns since epoch (keep 9 digits)
    main, _, frac = s.rstrip('Z').partition('.')
    base = datetime.fromisoformat(main + '+00:00').timestamp()
    frac = (frac + '000000000')[:9]
    return int(base) * 10**9 + int(frac)


def samples_from_run_data(path, section, rate_signal):
    j = json.load(open(path))
    out = []
    for s in j['samples']:
        tw = s.get('timing_window') or {}
        sec = tw.get(section) or {}
        fq = s.get('freq') or {}
        out.append(dict(
            ts=iso_ns(s['timestamp']) / 1e9,
            off=int(s.get('offset_ms') or 0),
            p50=int(sec.get('p50_ns') or 0),
            p90=int(sec.get('p90_ns') or 0),
            count=int(sec.get('count') or tw.get('request_count') or 0),
            rate=float(tw.get(rate_signal) or 0),
            rate1=float(tw.get('arrival_rps_1s') or 0),
            f=float(fq.get('actual_freq_mhz') or 0),
            fok=bool(fq.get('ok', False)),
            cycles=0, instr=0,
        ))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('roots', nargs='+', help='dirs scanned for stage3eval_*/runs/run_1')
    ap.add_argument('--config', required=True, help='gordion.json to replay')
    ap.add_argument('--curve', required=True, help='matching curve.csv')
    ap.add_argument('--tag', default='replay', help='output suffix')
    args = ap.parse_args()
    cfg = json.load(open(args.config))
    curve = load_curve(args.curve)
    section = cfg.get('latency_section', 'processing_time')
    rate_signal = cfg.get('rate_signal', 'arrival_rps_3s')
    k = float(cfg['k'])

    runs = []
    for r in args.roots:
        runs += sorted(glob.glob(os.path.join(r, '**', 'stage3eval_*', 'runs', 'run_1'), recursive=True))
    if not runs:
        sys.exit('no runs found')
    for run in runs:
        rd = os.path.join(run, 'run_data.json')
        if not os.path.isfile(rd):
            print('skip (no run_data.json):', run)
            continue
        samples = samples_from_run_data(rd, section, rate_signal)
        rows = replay(samples, cfg, curve, k, 1.0)
        mdir = os.path.join(run, 'mitigation')
        os.makedirs(mdir, exist_ok=True)
        orig = glob.glob(os.path.join(mdir, '*.scores.csv'))
        orig = [o for o in orig if '.scores.replay-' not in o]
        target, pod, name = 'search', '', os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(run))))
        if orig:
            name = os.path.basename(orig[0])[:-len('.scores.csv')]
            with open(orig[0]) as fh:
                for r in csv.DictReader(fh):
                    target, pod = r.get('target', target), r.get('pod', pod)
                    break
        out = os.path.join(mdir, f'{name}.scores.replay-{args.tag}.csv')
        with open(out, 'w', newline='') as fh:
            w = csv.writer(fh)
            w.writerow(['unix_ms', 'target', 'pod', 'yhat50', 'y50', 'y90', 'ext90', 'e_iso', 'n', 'applied_cap', 'ext50', 'i_horz'])
            for ts, y50, y90, e50, e90, _ in rows:
                w.writerow([int(round(ts * 1000)), target, pod, f'{y50:.4f}', f'{y50:.4f}', f'{y90:.4f}',
                            f'{e90:.4f}', f'{y90 * e90:.4f}', 0, '6.00', f'{e50:.4f}', '0.0000'])
        tail = rows[len(rows) // 2:]
        m = lambda i: sum(r[i] for r in tail) / len(tail)  # noqa: E731
        print(f'{name:28s} windows {len(rows):5d}  second-half mean y50 {m(1):.3f} y90 {m(2):.3f} '
              f'ext90 {m(4):.3f} e_iso {sum(r[2] * r[4] for r in tail) / len(tail):.3f} -> {os.path.relpath(out)}')


if __name__ == '__main__':
    main()
