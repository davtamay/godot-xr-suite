extends "res://addons/godot_xr_interaction_toolkit/runtime/input/xr_input_adapter.gd"

## Shared base for controller + hand-tracking input adapters. This is the single
## source of truth for the platform-agnostic behavior: reading XRController3D aim
## poses, the XRHandTracker hand-ray + grip poses, synthesized bare-hand
## pinch-select, optional hand-select stabilization, and the select/activate state
## machine. Platform subclasses add ONLY their select source - see
## WebXRInputAdapter (browser interface events) and OpenXRInputAdapter (action-map
## button signals). Both call _resolve_rig() from their _ready.

const XRHandGestureProvider := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_gesture_provider.gd")
const XRHandTrackerResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")

## Internal source markers so a real hardware select (trigger / browser select)
## and a synthesized bare-hand pinch never fight over the same hand.
const HARDWARE_SELECT := "hardware"
const SYNTHETIC_SELECT := "synthetic"

@export_group("Rig")
@export var xr_origin_path: NodePath
@export var left_controller_path: NodePath
@export var right_controller_path: NodePath

@export_group("Ray Source")
## false: prefer the controller aim ray. true: prefer the hand-joint ray.
@export var prefer_hand_ray := false

@export_group("Pinch Select")
@export var synthesize_pinch_select := true
@export_range(0.001, 0.2, 0.001, "or_greater") var pinch_start_distance := 0.035
@export_range(0.001, 0.2, 0.001, "or_greater") var pinch_end_distance := 0.055

@export_group("Select Stabilization")
## Experimental: keeps a hand ray from jumping when thumb/index pinch geometry
## changes. While selected, the cached pre-select ray translates with the palm
## but keeps its aim direction stable until release.
@export var stabilize_hand_select := false

var _origin: Node3D
var _controllers := {}
var _select_down := {
	Hand.LEFT: false,
	Hand.RIGHT: false,
}
var _select_source := {
	Hand.LEFT: "",
	Hand.RIGHT: "",
}
# Synthetic pinch re-arm state: cleared when any select starts, set once the
# fingers open past pinch_end_distance (see _update_synthetic_pinch_select).
var _synthetic_armed := {
	Hand.LEFT: true,
	Hand.RIGHT: true,
}
var _activate_down := {
	Hand.LEFT: false,
	Hand.RIGHT: false,
}
var _activate_source := {
	Hand.LEFT: "",
	Hand.RIGHT: "",
}
var _last_free_hand_pose := {
	Hand.LEFT: {},
	Hand.RIGHT: {},
}
var _last_free_hand_anchor := {
	Hand.LEFT: null,
	Hand.RIGHT: null,
}
var _select_anchor_pose := {
	Hand.LEFT: {},
	Hand.RIGHT: {},
}
var _select_anchor_hand_anchor := {
	Hand.LEFT: null,
	Hand.RIGHT: null,
}


## Subclasses call this from their _ready() before wiring their select source.
func _resolve_rig() -> void:
	_origin = get_node_or_null(xr_origin_path) as Node3D
	_controllers[Hand.LEFT] = get_node_or_null(left_controller_path) as XRController3D
	_controllers[Hand.RIGHT] = get_node_or_null(right_controller_path) as XRController3D


func _process(_delta: float) -> void:
	if synthesize_pinch_select:
		_update_synthetic_pinch_select(Hand.LEFT)
		_update_synthetic_pinch_select(Hand.RIGHT)


func get_aim_pose(hand_id: int) -> Dictionary:
	if not _valid_hand(hand_id):
		return {}

	var hand_pose := _hand_aim_pose(hand_id)
	if not hand_pose.is_empty():
		hand_pose = _stabilized_hand_pose(hand_id, hand_pose)

	if prefer_hand_ray:
		return hand_pose if not hand_pose.is_empty() else _controller_aim_pose(hand_id)

	var controller_pose := _controller_aim_pose(hand_id)
	return controller_pose if not controller_pose.is_empty() else hand_pose


func get_grip_pose(hand_id: int) -> Dictionary:
	if not _valid_hand(hand_id):
		return {}

	var hand_pose := _hand_grip_pose(hand_id)
	return hand_pose if not hand_pose.is_empty() else _controller_aim_pose(hand_id)


func get_source_kind(hand_id: int) -> int:
	if not _valid_hand(hand_id):
		return SourceKind.NONE

	var hand_tracked := not _hand_aim_pose(hand_id).is_empty()
	var controller_tracked := not _controller_aim_pose(hand_id).is_empty()
	if prefer_hand_ray and hand_tracked:
		return SourceKind.HAND
	if controller_tracked:
		return SourceKind.CONTROLLER
	if hand_tracked:
		return SourceKind.HAND
	return SourceKind.NONE


func _controller_aim_pose(hand_id: int) -> Dictionary:
	if not _valid_hand(hand_id):
		return {}

	var controller := _controllers.get(hand_id) as XRController3D
	if controller == null or not controller.get_is_active() or not controller.get_has_tracking_data():
		return {}

	var xf := controller.global_transform
	return {
		"origin": xf.origin,
		"direction": (-xf.basis.z).normalized(),
		"basis": xf.basis.orthonormalized(),
	}


func _hand_aim_pose(hand_id: int) -> Dictionary:
	if not _valid_hand(hand_id) or _origin == null:
		return {}

	var tracker := XRHandTrackerResolver.get_tracker(hand_id)
	var local_pose := XRHandGestureProvider.get_hand_ray_pose(tracker)
	if local_pose.is_empty():
		return {}

	var origin_xf := _origin.global_transform
	var direction := (origin_xf.basis * (local_pose["direction"] as Vector3)).normalized()
	return {
		"origin": origin_xf * (local_pose["origin"] as Vector3),
		"direction": direction,
		"basis": XRHandGestureProvider.basis_from_forward(direction),
	}


## Palm-first, wrist-fallback grip joint selection, in TRACKER-LOCAL space
## (no XROrigin transform applied - callers world-transform the result
## themselves). Static so it is testable headless without a live rig; see
## tests/test_grab_feel.gd.
static func resolve_grip_anchor(tracker: XRHandTracker) -> Transform3D:
	if tracker == null:
		return Transform3D.IDENTITY
	var joint := XRHandTracker.HAND_JOINT_PALM
	if not XRHandGestureProvider.joint_position_valid(tracker, joint):
		joint = XRHandTracker.HAND_JOINT_WRIST
		# Both current callers gate on tracking first, but this is a public
		# static: with neither joint valid, hand back identity rather than
		# whatever stale transform the tracker still holds.
		if not XRHandGestureProvider.joint_position_valid(tracker, joint):
			return Transform3D.IDENTITY
	return tracker.get_hand_joint_transform(joint)


func _hand_grip_pose(hand_id: int) -> Dictionary:
	if not _valid_hand(hand_id) or _origin == null:
		return {}

	var tracker := XRHandTrackerResolver.get_tracker(hand_id)
	if tracker == null:
		return {}

	if not XRHandGestureProvider.joint_position_valid(tracker, XRHandTracker.HAND_JOINT_PALM) \
			and not XRHandGestureProvider.joint_position_valid(tracker, XRHandTracker.HAND_JOINT_WRIST):
		return {}

	var grip_transform := _origin.global_transform * resolve_grip_anchor(tracker)
	var origin: Vector3 = grip_transform.origin

	# Godot re-bases joint ORIENTATIONS into a humanoid convention (a held
	# object's grab point ends up aimed at the fingers/knuckles, not settled in
	# the fist). Joint POSITIONS are reliable, so build a controller-style grip
	# basis from them instead: -Z = pointing (wrist -> index knuckle), +Y = out
	# of the fist (palm normal). This matches the controller grip convention, so
	# grab points behave the same on hands and controllers.
	# Use the METACARPALS (palm bones) for direction, not the finger knuckles -
	# knuckles curl when you pinch, which would twist the grip by pose. Palm bones
	# hold still, so the held orientation matches the (open-hand) editor preview.
	var wrist := XRHandTracker.HAND_JOINT_WRIST
	var index := XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL
	var pinky := XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL
	if XRHandGestureProvider.joint_position_valid(tracker, wrist) \
			and XRHandGestureProvider.joint_position_valid(tracker, index) \
			and XRHandGestureProvider.joint_position_valid(tracker, pinky):
		var o := _origin.global_transform
		var wrist_p: Vector3 = (o * tracker.get_hand_joint_transform(wrist)).origin
		var index_p: Vector3 = (o * tracker.get_hand_joint_transform(index)).origin
		var pinky_p: Vector3 = (o * tracker.get_hand_joint_transform(pinky)).origin
		# ANCHOR HISTORY (origin only - the basis math below is unaffected either
		# way, it never read the midpoint):
		# - 2026-07-19 (15d3783, v1.43.0): origin moved OFF the tracker's PALM
		#   joint onto the wrist<->middle-metacarpal midpoint, to match the
		#   editor Preview Hand / pose-math convention (raw PALM sat elsewhere).
		# - 2026-07-24 (David, grab-feel design + on-device feel-check): that
		#   midpoint is what made grabbed objects read as pulled to the wrist -
		#   grip anchor is back on resolve_grip_anchor()'s PALM-first result
		#   (computed above into `origin`); this block no longer overrides it.
		#   Deliberate reversal, not a drive-by: authored grips (blaster/pen/
		#   spray) may shift as a result and are re-verified on-device in the
		#   grab-feel plan's Task 6 earn-in gate before this ships.
		var forward := index_p - wrist_p
		var across := pinky_p - index_p
		if forward.length_squared() > 0.000001 and across.length_squared() > 0.000001:
			forward = forward.normalized()
			var up := forward.cross(across.normalized()).normalized()
			if tracker.hand == XRPositionalTracker.TRACKER_HAND_LEFT:
				up = -up
			if up.length_squared() > 0.000001:
				var basis := Basis(up.cross(-forward).normalized(), up, -forward).orthonormalized()
				return {"origin": origin, "basis": basis}

	return {
		"origin": origin,
		"basis": grip_transform.basis.orthonormalized(),
	}


func _stabilized_hand_pose(hand_id: int, raw_pose: Dictionary) -> Dictionary:
	if not stabilize_hand_select:
		# The remembered pose/anchor are only ever read when stabilization is
		# on - skip the per-frame dict duplicate + extra tracker resolve.
		return raw_pose

	if not _select_down.get(hand_id, false):
		_remember_free_hand_pose(hand_id, raw_pose)
		return raw_pose

	var anchor_pose: Dictionary = _select_anchor_pose.get(hand_id, {})
	if anchor_pose.is_empty():
		_begin_select_stabilization(hand_id, raw_pose)
		anchor_pose = _select_anchor_pose.get(hand_id, {})
	if anchor_pose.is_empty():
		return raw_pose

	var start_anchor = _select_anchor_hand_anchor.get(hand_id)
	var current_anchor = _hand_anchor_global(hand_id)
	if start_anchor == null or current_anchor == null:
		return anchor_pose
	return _offset_pose_by_anchor_delta(anchor_pose, start_anchor, current_anchor)


func _remember_free_hand_pose(hand_id: int, pose: Dictionary) -> void:
	_last_free_hand_pose[hand_id] = pose.duplicate()
	_last_free_hand_anchor[hand_id] = _hand_anchor_global(hand_id)


func _begin_select_stabilization(hand_id: int, fallback_pose := {}) -> void:
	if not stabilize_hand_select or not _valid_hand(hand_id):
		return

	var pose: Dictionary = _last_free_hand_pose.get(hand_id, {})
	if pose.is_empty() and not fallback_pose.is_empty():
		pose = fallback_pose
	if pose.is_empty():
		pose = _hand_aim_pose(hand_id)

	_select_anchor_pose[hand_id] = pose.duplicate() if not pose.is_empty() else {}
	var anchor = _last_free_hand_anchor.get(hand_id)
	_select_anchor_hand_anchor[hand_id] = anchor if anchor != null else _hand_anchor_global(hand_id)


func _end_select_stabilization(hand_id: int) -> void:
	if not _valid_hand(hand_id):
		return
	_select_anchor_pose[hand_id] = {}
	_select_anchor_hand_anchor[hand_id] = null


func _hand_anchor_global(hand_id: int):
	if not _valid_hand(hand_id) or _origin == null:
		return null

	var tracker := XRHandTrackerResolver.get_tracker(hand_id)
	if tracker == null:
		return null

	if not XRHandGestureProvider.joint_position_valid(tracker, XRHandTracker.HAND_JOINT_PALM) \
			and not XRHandGestureProvider.joint_position_valid(tracker, XRHandTracker.HAND_JOINT_WRIST):
		return null

	return _origin.global_transform * resolve_grip_anchor(tracker).origin


func _offset_pose_by_anchor_delta(pose: Dictionary, start_anchor: Vector3, current_anchor: Vector3) -> Dictionary:
	var translated_pose := pose.duplicate()
	translated_pose["origin"] = (pose["origin"] as Vector3) + (current_anchor - start_anchor)
	return translated_pose


func _valid_hand(hand_id: int) -> bool:
	return hand_id == Hand.LEFT or hand_id == Hand.RIGHT


func _update_synthetic_pinch_select(hand_id: int) -> void:
	if not _valid_hand(hand_id):
		return
	if _select_source.get(hand_id, "") == HARDWARE_SELECT:
		return

	var distance := _pinch_distance(hand_id)
	if distance < 0.0:
		if _select_source.get(hand_id, "") == SYNTHETIC_SELECT:
			_emit_select_ended(hand_id, SYNTHETIC_SELECT)
		_synthetic_armed[hand_id] = true
		return

	# Re-arm hysteresis: after ANY select ends, the synthetic detector must not
	# start again until the fingers have physically OPENED past the end
	# threshold. Without it, a select that ends while the fingers are still
	# closed (the browser's recognizer releases early - tap-proven at 3.2cm on
	# Galaxy) re-presses instantly = a second click from one pinch.
	if distance >= pinch_end_distance:
		_synthetic_armed[hand_id] = true

	if not _select_down.get(hand_id, false) and distance <= pinch_start_distance and _synthetic_armed.get(hand_id, true):
		_emit_select_started(hand_id, SYNTHETIC_SELECT)
	elif _select_source.get(hand_id, "") == SYNTHETIC_SELECT and distance >= pinch_end_distance:
		_emit_select_ended(hand_id, SYNTHETIC_SELECT)


func _pinch_distance(hand_id: int) -> float:
	if not _valid_hand(hand_id):
		return -1.0

	var tracker := XRHandTrackerResolver.get_tracker(hand_id)
	if tracker == null:
		return -1.0

	var index_tip := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
	var thumb_tip := XRHandTracker.HAND_JOINT_THUMB_TIP
	if not XRHandGestureProvider.joint_position_valid(tracker, index_tip):
		return -1.0
	if not XRHandGestureProvider.joint_position_valid(tracker, thumb_tip):
		return -1.0

	var index_position := tracker.get_hand_joint_transform(index_tip).origin
	var thumb_position := tracker.get_hand_joint_transform(thumb_tip).origin
	return index_position.distance_to(thumb_position)


func _emit_select_started(hand_id: int, source: String) -> void:
	if not _valid_hand(hand_id) or _select_down.get(hand_id, false):
		return
	_begin_select_stabilization(hand_id)
	_select_down[hand_id] = true
	_select_source[hand_id] = source
	# Any select (either source) disarms the synthetic detector until the
	# fingers reopen - one pinch can never produce a second synthetic press.
	_synthetic_armed[hand_id] = false
	select_started.emit(hand_id)


func _emit_select_ended(hand_id: int, source: String) -> void:
	if not _valid_hand(hand_id) or not _select_down.get(hand_id, false):
		return
	# A select only ends from the source that started it (same rule as activate).
	# The old one-way guard let the browser's EARLY selectend (its pinch
	# recognizer releases while the fingers are still closed) kill our synthetic
	# select mid-pinch - the synthetic detector then instantly re-pressed, giving
	# TWO full clicks per pinch (tap-proven: every pinch double-toggled UI).
	if source != _select_source.get(hand_id, ""):
		return
	_select_down[hand_id] = false
	_select_source[hand_id] = ""
	_end_select_stabilization(hand_id)
	select_ended.emit(hand_id)


func _broadcast_select_started(source: String) -> void:
	_emit_select_started(Hand.LEFT, source)
	_emit_select_started(Hand.RIGHT, source)


func _broadcast_select_ended(source: String) -> void:
	_emit_select_ended(Hand.LEFT, source)
	_emit_select_ended(Hand.RIGHT, source)


func _emit_activate_started(hand_id: int, source: String) -> void:
	if not _valid_hand(hand_id) or _activate_down.get(hand_id, false):
		return
	_activate_down[hand_id] = true
	_activate_source[hand_id] = source
	activate_started.emit(hand_id)


func _emit_activate_ended(hand_id: int, source: String) -> void:
	if not _valid_hand(hand_id) or not _activate_down.get(hand_id, false):
		return
	if source != _activate_source.get(hand_id, ""):
		return
	_activate_down[hand_id] = false
	_activate_source[hand_id] = ""
	activate_ended.emit(hand_id)


func _broadcast_activate_started(source: String) -> void:
	_emit_activate_started(Hand.LEFT, source)
	_emit_activate_started(Hand.RIGHT, source)


func _broadcast_activate_ended(source: String) -> void:
	_emit_activate_ended(Hand.LEFT, source)
	_emit_activate_ended(Hand.RIGHT, source)
