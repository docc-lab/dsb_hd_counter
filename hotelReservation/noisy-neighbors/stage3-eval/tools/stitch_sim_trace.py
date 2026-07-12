#!/usr/bin/env python3
"""Stitch several Gordion-format sim traces (score_replay.py --sim-json
output) into one time-varying trace for simulation.py -- e.g. baseline ->
mild -> severe -> baseline, so the mitigation controllers see contention
levels rise and fall instead of a steady-state flat line.

Usage:
  python3 tools/stitch_sim_trace.py OUT.json SEG1.json SEG2.json ... \
      [--seg-seconds 30]

Each segment's samples are re-based so time is continuous across the
stitch; --seg-seconds trims every segment to its first N seconds first.
"""
import argparse
import json
import statistics as st


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('segments', nargs='+')
    ap.add_argument('--seg-seconds', type=float, default=None,
                    help='use only the first N seconds of each segment')
    args = ap.parse_args()

    merged, service = [], None
    t_next = 0.0
    for path in args.segments:
        with open(path) as f:
            data = json.load(f)
        service = service or data.get('service_name')
        samp = data['samples']
        if not samp:
            raise SystemExit(f'{path}: empty trace')
        t0 = samp[0]['offset_ms']
        rel = [(s['offset_ms'] - t0) / 1000.0 for s in samp]
        if args.seg_seconds is not None:
            keep = [i for i, r in enumerate(rel) if r < args.seg_seconds]
            samp, rel = [samp[i] for i in keep], [rel[i] for i in keep]
        step = (st.median(b - a for a, b in zip(rel, rel[1:]))
                if len(rel) > 1 else 0.1)
        for s, r in zip(samp, rel):
            out = dict(s)
            out['offset_ms'] = round((t_next + r) * 1000.0)
            merged.append(out)
        t_next += rel[-1] + step
        print(f'  {path}: {len(samp)} samples, {rel[-1]:.1f}s')

    with open(args.out, 'w') as f:
        json.dump({'service_name': service or 'search',
                   'samples': merged}, f)
    print(f'wrote {args.out}: {len(merged)} samples, {t_next:.1f}s total')


if __name__ == '__main__':
    main()
