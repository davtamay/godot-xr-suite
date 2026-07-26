# Poke fidelity: one decision, three surfaces

Status: approved design, 2026-07-25 (David). Implements item 6 of the ISDK
inventory (`Godot_WebXR_gh/docs/INNOVATION_BACKLOG.md`, entry 2026-07-24),
chosen after the poke path was read end to end.

## Licensing boundary

Technique implemented from the published description only. No ISDK code read
for implementation, copied, or adapted (Oculus SDK License, incompatible).
Any Meta constant is an order-of-magnitude sanity check, never a shipped
value. The primary gate below is deliberately NOT Meta's technique — see
"The gate is two tests".

## What already exists (corrects the inventory)

The inventory says `xr_pokeable.gd` has press/release depth only, and implies
poke is one system. Both are wrong in ways that change the scope.

There are **three independent poke implementations**:

| | Depth source | Press / release | Driven by |
|---|---|---|---|
| `XRPokeable` | dot along chosen face normal | `press_depth` 0.012 / `release_depth` 0.04 | `poke_update` from the interactor |
| `XRUICanvasInteractable` | `local.z` | same two, same defaults | `poke_update`, pushes synthetic mouse |
| `XRPokeButton` | cylinder test, cap travel | `press_fraction` 0.7, re-arm at half | **self-polls the group**, bypasses `poke_update` |

Consequences that scope this work:

- **`XRPokeable` has zero consumers.** Not one sample scene, not one test,
  despite being the block the dock advertises as "make ANY body pokeable". The
  poke that has earned in on device is `XRPokeButton` + `XRUICanvasInteractable`
  (`control_panel_demo`, `poke_playground_demo`, `XRPokeStation`). Evidence
  about those two is not evidence about `XRPokeable`.
- **Nothing anywhere tests approach direction.** All three test depth along an
  axis. The interactor sphere-queries at `poke_reach = 0.12` and dispatches
  `poke_update` to every target within 12 cm
  (`xr_poke_interactor.gd:174`), so a hand sweeping laterally across a row of
  buttons at surface depth presses each one in turn. This is the failure that
  limits how densely buttons can be authored.
- **Slide-off is indistinguishable from a deliberate release.**
  `xr_pokeable.gd:74` — leaving `half_size` calls `poke_end`, which emits
  `released`. Buttons conventionally fire on release, so an aborted press
  ACTIVATES the button. There is no `cancelled`.
- **`XRPokeButton` drops a genuinely fast poke.** `xr_poke_button.gd:66` —
  `local.y < -0.01: continue` skips a fingertip that reached below the base
  within one physics sample rather than clamping it to full travel. At 60 Hz a
  1.5 m/s poke moves 25 mm against 22 mm of default travel, so this is
  reachable. The other two are NOT affected: their valid bands are 52 mm and
  72 mm, needing >3 m/s to skip. No fix is proposed for them.
- **No visual pinning.** The marker dot passes through the surface.

Two structural constraints found while designing:

- `XRUICanvasInteractable extends XRBaseInteractable`, so a shared **base
  class** for poke targets is impossible. Composition only.
- `XRPokeButton` has **no collider at all**, which is why it self-polls; the
  interactor's own comment records this (`xr_poke_interactor.gd:92`).
  Unifying dispatch would mean adding an `Area3D` and putting it on
  `poke_collision_mask`, a scene-visible change to an earned-in path.

## Design

**One evaluator, three thin adapters. Dispatch is unchanged.**

New `runtime/poke/xr_poke_evaluator.gd`, a `RefCounted` — not a node. It owns
the entire press decision and nothing else: per-source entry state, smoothed
approach direction, depth band, hysteresis, bounds, cancel state, pinned
contact point. One call:

```
evaluate(source_id, local_point, delta) -> { event, depth_ratio, pinned_point }
```

`event` is `NONE | PRESSED | RELEASED | CANCELLED | DRAG`. `depth_ratio` is
penetration past the press plane normalized to `press_depth`, clamped to
0..1 — so an adapter can drive an animation from it without knowing the
units.

**Canonical frame.** Adapters hand the evaluator points in one convention:
**+Z is the outward normal and z is distance IN FRONT of the surface**, so the
surface is z = 0, a press fires at `z <= press_depth` and re-arms at
`z > release_depth`. This is `XRPokeable`'s existing convention verbatim, which
is why its thresholds carry over unchanged. `XRPokeable` folds its
`poke_face` into that rotation, the canvas is already there, `XRPokeButton`
maps +Y→+Z. The evaluator then has no concept of faces, panels or caps, which
is what lets one implementation serve three call sites.

| Adapter | Keeps | Delegates |
|---|---|---|
| `XRPokeable` | world→local along `poke_face`, signals | the press decision; gains `cancelled` |
| `XRUICanvasInteractable` | `local.z`, synthetic mouse, drag-as-motion | the press decision |
| `XRPokeButton` | self-polling, cylinder test, cap animation | press/release threshold, approach gate |

`XRPokeButton`'s units map onto the canonical frame rather than changing.
Its surface is the BOTTOMED-OUT cap position, so with cap penetration
`p = clamp(cap_rest_top - finger_bottom, 0, travel)` the canonical
`z = travel - p`, and its thresholds become:

```
press_depth   = travel * (1.0 - press_fraction)
release_depth = travel * (1.0 - press_fraction * 0.5)
```

At today's defaults (`travel` 0.022, `press_fraction` 0.7) that is 0.0066 and
0.0143. These are algebraically the same firing points the button uses now —
`p >= travel * press_fraction` to fire, `p <= travel * press_fraction * 0.5`
to re-arm — so the cap's feel is arithmetically unchanged. (An earlier draft
wrote `press_depth = travel * press_fraction`, which is the complement and
would have fired the button roughly twice as early.)

The button passes `half_size = Vector2.ZERO` (unbounded) and keeps its own
cylinder test, calling `forget(source_id)` when the point leaves the cap
radius. That is the per-adapter world→local work, not evaluator business.

`XRPokeButton` keeps self-polling. Giving it a collider to unify dispatch
changes physics layers on a path already earned in on device and buys nothing
the evaluator does not already give it. Lowest-risk layer that solves the
problem.

The one thing left duplicated by design is each adapter's world→local
conversion, because each genuinely differs. That is ~5 lines each and it is
the part that SHOULD differ.

### The gate is two tests, OR'd

Meta's published technique is a minimum approach angle. An earlier draft of
this design made a stateful entry test the primary and demoted the angle to a
refinement. Working the cases disproved that: **neither test dominates, and
each covers exactly the other's false negative.** The gate arms if EITHER
passes.

1. **Entry-through-face (stateful).** A source may only arm if it was
   previously observed **in-bounds and in front of the press plane**. A finger
   that slid in laterally at depth was never in front of the face.

2. **Approach angle (directional).** Require the travel vector to point
   inward within `max_approach_angle`, checked against EITHER of two spans:
   the short sample window as a whole, or just the most recent step. The
   whole-window check is what a normal approach satisfies. The recent-step
   check exists because a source that skims laterally within `press_depth` of
   the surface (so entry-through-face never arms) and then sharply changes
   direction inward has that direction change diluted below the limit when
   measured over the whole window - the lateral skim baked into the rest of
   the window outweighs a clean, steep final step. Checking the last step
   alone catches it without weakening the window check's rejection of an
   ordinary sweep (revised after I5 found the single-window version rejected
   this case).

| Case | Entry-through-face | Approach angle |
|---|---|---|
| Lateral sweep across a button row | blocks | blocks |
| Slide from one target to the next at depth | blocks | blocks |
| Approach from behind the surface | blocks | blocks |
| Sweep in from outside the bounds rectangle, then hold still | blocks | blocks (see abstain rule below) |
| Steep but deliberate poke (~50 deg off normal) | arms | FALSELY REJECTS |
| Fast diagonal poke: previous sample laterally out of bounds, next sample already past depth | FALSELY REJECTS | arms |
| Skim below `press_depth` along the surface, then a sharp jab inward | blocks (never in front) | arms (recent-step check) |

Every rejection case is blocked by both, so `OR` does not weaken the sweep
rejection that motivated the gate. The three false-negative rows are each
rescued by the other test. `AND` would ship all three false negatives; either
test alone ships some of them.

**Neither test needs a square root.** The angle comparison squares instead of
normalizing:

```
inward := t.z <= 0
within := t.z * t.z >= cos_max_angle_squared * t.length_squared()
```

So cost is not a reason to prefer one — a handful of multiplies on values the
adapter has already computed. Coverage is the only reason, and it points to
both.

**Abstain rule** on the angle test: if the displacement being checked (window
or recent-step, see above) is under `min_approach_travel` (~3 mm), the
direction is noise. This was originally specified — and first shipped — as an
unconditional pass, and that was wrong: in the `OR` gate an unconditional pass
arms the press **by itself**, which `require_entry_through_face` cannot veto.
Verified empirically: a source that sweeps in from outside the bounds
rectangle at press depth and then holds still presses after about 3 frames —
the time it takes the fast sweep samples to age out of the four-entry history
window and leave the angle test comparing the held point against itself. The
real failure mode was not "a sweep presses nothing", it was "a sweep presses
whichever key you stop on", with no sample ever in front of that key's face.

The rule actually implemented: abstaining returns `not
require_entry_through_face` — it DEFERS to the entry test rather than passing
outright. With entry-through-face required (the default), an abstention no
longer arms the gate on its own; a genuine slow creep-in is still armed, but
by the entry test, because it WAS seen in front of the face first. Only with
`require_entry_through_face` turned off does the abstain pass outright, since
then the angle test is the only gate left and a slow deliberate motion should
not be rejected purely for lacking speed.

Entry-through-face also fixes `XRPokeButton`'s dropped fast poke: a source
that WAS in front and is now below the base is clamped to full travel instead
of skipped, because we know it came through the cap.

**The sample history survives a bounds or band exit; only a lost source clears
it.** This is load-bearing, not incidental. The fast-diagonal rescue depends
on comparing a sample that fell OUTSIDE the face rectangle with the next one
inside it — clearing history on the bounds exit would leave the angle test
with a single sample and no travel vector, and the rescue case would silently
stop working while still reading as implemented. An adapter calling
`forget(source_id)` because the source is genuinely gone clears everything.

### Cancel

While pressed: leaving bounds, or losing the source, emits `CANCELLED`.
Retracting past `release_depth` while in bounds emits `RELEASED`. `XRPokeable`
gains `cancelled(hand)`.

The canvas maps `CANCELLED` to a motion event positioned OUTSIDE the panel
followed by mouse-up, so Godot `Control` buttons clear their pressed state
without emitting. That is the standard `Control` contract, not a workaround.

### Drag versus press

Opt-in, off by default: `interpret_drag := false`. When enabled, in-plane
travel past `drag_threshold` while pressed emits `DRAG` carrying the planar
delta, and suppresses the terminal `RELEASED` *activation* — so a target
authored as a drag handle cannot also fire as a button on let-go. Retracting
past `release_depth` while dragging emits a distinct `DRAG_ENDED` rather than
`NONE`: suppressing the activation must not also suppress the only
notification a consumer gets that the drag is over at all, or a target driven
purely by `pressed`/`released`/`cancelled` (a colour that resets on a
terminal signal, say) is stuck in its held state after the first completed
drag. `XRPokeable` exposes this as `drag_ended(hand)`. The canvas does not use
any of this; it already gets drag free from mouse motion while pressed.

### Pinning

The evaluator returns `pinned_point`: the local point with z clamped to >= 0.
Adapters expose `get_poke_pin(hand) -> Vector3` (`INF` when none) and
`XRPokeInteractor` prefers it over the raw fingertip when drawing the marker.
The dot then stops on the surface and press depth reads visually.

The rendered HAND still passes through the surface. Posing it requires a
runtime consumer for `xr_hand_pose_math.gd` — whose only callers today are
`xr_simulator.gd:534` and `xr_grab_point.gd:220` (editor preview only) — and
that is explicitly out of scope here.

### Authoring surface

Every evaluator parameter is exposed on all three adapters under a `Poke Feel`
group with ranges and doc comments, AND a new `XRPokeProfile` **Resource**
lets a project author one feel once and assign it to every poke target. This
follows `XRFeedbackTheme`, the pattern the suite already establishes for
scene-wide feel.

**Precedence: an assigned profile wins; the node's own exports are the
fallback.** An earlier draft said per-target exports override the profile,
which is not implementable — Godot cannot distinguish an export left at its
default from one an author deliberately set to that same value, so "overrides"
would mean "silently ignores the profile whenever the default happens to
match". One rule, no ambiguity: `poke_profile == null` uses the node's
exports, otherwise the profile supplies every property it carries.

This is the part that has to beat parity rather than match it: a designer
tunes press depth and gate angle in one `.tres` and the whole project moves.

### Station extension

`XRPokeStation` gains a dense button row that is only usable BECAUSE of the
gate, a drag handle, and a slide-off-to-cancel target. These are the first
`XRPokeable` consumers in the suite. `poke_playground_demo` picks them up
through the station.

## Testing

Headless, mutation-proven FAIL-then-PASS, in `tests/test_poke_fidelity.gd`,
driving the evaluator directly with synthetic point sequences:

| Case | Expected |
|---|---|
| Normal approach through the face | `PRESSED` once |
| Lateral sweep at press depth across bounds | no press, ever |
| Sweep in from outside bounds, then hold still (history ages out) | no press, ever |
| Slow creep-in from in front of the face | `PRESSED` (rescued by entry-through-face) |
| Slow creep-in with entry-through-face off | `PRESSED` (the angle test's abstain carries it) |
| Slide off while pressed | `CANCELLED`, never `RELEASED` |
| Jitter at the press plane | no chatter |
| Fast pass-through in one sample | `PRESSED` once, depth clamped |
| Pinned point | z clamped to 0 |
| Drag past `drag_threshold` with `interpret_drag` on | `DRAG` deltas, no terminal `RELEASED` |
| Drag retracting past `release_depth` | `DRAG_ENDED`, never `RELEASED` |
| Same motion with `interpret_drag` off | no `DRAG`, normal `RELEASED` |
| Steep deliberate poke, ~50 deg off normal | `PRESSED` (entry test rescues it) |
| Fast diagonal, previous sample out of bounds | `PRESSED` (angle test rescues it) |
| Skim below `press_depth`, then a sharp jab inward | `PRESSED` (recent-step check rescues it) |

The sweep-then-dwell row is the one the abstain rule got wrong until I1: the
old unconditional-pass abstain pressed once the sweep's early samples aged
out of the history window, with no sample ever in front of the face. The
steep-poke, fast-diagonal, and skim-then-jab rows are the whole argument for
`OR` and the recent-step check, and must be written so each FAILS when its
rescuing test is disabled alone. A suite that passes them with the rescuing
mechanism switched off is not testing the composition.

Plus adapter-level signal-mapping tests with a fake target, confirming each
adapter translates evaluator events to its own contract.

Mutation runs that MUST fail the suite: invert `require_entry_through_face`;
delete the abstain rule; emit `RELEASED` where `CANCELLED` is specified; widen
`max_approach_angle` to 180°; **change the gate's `OR` to `AND`** (this one
must fail on the two rescue rows specifically, and it is the mutation most
likely to pass a lazily written suite). A suite that passes against any of those is
worse than none — this project has shipped two such suites and the mutation
run caught both.

Fixtures must move the point across frames. A fixture that teleports a point
to its final position cannot detect a missing approach gate, because the gate
reads travel direction — the failure this suite is most likely to miss.

## Earn-in (gate)

This changes on-device-tuned behaviour, so it does not merge on headless
evidence.

`control_panel_demo` and `poke_playground_demo` on Quest, before and after:
the three `XRPokeButton`s and the `TouchPanel` must feel IDENTICAL. Then the
new dense row for the sweep case, and the drag handle for the cancel case.

Revert lever is one line: `max_approach_angle = 90` and
`require_entry_through_face = false` restore today's behaviour exactly. Both
defaults are shipped as authorable exports precisely so the revert needs no
code change.

## Out of scope

- **Unifying dispatch.** The three dispatch paths stay three. This unifies the
  DECISION, not the plumbing. Making `XRPokeButton` collider-driven is a
  separate change with a physics-layer cost on a working path.
- **Runtime hand posing.** The rendered hand continues to pass through
  surfaces. Item 4 (synthetic/display hand) owns that, and it is larger.
- **Fast-poke fixes for the canvas and `XRPokeable`.** Measured as not needed:
  52 mm and 72 mm valid bands need >3 m/s to skip. Claiming a fix there would
  be fixing an unmeasured problem.
- Items 4, 5 and 8 of the inventory.
