#!/bin/bash
# ===========================================================================
# write-run-manifest.sh
#
# Writes the per-run metadata JSON the mitigation side reads to slice
# its own captured streams by run boundary.
#
# Schema (v1) -- see README.md "Integration with mitigation side" for
# the long-form contract:
#
# {
#   "schema_version": 1,
#   "run_id": <int>,
#   "experiment_id": "<str>",
#   "experiment_name": "<str>",
#   "config_snapshot": <object>,            # full input YAML as JSON
#   "started_epoch_ns": <int64>,            # bracket starts when wrk2 drivers go
#   "ended_epoch_ns": <int64>,              #  ... and ends when they stop
#   "target_node": "<str>",
#   "victim":     { service, image, pod, node, testbed, score_log_enabled },
#   "aggressors": [ { testbed, service, role,
#                     namespace, deployment, pod, node } ],
#   "testbed_loadgens": { <testbed>: { rps, shape } },
#   "artifacts":  { wrk2_outputs: { <testbed>: <path> } }
# }
#
# Per-aggressor loadgen is gone: every in-scope testbed gets exactly one
# wrk2 driver (per the loadgen model in configs/schema.md), so loadgen
# config + outputs are keyed by testbed name.
#
# The orchestrator builds three tempfiles (aggressors[], artifacts{},
# testbed_loadgens{}) and passes them as jq inputs so we don't
# reconstruct the shapes here. It also passes the input YAML so we
# inline it as config_snapshot.
# ===========================================================================

set -u

# ---------------------------------------------------------------------------
# write_run_manifest \
#       <exp_id> <exp_name> <run_id> <run_dir> <input_yaml> \
#       <target_node> <started_ns> <ended_ns> \
#       <victim_json> <aggressors_json_file> <artifacts_json_file> \
#       <testbed_loadgens_json_file>
#
# All <*_json*> inputs are JSON values (not paths) except the three
# explicitly named *_file arguments which are paths to JSON files
# (used because the array/object can be too long for an argv string).
#
# Output: $run_dir/per_run.json (one ~1 KB file)
# ---------------------------------------------------------------------------
write_run_manifest() {
    local exp_id="$1"
    local exp_name="$2"
    local run_id="$3"
    local run_dir="$4"
    local input_yaml="$5"
    local target_node="$6"
    local started_ns="$7"
    local ended_ns="$8"
    local victim_json="$9"
    local aggressors_json_file="${10}"
    local artifacts_json_file="${11}"
    local testbed_loadgens_json_file="${12}"

    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR [write-run-manifest]: jq is required" >&2
        return 1
    fi
    if ! command -v yq >/dev/null 2>&1; then
        echo "ERROR [write-run-manifest]: yq is required (for config_snapshot inlining)" >&2
        return 1
    fi

    mkdir -p "$run_dir"
    local out="$run_dir/per_run.json"

    # Convert input YAML -> JSON for config_snapshot. Done with yq so a
    # missing field in the YAML becomes a missing field in the JSON,
    # not a string "null".
    local config_json
    config_json=$(yq -o=json -I=0 '.' "$input_yaml") || {
        echo "ERROR [write-run-manifest]: failed to convert $input_yaml to JSON" >&2
        return 1
    }

    # Assemble final per_run.json. Using --argjson to inject already-parsed
    # JSON values keeps quoting clean and avoids accidental string nesting.
    jq -n \
        --arg     exp_id           "$exp_id" \
        --arg     exp_name         "$exp_name" \
        --argjson run_id           "$run_id" \
        --argjson started_ns       "$started_ns" \
        --argjson ended_ns         "$ended_ns" \
        --arg     target_node      "$target_node" \
        --argjson config           "$config_json" \
        --argjson victim           "$victim_json" \
        --slurpfile aggressors     "$aggressors_json_file" \
        --slurpfile artifacts      "$artifacts_json_file" \
        --slurpfile testbed_loadgens "$testbed_loadgens_json_file" \
        '{
            schema_version:    1,
            run_id:            $run_id,
            experiment_id:     $exp_id,
            experiment_name:   $exp_name,
            config_snapshot:   $config,
            started_epoch_ns:  $started_ns,
            ended_epoch_ns:    $ended_ns,
            target_node:       $target_node,
            victim:            $victim,
            aggressors:        $aggressors[0],
            testbed_loadgens:  $testbed_loadgens[0],
            artifacts:         $artifacts[0]
        }' > "$out" || {
        echo "ERROR [write-run-manifest]: jq failed to produce $out" >&2
        return 1
    }

    return 0
}

# ---------------------------------------------------------------------------
# build_experiment_manifest <exp_dir>
#
# Called once at experiment end. Concatenates every runs/run_*/per_run.json
# into a single experiment_manifest.json (one JSON array) for the
# mitigation-side fetcher's convenience. Falls back to writing an empty
# array if no per_run.json files exist (unusual but possible if all runs
# failed before the manifest write).
# ---------------------------------------------------------------------------
build_experiment_manifest() {
    local exp_dir="$1"
    local out="$exp_dir/experiment_manifest.json"

    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR [write-run-manifest:build_experiment_manifest]: jq required" >&2
        return 1
    fi

    # Use shell glob expansion + jq -s '.' (slurp into array).
    # Sort by run_id so the array is in run order regardless of glob order.
    local files=( "$exp_dir"/runs/run_*/per_run.json )
    if [[ ! -e "${files[0]:-}" ]]; then
        echo "[]" > "$out"
        echo "WARNING [write-run-manifest]: no per_run.json files found in $exp_dir/runs/" >&2
        return 0
    fi

    jq -s 'sort_by(.run_id)' "${files[@]}" > "$out"
    echo "[write-run-manifest] $(jq 'length' "$out") run(s) in $out"
    return 0
}
