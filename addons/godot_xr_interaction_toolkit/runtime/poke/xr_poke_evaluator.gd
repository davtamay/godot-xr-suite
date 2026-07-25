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
##
## include_depth = false takes ONLY the approach gate. XRPokeButton needs this:
## a cap's throw is geometry (travel, press_fraction), not project feel, so a
## shared profile must not overwrite it.
func apply_profile(profile, include_depth := true) -> void:
	if profile == null:
		return
	if include_depth:
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

	if half_size.x > 0.0 and absf(point.x) > half_size.x:
		result["pinned_point"] = Vector3.INF
		result["event"] = _exit(state, true)
		return result
	if half_size.y > 0.0 and absf(point.y) > half_size.y:
		result["pinned_point"] = Vector3.INF
		result["event"] = _exit(state, true)
		return result

	if point.z < -release_depth or point.z > release_depth * 6.0:
		result["pinned_point"] = Vector3.INF
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


## True while THIS source is pressed. Adapters that drive per-source state -
## the canvas pushing drag motion for one hand while the other is idle - must
## use this, not is_pressed().
func is_source_pressed(source_id: int) -> bool:
	if not _sources.has(source_id):
		return false
	return bool(_sources[source_id]["pressed"])


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
