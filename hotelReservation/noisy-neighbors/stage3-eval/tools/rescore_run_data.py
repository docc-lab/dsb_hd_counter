#!/usr/bin/env python3
"""Rescore stage-3 runs offline, per 100 ms window, from the raw windowed dump
(runs/run_1/run_data.json) under a given Gordion calibration.

Why: the score log a run carries (mitigation/<name>.scores.csv) is whatever
ConfigMap the victim pod had at the time. The collect-smt sweep (2026-10-23)
ran under the total_time calibration (k 0.06, w 30), so its score columns
are not comparable with the processing_time runs. run_data.json has every
input the scorer uses (per-window p50/p90 of the chosen section, request
count, arrival_rps_3s, measured frequency), so the score can be replayed
exactly: same kcyc normalisation, hold-last for empty windows, causal
Gaussian smoothing, clamped tanh and curve-based extrinsic split as
scorer.go (the smoother is score-verify/calibrate_from_stream.smooth_stream,
which mirrors the Go Smoother; the curve lookup is score_replay's).

Outputs per run (next to the original files, originals untouched):

  mitigation/<name>.scores.replay-<tag>.csv
      the controller's scores.csv columns (unix_ms,target,pod,yhat50,y50,
      y90,ext90,e_iso,n,applied_cap,ext50,i_horz) recomputed; yhat50 = y50
      (YHAT_FROM_CURRENT=1), e_iso = y90*ext90, observer values for n (0),
      applied_cap (6.00), i_horz (0).

  runs/run_1/steps-<tag>.csv
      one row per 100 ms window: time (unix_ms, offset_ms, t_s since
      started_epoch), phase (pre / p1 / p2 / p3 / post from started_epoch_ns,
      --onset, armed_epoch_ns and ended_epoch_ns; the sampler dump starts
      about 90 s before t0 and runs past the end),
      load (request_count, arrival_count, arrival_rps_1s/3s), raw latency
      of all three sections (p50/p90, processing in us, total/blocking in
      ms), frequency, the scorer's intermediates (raw and smoothed kcyc for
      the scored section, curve D50/D90 at the smoothed rate), the scores
      (y50, y90, ext50, ext90, e_iso) and the perf deltas (cycles,
      instructions, cpi, ref-cycles, branch-misses, LLC-load-misses,
      dTLB-load-misses, page-faults). Windows without requests keep their
      load/perf columns; latency columns are empty and the score columns
      carry the hold-last value the live scorer would emit.

  --merged <file>
      all runs' step rows in one long CSV with sweep/config/run columns.

  python3 tools/rescore_run_data.py --config score-verify/gordion.json \
      --curve score-verify/curve.csv --tag proc \
      --merged /tmp/collect-smt-steps.csv data/collect-smt
"""
import argparse
import csv
import glob
import json
import math
import os
import sys
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'score-verify'))
from calibrate_from_stream import smooth_stream  # noqa: E402
from score_replay import curve_lookup, load_curve  # noqa: E402

PERF = ['cycles', 'instructions', 'ref-cycles', 'branch-misses',
        'LLC-load-misses', 'dTLB-load-misses', 'page-faults']

STEP_COLS = (['unix_ms', 'offset_ms', 't_s', 'phase',
              'request_count', 'arrival_count', 'arrival_rps_1s', 'arrival_rps_3s',
              'proc_p50_us', 'proc_p90_us', 'proc_p99_us',
              'total_p50_ms', 'total_p90_ms', 'block_p50_ms', 'block_p90_ms',
              'freq_mhz', 'freq_ok',
              'T50_raw_kcyc', 'T90_raw_kcyc', 'T50_kcyc', 'T90_kcyc', 'rate_smooth',
              'D50_kcyc', 'D90_kcyc',
              'y50', 'y90', 'ext50', 'ext90', 'e_iso']
             + [p.replace('-', '_') for p in PERF] + ['cpi'])


def iso_ns(s):
    # "2026-10-23T19:31:04.651055551Z" -> ns since epoch, 9-digit fraction kept
    main, _, frac = s.rstrip('Z').partition('.')
    base = datetime.fromisoformat(main + '+00:00').timestamp()
    return int(base) * 10**9 + int((frac + '000000000')[:9])


def read_int(path, default=None):
    try:
        return int(open(path).read().strip())
    except (OSError, ValueError):
        return default


def fmt(x, nd=4):
    return '' if x is None else (f'{x:.{nd}f}' if isinstance(x, float) else str(x))


def rescore_run(run, cfg, curve, onset):
    """Return (step_rows, meta) for one runs/run_1 dir; step_rows are dicts
    keyed by STEP_COLS."""
    j = json.load(open(os.path.join(run, 'run_data.json')))
    section = cfg.get('latency_section', 'processing_time')
    rate_signal = cfg.get('rate_signal', 'arrival_rps_3s')
    base = cfg['baseline']
    p50b, p90b = base['p50_kcyc'], base['p90_kcyc']
    s50, s90 = base['sigma50_kcyc'], base['sigma90_kcyc']
    fb = base.get('freq_mhz', 2400.0)
    w = int(cfg.get('smooth_window', 30))
    k = float(cfg['k'])

    t0_ns = read_int(os.path.join(run, 'started_epoch_ns.txt'))
    t1_ns = read_int(os.path.join(run, 'ended_epoch_ns.txt'))
    arm_ns = read_int(os.path.join(run, 'mitigation', 'armed_epoch_ns.txt'))
    t0 = (t0_ns / 1e9) if t0_ns else None
    end_t = ((t1_ns - t0_ns) / 1e9) if (t0_ns and t1_ns) else float('inf')
    arm_t = ((arm_ns - t0_ns) / 1e9) if (t0_ns and arm_ns) else 80.0

    def phase_of(t):
        # the sampler dump starts well before t0 (warm-up) and ends after the
        # run: label those 'pre' / 'post' so phase means stay clean
        if t is None:
            return ''
        if t < 0:
            return 'pre'
        if t >= end_t:
            return 'post'
        return 'p1' if t < onset else 'p2' if t < arm_t else 'p3'

    samples = j['samples']
    # --- scorer inputs, exactly as scorer.go / score_replay.replay ---
    raw50, raw90, rates, keep = [], [], [], []
    last50 = last90 = None
    for s in samples:
        tw = s.get('timing_window') or {}
        sec = tw.get(section) or {}
        fq = s.get('freq') or {}
        f = float(fq.get('actual_freq_mhz') or 0)
        if not (fq.get('ok') and f > 0):
            f = fb
        cnt = int(sec.get('count') or tw.get('request_count') or 0)
        p50, p90 = int(sec.get('p50_ns') or 0), int(sec.get('p90_ns') or 0)
        if cnt > 0 and p50 > 0:
            last50, last90 = p50 * f / 1e6, p90 * f / 1e6   # ns * MHz / 1e6 = kcyc
        keep.append(last50 is not None)
        raw50.append(last50 or 0.0)
        raw90.append(last90 or 0.0)
        rates.append(float(tw.get(rate_signal) or 0))
    sm50, sm90, smr = smooth_stream(raw50, w), smooth_stream(raw90, w), smooth_stream(rates, w)

    rows = []
    for i, s in enumerate(samples):
        tw = s.get('timing_window') or {}
        pr, to, bl = (tw.get('processing_time') or {}), (tw.get('total_time') or {}), (tw.get('blocking_time') or {})
        fq = s.get('freq') or {}
        d = s.get('perf_deltas') or {}
        ts = iso_ns(s['timestamp']) / 1e9
        t_s = (ts - t0) if t0 else None
        rq = int(tw.get('request_count') or 0)
        row = dict.fromkeys(STEP_COLS, None)
        row.update(unix_ms=int(round(ts * 1000)), offset_ms=int(s.get('offset_ms') or 0),
                   t_s=t_s, phase=phase_of(t_s),
                   request_count=rq, arrival_count=int(tw.get('arrival_count') or 0),
                   arrival_rps_1s=float(tw.get('arrival_rps_1s') or 0), arrival_rps_3s=float(tw.get('arrival_rps_3s') or 0),
                   freq_mhz=float(fq.get('actual_freq_mhz') or 0), freq_ok=int(bool(fq.get('ok'))))
        if rq:
            row.update(proc_p50_us=pr.get('p50_ns', 0) / 1e3, proc_p90_us=pr.get('p90_ns', 0) / 1e3,
                       proc_p99_us=pr.get('p99_ns', 0) / 1e3,
                       total_p50_ms=to.get('p50_ns', 0) / 1e6, total_p90_ms=to.get('p90_ns', 0) / 1e6,
                       block_p50_ms=bl.get('p50_ns', 0) / 1e6, block_p90_ms=bl.get('p90_ns', 0) / 1e6)
        if keep[i]:
            d50, d90 = curve_lookup(curve, smr[i])
            y50 = max(0.0, math.tanh(k * (sm50[i] - p50b) / s50))
            y90 = max(0.0, math.tanh(k * (sm90[i] - p90b) / s90))
            e50 = min(1.0, max(0.0, (sm50[i] - d50) / sm50[i])) if sm50[i] > 0 else 0.0
            e90 = min(1.0, max(0.0, (sm90[i] - d90) / sm90[i])) if sm90[i] > 0 else 0.0
            row.update(T50_raw_kcyc=raw50[i], T90_raw_kcyc=raw90[i], T50_kcyc=sm50[i], T90_kcyc=sm90[i],
                       rate_smooth=smr[i], D50_kcyc=d50, D90_kcyc=d90,
                       y50=y50, y90=y90, ext50=e50, ext90=e90, e_iso=y90 * e90)
        for p in PERF:
            row[p.replace('-', '_')] = int(d.get(p) or 0)
        cyc, ins = int(d.get('cycles') or 0), int(d.get('instructions') or 0)
        row['cpi'] = (cyc / ins) if ins else None
        rows.append(row)
    meta = dict(section=section, k=k, w=w, t0=t0, arm_t=arm_t, n_windows=len(rows),
                n_scored=sum(keep))
    return rows, meta


def phase_summary(rows):
    out = {}
    for ph in ('p1', 'p2', 'p3'):
        r = [x for x in rows if x['phase'] == ph and x['y50'] is not None]
        if not r:
            continue
        m = lambda c: sum(x[c] for x in r) / len(r)  # noqa: E731
        lat = [x for x in r if x['proc_p90_us'] is not None]
        out[ph] = dict(n=len(r), y50=m('y50'), y90=m('y90'), ext90=m('ext90'), e_iso=m('e_iso'),
                       proc_p90_us=(sum(x['proc_p90_us'] for x in lat) / len(lat)) if lat else float('nan'))
    return out


def write_scores_csv(run, rows, tag):
    mdir = os.path.join(run, 'mitigation')
    os.makedirs(mdir, exist_ok=True)
    name = os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(run))))
    target, pod = 'search', ''
    orig = [o for o in glob.glob(os.path.join(mdir, '*.scores.csv')) if '.scores.replay-' not in o]
    if orig:
        name = os.path.basename(orig[0])[:-len('.scores.csv')]
        with open(orig[0]) as fh:
            for r in csv.DictReader(fh):
                target, pod = r.get('target', target), r.get('pod', pod)
                break
    out = os.path.join(mdir, f'{name}.scores.replay-{tag}.csv')
    with open(out, 'w', newline='') as fh:
        wr = csv.writer(fh)
        wr.writerow(['unix_ms', 'target', 'pod', 'yhat50', 'y50', 'y90', 'ext90', 'e_iso', 'n', 'applied_cap', 'ext50', 'i_horz'])
        for r in rows:
            if r['y50'] is None:
                continue
            wr.writerow([r['unix_ms'], target, pod, fmt(r['y50']), fmt(r['y50']), fmt(r['y90']), fmt(r['ext90']),
                         fmt(r['e_iso']), 0, '6.00', fmt(r['ext50']), '0.0000'])
    return name, out


def write_steps_csv(path, rows, extra=None, header=True, mode='w'):
    cols = (list(extra.keys()) if extra else []) + STEP_COLS
    with open(path, mode, newline='') as fh:
        wr = csv.writer(fh)
        if header:
            wr.writerow(cols)
        for r in rows:
            vals = (list(extra.values()) if extra else []) + [fmt(r[c]) for c in STEP_COLS]
            wr.writerow(vals)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('roots', nargs='+', help='dirs scanned recursively for stage3eval_*/runs/run_1')
    ap.add_argument('--config', required=True, help='gordion.json to replay (k, smooth_window, section, baseline)')
    ap.add_argument('--curve', required=True, help='matching curve.csv')
    ap.add_argument('--tag', default='replay', help='suffix of the output files')
    ap.add_argument('--onset', type=float, default=20.0, help='p1/p2 boundary in s since t0 (contention start)')
    ap.add_argument('--merged', default='', help='also write all runs\' step rows to this one CSV')
    ap.add_argument('--no-steps', action='store_true', help='only write the scores.replay csv')
    args = ap.parse_args()

    cfg = json.load(open(args.config))
    curve = load_curve(args.curve)
    runs = []
    for r in args.roots:
        runs += sorted(glob.glob(os.path.join(r, '**', 'stage3eval_*', 'runs', 'run_1'), recursive=True))
    if not runs:
        sys.exit('no stage3eval_*/runs/run_1 under ' + ' '.join(args.roots))

    print(f"calibration: {cfg.get('latency_section')} k={cfg['k']} smooth_window={cfg.get('smooth_window')} "
          f"baseline p50 {cfg['baseline']['p50_kcyc']} / p90 {cfg['baseline']['p90_kcyc']} kcyc")
    first_merged = True
    for run in runs:
        if not os.path.isfile(os.path.join(run, 'run_data.json')):
            print('skip (no run_data.json):', run)
            continue
        rows, meta = rescore_run(run, cfg, curve, args.onset)
        name, _ = write_scores_csv(run, rows, args.tag)
        if not args.no_steps:
            write_steps_csv(os.path.join(run, f'steps-{args.tag}.csv'), rows)
        if args.merged:
            cfgdir = os.path.dirname(os.path.dirname(os.path.dirname(run)))
            extra = dict(sweep=os.path.basename(os.path.dirname(cfgdir)), config=os.path.basename(cfgdir),
                         run=os.path.basename(os.path.dirname(os.path.dirname(run))))
            write_steps_csv(args.merged, rows, extra, header=first_merged, mode='w' if first_merged else 'a')
            first_merged = False
        ps = phase_summary(rows)
        desc = '  '.join(f"{ph}: e_iso {v['e_iso']:.3f} y90 {v['y90']:.3f} proc p90 {v['proc_p90_us']:.0f}us"
                         for ph, v in ps.items())
        print(f"{name:28s} {meta['n_windows']:5d} windows ({meta['n_scored']} scored, arm at {meta['arm_t']:.1f}s)  {desc}")
    if args.merged:
        print('merged ->', args.merged)


if __name__ == '__main__':
    main()
