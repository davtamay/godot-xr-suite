# Far grab: the object declares what "grab" means

Status: approved design, 2026-07-26 (David).

## The reported problem

Far-grab push/pull "doesn't seem to work well". It is implemented —
`enable_motion_distance_manipulation` is on by default with
`distance_motion_scale = 3.0` — so this is a design fault, not a gap.

## Root cause, from the code

`xr_ray_interactor.gd`:

```gdscript
var movement := origin - _last_ray_origin
_pending_distance_delta += movement.dot(_last_ray_direction.normalized()) * distance_motion_scale
```

Hand motion is projected onto the **live** ray direction, so **aiming and
reeling are the same input**. Pulling your arm back also tilts the ray; at 4 m
a couple of degrees swings the object a long way, so it slews sideways while
you are trying to wind it in. And a ~25 cm arm pull at ×3 is 75 cm of reel —
several re-aiming pulls to bring in something across a room.

## What the incumbents do, and why it matters

- **Unity XRI** puts distance on a **separate axis** (`allowAnchorControl`,
  `translateSpeed`), driven by the thumbstick — deliberately not the hand,
  because the hand is aiming.
- **Meta ISDK** mostly does not reel at all: distance grab **attracts** the
  object to the hand.

Two teams solving the same problem both routed around continuous arm-driven
reeling. That convergence is the strongest evidence available, and it says the
mechanic is the problem rather than our tuning of it.

**Rejected: hand-to-shoulder distance.** More intuitive on first contact —
pulling something toward you needs no explanation — but usable arm travel is
30–50 cm against an object range of 0.25–6 m. That is ~10× gain, which
multiplies hand-tracking jitter by 10 and leaves no fine control at range.
Worse, **you run out of arm**: reaching your shoulder ends the gesture, so it
needs ratcheting, which reintroduces the drift and mode-confusion being fixed.
Wrist roll has ~180° of travel and does not drift. Twist survives contact with
the range problem; arm-pull does not.

## Design

**The object declares intent; the ray owns distance state.**

`XRGrabInteractable`:

```gdscript
enum FarGrabMode { ATTRACT, FIXED, REEL }
@export var far_grab_mode := FarGrabMode.ATTRACT
```

`XRRayInteractor` reads the mode from what it selected. Its existing exports
(`distance_motion_scale`, `max_distance_change_per_second`,
`reel_to_grip_distance`) stop being policy and become **limits REEL obeys** —
re-scoped, not deleted.

| Mode | Behaviour | Built from |
|---|---|---|
| **ATTRACT** (default) | The held distance is driven to the grip on select; the object tweens in and latches as a real hold. | `_grab_distance = floor_distance` at select + the existing `_arm_transit` tween + the existing `_grip_latched` latch |
| **FIXED** | Distance frozen where it was grabbed. Follows aim. Never reels, never attracts. Still clamped by `min_grab_distance`. | Motion manipulation and reel-to-grip both off for this object |
| **REEL** | Today's behaviour, minus the coupling bug. | Existing path + the axis fix below |

**ATTRACT adds almost no new machinery, and that is the point.** It composes
two mechanisms already earned in on device — the transit tween from inventory
item 1, and the reel-to-grip latch — rather than introducing a third motion
path that would have to earn in from scratch.

### The coupling fix (REEL only, and a bug fix regardless)

Capture the reel axis once, at select:

```gdscript
var _reel_axis := Vector3.FORWARD
```

and project onto it instead of the live `_last_ray_direction`. Aiming no
longer changes what "pull" means. This is correct independently of which mode
wins, so it lands even though REEL is no longer the default.

### Resolved: the two interactions flagged during design

- **ATTRACT with two-hand grab.** No special case. `_arm_transit` is already
  re-armed when a second hand joins — the existing code carries a comment
  about avoiding a stale `_transit_from` for exactly this — so the tween
  restarts correctly on its own.
- **FIXED when you walk up to the object.** It stays fixed. That is the whole
  meaning of the mode, and adding a proximity blend would make the one
  predictable option unpredictable. `min_grab_distance` still clamps, so it
  cannot end up inside the wearer.

### Phase 2: pinch-and-twist

For the placement case, where holding at range is the actual intent.

**Pinch cannot drive it.** Pinch *is* grab, so thumb-and-index are occupied
the moment a far-grab starts. The wrist is not: roll is uncommitted during a
pinch, gives ~180° of comfortable travel, and is decoupled from aim because
roll is *around* the ray axis rather than across it. Meta ships this shape in
the Hand Tracking Template (`PinchAndTwistEventSource`,
`UpdateSliderOnPinchAndTwist`) as a value driver, which is what reeling is.

Placement follows `xr_microgesture_locomotion_driver.gd`, which already lives
in the toolkit and is inert without `godot_xr_hands`: a
`xr_pinch_twist_distance_driver.gd` in the same place, calling a public
`adjust_grab_distance(delta)` on the ray. `xr.interaction` keeps
`requires=[]` and stays installable standalone — no DAG inversion.

Known ergonomic risk: sustained pronation while holding a pinch is fatiguing.
That is a measurement for the earn-in, not something to assume away.

## Testing

Headless, mutation-proven, driving the ray interactor's distance state
directly (an XR session cannot be stood up in a test):

| Case | Expected |
|---|---|
| ATTRACT on select | held distance goes to the grip floor, not the hit distance |
| ATTRACT | latches; does not reel back out along the ray |
| FIXED on select | held distance equals the hit distance |
| FIXED | hand motion along the ray changes nothing |
| FIXED | still clamped by `min_grab_distance` |
| REEL | hand motion along the ray still changes distance |
| REEL + aim change | rotating the ray after select does NOT change the reel response |
| Unspecified mode | behaves as ATTRACT |

The aim-change row is the coupling fix's guard and the one most likely to be
written weakly: it must rotate the ray *between* samples and assert the
distance delta is unchanged, not merely that some delta occurred.

## Earn-in (required — ATTRACT changes every existing far-grabbable)

The default moves from REEL to ATTRACT, so this is a `CLAUDE.md`
stop-condition and does not merge on headless evidence.

| Check | Pass condition |
|---|---|
| Far-grab any object | comes to the hand and stays; feels like a grab, not a launch |
| Far-grab something heavy/large | the tween does not overshoot or snap |
| An object authored FIXED | holds its distance, follows aim, never drifts in |
| An object authored REEL | reels, and rotating the ray mid-pull no longer swings it |
| Two-hand grab an attracted object | second hand joins without a jump |
| Near-grab anything | unchanged |

Revert lever: set `far_grab_mode = REEL` — the previous default — with no code
change.

## Out of scope

Recoil assist with velocity-dependent window expansion (inventory item 6's
remaining piece), hand-to-shoulder distance (rejected above), and any change
to near/direct grab.

## Amendment (2026-07-26, from the first ATTRACT earn-in)

Three findings from the headset, all of which change the design rather than
just its tuning.

### ATTRACT must target the adapter's grip pose, not a distance along the ray

Reported: "still there is distance with the attract one, i think it should go
straight to our hand". Correct, and the cause is a wiring gap.

`_resolve_grab_pose` reels a held object into the grip, but sources that grip
from `suppress_interactor_path` — and **that property is set in no scene in the
repository**. So `_grip_pose()` always returns `{"valid": false}`, the
reel-to-grip blend and latch never fire at all, and ATTRACT parks the object at
`min_grab_distance` (0.25 m) *in front of* the hand.

The original design said ATTRACT would compose the existing grip latch. That
was true of the code path and false in practice, because nothing configures the
path's one prerequisite. **ATTRACT now targets `_adapter.get_grip_pose(hand)`
directly**, which is always available and needs no scene wiring.

### The `grip_latched` ray hide was duplicate machinery

A proximity-based hide already exists — `hide_ray_when_held_within`, default
0.25, comparing the held object against the adapter's real grip origin
(commit `2944a22`, predating this branch). The `grip_latched` flag added during
this work keys off a latch that never fires, so it could never hide anything,
and it duplicates a mechanism that already works off a better signal.

Removed. Once ATTRACT actually delivers the object to the hand, the existing
proximity hide takes care of the ray by itself. Two symptoms, one cause, one
fix.

### Attract speed and easing are authorable, and separate from `transit_speed`

Reported: "as far as fast, anything appealing to the eye, it is too snappy,
maybe thats something to expose an authoring field".

`transit_speed` is shared with near-grab feel that is already earned in, so
moving it would drag settled behaviour along. A separate
`far_grab_attract_speed` on the interactable lets a heavy crate arrive
differently from a thrown ball — the authorability angle this whole feature
exists to serve.

"Too snappy" is also the easing, not only the speed: `transit_blend` is linear,
so the object travels at constant velocity and stops dead. An ease-out makes it
decelerate into the hand, which reads as arriving rather than colliding.

### What this says about the original design claim

"ATTRACT adds almost no new machinery — it composes two mechanisms already
earned in on device" was asserted from reading the transit and latch code
without checking either one's preconditions. The transit had a guard at the top
that excluded ordinary grabbables; the latch had a prerequisite nothing
configures. Both were found in the headset, neither by a passing suite.
