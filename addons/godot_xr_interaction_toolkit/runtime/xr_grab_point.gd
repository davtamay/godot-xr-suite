@tool
@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg")
class_name XRGrabPoint
extends Node3D

## An authored grip pose, as a self-wiring CHILD: parent this inside a grab
## interactable and place it where the HAND should hold the object - the
## handle of a mug, the hilt of a sword. Grabbing then SNAPS the object so
## this point lands in the hand (position AND orientation), instead of the
## object hanging wherever the ray touched it.
##
## Multiple grab points per object are fine - the nearest matching one wins
## at grab time. Orientation convention: the point's axes ARE the hand's axes
## when held - -Z = forward (aim direction), +Y = up out of the top of the
## clenched fist. A wand/torch whose long axis is its own +Y needs NO point
## rotation; rotate the point only to change how the object sits in the fist.
##
## In the editor the point draws a small palm bar + forward arrow so grips
## are authorable visually.

## Restrict this grip to one hand (-1 = either).
@export_enum("Any:-1", "Left:0", "Right:1") var hand := -1

## When several points match, higher priority wins before distance.
@export var priority := 0

## The hand this grip's pose is authored for (the Preview Hand is that hand).
@export_enum("Left:0", "Right:1") var authored_hand := 1

## Auto-mirror the grip for the OTHER hand, so you author once and both hands
## hold it as mirror images (a left-handed grip mirrors your right-handed one).
@export var mirror_to_other_hand := true

## Render the authored grip on the real hand while this point holds the object,
## instead of the live tracked fingers - the pose you previewed BECOMES the
## hold. A tracked hand around a virtual object is always a little wrong
## (fingers through the mesh, or floating off it), so showing the authored grip
## trades a true report of your fingers for a true depiction of the hold.
##
## Visual only: the trackers keep publishing your real hand, so releasing,
## gestures and every recognizer downstream still see the truth. Needs the
## godot_xr_hands realistic hand meshes; silently does nothing without them.
##
## ⚠ USE A RECORDED POSE. Curl-based grips (the built-ins, and any preset
## without a joint snapshot) cannot visually close on an object, and the
## reason is measured, not stylistic: FK curl bends each finger around its
## bind hinge, and even at curl 1.0 the fingertips stop 5.7 cm from the palm
## anchor - where a held object sits - against a spray can's 2.5 cm radius.
## Every curl value lands in the same place, so no tuning reaches a wrap.
## A pose RECORDED in the Gesture Studio carries the joint positions of a
## real hand actually holding something, which is the only data that reads
## as a hold. Reach: open 11.6 cm, trigger preset 7.3, Fist 6.6, curl 1.0
## 5.7 - all measured from the bundled hand's bind skeleton.
@export var pose_hand_while_held := false

## Fingers that keep TRACKING while the rest hold the authored grip. A spray
## can gripped by the body with the index left free lets you work the trigger
## with your own finger while the hold stays put - which is the whole reason
## per-finger freedom exists rather than a single frozen hand.
@export_flags("Thumb", "Index", "Middle", "Ring", "Pinky") var free_fingers := 0

## AUTHORING AID (editor only): show a translucent reference HAND gripping the
## object exactly as it will at runtime (same grip convention). Move/rotate this
## grab point until the hand holds the object naturally - then it's correct
## in-headset, no guessing. The preview is never saved and never appears in-game.
@export var preview_hand := false: set = _set_preview_hand

## Which pose this grip uses - previewed in the editor, and rendered on the
## real hand at runtime when pose_hand_while_held is on. The dropdown lists
## your SAVED poses from the Gesture Studio (shipped presets + your user://
## recordings) plus a few built-in grips, so the grip you record on a real
## hand is the grip the object is authored against and the one players see.
var preview_pose := "Relaxed Grip": set = _set_preview_pose

const _HAND_MODEL_PATH := "res://addons/godot_xr_hands/models/generic_hand/right.glb"

## Finger chains (metacarpal -> tip): bone names + matching XRHandTracker joints.
const _CHAINS := {
	"thumb": ["thumb-metacarpal", "thumb-phalanx-proximal", "thumb-phalanx-distal", "thumb-tip"],
	"index": ["index-finger-metacarpal", "index-finger-phalanx-proximal", "index-finger-phalanx-intermediate", "index-finger-phalanx-distal", "index-finger-tip"],
	"middle": ["middle-finger-metacarpal", "middle-finger-phalanx-proximal", "middle-finger-phalanx-intermediate", "middle-finger-phalanx-distal", "middle-finger-tip"],
	"ring": ["ring-finger-metacarpal", "ring-finger-phalanx-proximal", "ring-finger-phalanx-intermediate", "ring-finger-phalanx-distal", "ring-finger-tip"],
	"pinky": ["pinky-finger-metacarpal", "pinky-finger-phalanx-proximal", "pinky-finger-phalanx-intermediate", "pinky-finger-phalanx-distal", "pinky-finger-tip"],
}
const _FINGER_ORDER := ["thumb", "index", "middle", "ring", "pinky"]
# Loaded at runtime (not preload/class_name) so this core script still parses if
# godot_xr_hands is absent - the preview just no-ops then.
const _POSE_MATH_PATH := "res://addons/godot_xr_hands/runtime/xr_hand_pose_math.gd"


func _pose_math() -> Object:
	return load(_POSE_MATH_PATH) if ResourceLoader.exists(_POSE_MATH_PATH) else null

## Built-in grips (per-finger curl 0..1), consulted BEFORE the gesture library.
##
## These exist because a gesture RESOURCE and a held GRIP are different things
## that look interchangeable. A shipped preset like trigger_grip.tres is a
## recognition rule - "are these fingers making a trigger grip?" - stored as
## per-finger tolerance bands, and fingers it does not care about are simply
## absent. Rendered as a shape those absences read as straight fingers: the
## trigger preset leaves the THUMB unconstrained, so a hand posed from it holds
## nothing, thumb and index both sticking out. Recognition presets stay tuned
## for recognition; the grips below are tuned to look like a hold.
##
## A pose RECORDED in the Gesture Studio carries a real joint snapshot and is
## always preferred - it is a shape someone's actual hand made.
const _BUILTIN := {
	"Open": {"thumb": 0.0, "index": 0.0, "middle": 0.0, "ring": 0.0, "pinky": 0.0},
	"Relaxed Grip": {"thumb": 0.35, "index": 0.5, "middle": 0.55, "ring": 0.6, "pinky": 0.6},
	"Pinch": {"thumb": 0.45, "index": 0.5, "middle": 0.25, "ring": 0.2, "pinky": 0.2},
	"Fist": {"thumb": 0.5, "index": 0.85, "middle": 0.9, "ring": 0.95, "pinky": 0.95},
	# Wraps a can-sized body: three fingers closed, thumb closed OVER them, and
	# the index left nearly straight to reach a trigger or a top button.
	"Trigger Grip": {"thumb": 0.62, "index": 0.12, "middle": 0.85, "ring": 0.88, "pinky": 0.85},
	# A whole-hand wrap with no free finger, for handles and hafts.
	"Tool Grip": {"thumb": 0.6, "index": 0.8, "middle": 0.85, "ring": 0.88, "pinky": 0.88},
}


## Expose preview_pose as a dropdown of the built-in grips + every SAVED pose.
func _get_property_list() -> Array[Dictionary]:
	var names: Array = _BUILTIN.keys()
	var math := _pose_math()
	if math:
		for pose in math.list_poses():
			if not names.has(pose["name"]):
				names.append(pose["name"])
	var props: Array[Dictionary] = [{
		"name": "preview_pose",
		"type": TYPE_STRING,
		"usage": PROPERTY_USAGE_DEFAULT,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": ",".join(names),
	}]
	return props

var _interactable: Node
var _hand_preview: Node3D


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		return
	var cursor := get_parent()
	while cursor != null and not cursor.has_method("register_grab_point"):
		cursor = cursor.get_parent()
	_interactable = cursor
	if _interactable:
		_interactable.register_grab_point(self)


func _exit_tree() -> void:
	if _interactable and is_instance_valid(_interactable):
		_interactable.unregister_grab_point(self)
	_interactable = null


func _ready() -> void:
	if Engine.is_editor_hint():
		_build_editor_marker()
		if preview_hand:
			_rebuild_hand_preview()


## The interactable calls these when this point wins a grab and when the hold
## ends. Told rather than observed: several points can be registered on one
## object and only the one that actually won may pose the hand.
func notify_held(hand: int) -> void:
	if not pose_hand_while_held:
		return
	var visualizer := _mesh_visualizer()
	if visualizer == null:
		return
	var joints := _held_joints(hand)
	if joints.is_empty():
		return
	visualizer.set_grip_pose(hand, joints, free_fingers)


func notify_released(hand: int) -> void:
	if not pose_hand_while_held:
		return
	var visualizer := _mesh_visualizer()
	if visualizer:
		visualizer.clear_grip_pose(hand)


## Soft lookup by group: realistic hands live in godot_xr_hands, which the
## toolkit does not depend on. No meshes, no posing, no error.
func _mesh_visualizer() -> Node:
	if not is_inside_tree():
		return null
	var node := get_tree().get_first_node_in_group("xr_hand_mesh_visualizer")
	return node if node and node.has_method("set_grip_pose") else null


## The authored grip as wrist-relative joints for THIS hand. Built against the
## target hand's own bind skeleton, so a right-handed authored grip comes out
## correct on a left hand with no mirroring step - the poses are rotations over
## whatever bones the hand actually has, which is also why one authored pose
## fits every hand size (Meta ships per-scale pose variants to solve the same
## problem positionally).
func _held_joints(hand: int) -> Array:
	var math := _pose_math()
	if math == null:
		return []
	if _bind_cache.is_empty():
		# Parses a glb - cached statically, since every grab point in a scene
		# wants the same two skeletons.
		_bind_cache = math.load_bind_skeletons()
	if not _bind_cache.has(hand):
		return []
	var rel: Array = _bind_cache[hand]["rel"]
	var axes: Array = _bind_cache[hand]["curl_axes"]
	if _BUILTIN.has(preview_pose):
		return math.fk_pose(rel, axes, _BUILTIN[preview_pose])
	var gesture := _find_pose(preview_pose, math)
	if gesture == null:
		return []
	return math.pose_joints(rel, axes, gesture, hand)


static var _bind_cache := {}


func _set_preview_hand(value: bool) -> void:
	preview_hand = value
	if is_inside_tree() and Engine.is_editor_hint():
		_rebuild_hand_preview()


func _set_preview_pose(value: String) -> void:
	preview_pose = value
	if is_inside_tree() and Engine.is_editor_hint():
		_rebuild_hand_preview()


## Editor-only ghost hand whose GRIP coincides with this grab point (built from
## the model's bind-pose joints with the SAME basis the live grip uses), so what
## you see gripping the object here is what you get in-headset.
const _PREVIEW_META := "grab_point_hand_preview"

func _rebuild_hand_preview() -> void:
	# Remove any previous preview - including one orphaned by a @tool script
	# reload (which nulls _hand_preview but leaves the child), the case that made
	# toggling off do nothing.
	for child in get_children():
		if child.has_meta(_PREVIEW_META):
			remove_child(child)
			child.queue_free()
	_hand_preview = null
	if not preview_hand or not Engine.is_editor_hint():
		return
	var packed := load(_HAND_MODEL_PATH) as PackedScene
	if packed == null:
		return
	var ghost := packed.instantiate() as Node3D
	if ghost == null:
		return
	ghost.set_meta(_PREVIEW_META, true)
	add_child(ghost)
	_hand_preview = ghost
	var skeleton := _find_skeleton(ghost)
	if skeleton == null:
		return
	var wrist := skeleton.find_bone("wrist")
	# Metacarpals (palm bones) for direction - pose-independent, matching the
	# runtime grip - so the preview orientation holds regardless of finger curl.
	var index := skeleton.find_bone("index-finger-metacarpal")
	var pinky := skeleton.find_bone("pinky-finger-metacarpal")
	var middle := skeleton.find_bone("middle-finger-metacarpal")
	var middle_proximal := skeleton.find_bone("middle-finger-phalanx-proximal")
	if wrist < 0 or index < 0 or pinky < 0:
		return
	var s2w := skeleton.global_transform
	var wrist_p: Vector3 = s2w * skeleton.get_bone_global_rest(wrist).origin
	var index_p: Vector3 = s2w * skeleton.get_bone_global_rest(index).origin
	var pinky_p: Vector3 = s2w * skeleton.get_bone_global_rest(pinky).origin
	# The runtime's grip anchor (resolve_grip_anchor in
	# xr_controller_hand_adapter.gd) reads the tracker's real PALM joint
	# first. This rig has no "palm" bone to read directly, so approximate the
	# same anatomical point: OpenXR's XR_HAND_JOINT_PALM_EXT sits at the
	# CENTER of the middle metacarpal BONE, i.e. the midpoint between that
	# metacarpal's own joint and the middle finger's proximal phalanx joint
	# (Meta's OpenXR SDK computes a runtime-synthesized palm the same way;
	# xr_simulator.gd's fake tracker now agrees). A wrist<->metacarpal
	# midpoint reads too close to the wrist - that convention was retired
	# from the runtime grip anchor 2026-07-24 for exactly that reason. Until
	# this fix the preview still used the retired convention, so what you
	# authored against no longer matched where the object actually anchors.
	var origin_p := wrist_p
	if middle >= 0 and middle_proximal >= 0:
		var middle_p: Vector3 = s2w * skeleton.get_bone_global_rest(middle).origin
		var middle_proximal_p: Vector3 = s2w * skeleton.get_bone_global_rest(middle_proximal).origin
		origin_p = (middle_p + middle_proximal_p) * 0.5
	elif middle >= 0:
		origin_p = s2w * skeleton.get_bone_global_rest(middle).origin
	var forward := (index_p - wrist_p).normalized()
	var across := pinky_p - index_p
	if forward.length_squared() < 0.000001 or across.length_squared() < 0.000001:
		return
	var up := forward.cross(across.normalized()).normalized()
	var grip_world := Transform3D(Basis(up.cross(-forward).normalized(), up, -forward).orthonormalized(), origin_p)
	# Place the ghost so its grip lands on this grab point (using the OPEN-hand
	# joints), then curl the fingers into the chosen pose - the grip origin
	# (wrist/palm) does not move, so the alignment holds.
	var grip_rel_hand := ghost.global_transform.affine_inverse() * grip_world
	ghost.global_transform = global_transform * grip_rel_hand.affine_inverse()
	_pose_skeleton(skeleton)


## Pose the ghost's fingers into the selected grip via the shared pose math, so
## it matches the Gesture Studio exactly. We build the bind as wrist-relative
## bone-rest transforms, run the shared FK / snapshot solver, then write the
## result back (wrist_rest * result) as bone poses.
func _pose_skeleton(skeleton: Skeleton3D) -> void:
	var math := _pose_math()
	if math == null:
		return
	var joint_bone := _joint_bone_map(skeleton, math)
	if not joint_bone.has(XRHandTracker.HAND_JOINT_WRIST):
		return
	var wrist_rest: Transform3D = skeleton.get_bone_global_rest(joint_bone[XRHandTracker.HAND_JOINT_WRIST])
	var bind := _build_bind(skeleton, joint_bone, wrist_rest)
	var curl_axes: Array = math.measure_curl_axes(bind)
	var posed: Array
	if _BUILTIN.has(preview_pose):
		posed = math.fk_pose(bind, curl_axes, _BUILTIN[preview_pose])
	else:
		var gesture := _find_pose(preview_pose, math)
		if gesture == null:
			return
		posed = math.pose_joints(bind, curl_axes, gesture, 1)
	for joint in joint_bone:
		var world: Transform3D = wrist_rest * (posed[joint] as Transform3D)
		skeleton.set_bone_pose_position(joint_bone[joint], world.origin)
		skeleton.set_bone_pose_rotation(joint_bone[joint], world.basis.get_rotation_quaternion())


## Map each WebXR joint to the ghost skeleton's bone index.
func _joint_bone_map(skeleton: Skeleton3D, math: Object) -> Dictionary:
	var map := {}
	var wrist := skeleton.find_bone("wrist")
	if wrist >= 0:
		map[XRHandTracker.HAND_JOINT_WRIST] = wrist
	for f in _FINGER_ORDER.size():
		var names: Array = _CHAINS[_FINGER_ORDER[f]]
		var joints: Array = math.FINGER_CHAINS[f]
		for i in names.size():
			var bone := skeleton.find_bone(names[i])
			if bone >= 0:
				map[joints[i]] = bone
	return map


## Wrist-relative bone-rest transforms per joint (the bind the pose math wants).
func _build_bind(skeleton: Skeleton3D, joint_bone: Dictionary, wrist_rest: Transform3D) -> Array:
	var bind: Array = []
	bind.resize(XRHandTracker.HAND_JOINT_MAX)
	for j in XRHandTracker.HAND_JOINT_MAX:
		bind[j] = Transform3D.IDENTITY
	var to_wrist := wrist_rest.affine_inverse()
	for joint in joint_bone:
		bind[joint] = to_wrist * skeleton.get_bone_global_rest(joint_bone[joint])
	# Same grip-anchor convention as resolve_grip_anchor()'s runtime PALM and
	# xr_simulator.gd's fake tracker: OpenXR's XR_HAND_JOINT_PALM_EXT sits at
	# the CENTER of the middle metacarpal bone (metacarpal joint <->
	# proximal-phalanx joint midpoint), not a wrist<->metacarpal midpoint.
	# Traced downstream: this is currently DEAD data. xr_hand_pose_math.gd
	# (measure_curl_axes/fk_pose/pose_joints/rel_from_recorded) never reads
	# HAND_JOINT_PALM - they key off the finger chains and WRIST only - and
	# _pose_skeleton's write-back loop only visits joint_bone's keys, which
	# never include PALM (this rig has no "palm" bone to map one to). Kept
	# correct anyway, at zero behavioral cost, so it cannot silently diverge
	# again if a future reader starts using it.
	var middle: Vector3 = (bind[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL] as Transform3D).origin
	var middle_proximal_joint := XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL
	var palm_origin := middle
	if joint_bone.has(middle_proximal_joint):
		palm_origin = (middle + (bind[middle_proximal_joint] as Transform3D).origin) * 0.5
	bind[XRHandTracker.HAND_JOINT_PALM] = Transform3D(Basis.IDENTITY, palm_origin)
	return bind


func _find_pose(pose_name: String, math: Object) -> Object:
	for pose in math.list_poses():
		if pose["name"] == pose_name:
			return pose["resource"]
	return null


func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for child in node.get_children():
		var found := _find_skeleton(child)
		if found:
			return found
	return null


func _get_configuration_warnings() -> PackedStringArray:
	var cursor := get_parent()
	while cursor != null:
		if cursor.has_method("register_grab_point"):
			return PackedStringArray()
		cursor = cursor.get_parent()
	return PackedStringArray(["Place this INSIDE a grab interactable (any ancestor)."])


func matches_hand(interactor_hand: int) -> bool:
	return hand < 0 or hand == interactor_hand


## Editor-only visual: a palm bar with a forward (-Z) arrow. Not saved into
## the scene (no owner), zero runtime cost.
func _build_editor_marker() -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.35, 1.0, 0.6, 0.9)

	var palm := MeshInstance3D.new()
	var palm_mesh := BoxMesh.new()
	palm_mesh.size = Vector3(0.05, 0.012, 0.03)
	palm.mesh = palm_mesh
	palm.material_override = material
	add_child(palm)

	var arrow := MeshInstance3D.new()
	var arrow_mesh := CylinderMesh.new()
	arrow_mesh.top_radius = 0.0
	arrow_mesh.bottom_radius = 0.008
	arrow_mesh.height = 0.045
	arrow.mesh = arrow_mesh
	arrow.material_override = material
	arrow.position = Vector3(0.0, 0.0, -0.035)
	arrow.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	add_child(arrow)
