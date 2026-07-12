#!/usr/bin/env python3
"""Count spike windows in /tmp/sweep_probe.ndjson for BOTH sections.

Prints: "<proc_spikes> <blocking_spikes> <total_windows>"
(-1 -1 0 if the capture is too short to judge.)
"""
import json

pn = bn = t = 0
for line in open('/tmp/sweep_probe.ndjson'):
    try:
        s = json.loads(line)
    except Exception:
        continue
    tw = s.get('timingWindow') or {}
    pp = int((tw.get('processingTime') or {}).get('p50Ns') or 0)
    bp = int((tw.get('blockingTime') or {}).get('p50Ns') or 0)
    if pp > 0:
        t += 1
        if pp > 1_000_000:
            pn += 1
        if bp > 1_000_000:
            bn += 1
print(f"{pn} {bn} {t}" if t > 200 else "-1 -1 0")
