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

The holding interactor pushes into it each frame: bare hands from
`XRHandActivator`'s existing curl, controllers from their trigger axis. A prop
reads its own parent and never learns which kind of thing is holding it, so
controller props get analog input with no extra path.

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
