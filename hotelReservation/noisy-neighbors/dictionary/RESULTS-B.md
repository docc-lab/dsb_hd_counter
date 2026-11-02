# Phase B results record (HotelReservation, apt186, 2026-10-28)

Working notes behind the "Phase B" section of the report doc. Raw runs: `/local/results/hr/<run>/`
on node-0 and `blueprint/examples/bigsvc/results/hr/<run>/` on the laptop; analysis scripts in
`blueprint/examples/bigsvc/analysis/` (`analyze.py`, `client_view.py`, `e1_compare.py`,
`b6_compare.py`, `b4_compare.py`, `a5_compare.py`); driver `hr.sh`, queues `queue-*.sh`.

## Setup
* Instrumented fork image `10.10.1.1:5000/hr-gordion:gordion2` (gordion recorder in every service,
  caller stamp, per-window CPU and core MHz, `PERF_HOOKS=0`, `JAEGER_SAMPLE_RATIO=0`).
* SUT pinned on node-4 (`CPUSET=2-3`, k = 2, governor schedutil, no fillers); `hrgen` on node-4 cores
  1,4-7; other services unpinned on nodes 1-3 without CFS limits; databases/memcached on node-3.
* Default mix = wrk2 ratios 0.6/0.39/0.005/0.005 (search/recommend/reserve/user); contrasting mix
  0.2/0.2/0.5/0.1.

## B0 — overhead (frontend, 3000 req/s, 60 s)
caller p50/p90/p99: recorder off 4.49/7.77/12.73 ms, on 4.42/7.13/12.13 ms (within noise).
Streams sum exactly; stamp coverage 100 %.

## B1 — frontend floors and costs (200 req/s single-endpoint runs, schedutil: cores at 1.2 GHz)
| endpoint | FL_e (f stream, ms) | c_e idle @2.1 GHz (ms) | c_e operating (x 0.38, ms) |
|---|---|---|---|
| search | 0.36 | 1.30 | 0.50 |
| recommend | 0.36 | 0.99 | 0.38 |
| reserve | 0.36 | 0.93 | 0.35 |
| user | 0.27 | 0.50 | 0.19 |

c_e >> FL_e (3-4x): the frontend's CPU is spent in the gRPC client/transport goroutines while the handler
is "blocked". The idle-run cost overstates the loaded cost 2.6x even at the nominal clock (CPU/req at
nominal falls from 1.10 ms at 300 req/s to 0.38 ms at 6300 req/s): wake-up/batching overhead of a
lightly loaded process. ρ therefore uses c_e scaled to the operating range and divides by the
window's actual clock (`GORDION_FREQ_NORM=1`); with idle c_e alone ρ/k reaches 7 at saturation.

## B2 — frontend default-mix sweep (k = 2, 300 … 6300 req/s, 45 s steps)
* Server-side Lat_e (f = x + queue + processing): 0.38 ms (300) → 0.48 (1500, cores at 1.2-1.3 GHz)
  → 0.29 (3300, 2.5 GHz) → 0.51 ms (6300, cores 1.94/2 busy). Two regimes: frequency ramp below
  ρ/k ≈ 0.6, queue above 0.9; W_f ≤ 0.14 ms over the whole range, W90 1.5 ms at the top.
* Rule-A collapse trivially holds server-side (the four endpoints' W within 0.03 ms of each other);
  the wait regime (W50 > 0.5 ms) is never reached before the generator's top rate.
* Caller view (hrgen RTT 5-7 ms) is dominated by downstream time (search 6, reserve 9, recommend 2.5,
  user 1.4 ms at idle); its "W" includes the downstream services' own queues and frequency regimes, so
  for the frontend the caller view is not a single-queue measurement. CV_A 1.8 vs CV_B 0.14 at the
  top bin (B2) and 0.14 vs 0.63 (B3): inconclusive for the frontend.
* B3 (contrasting mix, avgS 0.37 vs 0.45 ms): same picture; the avgS lever is too small on the
  frontend to test the second W input.

## B6 — frontend admission-wait check
With the stamp the frontend sees 7-11 % of the caller's RTT growth (W_f 0.14 vs W_caller 1.46 ms at
6300 req/s); without it 0 % of its own wait and ~80 % of the RTT growth via p (which includes
downstream time). No in-process bend: processing stays 0.06-0.17 ms, falling with the clock.

## Reservation SUT (k = 2; runs r1-idle-* (gordion3), r-explore, r2-default, r3-heavy)
* Fix found on the way: the first build dropped negative caller-stamp offsets (cross-host clock offset
  ~ -0.2 ms made 82 % of the stamps negative) -> image gordion3 keeps them; x at idle = -0.07 ms, cancels in W.
* B1: FL_e CheckAvailability 0.89 ms, MakeReservation 1.02 ms; c_e idle 0.59/0.57 ms @2.1 GHz, operating
  (x 0.58 from the sweep calibration) 0.35/0.33 ms. Reservation's cores never ramp above 1.2 GHz (schedutil
  sees ~70 % per-core utilisation); the knee comes at 1.4 of 2 cores busy, i.e. the service is
  scheduler/I-O bound, not cycle bound.
* B2 (default mix, reservation λ = 0.6 x hrgen 225-4725): server-side W50 0.54 (ρ/k 0.72) -> 1.25 (0.81)
  -> 2.1 (0.90) -> 19.5 (0.94) -> 29 ms (0.98); IQR across the two endpoints 0.04-0.17 ms, CV_A 0.02-0.12;
  caller view W 0.05 -> 0.52 (0.49) -> 1.04 (0.69) -> 3.0 (0.82) -> 9.4 ms (0.95). Rule B CV just as small
  (floors differ by 13 %): the two rules are not separable on this service. Cherkasova floors / lowest step
  = 1.05 (0.99-1.11).
* B3 (reserve-heavy, 71 % MakeReservation): at matched ρ/k the heavy mix waits 0.5-0.7x the default near
  the knee (1.14 vs 1.71 ms at 0.76; 1.40 vs 2.38 at 0.81; 1.90 vs 4.30 at 0.84), overlaps within 10-20 %
  below 0.7. avgS is 0.34 ms in both mixes (c_e equal within 4 %): the second W input cannot be exercised;
  the mix effect is a service-time-distribution effect (MongoDB write vs memcached path; CheckAvailability's
  floor also drops 0.89 -> 0.55 ms because reservations keep its cache warm).
* B6: in-process bend yes (q 0.09 -> 0.7 ms, p 0.93 -> 1.85 ms); visible fraction of the caller's wait
  growth: with stamp 21-43 %, without 22-25 %.

## B4 / B5 (reservation r4-ramp, r5-stress-sweep, r5-ramp-stress; frontend f4-ramp)
* Ramp = fixed hrgen rate at 0.6 x knee (2700 / 3600), default -> heavy mix over 300 s, 415 windows.
* Old scorer (Algorithm 1 with D(lambda) from the default sweep, k = 0.07) vs new (per-endpoint
  FL_e + W(rho)); 2x2 cell = y >= 0.5 x %ext >= 0.5 (my thresholds).
* No aggressor: reservation old %ext median 0.00/0.02/0.04/0.00 (before/ramp halves/after), new
  0.02/0.01/0.03/0.00; windows called extrinsic 4 vs 6 of 415. Frontend: old 0.07/0.03/0/0, new
  0.09/0.08/0.04/0.02; 1 vs 3 of 415. The lambda-indexed scorer is NOT fooled on HR (equal endpoint
  costs on reservation; the heavy mix lowers the frontend's downstream load).
* Aggressor = search+geo+rate pinned on reservation's cores: stressed sweep knee ~1900 req/s, collapse at
  2950 (p50 204 ms); ground truth W_s - W at rho/k (actual clock) 0.1/0.2/0.3 = 0.13/0.47/2.72 ms.
  Stressed ramp: new %ext median 0.30/0.25/0.10/0.07, old 0.21/0.14/0.00/0.00; vs truth: new err median
  -0.20 (IQR -0.37..-0.03), |err| p90 0.47, 36 % within +-0.15; old -0.29 (-0.42..-0.13), 0.48, 25 %.
* Shape test not applicable (2 endpoints); a5_compare's (step, mix) segmentation does not fit a ramp.

## B7
* No SockShop. Profiling wall clock per service: 2 idle runs (~80 s each incl. rollout) + one 13-step
  sweep (10.5 min) ~ 13 min; online cost nil (B0). Static lock pass not done (HR handlers hold no
  cross-request locks; memcached/mongo/gRPC clients are shared by all endpoints = shared queue).

## Conclusions (see the report doc's "Conclusions by evidence" table)
rule A collapses on reservation (not separable from B there); rho needs operating-load c_e + actual clock;
mix shift absorbed below the knee, 0.5-0.7x near it, avgS untestable; stamp doubles the visible wait
(21-43 % vs 22-25 %); DSB bends in-process; old scorer not fooled by the ramp on HR; new scorer tracks
the aggressor better (36 % vs 25 % within +-0.15), both underestimate.
