#!/bin/bash
# Script to collect system metadata into a JSON file

OUTPUT_FILE="system_metadata.json"

# Run the Python script and redirect output to JSON file
python3 metadata_collector.py > "$OUTPUT_FILE"

echo "System metadata saved to $OUTPUT_FILE"
