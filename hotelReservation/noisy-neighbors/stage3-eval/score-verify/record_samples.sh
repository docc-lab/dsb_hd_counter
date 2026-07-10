#!/bin/bash
# record_samples.sh — subscribe to a pod's InstrumentationStream (:7901)
# and append one JSON object per Sample to an NDJSON file. The raw-sample
# sibling of record_scores.sh; used to calibrate the Gordion curve and
# baseline from live traffic (see calibrate_from_stream.py).
#
# Usage:
#   ./record_samples.sh <addr:port> <out.ndjson> [duration_seconds]
#   ./record_samples.sh localhost:7901 rate_2400.ndjson 120
#
# Requires: grpcurl, jq.
set -euo pipefail

ADDR="${1:?usage: record_samples.sh <addr:port> <out.ndjson> [duration_s]}"
OUT="${2:?usage: record_samples.sh <addr:port> <out.ndjson> [duration_s]}"
DURATION="${3:-0}"

command -v grpcurl >/dev/null || { echo "grpcurl not found" >&2; exit 1; }
command -v jq      >/dev/null || { echo "jq not found" >&2; exit 1; }

echo "recording Samples from $ADDR -> $OUT (duration: ${DURATION}s; 0 = until Ctrl-C)" >&2

# Truncate: a stale file from an earlier run must never leak into this
# capture (level files feed calibration; contamination corrupts it).
: > "$OUT"

# The timeout wraps grpcurl ITSELF (not a bash wrapper): when grpcurl
# dies, jq reads EOF and the whole pipeline exits. Wrapping in bash -c
# orphans the pipeline past the timeout, and the orphan keeps appending
# while later captures run -- which silently blends levels together.
if [[ "$DURATION" -gt 0 ]]; then
    timeout --foreground "${DURATION}s" \
        grpcurl -plaintext -d '{}' "$ADDR" gordion.instrumentation.InstrumentationStream/Subscribe \
        | jq -c --unbuffered '.' >> "$OUT" || true
else
    grpcurl -plaintext -d '{}' "$ADDR" gordion.instrumentation.InstrumentationStream/Subscribe \
        | jq -c --unbuffered '.' >> "$OUT"
fi

echo "recorded $(wc -l < "$OUT") samples into $OUT" >&2
