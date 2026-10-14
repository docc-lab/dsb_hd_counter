#!/bin/bash
# ===========================================================================
# config-parse.sh
#
# Sourced by stage3-eval.sh. Provides parse_config() which loads one
# YAML file via yq and exports flat bash variables + arrays for the
# orchestrator + downstream lib/*.sh helpers.
#
# Conventions (so downstream scripts don't have to re-parse):
#   EXPERIMENT_NAME, EXPERIMENT_DURATION_S, EXPERIMENT_WARMUP_S,
#   EXPERIMENT_COOLDOWN_S, EXPERIMENT_RUNS, TARGET_NODE         (scalars)
#   VICTIM_TESTBED, VICTIM_SERVICE, VICTIM_IMAGE,
#   VICTIM_SCORE_LOG, VICTIM_CPU_SET                             (victim scalars)
#   TESTBED_LOADGEN_JSON[<name>]                                 (per-testbed wrk2 cfg)
#   AGGRESSOR_COUNT, AGGRESSOR_JSON[<i>]                         (aggressor list)
#
# AGGRESSOR_JSON[i] is the original YAML element re-serialized as
# compact JSON; downstream helpers use jq to read fields without
# spreading N flat bash vars per aggressor.
#
# TESTBED_LOADGEN_JSON[<testbed>] is the per-testbed `loadgen` object
# as compact JSON, e.g. {"rps":200,"shape":"fixed"} or
# {"rps":300,"shape":{"burst_s":15,"idle_s":30,"peak_rps":600,"base_rps":100}}.
# ===========================================================================

set -u
# Note: we intentionally do NOT set -e here; sourcing scripts manage their
# own error handling. parse_config() returns non-zero on parse failure.

# ---------------------------------------------------------------------------
# Tool checks
# ---------------------------------------------------------------------------

require_yq_jq() {
    if ! command -v yq >/dev/null 2>&1; then
        echo "ERROR: yq is required but not on PATH." >&2
        echo "       Install: https://github.com/mikefarah/yq/releases (v4+, Go)" >&2
        return 1
    fi
    local yq_ver
    yq_ver=$(yq --version 2>&1 | head -1)
    if [[ ! "$yq_ver" =~ (mikefarah|version[[:space:]]+v?4) ]] \
       && [[ ! "$yq_ver" =~ ^yq[[:space:]]+\(https://github.com/mikefarah/yq/\) ]]; then
        echo "WARNING: yq version may be incompatible (need mikefarah v4+): $yq_ver" >&2
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: jq is required but not on PATH." >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# parse_config <yaml-file>
#
# Sets the bash globals listed at the top. Returns 0 on success, non-zero
# on parse / validation failure (with a stderr message). Validation is
# intentionally light here -- the orchestrator's preflight phase does
# cluster-state validation later.
# ---------------------------------------------------------------------------

# _validate_loadgen <yaml-path-for-messages> <loadgen-json>
#
# Checks the fields a loadgen (or its `extra`) shares: shape and
# start_offset_s. Needs EXPERIMENT_DURATION_S set.
_validate_loadgen() {
    local where="$1" lg="$2"
    # Validate shape: a string must be a known wrk2 distribution; an
    # object is the bursty form (its fields are checked by the driver).
    # Catches typos like shape: exp2 here instead of silently running
    # fixed at run time.
    local shape_type shape_val
    shape_type=$(echo "$lg" | jq -r '.shape | type')
    if [[ "$shape_type" == "string" ]]; then
        shape_val=$(echo "$lg" | jq -r '.shape')
        case "$shape_val" in
            fixed|exp|norm|zipf) ;;
            *) echo "ERROR: $where.shape='$shape_val' invalid (want fixed|exp|norm|zipf, or a bursty object {burst_s,idle_s,peak_rps,base_rps})" >&2
               return 1 ;;
        esac
    fi
    # start_offset_s delays the driver's first request; its window shrinks to
    # duration_s - offset so every driver still ends together.
    local off
    off=$(echo "$lg" | jq -r '.start_offset_s // 0')
    if ! [[ "$off" =~ ^[0-9]+$ ]] || [[ "$off" -ge "$EXPERIMENT_DURATION_S" ]]; then
        echo "ERROR: $where.start_offset_s must be an integer in [0, duration_s=$EXPERIMENT_DURATION_S) (got: '$off')" >&2
        return 1
    fi
    return 0
}

parse_config() {
    local config_file="$1"

    require_yq_jq || return 1

    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: config file not found: $config_file" >&2
        return 1
    fi

    # experiment block
    EXPERIMENT_NAME=$(yq -e -r '.experiment.name'           "$config_file") || {
        echo "ERROR: experiment.name missing or empty in $config_file" >&2; return 1; }
    EXPERIMENT_DURATION_S=$(yq -e -r '.experiment.duration_s // 300'    "$config_file")
    EXPERIMENT_WARMUP_S=$(yq   -e -r '.experiment.warmup_s   // 30'     "$config_file")
    EXPERIMENT_COOLDOWN_S=$(yq -e -r '.experiment.cooldown_s // 30'     "$config_file")
    EXPERIMENT_RUNS=$(yq       -e -r '.experiment.runs       // 3'      "$config_file")
    TARGET_NODE=$(yq -e -r     '.experiment.target_node'    "$config_file") || {
        echo "ERROR: experiment.target_node missing in $config_file" >&2; return 1; }

    for var in EXPERIMENT_DURATION_S EXPERIMENT_WARMUP_S EXPERIMENT_COOLDOWN_S EXPERIMENT_RUNS; do
        if ! [[ "${!var}" =~ ^[0-9]+$ ]]; then
            echo "ERROR: $var must be a non-negative integer (got: '${!var}')" >&2
            return 1
        fi
    done
    if [[ "$EXPERIMENT_RUNS" -lt 1 ]]; then
        echo "ERROR: experiment.runs must be >= 1" >&2
        return 1
    fi

    # victim block (no loadgen field; load comes from victim's testbed driver)
    VICTIM_TESTBED=$(yq -e -r        '.victim.testbed'  "$config_file") || {
        echo "ERROR: victim.testbed missing" >&2; return 1; }
    VICTIM_SERVICE=$(yq -e -r        '.victim.service'  "$config_file") || {
        echo "ERROR: victim.service missing" >&2; return 1; }
    VICTIM_IMAGE=$(yq -e -r          '.victim.image'    "$config_file") || {
        echo "ERROR: victim.image missing" >&2; return 1; }
    VICTIM_SCORE_LOG=$(yq -r         '.victim.score_log // false' "$config_file")
    # Instrumentation source applied to the victim at deploy time (onnx | none).
    # Default onnx. Lives here (not in the base manifests) so any HR service is
    # a clean stock service until it's selected as the victim.
    VICTIM_SCORE_SOURCE=$(yq -r       '.victim.score_source // "onnx"' "$config_file")
    # Cores the victim is pinned to (taskset inside the container, see
    # deploy_victim) and that the windowed sampler counts on. Empty = unpinned
    # and counted on every CPU.
    VICTIM_CPU_SET=$(yq -r            '.victim.cpu_set // ""' "$config_file")
    if [[ -n "$VICTIM_CPU_SET" && ! "$VICTIM_CPU_SET" =~ ^[0-9]+([,-][0-9]+)*$ ]]; then
        echo "ERROR: victim.cpu_set must be a cpu list like 2,3,4 or 2-4 (got: '$VICTIM_CPU_SET')" >&2
        return 1
    fi

    if [[ "$VICTIM_TESTBED" != "hotelReservation" ]]; then
        echo "ERROR: victim.testbed must be 'hotelReservation' (only testbed with stage3wire.Setup wired today, got '$VICTIM_TESTBED')" >&2
        return 1
    fi

    # testbeds block -> per-testbed loadgen JSON, one map slot per testbed.
    declare -gA TESTBED_LOADGEN_JSON=()
    declare -gA TESTBED_REPLICAS=()      # per-testbed compute-service replica count (default 1)
    local tb_names tb
    tb_names=$(yq -r '.testbeds | keys | .[]' "$config_file" 2>/dev/null || echo "")
    if [[ -z "$tb_names" ]]; then
        echo "ERROR: 'testbeds:' block is missing or empty in $config_file" >&2
        echo "       At minimum the victim's testbed must appear with a loadgen entry." >&2
        return 1
    fi
    while IFS= read -r tb; do
        [[ -z "$tb" ]] && continue
        local lg
        lg=$(yq -o=json -I=0 ".testbeds.\"$tb\".loadgen // null" "$config_file")
        if [[ "$lg" == "null" || -z "$lg" ]]; then
            echo "ERROR: testbeds.$tb.loadgen missing" >&2
            return 1
        fi
        # Validate rps is present and an integer. rps: 0 is deploy-only: the
        # testbed's pods are deployed/placed but no wrk2 driver runs (the
        # intrinsic configs keep SN/SS co-tenants present but unloaded).
        local rps
        rps=$(echo "$lg" | jq -r '.rps // empty')
        if [[ -z "$rps" ]] || ! [[ "$rps" =~ ^[0-9]+$ ]]; then
            echo "ERROR: testbeds.$tb.loadgen.rps must be a non-negative integer (got: '$rps')" >&2
            return 1
        fi
        if [[ "$rps" -eq 0 && "$tb" == "$VICTIM_TESTBED" ]]; then
            echo "ERROR: testbeds.$tb.loadgen.rps=0 is not allowed for the victim's testbed" >&2
            return 1
        fi
        _validate_loadgen "testbeds.$tb.loadgen" "$lg" || return 1
        # extra: an OPTIONAL second driver against the same frontend (same
        # script), how intrinsic overload is expressed:
        #   extra: {rps: 1600, shape: fixed, start_offset_s: 20}
        local extra
        extra=$(echo "$lg" | jq -c '.extra // empty')
        if [[ -n "$extra" ]]; then
            local xrps
            xrps=$(echo "$extra" | jq -r '.rps // empty')
            if [[ -z "$xrps" ]] || ! [[ "$xrps" =~ ^[0-9]+$ ]] || [[ "$xrps" -le 0 ]]; then
                echo "ERROR: testbeds.$tb.loadgen.extra.rps must be a positive integer (got: '$xrps')" >&2
                return 1
            fi
            _validate_loadgen "testbeds.$tb.loadgen.extra" "$extra" || return 1
        fi
        # Optional per-testbed replica count for the compute services. Used to
        # scale non-HR aggressor testbeds up so their node-pinned services
        # generate more load/CPU. Default 1. HR (the victim testbed) is left at
        # its manifest replicas regardless of this field.
        local reps
        reps=$(yq -r ".testbeds.\"$tb\".replicas // 1" "$config_file")
        if ! [[ "$reps" =~ ^[0-9]+$ ]] || [[ "$reps" -lt 1 ]]; then
            echo "ERROR: testbeds.$tb.replicas must be a positive integer (got: '$reps')" >&2
            return 1
        fi
        TESTBED_REPLICAS["$tb"]="$reps"
        TESTBED_LOADGEN_JSON["$tb"]="$lg"
    done <<< "$tb_names"

    # Victim's testbed must appear in testbeds:.
    if [[ -z "${TESTBED_LOADGEN_JSON[$VICTIM_TESTBED]:-}" ]]; then
        echo "ERROR: victim.testbed='$VICTIM_TESTBED' has no entry in testbeds: block" >&2
        return 1
    fi

    # aggressor list -> per-element compact JSON, one per AGGRESSOR_JSON slot.
    AGGRESSOR_COUNT=$(yq -r '.aggressors | length' "$config_file")
    if ! [[ "$AGGRESSOR_COUNT" =~ ^[0-9]+$ ]]; then
        AGGRESSOR_COUNT=0
    fi

    # shellcheck disable=SC2034  # AGGRESSOR_JSON consumed by orchestrator
    AGGRESSOR_JSON=()
    local i
    for ((i = 0; i < AGGRESSOR_COUNT; i++)); do
        local entry
        entry=$(yq -o=json -I=0 ".aggressors[$i]" "$config_file") || {
            echo "ERROR: failed to extract aggressors[$i]" >&2; return 1; }
        # Each aggressor is {testbed, service, role}. The pipeline pins
        # the named service to target_node and lets that testbed's wrk2
        # drive its load via the call chain.
        local agg_tb agg_svc
        agg_tb=$(echo "$entry"  | jq -r '.testbed // ""')
        agg_svc=$(echo "$entry" | jq -r '.service // ""')
        if [[ -z "$agg_tb" ]]; then
            echo "ERROR: aggressors[$i] requires a .testbed field" >&2
            return 1
        fi
        if [[ -z "$agg_svc" ]]; then
            echo "ERROR: aggressors[$i] requires a .service field (the service to pin to target_node)" >&2
            return 1
        fi
        if [[ -z "${TESTBED_LOADGEN_JSON[$agg_tb]:-}" ]]; then
            echo "ERROR: aggressors[$i].testbed='$agg_tb' has no entry in testbeds: block" >&2
            return 1
        fi
        AGGRESSOR_JSON+=("$entry")
    done

    # Export scalars so child shells can see them. Associative arrays
    # don't export across processes; the orchestrator dumps any state
    # it needs in subshells to sidecar JSON files (see metadata/).
    export EXPERIMENT_NAME EXPERIMENT_DURATION_S EXPERIMENT_WARMUP_S \
           EXPERIMENT_COOLDOWN_S EXPERIMENT_RUNS TARGET_NODE \
           VICTIM_TESTBED VICTIM_SERVICE VICTIM_IMAGE VICTIM_SCORE_LOG \
           VICTIM_SCORE_SOURCE VICTIM_CPU_SET AGGRESSOR_COUNT

    return 0
}

# ---------------------------------------------------------------------------
# Helpers callers use to read individual aggressor entries by index
# without having to know jq syntax themselves.
# ---------------------------------------------------------------------------

# aggressor_field <index> <jq-path-from-root>
aggressor_field() {
    local idx="$1"
    local path="$2"
    if [[ "$idx" -ge "${AGGRESSOR_COUNT:-0}" ]]; then
        echo ""
        return
    fi
    echo "${AGGRESSOR_JSON[$idx]}" | jq -r "${path} // empty"
}

# testbed_loadgen_json <testbed-name>
#
# Echoes the per-testbed loadgen object as compact JSON. Empty string
# if the testbed isn't configured.
testbed_loadgen_json() {
    local tb="$1"
    echo "${TESTBED_LOADGEN_JSON[$tb]:-}"
}

# testbed_loadgen_rps <testbed-name>
testbed_loadgen_rps() {
    local tb="$1"
    local lg="${TESTBED_LOADGEN_JSON[$tb]:-}"
    [[ -z "$lg" ]] && { echo ""; return; }
    echo "$lg" | jq -r '.rps'
}

# testbed_loadgen_offset <testbed-name>  -> start_offset_s (0 if unset)
testbed_loadgen_offset() {
    local lg="${TESTBED_LOADGEN_JSON[$1]:-}"
    [[ -z "$lg" ]] && { echo 0; return; }
    echo "$lg" | jq -r '.start_offset_s // 0'
}

# testbed_loadgen_extra_json <testbed-name>  -> the `extra` object, or ""
testbed_loadgen_extra_json() {
    local lg="${TESTBED_LOADGEN_JSON[$1]:-}"
    [[ -z "$lg" ]] && { echo ""; return; }
    echo "$lg" | jq -c '.extra // empty'
}

# testbed_loadgen_shape_json <testbed-name>
#
# Echoes the shape sub-object as compact JSON ("fixed" if missing or
# the testbed isn't configured, so downstream callers always get a
# valid JSON value).
testbed_loadgen_shape_json() {
    local tb="$1"
    local lg="${TESTBED_LOADGEN_JSON[$tb]:-}"
    [[ -z "$lg" ]] && { echo '"fixed"'; return; }
    echo "$lg" | jq -c '.shape // "fixed"'
}

# driven_testbed_names
#
# Echoes (one per line, no duplicates) the names of testbeds that are
# in scope for this experiment: the victim's testbed plus any testbed
# referenced by any aggressor. Used by the orchestrator to decide
# which testbeds to deploy + start a wrk2 driver for.
driven_testbed_names() {
    {
        echo "$VICTIM_TESTBED"
        local i tb
        for ((i = 0; i < AGGRESSOR_COUNT; i++)); do
            tb=$(aggressor_field "$i" '.testbed')
            [[ -n "$tb" ]] && echo "$tb"
        done
    } | awk '!seen[$0]++'
}
