#!/usr/bin/env python3
"""Replay the Gordion scorer offline over a captured :7901 Sample stream
under multiple parameter variants -- N score models "running" against the
SAME workload with zero cluster overhead.

Mirrors scorer.go semantics: kcyc normalization with per-window measured
frequency, causal Gaussian smoothing (reuses calibrate_from_stream's
smooth_stream, which mirrors the Go Smoother), clamped tanh scoring, and
the extrinsic decomposition against the curve, with the hold-last-value
behavior for empty windows.

Usage:
  python3 score_replay.py --samples run.ndjson \
      --config gordion.json --curve curve.csv \
      --variant k1=1.0 --variant kg=0.025 --variant kmid=0.1 \
      [--out-prefix /tmp/replay]

Each variant is NAME=K[xSIGMA_MULT], e.g. "wide=1.0x4" keeps k=1 but
multiplies both sigmas by 4 (the label_51-style wider-band framing --
only the k/sigma ratio matters to the tanh).

Outputs one verifier-compatible score log per variant
(<out-prefix>_<name>.log, consumable by verify_score_tracking.py with
the usual phases file) plus a per-variant summary on stdout.
"""
import argparse
import json
import math
import sys

from calibrate_from_stream import smooth_stream


def load_curve(path):
    rows = []
    with open(path) as f:
        header = f.readline().strip().split(',')
        i_rate = header.index('target_rps')
        i_p50 = header.index('svc_p50_norm_kcyc')
        i_p90 = header.index('svc_p90_norm_kcyc')
        for line in f:
            c = line.strip().split(',')
            if len(c) <= max(i_rate, i_p50, i_p90):
                continue
            rows.append((float(c[i_rate]), float(c[i_p50]), float(c[i_p90])))
    rows.sort()
    return rows


def curve_lookup(rows, lam):
    """Clamped linear interpolation, matching the Go Curve.Lookup intent."""
    if not rows:
        return 0.0, 0.0
    if lam <= rows[0][0]:
        return rows[0][1], rows[0][2]
    if lam >= rows[-1][0]:
        return rows[-1][1], rows[-1][2]
    for (r0, a0, b0), (r1, a1, b1) in zip(rows, rows[1:]):
        if r0 <= lam <= r1:
            t = (lam - r0) / (r1 - r0) if r1 > r0 else 0.0
            return a0 + t * (a1 - a0), b0 + t * (b1 - b0)
    return rows[-1][1], rows[-1][2]


def fget(d, *names, default=None):
    for n in names:
        if n in d:
            return d[n]
    return default


def load_samples(path, section, rate_signal):
    sec_camel = {'processing_time': 'processingTime',
                 'total_time': 'totalTime',
                 'blocking_time': 'blockingTime'}[section]
    rate_camel = {'arrival_rps_1s': 'arrivalRps1s',
                  'arrival_rps_3s': 'arrivalRps3s'}[rate_signal]
    out = []
    for line in open(path):
        try:
            s = json.loads(line)
        except Exception:
            continue
        ts = int(fget(s, 'timestampNs', 'timestamp_ns', default=0))
        tw = fget(s, 'timingWindow', 'timing_window', default=None) or {}
        sec = fget(tw, sec_camel, section, default=None) or {}
        fq = s.get('freq') or {}
        deltas = fget(s, 'perfDeltas', 'perf_deltas', default=None) or {}
        out.append(dict(
            ts=ts / 1e9,
            off=int(fget(s, 'offsetMs', 'offset_ms', default=0) or 0),
            p50=int(fget(sec, 'p50Ns', 'p50_ns', default=0) or 0),
            p90=int(fget(sec, 'p90Ns', 'p90_ns', default=0) or 0),
            count=int(fget(sec, 'count', default=0) or 0),
            rate=float(fget(tw, rate_camel, rate_signal, default=0) or 0),
            rate1=float(fget(tw, 'arrivalRps1s', 'arrival_rps_1s',
                             default=0) or 0),
            f=float(fget(fq, 'actualFreqMhz', 'actual_freq_mhz', default=0) or 0),
            fok=bool(fget(fq, 'ok', default=False)),
            cycles=int(fget(deltas, 'cycles', 'cpu-cycles', default=0) or 0),
            instr=int(fget(deltas, 'instructions', default=0) or 0),
        ))
    return out


def replay(samples, cfg, curve, k, sig_mult):
    base = cfg['baseline']
    p50b, p90b = base['p50_kcyc'], base['p90_kcyc']
    s50 = base['sigma50_kcyc'] * sig_mult
    s90 = base['sigma90_kcyc'] * sig_mult
    fb = base.get('freq_mhz', 2400.0)
    w = cfg.get('smooth_window', 30)

    # Build raw kcyc streams with hold-last for empty windows.
    t50s_raw, t90s_raw, rates, keep = [], [], [], []
    last50 = last90 = None
    for s in samples:
        f = s['f'] if (s['fok'] and s['f'] > 0) else fb
        if s['count'] > 0 and s['p50'] > 0:
            last50 = s['p50'] * f / 1e6
            last90 = s['p90'] * f / 1e6
        if last50 is None:
            keep.append(False)
            t50s_raw.append(0.0)
            t90s_raw.append(0.0)
        else:
            keep.append(True)
            t50s_raw.append(last50)
            t90s_raw.append(last90)
        rates.append(s['rate'])

    t50s = smooth_stream(t50s_raw, w)
    t90s = smooth_stream(t90s_raw, w)
    rs = smooth_stream(rates, w)

    rows = []
    for i, s in enumerate(samples):
        if not keep[i]:
            continue
        y50 = max(0.0, math.tanh(k * (t50s[i] - p50b) / s50))
        y90 = max(0.0, math.tanh(k * (t90s[i] - p90b) / s90))
        d50, d90 = curve_lookup(curve, rs[i])
        e50 = min(1.0, max(0.0, (t50s[i] - d50) / t50s[i])) if t50s[i] > 0 else 0.0
        e90 = min(1.0, max(0.0, (t90s[i] - d90) / t90s[i])) if t90s[i] > 0 else 0.0
        rows.append((s['ts'], y50, y90, e50, e90, i))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--samples', required=True)
    ap.add_argument('--config', default='gordion.json')
    ap.add_argument('--curve', default='curve.csv')
    ap.add_argument('--variant', action='append', required=True,
                    metavar='NAME=K[xSIGMA_MULT]')
    ap.add_argument('--competitors', action='store_true',
                    help='also emit the comparison-table scoring methods over '
                         'the same windows (Slowdown Ratio, CI tail-to-median, '
                         'CPI, Rolling Percentile, Binary Classifier) to '
                         '<out-prefix>_competitors.csv. Check the parameter '
                         'flags below against the cited papers.')
    ap.add_argument('--comp-window', type=int, default=10,
                    help='rolling-window length in samples (100ms each) for '
                         'CI/CPI/Binary rolling baselines [default 10 = 1s]')
    ap.add_argument('--rp-window', type=int, default=300,
                    help='Rolling Percentile lookback in samples [default 300 = 30s]')
    ap.add_argument('--rp-q', type=float, default=0.95,
                    help='Rolling Percentile reference quantile [default 0.95]')
    ap.add_argument('--bin-hi', type=float, default=2.0,
                    help='Binary Classifier enter threshold, x rolling median [default 2.0]')
    ap.add_argument('--bin-lo', type=float, default=1.5,
                    help='Binary Classifier exit threshold (hysteresis), x rolling median [default 1.5]')
    ap.add_argument('--sim-json', action='store_true',
                    help='also write <out-prefix>_<name>_sim.json per variant '
                         'in the Gordion JSON format consumed by '
                         'simulation.py (offset_ms, p50/p90_contention_score, '
                         'timing_window.arrival_rps_1s)')
    ap.add_argument('--out-prefix', default='/tmp/replay')
    args = ap.parse_args()

    cfg = json.load(open(args.config))
    curve = load_curve(args.curve)
    samples = load_samples(args.samples,
                           cfg.get('latency_section', 'processing_time'),
                           cfg.get('rate_signal', 'arrival_rps_3s'))
    if len(samples) < 50:
        sys.exit(f'only {len(samples)} samples in {args.samples}')

    print(f'{len(samples)} windows | variant results (steady state = after first 150):')
    for spec in args.variant:
        name, val = spec.split('=', 1)
        k, _, mult = val.partition('x')
        k, mult = float(k), float(mult) if mult else 1.0
        rows = replay(samples, cfg, curve, k, mult)
        out = f'{args.out_prefix}_{name}.log'
        with open(out, 'w') as f:
            for ts, y50, y90, e50, e90, _ in rows:
                f.write(f'replay INF score_replay > score_event timestamp={ts:.3f} '
                        f'y50_current={y50:.4f} tail_trend_label={y90:.4f} '
                        f'ext_pct_50={e50:.4f} ext_pct_90={e90:.4f} '
                        f'p50_trend_pred={y50:.4f} prediction_on=false\n')
        if args.sim_json:
            sim = {'service_name': cfg.get('service', 'search'),
                   'samples': [
                       {'offset_ms': samples[i]['off'],
                        'p50_contention_score': round(y50, 4),
                        'p90_contention_score': round(y90, 4),
                        'p90_extrinsic_pct': round(e90, 4),
                        'timing_window': {
                            'arrival_rps_1s': samples[i]['rate1']}}
                       for ts, y50, y90, e50, e90, i in rows]}
            sim_out = f'{args.out_prefix}_{name}_sim.json'
            with open(sim_out, 'w') as f:
                json.dump(sim, f)
            print(f'  {name:<8} sim trace: {len(sim["samples"])} samples '
                  f'-> {sim_out}')
        st = rows[150:] or rows
        m50 = sum(r[1] for r in st) / len(st)
        m90 = sum(r[2] for r in st) / len(st)
        e50m = sum(r[3] for r in st) / len(st)
        pin = sum(1 for r in st if r[1] > 0.99)
        print(f'  {name:<8} (k={k:g}, sigma x{mult:g}): mean y50={m50:.3f} '
              f'y90={m90:.3f} ext50={e50m:.3f} pinned {pin}/{len(st)}  -> {out}')

    if args.competitors:
        # Comparison-table methods, one value per window, all over the SAME
        # frequency-normalized latency stream the Gordion variants saw.
        # Formulas as implemented (VERIFY against the cited papers):
        #   slowdown_ratio  = L_t / median(L_0..L_t)          [historical,
        #                     non-isolated baseline -- deliberately so]
        #   ci              = mean(p90, last W) / mean(p50, last W)
        #                     [tail-to-median over short rolling window]
        #   cpi             = sum(cycles, last W) / sum(instructions, last W)
        #   rolling_pctl    = L_t / Q_q(L, last RP_W windows)
        #   binary          = 1 when L_t > bin_hi x rolling-median(last W),
        #                     back to 0 when L_t < bin_lo x rolling-median
        #                     (hysteresis)
        from bisect import insort, bisect_left
        W, RPW, Q = args.comp_window, args.rp_window, args.rp_q
        out = f'{args.out_prefix}_competitors.csv'
        hist_sorted = []          # slowdown ratio: all history, kept sorted
        roll = []                 # (p50k, p90k, cycles, instr) last W
        rp = []                   # last RPW p50k values
        state = 0
        rows = []
        with open(out, 'w') as f:
            f.write('ts,slowdown_ratio,ci,cpi,rolling_pctl,binary\n')
            for s in samples:
                if s['count'] <= 0 or s['p50'] <= 0:
                    continue
                fmhz = s['f'] if (s['fok'] and s['f'] > 0) else cfg['baseline'].get('freq_mhz', 2400.0)
                L = s['p50'] * fmhz / 1e6
                p90k = s['p90'] * fmhz / 1e6

                insort(hist_sorted, L)
                hmed = hist_sorted[len(hist_sorted) // 2]
                sr = L / hmed if hmed > 0 else 0.0

                roll.append((L, p90k, s['cycles'], s['instr']))
                if len(roll) > W:
                    roll.pop(0)
                m50 = sum(r[0] for r in roll) / len(roll)
                m90 = sum(r[1] for r in roll) / len(roll)
                ci = m90 / m50 if m50 > 0 else 0.0
                cyc = sum(r[2] for r in roll)
                ins = sum(r[3] for r in roll)
                cpi = cyc / ins if ins > 0 else 0.0

                rp.append(L)
                if len(rp) > RPW:
                    rp.pop(0)
                ref = sorted(rp)[min(len(rp) - 1, int(len(rp) * Q))]
                rpctl = L / ref if ref > 0 else 0.0

                rmed = sorted(r[0] for r in roll)[len(roll) // 2]
                if state == 0 and L > args.bin_hi * rmed:
                    state = 1
                elif state == 1 and L < args.bin_lo * rmed:
                    state = 0

                f.write(f"{s['ts']:.3f},{sr:.4f},{ci:.4f},{cpi:.4f},{rpctl:.4f},{state}\n")
                rows.append((sr, ci, cpi, rpctl, state, s))
        st = rows[150:] or rows
        n = len(st)
        names = ['slowdown_ratio', 'ci', 'cpi', 'rolling_pctl', 'binary(frac=1)']
        means = [sum(r[i] for r in st) / n for i in range(5)]
        print('  competitors (steady means): ' +
              ' | '.join(f'{nm}={m:.3f}' for nm, m in zip(names, means)) + f'  -> {out}')
        if args.sim_json:
            # RAW values, deliberately unnormalized -- only Gordion is [0,1]
            # by construction; map competitors onto the controllers' score
            # scale downstream (e.g. compare_drivers.py anchors baseline->0,
            # severe->1) so the normalization choice stays in one place.
            for j, nm in enumerate(('slowdown_ratio', 'ci', 'cpi',
                                    'rolling_pctl', 'binary')):
                sim = {'service_name': cfg.get('service', 'search'),
                       'samples': [
                           {'offset_ms': r[5]['off'],
                            'p50_contention_score': round(r[j], 4),
                            'p90_contention_score': round(r[j], 4),
                            'timing_window': {
                                'arrival_rps_1s': r[5]['rate1']}}
                           for r in rows]}
                with open(f'{args.out_prefix}_{nm}_sim.json', 'w') as f:
                    json.dump(sim, f)
            print(f'  competitors sim traces: {len(rows)} samples x 5 '
                  f'-> {args.out_prefix}_<method>_sim.json (raw values)')


if __name__ == '__main__':
    main()
