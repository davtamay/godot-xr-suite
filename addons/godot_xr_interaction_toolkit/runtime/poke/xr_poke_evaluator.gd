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

## DRAG_ENDED is the terminal event for a drag: interpret_drag suppresses the
## activation a retracting drag would otherwise fire (RELEASED), but a
## consumer still needs SOME signal that the drag is over - without one, a
## target that only reacts to PRESSED/RELEASED/CANCELLED (e.g. resetting a
## held colour) never hears about it and sticks in its held state.
enum Event { NONE, PRESSED, RELEASED, CANCELLED, DRAG, DRAG_ENDED }

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
## Below this window displacement the direction is noise, so the angle test
## DECLINES rather than approving (see _travel_is_inward) - an OR gate cannot
## let a test that can't judge vouch for a pass. A genuine slow, deliberate
## creep-in still presses via require_entry_through_face, which arms on
## having been seen in front of the surface, not on speed.
var min_approach_travel := 0.003

## Multiplier on half_size for the bounds test, but ONLY while a source is
## pressed (or dragging - dragging implies pressed, see _state_for/_exit).
## An UNPRESSED source is always tested against half_size exactly, at scale
## 1.0 - entry must stay tight, or the approach gate above is pointless (a
## neighbouring key inside the widened rectangle could steal a press) and a
## hand merely passing nearby could arm early. Once pressed, widening the
## rectangle lets a real finger drift off a narrow target - a 12 cm slider
## 2 cm tall - without the drift alone reading as a deliberate slide-off.
##
## DEFAULT MUST STAY 1.0 - this is not a stylistic choice, it is required by
## an existing test. XRUICanvasInteractable passes half_size = panel_size *
## 0.5; _test_canvas_cancel_pushes_the_release_off_panel slides a pressed
## poke to local x = 0.300 against a 0.4-wide panel (half-extent 0.2) to prove
## a slide-off CANCELS rather than firing the Control underneath the last
## in-panel pixel. A default of 2.0 would retest that same slide against a
## retained half-extent of 0.4, so x = 0.300 no longer leaves bounds and the
## cancel that test depends on - and the real slide-off-cancels behaviour it
## guards - stops happening. A no-op default (1.0) changes nothing anywhere;
## every adapter that wants the wider retention (XRPokeStation's drag handle)
## opts in explicitly per-target instead.
var bounds_retain_scale := 1.0

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
	bounds_retain_scale = profile.bounds_retain_scale


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

	# Entry stays tight (exactly half_size) always; retention widens ONLY once
	# pressed, and never for the still-approaching case above it - see
	# bounds_retain_scale's doc comment for why the default must be a no-op.
	var effective_half_size: Vector2 = half_size
	if state["pressed"]:
		effective_half_size = half_size * bounds_retain_scale
	if effective_half_size.x > 0.0 and absf(point.x) > effective_half_size.x:
		result["pinned_point"] = Vector3.INF
		result["event"] = _exit(state, true)
		return result
	if effective_half_size.y > 0.0 and absf(point.y) > effective_half_size.y:
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
					# DRAG_ENDED, not NONE: a drag does not activate on let-go,
					# but a consumer still needs to hear that it is over.
					result["event"] = Event.DRAG_ENDED
					return result
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


## The source left this target's SHAPE but is still nearby - the counterpart of
## the evaluator's own bounds exit, for adapters whose face is not a rectangle
## (a round cap). Keeps the sample history, so a fast approach whose previous
## sample fell outside the shape can still be rescued by the angle test.
## Use forget() instead when the source is genuinely gone.
func leave_bounds(source_id: int) -> Event:
	if not _sources.has(source_id):
		return Event.NONE
	return _exit(_sources[source_id], true)


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


## Passes if EITHER the travel over the whole sample window, OR just the most
## recent step, points inward within max_approach_angle. The full window is
## enough for a normal approach; a source that skims laterally within
## press_depth of the surface (so require_entry_through_face never arms) and
## then sharply changes direction inward needs the recent step alone, because
## the lateral skim baked into the rest of the window dilutes that direction
## change below the limit even though the last STEP is a clean, steep poke.
func _angle_passes(state: Dictionary) -> bool:
	var history: PackedVector3Array = state["history"]
	if history.size() < 2:
		return false
	if _travel_is_inward(history[history.size() - 1] - history[0]):
		return true
	if history.size() >= 3:
		if _travel_is_inward(history[history.size() - 1] - history[history.size() - 2]):
			return true
	return false


## Squared comparison, so no square root: for travel t and inward normal -Z,
## cos(angle) = -t.z / |t|, and requiring cos(angle) >= cos(max) with both
## sides non-negative squares to t.z^2 >= cos(max)^2 * |t|^2.
##
## DECLINE, below min_approach_travel: the direction is noise at this scale,
## so this test cannot judge it and must NOT vouch for it. The gate is
## `_entry_passes(state) or _angle_passes(state)`: in an OR, a test that
## cannot tell must decline (false), never approve, or it becomes a blanket
## pass on its own. A perfectly stationary source has travel_sq == 0, and
## 0 >= 0 is true - so returning true here unconditionally would arm the gate
## for a motionless finger with no angle information at all, reopening a
## variant of the sweep-then-dwell hole this gate exists to close. A source
## that swept in laterally and then held still would press once its early,
## clearly-lateral samples aged out of the four-entry history window, with no
## sample ever having been in front of the face.
##
## A slow, deliberate press is not lost by this decline: a genuine creep-in
## approaches from in front of the surface, so the entry test arms it instead
## - this method is only ever REACHED when require_entry_through_face is true
## and the source has not yet been seen in front (`_entry_passes` returned
## false), since `or` short-circuits on the entry test's own true. With
## require_entry_through_face turned off, `_entry_passes` always returns true
## and this method is never called at all for that source, so its decline
## never costs anything in that mode either.
func _travel_is_inward(travel: Vector3) -> bool:
	var travel_sq := travel.length_squared()
	if travel_sq < min_approach_travel * min_approach_travel:
		return false
	if travel.z > 0.0:
		return false  # Moving outward, away from the surface.
	var cos_max := cos(deg_to_rad(max_approach_angle))
	return travel.z * travel.z >= cos_max * cos_max * travel_sq
