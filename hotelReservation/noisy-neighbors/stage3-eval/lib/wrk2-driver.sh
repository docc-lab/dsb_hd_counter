#!/bin/bash
# ===========================================================================
# wrk2-driver.sh
#
# Background wrk2 launcher with two shapes:
#   fixed   -> one long wrk invocation at constant RPS
#   bursty  -> loop alternating { peak_rps for burst_s, base_rps for idle_s }
#              until total elapsed >= duration_s. Implemented as
#              successive wrk invocations (simple, gapless within a few ms).
#
# Used by stage3-eval.sh to drive each aggressor (and optionally the
# victim, though the victim is normally driven via ghz instead).
#
# Conventions:
#   - WRK2_BIN defaults to ../../../wrk2/wrk (relative to this dir),
#     matching the path used by ../data-collector.sh ($WRK2_DIR/wrk).
#   - Output of each wrk invocation goes to a single appended .txt file
#     so the mitigation side / experimenter sees one artifact per
#     aggressor per run.
#
# Process-management contract:
#   start_wrk2_driver writes the background PID to $pidfile and exits.
#   stop_wrk2_driver reads $pidfile and SIGTERMs the process group
#   (covers the wrapper shell + any in-flight wrk children).
# ===========================================================================

set -u

WRK2_BIN="${WRK2_BIN:-../../../wrk2/wrk}"

# Per-testbed wrk script paths + default loadgen target URLs. The orchestrator
# overrides target_url at call time if NodePort lookup resolved a different
# host:port, but having defaults keeps developer-mode invocations simple.
declare -gA WRK2_TESTBED_SCRIPT=(
    [hotelReservation]="../../wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua"
    [socialNetwork]="../../../socialNetwork/wrk2/scripts/social-network/mixed-workload.lua"
)

# Default wrk2 thread / connection knobs. Override per-aggressor via env if
# specific aggressors need more concurrency; experimenter can also set
# WRK2_THREADS / WRK2_CONNECTIONS globally before invoking stage3-eval.sh.
WRK2_THREADS="${WRK2_THREADS:-4}"
WRK2_CONNECTIONS="${WRK2_CONNECTIONS:-16}"

# ---------------------------------------------------------------------------
# resolve_wrk2_script <testbed>
#
# Echoes the lua script path the wrk2 driver should use for the given
# testbed. Returns non-zero if unknown.
# ---------------------------------------------------------------------------
resolve_wrk2_script() {
    local testbed="$1"
    local script="${WRK2_TESTBED_SCRIPT[$testbed]:-}"
    if [[ -z "$script" ]]; then
        echo "ERROR: no wrk2 script registered for testbed '$testbed'" >&2
        echo "       Known: ${!WRK2_TESTBED_SCRIPT[*]}" >&2
        return 1
    fi
    echo "$script"
}

# ---------------------------------------------------------------------------
# start_wrk2_driver <label> <target_url> <shape_json> <duration_s> \
#                   <out_file> <pid_file> <script_path>
#
# Launches the wrk2 driver in the background. Returns 0 immediately
# after fork; the driver runs until duration_s elapses or it's killed
# via stop_wrk2_driver.
#
# shape_json is one of:
#   "fixed" | "exp" | "norm" | "zipf"       -> a wrk2 inter-arrival
#                                              distribution (-D) run at the
#                                              single mean rate WRK2_FIXED_RPS:
#                                              fixed=constant, exp=Poisson,
#                                              norm=normal, zipf=zipfian.
#   {"burst_s":N,"idle_s":N,"peak_rps":N,"base_rps":N}  -> alternating
#                                              peak/idle bursty load.
# Any other string is rejected (so a typo'd shape fails loudly instead of
# silently degrading to fixed).
#
# For the string shapes we look at the WRK2_FIXED_RPS env var (caller sets
# it before invoking) for the target RPS. We do this rather than adding
# another positional arg because aggressor.loadgen.rps already lives in the
# YAML and the orchestrator's caller code is easier to read with one
# env-var hand-off.
# ---------------------------------------------------------------------------
start_wrk2_driver() {
    local label="$1"
    local target_url="$2"
    local shape_json="$3"
    local duration_s="$4"
    local out_file="$5"
    local pid_file="$6"
    local script_path="$7"

    if [[ ! -x "$WRK2_BIN" && ! -f "$WRK2_BIN" ]]; then
        echo "ERROR [wrk2-driver:$label]: WRK2_BIN not found at $WRK2_BIN" >&2
        return 1
    fi
    if [[ ! -f "$script_path" ]]; then
        echo "ERROR [wrk2-driver:$label]: lua script not found at $script_path" >&2
        return 1
    fi

    mkdir -p "$(dirname "$out_file")"
    : > "$out_file"

    # Determine shape kind: string "fixed" vs object form.
    local shape_kind
    shape_kind=$(echo "$shape_json" | jq -r 'if type == "object" then "bursty" else . end')

    # Spawn the driver in a subshell so we can put it in its own process
    # group via setsid, which makes stop_wrk2_driver a clean PGID kill.
    # Use `setsid` to detach into a new session; fall back to plain `&`
    # if setsid isn't available (it's universal on Linux but rare to be
    # missing; the fallback loses clean group kill but doesn't break).
    local launcher
    if command -v setsid >/dev/null 2>&1; then
        launcher="setsid -f"
    else
        launcher=""
    fi

    case "$shape_kind" in
        bursty)
            local burst_s   idle_s   peak_rps   base_rps
            burst_s=$(echo   "$shape_json" | jq -r '.burst_s')
            idle_s=$(echo    "$shape_json" | jq -r '.idle_s')
            peak_rps=$(echo  "$shape_json" | jq -r '.peak_rps')
            base_rps=$(echo  "$shape_json" | jq -r '.base_rps')
            for v in "$burst_s" "$idle_s" "$peak_rps" "$base_rps"; do
                if ! [[ "$v" =~ ^[0-9]+$ ]] || [[ "$v" -le 0 ]]; then
                    echo "ERROR [wrk2-driver:$label]: bursty shape requires positive integers (got burst_s=$burst_s idle_s=$idle_s peak_rps=$peak_rps base_rps=$base_rps)" >&2
                    return 1
                fi
            done

            $launcher bash -c "
                end=\$(( \$(date +%s) + $duration_s ))
                while [[ \$(date +%s) -lt \$end ]]; do
                    # Peak window
                    remaining=\$(( end - \$(date +%s) ))
                    if [[ \$remaining -le 0 ]]; then break; fi
                    burst=\$(( $burst_s < remaining ? $burst_s : remaining ))
                    echo '--- BURST peak_rps=$peak_rps for '\$burst's @ ' \$(date -Iseconds) >> '$out_file'
                    '$WRK2_BIN' -D fixed -t $WRK2_THREADS -c $WRK2_CONNECTIONS \
                        -d \${burst}s -L -R $peak_rps -s '$script_path' '$target_url' \
                        >> '$out_file' 2>&1 || true
                    # Idle window
                    remaining=\$(( end - \$(date +%s) ))
                    if [[ \$remaining -le 0 ]]; then break; fi
                    idle=\$(( $idle_s < remaining ? $idle_s : remaining ))
                    echo '--- IDLE base_rps=$base_rps for '\$idle's @ ' \$(date -Iseconds) >> '$out_file'
                    '$WRK2_BIN' -D fixed -t $WRK2_THREADS -c $WRK2_CONNECTIONS \
                        -d \${idle}s -L -R $base_rps -s '$script_path' '$target_url' \
                        >> '$out_file' 2>&1 || true
                done
            " &
            ;;

        fixed|exp|norm|zipf)
            # String shapes map 1:1 to wrk2's inter-arrival distribution
            # (-D): fixed=constant, exp=Poisson, norm=normal, zipf=zipfian.
            # All run at the single mean rate WRK2_FIXED_RPS.
            local dist="$shape_kind"
            local rps="${WRK2_FIXED_RPS:?WRK2_FIXED_RPS must be set for $dist shape}"
            if ! [[ "$rps" =~ ^[0-9]+$ ]] || [[ "$rps" -le 0 ]]; then
                echo "ERROR [wrk2-driver:$label]: WRK2_FIXED_RPS must be a positive integer (got '$rps')" >&2
                return 1
            fi
            $launcher bash -c "
                echo '--- shape=$dist rps=$rps for ${duration_s}s @ ' \$(date -Iseconds) >> '$out_file'
                '$WRK2_BIN' -D $dist -t $WRK2_THREADS -c $WRK2_CONNECTIONS \
                    -d ${duration_s}s -L -R $rps -s '$script_path' '$target_url' \
                    >> '$out_file' 2>&1 || true
            " &
            ;;

        *)
            # Previously this fell through to fixed, silently masking typos
            # like shape: exp2. Fail loudly instead.
            echo "ERROR [wrk2-driver:$label]: unknown shape '$shape_kind' (want: fixed|exp|norm|zipf, or a bursty object {burst_s,idle_s,peak_rps,base_rps})" >&2
            return 1
            ;;
    esac

    local pid=$!
    echo "$pid" > "$pid_file"
    return 0
}

# ---------------------------------------------------------------------------
# stop_wrk2_driver <pid_file>
#
# SIGTERMs the process group of the PID in pid_file (works whether
# setsid succeeded or not -- if PGID == PID, kill -PGID still hits it;
# if not, we also fall through to a plain kill). Idempotent.
# ---------------------------------------------------------------------------
stop_wrk2_driver() {
    local pid_file="$1"
    if [[ ! -f "$pid_file" ]]; then
        return 0
    fi
    local pid
    pid=$(cat "$pid_file" 2>/dev/null || echo "")
    [[ -z "$pid" ]] && return 0

    # Try group kill (negative pid). Then fall back to direct kill so
    # we cover both setsid-detached and plain-`&` cases.
    kill -TERM -- -"$pid" 2>/dev/null || true
    kill -TERM    "$pid"  2>/dev/null || true

    # Give it 2s to wind down, then SIGKILL if still alive.
    local i
    for ((i=0; i<10; i++)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$pid_file"
            return 0
        fi
        sleep 0.2
    done
    kill -KILL -- -"$pid" 2>/dev/null || true
    kill -KILL    "$pid"  2>/dev/null || true
    rm -f "$pid_file"
    return 0
}
