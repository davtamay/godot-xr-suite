@icon("res://addons/godot_xr_hands/icons/xr_gesture_recognizer.svg")
class_name XRGestureGhostHand
extends Node3D

## A joints-and-bones ghost hand with two modes:
## - show_gesture(): displays a gesture's recorded joint snapshot, slowly
##   yaw-rotating, as LEFT, RIGHT, or BOTH hands - the snapshot is mirrored
##   for the hand that did not record it (a wrist-local x-flip swaps
##   chirality), so one recording represents the pose on either hand.
## - start_live(): mirrors the user's live tracked hand in real time - during
##   recording you watch exactly what is being captured.
## set_highlight(true) tints it green (e.g. while the user matches the pose).

enum HandMode { LEFT, RIGHT, BOTH }

const _LINE_MATERIAL := preload("res://addons/godot_xr_hands/runtime/gesture_studio/gesture_ghost_material.tres")
const _FeatureExtractor := preload("res://addons/godot_xr_hands/runtime/gesture_studio/xr_hand_feature_extractor.gd")
const XRHandTrackerResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")

const _GHOST_COLOR := Color(0.45, 0.85, 1.0, 0.9)
const _MATCH_COLOR := Color(0.3, 1.0, 0.5, 0.95)
const _LIVE_COLOR := Color(1.0, 0.85, 0.4, 0.95)
const _BOTH_SPACING := 0.16

## Degrees per second of yaw spin while showing a static pose (0 = static).
@export_range(0.0, 180.0, 5.0) var rotate_speed := 40.0

## Uniform scale applied to the displayed hand (1 = life size).
@export_range(0.5, 3.0, 0.1) var display_scale := 1.4

## Which hand(s) the static display shows.
@export var hand_mode: HandMode = HandMode.BOTH:
	set(value):
		hand_mode = value
		if _gesture and _live_hand < 0:
			show_gesture(_gesture)

var _rigs: Array = []
var _gesture: XRHandGesture
var _live_hand := -1
var _highlight := [false, false]


func _ready() -> void:
	_rigs = [_build_skeleton(), _build_skeleton()]
	visible = false


func _process(delta: float) -> void:
	if _live_hand >= 0:
		var live_hands := [0, 1] if _live_hand == 2 else [_live_hand]
		for hand in 2:
			(_rigs[hand]["root"] as Node3D).visible = hand in live_hands
		for hand in live_hands:
			var tracker := XRHandTrackerResolver.get_tracker(hand)
			if tracker == null or not tracker.has_tracking_data:
				continue
			var wrist_inverse := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST).affine_inverse()
			var frame := PackedVector3Array()
			frame.resize(XRHandTracker.HAND_JOINT_MAX)
			for joint in XRHandTracker.HAND_JOINT_MAX:
				frame[joint] = wrist_inverse * tracker.get_hand_joint_transform(joint).origin
			_apply_positions(hand, frame)
			visible = true
	elif visible:
		for rig in _rigs:
			(rig["root"] as Node3D).rotate_y(deg_to_rad(rotate_speed) * delta)


## Show a gesture per hand_mode (returns false and hides only when gesture is
## null). Gestures without a recorded snapshot get one SYNTHESIZED from their
## curl conditions - an approximate but faithful preview, so every gesture in
## a library is visualizable, hand-authored presets included.
func show_gesture(gesture: XRHandGesture) -> bool:
	_live_hand = -1
	_gesture = gesture
	if gesture == null:
		visible = false
		return false
	# Recorded snapshots display RAW wrist-local, exactly like the live mimic
	# (the wrist frame is hand-relative - fingers present upward already; a
	# derived "correction" only fought it). Synthesized poses are built in
	# that same convention.
	var source := gesture.joint_snapshot
	var native_hand := gesture.recorded_hand if gesture.recorded_hand >= 0 else 1
	if source.size() < XRHandTracker.HAND_JOINT_MAX:
		source = _synthesize_snapshot(gesture)
		native_hand = 1
	# The snapshot's native chirality; mirror (wrist-local x-flip) for the
	# other hand.
	var shown := [hand_mode == HandMode.LEFT or hand_mode == HandMode.BOTH,
			hand_mode == HandMode.RIGHT or hand_mode == HandMode.BOTH]
	for hand in 2:
		var rig_root := _rigs[hand]["root"] as Node3D
		rig_root.visible = shown[hand]
		if not shown[hand]:
			continue
		var snapshot := source
		if hand != native_hand:
			snapshot = _mirrored(snapshot)
		_apply_positions(hand, snapshot)
		rig_root.rotation = Vector3.ZERO
		rig_root.position = Vector3.ZERO
	if hand_mode == HandMode.BOTH:
		(_rigs[0]["root"] as Node3D).position = Vector3(-_BOTH_SPACING, 0.0, 0.0)
		(_rigs[1]["root"] as Node3D).position = Vector3(_BOTH_SPACING, 0.0, 0.0)
	visible = true
	return true


## Approximate hand pose from curl conditions alone: a canonical right-hand
## skeleton whose fingers bend by each condition's target curl (unlisted
## fingers rest slightly relaxed). Bend distribution matches the extractor's
## curl normalization, so the preview curls the way the recognizer measures.
func _synthesize_snapshot(gesture: XRHandGesture) -> PackedVector3Array:
	var snapshot := PackedVector3Array()
	snapshot.resize(XRHandTracker.HAND_JOINT_MAX)
	snapshot[XRHandTracker.HAND_JOINT_WRIST] = Vector3.ZERO
	snapshot[XRHandTracker.HAND_JOINT_PALM] = Vector3(0.0, 0.0, 0.045)
	var base_x := {"thumb": -0.032, "index": -0.024, "middle": -0.006, "ring": 0.012, "pinky": 0.028}
	var segment_lengths := {"thumb": [0.04, 0.033, 0.028], "index": [0.062, 0.038, 0.024, 0.021],
			"middle": [0.06, 0.042, 0.027, 0.022], "ring": [0.058, 0.038, 0.025, 0.021], "pinky": [0.056, 0.03, 0.02, 0.019]}
	for finger in _FeatureExtractor.FINGERS:
		var chain: Array = _FeatureExtractor.FINGERS[finger]
		var curl: float = 0.25
		if gesture.conditions.has("curl_%s" % finger):
			curl = gesture.conditions["curl_%s" % finger].x
		var is_thumb: bool = finger == "thumb"
		var total_bend := curl * (1.7 if is_thumb else 3.6)
		var per_joint := total_bend / maxf(chain.size() - 2, 1.0)
		var bend_axis := Vector3(-0.2, -0.9, 0.0).normalized() if is_thumb else Vector3.LEFT
		var point := Vector3(base_x[finger], 0.0, 0.02 if is_thumb else 0.0)
		var direction := Vector3(-0.55, -0.1, 0.85).normalized() if is_thumb else Vector3.FORWARD * -1.0
		direction = Vector3(direction.x, direction.y, absf(direction.z))
		var lengths: Array = segment_lengths[finger]
		snapshot[chain[0]] = point
		for i in range(1, chain.size()):
			point += direction * (lengths[i - 1] as float)
			snapshot[chain[i]] = point
			if i >= 1:
				direction = direction.rotated(bend_axis, per_joint).normalized()
	# Built with fingers +Z / palm -Y; recorded wrist-local presents fingers
	# +Y - remap (x, y, z) -> (x, z, -y) so both conventions display alike.
	for i in snapshot.size():
		var point_out := snapshot[i]
		snapshot[i] = Vector3(point_out.x, point_out.z, -point_out.y)
	return snapshot


## Mirror the live tracked hand(s) until stop_live(). 0 = left, 1 = right,
## 2 = both (each rig follows its own tracker).
func start_live(hand: int) -> void:
	_live_hand = clampi(hand, 0, 2)
	for rig_hand in 2:
		var rig_root := _rigs[rig_hand]["root"] as Node3D
		rig_root.rotation = Vector3.ZERO
		rig_root.position = Vector3.ZERO
		_set_rig_color(rig_hand, _LIVE_COLOR)
	if _live_hand == 2:
		(_rigs[0]["root"] as Node3D).position = Vector3(-_BOTH_SPACING, 0.0, 0.0)
		(_rigs[1]["root"] as Node3D).position = Vector3(_BOTH_SPACING, 0.0, 0.0)


func stop_live() -> void:
	_live_hand = -1
	for hand in 2:
		_set_rig_color(hand, _MATCH_COLOR if _highlight[hand] else _GHOST_COLOR)
	if _gesture:
		show_gesture(_gesture)


## Green tint PER HAND while that hand matches the displayed pose - either
## hand indicates independently.
func set_hand_highlight(hand: int, on: bool) -> void:
	if hand < 0 or hand > 1:
		return
	_highlight[hand] = on
	if _live_hand < 0:
		_set_rig_color(hand, _MATCH_COLOR if on else _GHOST_COLOR)


## Convenience: tint/untint both hands (e.g. clearing on selection change).
func set_highlight(on: bool) -> void:
	set_hand_highlight(0, on)
	set_hand_highlight(1, on)


func _set_rig_color(hand: int, color: Color) -> void:
	((_rigs[hand]["material"]) as StandardMaterial3D).albedo_color = color


func _build_skeleton() -> Dictionary:
	var root := Node3D.new()
	add_child(root)
	var material := _LINE_MATERIAL.duplicate() as StandardMaterial3D
	material.albedo_color = _GHOST_COLOR
	var joint_mesh := SphereMesh.new()
	joint_mesh.radius = 0.007
	joint_mesh.height = 0.014
	var spheres: Array[MeshInstance3D] = []
	for joint in XRHandTracker.HAND_JOINT_MAX:
		var sphere := MeshInstance3D.new()
		sphere.mesh = joint_mesh
		sphere.material_override = material
		sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(sphere)
		spheres.append(sphere)
	var bone_mesh := ImmediateMesh.new()
	var bones := MeshInstance3D.new()
	bones.mesh = bone_mesh
	bones.material_override = material
	bones.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(bones)
	return {"root": root, "spheres": spheres, "bone_mesh": bone_mesh, "material": material}


func _apply_positions(rig_index: int, snapshot: PackedVector3Array) -> void:
	var rig: Dictionary = _rigs[rig_index]
	var spheres: Array[MeshInstance3D] = rig["spheres"]
	var bone_mesh: ImmediateMesh = rig["bone_mesh"]
	var center := Vector3.ZERO
	for point in snapshot:
		center += point
	center /= snapshot.size()
	for joint in XRHandTracker.HAND_JOINT_MAX:
		spheres[joint].position = (snapshot[joint] - center) * display_scale
	bone_mesh.clear_surfaces()
	bone_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for finger in _FeatureExtractor.FINGERS:
		var chain: Array = _FeatureExtractor.FINGERS[finger]
		bone_mesh.surface_add_vertex((snapshot[XRHandTracker.HAND_JOINT_WRIST] - center) * display_scale)
		bone_mesh.surface_add_vertex((snapshot[chain[0]] - center) * display_scale)
		for i in range(chain.size() - 1):
			bone_mesh.surface_add_vertex((snapshot[chain[i]] - center) * display_scale)
			bone_mesh.surface_add_vertex((snapshot[chain[i + 1]] - center) * display_scale)
	bone_mesh.surface_end()


func _mirrored(snapshot: PackedVector3Array) -> PackedVector3Array:
	var flipped := PackedVector3Array()
	flipped.resize(snapshot.size())
	for i in snapshot.size():
		var point := snapshot[i]
		flipped[i] = Vector3(-point.x, point.y, point.z)
	return flipped
