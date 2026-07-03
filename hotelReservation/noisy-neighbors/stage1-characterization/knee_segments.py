#!/usr/bin/env python3
"""
Detect the knee from a coarse-pass curve.csv and emit a progressive-fineness
SATURATION_SEGMENTS schedule centered on it (coarse far from the knee, finest
through the elbow, coarse tail past saturation).

Knee rule (interceptor-based, matching curve_aggregate.py's svc-derived
`saturated` column): K = target_rps of the LAST non-saturated level that also
actually received its offered load (arrival_rps_mean >= 0.85 * target, so a
loadgen-capped level can't masquerade as the knee).

Exit codes:
  0  knee found; segments printed on stdout (and conf updated with --write-conf)
  2  no saturated level in the sweep -> knee is above the ceiling; prints a
     suggested higher coarse schedule on stdout instead
  3  input/parse errors

Usage:
  knee_segments.py <exp_dir> [--knee-step 20] [--write-conf <conf_file>]
"""
import csv
import os
import re
import sys


def r(x, base):
    """Round x to the nearest multiple of base (min one base)."""
    return max(base, int(round(x / base)) * base)


def build_segments(k, knee_step):
    """Progressive-fineness schedule centered on knee K (target-RPS space).

    Template (matches RERUN-PLAN-search-curve.md, illustrated for K~3000):
      100-2400:300  2400-2790:100  2790-3210:20  3210-4200:250
       far: K/10     approach:K/30    knee band     tail: K/12
    """
    a = r(0.80 * k, 100)            # far/approach boundary
    b = r(0.93 * k, 10)             # approach/knee-band boundary
    c = r(1.07 * k, 10)             # knee-band/tail boundary
    d = r(1.40 * k, 100)            # sweep ceiling
    far_step = r(k / 10.0, 100)
    app_step = r(k / 30.0, 10)
    tail_step = r(k / 12.0, 50)

    # Keep boundaries strictly ordered even for small K.
    a = max(200, min(a, b - app_step))
    segs = []
    if a > 100:
        segs.append("100-%d:%d" % (a, far_step))
    segs.append("%d-%d:%d" % (a, b, app_step))
    segs.append("%d-%d:%d" % (b, c, knee_step))
    segs.append("%d-%d:%d" % (c, d, tail_step))
    return " ".join(segs)


def count_levels(segments):
    n = 0
    seen = set()
    for seg in segments.split():
        m = re.match(r"^(\d+)-(\d+):(\d+)$", seg)
        if not m:
            continue
        lo, hi, step = map(int, m.groups())
        v = lo
        while v <= hi:
            if v not in seen:
                seen.add(v)
                n += 1
            v += step
    return n


def write_conf(conf_path, segments, note):
    with open(conf_path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    new_line = "SATURATION_SEGMENTS=\"${SATURATION_SEGMENTS:-%s}\"  # %s" % (segments, note)
    replaced = False
    for i, line in enumerate(lines):
        if re.match(r"^\s*SATURATION_SEGMENTS=", line):
            lines[i] = new_line
            replaced = True
            break
    if not replaced:
        sys.stderr.write("ERROR: no SATURATION_SEGMENTS= line in %s\n" % conf_path)
        return False
    with open(conf_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
    return True


def main():
    args = list(sys.argv[1:])
    knee_step = 20
    conf = None
    if "--knee-step" in args:
        i = args.index("--knee-step"); knee_step = int(args[i + 1]); del args[i:i + 2]
    if "--write-conf" in args:
        i = args.index("--write-conf"); conf = args[i + 1]; del args[i:i + 2]
    if not args:
        sys.exit("usage: knee_segments.py <exp_dir> [--knee-step 20] [--write-conf <conf>]")
    exp = args[0]

    csv_path = os.path.join(exp, "curve.csv")
    try:
        rows = list(csv.DictReader(open(csv_path)))
    except OSError as e:
        sys.stderr.write("ERROR: cannot read %s: %s\n" % (csv_path, e))
        sys.exit(3)
    if not rows:
        sys.stderr.write("ERROR: empty curve.csv\n")
        sys.exit(3)

    knee = None
    ceiling = 0
    any_saturated = False
    for row in rows:
        try:
            tgt = float(row["target_rps"])
            arr = float(row["arrival_rps_mean"])
            sat = row["saturated"].strip().lower() == "true"
        except (KeyError, ValueError):
            continue
        ceiling = max(ceiling, tgt)
        if sat:
            any_saturated = True
        elif arr >= 0.85 * tgt:
            # last non-saturated, delivery-verified level so far
            if knee is None or tgt > knee:
                knee = tgt

    if not any_saturated:
        # Knee above the ceiling: suggest a taller coarse pass.
        new_hi = int(ceiling * 2)
        step = r(new_hi / 18.0, 50)
        suggestion = "100-%d:%d" % (new_hi, step)
        sys.stderr.write(
            "NO KNEE: nothing saturated up to %.0f RPS (svc_p99 never crossed "
            "threshold x baseline). Raise the ceiling and re-run the coarse "
            "pass. Suggested coarse segments:\n" % ceiling)
        print(suggestion)
        sys.exit(2)

    if knee is None:
        sys.stderr.write(
            "ERROR: every level was saturated or delivery-capped -- the sweep "
            "started past the knee. Lower the start / raise loadgen capacity.\n")
        sys.exit(3)

    segments = build_segments(knee, knee_step)
    n = count_levels(segments)
    sys.stderr.write("knee K=%.0f RPS -> %d levels (~%d min at ~60s/level)\n"
                     % (knee, n, n))
    print(segments)

    if conf:
        note = "auto-tuned: knee~%.0f rps (%s)" % (knee, os.path.basename(exp.rstrip("/\\")))
        if not write_conf(conf, segments, note):
            sys.exit(3)
        sys.stderr.write("wrote SATURATION_SEGMENTS into %s\n" % conf)


if __name__ == "__main__":
    main()
