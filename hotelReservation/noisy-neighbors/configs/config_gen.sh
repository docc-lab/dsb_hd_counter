#!/bin/bash
# ===========================================================================
# config_gen.sh — regenerate the stage-2 contention-sweep config grid.
#
# Grid = RATES x SHAPES. Run from configs/ (needs ./a.sh + ./test.conf).
#
# 2026-07-03 rescale: the old grid swept WRK2_RATE 200-500, sized for the
# broken pre-fix environment (rate crash-loops, 117KB memcached values,
# cross-node cache). The fixed testbed sustains ~2500 rps e2e, so 200-500
# exercised <20% of the stage-3 operating region. New tiers sweep finely up
# to just under the ceiling. Stressor burst intensities (10-40 workers) are
# kept as-is: the aggressor side contends for the same cores regardless of
# victim rps.
#
# Also fixed from the old generator: the 10s_repeated4_burst{30,40}_start20
# entries passed num_bursts=2 (mislabeled as repeated4) — now actually 4.
#
# 2026-07-05: added the no-stressor baseline tier (0s_baseline_rps*) that the
# original grid forgot — one per rate, same template/threads/connections as
# the contention configs, CONTENTION_BURSTS=none.
#
# WRK2_THREADS scales with rate; WRK2_CONNECTIONS is only a FLOOR — the
# harness auto-scales connections to max(floor, rate) capped at 256
# (data-collector.sh run_load), so 32 everywhere is correct.
# ===========================================================================
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
chmod +x ./a.sh

# --------------------------------------------------------------------------
# Victim-load tiers (finer grid; testbed ceiling ~2500 rps e2e).
# --------------------------------------------------------------------------
RATES=(300 600 900 1200 1500 1800 2100 2400)

# wrk2 client threads per tier (>= 1 core per ~300-400 rps of lua workload).
threads_for_rate() {
    local r="$1"
    if   (( r <= 600 ));  then echo 4
    elif (( r <= 1200 )); then echo 6
    else                       echo 8
    fi
}
CONNS_FLOOR=32   # floor only; harness auto-scales to >= rate (cap 256)

# --------------------------------------------------------------------------
# Contention shapes: "name_prefix|burst_expression" (rate suffix appended).
# Helpers (sourced by data-collector.sh from contention-shapes.sh):
#   burst            <start> <duration> <intensity>
#   repeat_burst     <start> <burst_dur> <idle> <num_bursts> <intensity>
#   linear_intensity <start> <burst_dur> <idle> <num_bursts> <from> <to>
# --------------------------------------------------------------------------
SHAPES=(
    # Single bursts — varying burst size and start time
    "30s_single_burst20_start20|\$(burst 20 30 20)"
    "30s_single_burst25_start20|\$(burst 20 30 25)"
    "30s_single_burst30_start20|\$(burst 20 30 30)"
    "30s_single_burst35_start20|\$(burst 20 30 35)"
    "30s_single_burst40_start20|\$(burst 20 30 40)"
    "30s_single_burst20_start10|\$(burst 10 30 20)"
    "30s_single_burst30_start10|\$(burst 10 30 30)"
    "30s_single_burst40_start10|\$(burst 10 30 40)"
    # Repeated bursts — 30s window, 2 repeats, varying burst size
    "30s_repeated2_burst20_start20|\$(repeat_burst 20 30 20 2 20)"
    "30s_repeated2_burst25_start20|\$(repeat_burst 20 30 20 2 25)"
    "30s_repeated2_burst30_start20|\$(repeat_burst 20 30 20 2 30)"
    "30s_repeated2_burst35_start20|\$(repeat_burst 20 30 20 2 35)"
    "30s_repeated2_burst40_start20|\$(repeat_burst 20 30 20 2 40)"
    # Repeated bursts — 30s window, 3 repeats
    "30s_repeated3_burst20_start20|\$(repeat_burst 20 30 20 3 20)"
    "30s_repeated3_burst30_start20|\$(repeat_burst 20 30 20 3 30)"
    "30s_repeated3_burst40_start20|\$(repeat_burst 20 30 20 3 40)"
    # Repeated bursts — 10s window, 2 repeats
    "10s_repeated2_burst20_start20|\$(repeat_burst 20 10 20 2 20)"
    "10s_repeated2_burst30_start20|\$(repeat_burst 20 10 20 2 30)"
    "10s_repeated2_burst40_start20|\$(repeat_burst 20 10 20 2 40)"
    # Repeated bursts — 10s window, 3 repeats
    "10s_repeated3_burst20_start20|\$(repeat_burst 20 10 20 3 20)"
    "10s_repeated3_burst30_start20|\$(repeat_burst 20 10 20 3 30)"
    "10s_repeated3_burst40_start20|\$(repeat_burst 20 10 20 3 40)"
    # Repeated bursts — 10s window, 4 repeats (num_bursts fixed: was 2)
    "10s_repeated4_burst20_start20|\$(repeat_burst 20 10 20 4 20)"
    "10s_repeated4_burst30_start20|\$(repeat_burst 20 10 20 4 30)"
    "10s_repeated4_burst35_start20|\$(repeat_burst 20 10 20 4 35)"
    "10s_repeated4_burst40_start20|\$(repeat_burst 20 10 20 4 40)"
    # Early start (start=10)
    "30s_repeated2_burst20_start10|\$(repeat_burst 10 30 20 2 20)"
    "30s_repeated2_burst30_start10|\$(repeat_burst 10 30 20 2 30)"
    "30s_repeated2_burst40_start10|\$(repeat_burst 10 30 20 2 40)"
    "10s_repeated3_burst30_start10|\$(repeat_burst 10 10 20 3 30)"
    "10s_repeated3_burst40_start10|\$(repeat_burst 10 10 20 3 40)"
    "10s_repeated4_burst30_start10|\$(repeat_burst 10 10 20 4 30)"
    "10s_repeated4_burst40_start10|\$(repeat_burst 10 10 20 4 40)"
    # 20s window, 2-3 repeats
    "20s_repeated2_burst25_start20|\$(repeat_burst 20 20 20 2 25)"
    "20s_repeated2_burst35_start20|\$(repeat_burst 20 20 20 2 35)"
    "20s_repeated3_burst30_start20|\$(repeat_burst 20 20 20 3 30)"
    # Small bursts — 10 and 15 workers
    "30s_single_burst10_start20|\$(burst 20 30 10)"
    "30s_single_burst15_start20|\$(burst 20 30 15)"
    "30s_single_burst10_start10|\$(burst 10 30 10)"
    "30s_single_burst15_start10|\$(burst 10 30 15)"
    "30s_repeated2_burst10_start20|\$(repeat_burst 20 30 20 2 10)"
    "30s_repeated2_burst15_start20|\$(repeat_burst 20 30 20 2 15)"
    "10s_repeated3_burst10_start20|\$(repeat_burst 20 10 20 3 10)"
    "10s_repeated3_burst15_start20|\$(repeat_burst 20 10 20 3 15)"
    "10s_repeated4_burst10_start20|\$(repeat_burst 20 10 20 4 10)"
    "10s_repeated4_burst15_start20|\$(repeat_burst 20 10 20 4 15)"
    # Linear intensity ramps
    "30s_linear2_burst20-30_start20|\$(linear_intensity 20 30 20 2 20 30)"
    "30s_linear2_burst30-40_start20|\$(linear_intensity 20 30 20 2 30 40)"
    "30s_linear2_burst30-20_start20|\$(linear_intensity 20 30 20 2 30 20)"
    "30s_linear2_burst40-30_start20|\$(linear_intensity 20 30 20 2 40 30)"
)

# --------------------------------------------------------------------------
# No-stressor baselines: one per rate tier.
# CONTENTION_BURSTS=none is data-collector.sh's explicit no-contention mode
# (generate_burst_schedule); in that mode the run length comes from
# EXPERIMENT_DURATION instead of the burst schedule, so pin it explicitly.
# 100s sits at the median of the contention iterations (shape max_end ranges
# 40-150s) and matches the modal 30s_repeated2 / linear2 shapes exactly.
# Everything else (test.conf template, rate tiers, threads_for_rate, conns
# floor) is identical to the contention grid, so baselines are directly
# comparable to the already-run stage-2 experiments. The "0s_" prefix keeps
# the names inside run-batch.sh's default 'configs/[0-9]*.conf' glob and
# sorts them ahead of the 10s_/20s_/30s_ shapes.
# --------------------------------------------------------------------------
BASELINE_DURATION=100
total=0
for rate in "${RATES[@]}"; do
    threads=$(threads_for_rate "$rate")
    name="0s_baseline_rps${rate}"
    ./a.sh "EXPERIMENT_NAME='${name}'" \
           "CONTENTION_BURSTS=none" \
           "WRK2_RATE=${rate}" \
           "WRK2_THREADS=${threads}" \
           "WRK2_CONNECTIONS=${CONNS_FLOOR}"
    if grep -q '^EXPERIMENT_DURATION=' "${name}.conf"; then
        sed -i "s|^EXPERIMENT_DURATION=.*|EXPERIMENT_DURATION=${BASELINE_DURATION}|" "${name}.conf"
    else
        echo "EXPERIMENT_DURATION=${BASELINE_DURATION}" >> "${name}.conf"
    fi
    total=$((total + 1))
done

# --------------------------------------------------------------------------
# Generate: RATES x SHAPES
# --------------------------------------------------------------------------
for rate in "${RATES[@]}"; do
    threads=$(threads_for_rate "$rate")
    for entry in "${SHAPES[@]}"; do
        name="${entry%%|*}"
        expr="${entry#*|}"
        ./a.sh "EXPERIMENT_NAME='${name}_rps${rate}'" \
               "CONTENTION_BURSTS=${expr}" \
               "WRK2_RATE=${rate}" \
               "WRK2_THREADS=${threads}" \
               "WRK2_CONNECTIONS=${CONNS_FLOOR}"
        total=$((total + 1))
    done
done

echo ""
echo "Generated $total configs (${#RATES[@]} rate tiers x (${#SHAPES[@]} shapes + 1 baseline))."
