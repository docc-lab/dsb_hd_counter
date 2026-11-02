# Phase B reprocessed (RESULTS-B2, PHASEC-HANDOFF.md section 1) — 2026-11-01

## What changed vs RESULTS-B.md

| | RESULTS-B.md (Phase B) | RESULTS-B2.md (this file) |
|---|---|---|
| Lat_e | caller send stamp -> handler return minus blocked (recorder f stream) | within-service latency from the tap, downstream-blocked time excluded (recorder pp / rawp stream); the stamp is ignored (`GORDION_LAT=unstamped`, now the default of every analysis script) |
| c_e | single-endpoint idle runs (B1) scaled by one operating factor (x 0.445 frontend, x 0.584 reservation) | NNLS on the per-window process CPU of the b2/b3 (r2/r3) sweep windows at measured utilisation 0.3–0.9, clock-normalised to f_nom = 2.1 GHz (`analysis/r3_costs.py`); two variants, see R3 |
| old scorer's D(λ) | caller RTT per λ bin | the SUT's own unstamped service-level p50 per λ bin (same stream as the new scorer) |
| dictionary of the new scorer | caller view (client_curve) | the SUT's own stream (analyze_profile / fit_rule_a) |
| ρ | c_e (operating) / window clock | c_e (NNLS) / window clock, unchanged formula ρ = λ Σ %_e c_e ÷ (f/f_nom) ÷ k |

Scripts: `analysis/r3_costs.py` (new), `analysis/b4_compare.py --server` (server-side dictionary + old curve), `dictionary.py` (`GORDION_LAT`, `GORDION_NOMINAL_MHZ`). Raw data unchanged: `blueprint/examples/bigsvc/results/hr/<run>/`.

## R3 — c_e by NNLS (prominent: every endpoint moves by more than 15 %)

Per-window model CPU_nominal(ms) = base · dt + Σ_e c_e · a_e, windows of the default **and** the heavy sweep pooled (with a single fixed mix every a_e column is proportional to the total — max |cos| between endpoint columns 0.986 on b2-default alone — so the per-endpoint split is not identifiable from one sweep; pooling the second mix lowers it to 0.32 on reservation). Window band: measured clock-normalised utilisation 0.3–0.9 (cost-independent; selecting by ρ/k from the costs being fitted feeds back on itself and shrinks the band every iteration).

Frontend (b2-default + b3-heavy, 3948 windows, mean clock 1657 MHz):

| endpoint | c_e marginal, NNLS **with** intercept (ms @2.1 GHz) | c_e average, NNLS **without** intercept | Phase B scaled-idle (op2) | marginal vs Phase B |
|---|---|---|---|---|
| search | 0.450 | 0.589 | 0.581 | −22 % |
| recommend | 0.399 | 0.513 | 0.443 | −10 % |
| reserve | 0.338 | 0.461 | 0.412 | −18 % |
| user | 0.358 | 0.438 | 0.224 | +60 % |
| intercept | 304 ms CPU/s = 0.15 of 2 cores (R² 0.92) | — (R² 0.82) | | |

Reservation (r2-default + r3-heavy, 6534 windows, clock 1217 MHz):

| endpoint | marginal (with intercept) | average (no intercept) | Phase B scaled-idle (op) | marginal vs Phase B |
|---|---|---|---|---|
| MakeReservation | 0.162 | 0.305 | 0.332 | −51 % |
| CheckAvailability | 0.155 | 0.327 | 0.345 | −55 % |
| intercept | 405 ms CPU/s = 0.20 of 2 cores (R² 0.69) | — (R² 0.00) | | |

What this means. The per-request CPU of both Go services falls with load (wake-up/batching: cpu/req at nominal clock 1.10 → 0.38 ms on the frontend between 300 and 6300 req/s), so CPU vs arrivals is concave and a line through the 0.3–0.9 band has a large positive intercept. The marginal c_e (R3's literal definition) therefore puts reservation's knee at **ρ/k ≈ 0.4** (0.38 default / 0.43 heavy at the last step, where 1.4 of 2 cores are busy and p50 has doubled), i.e. ρ no longer reads as an offered utilisation. The no-intercept fit (all CPU attributed to requests = the average cost at operating load) reproduces Phase B's scaled-idle costs within 10 % and puts the knee at ρ/k 0.80–0.83. **Figures and the ρ axis below use the average (no-intercept) c_e**; `costs-*-nnls.json` (marginal) and `costs-*-avg.json` (average) are both in `results/hr/`. Decision needed on which definition the paper adopts; the collapse (Fig. A right panel) is the same under either, only the x-scale changes.

## R4 — per-window clock

* Phase B runs (gordion2/gordion3 images): every window carries `mhz` (sysfs cpufreq of the affinity cores) and `cpu`; ρ divides the offered work by f/f_nom in every table and figure (`GORDION_FREQ_NORM=1`), and c_e is expressed at f_nom = 2.1 GHz. Clock range: frontend 1.2 → 2.6 GHz across the sweep (schedutil), reservation 1.2 GHz throughout (schedutil never ramps it: ~70 % per-core utilisation).
* Lat_e is **not** clock-normalised: the dictionary stores wall-clock ms, so a window at a lower clock has a longer FL_e. On the frontend this is the dominant effect (own processing 0.17 → 0.06 ms as the clock rises, Fig. A frontend row); on reservation the clock is constant so it does not matter. If Lat_e should be expressed in cycles (Gordion's kcyc view), it is a one-line change in `lat_samples` (multiply by mhz/f_nom); not done because the handoff defines D_e in ms.
* Phase A2 runs (apt186, image k123/fam184 of 2026-10-27) carry **no** per-window clock; the SCHED_IDLE fillers held the cores at 2.1 GHz and the CPU accounting (cores busy = Σ a_e c_e within 5 %) is the evidence that f = f_nom there. Every Phase A2 number assumes f_nom.
* Phase C runs on clnode258 (Ice Lake 8360Y): no cpufreq driver at all (hardware P-states). The recorder falls back to /proc/cpuinfo, which reports the base clock for idle cores, so its `mhz` is unreliable at low load. The cores are instead pinned from below through MSR IA32_HWP_REQUEST (min = 0x1f; the max field is ignored by this firmware, as is the turbo-disable bit) and verified by IA32_PERF_STATUS = ratio 31 busy and idle: f = f_nom = 3.1 GHz, constant, `GORDION_FREQ_NORM=0`.

## R1 — B4 / B5 / B6 re-scored with unstamped Lat_e (side by side)

B4/B5 (`b4_compare.py`, 2×2 cell = y ≥ 0.5 × %ext ≥ 0.5, k = 0.07; ramp = fixed hrgen rate 0.6 × knee, default → heavy mix over 300 s, ~415 one-second windows):

Re-scored on 2026-11-02 with one correction to `b4_compare.py` that also applies to the Phase B numbers: the
service-level latency of a window is now the same statistic as the old curve's D(λ) (the pooled median of the
window's requests; before it was the n-weighted mean of the endpoints' medians, which on a log-spread mix sat far above
the pooled median and made the old scorer read %ext 0.4–0.6 at the profiled mix itself — invisible on HotelReservation's
near-equal floors, large on the synthetic service). Costs = average c_e (costs-*-avg.json).

| run | definition | old D(λ): %ext median, windows ≥ 0.5 | new D_e[ρ]: %ext median, windows ≥ 0.5 | cells old (slow/ext, slow/int) | cells new | G1 n/a | vs ground truth (within ±0.15, err median): new / old; G3 cell accuracy old / new |
|---|---|---|---|---|---|---|---|
| reservation r4-ramp (no aggressor) | Phase B (stamped, caller = frontend) | 0.015, 1.0 % | 0.014, 0.5 % | 4, 62 | 2, 60 | 4 | — |
| reservation r4-ramp | **Phase C (unstamped, server-side both sides)** | 0.018, 0.0 % | 0.005, 0.0 % | 0, 0 | 0, 0 | 0 | — |
| reservation r5-ramp-stress (search+geo+rate colocated) | Phase B | 0.080, 6.7 % | 0.176, 5.2 % | 28, 89 | 21, 85 | 11 | 34 % (−0.22) / 20 % (−0.32); 87 % / 82 % |
| reservation r5-ramp-stress | **Phase C** | 0.000, 0.2 % | 0.010, 1.0 % | 0, 0 (1 fast/ext) | 0, 0 (4 fast/ext) | 0 | 77 % (−0.07) / 77 % (−0.09); 97 % / 97 % (the truth itself is ≈ 0: 15 fast/ext, 401 fast/int) |
| frontend f4-ramp (no aggressor) | Phase B (stamped, hrgen caller) | 0.000, 0.7 % | 0.074, 0.0 % | 3, 122 | 0, 117 | 13 | — |
| frontend f4-ramp | **Phase C** | 0.030, 0.0 % | 0.000, 0.0 % | 0, 0 | 0, 0 | 9 | — |

Reading. (1) The Phase B conclusion stands: neither scorer flips under the mix ramp on HotelReservation (equal endpoint costs on reservation). (2) With the unstamped Lat_e the aggressor run becomes *invisible* at the ramp's load: the ramp runs at 0.6 × knee (reservation λ ≈ 1650 req/s) and there the unstamped within-service wait under the aggressor is 0.00 ms (B6 table below, step 6: W_p −0.006 ms) while the caller sees +0.9 ms. Every window is "fast" and both scorers report 0 — correctly for what the service can see, uselessly for the operator. The stamped definition saw 118 slow windows there. This is the limitation paragraph's number: at 0.6 × knee the unstamped stream carries none of the colocated aggressor's effect; at 0.8–0.9 × knee it carries 22–36 % of it.

B6 (`b6_compare.py`; waits relative to the lowest step; "stamp" = f stream = Phase B Lat_e, "no stamp" = p stream = Phase C Lat_e):

| run | step (λ_res) | W_caller | W_f (stamped) | W_p (unstamped) | visible stamped | visible unstamped |
|---|---|---|---|---|---|---|
| reservation r2-default | 6 (1765) | 0.58 | 0.16 | 0.15 | 0.28 | 0.25 |
| | 9 (2339) | 1.06 | 0.39 | 0.26 | 0.37 | 0.24 |
| | 11 (2680) | 2.37 | 1.01 | 0.54 | 0.43 | 0.23 |
| | 12 (2852) | 4.28 | 1.84 | 0.92 | 0.43 | 0.22 |
| reservation r5-stress-sweep (aggressor) | 6 (1765) | 0.90 | 0.32 | −0.01 | 0.36 | −0.01 |
| | 8 (2179) | 2.92 | 1.64 | 0.63 | 0.56 | 0.22 |
| | 10 (2497) | 9.15 | 5.85 | 2.76 | 0.64 | 0.30 |
| | 11 (2679) | 16.19 | 11.46 | 5.76 | 0.71 | 0.36 |
| frontend b2-default | 12 (6301) | 1.46 | 0.14 | −0.11 (pp) | 0.09 | 0 (own processing falls with the clock) |

Phase B's "with stamp 21–43 %, without 22–25 %" is reproduced (stamped column 0.28–0.43, unstamped 0.22–0.25); under the aggressor the stamped share rises to 0.56–0.71 and the unstamped to 0.22–0.36 at the top of the sweep.

## Figures regenerated

* `results/hr/figA-hr.png` — Fig. A rows for reservation (default / reserve-heavy) and the frontend (own processing), unstamped Lat_e, ρ from the average c_e. Reservation: the two mixes separate by λ (heavy mix 20 % slower at 2500 req/s on the λ axis) and overlay by ρ/k until 0.75, with the heavy mix's p90 below the default's at the top — the same picture as the Phase B figure. Frontend: no queue at any load; its own processing shrinks 0.17 → 0.06 ms as the clock rises, so it is not a Fig. A candidate (kept for the appendix).
