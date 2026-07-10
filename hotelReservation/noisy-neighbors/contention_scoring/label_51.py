"""
label_func_comp2.py
=====================
Gordion-only contention scoring visualisation.

Layout (per run file):
  Row 0 – Latency p90   (solid dark)          ← own y-scale
  Row 1 – Latency p50   (dashed grey)         ← own y-scale
  Row 2 – Gordion contention score (p90 solid, p50 dashed)
  Row 3 – CPI (cycles per instruction) vs time
  Row 4 – Congestion Intensity (p99 / p50, RAW latencies) vs time
  Row 5 – Extrinsic Percentile  (p90 solid, p50 dashed)   ← NEW

p90 and p50 latencies are plotted in separate sub-panels so their
independent scales are both clearly visible.

Each quantile also has its own k value that controls tanh sensitivity:
  k_p90  –  sensitivity for the tail (p90) score
  k_p50  –  sensitivity for the mean (p50) score

NOTE: Scoring uses normalised latencies (ms * Hz), where the frequency is
      the ACTUAL measured CPU frequency read directly from each sample
      (sample["freq"]["actual_freq_mhz"]), not a value derived from cycles.
      norm_latency   = latency_ms * freq_hz,   freq_hz = actual_freq_mhz * 1e6.
      Signal latencies are normalised with each sample's own actual_freq_mhz.
      Baseline stats are normalised with a fixed baseline frequency (MHz),
      producing a stable constant reference that is independent of
      per-run frequency fluctuations.

NOTE: The Congestion Intensity panel (p99 / p50) is computed from RAW
      (un-normalised, i.e. NOT frequency-scaled) latencies in milliseconds.
      It is a plain ratio of the tail to the median and is deliberately
      kept separate from the frequency-normalised latencies used for
      plotting/scoring elsewhere in this script.

NOTE (NEW): Extrinsic Percentile (%ext_90, %ext_50).
      This measures how far the *smoothed, frequency-normalised* latency at
      sample i deviates from the value predicted by a clean load↔latency
      curve (curve.csv) evaluated at that sample's own arrival rate λ[i]:

          %ext_90[i] = (T90_smooth[i] - D90[λ[i]]) / T90_smooth[i]
          %ext_50[i] = (T50_smooth[i] - D50[λ[i]]) / T50_smooth[i]

      curve.csv contains per-load service latencies (svc_p50_us,
      svc_p99_us) and the CPU frequency (freq_mhz) recorded during that
      clean (uncontended) sweep. Since curve.csv only samples a discrete
      set of arrival rates (it does not cover every possible λ), D90(λ) /
      D50(λ) are built by finding the curve row whose target_rps is
      CLOSEST to each sample's λ[i] (nearest-neighbour lookup, not
      interpolation) and using THAT row's own freq_mhz — together with its
      svc_p99_us / svc_p50_us — to build the normalised reference:

          norm = latency_ms * freq_hz = (latency_us / 1000) * (freq_mhz * 1e6)
               = latency_us * freq_mhz * 1000

      D90 uses the matched row's svc_p99_us (tail reference) and D50 uses
      its svc_p50_us (median reference), both normalised with that same
      row's freq_mhz — so the frequency used to normalise the curve value
      always corresponds to the arrival rate actually matched, not a
      globally interpolated frequency.

      Unlike the Gordion tanh score (which compares against a single fixed
      baseline), the extrinsic percentile compares against the *load-aware*
      expected latency at the current arrival rate — i.e. it isolates the
      portion of the latency increase that is NOT explained by the offered
      load itself ("extrinsic" contention, e.g. from a co-located noisy
      neighbour), as opposed to ordinary queueing/service-time effects that
      already show up in the clean curve at that same λ.

      Since %ext is a percentage, the final value is clipped to the
      [0, 100] range (values below 0, i.e. observed latency lower than the
      load-aware expectation, are clamped to 0; values above 100 are
      clamped to 100).

NOTE (FIX): Arrival-rate extraction.
      Real run samples do NOT carry a top-level 'target_rps' / 'rps' /
      'arrival_rate' / 'load_rps' field, nor a nested 'load' block. The
      actual per-sample offered-load signal lives inside:

          sample['timing_window']['arrival_rps_1s']   (preferred — ~instantaneous)
          sample['timing_window']['arrival_rps_3s']   (fallback — smoother)

      extract_arrival_rate() now checks these locations (in addition to the
      original top-level / 'load' block candidates, kept for backward
      compatibility with older/synthetic files), so the extrinsic-percentile
      feature actually receives a valid λ[i] instead of an all-NaN array.
"""

import json
import time
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from pathlib import Path
from typing import Dict, List, Optional, Tuple


# ============================================================================
# UTILITIES
# ============================================================================

def extract_response_times(samples: List[Dict], perc: str = 'p90_ns') -> np.ndarray:
    times = []
    for s in samples:
        ns = s.get('timing_window', {}).get('processing_time', {}).get(perc, 0)
        times.append(ns / 1_000_000 if ns > 0 else 0.0)
    return np.array(times)
    #output is in seconds


def extract_actual_freq_mhz(samples: List[Dict]) -> np.ndarray:
    """
    Extract actual CPU frequency (MHz) from sample["freq"]["actual_freq_mhz"].
    Returns 0.0 for samples where freq.ok is False or the field is absent.
    """
    freqs = []
    for s in samples:
        freq_block = s.get('freq', {})
        if freq_block.get('ok', False):
            freqs.append(float(freq_block.get('actual_freq_mhz', 0.0)))
        else:
            freqs.append(0.0)
    return np.array(freqs, dtype=float)


def extract_arrival_rate(
        samples: List[Dict],
        field_candidates: Tuple[str, ...] = ('target_rps', 'rps', 'arrival_rate', 'load_rps'),
        timing_window_candidates: Tuple[str, ...] = ('arrival_rps_1s', 'arrival_rps_3s'),
) -> np.ndarray:
    """
    Extract the per-sample offered arrival rate λ (requests/sec), used to
    look up the matching point on the clean load↔latency curve (curve.csv)
    for the extrinsic percentile calculation.

    Lookup order (first match wins):
      1. Top level of the sample dict, using `field_candidates`
         (e.g. sample['target_rps']). Kept for backward compatibility with
         synthetic / older schemas.
      2. A nested 'load' block, using `field_candidates`
         (sample['load'][<candidate>]). Also legacy support.
      3. sample['timing_window'][<candidate>], using `timing_window_candidates`
         — this is where REAL run files carry the signal, specifically
         'arrival_rps_1s' (preferred, ~instantaneous offered load) and
         'arrival_rps_3s' (fallback, smoother/more stable estimate).

    Returns NaN for samples where no matching field is found anywhere.
    """
    rates = []
    for s in samples:
        val = None

        # 1) top-level candidates
        for key in field_candidates:
            if key in s:
                val = s[key]
                break

        # 2) nested 'load' block (legacy)
        if val is None:
            load_block = s.get('load', {})
            if isinstance(load_block, dict):
                for key in field_candidates:
                    if key in load_block:
                        val = load_block[key]
                        break

        # 3) nested 'timing_window' block (real schema — arrival_rps_1s / _3s)
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


def normalize_latency(rt: np.ndarray, freq_mhz: np.ndarray) -> np.ndarray:
    """
    Normalise latency by the ACTUAL measured CPU frequency for each sample.

    freq_hz      = actual_freq_mhz * 1e6
    norm_latency = latency_ms * freq_hz          (units: ms * Hz = ms·cycles/s)

    Samples with zero / unavailable frequency are left unchanged (no division).
    """
    freq_hz   = freq_mhz * 1e6
    safe_freq = np.where(freq_hz > 0, freq_hz, np.nan)
    normed    = rt / 1000 * safe_freq
    # Where freq == 0 fall back to the raw value so the array stays finite
    return np.where(np.isfinite(normed), normed, rt)


def normalize_scalar(value: float, baseline_freq_mhz: float) -> float:
    """
    Normalise a scalar baseline stat using a fixed baseline frequency (MHz).

    Uses a stable baseline frequency rather than per-sample run frequency,
    so the reference point is unaffected by frequency fluctuations under
    contention.

        freq_hz    = baseline_freq_mhz * 1e6
        norm_value = value * freq_hz          (ms * Hz = ms·cycles/s)

    Returns the raw value unchanged if baseline_freq_mhz <= 0.
    """
    if baseline_freq_mhz <= 0:
        return value
    freq_hz = baseline_freq_mhz * 1e6
    return value / 1000 * freq_hz


def extract_congestion_intensity(rt_p99: np.ndarray, rt_p50: np.ndarray) -> np.ndarray:
    """
    Congestion Intensity = p99 / p50, computed from RAW (un-normalised,
    non frequency-scaled) latencies in milliseconds.

    This is intentionally NOT computed on the frequency-normalised
    latencies used elsewhere in this script (rt*_norm). It stays a plain
    ratio of raw tail latency to raw median latency.

    Returns NaN where p50 is zero / unavailable so the panel can skip
    those points instead of producing inf.
    """
    safe_p50 = np.where(rt_p50 > 0, rt_p50, np.nan)
    intensity = rt_p99 / safe_p50
    return intensity


def extract_cpi(samples: List[Dict]) -> np.ndarray:
    """
    Extract per-sample CPI (cycles per instruction) from perf_deltas.

    CPI = perf_deltas.cycles / perf_deltas.instructions

    Returns NaN for samples where either field is missing, zero, or
    non-numeric, so the CPI panel can simply skip those points.
    """
    cpis = []
    for s in samples:
        pd_ = s.get('perf_deltas', {})
        cycles       = pd_.get('cycles', 0.0)
        instructions = pd_.get('instructions', 0.0)
        try:
            cycles       = float(cycles)
            instructions = float(instructions)
        except (TypeError, ValueError):
            cpis.append(np.nan); continue
        if instructions > 0:
            cpis.append(cycles / instructions)
        else:
            cpis.append(np.nan)
    return np.array(cpis, dtype=float)


def load_baseline_stats(path: str) -> Tuple[Dict, Optional[Dict], float]:
    """
    Load baseline stats JSON.

    Returns
    -------
    s90 : Dict
        Latency stats for p90.
    s50 : Optional[Dict]
        Latency stats for p50 (None for legacy flat files).
    baseline_freq_mhz : float
        Mean actual CPU frequency (MHz) used as the stable reference
        frequency for normalising baseline latency scalars.
        0.0 if the field is absent (falls back to un-normalised values).
    """
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"Baseline file not found: {p}")
    with open(p) as f:
        raw = json.load(f)

    if 'latency_p90' in raw and 'latency_p50' in raw:
        s90 = dict(raw['latency_p90'])
        s50 = dict(raw['latency_p50'])
        for s in (s90, s50):
            s.setdefault('q50', s.get('median', s['mean']))

        # Baseline reference frequency — mean of actual_freq_mhz from the
        # baseline collection run, nested at freq_stats.actual_freq_mhz.mean:
        #   "freq_stats": {"actual_freq_mhz": {"mean": ..., ...}, ...}
        # Falls back to a flat freq_stats.mean (older schema) if present,
        # else 0.0 (disables baseline normalisation).
        freq_stats = raw.get('freq_stats', {})
        baseline_freq_mhz = 0.0
        if isinstance(freq_stats, dict):
            actual_freq_block = freq_stats.get('actual_freq_mhz', {})
            if isinstance(actual_freq_block, dict) and 'mean' in actual_freq_block:
                baseline_freq_mhz = float(actual_freq_block['mean'])
            elif 'mean' in freq_stats:
                baseline_freq_mhz = float(freq_stats['mean'])

        print(f"  p90 baseline — mean={s90['mean']:.4f} ms, q90={s90['q90']:.4f} ms")
        print(f"  p50 baseline — mean={s50['mean']:.4f} ms, q50={s50['q50']:.4f} ms")
        print(f"  Baseline actual_freq_mhz mean — {baseline_freq_mhz:.1f}"
              + (" ⚠ (missing — baseline normalisation disabled)" if baseline_freq_mhz == 0 else ""))
        return s90, s50, baseline_freq_mhz

    raw.setdefault('q50', raw.get('median', raw['mean']))
    print("  Flat (legacy) baseline stats loaded")
    return raw, None, 0.0


def load_curve_data(path: str) -> Dict[str, np.ndarray]:
    """
    Load the clean load↔latency curve (curve.csv).

    Expected curve.csv columns:
        target_rps   – offered load / arrival rate (requests/sec)
        svc_p50_us   – service p50 latency at that load (µs, raw)
        svc_p90_us   – service p99 latency at that load (µs, raw)
        freq_mhz     – CPU frequency recorded at that load (MHz)

    Unlike an earlier version of this loader, the latency columns are kept
    RAW (not pre-normalised) here. curve.csv only samples a discrete set of
    arrival rates, so at lookup time (see `nearest_curve_values`) each
    sample's arrival rate is matched to the CLOSEST row in this curve, and
    that row's own freq_mhz is used to normalise its svc_p50_us /
    svc_p90_us — this guarantees the frequency used always corresponds to
    the specific curve row that was actually matched.

    Returns
    -------
    Dict with sorted 'rps', 'svc_p50_us', 'svc_p99_us', 'freq_mhz' arrays
    (all sorted by rps, ready for nearest-neighbour lookup).
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
    return {'rps': rps, 'svc_p50_us': svc_p50, 'svc_p90_us': svc_p90, 'freq_mhz': freq_mhz}


def nearest_curve_values(arrival_rate: np.ndarray, curve: Dict[str, np.ndarray]) -> Tuple[np.ndarray, np.ndarray]:
    """
    For each sample's arrival rate λ, find the curve.csv row whose
    target_rps is CLOSEST to λ (nearest-neighbour match — curve.csv does
    not contain every possible arrival rate, so exact matches usually
    don't exist and interpolation would blend frequencies from two
    different, unrelated operating points).

    The matched row's OWN freq_mhz is then used — together with its
    svc_p99_us / svc_p50_us — to build the frequency-normalised D90[λ] /
    D50[λ] reference used in the extrinsic percentile calculation:

        norm = latency_us * freq_mhz * 1000   (== latency_ms * freq_hz)

    Samples with an unavailable / NaN arrival rate fall back to the curve
    row closest to the median offered load in the curve.

    Returns
    -------
    d90_vals, d50_vals : np.ndarray
        Per-sample, frequency-normalised D90[λ[i]] / D50[λ[i]] values.
    """
    rps      = curve['rps']
    svc_p50  = curve['svc_p50_us']
    svc_p90  = curve['svc_p90_us']
    freq_mhz = curve['freq_mhz']
    n = len(arrival_rate)

    idx = np.zeros(n, dtype=int)
    valid = np.isfinite(arrival_rate)

    if np.any(valid):
        # searchsorted gives the insertion point; the closest row is either
        # that position or the one directly before it.
        pos = np.searchsorted(rps, arrival_rate[valid])
        pos = np.clip(pos, 1, len(rps) - 1)
        left_rps  = rps[pos - 1]
        right_rps = rps[pos]
        go_left = (arrival_rate[valid] - left_rps) <= (right_rps - arrival_rate[valid])
        nearest = np.where(go_left, pos - 1, pos)
        idx[valid] = nearest

    if np.any(~valid):
        # Fall back to the curve row closest to the median offered load.
        fallback_idx = int(np.argmin(np.abs(rps - np.median(rps))))
        idx[~valid] = fallback_idx

    row_freq = freq_mhz[idx]
    d90_vals = svc_p90[idx] * row_freq# * 1000.0
    d50_vals = svc_p50[idx] * row_freq# * 1000.0
    return d90_vals, d50_vals


# ============================================================================
# SMOOTHING HELPER
# ============================================================================

def _gaussian_smooth(data: np.ndarray, window: int) -> np.ndarray:
    if window <= 1:
        return data.copy()
    x      = np.arange(window)
    kernel = np.exp(-(x ** 2) / (2 * (window / 3.0) ** 2))
    kernel /= kernel.sum()
    out = np.zeros_like(data)
    for i in range(len(data)):
        s   = max(0, i - window + 1)
        w   = data[s:i + 1]
        k   = kernel[(window - len(w)):][::-1]
        out[i] = np.dot(w, k)
    return out


# ============================================================================
# GORDION LABELLING
# ============================================================================

def _burst_pool(raw: np.ndarray, burst_window: int) -> np.ndarray:
    n      = len(raw)
    stride = max(1, burst_window // 2)
    wp, wm = [], []
    for i in range(0, n, stride):
        s = max(0, i - burst_window + 1)
        wm.append(np.max(raw[s:min(n, i + 1)]))
        wp.append(i)
    if wp[-1] != n - 1:
        wm.append(np.max(raw[max(0, n - burst_window):]))
        wp.append(n - 1)
    wp, wm = np.array(wp), np.array(wm)
    out = np.zeros(n)
    for i in range(n):
        if i <= wp[0]:           out[i] = wm[0]
        elif i >= wp[-1]:        out[i] = wm[-1]
        else:
            ir = np.searchsorted(wp, i, side='right')
            il = ir - 1
            t  = (i - wp[il]) / (wp[ir] - wp[il])
            out[i] = wm[il] + t * (wm[ir] - wm[il])
    return np.clip(out, 0.0, 1.0)


def gordion_score(
        rt_p90: np.ndarray,
        rt_p50: np.ndarray,
        p50_based: np.ndarray,
        p50_std: np.ndarray,
        baseline_p90: np.ndarray,
        baseline_std: np.ndarray,
        # ── tuneable sensitivity per quantile ──────────────────────────────
        k_p90: float = 0.5,          # tanh sensitivity for p90 (tail) score
        k_p50: float = 2.0,          # tanh sensitivity for p50 (mean) score
        # ──────────────────────────────────────────────────────────────────
        smoothing_window: int = 10,
        burst_window: int = 25,
        p50_sensitivity: float = 1.0,
        p50_threshold: float = 0.0,
        failure_value=None,
        # ── NEW: extrinsic-percentile reference curves ─────────────────────
        d90_curve_vals: Optional[np.ndarray] = None,   # D90[λ[i]], per-sample
        d50_curve_vals: Optional[np.ndarray] = None,   # D50[λ[i]], per-sample
) -> Tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """
    Compute per-sample Gordion contention scores (p90, p50) AND the
    extrinsic percentiles (%ext_90, %ext_50).

    All latency inputs must be in the same normalised space:
        norm_latency = latency_ms * freq_hz   (ms * Hz = ms·cycles/s)

    Signal arrays (rt_p90, rt_p50) are normalised with each sample's own
    actual_freq_mhz via normalize_latency().  Baseline arrays (baseline_p90,
    baseline_std, p50_based, p50_std) are constant arrays produced by
    broadcasting the scalar returned by normalize_scalar() -- which uses a
    fixed baseline frequency -- across all n samples.

    d90_curve_vals / d50_curve_vals are the per-sample D90[λ[i]] / D50[λ[i]]
    values obtained by matching the clean load↔latency curve (curve.csv,
    see load_curve_data / nearest_curve_values) to each sample's own
    arrival rate via nearest-neighbour lookup, normalised using that
    matched row's own freq_mhz. If either is None, the corresponding
    extrinsic-percentile output is returned as all-NaN (feature disabled).

    Parameters
    ----------
    rt_p90 : np.ndarray
        Per-sample normalised p90 response times (ms * Hz).
    rt_p50 : np.ndarray
        Per-sample normalised p50 response times (ms * Hz).
    p50_based : np.ndarray
        Normalised baseline p50 reference, broadcast to n samples (ms * Hz).
    p50_std : np.ndarray
        Normalised baseline p50 std-dev, broadcast to n samples (ms * Hz).
    baseline_p90 : np.ndarray
        Normalised baseline p90 reference, broadcast to n samples (ms * Hz).
    baseline_std : np.ndarray
        Normalised baseline p90 std-dev, broadcast to n samples (ms * Hz).
    k_p90 : float
        Tanh scaling factor for the tail (p90) score.  Larger → steeper rise.
    k_p50 : float
        Tanh scaling factor for the mean (p50) score.  Larger → steeper rise.

    Returns
    -------
    lp90, lp50 : np.ndarray
        Burst-pooled Gordion contention scores (unchanged behaviour).
    pct_ext_90, pct_ext_50 : np.ndarray
        Extrinsic percentile, as a PERCENTAGE clipped to [0, 100]:
        100 * (T_smooth - D[λ]) / T_smooth, computed on the same
        Gaussian-smoothed normalised latency used for scoring, NOT
        burst-pooled (matches the labelling algorithm, which defines %ext
        directly from T̃ with no additional pooling step). Values are
        clamped to 0 (observed latency at/below the load-aware expectation)
        and 100 (observed latency effectively unbounded above expectation).
        NaN is preserved for samples where the value is undefined
        (failures, zero smoothed latency, or missing curve data).
    """

    n     = len(rt_p90)
    fails = (np.isnan(rt_p90) | np.isnan(rt_p50)
             if failure_value is None
             else (rt_p90 == failure_value) | (rt_p50 == failure_value))

    sp90 = _gaussian_smooth(rt_p90, smoothing_window)
    sp50 = _gaussian_smooth(rt_p50, 25)

    raw90 = np.zeros(n)
    raw50 = np.zeros(n)
    for i in range(n):
        if fails[i]:
            raw90[i] = raw50[i] = 1.0; continue
        # ── p90 score: k_p90 controls tanh steepness ──────────────────────
        if sp90[i] > baseline_p90[i]:
            raw90[i] = np.tanh(
                (sp90[i] - baseline_p90[i]) / (baseline_std[i] + 1e-6) * k_p90
            )
        # ── p50 score: k_p50 controls tanh steepness ──────────────────────
        act = p50_based[i] * (1 + p50_threshold)
        #print(p50_based[i])
        if sp50[i] > act:
            raw50[i] = (
                np.tanh((sp50[i] - p50_based[i]) / (p50_std[i] + 1e-6) * k_p50)
                * p50_sensitivity
            )

    lp90 = _burst_pool(raw90, 10)
    lp50 = _burst_pool(raw50, 25)
    lp90[fails] = lp50[fails] = 1.0

    # ── NEW: Extrinsic percentile ───────────────────────────────────────────
    #   %ext_90[i] = (T90_smooth[i] - D90[λ[i]]) / T90_smooth[i]
    #   %ext_50[i] = (T50_smooth[i] - D50[λ[i]]) / T50_smooth[i]
    # Expressed as a percentage in [0, 100].
    pct_ext_90 = np.full(n, np.nan)
    pct_ext_50 = np.full(n, np.nan)

    if d90_curve_vals is not None:
        with np.errstate(divide='ignore', invalid='ignore'):
            pct_ext_90 = np.where(sp90 != 0, (sp90 - d90_curve_vals) / (d90_curve_vals-baseline_p90 )* 10.0, np.nan)
        pct_ext_90[fails] = np.nan
        pct_ext_90 = np.clip(pct_ext_90, 0.0, 100.0)

    if d50_curve_vals is not None:
        with np.errstate(divide='ignore', invalid='ignore'):
            pct_ext_50 = np.where(sp50 != 0, (sp50 - d50_curve_vals) / p50_based * 100.0, np.nan)
        pct_ext_50[fails] = np.nan
        pct_ext_50 = np.clip(pct_ext_50, 0.0, 100.0)

    print(sp50,d50_curve_vals)
    return lp90, lp50, pct_ext_90, pct_ext_50


# ============================================================================
# PLOTTING
# ============================================================================

def plot_gordion(
        input_file: str,
        baseline_stats: Dict,
        baseline_stats_p50: Optional[Dict] = None,
        baseline_freq_mhz: float = 0.0,
        output_dir: Optional[str] = None,
        zoom_window: int = 50,
        sample_interval_ms: int = 100,
        # ── per-quantile k values ────────────────────────────────────────
        k_p90: float = 0.5,
        k_p50: float = 0.2,
        # ── NEW: clean load↔latency curve for extrinsic percentile ────────
        curve_csv: Optional[str] = None,
):
    ip = Path(input_file)
    if not ip.exists():
        raise FileNotFoundError(ip)

    print(f"\n{'='*65}")
    print(f"  {ip.name}")
    print(f"{'='*65}")

    with open(ip) as f:
        raw = json.load(f)
    samples = raw['samples'] if isinstance(raw, dict) and 'samples' in raw else raw

    rt90     = extract_response_times(samples, 'p90_ns')
    rt50     = extract_response_times(samples, 'p50_ns')
    rt99     = extract_response_times(samples, 'p99_ns')
    freq_mhz = extract_actual_freq_mhz(samples)
    cpi      = extract_cpi(samples)
    t        = np.arange(len(rt90)) * (sample_interval_ms / 1000.0)

    n_valid_freq = int(np.sum(freq_mhz > 0))
    print(f"  freq.actual_freq_mhz available for {n_valid_freq}/{len(samples)} samples")
    n_valid_cpi = int(np.sum(~np.isnan(cpi)))
    print(f"  CPI (cycles/instructions) available for {n_valid_cpi}/{len(samples)} samples")

    # ── Normalised latencies — used for both plotting and scoring ──────────
    # Normalisation uses each sample's own ACTUAL measured frequency
    # (sample["freq"]["actual_freq_mhz"]), not a value derived from cycles.
    rt90_norm = normalize_latency(rt90, freq_mhz)
    rt50_norm = normalize_latency(rt50, freq_mhz)

    # ── Congestion Intensity — p99 / p50 on RAW (non frequency-scaled)
    # latencies. Deliberately kept independent of the normalised latencies
    # used for scoring/plotting above.
    congestion_intensity = extract_congestion_intensity(rt99, rt50)
    n_valid_ci = int(np.sum(np.isfinite(congestion_intensity)))
    print(f"  Congestion Intensity (p99/p50, raw) available for {n_valid_ci}/{len(samples)} samples")

    print(f"  Samples: {len(rt90)}  |  Duration: {t[-1]:.1f}s")
    print(f"  p90 range:          [{rt90.min():.2f}, {rt90.max():.2f}] ms")
    print(f"  p50 range:          [{rt50.min():.2f}, {rt50.max():.2f}] ms")
    print(f"  k_p90={k_p90}  k_p50={k_p50}")

    # Baseline scalar stats (raw ms) — normalise using the fixed baseline
    # frequency, then broadcast to constant arrays of length n for scoring
    # and plotting.  This avoids using per-sample run frequency (which
    # fluctuates under contention) to anchor the reference point.
    bs90  = baseline_stats
    bs50  = baseline_stats_p50 if baseline_stats_p50 else baseline_stats
    n     = len(rt90)

    bp90_scalar = normalize_scalar(bs90['q90'],                                    baseline_freq_mhz)
    bstd_scalar = normalize_scalar(bs90['std'],                                    baseline_freq_mhz)
    p50b_scalar = normalize_scalar(bs50.get('q50', bs90.get('q50', bs90['mean'])), baseline_freq_mhz)
    p50s_scalar = normalize_scalar(bs50.get('std', bs90['std']),                   baseline_freq_mhz)

    # Constant arrays broadcast from the single normalised scalar
    bp90_norm = np.full(n, bp90_scalar)
    bstd_norm = np.full(n, bstd_scalar)
    p50b_norm = np.full(n, p50b_scalar)
    p50s_norm = np.full(n, p50s_scalar)

    # ── NEW: extrinsic-percentile reference curve, per sample ──────────────
    # D90[λ[i]] / D50[λ[i]] obtained by matching curve.csv to each sample's
    # own arrival rate via nearest-neighbour lookup, normalised using that
    # matched row's own freq_mhz.
    d90_vals = d50_vals = None
    if curve_csv:
        curve         = load_curve_data(curve_csv)
        arrival_rate  = extract_arrival_rate(samples)
        #print(arrival_rate)
        n_valid_rate  = int(np.sum(np.isfinite(arrival_rate)))
        print(f"  arrival rate (λ) available for {n_valid_rate}/{len(samples)} samples")
        if n_valid_rate > 0:
            print(f"  arrival rate (λ) range — "
                  f"[{np.nanmin(arrival_rate):.1f}, {np.nanmax(arrival_rate):.1f}] rps")
        d90_vals, d50_vals = nearest_curve_values(arrival_rate, curve)
    else:
        print("  No curve.csv supplied — extrinsic percentile disabled")

    # Gordion scores — computed on normalised latencies
    gp90, gp50, pct_ext_90, pct_ext_50 = gordion_score(
        rt90_norm, rt50_norm,
        p50_based=p50b_norm, p50_std=p50s_norm,
        baseline_p90=bp90_norm, baseline_std=bstd_norm,
        k_p90=k_p90,
        k_p50=k_p50,
        d90_curve_vals=d90_vals,
        d50_curve_vals=d50_vals,
    )

    n_valid_ext90 = int(np.sum(np.isfinite(pct_ext_90)))
    n_valid_ext50 = int(np.sum(np.isfinite(pct_ext_50)))
    print(f"  Extrinsic %  p90 available for {n_valid_ext90}/{n} samples, "
          f"p50 available for {n_valid_ext50}/{n} samples")

    peak_idx  = int(np.argmax(rt90))
    peak_time = t[peak_idx]
    print(f"  Peak p90 at t={peak_time:.1f}s  ({rt90[peak_idx]:.2f} ms)")

    # Output dir
    od = Path(output_dir) if output_dir else ip.parent
    od.mkdir(parents=True, exist_ok=True)
    ts   = int(time.time() * 1000) % 100_000
    stem = ip.stem

    saved = []
    for view, (s, e) in [('full',   (0, len(rt90))),
                          ('zoomed', (max(0, peak_idx - zoom_window // 2),
                                      min(len(rt90), peak_idx + zoom_window // 2)))]:
        sl   = slice(s, e)
        tv   = t[sl]
        mk   = 'o' if view == 'zoomed' else None
        mksz = 3  if view == 'zoomed' else 0

        # ── 6-panel figure ─────────────────────────────────────────────────
        fig, axes = plt.subplots(
            6, 1, figsize=(12, 14),
            gridspec_kw={'height_ratios': [2.5, 2.5, 2, 1.8, 2, 2], 'hspace': 0.10},
            sharex=True,
        )
        fig.suptitle(
            f'Gordion Contention Scoring — {view.title()} View\n'
            f'{stem}   (k_p90={k_p90}, k_p50={k_p50})',
            fontsize=11, fontweight='bold', y=1.01,
        )

        # ── Panel 0: p90 Normalised Latency ────────────────────────────────
        ax0 = axes[0]
        ax0.plot(tv, rt90_norm[sl], color='#2C2C2C', lw=1.4, alpha=0.85,
                 marker=mk, markersize=mksz, label='p90 norm latency')
        ax0.plot(tv, bp90_norm[sl], color='#888888', lw=0.9, alpha=0.6,
                 linestyle=':', label='baseline p90 norm')
        ax0.axvline(peak_time, color='#E63946', lw=1.0, ls='--', alpha=0.7,
                    label=f'Peak {rt90[peak_idx]:.1f} ms (raw)')
        ax0.set_ylabel('p90 Norm Latency\n(cycles)', fontsize=9, fontweight='bold')
        ax0.legend(loc='upper right', fontsize=7, framealpha=0.85)
        ax0.set_ylim(bottom=0)
        ax0.grid(True, alpha=0.25, lw=0.4)
        ax0.tick_params(axis='y', labelsize=8)

        # ── Panel 1: p50 Normalised Latency ────────────────────────────────
        ax1 = axes[1]
        ax1.plot(tv, rt50_norm[sl], color='#555555', lw=1.2, alpha=0.80,
                 linestyle='--', marker=mk, markersize=mksz, label='p50 norm latency')
        ax1.plot(tv, p50b_norm[sl], color='#888888', lw=0.9, alpha=0.6,
                 linestyle=':', label='baseline p50 norm')
        ax1.axvline(peak_time, color='#E63946', lw=1.0, ls='--', alpha=0.7)
        ax1.set_ylabel('p50 Norm Latency\n(cycles)', fontsize=9, fontweight='bold')
        ax1.legend(loc='upper right', fontsize=7, framealpha=0.85)
        #ax1.set_ylim(bottom=0, top=1e8)
        ax1.grid(True, alpha=0.25, lw=0.4)
        ax1.tick_params(axis='y', labelsize=8)

        # ── Panel 2: Gordion Score ──────────────────────────────────────────
        ax2 = axes[2]
        ax2.plot(tv, gp90[sl], color='#1D6FA4', lw=1.6, alpha=0.90,
                 marker=mk, markersize=mksz,
                 label=f'p90 score (k={k_p90})')
        ax2.plot(tv, gp50[sl], color='#1D6FA4', lw=1.0, alpha=0.55,
                 linestyle='--', marker=mk, markersize=mksz,
                 label=f'p50 score (k={k_p50})')
        ax2.axvline(peak_time, color='#E63946', lw=1.0, ls='--', alpha=0.7)
        ax2.axhline(0.5, color='#E63946', lw=0.7, ls=':', alpha=0.5,
                    label='Threshold 0.5')
        ax2.set_ylabel('Contention\nScore', fontsize=9, fontweight='bold')
        ax2.set_ylim(-0.05, 1.05)
        ax2.legend(loc='upper right', fontsize=7, framealpha=0.85)
        ax2.grid(True, alpha=0.25, lw=0.4)
        ax2.tick_params(axis='y', labelsize=8)

        # ── Panel 3: CPI (cycles per instruction) vs time ───────────────────
        ax3 = axes[3]
        cpi_sl    = cpi[sl]
        valid_cpi = np.isfinite(cpi_sl)
        if np.any(valid_cpi):
            ax3.plot(tv, cpi_sl, color='#8E5B3A', lw=1.2, alpha=0.85,
                     marker=mk, markersize=mksz, label='CPI (cycles / instr)')
            mean_cpi = np.nanmean(cpi_sl)
            ax3.axhline(mean_cpi, color='#888888', lw=0.8, ls=':', alpha=0.6,
                        label=f'Mean {mean_cpi:.3f}')
            ax3.legend(loc='upper right', fontsize=7, framealpha=0.85)
        else:
            ax3.text(0.5, 0.5, 'CPI unavailable (no perf_deltas)',
                      transform=ax3.transAxes, ha='center', va='center',
                      fontsize=8, color='#888888')
        ax3.axvline(peak_time, color='#E63946', lw=1.0, ls='--', alpha=0.7)
        ax3.set_ylabel('CPI\n(cycles/instr)', fontsize=9, fontweight='bold')
        ax3.set_ylim(bottom=0)
        ax3.grid(True, alpha=0.25, lw=0.4)
        ax3.tick_params(axis='y', labelsize=8)

        # ── Panel 4: Congestion Intensity (p99 / p50, RAW latencies) ────────
        ax4 = axes[4]
        ci_sl    = congestion_intensity[sl]
        valid_ci = np.isfinite(ci_sl)
        if np.any(valid_ci):
            ax4.plot(tv, ci_sl, color='#7A2E8E', lw=1.3, alpha=0.85,
                     marker=mk, markersize=mksz, label='Congestion Intensity (p99/p50, raw)')
            mean_ci = np.nanmean(ci_sl)
            ax4.axhline(mean_ci, color='#888888', lw=0.8, ls=':', alpha=0.6,
                        label=f'Mean {mean_ci:.2f}')
            ax4.legend(loc='upper right', fontsize=7, framealpha=0.85)
        else:
            ax4.text(0.5, 0.5, 'Congestion Intensity unavailable',
                      transform=ax4.transAxes, ha='center', va='center',
                      fontsize=8, color='#888888')
        ax4.axvline(peak_time, color='#E63946', lw=1.0, ls='--', alpha=0.7)
        ax4.set_ylabel('Congestion\nIntensity\n(p99/p50, raw)', fontsize=9, fontweight='bold')
        ax4.set_ylim(bottom=0)
        ax4.grid(True, alpha=0.25, lw=0.4)
        ax4.tick_params(axis='y', labelsize=8)

        # ── Panel 5: Extrinsic Percentile (p90 solid, p50 dashed)  ── NEW ───
        # pct_ext_90 / pct_ext_50 are already percentages clipped to [0, 100]
        # (see gordion_score) — plotted directly, no extra scaling here.
        ax5 = axes[5]
        ext90_sl = pct_ext_90[sl]
        ext50_sl = pct_ext_50[sl]
        valid_ext90 = np.isfinite(ext90_sl)
        valid_ext50 = np.isfinite(ext50_sl)
        if np.any(valid_ext90) or np.any(valid_ext50):
            if np.any(valid_ext90):
                ax5.plot(tv, ext90_sl, color='#2A9D8F', lw=1.6, alpha=0.90,
                         marker=mk, markersize=mksz, label='%ext p90')
            if np.any(valid_ext50):
                ax5.plot(tv, ext50_sl, color='#2A9D8F', lw=1.0, alpha=0.55,
                         linestyle='--', marker=mk, markersize=mksz, label='%ext p50')
            ax5.axhline(0.0, color='#888888', lw=0.8, ls=':', alpha=0.6)
            ax5.legend(loc='upper right', fontsize=7, framealpha=0.85)
        else:
            ax5.text(0.5, 0.5, 'Extrinsic percentile unavailable (no curve.csv / λ)',
                      transform=ax5.transAxes, ha='center', va='center',
                      fontsize=8, color='#888888')
        ax5.axvline(peak_time, color='#E63946', lw=1.0, ls='--', alpha=0.7)
        ax5.set_ylabel('Extrinsic %\n(vs load curve)', fontsize=9, fontweight='bold')
        ax5.set_ylim(-2, 102)
        ax5.grid(True, alpha=0.25, lw=0.4)
        ax5.tick_params(axis='y', labelsize=8)
        ax5.set_xlabel('Time (s)', fontsize=9, fontweight='bold')
        ax5.tick_params(axis='x', labelsize=8)

        plt.tight_layout()
        out = od / f"{view}_{ip.parent.name}_{stem}_{ts}.png"
        fig.savefig(out, dpi=200, bbox_inches='tight')
        plt.close(fig)
        print(f"  ✓ {view} saved → {out.name}")
        saved.append(str(out))

    return saved


# ============================================================================
# SERVICE DETECTION
# ============================================================================

# Known service names — the parent directory of each run file must match one
# of these exactly (case-insensitive) for automatic service detection.
KNOWN_SERVICES = ('search', 'profile')


def detect_service(file_path: str) -> str:
    """
    Infer the service name from the run file path.

    Looks for a path component that matches one of KNOWN_SERVICES
    (case-insensitive), searching from the innermost directory outward.
    Raises ValueError if no match is found.

    Example
    -------
    .../windowed/search/run_data_iter1_filtered_labeled.json  →  'search'
    .../windowed/profile/run_data_iter2_filtered_labeled.json →  'profile'
    """
    parts = Path(file_path).parts
    for part in reversed(parts):
        if part.lower() in KNOWN_SERVICES:
            return part.lower()
    raise ValueError(
        f"Cannot detect service for '{file_path}'. "
        f"Expected one of {KNOWN_SERVICES} as a path component."
    )


# ============================================================================
# BATCH ENTRY POINT
# ============================================================================

def plot_all_files(
        file_list: List[str],
        baseline_stats_files: Dict[str, str],
        output_dir: Optional[str] = None,
        zoom_window: int = 50,
        sample_interval_ms: int = 100,
        # ── per-quantile k values (tune here) ────────────────────────────
        k_p90: float = 0.5,
        k_p50: float = 2.0,
        # ── NEW: per-service clean load↔latency curve (curve.csv) ─────────
        curve_csv_files: Optional[Dict[str, str]] = None,
):
    """
    Batch-plot all files in *file_list*, routing each file to the correct
    baseline (and, if supplied, curve.csv) using its service name detected
    from the path.

    Parameters
    ----------
    baseline_stats_files : Dict[str, str]
        Mapping of service name → baseline JSON path, e.g.::

            {
                'search':  r'..\\Data\\baseline_stats_search.json',
                'profile': r'..\\Data\\baseline_stats_profile.json',
            }

        Each JSON file must contain 'latency_p90' and 'latency_p50'
        (produced by a single baseline collection run). An optional
        'freq_stats' block with a 'mean' field supplies the fixed
        baseline frequency (MHz) used to normalise baseline scalars.

    curve_csv_files : Optional[Dict[str, str]]
        Mapping of service name → curve.csv path, e.g.::

            {
                'search':  r'..\\Data\\curve_search.csv',
                'profile': r'..\\Data\\curve_profile.csv',
            }

        Each CSV must contain target_rps, svc_p50_us, svc_p90_us, freq_mhz
        (see load_curve_data). If a service has no entry here, the
        extrinsic-percentile panel is disabled for its files.

    k_p90 / k_p50
    -------------
    Steepness of the tanh function mapping latency excess → contention score.

      Higher k  →  score rises faster for the same excess above baseline
      Lower  k  →  score rises more gradually (less sensitive)

    Typical starting points:
      k_p90 = 0.5   (tail latency; already elevated → moderate sensitivity)
      k_p50 = 0.2   (median; needs larger excess to matter → lower sensitivity)
    """

    print(f"\n{'='*65}")
    print("  GORDION CONTENTION VISUALISATION")
    print(f"  k_p90={k_p90}   k_p50={k_p50}")
    print(f"{'='*65}")

    curve_csv_files = curve_csv_files or {}

    # Load and cache baseline stats per service (avoid re-reading the same
    # file for every run that belongs to the same service).
    baseline_cache: Dict[str, Tuple] = {}
    for service, bpath in baseline_stats_files.items():
        print(f"\n  Loading baseline for service='{service}':")
        bs90, bs50, bfreq = load_baseline_stats(bpath)
        bs50 = bs50 if bs50 is not None else bs90   # fall back p50 → p90 stats
        baseline_cache[service] = (bs90, bs50, bfreq)

    all_saved, ok, fail = [], 0, 0
    for i, fp in enumerate(file_list):
        try:
            service = detect_service(fp)
            if service not in baseline_cache:
                raise KeyError(
                    f"No baseline registered for service='{service}'. "
                    f"Add it to baseline_stats_files."
                )
            bs90, bs50, bfreq = baseline_cache[service]
            curve_csv = curve_csv_files.get(service)  # None → feature disabled

            print(f"\n[{i+1}/{len(file_list)}]  service={service}")
            saved = plot_gordion(
                fp, bs90, bs50,
                baseline_freq_mhz=bfreq,
                output_dir=output_dir,
                zoom_window=zoom_window,
                sample_interval_ms=sample_interval_ms,
                k_p90=k_p90,
                k_p50=k_p50,
                curve_csv=curve_csv,
            )
            all_saved.extend(saved); ok += 1
        except Exception as exc:
            import traceback
            print(f"  ✗ ERROR: {exc}")
            traceback.print_exc()
            fail += 1

    print(f"\n{'='*65}")
    print(f"  Done — {ok} succeeded, {fail} failed")
    print(f"{'='*65}")
    return all_saved


# ============================================================================
# __main__
# ============================================================================

if __name__ == '__main__':
    output_plots_dir = r"..\Data\Plots"

    # One baseline file per service — each file contains latency_p90,
    # latency_p50, and (optionally) freq_stats.
    baseline_stats_files = {
        'search':  r"..\Data\baseline_stats_search.json",
        'profile': r"..\Data\baseline_stats_profile.json",
    }

    # NEW: one clean load↔latency curve (curve.csv) per service, used for
    # the extrinsic-percentile panel. Omit / leave a service out to disable
    # that panel for its files.
    curve_csv_files = {
        'search':  r"..\Data\curve_search.csv",
        'profile': r"..\Data\curve_profile.csv",
    }

    input_files = [

        #r"..\Data\exp_20260618_200523_a796a066\raw\windowed\search\run_data_iter3_ready.json",
        #r"..\Data\exp_20260618_180201_e9aef2f8\raw\windowed\search\run_data_iter1_ready.json",
        #r"..\Data\exp_20260705_114049_dfe391ba\raw\windowed\search\run_data_iter2_ready.json",
        r"..\Data\exp_20260704_115519_8902fffc\raw\windowed\search\run_data_iter3_ready.json",
        #r"..\Data\exp_20260706_195705_7c926020\raw\windowed\search\run_data_iter1_ready.json",
        


        #r"..\Data\no_contention\raw\windowed\search\run_data_iter2_filtered_labeled.json",
    ]

    plot_all_files(
        file_list            = input_files,
        baseline_stats_files = baseline_stats_files,
        output_dir           = output_plots_dir,
        zoom_window          = 50,
        sample_interval_ms   = 100,
        # ── Tune these to adjust score sensitivity per quantile ────────────
        k_p90                = 0.25,   # tail latency sensitivity
        k_p50                = 10,   # median latency sensitivity
        curve_csv_files      = curve_csv_files,
    )