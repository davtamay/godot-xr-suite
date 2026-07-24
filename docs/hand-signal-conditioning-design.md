# Hand Signal Conditioning — Design (2026-07-24)

A conditioning layer between raw `XRHandTracker` joints and everything that
consumes them: adaptive filtering, tracking-loss recovery, and a single
accessor that all consumers share.

This is **Spec 1 of a multi-spec effort** to raise the suite's hand-tracking
fidelity to match what Meta's Interaction SDK achieves. It is the foundation
layer; later specs build on it.

## Why this first

Comparison against Meta's Interaction SDK (ISDK v205, read locally from
`com.meta.xr.sdk.interaction@c7b9fd4a82b0`, 678 C# files) identified eight gaps.
This spec addresses the one every other gap sits on top of.

**The suite performs no adaptive filtering of hand data.** A search for
one-euro / lowpass / adaptive smoothing across all addons returns nothing. What
exists is three fixed-alpha `lerp`/`slerp` calls inside individual recognizers:

- `godot_xr_hands/runtime/recognition/xr_thumb_microgesture_recognizer.gd:115`
- `godot_xr_hands/runtime/recognition/xr_thumb_pose_recognizer.gd:58`
- `godot_xr_hands/runtime/binding/xr_microgesture_locomotion.gd:221`

Fixed-alpha smoothing buys stability only by paying a constant lag. It cannot
be both still at rest and responsive at speed — the two requirements that
hand tracking actually has. Meta filters at the data source, so every consumer
inherits conditioned data. We do not, so every consumer inherits raw jitter.

Two secondary problems compound it:

**The accessor is split.** Seven files resolve hand trackers through
`XRHandTrackerResolver`. At least eight call sites bypass it with raw
`XRServer.get_tracker("/user/hand_tracker/...")`, including
`xr_poke_interactor.gd:112`, `xr_locomotion.gd:282`, `xr_hand_mesh_visualizer.gd:131`,
and all three gesture-studio files. Conditioning only what the resolver reaches
would leave poke and locomotion noisy while everything else smoothed —
*inconsistent* fidelity, which reads worse than uniform noise because the user
cannot form a stable expectation.

**Tracking loss has no shared policy.** `has_tracking_data` is checked in
roughly twelve places, each reacting differently — some hide the hand, some
skip the frame, some bail out of a gesture. There is no hold-last-good
behaviour anywhere, so a momentary dropout is a visible pop.

## Non-goals

Explicitly deferred to later specs, listed so the boundary is unambiguous:

| Deferred | Spec |
|---|---|
| Synthetic/display hand (per-joint freedom, wrist lock, eased lock/unlock) | 2 |
| Grab pose scoring (translation + rotation), grab surfaces | 3 |
| Tweened grab movement via perceived distance | 3 |
| RANSAC throw velocity with release dead-zone | 4 |
| Poke fidelity (tangent hysteresis, approach angle, pinning, recoil) | 5 |
| Ray stabilization and cursor | 6 |
| Locomotion gate | 7 |

This spec ships no new interaction behaviour. It changes the quality of the
signal that existing behaviour runs on.

## Clean-room constraint

Meta's ISDK is licensed under the Oculus SDK License, which is not compatible
with this suite's licensing. **No ISDK code is copied, transcribed, or
adapted.** What transfers is technique and the knowledge that a technique
works at production scale.

Every algorithm here is implemented from published literature:

- **One Euro filter** — Casiez, Roussel & Vogel, *1€ Filter: A Simple
  Speed-based Low-pass Filter for Noisy Input in Interactive Systems*, CHI 2012.

Where ISDK constant values are known, they are treated as **order-of-magnitude
sanity checks only** — our parameters are derived from our own recorded traces
(see Validation), not transcribed.

## Architecture

```
XRHandTracker (raw: WebXR / OpenXR / xr_simulator)
        |
        v
XRTrackerHandPoseSource            -> XRHandFrame (raw)         [exists today]
        |
        v
XRHandConfidenceGate   (decorator)  hold-last-good; raises discontinuity
        |
        v
XRHandFilter           (decorator)  One Euro on wrist pose + local rotations
        |
        v
                    XRHandFrame (conditioned)
        |
        +---------------------------------+
        |                                 |
        v                                 v
gesture pipeline reads the        XRConditionedHandPublisher
frame directly  [already does]    writes a shadow XRHandTracker
                                          |
                                          v
                                  XRHandTrackerResolver returns it
                                          |
                                          v
                                  all 13 existing consumers, unchanged
```

### Why this shape

**The seam already exists.** `XRHandPoseSource` documents itself as the
"acquisition seam for WebXR, OpenXR, replay files, simulated hands, or a future
native provider," feeding `XRHandFrame`. Conditioning is precisely what that
seam was built for. It is currently consumed only by the gesture pipeline
(`xr_gesture_runtime.gd`). This spec finishes it rather than inventing a
parallel abstraction.

**Two delivery surfaces, one implementation.** Code that already speaks
`XRHandFrame` reads the conditioned frame. The thirteen files that speak
`XRHandTracker` read a *shadow tracker* populated from the same frame — so
they receive conditioned data without being rewritten. This pattern is already
proven in this codebase: `xr_simulator.gd:703` constructs `XRHandTracker`
instances and writes joints via `set_hand_joint_transform` /
`set_hand_joint_flags`.

**Gate before filter, not after.** If the filter runs first, a tracking dropout
makes it interpolate smoothly *into* the garbage pose and smoothly back out —
a visible lurch in both directions, worse than the pop it replaced. Gating
first means the filter never sees an invalid sample.

**Reacquisition must reset filter state.** On lost -> reacquired transition the
gate raises a discontinuity flag; the filter clears its history for that hand
and re-seeds from the first good sample. Without this, the filter slews from a
stale held pose to the live one over its whole time constant.

## Components

### `XROneEuroFilter` (RefCounted)

Scalar adaptive low-pass. Cutoff frequency rises with estimated signal speed:
heavily smoothed at rest, low-lag at speed.

```
dx      = (x - x_prev) / dt
dx_hat  = lowpass(dx, alpha(d_cutoff, dt))
cutoff  = min_cutoff + beta * abs(dx_hat)
x_hat   = lowpass(x, alpha(cutoff, dt))

alpha(c, dt) = 1 / (1 + tau/dt),  tau = 1 / (2*pi*c)
```

Parameters: `min_cutoff` (Hz — governs stillness at rest), `beta` (governs lag
reduction under motion), `d_cutoff` (Hz — smoothing of the speed estimate).

**Operates on `Vector3` and `Quaternion` as whole units, not per component** —
one speed estimate from the magnitude, one alpha, one native `lerp`/`slerp`.
See Performance for why this is both faster and more correct. State is held in
flat packed arrays indexed by joint rather than in per-scalar objects, so this
is a set of static functions over shared state rather than an instance per
filtered value.

**Driven by real timestamps, not frame counts.** WebXR frame pacing is
variable; a frame-count-driven filter silently retunes itself whenever the
framerate moves. `dt` comes from `Time.get_ticks_usec()` deltas.

- **Depends on:** nothing.
- **Used by:** `XRHandFilter` only.

### Rotation filtering

Same adaptive cutoff, with speed measured as angular distance per second and
applied via a single `slerp`. Includes hemisphere correction (negate when
`dot < 0`) so the filter never takes the long way around.

Fingertip joints are **position-only** — they have no children, and their
rotation is unused by poke and pinch — so they skip rotation filtering
entirely.

### `XRHandJointHierarchy`

Static parent map for Godot's 26 `XRHandTracker` joints. `WRIST` is the root;
`PALM` and each `*_METACARPAL` parent to `WRIST`; every other joint parents to
its predecessor in the finger chain. Mirrors the chain structure already
declared in `xr_simulator.gd:345-349`.

- **Depends on:** nothing. Constant data.

### `XRHandFilter` (XRHandPoseSource decorator)

The core. For each frame:

1. Decompose into **wrist world pose** plus, for every other joint, its
   transform **relative to its parent**.
2. Filter the wrist position and rotation.
3. Filter each joint's parent-local rotation (tips excepted — see above).
4. Filter each joint's parent-local **translation** with a very low cutoff.
5. Recompose world transforms by walking the hierarchy.

Steps 2–4 skip entirely when the raw pose is unchanged from the previous frame,
and step 3–4 cover only the joints currently consumed. See Performance.

**Why parent-local.** Filtering world positions independently lets neighbouring
joints be smoothed by different amounts, so bone lengths breathe and the hand
visibly stretches under fast motion. Filtering rotations in parent-local space
makes distortion structurally impossible — no filter strength can change a bone
length, because lengths live in the translations, not the rotations.

**Why step 4 is a bonus, not a cost.** A given user's bone offsets are
essentially constant; the runtime reports a fixed skeleton with measurement
noise on top. Filtering them hard converges to a stable per-user skeleton
estimate, which stops the mesh hand breathing — a separate visible artifact
from joint jitter, fixed for free.

**Per-source parameter sets.** Controller-emulated hands
(`HAND_TRACKING_SOURCE_CONTROLLER`) have different noise characteristics from
optically tracked ones — `xr_poke_interactor.gd:106` already works around this
with a hand-written special case. `XRHandFilter` holds one parameter set per
source and selects automatically from `tracker.hand_tracking_source`.

- **Depends on:** `XROneEuroFilter`, `XRHandQuaternionFilter`,
  `XRHandJointHierarchy`, `XRHandFrame`.

### `XRHandConfidenceGate` (XRHandPoseSource decorator)

Tracking-loss policy in one place instead of twelve.

- **Hand level:** when `has_tracking_data` is false or `valid_joint_count`
  falls below `min_valid_joints`, emit the last good frame for up to
  `hold_duration_sec` (default 0.25). Past that, emit invalid.
- **Joint level:** when individual joints lose `POSITION_VALID` while the hand
  remains tracked, hold those joints from the last good frame and leave the
  rest live.
- **Discontinuity:** on lost -> reacquired, set a flag on the frame. Downstream
  filters reset on it.

- **Depends on:** `XRHandFrame`.

### `XRConditionedHandPublisher`

Owns one shadow `XRHandTracker` per hand, registered into `XRServer` under a
distinct name (`/user/hand_tracker/left_conditioned`, `..._right_conditioned`),
and populates it from the conditioned frame each frame.

Carries through: joint transforms, joint radii, joint flags,
`has_tracking_data`, and **`hand_tracking_source`** — the last is required or
`xr_input_modality_manager.gd` stops distinguishing controller-driven hands.

- **Depends on:** `XRHandFrame`.

### `XRHandTrackerResolver` (extended in place)

Stays in `godot_xr_interaction_toolkit/runtime/input/`. The acquisition layer
moves *down* to join it instead — see Repo changes.

Extended with a `conditioned` mode (default on): return the shadow tracker when
one is live, else fall back to the raw tracker. Existing scoring and per-frame
caching are unchanged.

**Chain driving.** The conditioning chain runs lazily on first access per
rendered frame, keyed on `Engine.get_process_frames()` — matching the
resolver's existing cache. This is correct rather than merely convenient: as
the resolver's own comment notes, `XRServer` updates trackers pre-render, so
hand data genuinely does not change between physics ticks within a render
frame. Physics-tick consumers reuse the same conditioned frame, and the filter
advances exactly once per real tracking update. No autoload, no node, no scene
setup, and it works in headless tests.

### Trace harness

`XRHandTraceRecorder` — writes raw frames (timestamp, 26 transforms, radii,
flags, source) to a file during a live session.

`XRHandTracePlayer` — an `XRHandPoseSource` that replays a trace file, so the
whole chain can run headless with no headset.

`XRHandTraceMetrics` — computes, for a trace run through a given configuration:

| metric | definition | measures |
|---|---|---|
| **rest jitter** | RMS joint deviation from local mean over a rest segment | what filtering is *for* |
| **motion lag** | cross-correlation peak offset, raw vs conditioned, over a fast segment | what filtering *costs* |
| **bone-length σ** | standard deviation of each bone length across the trace | rigidity claim |

These three are exactly the quantities One Euro trades against each other, so
they are the honest measure of whether a parameter set is better or merely
different. They also become regression tests and an offline tuning loop —
parameters get tuned without wearing the headset.

### A/B toggle

A debug action flipping `XRHandTrackerResolver` between raw and conditioned at
runtime, so the difference can be felt in-headset as well as measured.

## Repo changes

### Preserving the dependency DAG

`DECISION_LOG.md` records a deliberate architecture: independent addons with
`godot_xr_interaction_toolkit` as the runtime base that **depends on nothing**,
and it explicitly places the `XRHandTracker` gesture/resolver helpers there.
The code agrees — `godot_xr_hands` hard-`preload`s the toolkit in 4 files,
while the toolkit's only references to hands are editor path strings and one
model path that no-ops when hands is absent.

Conditioning therefore has to live **at or below** the resolver, never above
it. Putting the filter in `godot_xr_hands` and having the toolkit's resolver
return its output would give the toolkit a hard runtime dependency on hands,
inverting the DAG and breaking standalone toolkit installs.

So the acquisition layer moves **down** into the base addon:

| File | From | To |
|---|---|---|
| `xr_hand_frame.gd` | `godot_xr_hands/runtime/data/` | `godot_xr_interaction_toolkit/runtime/input/` |
| `xr_hand_pose_source.gd` | `godot_xr_hands/runtime/input/` | `godot_xr_interaction_toolkit/runtime/input/` |
| `xr_tracker_hand_pose_source.gd` | `godot_xr_hands/runtime/input/` | `godot_xr_interaction_toolkit/runtime/input/` |

All three declare `class_name`, so they are globally registered and references
by class name survive the move untouched. Only explicit `preload(path)` calls
need updating — and `xr_tracker_hand_pose_source.gd`'s preload of the resolver
becomes a same-directory reference.

Gesture recognition, feature extraction, and both visualizers stay in
`godot_xr_hands`. Only the acquisition plumbing moves.

**Manifest update.** The suite declares inter-addon dependencies formally in
`xr_package.cfg`, which the package resolver and Project Doctor read.
`xr.interaction` is `layer="foundation"` with `requires=PackedStringArray()`,
and `xr.hands` is `layer="capability"` with `requires=["xr.interaction"]`. This
design keeps both true — which is exactly why the acquisition layer moves down
rather than the resolver moving up. The inverse would have made a *foundation*
package require a *capability* package, giving mutually recursive `requires`
and a foundation that cannot be installed alone.

Deliverable: add a hand-input capability to `xr.interaction`'s `provides` list,
since the toolkit now offers conditioned hand data to packages above it.

Unaffected: `godot_universal_xr_apk` is `layer="deployment"`,
`requires=["openxr.vendors"]`, `runtime_footprint="Editor/export only"`. It has
no coupling to either addon and packages whatever the project contains.

Consequence worth stating: the toolkit's own poke, direct, and ray interactors
now get conditioned hand data even when the toolkit is installed alone, without
`godot_xr_hands` present. That is the correct outcome — they are the heaviest
consumers of fingertip precision in the suite.

**Unified:** the ~8 call sites using raw `XRServer.get_tracker(...)` for hand
trackers switch to `XRHandTrackerResolver.get_tracker(hand)` —
`xr_poke_interactor.gd` (2), `xr_locomotion.gd`, `xr_hand_mesh_visualizer.gd`,
`xr_gesture_ghost_hand.gd`, `xr_gesture_recognizer.gd`, `xr_gesture_recorder.gd` (2).
This is a straight substitution; the resolver's scoring is strictly more robust
than a fixed path lookup.

`xr_input_modality_manager.gd` and `xr_simulator.gd` keep raw access
deliberately — the modality manager must observe true hardware state, and the
simulator *produces* trackers rather than consuming them.

**New**, all in the base addon so the DAG holds:
`godot_xr_interaction_toolkit/runtime/input/filter/` (one euro, quaternion
filter, joint hierarchy, hand filter, confidence gate),
`godot_xr_interaction_toolkit/runtime/input/` (publisher),
`godot_xr_interaction_toolkit/tools/trace/` (recorder, player, metrics).

Per the break-and-fix-forward posture, conditioning is **on by default** with
no compatibility shim. The raw path stays reachable through the resolver flag
for A/B and debugging.

## Error handling

| Condition | Behaviour |
|---|---|
| No tracker present | Shadow reports `has_tracking_data = false`; consumers behave exactly as today |
| Non-finite input (NaN/Inf) | Reset that joint's filter state, pass the raw value through, count it in a diagnostic |
| `dt <= 0` or absurdly large | Clamp to a sane range; a paused/backgrounded tab must not produce a filter spike on resume |
| Tracking dropout | Gate holds last good, bounded by `hold_duration_sec` |
| Reacquisition | Discontinuity flag resets filter state; no slew from the stale pose |
| Controller-driven hand | Controller parameter set selected automatically |

## Performance

### Why this is designed for, not deferred

The usual posture — ship the obvious implementation, measure, optimize if
needed — assumes a cheap escape hatch. Here there isn't one.

`EVIDENCE_LOG.md` records that Godot's default web export templates ship
`variant/extensions_support=false`, and that GDExtension on web requires the
`dlink` template variant. Dropping to native code is therefore a **custom
export template** commitment — layer 7 in `CLAUDE.md`'s hierarchy — not a
drop-in rewrite. For the WebXR target, GDScript-level efficiency is the primary
lever rather than a fallback.

Two of the measures below are also *more correct* than the naive approach, so
they belong in the first implementation regardless of cost.

### Vectorize — do not filter per-component

A position filtered as three independent scalars gives each axis its own
adaptive alpha. Because One Euro's cutoff tracks per-axis speed, a diagonal
motion smooths the slow axis more than the fast one, the slow component lags
further, and **the trajectory bends**. The filter introduces a direction error
that scales with how diagonal the motion is.

Instead: derive one speed estimate from the vector's magnitude, compute one
alpha, apply one native `lerp`. Rotations likewise — one angular speed, one
alpha, one `slerp`. Direction is preserved exactly, and 7 GDScript-level
operations per joint collapse to 2.

This is a deliberate choice, not the only valid one — per-component filtering
is common in 1€ implementations. For a rigid skeleton, where direction fidelity
matters more than per-axis tuning, the shared-alpha variant is the better
trade.

### Flat state, not filter objects

The obvious implementation allocates one filter object per filtered scalar —
roughly 380 `RefCounted` instances, each accessed through property get/set,
which is among GDScript's slowest operations. State lives instead in
`PackedVector3Array` / `PackedFloat32Array` indexed by joint, operated on by
static functions. Removes both the allocation and the property lookups.

### Skip work that cannot matter

| Measure | Saving |
|---|---|
| No-op when the raw pose is unchanged from last frame (render rate commonly exceeds hand-tracking rate) | Whole chain, on a meaningful fraction of frames |
| Filter only consumed joints — with the mesh hand hidden, roughly 8 of 26 matter; re-seed on show, which is invisible because the hand just appeared | ~3x in gesture-only scenes |
| Fingertips are position-only — the 5 tips have no children and their rotation is unused by poke and pinch | 5 quaternion filters per hand |
| Hoist per-frame constants (`1 / (2*pi*dt)`) out of the joint loop | Constant factor |

### Budget

Approximately **104 vector-level operations on flat arrays** per frame across
both hands, versus ~380 scalar operations on objects for the naive version.

No number is claimed here. The naive estimate was 0.1–0.4 ms in GDScript and
the measures above should improve on it substantially, but **the trace harness
produces the real figure and it is a gate on acceptance, not a footnote** —
including a WebAssembly measurement, since that is the target that matters and
the one where GDScript is weakest.

If measurement still shows it does not fit, the next step is a scope decision
(filter fewer joints, or condition only the consumers that demonstrably need
it), not an automatic jump to GDExtension — which would drag in the `dlink`
template and its own build, size, and deployment costs, and needs its own
justification.

## Testing

**Unit**
- One Euro step response matches the published formulation for known inputs.
- Adaptive cutoff increases monotonically with input speed.
- Quaternion filter takes the short path across the hemisphere boundary.
- NaN / Inf / zero-dt inputs reset cleanly rather than poisoning state.
- Joint hierarchy: every joint reaches `WRIST`; no cycles; all 26 covered.

**Property**
- *Rigidity:* for any input frame and any filter parameters — including
  deliberately extreme ones — every conditioned bone length stays within
  0.5 mm of the raw skeleton's median for that bone. This is the
  formal statement of the parent-local design's central guarantee, and it must
  hold by construction rather than by tuning.

**Integration (trace replay, headless)**
- Replay a recorded trace; assert the three metrics against thresholds.
- Replay a trace containing a deliberate tracking dropout; assert the gate
  holds, then invalidates, then resets the filter on reacquisition.

**Manual**
- In-headset A/B on the existing gesture and poke demos.

New tests live in `godot_xr_interaction_toolkit/tests/`, following the existing
harness pattern of `godot_xr_hands/tests/test_gesture_foundation.gd`.

## Success criteria

Thresholds are **calibrated from the first recorded baseline**, not asserted in
advance. Once the baseline exists, acceptance requires:

1. Rest jitter reduced by **>= 50%** versus raw.
2. Added motion lag **<= one frame** at 72 Hz (13.9 ms).
3. Bone-length standard deviation **<= 0.5 mm** across the trace.
4. Measured frame cost within the stated budget on the target device.
5. No regression in the existing gesture test suite.
6. All hand-tracker consumers resolve through one accessor (verifiable by grep).

Criteria 1 and 2 are deliberately in tension — that tension is the whole point
of an adaptive filter, and reporting both is what makes the result honest
rather than a claim that smoothing was applied.

## Decisions and their consequences

**Gesture recognizers keep their existing fixed-alpha smoothing.** Chosen for
blast radius. The consequence is real and should be stated plainly: the
recognizers now smooth already-smoothed data, so they retain their current lag,
and the filter must be tuned gently enough not to disturb their thresholds —
it cannot be tuned purely for its own job.

This is revisitable with data rather than permanently locked. The trace harness
measures exactly how much filtering the recognizers tolerate before their
thresholds drift, so a later pass can remove the redundant layer and retune
against evidence. Logged as follow-up work, not silently accepted.

## Risks

**Blue team — why this works.** The insertion point already exists and is
already correct; the shadow-tracker mechanism is already proven in this
codebase by the simulator; the parent-local decomposition makes the primary
failure mode (visible hand distortion) structurally impossible rather than
merely unlikely; and the trace harness means every claim is measured before
it is made.

**Red team — how this fails.**

- *Cost exceeds budget on WebAssembly.* Most likely failure, and the one with
  the worst escape hatch: GDScript in wasm is materially slower than native,
  this runs every frame on the critical path, and dropping to GDExtension means
  adopting the `dlink` export template. Mitigated by designing for efficiency
  up front rather than deferring it (see Performance) and by measuring on the
  web target early — the harness exists before tuning starts, so this is caught
  in week one, not at demo time.
- *Gentle tuning yields an underwhelming result.* Constrained by the recognizer
  decision above, the filter may not be allowed to be strong enough to deliver
  a felt improvement. Detected by the metrics; the response is the follow-up
  pass, and the risk is visible rather than hidden.
- *Shadow tracker desynchronizes.* If a consumer reads the shadow before the
  chain has run for that frame, it sees last frame's data. Mitigated by the
  lazy-run-on-first-access design, which makes staleness structurally
  impossible — access *is* what triggers the run.
- *Moving the acquisition layer breaks an external consumer.* Low: all three
  moved files declare `class_name`, so only explicit `preload(path)` callers
  break. Accepted under the break-and-fix-forward posture, but worth a
  changelog note since these are public-facing class names.
- *Spec 2 hits the same DAG constraint.* The synthetic hand must also sit at or
  below the resolver, so it lands in the toolkit too. If that accumulation
  starts making the toolkit incoherent, the answer is the `godot_xr_core` base
  addon considered and deferred here — revisit at Spec 2, not now.

## Evidence

| Claim | Source |
|---|---|
| No adaptive filtering exists in the suite | grep across all addons for one-euro/lowpass/adaptive: no hits |
| Three fixed-alpha smoothers in recognizers | `xr_thumb_microgesture_recognizer.gd:115`, `xr_thumb_pose_recognizer.gd:58`, `xr_microgesture_locomotion.gd:221` |
| Accessor is split | 7 files via resolver; 8+ call sites via raw `XRServer.get_tracker` |
| Shadow trackers are viable in Godot 4.8 | `xr_simulator.gd:703-705` writes joints into a constructed `XRHandTracker` |
| Toolkit is the dependency-free runtime base | `DECISION_LOG.md` (addon split); hands hard-preloads toolkit in 4 files, toolkit references hands only via editor strings and one no-op model path |
| The DAG is declared formally, not just by convention | `xr_package.cfg`: `xr.interaction` layer=foundation requires=[]; `xr.hands` layer=capability requires=["xr.interaction"] |
| Universal APK is unaffected by addon layering | `godot_universal_xr_apk/xr_package.cfg`: layer=deployment, requires=["openxr.vendors"], runtime_footprint="Editor/export only" |
| GDExtension is not a cheap fallback on web | `EVIDENCE_LOG.md`: default web templates ship `variant/extensions_support=false`; GDExtension web use requires the `dlink` template variant |
| The acquisition seam exists and is unused outside gestures | `xr_hand_pose_source.gd`; only `xr_gesture_runtime.gd` consumes it |
| Meta conditions at the data source | ISDK `Runtime/Scripts/Input/OneEuroFilter/` (7 files), applied via `Input/Hands/DataModifiers/HandFilter.cs` |
| Meta tunes filtering per hand region | ISDK `Input/OneEuroFilter/HandFilterParameterBlock.cs` |
| Meta has explicit tracking-loss recovery | ISDK `Input/Hands/DataModifiers/LastKnownGoodHand.cs` |

## Next smallest step

Build `XROneEuroFilter` — vectorized over `Vector3`/`Quaternion` with flat
packed state from the start, not a scalar-object version to be optimized later
— plus its unit tests, then the trace recorder.

The recorder must exist before any tuning happens, so the first parameter
choice is made against a real baseline rather than a guess. Its first job is a
WebAssembly cost measurement, since that is the target where the budget is
tightest and the fallback is most expensive.
