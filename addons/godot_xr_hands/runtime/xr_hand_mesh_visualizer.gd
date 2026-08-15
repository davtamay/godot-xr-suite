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


func _ready() -> void:
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


func _process(_delta: float) -> void:
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
		for pair in _bone_joints[hand]:
			var joint_transform: Transform3D = tracker.get_hand_joint_transform(pair[1])
			skeleton.set_bone_pose_position(pair[0], joint_transform.origin)
			skeleton.set_bone_pose_rotation(pair[0], (joint_transform.basis * _UNADJUST).get_rotation_quaternion())
