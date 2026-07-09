#!/bin/bash
# ===========================================================================
# reslice-curve.sh
#
# Rebuild curve.csv for a FINISHED curve_* experiment from its saved
# run_data + per-level manifest, WITHOUT re-running the sweep. Use after a
# slicing/aggregation fix or to add columns (e.g. p90).
#
# Loads the (large) run_data ONCE and slices all levels in one pass via
# curve_aggregate.py --build, so it's ~seconds even for hours-long runs.
#
# Reads:  <exp_dir>/saturation/levels.csv
#         <exp_dir>/raw/windowed/<svc>/run_data_full_raw.json
#         <exp_dir>/saturation/L<level>_rps<rps>.json   (for ghz_p90)
# Writes: <exp_dir>/curve.csv
#
# Usage: ./stage1-characterization/reslice-curve.sh <exp_dir>
# ===========================================================================
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exp="${1:?usage: reslice-curve.sh <exp_dir>}"

python3 "$DIR/curve_aggregate.py" --build "$exp"
