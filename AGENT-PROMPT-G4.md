# Prompt for the code agent — Phase G, after the (iv) stop point

---

The (iv) stop point is accepted, with the §2.3 correction noted. Read PHASEG-HANDOFF.md Addendum C.

1. Verdict rule (C.1): row 1 triggers on aggressor occupancy φ ≫ 0 (probe v3) together with E ≫ 0; the amount stays
   %ext = E ÷ Lat as in Phase F; R_foreign's holder names the target. Row 2 adds φ ≈ 0. Re-score i, ii, iii with
   this rule and report the verdict rows and the cells against truth, beside the old rule.
2. Explain, in RESULTS-G.md: what row 7 is; which condition failed on the 14 of 41 windows of ii that missed row 2;
   why i's E-vs-truth is 57 % against the Phase F row for the same scenario, or how the configurations differ.
3. Runs, probe v3 on, aggressor in its own cgroup: (iv-b) stream aggressor outside the cpuset against a 30 %
   VioMemWalk mix (BIGSVC_MEMWALK_MB past the LLC), with its unstressed twin; this is also G3.1. Then (v)
   SocialNetwork setup and the Thrift p90 case with per-request rows. Then (vi) VioMutex at 10 % of a uniform mix.
   Stop and report after (vi) with the full confusion matrix (new rule) per scenario.
4. RESULTS-G.md §2 complete with deviations.

Rules carry over. New columns: phi_cpuset, holder_cgroup. Nothing committed.
