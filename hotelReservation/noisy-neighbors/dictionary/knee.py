#!/usr/bin/env python3
"""Knee of an exploratory sweep from hrgen's wlgen.jsonl (stdlib only, runs on node-0).

The knee is the first step whose caller p50 exceeds twice the p50 of the lowest step, or
whose served rate falls below 95% of the target, or that returns errors; printed as the
previous step's rate (the last clean step). Falls back to the highest step.
Usage: knee.py RUN_DIR/wlgen.jsonl [RUN_DIR2/wlgen.jsonl ...]
"""
import json
import sys
from collections import defaultdict

steps = {}
by = defaultdict(list)
for path in sys.argv[1:]:
    for line in open(path):
        r = json.loads(line)
        if r.get("event") == "step" and r["step"] >= 0:
            steps[(path, r["step"])] = r["rate"]
        elif "event" not in r and r.get("step", -9) >= 0:
            by[(path, r["step"])].append(r)


def med(v):
    v = sorted(v)
    return v[len(v) // 2] if v else 0


rows = []
for key in sorted(by, key=lambda k: steps.get(k, 0)):
    rs = by[key][3:]
    if not rs or key not in steps:
        continue
    done = sum(r["all"][0] for r in rs) / len(rs)
    p50 = med([r["all"][1] for r in rs]) / 1e6
    errs = sum(sum(v[4] for v in r["ep"].values()) for r in rs)
    rows.append((steps[key], done, p50, errs))
rows.sort()
base = min(r[2] for r in rows)
knee = rows[-1][0]
for i, (rate, done, p50, errs) in enumerate(rows):
    print(f"# {rate:6.0f} req/s: served {done:6.0f}/s p50 {p50:6.2f} ms errs {errs}", file=sys.stderr)
    if p50 > 2 * base or done < 0.95 * rate or errs > 0:
        knee = rows[i - 1][0] if i > 0 else rate
        break
print(int(knee))
