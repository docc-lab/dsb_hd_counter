#!/usr/bin/env python3
"""
make_phases.py — build the analyzer's phases file from stage3-eval run
directories (each records started_epoch_ns.txt / ended_epoch_ns.txt).

Each --phase argument is NAME:RANK:RUN_DIR, in schedule order. RANK
encodes expected contention ordering (0 = no aggressors); the analyzer
checks that phase-mean scores are ordered by rank across adjacent
phases.

Example (5-phase schedule realized as 5 harness runs):

  python3 make_phases.py \
      --phase baseline:0:expA/runs/run_1 \
      --phase moderate-up:1:expB/runs/run_1 \
      --phase severe:2:expC/runs/run_1 \
      --phase moderate-down:1:expD/runs/run_1 \
      --phase off:0:expE/runs/run_1 \
      --out phases.yaml

  cat exp{A,B,C,D,E}/runs/run_1/score_events.log > scores.log
  python3 verify_score_tracking.py --scores scores.log --phases phases.yaml

The output is JSON text (valid YAML too), so it loads with or without
PyYAML installed.
"""
import argparse
import json
import os
import sys


def read_ns(run_dir, fname):
    path = os.path.join(run_dir, fname)
    try:
        return int(open(path).read().strip())
    except (OSError, ValueError) as e:
        sys.exit(f"{path}: {e}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", action="append", required=True,
                    metavar="NAME:RANK:RUN_DIR",
                    help="repeatable, in schedule order")
    ap.add_argument("--out", default="phases.yaml")
    args = ap.parse_args()

    phases, last_end = [], None
    for spec in args.phase:
        try:
            name, rank, run_dir = spec.split(":", 2)
        except ValueError:
            sys.exit(f"bad --phase {spec!r}: want NAME:RANK:RUN_DIR")
        start = read_ns(run_dir, "started_epoch_ns.txt") / 1e9
        last_end = read_ns(run_dir, "ended_epoch_ns.txt") / 1e9
        phases.append({"name": name, "rank": int(rank), "start": start})

    doc = {"phases": phases, "end": last_end}
    with open(args.out, "w") as f:
        json.dump(doc, f, indent=2)
    print(f"wrote {args.out}: {len(phases)} phases, "
          f"{phases[0]['start']:.0f} .. {last_end:.0f}")


if __name__ == "__main__":
    main()
