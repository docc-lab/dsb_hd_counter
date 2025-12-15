#!/bin/bash
# Simple test script for the CPU cycle counter
# Usage: ./test_cycle_counter.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CYCLE_COUNTER_SOURCE="$SCRIPT_DIR/cycle_counter.c"
CYCLE_COUNTER_BIN="$SCRIPT_DIR/cycle_counter"
TEST_DIR="$SCRIPT_DIR/cycle_test_$$"

echo "=== CPU Cycle Counter Test ==="
echo ""

# Clean up any existing binary
if [[ -f "$CYCLE_COUNTER_BIN" ]]; then
    echo "Removing existing binary..."
    rm -f "$CYCLE_COUNTER_BIN"
fi

# Compile
echo "Compiling cycle counter..."
if gcc -O2 -o "$CYCLE_COUNTER_BIN" "$CYCLE_COUNTER_SOURCE" -pthread; then
    echo "✓ Compilation successful"
else
    echo "✗ Compilation failed"
    exit 1
fi

# Create test directory
mkdir -p "$TEST_DIR"
echo "Test directory: $TEST_DIR"
echo ""

# Test 1: Single measurement
echo "Test 1: Single measurement"
if "$CYCLE_COUNTER_BIN" 0 "$TEST_DIR/test1.txt"; then
    echo "✓ Measurement successful"
    cat "$TEST_DIR/test1.txt"
    echo ""
else
    echo "✗ Measurement failed"
    exit 1
fi

# Test 2: Start/End pair simulation
echo "Test 2: Simulating iteration measurement"
echo "  Taking start measurement..."
"$CYCLE_COUNTER_BIN" 0 "$TEST_DIR/start.txt"
START_CYCLES=$(cut -d',' -f1 "$TEST_DIR/start.txt")
START_FREQ=$(cut -d',' -f2 "$TEST_DIR/start.txt")
echo "  Start cycles: $START_CYCLES (freq: ${START_FREQ} MHz)"

echo "  Sleeping for 2 seconds..."
sleep 2

echo "  Taking end measurement..."
"$CYCLE_COUNTER_BIN" 0 "$TEST_DIR/end.txt"
END_CYCLES=$(cut -d',' -f1 "$TEST_DIR/end.txt")
END_FREQ=$(cut -d',' -f2 "$TEST_DIR/end.txt")
echo "  End cycles: $END_CYCLES (freq: ${END_FREQ} MHz)"

# Calculate delta
DELTA=$((END_CYCLES - START_CYCLES))
AVG_FREQ=$(awk "BEGIN {printf \"%.2f\", ($START_FREQ + $END_FREQ) / 2}")
EXPECTED_CYCLES=$(awk "BEGIN {printf \"%.0f\", $AVG_FREQ * 1000000 * 2}")  # 2 seconds
# Calculate absolute deviation (awk may not have abs function)
DEVIATION=$(awk "BEGIN {
    diff = ($DELTA - $EXPECTED_CYCLES) / $EXPECTED_CYCLES * 100;
    printf \"%.1f\", (diff < 0) ? -diff : diff
}")

echo ""
echo "Results:"
echo "  Cycle delta: $DELTA"
echo "  Average frequency: ${AVG_FREQ} MHz"
echo "  Expected cycles (2s): $EXPECTED_CYCLES"
echo "  Deviation: ${DEVIATION}%"

# Check if deviation is reasonable (< 10%)
if (( $(awk "BEGIN {print ($DEVIATION < 10) ? 1 : 0}") )); then
    echo "  ✓ Deviation within acceptable range"
else
    echo "  ⚠ Deviation higher than expected (may indicate frequency scaling)"
fi

echo ""
echo "=== Test Complete ==="
echo "Test files saved in: $TEST_DIR"
echo ""
echo "To clean up:"
echo "  rm -rf $TEST_DIR"
echo "  rm -f $CYCLE_COUNTER_BIN"

