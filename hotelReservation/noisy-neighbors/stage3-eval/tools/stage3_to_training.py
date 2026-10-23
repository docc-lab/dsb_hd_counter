#!/usr/bin/env python3
"""stage3_to_training.py -- stage-3 run dirs -> the predictor trainer's input layout.

The GRU trainer chain (origin/master hotelReservation/noisy-neighbors/
contention_scoring/postprocess2.py -> act_func_label2.py -> ml_training_deployment/
gru_train.py) scans  <Data>/*/raw/windowed/<service>/run_data_iter[1-3].json .
Stage 3 writes the same windowed-sampler dump as runs/run_1/run_data.json, but
it covers the pod's whole lifetime and lacks offset_from_workload_ms. This
script mirrors data-collector.sh's post-processing for every stage3eval_* dir
found under the given paths:

  * keep the samples whose timestamp lies in [started_epoch_ns, ended_epoch_ns]
  * add offset_from_workload_ms (ms since the run's t0)
  * keep zero-request windows (postprocess2.filter_zero_request_samples drops
    them later, as in stage 2)
  * record the stage-3 context (config name, aggressor pool, contention onset)
    in a `stage3` block that the trainer ignores

Output: <out>/<exp_dir>/raw/windowed/<service>/run_data_iter1.json where
exp_dir = exp_<config name>_<stage3eval id>. Point postprocess2 at <out>.

  python3 tools/stage3_to_training.py --out ../Data-stage3 data/collect-smt data/sweep-none
"""
import argparse
import datetime
import glob
import json
import os
import re
import sys


def ts_epoch(s):
    s = re.sub(r"\.(\d{6})\d+", r".\1", s).replace("Z", "+00:00")
    return datetime.datetime.fromisoformat(s).timestamp()


def run_dirs(paths):
    for p in paths:
        if os.path.isfile(os.path.join(p, "input.yaml")):
            yield p
        else:
            for d in sorted(glob.glob(os.path.join(p, "**", "stage3eval_*"), recursive=True)):
                if os.path.isfile(os.path.join(d, "input.yaml")):
                    yield d


def yaml_scalar(path, key):
    """First `key: value` line of a (simple) YAML file, or None."""
    try:
        for line in open(path):
            m = re.match(r"\s*%s:\s*(.+?)\s*(#.*)?$" % re.escape(key), line)
            if m:
                return m.group(1).strip().strip('"')
    except OSError:
        pass
    return None


def contention_onset_s(input_yaml):
    """Earliest start_offset_s of any aggressor driver or `extra` block."""
    try:
        txt = open(input_yaml).read()
    except OSError:
        return None
    offs = [int(x) for x in re.findall(r"start_offset_s:\s*(\d+)", txt)]
    return min(offs) if offs else None


def convert(d, out_root, service):
    run = os.path.join(d, "runs", "run_1")
    src = os.path.join(run, "run_data.json")
    if not os.path.isfile(src):
        return None, "no run_data.json"
    j = json.load(open(src))
    if j.get("service_name") not in (None, service):
        return None, "service %s != %s" % (j.get("service_name"), service)
    t0 = int(open(os.path.join(run, "started_epoch_ns.txt")).read()) / 1e9
    t1 = int(open(os.path.join(run, "ended_epoch_ns.txt")).read()) / 1e9

    kept = []
    for s in j["samples"]:
        t = ts_epoch(s["timestamp"])
        if t0 <= t <= t1:
            s = dict(s)
            s["offset_from_workload_ms"] = int(round((t - t0) * 1000))
            kept.append(s)
    if not kept:
        return None, "no samples inside the run window"

    name = yaml_scalar(os.path.join(d, "input.yaml"), "name") or os.path.basename(d)
    pool = None
    for cand in (os.path.join(d, "..", "aggr_cpuset.txt"),
                 os.path.join(run, "mitigation", "aggr_cpuset.txt")):
        if os.path.isfile(cand):
            pool = open(cand).read().strip()
            break
    with_timing = sum(1 for s in kept if (s.get("timing_window") or {}).get("request_count", 0) > 0)
    out = {
        "service_name": j.get("service_name", service),
        "iteration_id": 1,
        "run_start": j.get("run_start"),
        "run_end": j.get("run_end"),
        "run_duration_ms": int(round((t1 - t0) * 1000)),
        "window_interval_ms": j.get("window_interval_ms", 100),
        "perf_events": j.get("perf_events"),
        "filtering": {
            "applied": True,
            "method": "timestamp in [started_epoch_ns, ended_epoch_ns]",
            "offset_start_ms": int(round((t0 - ts_epoch(j["run_start"])) * 1000)) if j.get("run_start") else None,
            "offset_end_ms": int(round((t1 - ts_epoch(j["run_start"])) * 1000)) if j.get("run_start") else None,
            "rationale": "stage-3 run window; offset_from_workload_ms = ms since the run's t0",
        },
        "stage3": {
            "config_name": name,
            "run_dir": os.path.abspath(d),
            "aggressor_cpuset": pool,
            "contention_onset_s": contention_onset_s(os.path.join(d, "input.yaml")),
            "arm": (open(os.path.join(run, "mitigation", "arm.txt")).read().strip()
                    if os.path.isfile(os.path.join(run, "mitigation", "arm.txt")) else None),
        },
        "samples": kept,
        "sample_count": len(kept),
        "samples_with_timing": with_timing,
        "samples_idle": len(kept) - with_timing,
        "aggregates": j.get("aggregates"),
    }
    exp_dir = "exp_%s_%s" % (name, os.path.basename(d).replace("stage3eval_", ""))
    dst_dir = os.path.join(out_root, exp_dir, "raw", "windowed", service)
    os.makedirs(dst_dir, exist_ok=True)
    dst = os.path.join(dst_dir, "run_data_iter1.json")
    with open(dst, "w") as f:
        json.dump(out, f)
    return dst, "%d windows (%d with requests), %.0f s" % (len(kept), with_timing, t1 - t0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+", help="run dirs or dirs containing stage3eval_* (searched recursively)")
    ap.add_argument("--out", required=True, help="trainer Data directory to write into")
    ap.add_argument("--service", default="search")
    args = ap.parse_args()
    n = 0
    for d in run_dirs(args.paths):
        dst, msg = convert(d, args.out, args.service)
        tag = "ok  " if dst else "skip"
        print("%s %-40s %s" % (tag, os.path.relpath(d), msg))
        n += bool(dst)
    print("wrote %d files under %s" % (n, args.out))
    return 0 if n else 1


if __name__ == "__main__":
    sys.exit(main())
