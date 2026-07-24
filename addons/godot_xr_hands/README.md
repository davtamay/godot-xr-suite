# Godot XR Hands

A portable hand-processing and gesture foundation for XR, plus a procedural
hand-joint visualizer. Pure GDScript.

The visualizer remains presentation-only. Gesture recognition is a separate
pipeline that snapshots tracking once, derives normalized features once, and
shares those features across authorable gesture definitions.

**Requires** the `godot_xr_interaction_toolkit` addon for its handedness enum
and robust `XRHandTracker` resolver. Runtime gesture logic does **not** require
`godot_webxr_kit`.

## Contents

```text
addons/godot_xr_hands/
  plugin.cfg / plugin.gd
  runtime/
    hand_visualizer.gd                 # presentation only
    features/                           # palm-local normalized features
    gestures/                           # Resource definitions and conditions
    recognition/                       # canonical events + lifecycle/scheduler
  presets/                             # pinch, fist, point, open-palm assets
  samples/gesture_diagnostics_demo.tscn
  samples/microgesture_locomotion_demo.tscn
  tests/test_gesture_foundation.gd
```

## Gesture pipeline

```text
XRHandTracker / future replay or runtime source
  -> XRHandFrame
  -> XRHandFeatureExtractor
  -> XRGestureDefinition resources
  -> XRGestureStateMachine
  -> gesture_started / gesture_performed / gesture_ended
```

`XRGestureRuntime` double-buffers hand frames and acquires every joint once per
hand per frame. Gesture conditions consume only `XRHandFeatures`; they never
query WebXR, OpenXR, or trackers directly. The current authored graph is kept
simple and debuggable, with an explicit future seam for compiling Resources to
a compact runtime program after profiling justifies it.

## Visualizer usage

Add a `Node3D` under your `XROrigin3D`, attach `hand_visualizer.gd`, and point
its optional fallback paths at your left and right `XRController3D` nodes. The
visualizer reads `XRHandTracker`, which WebXR and native OpenXR runtimes both
populate.

The visualizer can feature-detect `window.CompanyWebXRHandBridge` when the
WebXR kit shell is installed. This is only a startup presentation fallback; it
is not used by the engine-agnostic gesture pipeline.

## Diagnostic sample

Run `samples/gesture_diagnostics_demo.tscn`. It displays tracking quality,
palm-normalized pinch distance, finger curls, and gesture lifecycle events in
desktop and headset views. Four authored poses drive a small gesture reactor:
pinch charges its core, fist emits a shockwave, point fires an energy beam, and
open palm resets the system. The scene dynamically loads `godot_webxr_kit` when
present to add VR/AR buttons, while remaining importable in native OpenXR
projects.

Run `samples/microgesture_locomotion_demo.tscn` for palm-local thumb taps and
horizontal swipes. A tap opens teleport targeting and a second tap commits it,
while left/right snap-turn the origin by 45 degrees. The sample additionally
recognizes held fist-plus-thumbs-up/down poses for teleport aim/commit. Thumb
swipes require curled fingers and thumb contact with the side of the index,
keeping ordinary fingertip pinches out of the locomotion path. Recognition
emits action-neutral events, so locomotion policy stays outside the hand input
layer. Space and the arrow keys drive the same canonical actions for desktop
testing.

Pose-started teleport targeting is maintained only while the thumb-pose intent
remains active. Returning to neutral cancels and hides the target after a short
grace period; transitioning directly from thumbs-up to thumbs-down preserves
the target long enough to confirm the teleport.

Teleport targeting is hand-directed by default. The invoking hand's normalized
wrist-to-middle-knuckle axis launches a sampled projectile curve, with temporal
smoothing; the first valid surface hit becomes the destination. Lowering the
hand produces a near landing and raising it extends the arc, while projectile
speed defines the overall comfortable range. Head direction is used only when
hand orientation is unavailable. This keeps the behavior portable without
requiring a vendor-specific hand-aim pose.

After thumbs-up activates, pose maintenance checks the curled-finger and
extended-thumb anatomy rather than requiring the thumb to remain world-up.
The user can therefore pitch the whole fist down for a close landing without
accidentally cancelling targeting. A clearly opposite thumb direction, an open
hand, a retracted thumb, or tracking loss still ends the maintained pose.

Maintenance requires at least three of the four fingers plus an average curl
gate, so opening the fist cancels targeting even if the thumb remains extended.
The initial up/down cone is intentionally wider than the maintenance rule: the
thumb may be naturally angled rather than perfectly vertical, which improves
left/right-hand and user-to-user tolerance without allowing an open-hand pose.

`XRMicrogestureSource` defines the canonical wearer-relative event vocabulary:
left, right, forward, backward, and tap. Providers may derive those events from
normalized joints, native runtime classifications, recordings, or simulation.
`XRMicrogestureLocomotion` consumes only that contract rather than querying a
tracker or vendor API, so providers can be exchanged without changing authored
gestures, locomotion, or gameplay scenes. Handedness is normalized by the
provider: equivalent left- and right-hand motions emit the same semantic event.

Horizontal swipes are measured as travel along the curved index-finger surface,
from proximal joint to fingertip. Normal travel commits when the thumb lifts,
keeping the implementation independent and portable.

For noisy trackers, a swipe can also commit once contact travel crosses a
stricter high-confidence threshold before release. It still enters a release
lockout immediately, so one physical swipe produces at most one event. Thumb
poses tolerate very short candidate dropouts so a single unstable joint frame
does not restart their activation timer.

## Current scope

The current slice proves static feature conditions, confidence scoring,
hysteresis, activation/release timing, cooldown, lifecycle signals, and a
zero-allocation-per-frame palm-local thumb microgesture state machine. Longer
motion history, compound condition trees, gesture compilation, native runtime
microgesture event adapters, and recording/replay remain next-stage additions.
