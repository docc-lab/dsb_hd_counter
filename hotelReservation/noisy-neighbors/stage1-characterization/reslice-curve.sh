#!/bin/bash
# ===========================================================================
# reslice-curve.sh
#
# Rebuild curve.csv for a FINISHED curve_* experiment from its saved
# run_data + per-level manifest, WITHOUT re-running the sweep. Use this after
# a slicing fix, or to re-aggregate with different logic.
#
# Reads:
#   <exp_dir>/saturation/levels.csv                         (per-level manifest)
#   <exp_dir>/raw/windowed/<svc>/run_data_full_raw.json     (single run_data)
# Writes:
#   <exp_dir>/curve.csv
#
# Usage (from anywhere):
#   ./stage1-characterization/reslice-curve.sh experiment_data/curve_search_<ts>_<id>
# ===========================================================================
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exp="${1:?usage: reslice-curve.sh <exp_dir>}"

manifest="$exp/saturation/levels.csv"
raw="$(ls "$exp"/raw/windowed/*/run_data_full_raw.json 2>/dev/null | head -1)"

[[ -s "$manifest" ]] || { echo "ERROR: no manifest at $manifest" >&2; exit 1; }
[[ -n "$raw" && -s "$raw" ]] || { echo "ERROR: no run_data_full_raw.json under $exp/raw/windowed/*/" >&2; exit 1; }

out="$exp/curve.csv"
echo "target_rps,arrival_rps_mean,arrival_rps_p50,arrival_rps_p99,svc_mean_us,svc_p50_us,svc_p99_us,ipc,llc_mpki,freq_mhz,freq_util_pct,active_windows,total_requests,ghz_actual_rps,ghz_p50_ms,ghz_p99_ms,ghz_errors,saturated" > "$out"

ln=0
while IFS=, read -r level rps mstart mend actual p50 p99 err sat; do
    ln=$((ln + 1)); [[ $ln -eq 1 ]] && continue    # skip manifest header
    agg=$(python3 "$DIR/curve_aggregate.py" "$raw" "$mstart" "$mend" 2>/dev/null || echo "0,0,0,0,0,0,0,0,0,0,0,0")
    echo "${rps},${agg},${actual},${p50},${p99},${err},${sat}" >> "$out"
done < "$manifest"

echo "Rewrote $out ($((ln - 1)) levels) from $(basename "$raw")"
