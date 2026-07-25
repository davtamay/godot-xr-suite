# Hand conditioning — measured results (Task 10 baseline + tuning)

Date: 2026-07-24. Device: Quest over Link (desktop OpenXR, Oculus runtime
1.205.0), passthrough AR session. Traces recorded raw (upstream of all
conditioning) by `demo/scenes/trace_capture.tscn`; measured by
`tools/trace/measure_traces.gd`. Six traces: rest / motion / dropout, both
hands, 370–865 frames each.

## Acceptance criteria vs. measured

| Criterion (plan) | Result | Status |
|---|---|---|
| Rest jitter −50% vs raw | −65 to −66 % (frame-to-frame RMS, tip) at tuned params | PASS, with metric caveat below |
| Motion lag ≤ 13.9 ms (1 frame @ 72 Hz) | 17.8 ms left (1 frame @ its 56 Hz effective rate), 27.8 ms right (2 frames @ 72 Hz) | PARTIAL — see lag floor |
| Tip bone deviation ≤ 0.5 mm | 0.07–0.37 mm on every trace (raw: 0.22–0.98 mm) | PASS on all six traces |

## Tuned parameters

`position_min_cutoff = 1.0` (unchanged), `position_beta = 0.7 → 2.0`.

Sweep evidence (25-point grid + 7-point refinement): raising beta from 0.7 to
2.0 cut measured wrist motion lag from 53–56 ms to 18–28 ms while the
frame-to-frame rest-jitter ratio moved only 0.343 → 0.345. The lag surface
plateaus for beta ≥ 1.5 at every cutoff tested (0.5–3.0); beta up to 4.0 buys
nothing further. Raising min_cutoff instead degrades jitter (ratio 0.38 at
3.0) without breaking the lag plateau. beta=2.0 is the knee.

Bone deviation is insensitive to both parameters (governed by the separate
`bone_min_cutoff = 0.05` hard-smoothing path), which is the parent-local
design working as specified.

## Metric caveats — read before re-tuning

1. **The plan's `rest_jitter` (RMS from the segment mean) is drift-dominated
   on real hands.** A human "still" hand drifts several mm over 12 s; raw
   rest jitter read 7–10 mm — an order of magnitude above sensor noise — and
   conditioning "only" improved it 2–13 % because the filter correctly does
   not fight slow drift. The −50 % criterion is unreachable under that
   formulation without blowing the lag budget. Frame-to-frame RMS (used
   above; raw tip 0.54 mm, conditioned 0.19 mm) isolates actual noise and is
   the honest tuning signal. Spec-challenge: the acceptance metric should be
   redefined as frame-to-frame; the plan's formulation was only ever
   validated on drift-free synthetic traces.
2. **The lag metric is quantized to whole frames of each trace's mean dt**
   (13.9 ms right, 17.8 ms left after its drops). The measured floor —
   1–2 frames — is consistent with the irreducible group delay of any causal
   smoother; sub-frame lag cannot be observed by this metric at all.
3. **Rest-trace "lag" and motion-trace "jitter" are meaningless by
   construction** (aligning noise / measuring the sweep itself). Read each
   metric only on its matching trace kind.
4. **Dropout traces contain gaps, not invalid frames** — the recorder only
   stores captured frames, so replay exercises large-dt robustness (clean:
   no NaNs, bone dev 0.14–0.17 mm conditioned) but NOT the gate's hold path.
   Gate behaviour is covered by unit tests instead.

## Remaining before Task 10 closes

- On-device FEEL check of the tuned parameters (the earn-in gate): grab, poke,
  gesture recognition, and the A/B toggle (`XRHandTrackerResolver.
  set_conditioned`) — discard the first frames after each flip, the toggle
  re-seeds the chain by design.
- WEB frame-cost measurement (the conditioning chain is GDScript per frame;
  web is where that cost bites).
- Right-hand lag sits at 2 frames measured; decide whether to chase it (the
  metric may simply be unable to show 1 frame) or accept after the feel check.
