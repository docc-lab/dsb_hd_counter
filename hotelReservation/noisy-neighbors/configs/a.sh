#!/bin/bash

# Usage:
# ./a.sh "EXPERIMENT_NAME='name'" "CONTENTION_BURSTS=\$(burst ...)" "WRK2_RATE=200" "WRK2_THREADS=3" "WRK2_CONNECTIONS=3"

set -e

########################################
# Check arguments
########################################
if [ "$#" -lt 2 ] || [ "$#" -gt 5 ]; then
    echo "Usage: $0 \"EXPERIMENT_NAME='name'\" \"CONTENTION_BURSTS=\$(...)\" [\"WRK2_RATE=200\"] [\"WRK2_THREADS=3\"] [\"WRK2_CONNECTIONS=3\"]"
    exit 1
fi

NEW_EXPERIMENT="$1"
NEW_BURSTS="$2"
NEW_WRK2_RATE="${3:-}"
NEW_WRK2_THREADS="${4:-}"
NEW_WRK2_CONNECTIONS="${5:-}"

########################################
# Files
########################################
TEMPLATE="test.conf"

# extract experiment name for filename
EXP_NAME=$(echo "$NEW_EXPERIMENT" | sed -E "s/EXPERIMENT_NAME='([^']+)'/\1/")

OUTPUT="${EXP_NAME}.conf"

########################################
# Copy template
########################################
cp "$TEMPLATE" "$OUTPUT"

########################################
# Patch fields
########################################

# replace experiment name
sed -i "s|^EXPERIMENT_NAME=.*|$NEW_EXPERIMENT|" "$OUTPUT"

# replace contention bursts
sed -i "s|^CONTENTION_BURSTS=.*|$NEW_BURSTS|" "$OUTPUT"

# replace wrk2 settings if provided
if [ -n "$NEW_WRK2_RATE" ]; then
    sed -i "s|^WRK2_RATE=.*|$NEW_WRK2_RATE|" "$OUTPUT"
fi

if [ -n "$NEW_WRK2_THREADS" ]; then
    sed -i "s|^WRK2_THREADS=.*|$NEW_WRK2_THREADS|" "$OUTPUT"
fi

if [ -n "$NEW_WRK2_CONNECTIONS" ]; then
    sed -i "s|^WRK2_CONNECTIONS=.*|$NEW_WRK2_CONNECTIONS|" "$OUTPUT"
fi

chmod +x "$OUTPUT"

echo "✅ Created $OUTPUT"
