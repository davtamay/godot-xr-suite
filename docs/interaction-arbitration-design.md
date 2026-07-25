# Interaction arbitration: one explicit mode per hand

Status: approved design, 2026-07-25 (David). First of three subsystems in the
ISDK-style near/far interaction work; the other two — far-ray targeting
quality (shoulder-anchored origin, conical scoring, hover hysteresis) and the
visual language (ray states, surface-conforming reticle, teleport arc
styling) — consume this one's states and are explicitly out of scope here.

Motivating problems, both observed on-device by David (2026-07-24/25):
the teleport arc sometimes stays "stuck on hand"; and it is not predictable
when near, far, and teleport interaction are each available.

## Licensing boundary

Techniques are implemented from published descriptions of Meta's interaction
model and cited where used. No ISDK code is read for implementation, copied,
or adapted (Oculus SDK License, incompatible). Meta's constants are
order-of-magnitude sanity checks only; every shipped value comes from our own
on-device earn-in.

## The problem with today's design

Each interactor decides for itself when to stand down, through a scatter of
independent booleans on `xr_ray_interactor.gd`: `suppress_on_poke`,
`suppress_on_teleport`, `suppress_on_linked_hover`, `suppress_on_linked_select`,
plus `suppress_interactor_path` and an optional `hand_ray_requires_aim_pose`
gate. Nothing owns the question "what is this hand doing right now?", so:

- there is no single place to reason about, test, or visualise the answer;
- a state can be entered and never cleanly left, because no one owns leaving
  it (the stuck teleport arc);
- the visual layer has no formal states to render, which is why subsystem
  three cannot be built before this one.

## Design

**One mode per hand**, owned by a new `XRInteractionArbiter` node placed in the
rig and discovered by group — the same discovery pattern the suite already
uses for `xr_input_modality_manager`:

```
enum Mode { NONE, NEAR, FAR, TELEPORT }
```

Resolved once per frame per hand. Every interactor asks the arbiter whether
its own mode is active for its hand, instead of running private suppression
reasoning.

**Transition rules**, evaluated in this order:

1. **TELEPORT is exclusive and wins from any state.** Entered only via the
   locomotion intent API (`begin_teleport_aim`), left only on commit or
   cancel. While active, FAR and poke are inert and their visuals hidden.

   **CORRECTION (2026-07-25, whole-branch review).** The original text claimed
   this was the structural fix for the stuck arc, "because the arc cannot
   outlive a state that exclusively owns it". THAT IS NOT WHAT WAS BUILT. The
   arbiter only *reads* `XRLocomotion.is_aiming()`; locomotion still draws the
   arc, still owns its `_INTENT_TIMEOUT`, and still decides when aiming ends.
   The arbiter is a follower of that state, not its owner, so a stuck aim
   produces a stuck TELEPORT mode rather than being prevented by it — and
   because poke now stands down in TELEPORT, a stuck arc is HARDER to recover
   from than before, not easier.

   What this subsystem actually delivers is that teleport, ray and poke can no
   longer disagree about who is active: one value decides. Fixing the arc
   itself means giving something ownership of its lifecycle, which is separate
   work and is NOT in this branch. The earn-in must therefore treat "the arc
   never persists after the gesture ends" as an OPEN BUG to observe, not as a
   fix to confirm.
2. **NONE** when the hand is not tracked.
3. **NEAR** when the direct interactor already reports a hover or selection
   for that hand, **FAR** otherwise.

   **NEAR gates the far ray only — never poke.** NEAR is derived from the GRAB
   interactor's hover, and poke targets are not grab interactables:
   `XRPokeButton` carries no collider at all. Gating poke on NEAR made every
   poke button in the suite unpressable whenever an arbiter existed, including
   the arbiter's own off switch. Poke is gated on TELEPORT exclusivity alone;
   its `poke_reach` broad-phase already is its near-field test. Recorded
   because the mistake is easy to repeat: a mode DERIVED from one interactor
   cannot also GATE a different one whose targets it cannot see.

   For the same reason `XRDirectInteractor` is not gated at all — gating it on
   a mode derived from its own hover would be a feedback loop. Direct grabbing
   is therefore NOT inert during TELEPORT, which the original text claimed it
   would be.

**Hysteresis is a DWELL, not a second radius.** The arbiter reuses the direct
interactor's already-tuned `hover_radius` rather than introducing one of its
own, so the damping lives in time: NEAR survives `near_release_dwell_sec`
after its candidate disappears. Entering is immediate.

The clock measures time since the candidate was last SEEN, not time in the
mode. A time-in-mode clock was the first implementation and it strobed: a
candidate flickering at the sphere edge never changes the mode, so that clock
ran out anyway and dropped to FAR mid-flicker.

**Back-compatibility is a hard requirement.** With no arbiter node in the
scene, every interactor keeps its current suppression behaviour byte for
byte. The arbiter is opt-in per rig. `xr.interaction` stays `layer="foundation"`
with `requires=[]` and standalone-installable. No existing scene changes
behaviour until it adds the node.

## Architecture

- Create `addons/godot_xr_interaction_toolkit/runtime/xr_interaction_arbiter.gd`
  (`class_name XRInteractionArbiter`, group `xr_interaction_arbiter`):
  per-frame resolution, per-hand mode query, exported tuning values.
- The transition table is a **static pure function** over
  (hand_tracked, nearest_distance, teleport_active, previous_mode,
  time_in_mode) → Mode, so it is fully headless-testable and
  mutation-provable independent of any scene.
- Interactors gain one guarded consult: if an arbiter exists, defer to it;
  otherwise fall back to existing logic. No existing suppression export is
  removed or repurposed in this piece.
- Proximity uses the interactors' existing physics queries rather than a new
  broad-phase; scope is one sphere query per hand per frame.

## Testing

- Headless unit tests, mutation-proven FAIL-then-PASS, on the static table:
  teleport exclusivity from each other mode; teleport release returning to the
  proximity-derived mode; the hysteresis band (a distance inside the margin
  must NOT flip the mode); dwell enforcement; NONE on tracking loss and
  recovery out of it.
- Fixtures must vary the input across frames. This branch's recurring defect
  is fixtures too benign to fail — a static-distance fixture cannot exercise
  hysteresis at all, which is precisely the property most likely to be wrong.
- Regression: all three existing suites stay green, demo boots clean, and a
  scene with no arbiter is asserted to behave exactly as before.

## Earn-in (gate)

Arbiter on/off dial plus a live per-hand mode readout. Checklist:

- the far ray disappears as a hand approaches a grabbable and returns on
  withdrawal, WITHOUT flicker (tune `near_release_dwell_sec` live);
- POKE BUTTONS STILL WORK in every mode -- the scene's own dials are poke
  buttons, and gating poke on NEAR once made all of them dead;
- CONTROLLERS WORK -- ray and poke both function with controllers in hand,
  since liveness used to require a hand tracker;
- teleport aiming hides ray and poke, and restores them on commit and cancel;
- the arc persisting after a gesture is an OPEN BUG to observe, not a fix to
  confirm -- see the correction above;
- nothing feels worse than with the arbiter off.
