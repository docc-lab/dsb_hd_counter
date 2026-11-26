# Prompt for the code agent — Phase G, after the §2.3 stop point

---

The §2.3 stop point is accepted. Read PHASEG-HANDOFF.md Addendum B; it redefines I and sets the §2.4 order.

1. Analysis, before or alongside the runs: (B.1) define g(ρ) = u_sweep(ρ) ÷ c̄_sweep from each service's profiling
   sweep (u = process CPU per served request, interpolated in ρ) and store it in the service dictionary beside h(ρ);
   I = U ÷ [λ·c̄·g(ρ)]. Recompute the twin and one-aggressor tables of §1 with it; keep I_avg and I_marg as columns.
   (B.2) g-collapse check: U ÷ (λ·c̄) against ρ for the four Phase E mixes on one panel, same layout as F3; report
   the cross-mix ratio below the knee. (B.3) D90: add "when it speaks" and decomposition accuracy to its table.
   (B.4) For the geo and recommendation collapse steps, report the generator's error class and client-side CPU
   from wlgen.jsonl; one paragraph.
2. §2.4 re-runs, aggressor in its own cgroup, probe on: (i) synthetic mix shift across the knee + 1 aggressor;
   (iii) HR recommendation, one aggressor per core, past the knee; (iv) stream aggressor outside the cpuset. Row 2
   (ii) is taken from the 850–900 req/s steps of the probe-on sweep unless their gate configuration differs from
   (i); say if it does. Then (v) SocialNetwork setup and the Thrift p90 case; (vi) VioMutex only if Q is below
   threshold in i–v. Stop and report after (iv) with the per-scenario verdict rows against twin truth, and again
   after (vi).
3. RESULTS-G.md §2 with the deviations list.

Rules carry over unchanged. New columns: g_rho, I_g. Nothing committed until I say so.
