# Microgesture hardening: one recognizer, every device

Proposal, per the standing rule protecting the recognizer: nothing here lands
without the on-device plan attached to it being walked. The goal is stated by
the user as parity — *"as reliable as Meta's"* — on Quest, Android XR, WebXR,
and anything else, from one portable recognizer.

The reliability reference is the Feel Check MICRO DETECTOR dial's PLATFORM
setting on Quest: Meta's own runtime detector on the same hardware, same hand,
same session. That is what "reliable" feels like; the joint recognizer is tuned
until the difference stops being noticeable.

## The architecture principle

**Normalize at the edges; recognize in the middle.**

The recognizer must consume *device-independent* features and emit a
*device-independent* contract. Every source of cross-device variance gets
absorbed in a named layer, never inside the recognition logic:

| Variance | Where it is absorbed |
|---|---|
| Frame rate (72/90/120 Hz, browser-variable) | exact dt compensation in the smoothing math |
| Skeleton proportions (Quest vs Android XR joints) | per-hand self-calibration (quantile envelopes) |
| Tracking dropouts / FOV freezes | the conditioning chain, surfaced as discontinuity events the recognizer consumes |
| Detector capability (native FORWARD/BACKWARD) | a capability contract on XRMicrogestureSource |

This is the same shape the suite already uses for hand rays (platform pose
preferred, derived fallback, conditioning downstream), so it is a continuation,
not a new invention.

The efficiency argument writes itself: the recognizer is O(1) per frame over a
handful of floats. Nothing below adds an allocation or a per-joint loop. The
"efficient standard" is one small state machine plus per-device *data*
(calibration), never per-device *code*.

---

## Tier 1 — correctness fixes. No feel change intended; testable headless.

**EARNED IN 2026-07-29, Quest over Link.** The bar was "you can't tell the
difference" and the verdict was exactly that: *"same as before."* Shipped at
`80c1daf`. The user's overall read — *"not 100% reliable"* — is the expected
state after this tier: tier 1 removed ways the recognizer LIES (phantom swipes,
dead cooldowns, rate-dependent thresholds); the remaining misses live in the
silent dead band and the fixed posture gate, which are tiers 2 and 3.

### 1a. Frame-rate-independent smoothing

`_update_tracking` smooths contact position with
`lerpf(prev, target, contact_position_smoothing)` **per frame**. At 90 Hz the
same physical swipe is smoothed less per unit time than at 72 Hz, so its peak
travel measures differently — the thresholds are silently tuned to the frame
rate of the device they were tuned on. This is the identical bug class fixed in
`XRAimStabilizer`; the closed form is exact:

```
alpha_dt = 1.0 - pow(1.0 - contact_position_smoothing, delta / REFERENCE_DT)
```

`REFERENCE_DT = 1/72` — the rate the current values were earned in at over
Link — so behaviour at 72 Hz is bit-compatible with today and the on-device
baseline is preserved by construction.

*Test:* replay one scripted gesture at 72/90/120 Hz timestamps; peak travel and
the emitted gesture must be identical. Mutation: revert to plain lerp → the
90/120 Hz replays must diverge.

### 1b. Consume discontinuities instead of recognizing them

The recognizer reads *conditioned* features, downstream of the confidence
gate's FOV freeze. On reacquisition the contact position jumps; `_update_tracking`
commits early at confidence 0.86 the moment `|peak| >= confident_commit_travel`.
A reacquisition jump can satisfy that: a phantom swipe with high confidence.

The gate already publishes `consume_discontinuity(hand)`; only the pose filter
reads it. Plumb it through the feature provider so the recognizer, on a
discontinuity frame: aborts any in-flight TRACKING to WAITING_FOR_RELEASE
(no emit), re-seeds `smoothed_contact_position`, and leaves the cooldown alone.

*Test:* scripted stream with a mid-gesture position jump flagged as a
discontinuity → nothing emitted; same jump unflagged → today's behaviour
(pinning that the change is scoped to flagged frames only). Mutation: ignore
the flag → phantom swipe emitted.

### 1c. A bad frame suspends; it does not reset

`process_features` calls `_reset_state` on any frame below
`minimum_tracking_quality`. That zeroes `cooldown_left` (the double-fire guard
dies), zeroes `last_timestamp` (so the next delta is 0 and the cooldown cannot
tick), and re-arms mid-gesture.

Replace with suspend semantics: tolerate up to `quality_grace_frames`
(propose 3, mirroring the gate's `reacquire_frames`) of bad frames inside a
gesture before aborting to WAITING_FOR_RELEASE; **never** zero the cooldown or
the timestamp on a quality dip. A hand that goes bad for 40 ms mid-swipe
currently forgets it was ever swiping *and* forgets it just fired.

*Test:* inject one low-quality frame mid-swipe → the swipe still completes;
inject one immediately after a commit → cooldown still holds. Mutations:
restore the old reset → both fail.

## Tier 2 — never fail silently

**SHIPPED 2026-07-29** at `dd06c02` (contract, recognizer emissions, driver
relay + capability query; 7 mutations caught) and demo `15b0975` (Feel Check
counts rejections by reason, flashes per event, mirrors to stdout). One
correction to this design's sketch: the "soft haptic" is impossible for the
input being measured -- bare hands have no actuator -- so the feedback channel
is visual (and later audio, if earned). Earn-in pending: a Feel Check session
where deliberately fumbled swipes produce visible SWIPE_TOO_SHORT counts, and
the counts from ordinary use become the dead-band tuning evidence.

### 2a. `gesture_rejected` on the source contract

The dead band is real: travel in `(maximum_tap_travel, minimum_index_travel)` =
(0.09, 0.12) emits nothing at all. A fumbled swipe is a silent miss, and
slightly shorter is a TAP — which arms or commits teleport.

Meta's model (technique, from the ISDK sweep): invalid commits get **explicit
rejection feedback, never silence**. Proposal: add
`signal gesture_rejected(hand: int, reason: int)` to `XRMicrogestureSource`
(reasons: TOO_SHORT_FOR_SWIPE, TOO_LONG_FOR_TAP, TOO_SLOW, LOW_QUALITY,
DISCONTINUITY). Consumers get to buzz/flash; the demo wires it to a soft
haptic.

Deliberately **not** proposed: reclassifying dead-band travel as the nearest
gesture. That changes what fires on-device and risks converting fumbles into
phantom swipes — the exact artifact tier 1b removes. If the dead band itself
should shrink, that is a threshold change and goes through Feel Check, not
through code.

*Test:* travel of 0.105 emits exactly one rejection and no gesture. Mutation:
suppress the signal → fails.

### 2b. Capability contract

The portable recognizer emits LEFT/RIGHT/TAP; the native source adds
FORWARD/BACKWARD. Consumers currently discover this by nothing happening.
Add `get_supported_gestures() -> Array` to `XRMicrogestureSource`; the
locomotion driver already muxes per hand and can surface "forward swipe not
available on this device" instead of dead air.

Portable FORWARD/BACKWARD itself is **an investigation, not a commitment**:
`XRHandFeatures` carries only one contact axis (along the index side), so
forward/back needs a second axis measured from the thumb-tip's motion normal to
that axis. Whether that signal is separable from noise on-device is unknown.
Instrument first: log the candidate axis during deliberate forward/back swipes
on Quest with the native detector as ground-truth labels, and only then decide.

## Tier 3 — cross-device calibration (the Android XR unlock)

The adaptive envelope already self-calibrates `thumb_index_side_distance` with
per-hand quantiles — that pattern is proven in this file. But the posture gate
uses fixed curl thresholds and a fixed start zone, and the 2026-07-25 handoff
measured Android XR reporting curls **below** `minimum_finger_curl` and contact
position at 0.97–1.0 — outside `start_zone_maximum` entirely. **The recognizer
cannot arm on Android XR today.** Different skeleton, same constants.

Proposal: extend the same quantile machinery to finger curls and the contact
start zone. Fixed constants become per-hand learned ranges with the shipped
values as priors, exactly as `effective_contact_threshold` does now. Add
hysteresis to gate entry while there: arming currently requires
`posture_score >= 0.999` — effectively exact equality on a continuous noisy
score — with release at 0.42; propose an explicit arm threshold (~0.95) so
entry is a band, not an edge.

**Sequencing constraint: instrument before building.** The Android XR numbers
are one session old and pre-date the conditioning chain. First step is a
logging pass on Galaxy XR (the existing `debug_tracking` probe plus a curls /
contact-position dump), plus the `--verbose` boot capture that answers whether
it advertises the aim and microgesture extensions at all. The calibration
design should be shaped by what those numbers say, not by last week's.

Blue team: it is the same fix that already worked for contact distance, and it
removes the last per-device constants from the arming path. Red team: quantile
learning needs the user to actually *perform* the posture before it can learn
it — a cold-start problem the contact envelope dodges because relaxed hands
still produce distance samples. Mitigation: priors stay live until
`minimum_samples` arrive, so cold start equals today's behaviour on Quest and
today's broken-but-no-worse behaviour on Android XR until the first gestures
are attempted.

## Tier 4 — the verification harness that makes it a standard

One recognizer across devices is only credible with device evidence, and
headset time is the scarcest resource in this project. Proposal: a
record/replay corpus.

- A `debug_record_features` switch on the feature provider dumps the per-frame
  feature stream (a dozen floats) to a file during a device session.
- Recordings from Quest (joint + native detector as ground-truth labels),
  Android XR, and WebXR-in-browser get committed as fixtures.
- A headless suite replays every recording through the recognizer and asserts
  the emitted gesture sequence. Every future tuning change is then judged
  against *all devices at once*, offline, before anyone puts a headset on.

This converts device sessions from "test the change" into "extend the corpus",
which is the only way cross-device tuning stays cheap as devices multiply.

---

## On-device earn-in plan

1. **Quest over Link, joint recognizer**: tier 1 must be *unnoticeable* — same
   gestures fire, no new misses, no rigidity. Record a corpus session while
   there (tier 4).
2. **Quest, MICRO DETECTOR dial A/B**: PLATFORM vs PORTABLE, same session —
   count silent misses and phantom fires each side. This is the parity metric,
   before/after.
3. **Galaxy XR instrumentation pass**: boot capture + feature logging. No code
   changes shipped until these numbers exist.
4. **Galaxy XR after tier 3**: the arming rate goes from zero to comparable
   with Quest, measured on the same physical gestures.
5. **WebXR browser session**: replay-corpus capture plus the deferred aim-probe
   run, one session, two measurements.

## What is deliberately not proposed

- Threshold value changes (0.09/0.12/0.22 etc.) — Feel Check territory, with
  the user's thumb as the judge.
- Reclassifying dead-band gestures — see 2a.
- Replacing the recognizer with the native detector anywhere — the standing
  rule stands; native remains additive per hand.
- The session-gate model (enter/exit mode, index-straighten exit) — consumer
  layer, valuable, separate proposal.
