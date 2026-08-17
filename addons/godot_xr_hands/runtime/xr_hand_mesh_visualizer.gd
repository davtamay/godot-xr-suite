@icon("res://addons/godot_xr_hands/icons/xr_hand_mesh_visualizer.svg")
class_name XRHandMeshVisualizer
extends Node3D

## Realistic tracked hands: the WebXR Input Profiles registry's rigged
## generic-hand meshes (MIT, bundled in models/generic_hand/) skinned live to
## XRHandTracker joints. One asset, one driver, every platform hand tracking
## works on - WebXR (Quest/Galaxy browsers) and OpenXR (Link/native).
##
## The asset's skeleton is FLAT (all 25 joints are root-level siblings named
## with the standard WebXR joint names), so each bone's pose is simply the
## joint's tracker-space transform - no hierarchy math.
##
## Mount contract (same as the procedural hand_visualizer): per-hand roots are
## named LeftHandTracking/RightHandTracking so XRHandsMount's per-modality
## render-layer hiding works unchanged, and THIS node owns per-hand `visible`
## from tracking state. Parent under an XROrigin3D (joint transforms are
## origin-relative).

const _MODEL_PATHS := [
	"res://addons/godot_xr_hands/models/generic_hand/left.glb",
	"res://addons/godot_xr_hands/models/generic_hand/right.glb",
]
const XRHandTrackerResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")

## Asset bone names (WebXR standard joint names) -> XRHandTracker joints.
const _JOINT_BY_BONE := {
	"wrist": XRHandTracker.HAND_JOINT_WRIST,
	"thumb-metacarpal": XRHandTracker.HAND_JOINT_THUMB_METACARPAL,
	"thumb-phalanx-proximal": XRHandTracker.HAND_JOINT_THUMB_PHALANX_PROXIMAL,
	"thumb-phalanx-distal": XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL,
	"thumb-tip": XRHandTracker.HAND_JOINT_THUMB_TIP,
	"index-finger-metacarpal": XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL,
	"index-finger-phalanx-proximal": XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL,
	"index-finger-phalanx-intermediate": XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE,
	"index-finger-phalanx-distal": XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL,
	"index-finger-tip": XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,
	"middle-finger-metacarpal": XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL,
	"middle-finger-phalanx-proximal": XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL,
	"middle-finger-phalanx-intermediate": XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE,
	"middle-finger-phalanx-distal": XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL,
	"middle-finger-tip": XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP,
	"ring-finger-metacarpal": XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL,
	"ring-finger-phalanx-proximal": XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL,
	"ring-finger-phalanx-intermediate": XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE,
	"ring-finger-phalanx-distal": XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL,
	"ring-finger-tip": XRHandTracker.HAND_JOINT_RING_FINGER_TIP,
	"pinky-finger-metacarpal": XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL,
	"pinky-finger-phalanx-proximal": XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL,
	"pinky-finger-phalanx-intermediate": XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE,
	"pinky-finger-phalanx-distal": XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL,
	"pinky-finger-tip": XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP,
}

## Godot rebases XRHandTracker joint ORIENTATIONS into its Humanoid-skeleton
## convention (Y back along the bone, Z out the back of the hand) by right-
## multiplying every joint basis with a constant adjustment - identically on
## WebXR (webxr_interface_js.cpp) and OpenXR (openxr_hand_tracking_extension
## .cpp). This asset is skinned against RAW WebXR joint orientations (what
## three.js feeds it), so undo the rebase per joint; without this the skin
## crumples (joint positions right, every segment rotated wrong). The
## adjustment is a 180-degree rotation, so it is its own inverse.
const _UNADJUST := Basis(Vector3(-1, 0, 0), Vector3(0, 0, -1), Vector3(0, -1, 0))

## Optional material for every hand surface. Leave empty to keep the asset's
## neutral gray (imported at editor time, so it bakes for WebGPU exports too).
@export var hand_material: Material

## Swap in your own hand meshes. ANY rigged glb whose bones use the standard
## WebXR joint names (wrist, index-finger-phalanx-proximal, ...) drives with
## zero code changes - that name map is the whole contract. Leave empty to use
## the bundled generic-hand asset. Set both, or just one per hand.
@export var left_model: PackedScene
@export var right_model: PackedScene

var _roots: Array = [null, null]
var _skeletons: Array = [null, null]
var _bone_joints: Array = [[], []]  # per hand: [[bone_idx, joint], ...]
## Per hand: {} or {joints, locked, weight, target} - see set_grip_pose.
var _grip: Array = [{}, {}]

## Seconds to blend into and out of an authored grip. A hard cut reads as a
## glitch; this is short enough that the hand still looks like it closed on
## the object rather than melting into it.
const GRIP_BLEND_SECONDS := 0.09

const _POSE_MATH_PATH := "res://addons/godot_xr_hands/runtime/xr_hand_pose_math.gd"

## Findable by consumers that must not hard-depend on this addon - the grab
## points that author held grips live in the toolkit, which ships without it.
const GROUP := "xr_hand_mesh_visualizer"


## Render an AUTHORED grip on this hand instead of the live tracked fingers.
##
## A tracked hand holding a virtual object is always slightly wrong - fingers
## pass through the mesh or float off it, because nothing stops them. Showing
## the grip the object was authored for trades a true report of your fingers
## for a true depiction of the hold, which is the trade every hand-tracking
## app that looks right has made (Meta's ISDK calls it a HandGrabPose).
##
## `joints` is wrist-relative, in the bind convention XRHandPoseMath produces
## (fk_pose / pose_joints output straight from load_bind_skeletons). The WRIST
## itself always stays live: the object was already snapped into the hand by
## the grab point, so overriding the wrist would fight that snap instead of
## completing it. `free_fingers` is a bitmask (1 = thumb ... 16 = pinky) of
## fingers that keep tracking - a trigger finger stays yours while the rest of
## the hand holds the tool.
##
## VISUAL ONLY, deliberately: the trackers keep publishing your real fingers,
## so release detection, gesture recognizers and every consumer downstream go
## on seeing the truth. Driving the trackers instead would put two writers on
## one signal, which is the bug class this stack has spent weeks removing.
func set_grip_pose(hand: int, joints: Array, free_fingers: int = 0) -> void:
	if hand < 0 or hand > 1 or joints.size() <= XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP:
		return
	var previous: Dictionary = _grip[hand]
	_grip[hand] = {
		"joints": joints,
		"locked": _locked_joints(free_fingers),
		# Keep the weight across a re-pose (a grip changing mid-hold, e.g. a
		# use-value morph) so it does not blink back through the live hand.
		"weight": float(previous.get("weight", 0.0)),
		"target": 1.0,
	}


## Hand the fingers back. Blends out rather than cutting, then drops.
func clear_grip_pose(hand: int) -> void:
	if hand < 0 or hand > 1 or _grip[hand].is_empty():
		return
	_grip[hand]["target"] = 0.0


func has_grip_pose(hand: int) -> bool:
	return hand >= 0 and hand <= 1 and not _grip[hand].is_empty()


## Which joints a finger mask locks. Built from the shared chain table, so a
## joint this addon adds later is covered without touching this block.
func _locked_joints(free_fingers: int) -> Dictionary:
	var locked := {}
	if not ResourceLoader.exists(_POSE_MATH_PATH):
		return locked
	var math: Object = load(_POSE_MATH_PATH)
	var chains: Array = math.FINGER_CHAINS
	for finger in chains.size():
		if (free_fingers & (1 << finger)) != 0:
			continue
		for joint in chains[finger]:
			locked[joint] = true
	return locked


func _ready() -> void:
	add_to_group(GROUP)
	for hand in 2:
		_setup_hand(hand)


func _setup_hand(hand: int) -> void:
	var override: PackedScene = left_model if hand == 0 else right_model
	var scene := override if override else load(_MODEL_PATHS[hand]) as PackedScene
	if scene == null:
		push_warning("XRHandMeshVisualizer: hand model missing at '%s'." % _MODEL_PATHS[hand])
		return
	var root := Node3D.new()
	root.name = XRHandIdentity.hand_tracking_root_name(hand)
	root.visible = false
	add_child(root)
	var model := scene.instantiate() as Node3D
	root.add_child(model)

	var skeletons := model.find_children("*", "Skeleton3D", true, false)
	if skeletons.is_empty():
		push_warning("XRHandMeshVisualizer: no Skeleton3D in '%s'." % _MODEL_PATHS[hand])
		return
	var skeleton := skeletons[0] as Skeleton3D

	if hand_material:
		for mesh in model.find_children("*", "MeshInstance3D", true, false):
			(mesh as MeshInstance3D).material_override = hand_material

	var pairs := []
	for bone in skeleton.get_bone_count():
		var joint: int = _JOINT_BY_BONE.get(skeleton.get_bone_name(bone), -1)
		if joint >= 0:
			pairs.append([bone, joint])
	if pairs.size() < 20:
		var names := PackedStringArray()
		for bone in skeleton.get_bone_count():
			names.append(skeleton.get_bone_name(bone))
		push_warning("XRHandMeshVisualizer: only %d/25 bones mapped in '%s' (bones: %s)." % [
			pairs.size(), _MODEL_PATHS[hand], ", ".join(names)])

	_roots[hand] = root
	_skeletons[hand] = skeleton
	_bone_joints[hand] = pairs


func _process(delta: float) -> void:
	for hand in 2:
		var root := _roots[hand] as Node3D
		if root == null:
			continue
		var tracker := XRHandTrackerResolver.get_tracker(hand)
		var live := tracker != null and tracker.has_tracking_data
		root.visible = live
		if not live:
			continue
		var skeleton := _skeletons[hand] as Skeleton3D
		var weight := _advance_grip(hand, delta)
		# The authored pose rides the LIVE wrist, so the hand still goes where
		# the tracking says - only the grip is authored.
		var wrist_world := Transform3D.IDENTITY
		if weight > 0.0:
			var wrist: Transform3D = tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST)
			wrist_world = Transform3D(wrist.basis * _UNADJUST, wrist.origin)
		var grip: Dictionary = _grip[hand]
		for pair in _bone_joints[hand]:
			var joint_transform: Transform3D = tracker.get_hand_joint_transform(pair[1])
			var world := Transform3D(joint_transform.basis * _UNADJUST, joint_transform.origin)
			if weight > 0.0 and (grip["locked"] as Dictionary).has(pair[1]):
				var authored: Transform3D = wrist_world * ((grip["joints"] as Array)[pair[1]] as Transform3D)
				world = _blend(world, authored, weight) if weight < 1.0 else authored
			skeleton.set_bone_pose_position(pair[0], world.origin)
			skeleton.set_bone_pose_rotation(pair[0], world.basis.get_rotation_quaternion())


## Moves this hand's grip blend toward its target and returns the weight;
## drops the override once it has fully blended back out.
func _advance_grip(hand: int, delta: float) -> float:
	var grip: Dictionary = _grip[hand]
	if grip.is_empty():
		return 0.0
	var target := float(grip["target"])
	var step := delta / GRIP_BLEND_SECONDS
	var weight := move_toward(float(grip["weight"]), target, step)
	grip["weight"] = weight
	if weight <= 0.0 and target <= 0.0:
		_grip[hand] = {}
		return 0.0
	return weight


func _blend(from: Transform3D, to: Transform3D, weight: float) -> Transform3D:
	return Transform3D(
			Basis(from.basis.get_rotation_quaternion().slerp(to.basis.get_rotation_quaternion(), weight)),
			from.origin.lerp(to.origin, weight))
