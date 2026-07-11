#!/usr/bin/env python3
"""Count pinned score events (y50 > 0.9 after smoother warmup) in a
stage3-eval experiment dir's run_1 score log.

Usage: ap_ybad.py <exp_dir_with_trailing_slash>
Prints the pinned count, or 9999 if the log is missing/short (so the
caller treats capture failures as dirty, never as clean).
"""
import re
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")
KV = re.compile(r"(\w+)=(\S+)")

ys = []
try:
    for line in open(sys.argv[1].rstrip('/') + '/runs/run_1/score_events.log'):
        line = ANSI.sub('', line)
        if 'score_event' not in line:
            continue
        ys.append(float(dict(KV.findall(line)).get('y50_current', 0)))
except Exception:
    pass
print(sum(1 for y in ys[50:] if y > 0.9) if len(ys) > 500 else 9999)
