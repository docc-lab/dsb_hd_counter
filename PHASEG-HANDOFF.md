# Phase G handoff — the three-signal scorer: validation and implementation

Companion to the Project doc `claude/validation-plan-three-signal.md` (the living plan; this file is the executable
spec for the agent) and the artifact "Three-Signal Design" (five figures). Phases C–F: `RESULTS-C.md` … `RESULTS-F.md`.
Everything in PHASED §6, PHASEE §0 and PHASEF §0 still holds: D[ρ; mix] = F̄ + h(ρ)·K, F̄ the mixture median,
ρ = λc̄ ÷ (f/f_nom) ÷ k, one FIFO line (M/G/1), wait guard off when W_max < 3× floor noise, 5 s smoothing, gate as
experimental apparatus, vocabulary aggressor / scenario / c̄ / c̄² / service dictionary.

## 0. What Phase G adds, and the decisions already taken

The dictionary stays the no-neighbor baseline. The residual E = Lat − D is no longer one label; it is explained by
signals that are measured, not inferred:

| symbol | definition | source |
|---|---|---|
| E | Lat − D[ρ; mix], pooled p50 per window | existing |
| R_foreign, R_self | run-queue delay of the service's threads (runnable → running gap), split by the cgroup of the task that ran on that CPU in between | **new** eBPF probe on `sched_switch` |
| I | U ÷ ρ_offered: CPU seconds burned by the service's cgroup per window ÷ (λ·c̄ ÷ (f/f_nom)) per window | measured U (new or from the existing `cpu` field, see §1) + existing ρ |
| G | GC pause time per window | `runtime/metrics` (Go) |
| Q | runtime or lock wait: goroutine runnable with no P free, or asleep on a mutex / channel | Go: `runtime/metrics` `/sched/latencies:seconds`, `/sync/mutex/wait/total:seconds`; C++: eBPF, `prev_state` sleeping on switch-out |

Verdict rows (origin axis; the slowness axis y is unchanged):
1. R_foreign ≫ 0 → extrinsic, attributable to the holder cgroup
2. E ≫ 0, R_foreign ≈ 0, I ≈ 1, Q ≈ 0, slot busy ≈ 1 → intrinsic overload (own queue past the profile); replaces today's n/a
3. E ≫ 0, R_foreign ≈ 0, I ≫ 1 → shared resource (neighbor or self; not resolvable without a per-cgroup cache counter)
4. E ≫ 0, R_foreign ≈ 0, I ≈ 1, Q ≫ 0 → runtime or lock wait: intrinsic, not overload
5. G ≫ 0 → GC, its own term
6. E ≈ 0 → nothing to explain

Decisions already taken (do not reopen):
- Time blocked on downstream / datastore calls stays excluded from Lat (interceptor markers) and is not a segment.
- Time before the tap (accept queue, network stack) is out of scope.
- Tail: no tail dictionary. The requests above p95 are decomposed into measured components; the tail verdict is the
  dominant component as a share of slow requests.
- `util` in today's `b4_windows.csv` is ρ ÷ k, a computed number, not a measurement. Do not use it as U.

Terms: run-queue delay is the kernel's (thread runnable, not running). "Scheduling latency" is Go's word for a goroutine
waiting for a P; call that runtime wait. Never "hog" in prose; run names may keep it.

## 1. G1 — analysis only, no cluster time. Stop and report after this section.

1.1 **Find U.** `gordion.jsonl` carries a per-second `cpu` field (e.g. `"cpu":2823000`). Establish its unit and whether it
is cumulative or per interval from the recorder source (`workflow/bigsvc`, the interceptor's stats emitter), not by
guessing; cross-check one run against the pod's `cpu.stat` or `/proc/<pid>/stat` if either was captured. Write the
finding, with the code line, at the top of RESULTS-G.md. If `cpu` is process CPU time, U = Δcpu ÷ Δt ÷ |cpuset|;
otherwise say what is missing and stop at 1.1.

1.2 **I on the twins.** For every unstressed sweep and twin run from Phases C–F (synthetic, post-storage, HR frontend,
reservation, geo, recommendation): I = U ÷ ρ per window, smoothed as Lat is (5 s). Table: service × step → median I,
IQR. Flag the lowest step separately; the wake-up effect is expected to put it above 1. Plot I against ρ per service,
one panel per service, twins only. Claim C1: I ≈ 1 within the per-step IQR, lowest step excluded.

1.3 **I under one aggressor.** Same for every stressed run that has a twin (synthetic mix shifts, HR recommendation
stepped past the knee, one aggressor per core). Expected: I stays near 1 (stress-ng matrixprod is a time-slicer).
If I rises with the aggressor, report it as the first sign of cache pressure, with the number; do not interpret further.

1.4 **Collapse windows.** Re-score the geo and recommendation collapse windows with slot busy and I. Do they fit row 2
(I ≈ 1, slot busy ≈ 1, R unknown yet)? Report the share that would.

1.5 **p90 collapse check.** Recompute the W ÷ K collapse (Phase E, `e1_mix.csv`) with p90 in place of p50 on the four
synthetic mixes. One figure, same layout as F3. Verdict: does W90 ÷ K collapse across mixes or not. This decides
whether a p90 dictionary is a candidate at all.

1.6 **Thresholds.** From the twins: ≈ means within the per-step IQR of the unstressed run; ≫ means beyond 3× it.
Write the numbers per service. They are provisional until G2.

Deliverables: RESULTS-G.md §1 with the U finding, the I tables, two figures (I vs ρ on twins; p90 collapse), and the
threshold table. Then **stop**; I decide whether G2 proceeds and on which node.

## 2. G2 — the probe, its overhead, and the re-runs (cluster)

2.1 **Where it runs.** The service is a pod on the service node (cpuset in `meta.json`, e.g. `2-5`); the aggressor is
`stress-ng` on the host, pinned by `scripts/stressor.sh`. The probe runs on the host, outside the pod. First, record
`uname -r`, cgroup version, `/sys/kernel/btf/vmlinux` presence, and whether `bpftrace` / `libbpf` are installable, in
RESULTS-G.md. If BTF is missing, say what the fallback is (kprobe on `finish_task_switch` with a vmlinux header) before
building it.

2.2 **What it records.** On `sched_switch(prev, next)` for every CPU in the service's cpuset:
- when `next` belongs to the service's cgroup: if it was marked runnable at time t_r, add (now − t_r) to
  `R[holder]`, where holder is the cgroup id of the task(s) that ran on this CPU between t_r and now (credit by time
  share if more than one; the simplest correct version credits the last one and reports how often more than one ran);
- when `prev` belongs to the service's cgroup: if `prev_state` is runnable (preempted), mark t_r = now; if sleeping,
  mark t_s = now and on the next wake-up (`sched_wakeup`) add (wake − t_s) to `Q_sleep` — this is the C++ side of Q,
  and for Go it is a cross-check against `runtime/metrics`;
- a log2 histogram of the runnable gaps, for the tail.
Holder cgroups to name: the service's own (R_self), the aggressor's (stress-ng runs in the host's cgroup; give it one),
kernel threads, anything else (R_other, reported, never attributed).
Export once per 100 ms window to a file the collector picks up with `gordion.jsonl`, keyed by the same `t`. Add
`cpu.stat` `usage_usec` of the pod's cgroup to the same record so U no longer depends on the process counter.

2.3 **Overhead run.** Unstressed synthetic sweep, uniform mix, probe off then probe on, same node, same cpuset. Compare:
floor per endpoint, knee, CPU per request (cₑ), and the probe's own CPU (its thread, from `/proc`). Claim C6: ≤ ~2 % of
a core at the highest switch rate seen and no floor shift beyond noise. If it fails, switch to sampling (attach for one
window in N) and re-run the comparison once.

2.4 **Re-runs with the probe on.** In this order, each with its twin where a twin exists:
   a. synthetic, mix shift across the knee + 1 aggressor (Phase F row) — expect R_foreign tracks the aggressor's
      share, I ≈ 1;
   b. HR recommendation, 1 aggressor per core, stepped past the knee — the guard trade row; expect the abstained
      windows now land in row 1 or row 2 with the right split;
   c. a cache / bandwidth aggressor: `stress-ng --stream` or `--matrix-size` large, pinned to a core **not** in the
      service's cpuset but sharing its LLC — expect I ≫ 1, R_foreign ≈ 0 (claim C3);
   d. the Thrift C++ service with the p90-only contention — per-request rows (thread = request), tail component
      shares (claim C7).
Record Q in all of them. The synthetic service already has `VioMutex` (`gen/main.go`, `-violators`): if Q is below the
≈ threshold everywhere in a–d, run one uniform sweep with VioMutex at 10 % of the mix and show Q catches it (row 4,
claim C9); if Q is material anywhere in a–d, report where before running VioMutex.

2.5 **Confusion matrix.** Per scenario, the verdict row against twin-run truth (truth defined as in Phase F: twin or
unstressed sweep at the same step; served steps only). Add the row-level matrix to RESULTS-G.md and the per-step
figure in the F7 layout (stacked cells per step).

## 3. G3 — self-interference (cluster, after §2)

`VioMemWalk` with `BIGSVC_MEMWALK_MB` large (256 MB default; go to the LLC size × 2) gives a memory-heavy endpoint.
Build a mix shift from CPU-bound to 50 % VioMemWalk with no aggressor; profile cₑ, FLₑ at operating load as usual.
Measure I along the shift and the W ÷ K collapse. Report the bias: how far D[ρ; mix] under-predicts where the mix
interferes with itself, and whether I tracks it (claim C5). This is the stated-limit number for the paper.

## 4. G4 — the verdict replaces the guard (analysis, after §2)

Implement rows 1–6 in the scorer with the §1.6 thresholds; keep the OOR guard only for ρ outside the profiled range.
Re-score every row of the Phase F results table; add the pattern-verdict column beside cell accuracy and decomposition
accuracy (claim C8: no index row drops). Re-score the collapse windows: expected "intrinsic overload" against D(λ)'s
262 false extrinsic. Check the controller target: the cgroup named by R_foreign equals the aggressor's cgroup in every
§2.4 run.

## 5. G5 — tail (after §2)

Per-request component rows in the recorder: gate wait (direct), run delay while the request held a thread (from the
probe's per-thread series, joined by thread id and time), thread CPU delta vs cₑ. Go: record the M at handler entry and
exit; report how often they differ (bounds the proxy error). Minimum sample: requests above p95 per window needed for a
stable dominant-component share; propose the tail window length. Tail verdict shares on the §2.4 runs.

## 6. Deliverables and rules

- RESULTS-G.md with sections numbered as above, a deviations list (RESULTS-D §4 style), and every figure titled with the
  latency stream and the signal it shows.
- No CSV overwritten; new columns are appended (`U`, `I`, `R_foreign_ms`, `R_self_ms`, `R_other_ms`, `Q_ms`, `G_ms`,
  `slot_busy`), raw and smoothed both kept.
- The probe's source lives in `blueprint/examples/bigsvc/probe/` with a README stating kernel, BTF, cgroup layout, and
  the overhead number.
- Stop points: after §1; after §2.3 (overhead); after §2.4 (before §3–§5). Report at each.
- If something cannot be measured on this kernel (no BTF, no `sched_wakeup` tracepoint, no cgroup v2), say what it
  would take instead of building around it; I decide.

---

## Addendum A — decisions after G1 (Nov 10 review of RESULTS-G.md §1), and the amended §2

G1 is accepted as written. Three decisions, each "try this first; if it fails, fall back":

A.1 **I is marginal.** I = (U − U₀) ÷ ρ_offered, with U₀ the per-service base CPU: the intercept of the unstressed
sweep (the D₀ of the cost regression in `r3_costs.py`). Recompute the §1.6 bands on the marginal I; they should now sit
around 1. State in RESULTS-G.md that U₀ is elastic (idle-priority GC workers yield to an aggressor), so the marginal I
is biased low under an aggressor at low load. Fallback, only if the marginal I is not within ±0.05 of 1 on the twins
above the lowest step: keep the average form with per-step bands and say so. Once the probe exists (§2.1), add the
clean form, per-request thread CPU ÷ c̄, as a second column; it excludes background work by construction.

A.2 **Row 2 keeps slot busy ≈ 1.** On today's geo / recommendation collapse windows it says "not our overload", which is
the truth. Row 2 is validated instead on a genuine overload scenario (A.5 c). Fallback, only if no scenario makes the
slots busy with the gate on: replace the discriminator with the probe's R_self share and report why.

A.3 **D90 is a side track.** Analysis only, any time, never blocking the cluster work: D90 = F̄90 + h90(ρ)·K from the
existing sweeps (F̄90 the 0.9 quantile of the mixture, h90 = W90_sweep ÷ K), decomposition accuracy on the mix-shift
rows against p90 truth, inside the guard range. One table, one figure. If it does not score, say so and stop.

A.4 **Before any cluster run (analysis):** read the HR deployment manifests (hotelReservation, and the synthetic
service's) for `resources.limits.cpu`. Report per pod: limit or none. A CPU limit means CFS bandwidth throttling is the
leading explanation of the collapse (process idle, generator refused, recorder flush stretched to 500 ms).

A.5 **Amended §2 order.** Node facts (§2.1) first, RUNBOOK §17 read, every environment change logged there. Then:
   a. **Base-term run.** One unstressed step at operating load on the synthetic service and on HR recommendation, raw
      histograms off and w = 1000 ms, pod `cpu.stat` captured (`usage_usec`, `nr_periods`, `nr_throttled`,
      `throttled_usec`) every second from the host. Compare U₀ with the §1 intercept. If U₀ drops, the base is our
      instrumentation: report it as overhead and keep subtracting it. If the HR pod has a limit, also capture `cpu.stat`
      through one collapse step of the existing recommendation sweep; `nr_throttled` rising is the answer to A.4. If it
      is throttling, **stop and report**: the collapse rows are a configuration artifact and I decide whether they are
      re-run without the limit.
   b. Probe (§2.2) and overhead run (§2.3). **Stop and report** with the overhead number.
   c. Re-runs (§2.4) in this order: (i) synthetic mix shift across the knee + 1 aggressor; (ii) **overload scenario**
      for row 2: synthetic service, gate on, uniform mix, open-loop generator driven past the knee until slot busy ≈ 1
      — check the existing beyond-knee sweeps (`a2-uniform-k5`, `a5-*-stress`) for a usable step first; (iii) HR
      recommendation, one aggressor per core, past the knee; (iv) cache / bandwidth aggressor; (v) Thrift p90 case;
      (vi) VioMutex only if Q is below threshold in i–v. **Stop after c.**
   Everything else in §2–§6 stands. New columns: `U0`, `I_marg`, `I_req` (when available), `throttled_usec`.

---

## Addendum B — after the §2.3 stop point (Nov 10 evening review)

Accepted as reported: marginal I fails on the real services (per-request CPU is concave in load; the §1 intercepts were a
line through a curve); no CFS throttling anywhere (cpu.max unlimited, nr_throttled 0 through the 12 000 req/s collapse
step), so the collapse is in front of the tap and out of scope; the base CPU is the runtime, not the recorder; the probe
(bpftrace 0.14, pid→cgroup map, no BTF) costs 0.0046 cores plus 0.1–0.6 % in-kernel with floors and knee unchanged, so
C6 holds; the 850–900 req/s steps of the probe-on sweep are a genuine overload (three slots full, R_foreign 0).

B.1 **I is defined against the CPU curve.** From each service's profiling sweep (the one that gives h(ρ)): u(ρ) =
process CPU per served request at each step, interpolated in ρ; g(ρ) = u(ρ) ÷ c̄_sweep. Store g in the service
dictionary beside h. Expected CPU of a window = λ·c̄(mix)·g(ρ); I = U ÷ [λ·c̄·g(ρ)]. Recompute the §1 twin and
one-aggressor tables and the bands with it. I_avg and I_marg stay as columns. The lowest step is in g, so it needs no
exclusion.

B.2 **g-collapse check (analysis).** U ÷ (λ·c̄) against ρ for the four Phase E mixes on one panel, F3 layout. The
hypothesis, parallel to h: g is mix-independent below the knee. Report the cross-mix ratio. If it does not collapse,
say so; I decide whether g becomes g(ρ; mix).

B.3 **D90 (side track).** Add "when it speaks" and decomposition accuracy (|%ext − truth| ≤ 0.15) to its table, beside
strict. Note in the text that D90's wait guard is off on those rows (p90 floor noise), which is why it never abstains.
No further D90 work until I read that table.

B.4 **Collapse rows.** From wlgen.jsonl for the geo and recommendation collapse steps: generator error class
(refused / reset / timeout) and the generator's own CPU. One paragraph. The paper row reads "saturation in front of
the tap; no verdict".

B.5 **§2.4 order.** Aggressor in its own cgroup, probe on: (i) synthetic mix shift across the knee + 1 aggressor;
(iii) HR recommendation, one aggressor per core, past the knee; (iv) stream aggressor pinned outside the service's
cpuset, sharing its LLC. (ii) is taken from the probe-on sweep's overload steps unless their gate configuration differs
from (i); say if it does. Stop and report after (iv): per scenario, the verdict row for every window against twin
truth, served steps only. Then (v) SocialNetwork setup (approved, ~25 min) and the Thrift p90 case; (vi) VioMutex only
if Q is below threshold in i–v. Stop after (vi).

New columns: `g_rho`, `I_g`. Nothing committed until told.

---

## Addendum C — after the (iv) stop point (Nov 10, late)

Accepted: I_g (B.1) holds on every service and g collapses across mixes within ±5 % (B.2); the collapse is the generator
(hrgen in-flight pinned at its 20 000 cap, 10 s timeouts), closed as "saturation in front of the tap; no verdict"; the
850–900 req/s steps were not served, so scenario ii is the 600 req/s step past a dictionary truncated at ρ 0.57; probe
v3 (occupancy fields) at 0.005 cores; Q below threshold in i–iv.

C.1 **Row 1 triggers on occupancy.** A time-slicing aggressor has two faces: preemption (R_foreign, seen in iii) and
capacity loss (our threads migrate off the busy core and queue behind each other: R_foreign ≈ 0, R_self 14× the twin,
seen in i). The quantity covering both is φ = the aggressor cgroups' share of CPU time on our cpuset, which v3 exports.
New origin rule, evaluated in this order per window:
   6. E ≈ 0 → nothing to explain
   1. E ≫ 0 and φ ≫ 0 → extrinsic; amount %ext = E ÷ Lat (unchanged from Phase F); target = the cgroup with the largest
      share of φ, with R_foreign's holder as corroboration
   3. E ≫ 0, φ ≈ 0, I_g ≫ 1 → shared resource
   4. E ≫ 0, φ ≈ 0, I_g ≈ 1, Q ≫ 0 → runtime or lock wait
   2. E ≫ 0, φ ≈ 0, I_g ≈ 1, Q ≈ 0, slot busy ≈ 1 → intrinsic overload
   5. G ≫ 0 is reported alongside whichever row fired
   7. anything else → no verdict (say what this row was in your table; name it so)
The cell (slow × ext) is unchanged: y ≥ 0.5 and %ext ≥ 0.5. The signals change the origin label and the target only.
Fallback if φ cannot be read reliably: trigger row 1 on R_foreign ≫ 0 or R_self ≫ R_self_twin(ρ); say so.

C.2 **Re-score i, ii, iii** with C.1 beside the §0 rule: verdict rows and cells against truth, per scenario.

C.3 **Explain** in RESULTS-G.md: row 7 in i (10 windows); which condition failed on the 14 of 41 windows in ii that
missed row 2; i's E-vs-truth 57 % against the Phase F row for the same scenario (same configuration, or how it differs).

C.4 **Runs**, probe v3, aggressor in its own cgroup, each with its unstressed twin:
   iv-b  stream aggressor pinned outside the cpuset, sharing the LLC, against a 30 % VioMemWalk mix with
         BIGSVC_MEMWALK_MB past the LLC size. Expect I_g ≫ 1, φ ≈ 0, R_foreign ≈ 0 → row 3. This is also G3.1; keep
         the unstressed sweep for the G3 bias number.
   v     SocialNetwork setup (approved, ~25 min) and the Thrift p90-only case with per-request rows (thread = request).
   vi    VioMutex at 10 % of a uniform mix, no aggressor. Expect row 4 with Q ≫ 0.
   Stop and report after vi with the full confusion matrix under C.1, per scenario.

C.5 Noted as a limit, not to fix now: under a time-slicing aggressor I_g reads below 1 on the real services (the
elastic base), so cache pressure from the same aggressor can be masked; the frontend's +0.16 is the one case above.

New columns: `phi_cpuset`, `holder_cgroup`. Nothing committed.

---

## Addendum D — after the (vi) stop point (Nov 11)

Accepted: the Addendum C rule scores 90–100 % cells on every scenario; row 1 fires only where an aggressor holds the
cpuset and the p50 moved, never on a twin; (v) is p90-only as Phase F predicted; C3 not demonstrated with a stream
aggressor; (vi) null. G2 is closed except the three questions below.

D.1 **(v) made explicit.** Which latency stream rose 20–110 % at p90: with blocked time excluded, or the full latency?
How much survives with blocked time excluded? Does the store share the node with the aggressor? The per-request
analysis cites pair 4 (probe v3.2) only; the matrix stands because its verdict comes from E. Paper sentence either
way: a slowed dependency is the dependency's verdict; the per-request rows name the store call.

D.2 **(vi) was it a test?** Realized mutex utilization per step: 2 ms hold × VioMutex requests per second. Below ~0.3
the null is by construction.

D.3 Restate deviation 28 cleanly. Note the 25–33 % twin drift in CPU per request on post-storage as a limitation of I_g
on store-backed services.

D.4 **One LLC-capacity attempt for row 3.** Aggressor with a working set ≈ LLC size and reuse (`stress-ng --cache`, or
a memwalk loop at the LLC size) on the cores that share the LLC with the victim, outside the cpuset; victim the 24 MB
memwalk30 mix; core frequency pinned (`cpufreq` set, not "none") and uncore frequency pinned where
`/sys/devices/system/cpu/intel_uncore_frequency` exists; twin under the same pinning. Expect I_g ≫ 1, φ ≈ 0 → row 3.
If nothing: row 3 is a stated limitation ("I_g flags, unsized, no positive LLC case on this hardware") and G3's bias
numbers (over-prediction up to 0.43 in-LLC, the opposite sign at 128 MB; give the 128 MB number) are the
self-interference result. No third attempt.

D.5 **One contended-lock attempt for row 4.** VioMutex share set so the lock is near 0.7 utilization at operating
load (from D.2). Expect Q ≫ 0 → row 4. If Q still reads zero, the Go counter is wrong: switch Q's Go source to the
eBPF sleep split and say so. No third attempt.

D.6 **G4 now, before D.4 / D.5.** The Addendum C rule in the scorer; OOR guard kept for ρ outside the profiled range.
Re-score every row of the Phase F results table; add the pattern-verdict column beside cell accuracy and decomposition
accuracy; collapse windows read "saturation in front of the tap; no verdict". Before/after figure in the F6 layout with
the verdict row as a third panel. Row 7 at ii's slot-busy margin: the threshold that removes it and what it costs
elsewhere. Stop and report with the table.

D.7 G5's Go thread↔request mapping is deferred until the table is in.

D.8 (Nov 11, 02:00) Addendum D is run unattended overnight: no stop points; D.4, D.5, G3.2 and a 128 MB repeat queued
on the cluster in that order, G4 / D.1–D.3 / D90 / a bounded G5.2 done meanwhile; one morning report in RESULTS-G.md
§5. Frequency pinning restored and logged at the end. Prompt: AGENT-PROMPT-G5.md.

## Addendum E — after the post-acceptance additions (Nov 12)

Vocabulary change first: the diagnoses are named by mechanism in every file from now on: run-queue contention (was
"extrinsic", trigger φ, amount E ÷ Lat, target the holder cgroup), service-time inflation (was "shared resource"), lock
wait, own overload, GC, nothing to explain, no verdict. The cell (slow × ext) keeps its name. Rename in RESULTS-G.md,
g-final/ and the scorer's labels; no numbers.

E.1 Analysis, no cluster: the amount of run-queue contention from φ instead of from E. For every served second of i and
iii (and the no-aggressor rows as the zero control), compute (a) E ÷ Lat as today, (b) the naive signal-only amount
R_foreign ÷ Lat, (c) the capacity counterfactual: D(ρ ÷ (1 − φ)) − D(ρ), divided by Lat, with φ the aggressor cgroups'
share of the cpuset and the dictionary evaluated at the same mix. Score each against the truth share (within ±0.15, and
the cell). One table, one figure for i and iii in the F6 layout with the three amounts as lines over the truth. Say
where (c) matches E and where the queue model stops.

E.2 Checks on clnode170, no runs, record in RESULTS-G.md §6 and RUNBOOK: whether /sys/fs/resctrl mounts and which of
CMT / MBM / CAT it exposes; cgroup v2 cpu.pressure present and readable per pod; perf_event_paranoid, rdpmc
availability, number of programmable counters with SMT on; the SMT sibling map of the service's cpuset; whether a
libbpf toolchain (clang, libbpf headers) can be installed. Write the same checklist as a script so it can be run on the
Ice Lake nodes later.

E.3 Probe v4 (bpftrace where it can, libbpf where it must; measure overhead as in §2.3): (a) φ_sibling: the same
occupancy accounting on the sibling hyperthreads of our cpuset, per holder cgroup; (b) waker split: on sched_wakeup of
one of our threads, classify the sleep that just ended by the waker (our own cgroup → lock or channel; kernel → I/O;
other cgroup → other) and accumulate per window; (c) if E.2 allows it, per-task counters at switch: cycles,
instructions, LLC misses per thread per window, with the probe's own cost.

E.4 Runs, each with its unstressed twin, probe v4, aggressor in its own cgroup:
(a) SMT-sibling aggressor: stress-ng pinned to the sibling hyperthreads of the service's cpuset, not to the cpuset
itself; uniform mix, then memwalk30 at 24 MB. Expect φ ≈ 0, φ_sibling ≫ 0, I_g above 1. Report which diagnosis fires
under the current rule, and propose the rule for a sibling case.
(b) If E.3(c) works: the D.4 cache-aggressor pair at 24 MB once more, reporting IPC and LLC misses per window for
victim and aggressor alongside I_g, so the 18 % speed-up has a counter next to it.
Stop after (b) with the per-scenario tables. No third attempts.

E.5 RESULTS-G.md §6 with deviations; g-final/ updated; staged, not committed. (User, same message: the cluster was used
for another set of experiments in between; make sure the environment is ready before starting the runs.)

## Addendum F — two runs for the tail (Nov 12)

Probe work first, then runs; each stressed run after its own twin; nothing committed; stage when done. Diagnosis names
as in Addendum E.

F.1 Probe: per-resume records. For the victim's threads only, emit one record per resume: tid, timestamp, run-queue
delay of that resume, and the cgroup that held the CPU during it (time-share credit as in v2). Join to requests by
thread id and the request's start/end timestamps from the recorder (rawt), so each request gets its own run-queue
delay by holder, not the per-second split of g5_tail.py. Report the probe's cost with this export on.

F.2 Probe: softirq on the victim's cores. irq:softirq_entry / softirq_exit per CPU in the victim's cpuset: time in
softirq per window by vector (NET_RX separately), and, for each wake-up of a victim thread, the delay between the
softirq's raise and its exit when it ran behind another task (credit the task that was running). Report cost.

F.3 Run A, the positive case: a CPU-bound service with no store or downstream call, thread = request. First choice
SocialNetwork unique-id-service (C++ Thrift); if it cannot be driven alone, the synthetic service with the uniform
mix. Aggressor in its own cgroup on the victim's core(s), duty-cycled so it is busy about 20 % of the time
(stress-ng --cpu 1 --cpu-load 20, or an equivalent on/off loop with ~10 ms bursts). Four load steps below the knee.
Target: p50 within ±5 % of the twin while p95 rises by 20 % or more. One tuning pass on the duty cycle if the
target is missed; say what you used. No second pass.
Report per step, twin and stressed, for requests ≥ the step's p95 (medians and means): total, handler on-CPU time,
run-queue delay behind the aggressor's cgroup, behind own threads, behind others, and the unattributed remainder;
then the growth under the aggressor split the same way, as shares. Also the window diagnoses for the run.

F.4 Run B, the post-storage pair once more (same configuration as (v) pair 4) with F.1 and F.2 on. Same table as F.3
plus: softirq time on the victim's core per window, twin vs stressed, and how much of the blocked segment's growth
is softirq delayed behind the aggressor. State plainly whether the softirq hypothesis of §2.4 D holds.

F.5 Deliver: RESULTS-G.md §7; g-final/f/ with one CSV per run holding the per-step tail composition and the growth
split (columns: run, step, req_s, variant, total_ms, oncpu_ms, rq_foreign_ms, rq_self_ms, rq_other_ms,
softirq_ms, blocked_ms, unattributed_ms), so the figure can be drawn from it. Restore the cluster; RUNBOOK entry.

## Apparatus note — the memory-walk endpoint's step count (Nov 17, after RESULTS-K §6.3)

`VioMemWalk` (and every `memwalk` endpoint with Param 0) is sized once at pod start: steps per request = FloorMs ÷ the
time per step measured then (`walk_ns_per_step` in the pod's calibration line). A pod started while a neighbour is
already running measures slow steps and does fewer of them for its whole life: D.4's aggressor runs did 2.8× fewer
steps at 24 MB (1.4× at 128 MB), which was the whole of its "faster under a neighbour" result (RESULTS-K §6.3; note at
RESULTS-G §2.8). Two rules for any run that compares the endpoint across conditions:

- Start every pod with nothing else running on the socket, and start the neighbour afterwards (as K6 C3/C4 did); or
- fix the step count: `BIGSVC_MEMWALK_STEPS=N` in the pod (`MEMWALK_STEPS=N bash scripts/exp.sh deploy …`). N > 0
  makes Param-0 memwalk endpoints walk exactly N steps per request; the default 0 keeps the calibrated sizing. The
  value is logged as `memwalk_steps_fixed` in the calibration line and as `memwalk_steps` in `meta.json`. For the
  K6 24 MB pod the calibrated count was 117 682 (34.0 ns per step for the 4 ms floor).

The option is in `workflow/bigsvc/kernels.go` and `scripts/exp.sh` (staged); the images in the registry (`k123g4` and
earlier) predate it, so it takes effect after the next image build.
