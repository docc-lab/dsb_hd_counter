# Prompt for the code agent — Phase G, overnight run after the (vi) stop point

---

The (vi) stop point is accepted. Read PHASEG-HANDOFF.md Addendum D. This is an unattended run of several hours: there
are no stop points below; make the decisions the addendum already names, write each one into RESULTS-G.md as you take
it, and leave one report (§5, "Overnight summary") for the morning. Nothing committed. Stop early only if the cluster
itself breaks (a node unreachable, a pod that will not schedule); then write what happened and halt.

Queue the cluster work first so it runs while you do the analysis:

A. Cluster queue, in this order, each run with its twin, probe v3.2, aggressor in its own cgroup, environment changes
   logged in RUNBOOK §17.1:
   A1. D.4 — LLC-capacity aggressor (working set ≈ LLC with reuse: stress-ng --cache, or a memwalk loop at the LLC
       size) on the LLC-sharing cores outside the cpuset, against the 24 MB memwalk30 mix; core frequency pinned
       (cpufreq set, not "none") and uncore frequency pinned where /sys/devices/system/cpu/intel_uncore_frequency
       exists; the twin under the same pinning. Record the LLC size and the pinned frequencies in the run's meta.
   A2. D.5 — VioMutex at the share that puts the lock near 0.7 utilization at operating load (from D.2 below; if D.2
       is not yet computed when the queue reaches A2, use 40 % share), no aggressor, with twin.
   A3. G3.2 — mix-shift sweep from uniform toward 50 % VioMemWalk at 24 MB, no aggressor, with the frequency pinning
       of A1; the self-interference curve, not just the two points.
   A4. If time remains: A1 repeated at 128 MB (the beyond-LLC victim) under the same pinning, so the bias and the
       aggressor response are reported at both working sets.
   Restore the frequency settings to their previous state at the end and log it.

B. Analysis, while A runs:
   B1. D.1 — for (v): which latency stream rose at p90 (blocked time excluded, or full); how much survives with
       blocked time excluded; whether the store shares the node with the aggressor. Per-request analysis cites pair 4
       only. D.2 — realized mutex utilization in (vi) per step. D.3 — deviation 28 restated.
   B2. G4 — the Addendum C rule in the scorer (OOR guard kept for ρ outside the profiled range); every row of the
       Phase F results table re-scored with the pattern-verdict column beside cell and decomposition accuracy;
       collapse windows "saturation in front of the tap; no verdict"; before/after figure in the F6 layout with the
       verdict row as a third panel; row 7 at the slot-busy margin: the threshold that removes it and what it costs
       elsewhere; controller target (largest φ holder) checked against the aggressor cgroup in every G2 run.
   B3. D90 — judged on its three columns against the same rows; one paragraph: keep as a window-level tail path or
       close the side track.
   B4. G5.2 — Go thread↔request mapping, bounded to two hours: record the M at handler entry and exit, measure how
       often they differ per window on one existing probe-on run; if it needs per-request attribution the probe
       cannot give on bpftrace 0.14, write what it would take (newer bpftrace from source, or a libbpf program) and
       stop that item.

C. When A finishes, score A1–A4 under the Addendum C rule against their twins and add them to the matrix. For D.4 and
   D.5 the outcome is binary and final: row 3 / row 4 demonstrated, or stated as a limitation in the words of D.4 /
   D.5. No third attempts.

D. RESULTS-G.md §3 (G3 numbers, both working sets), §4 (G4 table and figure), §5 overnight summary: what ran, what
   each decision was and why, the final matrix, deviations, and the list of things that need my decision in the
   morning (expected: none beyond reading the table).

Rules carry over: figure titles name the latency stream and the signal; no CSV overwritten; raw and smoothed kept;
run names may keep "stress"/"hog", prose says aggressor; kernel run-queue delay and Go runtime wait named differently.
