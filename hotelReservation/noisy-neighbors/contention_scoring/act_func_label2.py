# act_func_label2.py

import json
import numpy as np
import pandas as pd
from pathlib import Path
from typing import Dict, List, Optional, Tuple


def extract_response_times(samples: List[Dict], perc='p90_ns') -> np.ndarray:
    """Extract response times from samples."""
    response_times = []
    for sample in samples:
        timing = sample.get('timing_window', {})
        total_time = timing.get('processing_time', {}).get(perc, 0)
        response_time_ms = total_time / 1_000_000 if total_time > 0 else 0
        response_times.append(response_time_ms)
    return np.array(response_times)


def extract_actual_freq_mhz(samples: List[Dict]) -> np.ndarray:
    """
    Extract actual CPU frequency (MHz) from sample["freq"]["actual_freq_mhz"].
    Returns 0.0 for samples where freq.ok is False or the field is absent.
    """
    freqs = []
    for sample in samples:
        freq_block = sample.get('freq', {})
        if freq_block.get('ok', False):
            freqs.append(float(freq_block.get('actual_freq_mhz', 0.0)))
        else:
            freqs.append(0.0)
    return np.array(freqs)


def extract_arrival_rate(
        samples: List[Dict],
        field_candidates: Tuple[str, ...] = ('target_rps', 'rps', 'arrival_rate', 'load_rps'),
        timing_window_candidates: Tuple[str, ...] = ('arrival_rps_1s', 'arrival_rps_3s'),
) -> np.ndarray:
    """
    Extract the per-sample offered arrival rate λ (requests/sec), used to look
    up the matching point on the clean load↔latency curve (curve.csv) for the
    extrinsic-percentage calculation.

    Lookup order (first match wins):
      1. Top level of the sample dict (field_candidates) — legacy/synthetic.
      2. A nested 'load' block (field_candidates) — legacy.
      3. sample['timing_window'][<candidate>] using timing_window_candidates —
         where real run files carry the signal ('arrival_rps_1s' preferred,
         'arrival_rps_3s' fallback).

    Returns NaN for samples where no matching field is found anywhere.
    """
    rates = []
    for s in samples:
        val = None
        for key in field_candidates:
            if key in s:
                val = s[key]
                break
        if val is None:
            load_block = s.get('load', {})
            if isinstance(load_block, dict):
                for key in field_candidates:
                    if key in load_block:
                        val = load_block[key]
                        break
        if val is None:
            tw_block = s.get('timing_window', {})
            if isinstance(tw_block, dict):
                for key in timing_window_candidates:
                    if key in tw_block:
                        val = tw_block[key]
                        break
        try:
            rates.append(float(val) if val is not None else np.nan)
        except (TypeError, ValueError):
            rates.append(np.nan)
    return np.array(rates, dtype=float)


def load_curve_data(path: str) -> Dict[str, np.ndarray]:
    """
    Load the clean load↔latency curve (curve.csv).

    Expected columns: target_rps, svc_p50_us, svc_p90_us, freq_mhz.
    Latency columns are kept RAW; at lookup time each sample's arrival rate
    is matched to the closest row (nearest_curve_values), and that row's own
    freq_mhz is used to normalise its svc_p50_us / svc_p90_us.

    Returns sorted 'rps', 'svc_p50_us', 'svc_p99_us', 'freq_mhz' arrays.
    """
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"Curve file not found: {p}")
    df = pd.read_csv(p)

    rps      = df['target_rps'].to_numpy(dtype=float)
    svc_p50  = df['svc_p50_us'].to_numpy(dtype=float)
    svc_p90  = df['svc_p90_us'].to_numpy(dtype=float)
    freq_mhz = df['freq_mhz'].to_numpy(dtype=float)

    order = np.argsort(rps)
    rps, svc_p50, svc_p90, freq_mhz = rps[order], svc_p50[order], svc_p90[order], freq_mhz[order]

    print(f"  Curve loaded ({p.name}): {len(rps)} points, "
          f"rps range [{rps.min():.0f}, {rps.max():.0f}]")
    return {'rps': rps, 'svc_p50_us': svc_p50, 'svc_p99_us': svc_p90, 'freq_mhz': freq_mhz}


def nearest_curve_values(arrival_rate: np.ndarray, curve: Dict[str, np.ndarray]) -> Tuple[np.ndarray, np.ndarray]:
    """
    For each sample's arrival rate λ, find the curve.csv row whose target_rps
    is CLOSEST to λ (nearest-neighbour match), then use that row's own
    freq_mhz — together with its svc_p99_us / svc_p50_us — to build the
    frequency-normalised D90[λ] / D50[λ] reference used in the extrinsic
    percentage calculation.

    Samples with an unavailable / NaN arrival rate fall back to the curve
    row closest to the median offered load in the curve.

    Returns per-sample D90[λ[i]], D50[λ[i]] arrays.
    """
    rps      = curve['rps']
    svc_p50  = curve['svc_p50_us']
    svc_p90  = curve['svc_p99_us']
    freq_mhz = curve['freq_mhz']
    n = len(arrival_rate)

    idx = np.zeros(n, dtype=int)
    valid = np.isfinite(arrival_rate)

    if np.any(valid):
        pos = np.searchsorted(rps, arrival_rate[valid])
        pos = np.clip(pos, 1, len(rps) - 1)
        left_rps  = rps[pos - 1]
        right_rps = rps[pos]
        go_left = (arrival_rate[valid] - left_rps) <= (right_rps - arrival_rate[valid])
        nearest = np.where(go_left, pos - 1, pos)
        idx[valid] = nearest

    if np.any(~valid):
        fallback_idx = int(np.argmin(np.abs(rps - np.median(rps))))
        idx[~valid] = fallback_idx

    row_freq = freq_mhz[idx]
    d90_vals = svc_p90[idx] * row_freq
    d50_vals = svc_p50[idx] * row_freq
    return d90_vals, d50_vals


def load_baseline_stats(stats_filepath: str = None) -> Tuple[Dict, Optional[Dict], float]:
    """
    Load baseline statistics from file.

    Supports two formats:
      1. Nested  — {"latency_p90": {...}, "latency_p50": {...}, "freq_stats": {...}}
      2. Flat    — {"mean": ..., "std": ..., "q90": ...}  (legacy)

    Returns
    -------
    baseline_stats_p90 : flat dict with mean/std/q50/q90/q95/q99/median keys
    baseline_stats_p50 : flat dict (same shape) or None for legacy flat files
    baseline_freq_mhz  : mean actual CPU frequency (MHz) recorded during the
                         baseline run, used to normalise baseline latency
                         scalars onto the same (ms*Hz) scale as per-sample
                         signals. 0.0 if unavailable (normalisation disabled).
    """
    if stats_filepath is None:
        stats_filepath = Path("..") / "Data" / "baseline_stats.json"
    else:
        stats_filepath = Path(stats_filepath)

    if not stats_filepath.exists():
        raise FileNotFoundError(f"Baseline statistics file not found: {stats_filepath}")

    print(f"Loading baseline statistics from: {stats_filepath}")

    with open(stats_filepath, 'r') as f:
        raw = json.load(f)

    # ── Nested format (new) ───────────────────────────────────────────────────
    if 'latency_p90' in raw and 'latency_p50' in raw:
        s90 = dict(raw['latency_p90'])
        s50 = dict(raw['latency_p50'])
        for s in (s90, s50):
            s.setdefault('q50',    s.get('median', s['mean']))
            s.setdefault('median', s.get('q50',    s['mean']))

        # Baseline reference frequency — mean actual_freq_mhz from the
        # baseline collection run, at freq_stats.actual_freq_mhz.mean
        # (falls back to a flat freq_stats.mean for older schemas).
        freq_stats = raw.get('freq_stats', {})
        baseline_freq_mhz = 0.0
        if isinstance(freq_stats, dict):
            actual_freq_block = freq_stats.get('actual_freq_mhz', {})
            if isinstance(actual_freq_block, dict) and 'mean' in actual_freq_block:
                baseline_freq_mhz = float(actual_freq_block['mean'])
            elif 'mean' in freq_stats:
                baseline_freq_mhz = float(freq_stats['mean'])

        print(f"Baseline statistics loaded (nested format):")
        print(f"  [p90] Mean={s90['mean']:.4f} ms  q90={s90['q90']:.4f} ms")
        print(f"  [p50] Mean={s50['mean']:.4f} ms  q50={s50['q50']:.4f} ms")
        print(f"  Baseline actual_freq_mhz mean: {baseline_freq_mhz:.1f}"
              + (" ⚠ (missing — baseline normalisation disabled)" if baseline_freq_mhz == 0 else ""))
        return s90, s50, baseline_freq_mhz

    # ── Flat / legacy format ──────────────────────────────────────────────────
    raw.setdefault('q50',    raw.get('median', raw['mean']))
    raw.setdefault('median', raw.get('q50',    raw['mean']))

    print(f"Baseline statistics loaded (flat/legacy format):")
    print(f"  Mean: {raw['mean']:.4f} ms")
    print(f"  Std:  {raw['std']:.4f} ms")
    print(f"  Q90:  {raw['q90']:.4f} ms")
    print(f"  Q99:  {raw['q99']:.4f} ms")
    return raw, None, 0.0


# ══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════════════════════════════

def _gaussian_smooth(data: np.ndarray, window: int) -> np.ndarray:
    """Causal Gaussian smoother (no look-ahead)."""
    if window <= 1:
        return data.copy()
    x = np.arange(window)
    sigma = window / 3.0
    kernel = np.exp(-(x ** 2) / (2 * sigma ** 2))
    kernel /= kernel.sum()
    smoothed = np.zeros_like(data)
    for i in range(len(data)):
        start = max(0, i - window + 1)
        w = data[start:i + 1]
        k = kernel[(window - len(w)):][::-1]
        smoothed[i] = np.dot(w, k)
    return smoothed


def _normalize_latency(rt_ms: np.ndarray, freq_mhz: np.ndarray) -> np.ndarray:
    """
    Frequency-normalise latency: rt_s * freq_hz.
    freq_hz = actual_freq_mhz * 1e6  (read directly from sample["freq"]).
    rt_ms is converted to seconds (rt_ms / 1000) before multiplying, matching
    the Gordion reference implementation (label_func_comp2.normalize_latency).
    Falls back to rt_ms unchanged where freq is zero / unavailable.
    """
    freq_hz   = freq_mhz * 1e6
    safe_freq = np.where(freq_hz > 0, freq_hz, np.nan)
    normed    = rt_ms / 1000 * safe_freq
    return np.where(np.isfinite(normed), normed, rt_ms)


def _normalize_scalar(value: float, baseline_freq_mhz: float) -> float:
    """
    Normalise a scalar latency (ms) using a fixed baseline frequency.
    value is converted to seconds (value / 1000) before multiplying, matching
    the Gordion reference implementation (label_func_comp2.normalize_scalar).
    """
    if baseline_freq_mhz <= 0:
        return value
    freq_hz = baseline_freq_mhz * 1e6
    return value / 1000 * freq_hz


# ══════════════════════════════════════════════════════════════════════════════
# GORDION: DUAL TANH SCORING + INDEPENDENT EXTRINSIC PERCENTAGE
#
# Contention SCORE and extrinsic PERCENTAGE are computed in the same function
# but are fully independent:
#   - p90/p50 scores    : pure latency-based tanh vs a fixed baseline
#   - pct_ext_90/50     : deviation of smoothed, freq-normalised latency from
#                         the load-aware expectation D90[λ]/D50[λ] read off a
#                         clean load↔latency curve (curve.csv), matched to
#                         each sample's own arrival rate
#
# Returns p90_labels, p50_labels, pct_ext_90, pct_ext_50 separately.
# ══════════════════════════════════════════════════════════════════════════════

def gordion_contention(response_times_p90, response_times_p50,
                       p50_based, p50_std,
                       baseline_mean, baseline_median, baseline_std,
                       baseline_p50, baseline_p90, baseline_p95, baseline_p99,
                       failure_value=None, k=1.0, smoothing_window=10,
                       p50_sensitivity=1.0, p50_threshold=0.00,
                       burst_window=25,
                       freq_mhz=None,
                       d90_curve_vals=None,
                       d50_curve_vals=None,
                       **kwargs):
    """
    Gordion: Dual-input contention scoring with independent extrinsic
    percentage.

    Contention SCORE  — derived from freq-normalised latency (p90 / p50 tanh).
                        freq_hz = actual_freq_mhz * 1e6 per sample.
                        Falls back to raw ms where freq is unavailable.
    Extrinsic PERCENT — (T_smooth - D[λ]) / T_smooth * 100, comparing the
                        smoothed freq-normalised latency against the
                        load-aware reference from curve.csv at that sample's
                        own arrival rate. Clipped to [0, 100]; NaN where the
                        curve reference or arrival rate is unavailable.
    Both are computed together but neither gates the other.

    Parameters
    ----------
    freq_mhz : np.ndarray, optional
        Per-sample actual CPU frequency in MHz from sample["freq"]["actual_freq_mhz"].
        When provided, latencies are normalised to ms*Hz before scoring so that
        CPU-frequency fluctuations do not create false contention signals.
        Baseline thresholds (baseline_p90, p50_based, etc.) must already be
        freq-normalised to the same scale (use _normalize_scalar).
    d90_curve_vals, d50_curve_vals : np.ndarray, optional
        Per-sample, frequency-normalised D90[λ[i]] / D50[λ[i]] reference
        values from the clean load curve (see nearest_curve_values). If
        either is None, the corresponding extrinsic-percentage output is
        returned as all-NaN (feature disabled).

    Returns
    -------
    p90_labels  : np.ndarray [0,1]    — tail/bursty severity
    p50_labels  : np.ndarray [0,1]    — mean/sustained severity
    pct_ext_90  : np.ndarray [0,100]  — extrinsic percentage (tail), NaN if disabled
    pct_ext_50  : np.ndarray [0,100]  — extrinsic percentage (median), NaN if disabled
    """
    response_times_p90 = np.array(response_times_p90, dtype=float)
    response_times_p50 = np.array(response_times_p50, dtype=float)
    n = len(response_times_p90)

    assert n == len(response_times_p50), "P90 and P50 arrays must have same length"

    # ── failure mask (on raw ms, before normalisation) ────────────────────────
    if failure_value is not None:
        failures = (response_times_p90 == failure_value) | \
                   (response_times_p50 == failure_value)
    else:
        failures = np.isnan(response_times_p90) | np.isnan(response_times_p50)

    # ── freq normalisation: rt_s * actual_freq_hz ────────────────────────────
    if freq_mhz is not None:
        freq_mhz_arr = np.array(freq_mhz, dtype=float)
        assert len(freq_mhz_arr) == n, "freq_mhz must have same length as response_times"
        rt_p90 = _normalize_latency(response_times_p90, freq_mhz_arr)
        rt_p50 = _normalize_latency(response_times_p50, freq_mhz_arr)
    else:
        rt_p90 = response_times_p90
        rt_p50 = response_times_p50

    # ── smooth (causal) ───────────────────────────────────────────────────────
    smoothed_p90 = _gaussian_smooth(rt_p90, smoothing_window)
    smoothed_p50 = _gaussian_smooth(rt_p50, smoothing_window)

    # ══════════════════════════════════════════════════════════════════════════
    # BRANCH A — CONTENTION SCORE  (latency tanh vs fixed baseline)
    # ══════════════════════════════════════════════════════════════════════════
    raw_p90 = np.zeros(n, dtype=float)
    raw_p50 = np.zeros(n, dtype=float)

    for i in range(n):
        if failures[i]:
            raw_p90[i] = raw_p50[i] = 1.0
            continue

        if smoothed_p90[i] > baseline_p90:
            raw_p90[i] = np.tanh(
                (smoothed_p90[i] - baseline_p90) / (baseline_std + 1e-6) * k)

        p50_activation = p50_based * (1 + p50_threshold)
        if smoothed_p50[i] > p50_activation:
            raw_p50[i] = np.tanh(
                (smoothed_p50[i] - p50_based) / (p50_std + 1e-6) * k) * p50_sensitivity

    # ── burst-aware max-pool with linear interpolation ────────────────────────
    def _burst_pool(raw_scores: np.ndarray) -> np.ndarray:
        stride = burst_window // 2
        wm, wp = [], []
        for i in range(0, n, stride):
            start = max(0, i - burst_window + 1)
            wm.append(np.max(raw_scores[start:min(n, i + 1)]))
            wp.append(i)
        if wp[-1] != n - 1:
            wm.append(np.max(raw_scores[max(0, n - burst_window):]))
            wp.append(n - 1)
        wm, wp = np.array(wm), np.array(wp)
        out = np.zeros(n, dtype=float)
        for i in range(n):
            if i <= wp[0]:
                out[i] = wm[0]
            elif i >= wp[-1]:
                out[i] = wm[-1]
            else:
                ir = np.searchsorted(wp, i, side='right')
                il = ir - 1
                t  = (i - wp[il]) / (wp[ir] - wp[il])
                out[i] = wm[il] + t * (wm[ir] - wm[il])
        return np.clip(out, 0.0, 1.0)

    labels_p90 = _burst_pool(raw_p90)
    labels_p50 = _burst_pool(raw_p50)
    labels_p90[failures] = 1.0
    labels_p50[failures] = 1.0

    # ══════════════════════════════════════════════════════════════════════════
    # BRANCH B — EXTRINSIC PERCENTAGE  (load-aware deviation, fully independent)
    # ══════════════════════════════════════════════════════════════════════════
    pct_ext_90 = np.full(n, np.nan)
    pct_ext_50 = np.full(n, np.nan)

    if d90_curve_vals is not None:
        with np.errstate(divide='ignore', invalid='ignore'):
            pct_ext_90 = np.where(smoothed_p90 != 0,
                                   (smoothed_p90 - d90_curve_vals) / smoothed_p90 * 100.0,
                                   np.nan)
        pct_ext_90[failures] = np.nan
        pct_ext_90 = np.clip(pct_ext_90, 0.0, 100.0)

    if d50_curve_vals is not None:
        with np.errstate(divide='ignore', invalid='ignore'):
            pct_ext_50 = np.where(smoothed_p50 != 0,
                                   (smoothed_p50 - d50_curve_vals) / smoothed_p50 * 100.0,
                                   np.nan)
        pct_ext_50[failures] = np.nan
        pct_ext_50 = np.clip(pct_ext_50, 0.0, 100.0)

    return labels_p90, labels_p50, pct_ext_90, pct_ext_50


# ══════════════════════════════════════════════════════════════════════════════
# LEGACY DUAL INPUT — kept for comparison / backward compat
# ══════════════════════════════════════════════════════════════════════════════

def tanh_label_contention_dual_input(response_times_p90, response_times_p50,
                                     p50_based, p50_std,
                                     baseline_mean, baseline_median, baseline_std,
                                     baseline_p50, baseline_p90, baseline_p95, baseline_p99,
                                     failure_value=None, k=1.0, smoothing_window=10,
                                     p50_sensitivity=1.0, p50_threshold=0.00,
                                     burst_window=25, **kwargs):
    """
    Original dual-input contention scoring with burst-aware smoothing.
    Kept for backward compatibility and comparison plots.
    """
    response_times_p90 = np.array(response_times_p90, dtype=float)
    response_times_p50 = np.array(response_times_p50, dtype=float)

    assert len(response_times_p90) == len(response_times_p50), \
        "P90 and P50 arrays must have same length"

    labels = np.zeros_like(response_times_p90, dtype=float)

    if failure_value is not None:
        failures = (response_times_p90 == failure_value) | \
                   (response_times_p50 == failure_value)
    else:
        failures = np.isnan(response_times_p90) | np.isnan(response_times_p50)
    labels[failures] = 1.0

    def gaussian_smooth(data, window):
        if window <= 1:
            return data.copy()
        x = np.arange(window)
        sigma = window / 3.0
        kernel = np.exp(-(x**2) / (2 * sigma**2))
        kernel = kernel / kernel.sum()
        smoothed = np.zeros_like(data)
        for i in range(len(data)):
            start = max(0, i - window + 1)
            data_window = data[start:i+1]
            k_slice = kernel[(window - len(data_window)):]
            k_slice = k_slice[::-1]
            smoothed[i] = np.sum(data_window * k_slice)
        return smoothed

    smoothed_p90 = gaussian_smooth(response_times_p90, smoothing_window)
    smoothed_p50 = gaussian_smooth(response_times_p50, smoothing_window)

    raw_scores = np.zeros_like(response_times_p90, dtype=float)

    for i in range(len(response_times_p90)):
        if failures[i]:
            raw_scores[i] = 1.0
            continue
        score_p90 = 0.0
        if smoothed_p90[i] > baseline_p90:
            delta_p90 = (smoothed_p90[i] - baseline_p90) / (baseline_std + 1e-6)
            score_p90 = np.tanh(delta_p90 * k)
        score_p50 = 0.0
        p50_activation = p50_based * (1 + p50_threshold)
        if smoothed_p50[i] > p50_activation:
            delta_p50 = (smoothed_p50[i] - p50_based) / (p50_std + 1e-6)
            score_p50 = np.tanh(delta_p50 * k)
        raw_scores[i] = max(score_p90, p50_sensitivity * score_p50)

    stride = burst_window // 2
    window_maxes, window_positions = [], []
    for i in range(0, len(raw_scores), stride):
        start = max(0, i - burst_window + 1)
        end = min(len(raw_scores), i + 1)
        window_maxes.append(np.max(raw_scores[start:end]))
        window_positions.append(i)
    if window_positions[-1] != len(raw_scores) - 1:
        start = max(0, len(raw_scores) - burst_window)
        window_maxes.append(np.max(raw_scores[start:]))
        window_positions.append(len(raw_scores) - 1)

    window_maxes     = np.array(window_maxes)
    window_positions = np.array(window_positions)

    for i in range(len(raw_scores)):
        if i <= window_positions[0]:
            labels[i] = window_maxes[0]
        elif i >= window_positions[-1]:
            labels[i] = window_maxes[-1]
        else:
            idx_right = np.searchsorted(window_positions, i, side='right')
            idx_left  = idx_right - 1
            pos_left  = window_positions[idx_left]
            pos_right = window_positions[idx_right]
            val_left  = window_maxes[idx_left]
            val_right = window_maxes[idx_right]
            t = (i - pos_left) / (pos_right - pos_left)
            labels[i] = val_left + t * (val_right - val_left)

    labels = np.clip(labels, 0.0, 1.0)
    return labels


# ══════════════════════════════════════════════════════════════════════════════
# COMPARISON METHODS (unchanged)
# ══════════════════════════════════════════════════════════════════════════════

def tanh_label_contention(response_times, baseline_mean, baseline_median, baseline_std,
                          baseline_p50, baseline_p90, baseline_p95, baseline_p99,
                          failure_value=None, k=1.0, smoothing_window=10, **kwargs):
    """Method 1: Percentile-Based Tanh with Gaussian Smoothing"""
    response_times = np.array(response_times, dtype=float)
    labels = np.zeros_like(response_times, dtype=float)
    if failure_value is not None:
        failures = (response_times == failure_value)
    else:
        failures = np.isnan(response_times)
    labels[failures] = 1.0
    transition_start = baseline_p90
    if smoothing_window > 1:
        x = np.arange(smoothing_window)
        sigma = smoothing_window / 3.0
        kernel = np.exp(-(x**2) / (2 * sigma**2))
        kernel = kernel / kernel.sum()
        smoothed_rt = np.zeros_like(response_times)
        for i in range(len(response_times)):
            start = max(0, i - smoothing_window + 1)
            window = response_times[start:i+1]
            k_slice = kernel[(smoothing_window - len(window)):]
            k_slice = k_slice[::-1]
            smoothed_rt[i] = np.sum(window * k_slice)
    else:
        smoothed_rt = response_times.copy()
    for i, t in enumerate(smoothed_rt):
        if failures[i]:
            continue
        if t <= transition_start:
            labels[i] = 0.0
        else:
            normalized_pos = ((t - baseline_p90) / (2*baseline_std + 1e-6))
            labels[i] = np.tanh(normalized_pos * k)
    labels = np.clip(labels, 0.0, 1.0)
    return labels


def slowdown_ratio_contention(response_times, baseline_mean, baseline_median, baseline_std,
                              baseline_p50, baseline_p90, baseline_p99,
                              failure_value=None, smoothing_window=5, **kwargs):
    """Method 2: Slowdown Ratio"""
    response_times = np.array(response_times, dtype=float)
    labels = np.zeros_like(response_times, dtype=float)
    if failure_value is not None:
        failures = (response_times == failure_value)
    else:
        failures = np.isnan(response_times)
    labels[failures] = 1.0
    for i, t in enumerate(response_times):
        if failures[i]:
            continue
        slowdown = t / (baseline_p50 + 1e-6)
        labels[i] = (slowdown - 1.0) / 5.0
        labels[i] = max(0.0, min(1.0, labels[i]))
    return labels


def robust_zscore_contention(response_times, baseline_mean, baseline_median, baseline_std,
                             baseline_p50, baseline_p90, baseline_p99,
                             failure_value=None, threshold=3.5,
                             smoothing_window=5, **kwargs):
    """Method 3: Robust Z-Score (MAD)"""
    response_times = np.array(response_times, dtype=float)
    labels = np.zeros_like(response_times, dtype=float)
    if failure_value is not None:
        failures = (response_times == failure_value)
    else:
        failures = np.isnan(response_times)
    labels[failures] = 1.0
    baseline_mad = 0.6745 * baseline_std
    for i, t in enumerate(response_times):
        if failures[i]:
            continue
        robust_z = 0.6745 * (t - baseline_median) / (baseline_mad + 1e-6)
        labels[i] = max(0.0, (robust_z - 1.0) / threshold)
        labels[i] = min(1.0, labels[i])
    return labels


def binary_contention_classifier(response_times, baseline_mean=None, baseline_median=None,
                                 baseline_std=None, baseline_p50=None,
                                 baseline_p90=None, baseline_p99=None,
                                 failure_value=None, window_size=10,
                                 percentile_threshold=90, **kwargs):
    """Method 4: Binary Contention Classifier"""
    response_times = np.array(response_times, dtype=float)
    labels = np.zeros_like(response_times, dtype=float)
    if failure_value is not None:
        failures = (response_times == failure_value)
    else:
        failures = np.isnan(response_times)
    labels[failures] = 1.0
    for i in range(len(response_times)):
        if failures[i]:
            continue
        start_idx = max(0, i - window_size + 1)
        window = response_times[start_idx:i+1]
        window = window[~np.isnan(window)]
        if len(window) < 3:
            labels[i] = 0.0
            continue
        threshold = np.percentile(window, percentile_threshold)
        current = response_times[i]
        labels[i] = 1.0 if current > threshold * 1.1 else 0.0
    return labels


def adaptive_rolling_percentile(response_times, baseline_mean=None, baseline_median=None,
                                baseline_std=None, baseline_p50=None,
                                baseline_p90=None, baseline_p99=None,
                                failure_value=None, window_size=100,
                                smoothing_window=5, **kwargs):
    """Method 5: Adaptive Rolling Percentile"""
    response_times = np.array(response_times, dtype=float)
    labels = np.zeros_like(response_times, dtype=float)
    if failure_value is not None:
        failures = (response_times == failure_value)
    else:
        failures = np.isnan(response_times)
    labels[failures] = 1.0
    for i in range(len(response_times)):
        if failures[i]:
            continue
        start_idx = max(0, i - window_size + 1)
        window = response_times[start_idx:i+1]
        window = window[~np.isnan(window)]
        if len(window) < 10:
            labels[i] = 0.0
            continue
        p50_rolling = np.percentile(window, 50)
        p90_rolling = np.percentile(window, 90)
        p99_rolling = np.percentile(window, 99)
        current = response_times[i]
        if current <= p90_rolling:
            labels[i] = 0.0
        elif current <= p99_rolling:
            labels[i] = 0.8 * (current - p90_rolling) / (p99_rolling - p90_rolling + 1e-6)
        else:
            labels[i] = 0.8 + 0.2 * min(1.0, (current - p99_rolling) / (p99_rolling - p50_rolling + 1e-6))
    return labels


def slo_violation_score(response_times, baseline_mean=None, baseline_median=None,
                        baseline_std=None, baseline_p50=None,
                        baseline_p90=None, baseline_p99=None,
                        failure_value=None, window_size=100,
                        smoothing_window=5, **kwargs):
    """Method 6: SLO Burn Rate Score"""
    response_times = np.array(response_times, dtype=float)
    labels = np.zeros_like(response_times, dtype=float)
    if failure_value is not None:
        failures = (response_times == failure_value)
    else:
        failures = np.isnan(response_times)
    labels[failures] = 1.0
    for i in range(len(response_times)):
        if failures[i]:
            continue
        start_idx = max(0, i - window_size + 1)
        window = response_times[start_idx:i+1]
        window = window[~np.isnan(window)]
        if len(window) < 10:
            labels[i] = 0.0
            continue
        slo_threshold = baseline_p90
        error_rate    = np.mean(window > slo_threshold)
        burn_rate     = error_rate / 0.01
        labels[i]     = np.clip(burn_rate / 14.0, 0.0, 1.0)
    return labels


def detect_service_from_path(file_path: str) -> str:
    """Detect which service a file belongs to based on its path."""
    path = Path(file_path)
    path_str = str(path)
    if '/search/' in path_str.replace('\\', '/'):
        return 'search'
    elif '/profile/' in path_str.replace('\\', '/'):
        return 'profile'
    else:
        raise ValueError(f"Cannot detect service from path: {file_path}")


# ══════════════════════════════════════════════════════════════════════════════
# OUTPUT FILENAME HELPER
# ══════════════════════════════════════════════════════════════════════════════

def _make_output_path(input_path: Path, output_filepath: Optional[str]) -> Path:
    if output_filepath is not None:
        return Path(output_filepath)
    stem = input_path.stem
    for suffix in ('_filtered_labeled', '_filtered', '_labeled'):
        if stem.endswith(suffix):
            stem = stem[: -len(suffix)]
            break
    return input_path.parent / f"{stem}_ready{input_path.suffix}"


# ══════════════════════════════════════════════════════════════════════════════
# add_labels_to_json
#
# Frequency normalisation
# -----------------------
#   Uses sample["freq"]["actual_freq_mhz"] directly.
#   freq_hz = actual_freq_mhz * 1e6   (no derivation from cycles).
#   Falls back gracefully where freq is unavailable.
#   Baseline scalars are normalised with a fixed baseline_freq_mhz (from the
#   baseline stats file's freq_stats block) so the reference point is stable
#   across per-run frequency fluctuations.
#
# Extrinsic percentage
# ---------------------
#   Uses curve.csv (clean load↔latency sweep) matched to each sample's own
#   arrival rate λ (nearest-neighbour lookup) to compute the load-aware
#   deviation %ext_90 / %ext_50. Disabled (null) when curve_csv is not
#   supplied or the file is missing.
#
# Writes per sample:
#   p90_contention_score — tail / bursty severity  [0, 1]
#   p50_contention_score — mean / sustained severity [0, 1]
#   contention_score     — backward-compat alias = p90_contention_score
#   pct_ext_90            — extrinsic percentage, tail   [0, 100] or null
#   pct_ext_50            — extrinsic percentage, median [0, 100] or null
#
# Output filename: *_ready.json
# ══════════════════════════════════════════════════════════════════════════════

def add_labels_to_json(input_filepath: str, output_filepath: str = None,
                       baseline_stats: Dict = None,
                       baseline_stats_p50: Dict = None,
                       baseline_freq_mhz: float = 0.0,
                       curve_csv: Optional[str] = None,
                       k: float = 1.0):
    """Add contention_score + extrinsic percentage labels to JSON file."""
    input_path = Path(input_filepath)
    if not input_path.exists():
        raise FileNotFoundError(f"Input file not found: {input_filepath}")

    output_path = _make_output_path(input_path, output_filepath)

    # ── Unpack baseline stats ─────────────────────────────────────────────────
    baseline_median = baseline_stats['median']
    baseline_mean   = baseline_stats['mean']
    baseline_std    = baseline_stats['std']
    baseline_p50    = baseline_stats['q50']
    baseline_p90    = baseline_stats['q90']
    baseline_p95    = baseline_stats['q95']
    baseline_p99    = baseline_stats['q99']

    _p50_stats = baseline_stats_p50 if baseline_stats_p50 is not None else baseline_stats
    p50_based  = _p50_stats.get('q50', baseline_p50)
    p50_std    = _p50_stats.get('std', baseline_std)

    # ── Normalise baseline scalars onto the same (ms*Hz) scale as the
    #    per-sample signal, using the fixed baseline frequency. ────────────────
    baseline_p90_n = _normalize_scalar(baseline_p90, baseline_freq_mhz)
    baseline_std_n = _normalize_scalar(baseline_std, baseline_freq_mhz)
    p50_based_n    = _normalize_scalar(p50_based,    baseline_freq_mhz)
    p50_std_n      = _normalize_scalar(p50_std,      baseline_freq_mhz)

    print(f"\n  Processing: {input_path.name}")

    with open(input_path, 'r') as f:
        data = json.load(f)

    if isinstance(data, dict) and 'samples' in data:
        samples, is_wrapped = data['samples'], True
    elif isinstance(data, list):
        samples, is_wrapped = data, False
    else:
        raise ValueError("Unexpected JSON format")

    # ── Extract latencies ─────────────────────────────────────────────────────
    response_times_p90 = extract_response_times(samples, 'p90_ns')
    response_times_p50 = extract_response_times(samples, 'p50_ns')

    # ── Extract actual CPU frequency (MHz) from freq block ────────────────────
    actual_freq_mhz = extract_actual_freq_mhz(samples)
    n_valid_freq = int(np.sum(actual_freq_mhz > 0))
    print(f"    freq.actual_freq_mhz available for {n_valid_freq}/{len(samples)} samples")

    # ── Extrinsic-percentage reference curve (optional) ────────────────────────
    d90_vals = d50_vals = None
    if curve_csv:
        curve_path = Path(curve_csv)
        if curve_path.exists():
            curve = load_curve_data(str(curve_path))
            arrival_rate = extract_arrival_rate(samples)
            n_valid_rate = int(np.sum(np.isfinite(arrival_rate)))
            print(f"    arrival rate (λ) available for {n_valid_rate}/{len(samples)} samples")
            d90_vals, d50_vals = nearest_curve_values(arrival_rate, curve)
        else:
            print(f"    ⚠ curve.csv not found ({curve_csv}) — extrinsic % disabled")

    # ── Gordion dual scoring — score and extrinsic % independent ──────────────
    p90_labels, p50_labels, pct_ext_90, pct_ext_50 = gordion_contention(
        response_times_p90, response_times_p50,
        p50_based              = p50_based_n,
        p50_std                = p50_std_n,
        baseline_mean          = baseline_mean,
        baseline_median        = baseline_median,
        baseline_std           = baseline_std_n,
        baseline_p50           = baseline_p50,
        baseline_p90           = baseline_p90_n,
        baseline_p95           = baseline_p95,
        baseline_p99           = baseline_p99,
        k                      = k,
        freq_mhz               = actual_freq_mhz,
        d90_curve_vals         = d90_vals,
        d50_curve_vals         = d50_vals,
    )

    # ── Write fields ──────────────────────────────────────────────────────────
    for i, sample in enumerate(samples):
        sample['p90_contention_score'] = round(float(p90_labels[i]), 6)
        sample['p50_contention_score'] = round(float(p50_labels[i]), 6)
        sample['contention_score']     = sample['p90_contention_score']  # backward compat
        sample['pct_ext_90'] = None if np.isnan(pct_ext_90[i]) else round(float(pct_ext_90[i]), 4)
        sample['pct_ext_50'] = None if np.isnan(pct_ext_50[i]) else round(float(pct_ext_50[i]), 4)

    with open(output_path, 'w') as f:
        if is_wrapped:
            data['samples'] = samples
            json.dump(data, f, indent=2)
        else:
            json.dump(samples, f, indent=2)

    n_ext90 = int(np.sum(~np.isnan(pct_ext_90)))
    n_ext50 = int(np.sum(~np.isnan(pct_ext_50)))
    print(f"    ✓ Labeled {len(samples)} samples → {output_path.name}")
    print(f"      extrinsic %: p90 available for {n_ext90}/{len(samples)}, "
          f"p50 available for {n_ext50}/{len(samples)}")

    return str(output_path)


# ══════════════════════════════════════════════════════════════════════════════
# BATCH FUNCTIONS
# ══════════════════════════════════════════════════════════════════════════════

def batch_label_from_list(valid_files_list: str, baseline_stats_file: str,
                          baseline_stats_file_50: str = None,
                          curve_csv_file: Optional[str] = None,
                          k: float = 1.0):
    """
    Label all files from the valid files list.

    Loads baseline stats using the unified loader which handles both the new
    nested format {"latency_p90": ..., "latency_p50": ..., "freq_stats": ...}
    and the legacy flat format {"mean": ..., "std": ..., "q90": ...}.
    """
    baseline_stats_p90, baseline_stats_p50_from_file, baseline_freq_mhz = \
        load_baseline_stats(baseline_stats_file)

    baseline_stats_p50 = baseline_stats_p50_from_file
    if baseline_stats_p50 is None and baseline_stats_file_50 is not None:
        baseline_stats_p50, _, _ = load_baseline_stats(baseline_stats_file_50)

    if curve_csv_file:
        print(f"Extrinsic-percentage curve ENABLED — {curve_csv_file}")
        print(f"  (pct_ext_90/pct_ext_50 computed from load-aware deviation)")
    else:
        print("⚠ No curve.csv supplied — pct_ext_90/pct_ext_50 will be null for all samples")
        print("  (contention_score still computed from latency)")

    list_path = Path(valid_files_list)
    if not list_path.exists():
        raise FileNotFoundError(f"Valid files list not found: {valid_files_list}")

    print(f"\nReading valid files from: {valid_files_list}")
    with open(list_path, 'r') as f:
        valid_files = [line.strip() for line in f if line.strip()]

    print(f"Found {len(valid_files)} files to label")

    if len(valid_files) == 0:
        print("\n⚠ No files in the list!")
        return []

    print(f"\n{'='*70}")
    print(f"BATCH LABELING {len(valid_files)} FILES")
    print(f"{'='*70}")
    print(f"k (sensitivity): {k}")

    output_files       = []
    successful, failed = 0, 0

    for i, file_path in enumerate(valid_files):
        try:
            output_file = add_labels_to_json(
                input_filepath     = file_path,
                baseline_stats     = baseline_stats_p90,
                baseline_stats_p50 = baseline_stats_p50,
                baseline_freq_mhz  = baseline_freq_mhz,
                curve_csv          = curve_csv_file,
                k                  = k
            )
            output_files.append(output_file)
            successful += 1
            if (i + 1) % 10 == 0:
                print(f"\n  Progress: {i+1}/{len(valid_files)} files processed")
        except Exception as e:
            print(f"\n  ✗ Error: {Path(file_path).name} - {e}")
            failed += 1

    print(f"\n{'='*70}")
    print("BATCH LABELING COMPLETE!")
    print(f"{'='*70}")
    print(f"Successfully labeled: {successful}/{len(valid_files)} files")
    if failed > 0:
        print(f"Failed: {failed} files")

    return output_files


def batch_label_multi_service(base_data_path: str,
                              services: List[str] = ['search', 'profile'],
                              k: float = 1.0) -> Dict[str, List[str]]:
    """Label all files for multiple services using appropriate baseline stats."""
    base_path = Path(base_data_path)
    labeled_files_by_service = {}

    print("="*70)
    print("MULTI-SERVICE BATCH LABELING")
    print("="*70)
    print(f"Services: {', '.join(services)}")
    print(f"k (sensitivity): {k}")
    print()

    for service in services:
        print(f"\n{'='*70}")
        print(f"PROCESSING SERVICE: {service.upper()}")
        print(f"{'='*70}")

        valid_files_list       = base_path / f"valid_filtered_files_{service}.txt"
        baseline_stats_file    = base_path / f"baseline_stats_{service}.json"
        baseline_stats_file_50 = base_path / f"baseline_stats_{service}_p50.json"
        curve_csv_file          = base_path / f"curve_{service}.csv"

        if not valid_files_list.exists():
            print(f"⚠ Valid files list not found: {valid_files_list}")
            print(f"  Skipping {service}")
            continue

        if not baseline_stats_file.exists():
            print(f"⚠ Baseline stats not found: {baseline_stats_file}")
            print(f"  Skipping {service}")
            continue

        p50_file   = str(baseline_stats_file_50) \
            if baseline_stats_file_50.exists() else None
        curve_file = str(curve_csv_file) \
            if curve_csv_file.exists() else None

        try:
            labeled_files = batch_label_from_list(
                valid_files_list       = str(valid_files_list),
                baseline_stats_file    = str(baseline_stats_file),
                baseline_stats_file_50 = p50_file,
                curve_csv_file         = curve_file,
                k                      = k
            )
            labeled_files_by_service[service] = labeled_files
        except Exception as e:
            print(f"\n✗ Error processing {service}: {e}")
            import traceback
            traceback.print_exc()

    print(f"\n{'='*70}")
    print("MULTI-SERVICE LABELING SUMMARY")
    print(f"{'='*70}")
    for service in services:
        if service in labeled_files_by_service:
            count = len(labeled_files_by_service[service])
            print(f"[{service.upper()}]: {count} files labeled")
        else:
            print(f"[{service.upper()}]: Not processed")

    return labeled_files_by_service


def merge_labeled_files(base_data_path: str,
                        services: List[str] = ['search', 'profile'],
                        output_file: str = "valid_filtered_files.txt") -> List[str]:
    """Merge valid files lists from multiple services into a single list."""
    base_path = Path(base_data_path)
    all_files = []

    print(f"\n{'='*70}")
    print("MERGING FILES FROM ALL SERVICES")
    print(f"{'='*70}")

    for service in services:
        service_file = base_path / f"valid_filtered_files_{service}.txt"
        if not service_file.exists():
            print(f"⚠ File not found for {service}: {service_file}")
            continue
        with open(service_file, 'r') as f:
            lines = [line.strip() for line in f if line.strip()]
        print(f"[{service.upper()}]: {len(lines)} files")
        all_files.extend(lines)

    output_path = base_path / output_file
    with open(output_path, 'w') as f:
        for file_path in all_files:
            f.write(f"{file_path}\n")

    print(f"\n{'='*70}")
    print("MERGE COMPLETE")
    print(f"{'='*70}")
    print(f"Total files: {len(all_files)}")
    print(f"Saved to: {output_path}")

    return all_files


# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    print("="*70)
    print("MULTI-SERVICE LABELING AND MERGING")
    print("="*70)

    base_data_path = r"..\Data"
    services       = ['search', 'profile']
    k_value        = 1.0

    print(f"\nConfiguration:")
    print(f"  Base data path: {base_data_path}")
    print(f"  Services: {', '.join(services)}")
    print(f"  k (sensitivity): {k_value}")
    print(f"\n  Primary baseline file (per service, supports nested & flat formats):")
    for svc in services:
        print(f"    {base_data_path}/baseline_stats_{svc}.json")
    print(f"\n  Optional legacy supplement (used only when primary is flat format):")
    for svc in services:
        print(f"    {base_data_path}/baseline_stats_{svc}_p50.json")
    print(f"\n  Optional extrinsic-percentage curve (clean load↔latency sweep):")
    for svc in services:
        print(f"    {base_data_path}/curve_{svc}.csv")
    print(f"\n  Frequency normalisation:")
    print(f"    Uses sample['freq']['actual_freq_mhz'] directly.")
    print(f"    freq_hz = actual_freq_mhz * 1e6  (no derivation from cycles).")
    print(f"    Falls back to raw ms latency where freq is unavailable.")
    print(f"    Baseline scalars normalised via the baseline file's freq_stats mean.")
    print(f"\n  Contention score and extrinsic percentage: computed together but independently")

    try:
        labeled_files_by_service = batch_label_multi_service(
            base_data_path = base_data_path,
            services       = services,
            k              = k_value
        )

        merged_files = merge_labeled_files(
            base_data_path = base_data_path,
            services       = services,
            output_file    = "valid_filtered_files.txt"
        )

        if merged_files:
            print(f"\n{'='*70}")
            print("SUCCESS!")
            print(f"{'='*70}")
            print(f"\nEach sample now contains:")
            print(f"  contention_score      (p90-based latency tanh, backward compat)")
            print(f"  p90_contention_score  (tail/bursty contention severity — latency only)")
            print(f"  p50_contention_score  (mean/sustained contention severity — latency only)")
            print(f"  pct_ext_90            (extrinsic percentage, tail   — vs load curve, [0,100] or null)")
            print(f"  pct_ext_50            (extrinsic percentage, median — vs load curve, [0,100] or null)")
            print(f"\n  Score and extrinsic % are independent: score uses a fixed baseline tanh,")
            print(f"  extrinsic % uses the load-aware curve.csv reference. Neither gates the other.")
            print(f"\n  Frequency normalisation: actual_freq_mhz * 1e6 Hz per sample.")
            print(f"\nOutput files named: *_ready.json")
            print(f"Merged file list: {base_data_path}/valid_filtered_files.txt")
            print("\nNext steps:")
            print("  - Use valid_filtered_files.txt for LSTM training")
            print("  - The model will be trained on data from all services")

    except FileNotFoundError as e:
        print(f"\n{'='*70}")
        print("ERROR!")
        print(f"{'='*70}")
        print(f"\n{e}")
        print("\nPlease ensure:")
        for service in services:
            print(f"  - Valid files list exists: {base_data_path}/valid_filtered_files_{service}.txt")
            print(f"  - Baseline stats exist:    {base_data_path}/baseline_stats_{service}.json")
            print(f"    (nested format preferred; flat/legacy also supported)")
        print("\nRun the filtering script first to generate these files.")

    except Exception as e:
        print(f"\nUnexpected error: {e}")
        import traceback
        traceback.print_exc()