#!/usr/bin/env python3
"""Neighbour-side cost of a mitigation, from the aggressor testbeds' wrk2
output that the phase orchestrator stores per run (runs/run_1/wrk2/
<testbed>.txt). The bursty load generator writes one wrk2 block per
segment, preceded by a timestamped header:

    --- BURST peak_rps=7000 for 10s @  2026-10-23T23:28:26+00:00
    Running 10s test @ http://10.10.1.5:9106
    ...
    Requests/sec:   1728.99

Each block is placed on the run's time axis (started_epoch_ns) and given a
phase (p1 / p2 / p3 from --onset and armed_epoch_ns). Per testbed and phase
the tool reports the burst segments' achieved rate (= the aggressors'
capacity when they are saturated, as socialNetwork is at 7000 rps), p50 /
p99 latency and error count, and the within-run p3/p2 ratio, which is the
apples-to-apples neighbour cost: same run, same load, the only difference
being that the mitigation is armed in p3. Cross-run comparisons of absolute
aggressor throughput are confounded by run-to-run variance of the
aggressor pipelines (observed 2x between identical p2 phases).

  python3 tools/aggr_wrk2_phases.py data/motiv/none data/motiv/hc-bang \
      data/motiv/horizontal-any-node4 [--csv out.csv]
"""
import argparse
import csv
import glob
import os
import re
import sys
from datetime import datetime

UNIT_MS = {'us': 1e-3, 'ms': 1.0, 's': 1e3, 'm': 6e4}


def to_ms(m):
    if not m:
        return None
    return float(m.group(1)) * UNIT_MS.get(m.group(2), 1.0)


def parse_blocks(path):
    """Yield dicts per wrk2 block with the header timestamp when present."""
    txt = open(path, errors='replace').read()
    # split on the segment headers (keep them) and on bare 'Running' lines
    parts = re.split(r'(?=^--- (?:BURST|IDLE|BASE|waiting|STEADY)[^\n]*)', txt, flags=re.M)
    out = []
    for part in parts:
        hdr = re.match(r'--- (\w+)([^\n]*?)@\s*(\S+)', part)
        for blk in re.split(r'(?=Running \d+s test @)', part):
            if not blk.startswith('Running'):
                continue
            dur = int(re.match(r'Running (\d+)s', blk).group(1))
            rps = re.search(r'Requests/sec:\s+([\d.]+)', blk)
            req = re.search(r'(\d+) requests in ([\d.]+)([a-z]+)', blk)
            err = re.search(r'Non-2xx or 3xx responses: (\d+)', blk)
            sock = re.search(r'Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)', blk)
            out.append(dict(
                kind=hdr.group(1) if hdr else '',
                label=(hdr.group(2).strip() if hdr else ''),
                start=(datetime.fromisoformat(hdr.group(3)).timestamp() if hdr else None),
                dur=dur,
                rps=float(rps.group(1)) if rps else None,
                n=int(req.group(1)) if req else None,
                p50=to_ms(re.search(r'^\s*50\.000%\s+([\d.]+)(\w+)', blk, re.M)),
                p90=to_ms(re.search(r'^\s*90\.000%\s+([\d.]+)(\w+)', blk, re.M)),
                p99=to_ms(re.search(r'^\s*99\.000%\s+([\d.]+)(\w+)', blk, re.M)),
                err=int(err.group(1)) if err else 0,
                timeouts=int(sock.group(4)) if sock else 0,
            ))
    return out


def read_int(path):
    try:
        return int(open(path).read().strip())
    except (OSError, ValueError):
        return None


def analyse_run(run, onset):
    t0_ns = read_int(os.path.join(run, 'started_epoch_ns.txt'))
    arm_ns = read_int(os.path.join(run, 'mitigation', 'armed_epoch_ns.txt'))
    t0 = t0_ns / 1e9
    arm_t = (arm_ns - t0_ns) / 1e9 if arm_ns else 80.0
    res = {}
    for f in sorted(glob.glob(os.path.join(run, 'wrk2', '*.txt'))):
        tb = os.path.splitext(os.path.basename(f))[0]
        blocks = parse_blocks(f)
        if len(blocks) <= 1:
            continue          # the victim's single 140 s block: not a neighbour
        t = None
        for b in blocks:
            if b['start'] is not None:
                t = b['start'] - t0
            b['t'] = t
            b['phase'] = ('' if t is None else 'p1' if t < onset else 'p2' if t < arm_t else 'p3')
            if t is not None:
                t += b['dur']
        res[tb] = blocks
    return res, arm_t


def summarise(blocks, kind='BURST'):
    out = {}
    for ph in ('p2', 'p3'):
        sel = [b for b in blocks if b['phase'] == ph and (b['kind'] == kind or not kind) and b['rps']]
        if not sel:
            continue
        m = lambda c: sum(b[c] for b in sel if b[c] is not None) / max(1, len([b for b in sel if b[c] is not None]))  # noqa: E731
        out[ph] = dict(n=len(sel), rps=m('rps'), p50=m('p50'), p99=m('p99'),
                       err=sum(b['err'] for b in sel), timeouts=sum(b['timeouts'] for b in sel))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('roots', nargs='+', help='dirs scanned recursively for stage3eval_*/runs/run_1')
    ap.add_argument('--onset', type=float, default=20.0)
    ap.add_argument('--kind', default='BURST', help='segment kind to summarise (BURST, IDLE, or "" for all)')
    ap.add_argument('--csv', default='', help='write per-block rows here')
    args = ap.parse_args()

    runs = []
    for r in args.roots:
        runs += sorted(glob.glob(os.path.join(r, '**', 'stage3eval_*', 'runs', 'run_1'), recursive=True))
    if not runs:
        sys.exit('no runs under ' + ' '.join(args.roots))

    rows = []
    print(f"{'run':24s} {'testbed':14s} {'ph':3s} {'segs':>4s} {'rps':>7s} {'p50ms':>8s} {'p99ms':>8s} {'err':>5s} {'t/o':>5s}   p3/p2: rps   p50   p99")
    for run in runs:
        label = os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(run))))
        res, arm_t = analyse_run(run, args.onset)
        for tb, blocks in res.items():
            s = summarise(blocks, args.kind)
            for ph in ('p2', 'p3'):
                if ph not in s:
                    continue
                v = s[ph]
                ratio = ''
                if ph == 'p3' and 'p2' in s and s['p2']['rps']:
                    q = s['p2']
                    ratio = f"{v['rps'] / q['rps']:5.2f} {v['p50'] / q['p50'] if q['p50'] else float('nan'):5.2f} " \
                            f"{v['p99'] / q['p99'] if q['p99'] else float('nan'):5.2f}"
                print(f"{label:24s} {tb:14s} {ph:3s} {v['n']:4d} {v['rps']:7.0f} {v['p50']:8.0f} {v['p99']:8.0f} "
                      f"{v['err']:5d} {v['timeouts']:5d}   {ratio}")
            for b in blocks:
                rows.append(dict(run=label, testbed=tb, **{k: b[k] for k in
                            ('kind', 'label', 't', 'phase', 'dur', 'rps', 'n', 'p50', 'p90', 'p99', 'err', 'timeouts')}))
        print(f"{'':24s} (arm at {arm_t:.1f} s; {args.kind or 'all'} segments only)")
    if args.csv:
        with open(args.csv, 'w', newline='') as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
        print('wrote', args.csv)


if __name__ == '__main__':
    main()
