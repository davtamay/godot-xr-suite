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
   cancel. While active, NEAR and FAR are inert and their visuals hidden.
   This is the structural fix for the stuck arc: the arc cannot outlive a
   state that exclusively owns it, where another suppression flag would only
   add a second way to get out of sync.
2. **NONE** when the hand is not tracked.
3. **NEAR** when any interactable lies within `near_radius` of the hand's grip
   anchor (`XRControllerHandAdapter.resolve_grip_anchor`, i.e. the palm),
   **FAR** otherwise.

**Hysteresis on the near/far boundary.** Enter NEAR at `near_radius`; leave
only beyond `near_radius + near_release_margin`, and only after
`minimum_dwell_sec` in the current mode. Without this the ray strobes when a
hand rests at the edge of a table. Same shape as `XRHandConfidenceGate`'s
hold, which is already earned-in on-device.

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

Adds a fourth feel-check dial: arbiter on/off, so the whole state machine is
A/B-able against current behaviour in one poke. Checklist: the ray disappears
as a hand approaches a grabbable and returns on withdrawal, without flicker at
the boundary; teleport aiming hides both ray and poke visuals and restores
them exactly once on commit or cancel; the arc never persists after the
gesture ends; nothing feels worse than today. Values (`near_radius`,
`near_release_margin`, `minimum_dwell_sec`) are set from this session, not
chosen offline.
