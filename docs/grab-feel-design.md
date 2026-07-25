# Grab feel: attach transit, hold-where-grabbed, and throw consensus

Status: approved design, 2026-07-25. Implements ISDK-inventory items 1 and 2
(docs/INNOVATION_BACKLOG.md in Godot_WebXR_gh, entry 2026-07-24). On-device
finding that motivated it: grabbed cubes yank to the wrist (David, feel-check
session 2026-07-24, present in RAW and CONDITIONED — pre-existing, not a
conditioning regression).

## Licensing boundary

Techniques are implemented from Meta's published descriptions and cited where
used. No ISDK code is read for implementation, copied, transcribed, or
adapted (Oculus SDK License, incompatible). Meta's constants are
order-of-magnitude sanity checks only; shipped values come from our own
on-device earn-in.

## Behavior specification

**Grab policy is authored by block composition — no new nodes, no new enums:**

| Grabbable has | On grab |
|---|---|
| An `XRGrabPoint` child | Object tweens from its grab-moment pose to the grip pose ("attach transit"), then tracks normally |
| No `XRGrabPoint` | Hold-where-grabbed: the hand-relative offset at the grab instant is captured and tracked permanently; the object never relocates in the hand |

Existing blocks and scenes keep working unchanged. Implementation includes a
prefab audit: every shipped grabbable prefab is checked for whether it has an
XRGrabPoint, and the result (transit vs hold-where-grabbed) is confirmed to
be the intended feel for that object — tools tween, plain objects hold.

**Attach transit timing** (from the published ISDK description): travel time
is proportional to *perceived* distance,
`travel = max(translation_m, rotation_deg * 0.5 / 360.0) / transit_speed`,
so a large rotation takes as long as a comparable translation and neither
pops. Interpolation: position lerp + basis slerp over that duration; transit
is skipped when travel < one frame. During transit the hand keeps moving —
the tween target is re-evaluated against the live grip pose each frame, so
transit ends exactly in normal tracking with no handoff pop.

**Anchor correctness:** grip poses resolve against the PALM joint; the WRIST
fallback fires only when the palm joint is invalid that frame. The current
behaviour that reads as "pulled to the wrist" must be reproduced in a test
first (palm valid, yet wrist chosen or wrist-offset pose produced), then
fixed.

**Throw velocity consensus** (replaces the unweighted 5-sample mean):
ring buffer of the last ~10 per-frame velocities; on release discard the
newest 2 samples (release-corruption dead-zone: the frames where fingers
peel off corrupt tracked velocity most); estimate from consensus over the
remaining samples: two samples agree when their difference is under
`consensus_tolerance` times the median sample magnitude (exported, default
to be earned-in); take the largest set of mutually agreeing samples and
return its mean. Ties go to the more recent set. Fewer than 4 usable
samples: fall back to the current mean. Angular velocity gets the same dead-zone but keeps
its existing estimator (smallest change that fixes the observed sideways
throws; revisit only if the earn-in still shows angular error).

**Tuned-value discipline:** `throw_velocity_scale`, `max_throw_speed`,
`max_throw_angular_speed`, smoothing speeds and every other exported tuning
value are untouched. New exports: `transit_speed` (m/s of perceived
distance) and `throw_deadzone_frames`, both with conservative defaults to be
earned-in on device.

## Architecture (approach A — transit as a phase, not a mode)

All changes inside the existing blocks:

- `xr_grab_interactable.gd`: a transit phase wrapped around the existing
  `_apply_movement` — states GRABBED_TRANSIT -> GRABBED_TRACKING. The
  `MovementType` enum and all three movement behaviours are unchanged and
  apply after (or during, for the tracked target) transit. Hold-where-grabbed
  is an offset composed into the desired transform before `_apply_movement`;
  KINEMATIC_SMOOTH and VELOCITY_TRACKED work unchanged on top.
- `xr_grab_point.gd`: palm-anchor resolution fix.
- Pure, headless-testable functions for: transit duration, transit
  interpolation state, offset capture, and the consensus estimator.

Rejected: a new `MovementType.TWEENED_ATTACH` (transit is a phase every grab
passes through once, not a steady-state policy — modeling it as a mode makes
the two orthogonal choices exclusive); a separate attach-driver node (splits
one object's motion across two owners exactly where a handoff pop would be
most visible).

## Testing

- Headless unit tests (same harness and bar as the conditioning work,
  mutation-tested FAIL-then-PASS): transit duration math including the
  rotation-dominant case; transit converges to live tracking with a moving
  target; hold-where-grabbed offset is exact at capture and stable under
  hand motion; consensus estimator rejects synthetic release-corrupted
  tails the current mean provably fails on; palm-vs-wrist anchor selection.
- Regression: both existing suites stay green.
- Earn-in (gate, one session): cubes never relocate in the hand; blaster/
  pen settle smoothly with no yank; throws land straight at several speeds;
  nothing feels worse than before. Feel-check scene already has everything
  needed.

## Out of scope (next designs)

Far/distance grab, conical selection + hysteresis, near/far arbitration,
teleport arc lifecycle, synthetic display hand (inventory item 4).
