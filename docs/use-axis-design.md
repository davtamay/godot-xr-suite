# Analog use axis: separate GRAB from USE

Status: approved design, 2026-07-25 (David). Implements item 7 of the ISDK
inventory (`Godot_WebXR_gh/docs/INNOVATION_BACKLOG.md`, entry 2026-07-24) —
the smallest remaining item, chosen first on quality-per-line.

## Licensing boundary

Technique implemented from the published description only. No ISDK code read
for implementation, copied, or adapted (Oculus SDK License, incompatible).
Any Meta constant is an order-of-magnitude sanity check, never a shipped
value.

## What already exists (corrects the inventory)

The inventory says analog pinch is absent and the props are bespoke. Half of
that is wrong, and it matters for scoping:

- `XRHandActivator._finger_curl(hand)` already computes a 0..1 curl and emits
  `trigger_progress(hand, amount)`.
- Its curl math is ON-DEVICE TUNED and carries the reasoning in-code: it reads
  the base→distal joints rather than the fingertip, because curling to fire
  folds the tip toward the palm where the cameras lose it, which made a real
  pull read as "no data" and drop the shot.
- `xr_blaster.gd` already subscribes to `trigger_progress` — but only to
  rotate its trigger MESH. Firing itself is binary, and `xr_sprayer.gd`
  ignores the analog value entirely.

So the missing piece is not the math. It is that the value is activator-shaped
and hand-only, so no prop can simply read "how hard is this being used".

## Design

**The held object owns the axis.** `XRGrabInteractable` gains:

- `use_value: float` — 0..1, read-only to consumers
- `use_changed(value: float)` — emitted only when the value actually changes

`XRHandActivator` pushes into it: it already computes the normalized pull AND
already holds an `_interactable` reference, so publishing is one call beside
the existing `trigger_progress.emit` with zero change to the curl math.

**CORRECTION to the approved design (found during implementation).** The
design claimed "controllers get analog input for free". They do not. The
activator is bare-hand only, and `xr_input_adapter.gd` exposes no analog axis
at all (`get_aim_pose`, `get_grip_pose`, `get_source_kind` only). `use_value`
therefore stays 0 for controller-held props until a controller analog source
exists. The interactable-owned design is still right — it is where a
controller source would publish — but the benefit is future, not present.

**Binary behaviour is untouched.** `activated` / `deactivated` fire exactly as
today, at today's thresholds, through today's code. `use_value` is purely
additive: a prop that ignores it behaves identically to before. This is what
keeps the change clear of everything already earned in.

**`XRHandActivator` is not modified.** Its curl and thresholds are tuned
values under the project's protection rule; the axis CONSUMES it. If a change
there ever looks necessary, it needs its own on-device earn-in, separately.

**Two-hand grabs must decide whose curl drives the value.** This is the
decision most likely to be got wrong by implementation order rather than
intent, so it is specified here: the FIRST grabber (`_grabbers[0]`, the same
interactor `_grabbing` tracks for single-hand follow) owns the axis. On a
two-hand → one-hand handoff the remaining hand takes it over.

**Props become examples, not special cases.** `xr_blaster.gd` reads
`use_value` for pull strength while its firing stays binary; `xr_sprayer.gd`
gains a variable rate. Both then demonstrate a pattern any prop can adopt.

## Testing

Headless, mutation-proven FAIL-then-PASS:

- `use_value` clamps to 0..1 for out-of-range input
- `use_changed` fires on a real change and NOT every frame at a steady value
- the value returns to 0 on release, so a prop cannot latch a stale pull
- the two-hand rule: the first grabber drives it, and a handoff transfers it
- a prop that ignores `use_value` behaves exactly as before (the additive
  contract)

Fixtures must vary the value across frames. A steady-value fixture cannot
detect a `use_changed` that fires every frame — the failure this suite is
most likely to miss, and the tenth-occurrence defect class on this project is
fixtures too benign (or too narrowly scoped) to fail.

## Earn-in (gate)

Folds into the existing feel-check session, no new dial needed: squeeze the
spray can slowly and confirm the rate tracks the finger continuously rather
than snapping on; confirm the blaster's firing feel is UNCHANGED (the binary
path must be untouched); confirm nothing regresses with controllers in hand.

## Out of scope

Items 4, 5, 6 and 8 of the inventory. In particular the synthetic display
hand (item 4) is the agreed next piece and is much larger.


## Follow-up: duplication audit (David, 2026-07-25)

David challenged whether this session enhanced existing systems or grew
parallel ones. The audit found three cases:

1. **`XRConditionedHandPoseSource` was a duplicate of
   `XRTrackerHandPoseSource` differing by ONE line** (`get_tracker` vs
   `resolve_raw`). FIXED: folded back into the original as a `conditioned`
   flag, the duplicate deleted, its one consumer updated. Proven by mutation
   that the flag changes which tracker is read, not merely that it is stored.

2. **`XRHandActivator.trigger_progress` and `XRGrabInteractable.use_value`
   carry the same number through two mechanisms.** OPEN. One should be derived
   from the other or retired; keeping both means a prop can read its pull two
   ways. Needs a decision.

3. **`XRInteractionArbiter` and the four `suppress_on_*` booleans both answer
   "when is this interactor active".** OPEN BY DESIGN, but with no exit
   written down. Back-compat requires both during transition; it must not stay
   dual. Needs a deprecation path: arbiter standard in the rig, booleans
   marked deprecated, then removed.

Where existing code was checked first, duplication did not occur -- the
arbiter reuses the tuned `hover_radius` rather than adding a radius,
`_deadzone_slice` consolidated two copies, the use axis reuses the tuned curl,
and the throw fix replaced the mean rather than sitting beside it. The pattern
is simply: check first.
