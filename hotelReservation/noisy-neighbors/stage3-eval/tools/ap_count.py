#!/usr/bin/env python3
"""Count spike windows (proc p50 > 1ms) in /tmp/ap_probe.ndjson.

Prints the spike count, or -1 if the probe captured too few windows to
be a valid sample (< 200). Used by autopilot.sh as its activity gate.
"""
import json

n = t = 0
for line in open('/tmp/ap_probe.ndjson'):
    try:
        s = json.loads(line)
    except Exception:
        continue
    p = int(((s.get('timingWindow') or {}).get('processingTime') or {}).get('p50Ns') or 0)
    if p > 0:
        t += 1
        if p > 1_000_000:
            n += 1
print(n if t > 200 else -1)
