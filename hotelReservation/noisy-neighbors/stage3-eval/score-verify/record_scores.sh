#!/bin/bash
# record_scores.sh — subscribe to a pod's ContentionStream (:7900) and
# append one JSON object per ScoreEvent to an NDJSON file, stamped with
# the recorder's receive time.
#
# The server has gRPC reflection registered, so grpcurl needs no proto
# files. Works against a cluster-internal address or a local
# `kubectl port-forward <pod> 7900:7900`.
#
# Usage:
#   ./record_scores.sh <addr:port> <out.ndjson> [duration_seconds]
#
#   ./record_scores.sh localhost:7900 scores.ndjson          # until Ctrl-C
#   ./record_scores.sh 10.0.3.12:7900 scores.ndjson 1200     # 20 min
#
# Requires: grpcurl, jq.
set -euo pipefail

ADDR="${1:?usage: record_scores.sh <addr:port> <out.ndjson> [duration_s]}"
OUT="${2:?usage: record_scores.sh <addr:port> <out.ndjson> [duration_s]}"
DURATION="${3:-0}"

command -v grpcurl >/dev/null || { echo "grpcurl not found" >&2; exit 1; }
command -v jq      >/dev/null || { echo "jq not found" >&2; exit 1; }

# grpcurl pretty-prints each streamed message; jq -c re-flattens to one
# line per event and stamps the local receive time. --unbuffered so
# events land in the file as they arrive, not on pipe-buffer flushes.
#
# The timeout wraps grpcurl ITSELF: when it dies, jq reads EOF and the
# pipeline exits. (A bash -c wrapper orphans the pipeline past the
# timeout and it keeps appending into the file -- observed corrupting
# multi-capture sessions.)
echo "recording ScoreEvents from $ADDR -> $OUT (duration: ${DURATION}s; 0 = until Ctrl-C)" >&2

if [[ "$DURATION" -gt 0 ]]; then
    timeout --foreground "${DURATION}s" \
        grpcurl -plaintext -d '{}' "$ADDR" gordion.contention.ContentionStream/Subscribe \
        | jq -c --unbuffered '. + {recv_unix_ns: (now * 1e9 | floor)}' >> "$OUT" || true
else
    grpcurl -plaintext -d '{}' "$ADDR" gordion.contention.ContentionStream/Subscribe \
        | jq -c --unbuffered '. + {recv_unix_ns: (now * 1e9 | floor)}' >> "$OUT"
fi

echo "recorded $(wc -l < "$OUT") events into $OUT" >&2
