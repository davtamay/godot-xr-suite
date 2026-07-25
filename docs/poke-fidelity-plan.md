# Poke Fidelity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Centralize the poke press decision in one evaluator that all three
poke surfaces share, and gate arming on approach so a hand sweeping across a
dense button row no longer presses every button it crosses.

**Architecture:** A `RefCounted` evaluator owns the entire press decision in a
canonical frame (+Z outward, z = distance in front of the surface). Three
adapters — `XRPokeable`, `XRUICanvasInteractable`, `XRPokeButton` — keep their
own world→local conversion and their own dispatch, and delegate the decision.
Dispatch is deliberately NOT unified: `XRPokeButton` has no collider and keeps
self-polling.

**Tech Stack:** Godot 4.7 stable, GDScript. No new dependencies. No
GDExtension (web export ships `extensions_support=false`).

Design: `docs/poke-fidelity-design.md`. Read it before Task 1.

## Global Constraints

- **Godot binary:** `C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe`
  (v4.7.stable.official.5b4e0cb0f). Not on `PATH`; use the full path.
- **`--xr-mode off` on EVERY headless invocation**, or Godot hangs forever.
- **Demo project path:** `C:\Users\davta\Repos\Godot_WebXR_gh\demo`. Its
  `addons/*` are SYMLINKS into this repo's working tree, so edits here are
  live in the demo with no copy step.
- **Every file touched by this plan is TAB-indented.** Verified:
  `xr_pokeable.gd`, `xr_poke_button.gd`, `xr_ui_canvas_interactable.gd`,
  `xr_poke_interactor.gd`, `tests/test_grab_feel.gd`. Mixing tabs and spaces
  inside one file is a GDScript parse error. New files in this plan use tabs.
- **Use the Edit tool, never scripted pattern replacement.** Silent no-op
  matches have been reported as successful fixes on this project before.
- **Count `ERROR:` as well as `SCRIPT ERROR` and `Parse Error`** when checking
  boot. A real bug hid behind that gap for hours.
- **Do not change any default that alters on-device-tuned feel** beyond what
  this plan specifies. `XRPokeButton`'s firing points are preserved
  algebraically, not re-tuned.
- **No ISDK code.** Technique only; Meta constants are order-of-magnitude
  sanity checks, never shipped values.
- **Canonical frame (memorize):** +Z is the outward normal, `z` is distance IN
  FRONT of the surface, surface at `z = 0`. Press fires at `z <= press_depth`,
  re-arms at `z > release_depth`.

---

### Task 1: The evaluator

**Files:**
- Create: `addons/godot_xr_interaction_toolkit/runtime/poke/xr_poke_evaluator.gd`
- Test: `addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd`

**Interfaces:**
- Consumes: nothing.
- Produces: `XRPokeEvaluator` (`RefCounted`) with
  `enum Event { NONE, PRESSED, RELEASED, CANCELLED, DRAG }`;
  config properties `press_depth: float`, `release_depth: float`,
  `half_size: Vector2`, `require_entry_through_face: bool`,
  `max_approach_angle: float`, `min_approach_travel: float`,
  `interpret_drag: bool`, `drag_threshold: float`;
  `evaluate(source_id: int, point: Vector3) -> Dictionary` returning keys
  `event: Event`, `depth_ratio: float`, `pinned_point: Vector3`,
  `drag_delta: Vector2`; `forget(source_id: int) -> Event`;
  `apply_profile(profile) -> void`.

- [ ] **Step 1: Write the failing test file**

Create `addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd`
(TABS):

```gdscript
extends SceneTree

## Headless tests for poke fidelity (docs/poke-fidelity-design.md).
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd

const XRPokeEvaluator := preload("res://addons/godot_xr_interaction_toolkit/runtime/poke/xr_poke_evaluator.gd")

var _failures: Array[String] = []


func _init() -> void:
	_test_normal_approach_presses_once(_failures)
	_test_lateral_sweep_never_presses(_failures)
	_test_slow_creep_abstains_and_presses(_failures)
	_test_slide_off_cancels_not_releases(_failures)
	_test_jitter_does_not_chatter(_failures)
	_test_fast_pass_through_presses_once(_failures)
	_test_pinned_point_clamps_to_surface(_failures)
	_test_drag_on_suppresses_release(_failures)
	_test_drag_off_still_releases(_failures)
	_test_steep_poke_rescued_by_entry(_failures)
	_test_fast_diagonal_rescued_by_angle(_failures)
	if _failures.is_empty():
		print("XR poke fidelity: PASS")
		quit(0)
		return
	for failure in _failures:
		printerr("FAIL: %s" % failure)
	printerr("XR poke fidelity: %d FAILURE(S)" % _failures.size())
	quit(1)


## A default evaluator: XRPokeable's shipped thresholds.
func _make() -> RefCounted:
	var evaluator = XRPokeEvaluator.new()
	evaluator.press_depth = 0.012
	evaluator.release_depth = 0.04
	evaluator.half_size = Vector2(0.05, 0.05)
	return evaluator


## Feed a point sequence, collect the event per sample.
func _run(evaluator, points: Array) -> Array:
	var events := []
	for point in points:
		events.append(evaluator.evaluate(0, point)["event"])
	return events


func _count(events: Array, event: int) -> int:
	var total := 0
	for candidate in events:
		if candidate == event:
			total += 1
	return total


func _check(failures: Array[String], condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _test_normal_approach_presses_once(failures: Array[String]) -> void:
	var evaluator = _make()
	var events := _run(evaluator, [
		Vector3(0.0, 0.0, 0.100),
		Vector3(0.0, 0.0, 0.060),
		Vector3(0.0, 0.0, 0.030),
		Vector3(0.0, 0.0, 0.008),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.PRESSED) == 1,
			"normal approach: expected exactly 1 PRESSED, got %s" % [events])


func _test_lateral_sweep_never_presses(failures: Array[String]) -> void:
	# Enters from OUTSIDE the face rectangle, already at press depth, and
	# sweeps across. This is the failure the gate exists to prevent.
	var evaluator = _make()
	var events := _run(evaluator, [
		Vector3(0.200, 0.0, 0.008),
		Vector3(0.030, 0.0, 0.008),
		Vector3(0.000, 0.0, 0.008),
		Vector3(-0.030, 0.0, 0.008),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.PRESSED) == 0,
			"lateral sweep: expected no PRESSED, got %s" % [events])


## Isolates the ABSTAIN rule. Two constraints make this test actually test it:
## the entry test must stay REQUIRED (so it cannot supply the pass), and the
## motion must carry a LATERAL component. A purely axial creep satisfies the
## angle test at any magnitude, so an axial fixture would pass with the
## abstain deleted - which is exactly the mutation this must catch.
func _test_slow_creep_abstains_and_presses(failures: Array[String]) -> void:
	var evaluator = _make()
	evaluator.require_entry_through_face = true
	evaluator.min_approach_travel = 0.003
	# Both samples are already at press depth, so in_front is never set and
	# only the angle test can arm. Window travel is 1.5 mm, mostly sideways.
	var events := _run(evaluator, [
		Vector3(0.0000, 0.0, 0.0110),
		Vector3(0.0015, 0.0, 0.0108),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.PRESSED) == 1,
			"slow creep: expected 1 PRESSED via abstain, got %s" % [events])


func _test_slide_off_cancels_not_releases(failures: Array[String]) -> void:
	var evaluator = _make()
	var events := _run(evaluator, [
		Vector3(0.0, 0.0, 0.050),
		Vector3(0.0, 0.0, 0.008),
		Vector3(0.080, 0.0, 0.008),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.CANCELLED) == 1,
			"slide off: expected 1 CANCELLED, got %s" % [events])
	_check(failures, _count(events, XRPokeEvaluator.Event.RELEASED) == 0,
			"slide off: expected no RELEASED, got %s" % [events])


func _test_jitter_does_not_chatter(failures: Array[String]) -> void:
	var evaluator = _make()
	var events := _run(evaluator, [
		Vector3(0.0, 0.0, 0.050),
		Vector3(0.0, 0.0, 0.008),
		Vector3(0.0, 0.0, 0.014),
		Vector3(0.0, 0.0, 0.010),
		Vector3(0.0, 0.0, 0.013),
		Vector3(0.0, 0.0, 0.009),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.PRESSED) == 1,
			"jitter: expected 1 PRESSED, got %s" % [events])
	_check(failures, _count(events, XRPokeEvaluator.Event.RELEASED) == 0,
			"jitter: expected no RELEASED, got %s" % [events])


func _test_fast_pass_through_presses_once(failures: Array[String]) -> void:
	# One sample in front, the next already past the surface.
	var evaluator = _make()
	var events := _run(evaluator, [
		Vector3(0.0, 0.0, 0.200),
		Vector3(0.0, 0.0, -0.020),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.PRESSED) == 1,
			"fast pass-through: expected 1 PRESSED, got %s" % [events])


func _test_pinned_point_clamps_to_surface(failures: Array[String]) -> void:
	var evaluator = _make()
	evaluator.evaluate(0, Vector3(0.0, 0.0, 0.050))
	var result: Dictionary = evaluator.evaluate(0, Vector3(0.010, 0.020, -0.030))
	var pinned: Vector3 = result["pinned_point"]
	_check(failures, is_equal_approx(pinned.z, 0.0),
			"pinned point: expected z clamped to 0, got %f" % pinned.z)
	_check(failures, is_equal_approx(pinned.x, 0.010) and is_equal_approx(pinned.y, 0.020),
			"pinned point: planar coordinates must pass through, got %s" % [pinned])


func _test_drag_on_suppresses_release(failures: Array[String]) -> void:
	var evaluator = _make()
	evaluator.interpret_drag = true
	evaluator.drag_threshold = 0.010
	var events := _run(evaluator, [
		Vector3(0.0, 0.0, 0.050),
		Vector3(0.0, 0.0, 0.008),
		Vector3(0.020, 0.0, 0.008),
		Vector3(0.020, 0.0, 0.050),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.DRAG) >= 1,
			"drag on: expected at least 1 DRAG, got %s" % [events])
	_check(failures, _count(events, XRPokeEvaluator.Event.RELEASED) == 0,
			"drag on: RELEASED must be suppressed, got %s" % [events])


func _test_drag_off_still_releases(failures: Array[String]) -> void:
	var evaluator = _make()
	evaluator.interpret_drag = false
	var events := _run(evaluator, [
		Vector3(0.0, 0.0, 0.050),
		Vector3(0.0, 0.0, 0.008),
		Vector3(0.020, 0.0, 0.008),
		Vector3(0.020, 0.0, 0.050),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.DRAG) == 0,
			"drag off: expected no DRAG, got %s" % [events])
	_check(failures, _count(events, XRPokeEvaluator.Event.RELEASED) == 1,
			"drag off: expected 1 RELEASED, got %s" % [events])


## RESCUE CASE A. A deliberate poke ~50 deg off the normal, at a 45 deg limit.
## The angle test rejects it; the entry test must rescue it.
##
## TRAP: do NOT isolate by setting require_entry_through_face = false. That
## OPENS the gate unconditionally (_entry_passes returns true), so the press
## would still happen and the test would assert the opposite of what it looks
## like it asserts. Isolate instead by making the FIRST sample land outside
## the face, so in_front is never set and only the angle test remains.
func _test_steep_poke_rescued_by_entry(failures: Array[String]) -> void:
	var armed_evaluator = _make()
	armed_evaluator.half_size = Vector2(0.200, 0.200)
	armed_evaluator.max_approach_angle = 45.0
	var armed := _run(armed_evaluator, [
		Vector3(0.000, 0.0, 0.050),
		Vector3(0.060, 0.0, 0.000),
	])
	_check(failures, _count(armed, XRPokeEvaluator.Event.PRESSED) == 1,
			"steep poke: the entry test must rescue it, got %s" % [armed])

	var blocked_evaluator = _make()
	blocked_evaluator.half_size = Vector2(0.200, 0.200)
	blocked_evaluator.max_approach_angle = 45.0
	var blocked := _run(blocked_evaluator, [
		Vector3(0.300, 0.0, 0.050),
		Vector3(0.060, 0.0, 0.000),
	])
	_check(failures, _count(blocked, XRPokeEvaluator.Event.PRESSED) == 0,
			"steep poke: without entry through the face there must be no press, got %s" % [blocked])


## RESCUE CASE B. A fast diagonal whose PREVIOUS sample fell outside the face
## rectangle, so the entry test never armed. The angle test must rescue it.
func _test_fast_diagonal_rescued_by_angle(failures: Array[String]) -> void:
	var points := [
		Vector3(0.060, 0.0, 0.050),
		Vector3(0.000, 0.0, -0.001),
	]
	var with_angle = _make()
	var armed := _run(with_angle, points)
	_check(failures, _count(armed, XRPokeEvaluator.Event.PRESSED) == 1,
			"fast diagonal: angle test must rescue it, got %s" % [armed])

	var without_angle = _make()
	without_angle.max_approach_angle = 0.0
	var blocked := _run(without_angle, points)
	_check(failures, _count(blocked, XRPokeEvaluator.Event.PRESSED) == 0,
			"fast diagonal: with the angle test closed there must be no press, got %s" % [blocked])
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe' --headless --xr-mode off --path 'C:\Users\davta\Repos\Godot_WebXR_gh\demo' --script 'res://addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd'
```

Expected: FAIL. The preload of `xr_poke_evaluator.gd` cannot resolve, so Godot
reports a parse/load error and exits non-zero. This is the correct first
failure — it proves the test is actually running the file under test.

- [ ] **Step 3: Write the evaluator**

Create `addons/godot_xr_interaction_toolkit/runtime/poke/xr_poke_evaluator.gd`
(TABS):

```gdscript
class_name XRPokeEvaluator
extends RefCounted

## The whole poke press decision, in one place, for all three poke surfaces
## (XRPokeable, XRUICanvasInteractable, XRPokeButton). Design:
## docs/poke-fidelity-design.md.
##
## CANONICAL FRAME: +Z is the outward normal and z is distance IN FRONT of the
## surface, so the surface is z = 0. A press fires at z <= press_depth and
## re-arms at z > release_depth. Adapters convert into this frame; the
## evaluator knows nothing about faces, panels or caps.
##
## ARMING IS THE OR OF TWO TESTS, neither of which dominates: a steep but
## deliberate poke is falsely rejected by the angle test, and a fast diagonal
## whose previous sample fell outside the bounds is falsely rejected by the
## entry test. Every case the gate exists to reject is rejected by both.

enum Event { NONE, PRESSED, RELEASED, CANCELLED, DRAG }

## Samples kept per source for the approach vector. Four is enough to span a
## real approach at 60-90 Hz without lagging a direction change.
const _HISTORY_MAX := 4

## Depth to press, and depth to re-arm (hysteresis stops flicker). Metres.
var press_depth := 0.012
var release_depth := 0.04
## Half-extents of the face rectangle. Zero on an axis = unbounded there;
## adapters with non-rectangular faces (a round cap) pass ZERO and run their
## own bounds test, calling forget() when the point leaves.
var half_size := Vector2(0.05, 0.05)

## Gate: the source must have been seen in-bounds and in FRONT of the press
## plane before it can arm. A finger that slid in laterally at depth never was.
var require_entry_through_face := true
## Gate: travel over the sample window must point inward within this angle.
## 90 makes it accept any inward motion.
var max_approach_angle := 60.0
## Below this window displacement the direction is noise and the angle test
## ABSTAINS (passes). Without this a slow deliberate creep-in is rejected,
## which is the worst failure this gate can produce.
var min_approach_travel := 0.003

## Opt-in: in-plane travel past drag_threshold while pressed reports DRAG and
## suppresses the terminal RELEASED, so a drag handle cannot also fire as a
## button on let-go.
var interpret_drag := false
var drag_threshold := 0.01

var _sources := {}


## Copy configuration from an XRPokeProfile. An assigned profile WINS; the
## adapter's own exports are the fallback (Godot cannot distinguish an export
## left at its default from one deliberately set to that value).
func apply_profile(profile) -> void:
	if profile == null:
		return
	press_depth = profile.press_depth
	release_depth = profile.release_depth
	require_entry_through_face = profile.require_entry_through_face
	max_approach_angle = profile.max_approach_angle
	min_approach_travel = profile.min_approach_travel


## One sample for one source, in the canonical frame.
func evaluate(source_id: int, point: Vector3) -> Dictionary:
	var state: Dictionary = _state_for(source_id)
	var result := {
		"event": Event.NONE,
		"depth_ratio": clampf(1.0 - point.z / maxf(press_depth, 0.0001), 0.0, 1.0),
		"pinned_point": Vector3(point.x, point.y, maxf(point.z, 0.0)),
		"drag_delta": Vector2.ZERO,
	}

	# History is appended BEFORE the bounds and band tests, and survives them.
	# The fast-diagonal rescue compares a sample outside the face rectangle
	# against the next one inside it; dropping the outside sample would leave
	# the angle test with no travel vector and the rescue would silently stop
	# working while still reading as implemented.
	var history: PackedVector3Array = state["history"]
	history.append(point)
	if history.size() > _HISTORY_MAX:
		history = history.slice(history.size() - _HISTORY_MAX)
	state["history"] = history

	if half_size.x > 0.0 or half_size.y > 0.0:
		if absf(point.x) > half_size.x or absf(point.y) > half_size.y:
			result["event"] = _exit(state, true)
			return result

	if point.z < -release_depth or point.z > release_depth * 6.0:
		result["event"] = _exit(state, true)
		return result

	if state["pressed"]:
		var releasing: bool = point.z > release_depth
		if interpret_drag:
			var planar := Vector2(point.x, point.y) - (state["press_planar"] as Vector2)
			if state["dragging"] or planar.length() >= drag_threshold:
				state["dragging"] = true
				if releasing:
					state["pressed"] = false
					state["dragging"] = false
					return result  # NONE: a drag does not activate on let-go.
				result["event"] = Event.DRAG
				result["drag_delta"] = planar
				return result
		if releasing:
			state["pressed"] = false
			result["event"] = Event.RELEASED
		return result

	if point.z > press_depth:
		state["in_front"] = true
		return result

	if _entry_passes(state) or _angle_passes(state):
		state["pressed"] = true
		state["dragging"] = false
		state["press_planar"] = Vector2(point.x, point.y)
		result["event"] = Event.PRESSED
	return result


## The source is gone entirely (out of reach, untracked, or outside an
## adapter's own bounds test). Clears the history too. Returns CANCELLED when
## it was mid-press.
func forget(source_id: int) -> Event:
	if not _sources.has(source_id):
		return Event.NONE
	return _exit(_sources[source_id], false)


## True while any source is pressed - for adapters that expose is_pressed().
func is_pressed() -> bool:
	for state in _sources.values():
		if state["pressed"]:
			return true
	return false


func _state_for(source_id: int) -> Dictionary:
	if not _sources.has(source_id):
		_sources[source_id] = {
			"in_front": false,
			"pressed": false,
			"dragging": false,
			"press_planar": Vector2.ZERO,
			"history": PackedVector3Array(),
		}
	return _sources[source_id]


func _exit(state: Dictionary, keep_history: bool) -> Event:
	var was_pressed: bool = state["pressed"]
	state["pressed"] = false
	state["dragging"] = false
	state["in_front"] = false
	if not keep_history:
		state["history"] = PackedVector3Array()
	return Event.CANCELLED if was_pressed else Event.NONE


func _entry_passes(state: Dictionary) -> bool:
	if not require_entry_through_face:
		return true
	return bool(state["in_front"])


## Squared comparison, so no square root: for travel t and inward normal -Z,
## cos(angle) = -t.z / |t|, and requiring cos(angle) >= cos(max) with both
## sides non-negative squares to t.z^2 >= cos(max)^2 * |t|^2.
func _angle_passes(state: Dictionary) -> bool:
	var history: PackedVector3Array = state["history"]
	if history.size() < 2:
		return false
	var travel := history[history.size() - 1] - history[0]
	var travel_sq := travel.length_squared()
	if travel_sq < min_approach_travel * min_approach_travel:
		return true  # Abstain: the direction is noise at this scale.
	if travel.z > 0.0:
		return false  # Moving outward, away from the surface.
	var cos_max := cos(deg_to_rad(max_approach_angle))
	return travel.z * travel.z >= cos_max * cos_max * travel_sq
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe' --headless --xr-mode off --path 'C:\Users\davta\Repos\Godot_WebXR_gh\demo' --script 'res://addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd'
```

Expected: `XR poke fidelity: PASS`, exit code 0.

- [ ] **Step 5: Mutation-test the gate**

Apply each mutation, run the suite, confirm it FAILS, then revert. A suite
that passes any of these is worse than none — this project has shipped two
such suites and the mutation run caught both.

| # | Mutation | Must fail |
|---|---|---|
| 1 | `_entry_passes` returns `true` always | lateral sweep |
| 2 | `_angle_passes` returns `true` always | lateral sweep |
| 3 | Delete the abstain (`if travel_sq < ...: return true`) | slow creep |
| 4 | `_exit` returns `Event.RELEASED` instead of `Event.CANCELLED` | slide off |
| 5 | `max_approach_angle` default 180 | lateral sweep |
| 6 | **Change `_entry_passes(state) or _angle_passes(state)` to `and`** | BOTH rescue cases, and nothing else |
| 7 | `_exit(state, true)` → `_exit(state, false)` on the bounds test | fast diagonal rescue only |

Mutations 3, 6 and 7 are the ones a lazily written suite passes.

Mutation 3 in particular: a purely axial creep satisfies the angle test at ANY
magnitude, so an axial fixture passes with the abstain deleted. The slow-creep
fixture carries a lateral component for exactly this reason. If mutation 3
passes, that fixture has been "simplified" — restore the lateral component
rather than weakening the mutation.

If 6 or 7 passes, the rescue tests are asserting the union rather than the
composition. Fix the tests before continuing.

- [ ] **Step 6: Commit**

```bash
git add addons/godot_xr_interaction_toolkit/runtime/poke/xr_poke_evaluator.gd addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd
git commit -m "feat: one poke press decision, armed by either approach test"
```

---

### Task 2: The poke profile resource

**Files:**
- Create: `addons/godot_xr_interaction_toolkit/runtime/poke/xr_poke_profile.gd`
- Test: `addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd` (modify)

**Interfaces:**
- Consumes: `XRPokeEvaluator.apply_profile(profile)` from Task 1.
- Produces: `XRPokeProfile` (`Resource`) with exports `press_depth: float`,
  `release_depth: float`, `require_entry_through_face: bool`,
  `max_approach_angle: float`, `min_approach_travel: float`.

- [ ] **Step 1: Write the failing test**

Add to `test_poke_fidelity.gd`, and register it in `_init()` after
`_test_fast_diagonal_rescued_by_angle(_failures)`:

```gdscript
const XRPokeProfile := preload("res://addons/godot_xr_interaction_toolkit/runtime/poke/xr_poke_profile.gd")


func _test_profile_overrides_evaluator_config(failures: Array[String]) -> void:
	var profile = XRPokeProfile.new()
	profile.press_depth = 0.030
	profile.release_depth = 0.060
	profile.require_entry_through_face = false
	profile.max_approach_angle = 80.0
	profile.min_approach_travel = 0.001
	var evaluator = _make()
	evaluator.apply_profile(profile)
	_check(failures, is_equal_approx(evaluator.press_depth, 0.030),
			"profile: press_depth must be taken from the profile")
	_check(failures, is_equal_approx(evaluator.release_depth, 0.060),
			"profile: release_depth must be taken from the profile")
	_check(failures, evaluator.require_entry_through_face == false,
			"profile: require_entry_through_face must be taken from the profile")
	_check(failures, is_equal_approx(evaluator.max_approach_angle, 80.0),
			"profile: max_approach_angle must be taken from the profile")
	_check(failures, is_equal_approx(evaluator.min_approach_travel, 0.001),
			"profile: min_approach_travel must be taken from the profile")


func _test_null_profile_leaves_config_untouched(failures: Array[String]) -> void:
	var evaluator = _make()
	evaluator.apply_profile(null)
	_check(failures, is_equal_approx(evaluator.press_depth, 0.012),
			"profile: a null profile must leave the node's own exports in place")
```

- [ ] **Step 2: Run to verify it fails**

```bash
'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe' --headless --xr-mode off --path 'C:\Users\davta\Repos\Godot_WebXR_gh\demo' --script 'res://addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd'
```

Expected: FAIL — `xr_poke_profile.gd` does not exist, so the preload errors.

- [ ] **Step 3: Write the resource**

Create `addons/godot_xr_interaction_toolkit/runtime/poke/xr_poke_profile.gd`
(TABS):

```gdscript
@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_poke_interactor.svg")
class_name XRPokeProfile
extends Resource

## One resource carrying the whole POKE FEEL of a project: how deep a press
## is, how far it re-arms, and how strictly arming is gated on approach.
## Assign it to any poke target (XRPokeable, XRUICanvasInteractable,
## XRPokeButton) and every one of them moves together - the same pattern
## XRFeedbackTheme uses for scene-wide interaction feedback.
##
## PRECEDENCE: an assigned profile WINS. The node's own exports are the
## fallback, used only while poke_profile is null. Godot cannot distinguish an
## export left at its default from one deliberately set to that value, so
## per-property override would silently ignore the profile whenever the two
## happened to match.

@export_group("Depth")
## How close (metres) the poke point must come to the surface to press, and
## how far it must retract to re-arm. The gap between them is the hysteresis
## that stops flicker at the boundary.
@export_range(0.001, 0.1, 0.001) var press_depth := 0.012
@export_range(0.005, 0.2, 0.001) var release_depth := 0.04

@export_group("Approach Gate")
## Require the point to have been seen in front of the face before it can
## press. Stops a hand sweeping sideways across a row of buttons from pressing
## each one it crosses. Turn OFF (with max_approach_angle at 90) to restore
## pre-gate behaviour exactly.
@export var require_entry_through_face := true
## Travel over the sample window must point inward within this angle. 90
## accepts any inward motion; 0 accepts only a perfectly axial approach.
@export_range(0.0, 90.0, 1.0) var max_approach_angle := 60.0
## Below this window displacement (metres) the direction is noise and the
## angle test abstains. Do not set to 0: a slow, deliberate creep-in would
## then be rejected on jitter alone.
@export_range(0.0, 0.02, 0.0005) var min_approach_travel := 0.003
```

- [ ] **Step 4: Run to verify it passes**

```bash
'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe' --headless --xr-mode off --path 'C:\Users\davta\Repos\Godot_WebXR_gh\demo' --script 'res://addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd'
```

Expected: `XR poke fidelity: PASS`, exit 0.

- [ ] **Step 5: Mutation-test**

Change `apply_profile` to return early unconditionally (`return` as its first
line). The profile test must FAIL. Revert.

- [ ] **Step 6: Commit**

```bash
git add addons/godot_xr_interaction_toolkit/runtime/poke/xr_poke_profile.gd addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd
git commit -m "feat: one resource carries a project's whole poke feel"
```

---

### Task 3: XRPokeable adapter

**Files:**
- Modify: `addons/godot_xr_interaction_toolkit/runtime/xr_pokeable.gd`
- Test: `addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd` (modify)

**Interfaces:**
- Consumes: `XRPokeEvaluator`, `XRPokeProfile` from Tasks 1-2.
- Produces: `XRPokeable` signals `pressed(hand: int)`, `released(hand: int)`,
  **`cancelled(hand: int)`**, **`dragged(hand: int, delta: Vector2)`**; methods
  `poke_update(hand: int, world_point: Vector3)`, `poke_end(hand: int)`,
  `is_pressed() -> bool`, **`get_poke_pin(hand: int) -> Vector3`** (returns
  `Vector3.INF` when that hand has no contact).

- [ ] **Step 1: Write the failing test**

Add to `test_poke_fidelity.gd` and register both in `_init()`. `XRPokeable` is
a `Node3D` whose `global_transform` is read, so these must run from `_process`,
not `_init` — a node added to `get_root()` during `_init` is not yet inside the
tree. Add a `_process` handler mirroring `test_grab_feel.gd`:

```gdscript
const XRPokeableScript := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_pokeable.gd")

var _tree_tests_done := false


func _process(_delta: float) -> bool:
	if _tree_tests_done:
		return true
	_tree_tests_done = true
	_test_pokeable_emits_cancelled_on_slide_off(_failures)
	_test_pokeable_reports_a_pin(_failures)
	if _failures.is_empty():
		print("XR poke fidelity: PASS")
		quit(0)
		return true
	for failure in _failures:
		printerr("FAIL: %s" % failure)
	printerr("XR poke fidelity: %d FAILURE(S)" % _failures.size())
	quit(1)
	return true


## Build a pokeable at the origin, facing +Z, parented to a body so its
## self-wiring finds one.
func _make_pokeable() -> Node3D:
	var body := StaticBody3D.new()
	get_root().add_child(body)
	var pokeable := Node3D.new()
	pokeable.set_script(XRPokeableScript)
	body.add_child(pokeable)
	return pokeable


func _test_pokeable_emits_cancelled_on_slide_off(failures: Array[String]) -> void:
	var pokeable := _make_pokeable()
	var seen := {"pressed": 0, "released": 0, "cancelled": 0}
	pokeable.pressed.connect(func(_hand): seen["pressed"] += 1)
	pokeable.released.connect(func(_hand): seen["released"] += 1)
	pokeable.cancelled.connect(func(_hand): seen["cancelled"] += 1)
	# Face normal is +Z by default, so world +Z is "in front".
	pokeable.poke_update(0, Vector3(0.0, 0.0, 0.050))
	pokeable.poke_update(0, Vector3(0.0, 0.0, 0.008))
	pokeable.poke_update(0, Vector3(0.080, 0.0, 0.008))
	_check(failures, seen["pressed"] == 1,
			"pokeable: expected 1 pressed, got %d" % seen["pressed"])
	_check(failures, seen["cancelled"] == 1,
			"pokeable: expected 1 cancelled, got %d" % seen["cancelled"])
	_check(failures, seen["released"] == 0,
			"pokeable: a slide-off must NOT emit released, got %d" % seen["released"])
	pokeable.get_parent().queue_free()


func _test_pokeable_reports_a_pin(failures: Array[String]) -> void:
	var pokeable := _make_pokeable()
	pokeable.poke_update(0, Vector3(0.0, 0.0, 0.050))
	pokeable.poke_update(0, Vector3(0.010, 0.0, -0.020))
	var pin: Vector3 = pokeable.get_poke_pin(0)
	_check(failures, pin != Vector3.INF,
			"pokeable: expected a pin while in contact")
	_check(failures, is_equal_approx(pin.z, 0.0),
			"pokeable: the pin must sit ON the surface, got z=%f" % pin.z)
	pokeable.get_parent().queue_free()
```

Remove the `quit(0)` / `quit(1)` block from `_init()`; `_init` now only
accumulates failures and `_process` reports. Keep every `_init` test call.

- [ ] **Step 2: Run to verify it fails**

```bash
'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe' --headless --xr-mode off --path 'C:\Users\davta\Repos\Godot_WebXR_gh\demo' --script 'res://addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd'
```

Expected: FAIL — `cancelled` is not a signal on `XRPokeable`, and
`get_poke_pin` does not exist.

- [ ] **Step 3: Rewrite the adapter**

Replace the body of `xr_pokeable.gd` from the signals down (TABS). Keep
`_enter_tree`, `_exit_tree`, `_get_configuration_warnings`, `_local_normal`,
`_plane_u`, `_plane_v` exactly as they are:

```gdscript
signal pressed(hand: int)
signal released(hand: int)
## An aborted press: the fingertip left the face while still down. Buttons
## conventionally fire on RELEASE, so without this a slide-off ACTIVATES them.
signal cancelled(hand: int)
## Opt-in drag reporting, in metres along the face's own u/v axes.
signal dragged(hand: int, delta: Vector2)

const _Evaluator := preload("res://addons/godot_xr_interaction_toolkit/runtime/poke/xr_poke_evaluator.gd")

@export var poke_face := Face.Z_PLUS

@export_group("Poke Feel")
## Assign to take press depth and the approach gate from one project-wide
## resource. When set it WINS over the exports below.
@export var poke_profile: XRPokeProfile
## Finger must come within this depth of the surface to press, and retract past
## the second to release (hysteresis stops flicker). Metres.
@export var press_depth := 0.012
@export var release_depth := 0.04
## Half-extents of the pokeable face (metres) - a poke outside this rectangle is
## ignored. Zero = no bounds (the whole plane pokes).
@export var half_size := Vector2(0.05, 0.05)
## Require the fingertip to have been seen in FRONT of this face before it can
## press, so a hand sweeping sideways across a row of buttons does not press
## each one it crosses.
@export var require_entry_through_face := true
## Travel must point inward within this angle at the moment of crossing.
@export_range(0.0, 90.0, 1.0) var max_approach_angle := 60.0
## Below this displacement the direction is noise and the angle test abstains.
@export_range(0.0, 0.02, 0.0005) var min_approach_travel := 0.003
## Report drags instead of activating on let-go - for handles, not buttons.
@export var interpret_drag := false
@export_range(0.001, 0.1, 0.001) var drag_threshold := 0.01

var _body: CollisionObject3D
var _evaluator: XRPokeEvaluator
var _pins := {}  # hand -> world-space pinned point


func _sync_evaluator() -> void:
	if _evaluator == null:
		_evaluator = _Evaluator.new()
	_evaluator.press_depth = press_depth
	_evaluator.release_depth = release_depth
	_evaluator.half_size = half_size
	_evaluator.require_entry_through_face = require_entry_through_face
	_evaluator.max_approach_angle = max_approach_angle
	_evaluator.min_approach_travel = min_approach_travel
	_evaluator.interpret_drag = interpret_drag
	_evaluator.drag_threshold = drag_threshold
	_evaluator.apply_profile(poke_profile)


## Driven by the interactor with the world-space fingertip.
func poke_update(hand: int, world_point: Vector3) -> void:
	_sync_evaluator()
	var local := global_transform.affine_inverse() * world_point
	var normal := _local_normal()
	var u_axis := _plane_u(normal)
	var v_axis := _plane_v(normal)
	var depth := local.dot(normal)
	var planar := local - normal * depth
	# Canonical frame: +Z outward, z = distance in front of the surface.
	var canonical := Vector3(planar.dot(u_axis), planar.dot(v_axis), depth)
	var result: Dictionary = _evaluator.evaluate(hand, canonical)
	var pinned: Vector3 = result["pinned_point"]
	_pins[hand] = global_transform * (u_axis * pinned.x + v_axis * pinned.y + normal * pinned.z)
	_emit(hand, result)


## The poke source lost its point (hand untracked / moved away).
func poke_end(hand: int) -> void:
	if _evaluator == null:
		return
	_pins.erase(hand)
	var event: int = _evaluator.forget(hand)
	if event == _Evaluator.Event.CANCELLED:
		cancelled.emit(hand)


func is_pressed() -> bool:
	return _evaluator != null and _evaluator.is_pressed()


## World-space point pinned to this face while the hand is in contact, so a
## marker can stop ON the surface instead of sinking through it. INF = none.
func get_poke_pin(hand: int) -> Vector3:
	return _pins.get(hand, Vector3.INF)


func _emit(hand: int, result: Dictionary) -> void:
	match int(result["event"]):
		_Evaluator.Event.PRESSED:
			pressed.emit(hand)
		_Evaluator.Event.RELEASED:
			released.emit(hand)
		_Evaluator.Event.CANCELLED:
			_pins.erase(hand)
			cancelled.emit(hand)
		_Evaluator.Event.DRAG:
			dragged.emit(hand, result["drag_delta"])
```

Delete the old `_down` dictionary and the old bodies of `poke_update`,
`poke_end` and `is_pressed`.

- [ ] **Step 4: Run to verify it passes**

```bash
'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe' --headless --xr-mode off --path 'C:\Users\davta\Repos\Godot_WebXR_gh\demo' --script 'res://addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd'
```

Expected: `XR poke fidelity: PASS`, exit 0.

- [ ] **Step 5: Mutation-test**

Change the `Event.CANCELLED` branch of `_emit` to `released.emit(hand)`. The
slide-off test must FAIL. Revert.

- [ ] **Step 6: Commit**

```bash
git add addons/godot_xr_interaction_toolkit/runtime/xr_pokeable.gd addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd
git commit -m "feat: an aborted poke cancels instead of activating the button"
```

---

### Task 4: XRUICanvasInteractable adapter

**Files:**
- Modify: `addons/godot_xr_interaction_toolkit/runtime/xr_ui_canvas_interactable.gd:78-115`
- Test: `addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd` (modify)

**Interfaces:**
- Consumes: `XRPokeEvaluator`, `XRPokeProfile`.
- Produces: unchanged public surface plus `get_poke_pin(hand: int) -> Vector3`.
  `poke_update(source_id: int, world_point: Vector3)` and
  `poke_end(source_id: int)` keep their names and signatures.

- [ ] **Step 1: Write the failing test**

Add to `test_poke_fidelity.gd`, registered in `_process` alongside the
`XRPokeable` tests. The panel needs a `SubViewport`, so build a minimal one:

```gdscript
const XRUICanvasScript := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_ui_canvas_interactable.gd")


func _test_canvas_cancel_pushes_the_release_off_panel(failures: Array[String]) -> void:
	var panel := Node3D.new()
	panel.set_script(XRUICanvasScript)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(256, 256)
	panel.add_child(viewport)
	panel.viewport_path = panel.get_path_to(viewport)
	panel.panel_size = Vector2(0.4, 0.4)
	get_root().add_child(panel)

	var button := Button.new()
	button.anchor_right = 1.0
	button.anchor_bottom = 1.0
	viewport.add_child(button)
	var fired := {"count": 0}
	button.pressed.connect(func(): fired["count"] += 1)

	panel.poke_update(0, Vector3(0.0, 0.0, 0.050))
	panel.poke_update(0, Vector3(0.0, 0.0, 0.008))
	panel.poke_update(0, Vector3(0.300, 0.0, 0.008))  # slide off the panel
	_check(failures, fired["count"] == 0,
			"canvas: an aborted poke must not fire the Control, fired %d" % fired["count"])
	panel.queue_free()
```

- [ ] **Step 2: Run to verify it fails**

```bash
'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe' --headless --xr-mode off --path 'C:\Users\davta\Repos\Godot_WebXR_gh\demo' --script 'res://addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd'
```

Expected: FAIL — today `poke_end` pushes a mouse-up at the last in-panel
position, which is inside the Button's rect, so the Button fires.

- [ ] **Step 3: Rewrite the poke block**

Replace `xr_ui_canvas_interactable.gd` lines 78-115 (the `Poke Feel` group,
`_poke_pressed`, `poke_update`, `poke_end`) with (TABS):

```gdscript
@export_group("Poke Feel")
## Assign to take press depth and the approach gate from one project-wide
## resource. When set it WINS over the exports below.
@export var poke_profile: XRPokeProfile
## How deep (metres) a fingertip must push past the surface to register a
## press, and how far it must retract to release (hysteresis stops flicker).
@export var poke_press_depth := 0.012
@export var poke_release_depth := 0.04
## Max distance in front of the panel that still counts as poking it.
@export var poke_range := 0.09
## Require the fingertip to have been seen in FRONT of the panel before it can
## press, so a hand sweeping across the panel does not press what it crosses.
@export var poke_require_entry_through_face := true
@export_range(0.0, 90.0, 1.0) var poke_max_approach_angle := 60.0
@export_range(0.0, 0.02, 0.0005) var poke_min_approach_travel := 0.003

const _PokeEvaluator := preload("res://addons/godot_xr_interaction_toolkit/runtime/poke/xr_poke_evaluator.gd")
## Far outside any panel: where a CANCELLED release is delivered, so Godot
## Controls clear their pressed state without emitting. This is the standard
## Control contract - a Button fires only when the release lands in its rect.
const _OFF_PANEL := Vector2(-10000.0, -10000.0)

var _poke_evaluator: XRPokeEvaluator
var _poke_pins := {}


func _sync_poke_evaluator() -> void:
	if _poke_evaluator == null:
		_poke_evaluator = _PokeEvaluator.new()
	_poke_evaluator.press_depth = poke_press_depth
	_poke_evaluator.release_depth = poke_release_depth
	_poke_evaluator.half_size = panel_size * 0.5
	_poke_evaluator.require_entry_through_face = poke_require_entry_through_face
	_poke_evaluator.max_approach_angle = poke_max_approach_angle
	_poke_evaluator.min_approach_travel = poke_min_approach_travel
	_poke_evaluator.interpret_drag = false  # The viewport already drags on motion.
	_poke_evaluator.apply_profile(poke_profile)


## World-space fingertip update from a poke source (source_id per hand).
func poke_update(source_id: int, world_point: Vector3) -> void:
	if _viewport == null:
		return
	_sync_poke_evaluator()
	var local := global_transform.affine_inverse() * world_point
	# The panel owns its own REACH test; the evaluator owns the face rectangle.
	if local.z > poke_range or local.z < -0.06:
		poke_end(source_id)
		return
	var result: Dictionary = _poke_evaluator.evaluate(source_id, local)
	var pinned: Vector3 = result["pinned_point"]
	_poke_pins[source_id] = global_transform * pinned
	var pixels := map_local_point_to_viewport(local)
	match int(result["event"]):
		_PokeEvaluator.Event.PRESSED:
			_push_mouse_motion(pixels)
			_push_mouse_button(pixels, true)
			_last_pointer_position = pixels
		_PokeEvaluator.Event.RELEASED:
			_push_mouse_motion(pixels)
			_push_mouse_button(pixels, false)
			_last_pointer_position = pixels
		_PokeEvaluator.Event.CANCELLED:
			_poke_pins.erase(source_id)
			_push_mouse_motion(_OFF_PANEL)
			_push_mouse_button(_OFF_PANEL, false)
		_:
			if _poke_evaluator.is_pressed():
				_push_mouse_motion(pixels)  # Drag: sliders track the finger.
				_last_pointer_position = pixels


## The poke source lost its point (hand untracked / moved away).
func poke_end(source_id: int) -> void:
	if _poke_evaluator == null:
		return
	_poke_pins.erase(source_id)
	if _poke_evaluator.forget(source_id) == _PokeEvaluator.Event.CANCELLED:
		_push_mouse_motion(_OFF_PANEL)
		_push_mouse_button(_OFF_PANEL, false)


## World-space point pinned to the panel face while in contact. INF = none.
func get_poke_pin(source_id: int) -> Vector3:
	return _poke_pins.get(source_id, Vector3.INF)
```

- [ ] **Step 4: Run to verify it passes**

```bash
'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe' --headless --xr-mode off --path 'C:\Users\davta\Repos\Godot_WebXR_gh\demo' --script 'res://addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd'
```

Expected: `XR poke fidelity: PASS`, exit 0.

- [ ] **Step 5: Confirm the existing panel suite still passes**

```bash
'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe' --headless --xr-mode off --path 'C:\Users\davta\Repos\Godot_WebXR_gh\demo' --script 'res://addons/godot_xr_interaction_toolkit/tests/test_ui_canvas_pointer.gd'
```

Expected: PASS. This suite guards the hover-stack behaviour that the poke
rewrite must not disturb. If it fails, the drag path in the `_:` branch is the
first suspect — the old code pushed motion only while `_poke_pressed`.

- [ ] **Step 6: Mutation-test**

Change `_OFF_PANEL` to `Vector2.ZERO` (a point inside the panel). The canvas
cancel test must FAIL. Revert.

- [ ] **Step 7: Commit**

```bash
git add addons/godot_xr_interaction_toolkit/runtime/xr_ui_canvas_interactable.gd addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd
git commit -m "feat: a poke that slides off the panel no longer fires the control"
```

---

### Task 5: XRPokeButton adapter

**Files:**
- Modify: `addons/godot_xr_interaction_toolkit/runtime/xr_poke_button.gd:52-80`
- Test: `addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd` (modify)

**Interfaces:**
- Consumes: `XRPokeEvaluator`, `XRPokeProfile`.
- Produces: unchanged `pressed` / `released` signals and `is_pressed()`, plus
  `get_poke_pin(source_id: int) -> Vector3`.

**Threshold mapping — get this exactly right.** The button's surface is the
BOTTOMED-OUT cap. With cap penetration
`p = clampf(cap_rest_top - finger_bottom, 0.0, travel)`, the canonical
`z = travel - p`, and:

```
press_depth   = travel * (1.0 - press_fraction)
release_depth = travel * (1.0 - press_fraction * 0.5)
```

At the shipped defaults (`travel` 0.022, `press_fraction` 0.7) that is 0.0066
and 0.0143 — algebraically the same firing points the button has today
(`p >= travel * press_fraction` to fire, `p <= travel * press_fraction * 0.5`
to re-arm). It is `1.0 - press_fraction`, NOT `press_fraction`; the complement
would fire the cap at roughly twice its current sensitivity, on a path whose
feel this change must leave untouched.

- [ ] **Step 1: Write the failing test**

The fast-poke case: today a fingertip that reaches below the base within one
sample is skipped by `local.y < -0.01: continue`. Add to `test_poke_fidelity.gd`,
registered in `_process`:

```gdscript
const XRPokeButtonScript := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_poke_button.gd")


func _test_poke_button_fires_on_a_fast_poke(failures: Array[String]) -> void:
	var button := Node3D.new()
	button.set_script(XRPokeButtonScript)
	get_root().add_child(button)
	var fired := {"count": 0}
	button.pressed.connect(func(): fired["count"] += 1)
	# Above the cap, then in ONE step past the base - the sample the old
	# `local.y < -0.01: continue` guard threw away.
	button.poke_update(0, button.global_transform * Vector3(0.0, 0.120, 0.0))
	button.poke_update(0, button.global_transform * Vector3(0.0, -0.020, 0.0))
	_check(failures, fired["count"] == 1,
			"poke button: a fast poke must fire once, fired %d" % fired["count"])
	button.queue_free()


func _test_poke_button_thresholds_are_unchanged(failures: Array[String]) -> void:
	var button := Node3D.new()
	button.set_script(XRPokeButtonScript)
	get_root().add_child(button)
	# travel 0.022, press_fraction 0.7 -> press at p >= 0.0154, re-arm at
	# p <= 0.0077. Expressed canonically: press_depth 0.0066, release 0.0143.
	_check(failures, is_equal_approx(button.canonical_press_depth(), 0.0066),
			"poke button: press_depth must be travel * (1 - press_fraction), got %f"
					% button.canonical_press_depth())
	_check(failures, is_equal_approx(button.canonical_release_depth(), 0.0143),
			"poke button: release_depth must be travel * (1 - press_fraction * 0.5), got %f"
					% button.canonical_release_depth())
	button.queue_free()
```

- [ ] **Step 2: Run to verify it fails**

```bash
'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe' --headless --xr-mode off --path 'C:\Users\davta\Repos\Godot_WebXR_gh\demo' --script 'res://addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd'
```

Expected: FAIL — `poke_update`, `canonical_press_depth` and
`canonical_release_depth` do not exist on `XRPokeButton`.

- [ ] **Step 3: Rewrite the button's decision**

Replace `xr_poke_button.gd` lines 52-80 (`_physics_process` and the hysteresis
block) with (TABS). Keep `_build_visuals` and every `@export` as they are, and
ADD the profile export beside them:

```gdscript
const _PokeEvaluator := preload("res://addons/godot_xr_interaction_toolkit/runtime/poke/xr_poke_evaluator.gd")

## Assign to take the approach gate from one project-wide resource. The cap's
## own travel and press_fraction still set its depth - a button's throw is
## geometry, not project feel.
@export var poke_profile: XRPokeProfile

var _evaluator: XRPokeEvaluator
var _pressed_sources := {}
var _pins := {}


## The cap's firing point expressed in the evaluator's canonical frame, where
## the surface is the BOTTOMED-OUT cap: z = travel - penetration.
func canonical_press_depth() -> float:
	return travel * (1.0 - press_fraction)


func canonical_release_depth() -> float:
	return travel * (1.0 - press_fraction * 0.5)


func _sync_evaluator() -> void:
	if _evaluator == null:
		_evaluator = _PokeEvaluator.new()
	_evaluator.press_depth = canonical_press_depth()
	_evaluator.release_depth = canonical_release_depth()
	_evaluator.half_size = Vector2.ZERO  # Round cap: the button bounds it below.
	_evaluator.interpret_drag = false
	_evaluator.apply_profile(poke_profile)
	# The profile carries no cap geometry, so restore the derived depths after
	# it has supplied the gate settings.
	_evaluator.press_depth = canonical_press_depth()
	_evaluator.release_depth = canonical_release_depth()


## One poke point, in world space, from one source. Public so the button can
## be driven by a test or a custom dispatcher as well as by _physics_process.
func poke_update(source_id: int, world_point: Vector3) -> void:
	_sync_evaluator()
	var local := global_transform.affine_inverse() * world_point
	# Round cap: the button owns this bounds test, the evaluator owns the rest.
	if Vector2(local.x, local.z).length() > cap_radius + _FINGER_RADIUS:
		poke_end(source_id)
		return
	var cap_rest_top := _cap_rest_y + _cap_height * 0.5
	var finger_bottom := local.y - _FINGER_RADIUS
	if finger_bottom > cap_rest_top + 0.05:
		poke_end(source_id)
		return
	# Penetration into the cap, clamped. The clamp is the fast-poke fix: a
	# fingertip already below the base is BOTTOMED OUT, not absent, and the
	# old `local.y < -0.01: continue` threw that sample away.
	var penetration := clampf(cap_rest_top - finger_bottom, 0.0, travel)
	var canonical := Vector3(local.x, local.z, travel - penetration)
	var result: Dictionary = _evaluator.evaluate(source_id, canonical)
	_pins[source_id] = global_transform * Vector3(local.x, cap_rest_top - travel, local.z)
	match int(result["event"]):
		_PokeEvaluator.Event.PRESSED:
			_pressed_sources[source_id] = true
		_PokeEvaluator.Event.RELEASED, _PokeEvaluator.Event.CANCELLED:
			_pressed_sources.erase(source_id)


func poke_end(source_id: int) -> void:
	if _evaluator == null:
		return
	_pins.erase(source_id)
	_evaluator.forget(source_id)
	_pressed_sources.erase(source_id)


func get_poke_pin(source_id: int) -> Vector3:
	return _pins.get(source_id, Vector3.INF)


func _physics_process(_delta: float) -> void:
	if not enabled or _cap == null:
		return
	var depth := 0.0
	var source_id := 0
	for source in get_tree().get_nodes_in_group(XRPokeInteractor.GROUP):
		for hand in 2:
			var point: Vector3 = source.get_poke_point(hand)
			if point == Vector3.INF:
				poke_end(source_id)
			else:
				poke_update(source_id, point)
				var local := global_transform.affine_inverse() * point
				var cap_rest_top := _cap_rest_y + _cap_height * 0.5
				var finger_bottom := local.y - _FINGER_RADIUS
				if Vector2(local.x, local.z).length() <= cap_radius + _FINGER_RADIUS:
					depth = maxf(depth, clampf(cap_rest_top - finger_bottom, 0.0, travel))
			source_id += 1
	_cap.position.y = _cap_rest_y - depth

	var now_pressed := not _pressed_sources.is_empty()
	if now_pressed and not _is_pressed:
		_is_pressed = true
		_cap_material.albedo_color = pressed_color
		pressed.emit()
	elif not now_pressed and _is_pressed:
		_is_pressed = false
		_cap_material.albedo_color = cap_color
		released.emit()
```

Note `is_pressed()` above still returns `_is_pressed` — leave that function
unchanged.

- [ ] **Step 4: Run to verify it passes**

```bash
'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe' --headless --xr-mode off --path 'C:\Users\davta\Repos\Godot_WebXR_gh\demo' --script 'res://addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd'
```

Expected: `XR poke fidelity: PASS`, exit 0.

- [ ] **Step 5: Mutation-test the threshold mapping**

Change `canonical_press_depth` to `return travel * press_fraction`. The
threshold test must FAIL with a value of 0.0154. Revert. This mutation guards
the exact arithmetic error the design doc originally contained.

- [ ] **Step 6: Commit**

```bash
git add addons/godot_xr_interaction_toolkit/runtime/xr_poke_button.gd addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd
git commit -m "feat: a fast poke bottoms the cap out instead of being dropped"
```

---

### Task 6: The marker stops on the surface

**Files:**
- Modify: `addons/godot_xr_interaction_toolkit/runtime/xr_poke_interactor.gd:205-229`
- Test: `addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd` (modify)

**Interfaces:**
- Consumes: `get_poke_pin(source_id) -> Vector3` from Tasks 3-5.
- Produces: `XRPokeInteractor.get_marker_point(hand: int) -> Vector3` — the
  pinned point when any active target reports one, else the raw poke point.

- [ ] **Step 1: Write the failing test**

```gdscript
const XRPokeInteractorScript := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_poke_interactor.gd")


func _test_marker_prefers_the_pinned_point(failures: Array[String]) -> void:
	var interactor := Node.new()
	interactor.set_script(XRPokeInteractorScript)
	get_root().add_child(interactor)
	var pokeable := _make_pokeable()
	pokeable.poke_update(0, Vector3(0.0, 0.0, 0.050))
	pokeable.poke_update(0, Vector3(0.0, 0.0, -0.030))
	interactor.set_active_targets_for_test(0, [pokeable], Vector3(0.0, 0.0, -0.030))
	var marker: Vector3 = interactor.get_marker_point(0)
	_check(failures, is_equal_approx(marker.z, 0.0),
			"marker: expected the pinned point on the surface, got z=%f" % marker.z)
	interactor.queue_free()
	pokeable.get_parent().queue_free()
```

- [ ] **Step 2: Run to verify it fails**

```bash
'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe' --headless --xr-mode off --path 'C:\Users\davta\Repos\Godot_WebXR_gh\demo' --script 'res://addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd'
```

Expected: FAIL — neither `get_marker_point` nor `set_active_targets_for_test`
exists.

- [ ] **Step 3: Add the pin preference**

Add to `xr_poke_interactor.gd` (TABS), and change `_update_markers` to call
`get_marker_point(hand)` where it currently uses `_points[hand]`:

```gdscript
## The point the aiming dot should sit at: the surface-pinned contact when any
## active target reports one, else the raw fingertip. Pinning is what makes the
## dot STOP on a button face instead of sinking through it.
func get_marker_point(hand: int) -> Vector3:
	for target in _active[hand]:
		if is_instance_valid(target) and target.has_method("get_poke_pin"):
			var pin: Vector3 = target.get_poke_pin(hand)
			if pin != Vector3.INF:
				return pin
	return _points[hand]


## Test seam: populate the dispatch state without a physics world.
func set_active_targets_for_test(hand: int, targets: Array, point: Vector3) -> void:
	var touched := {}
	for target in targets:
		touched[target] = true
	_active[hand] = touched
	_points[hand] = point
```

In `_update_markers`, replace the final positioning line:

```gdscript
		(_markers[hand] as Node3D).global_position = get_marker_point(hand)
```

- [ ] **Step 4: Run to verify it passes**

```bash
'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe' --headless --xr-mode off --path 'C:\Users\davta\Repos\Godot_WebXR_gh\demo' --script 'res://addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd'
```

Expected: `XR poke fidelity: PASS`, exit 0.

- [ ] **Step 5: Mutation-test**

Make `get_marker_point` return `_points[hand]` unconditionally. The marker test
must FAIL. Revert.

- [ ] **Step 6: Commit**

```bash
git add addons/godot_xr_interaction_toolkit/runtime/xr_poke_interactor.gd addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd
git commit -m "feat: the poke dot stops on the surface instead of sinking through"
```

---

### Task 7: The station that proves it

**Files:**
- Modify: `addons/godot_xr_interaction_toolkit/runtime/xr_poke_station.gd`
- Modify: `addons/godot_xr_interaction_toolkit/samples/poke_playground_demo.tscn`
- Modify: `addons/godot_xr_interaction_toolkit/samples/poke_playground_demo.gd`

**Interfaces:**
- Consumes: `XRPokeable` signals `pressed`, `cancelled`, `dragged` from Task 3.
- Produces: no new script API. Scene content only.

`XRPokeable` has had zero consumers anywhere in the suite. This task creates
the first ones, and each exists to make one gate behaviour visible.

- [ ] **Step 1: Add the dense button row to the station scene**

In `poke_playground_demo.tscn`, add under `Stand` a `Node3D` named `DenseRow`
containing five `StaticBody3D` children named `Key0`..`Key4`, each with a
`BoxMesh` of size `(0.03, 0.03, 0.01)` and a matching `BoxShape3D`, spaced
0.035 m apart along local X (so the gaps are smaller than the keys — the
layout that is unusable without the gate). Each body gets a child `Node3D`
with `xr_pokeable.gd` attached, `poke_face = Z_PLUS`, `half_size = Vector2(0.015, 0.015)`.

Then add a `Label3D` named `DenseRowLabel` above the row, text
`SWEEP ME - only a poke through the face presses`.

- [ ] **Step 2: Add a drag handle and a cancel target**

Under `Stand`, add a `StaticBody3D` named `DragHandle` with a `BoxMesh`
`(0.12, 0.02, 0.01)` and matching shape, holding an `xr_pokeable.gd` child with
`interpret_drag = true`, `drag_threshold = 0.01`,
`half_size = Vector2(0.06, 0.01)`. Add `Label3D` `DragHandleLabel`, text
`DRAG ME - a handle does not fire on let-go`.

Under `Stand`, add a `StaticBody3D` named `CancelTarget` with a `BoxMesh`
`(0.06, 0.06, 0.01)`, an `xr_pokeable.gd` child with default settings, and a
`Label3D` `CancelTargetLabel` with text
`PRESS THEN SLIDE OFF - it cancels, it does not fire`.

- [ ] **Step 3: Wire them in the station script**

Add to `xr_poke_station.gd` (TABS), inside `_ready` after the existing lookups:

```gdscript
	_wire_dense_row()
	_wire_drag_handle()
	_wire_cancel_target()
```

And the methods:

```gdscript
## Five keys spaced closer than their own width. Sweeping a fingertip across
## them presses nothing; poking one through its face presses exactly one. This
## layout is the reason the approach gate exists.
func _wire_dense_row() -> void:
	var row := get_node_or_null("Stand/DenseRow")
	if row == null:
		return
	for index in row.get_child_count():
		var key := row.get_child(index)
		for child in key.get_children():
			if child is XRPokeable:
				child.pressed.connect(_on_dense_key.bind(index))


func _on_dense_key(_hand: int, index: int) -> void:
	if _orb_material:
		_orb_material.albedo_color = _COLORS[index % _COLORS.size()]


## A handle reports drags and does NOT activate on let-go, so releasing it
## after a slide cannot read as a button press.
func _wire_drag_handle() -> void:
	var handle := get_node_or_null("Stand/DragHandle")
	if handle == null:
		return
	for child in handle.get_children():
		if child is XRPokeable:
			child.dragged.connect(_on_handle_dragged)


func _on_handle_dragged(_hand: int, delta: Vector2) -> void:
	if _orb:
		_orb.position.x = clampf(delta.x * 4.0, -0.4, 0.4)


## Press it, then slide sideways off its face: it CANCELS. Before this change
## that slide emitted `released`, which is what a button fires on.
func _wire_cancel_target() -> void:
	var target := get_node_or_null("Stand/CancelTarget")
	if target == null:
		return
	for child in target.get_children():
		if child is XRPokeable:
			child.released.connect(_on_cancel_target_released)
			child.cancelled.connect(_on_cancel_target_cancelled)


func _on_cancel_target_released(_hand: int) -> void:
	if _counter_label:
		_counter_label.text = "CANCEL TARGET: FIRED"


func _on_cancel_target_cancelled(_hand: int) -> void:
	if _counter_label:
		_counter_label.text = "CANCEL TARGET: cancelled, not fired"
```

- [ ] **Step 4: Verify the scene boots with no errors**

```bash
'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe' --headless --xr-mode off --path 'C:\Users\davta\Repos\Godot_WebXR_gh\demo' res://addons/godot_xr_interaction_toolkit/samples/poke_playground_demo.tscn --quit-after 150
```

Expected: exit 0 with **zero** lines matching `ERROR:`, `SCRIPT ERROR` or
`Parse Error`. Count all three patterns — a real bug hid behind checking only
the last two.

- [ ] **Step 5: Commit**

```bash
git add addons/godot_xr_interaction_toolkit/runtime/xr_poke_station.gd addons/godot_xr_interaction_toolkit/samples/poke_playground_demo.tscn addons/godot_xr_interaction_toolkit/samples/poke_playground_demo.gd
git commit -m "demo: a button row too dense to sweep, and a handle that will not fire"
```

---

### Task 8: Full verification and the earn-in gate

**Files:**
- Modify: `addons/godot_xr_interaction_toolkit/README.md`
- Modify: `addons/godot_xr_interaction_toolkit/editor/xr_blocks_dock.gd:60`
- Modify: `docs/poke-fidelity-design.md`

- [ ] **Step 1: Run every suite**

```bash
for t in test_hand_conditioning test_grab_feel test_interaction_arbiter test_ui_canvas_pointer test_poke_fidelity; do 'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe' --headless --xr-mode off --path 'C:\Users\davta\Repos\Godot_WebXR_gh\demo' --script "res://addons/godot_xr_interaction_toolkit/tests/$t.gd"; done
```

Expected: five PASS lines, every exit code 0.

```bash
for t in godot_xr_hands/tests/test_gesture_foundation godot_xr_hands/tests/test_adaptive_contact godot_webxr_kit/tests/test_eye_height_calibrator; do 'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe' --headless --xr-mode off --path 'C:\Users\davta\Repos\Godot_WebXR_gh\demo' --script "res://addons/$t.gd"; done
```

Expected: three PASS lines, every exit code 0.

- [ ] **Step 2: Boot-check the two scenes that must not regress**

```bash
'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe' --headless --xr-mode off --path 'C:\Users\davta\Repos\Godot_WebXR_gh\demo' res://addons/godot_xr_interaction_toolkit/samples/control_panel_demo.tscn --quit-after 150
```

Expected: exit 0, zero `ERROR:` / `SCRIPT ERROR` / `Parse Error` lines.

- [ ] **Step 3: Update the dock description for Pokeable**

`xr_blocks_dock.gd:60`, the `"Pokeable"` block entry. Replace its `desc` with:

```
"Make ANY body pokeable (Unity XRPokeFilter-style): parent INSIDE a collider object, pick the face + press depth, get pressed/released/CANCELLED signals. Arming is gated on approach, so a hand sweeping sideways across a row of buttons presses none of them. Set interpret_drag for a handle that reports drags and does not fire on let-go."
```

- [ ] **Step 4: Document the profile in the addon README**

Add to `addons/godot_xr_interaction_toolkit/README.md`, under whatever section
covers poke (create a `### Poke feel` heading if none exists):

```markdown
### Poke feel

`XRPokeProfile` is one resource carrying a project's whole poke feel: press
and release depth, and how strictly arming is gated on approach. Assign it to
any `XRPokeable`, `XRUICanvasInteractable` or `XRPokeButton` and they all move
together.

An assigned profile WINS over the node's own exports, which are the fallback.
Godot cannot tell an export left at its default from one deliberately set to
that value, so per-property override would silently ignore the profile
whenever the two matched.

Arming is the OR of two tests. **Entry through the face**: the point must have
been seen in front of the surface before it can press, so a hand sweeping
sideways presses nothing. **Approach angle**: travel at the moment of crossing
must point inward within `max_approach_angle`, abstaining below
`min_approach_travel` so a slow deliberate press is never rejected on jitter.
Neither test dominates - each rescues a case the other falsely rejects.

To restore pre-gate behaviour exactly: `require_entry_through_face = false`.
```

- [ ] **Step 5: Commit the docs**

```bash
git add addons/godot_xr_interaction_toolkit/README.md addons/godot_xr_interaction_toolkit/editor/xr_blocks_dock.gd
git commit -m "docs: poke feel is one resource, and arming is gated on approach"
```

- [ ] **Step 6: On-device earn-in — DO NOT MERGE WITHOUT THIS**

This changes on-device-tuned behaviour. Headless evidence does not clear it.

```bash
pwsh tools/export-xr.ps1 -Target APK
```

```bash
adb install -r -g demo/build/android/universal/GodotXR-universal-debug.apk
```

On Quest, in one session:

| Check | Pass condition |
|---|---|
| `control_panel_demo`, three `XRPokeButton`s | feel IDENTICAL to before — same depth, same firing point |
| `control_panel_demo`, `TouchPanel` buttons and slider | press and drag unchanged |
| `poke_playground_demo`, dense row | sweeping across presses NOTHING; poking one presses exactly that one |
| `poke_playground_demo`, drag handle | slides the orb, does not fire on let-go |
| `poke_playground_demo`, cancel target | press-then-slide-off reads "cancelled, not fired" |
| Any button, deliberate slow press | presses — the abstain rule holds |
| Any button, hard fast slap | presses once, no double-fire |

If the first two rows regress, the revert lever is one line per target and no
code change: `require_entry_through_face = false` and
`max_approach_angle = 90`.

- [ ] **Step 7: Record the result**

Append an `## Earn-in result` section to `docs/poke-fidelity-design.md` stating
the date, the device, and the outcome of each row above — pass or fail, with
what was observed. Report honestly if a row failed; do not mark the item done
in `INNOVATION_BACKLOG.md` until every row passes.

```bash
git add docs/poke-fidelity-design.md
git commit -m "docs: record the poke fidelity earn-in session"
```

---

## Self-review notes

**Spec coverage.** Every design section maps to a task: evaluator → 1;
canonical frame → 1; the two-test OR → 1; cancel → 3, 4; pinning → 3, 4, 5, 6;
drag vs press → 1, 3, 7; authoring surface → 2, 8; station extension → 7;
testing → 1-6; earn-in → 8; the `XRPokeButton` threshold mapping → 5.

**Two traps the fixtures are shaped around**, both found by checking the
fixtures against the mutations rather than by reading them:

1. `require_entry_through_face = false` **opens** the gate — `_entry_passes`
   returns `true` unconditionally. The obvious way to isolate the angle test
   therefore asserts the opposite of what it appears to. Both rescue tests
   isolate by making the first sample land outside the face instead, so
   `in_front` is never set.
2. A purely axial creep satisfies the angle test at any magnitude, so the
   abstain rule is invisible to an axial fixture. The slow-creep fixture moves
   1.5 mm mostly **sideways** — without that, mutation 3 passes and the
   abstain is untested.

**Arithmetic verified by hand** for every fixture against the evaluator in
Task 1 Step 3, including the two rescue cases at their stated angles (50 deg
against a 45 deg limit; 49.6 deg against the 60 deg default) and the
`cos^2 * |t|^2` comparison in each.

**Type consistency.** `get_poke_pin(int) -> Vector3` returning `Vector3.INF`
for "none" is used identically by all three adapters and by
`XRPokeInteractor.get_marker_point`. `poke_update` takes `(source_id/hand: int,
world_point: Vector3)` everywhere. `evaluate` returns the same four keys
throughout.
