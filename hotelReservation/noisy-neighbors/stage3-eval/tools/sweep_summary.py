#!/usr/bin/env python3
"""Aggregate /tmp/param_sweep.log into per-arm spike-rate statistics."""
import re
from collections import defaultdict

pat = re.compile(r'arm=(\S+) proc_spikes=(-?\d+) blocking_spikes=(-?\d+) windows=(\d+)')
arms = defaultdict(lambda: {'cycles': 0, 'proc': 0, 'blk': 0, 'win': 0, 'spiky_cycles': 0})
for line in open('/tmp/param_sweep.log'):
    m = pat.search(line)
    if not m:
        continue
    a, p, b, w = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))
    if p < 0 or w == 0:
        continue
    d = arms[a]
    d['cycles'] += 1
    d['proc'] += p
    d['blk'] += b
    d['win'] += w
    if p > 0:
        d['spiky_cycles'] += 1

print(f"{'arm':<12} {'cycles':>6} {'spiky':>6} {'proc/1k win':>12} {'blk/1k win':>11}")
for a, d in sorted(arms.items()):
    if d['win'] == 0:
        continue
    print(f"{a:<12} {d['cycles']:>6} {d['spiky_cycles']:>6} "
          f"{1000*d['proc']/d['win']:>12.2f} {1000*d['blk']/d['win']:>11.2f}")
print("\nread: equal proc rates across arms -> environment, not parameters;")
print("      fixed_heavy >> fixed_cheap -> parameter-dependent; blk~0 -> DB out.")
