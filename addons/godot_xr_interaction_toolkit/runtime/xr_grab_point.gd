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

## Derive WHERE the hand goes from the object's own collision geometry instead
## of this node's authored transform, the way "Auto (fit object)" derives the
## fingers. The node's position stays meaningful as a HINT - it picks which
## side of the object the palm lands on - but the exact placement, the surface
## contact and the wrap orientation are solved from the shape.
##
## This exists because an authored grip transform is a six-degree-of-freedom
## hand-tune that nothing checks, and they drift: the spray can's authored
## point sat 13.6 cm from a can 6.4 cm wide, so the palm was anchored in empty
## air and the can dangled past the fingertips. No finger pose can rescue a
## palm that is not on the object.
@export var auto_place := false

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

## Fingers that stay EXTENDED to reach a control rather than wrapping the body.
## This is what makes a held spray can read as a spray can: photographs of the
## real grip all show three fingers round the body, the thumb opposite, and the
## index laid along the barrel onto the actuator - it never wraps. Curling every
## finger onto the surface, which is what fitting alone does, produces a uniform
## pipe-grip that holds the object without looking like anyone holding THAT
## object. Pair with the object's business end at the index side, which is where
## the auto-placed frame puts it.
@export_flags("Thumb", "Index", "Middle", "Ring", "Pinky") var reach_fingers := 0

## How straight a reaching finger stays. Not zero: a finger laid on a cap has a
## slight bend, and a perfectly straight one reads as a pointing hand.
@export_range(0.0, 0.6, 0.01) var reach_curl := 0.16

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


## The pose that is not a pose: derived from the OBJECT instead. Each finger
## curls (same hinge FK as every other pose) until it touches the object's own
## collision shape, so the item's geometry IS the grip data - no studio
## session, no authoring, and it holds for objects that do not exist yet.
## The editor ghost runs the same solve, so the preview shows the fitted grip
## against the actual item.
const AUTO_POSE := "Auto (fit object)"
## Skin pad: fingers stop this far off the surface rather than exactly on it,
## because a fingertip JOINT sits at the finger's core, not its pad.
const _FIT_PAD := 0.008
## Curl sweep for the fit. Past 1.0 deliberately: the 0..1 gesture range tops
## out with fingertips 5.7 cm from the palm (measured), while a wrap needs
## 2-4 cm - which extended curls reach (1.3 -> 3.2 cm, 1.5 -> 1.9 cm).
const _FIT_CURL_MAX := 1.7
const _FIT_STEPS := 24
## The thumb's FK spans 1.7 rad where the fingers span 3.6, so the same curl
## number turns it more than twice as far - past roughly this it folds through
## the palm rather than onto the object, whatever the contact test says.
const _FIT_THUMB_MAX := 0.85


## Expose preview_pose as a dropdown of the built-in grips + every SAVED pose.
func _get_property_list() -> Array[Dictionary]:
	var names: Array = [AUTO_POSE]
	names.append_array(_BUILTIN.keys())
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
	if preview_pose == AUTO_POSE:
		# A grip RECORDED against this object wins over fitting it. Auto-fit
		# curls each finger around one hinge until it touches the collider,
		# which closes plausibly but never humanly - no splay, no thumb rolling
		# across the barrel, no per-joint variation. A recording has all three
		# because a real hand made it against the real shape. Fitting is the
		# fallback that keeps every un-recorded prop working.
		var recorded := _recorded_grip_for_object(math)
		if recorded != null:
			return _snap_to_surface(math.pose_joints(rel, axes, recorded, hand), rel)
		return math.fk_pose(rel, axes, _fit_curls(rel, axes, math))
	if _BUILTIN.has(preview_pose):
		return math.fk_pose(rel, axes, _BUILTIN[preview_pose])
	var gesture := _find_pose(preview_pose, math)
	if gesture == null:
		return []
	return math.pose_joints(rel, axes, gesture, hand)


## Where the hand's grip actually goes for this point - the authored transform
## normally, or a placement solved from the object when auto_place is on.
## Everything that positions a hand against this point goes through here, so
## the runtime grab, the auto-fit and the editor ghost cannot disagree.
func grip_transform() -> Transform3D:
	if not auto_place:
		return global_transform
	var body := _collision_body()
	if body == null:
		return global_transform
	var frames: Variant = _auto_grip_in_body(body)
	if frames == null or (frames as Array).is_empty():
		return global_transform
	var chosen: int = clampi(_frame_choice, 0, (frames as Array).size() - 1)
	return body.global_transform * ((frames as Array)[chosen] as Transform3D)


func _collision_body() -> CollisionObject3D:
	var cursor := get_parent()
	while cursor != null and not (cursor is CollisionObject3D):
		cursor = cursor.get_parent()
	return cursor as CollisionObject3D


## Solve a wrap grip against the body's largest round shape: palm ON the
## surface, facing the axis, fist wrapping the circumference.
##
## Round shapes only (cylinder/capsule/sphere) - a hand wrapping a barrel is
## the case a shape can answer unambiguously. Boxes and meshes fall back to
## the authored transform rather than guessing a face, because "which way is
## up on this box" is an intent question, not a geometry one.
func _auto_grip_in_body(body: CollisionObject3D) -> Variant:
	var best: CollisionShape3D = null
	var best_size := -1.0
	for child in body.get_children():
		var col := child as CollisionShape3D
		if col == null or col.disabled or col.shape == null:
			continue
		var size := _round_shape_size(col.shape)
		if size > best_size:
			best_size = size
			best = col
	if best == null or best_size < 0.0:
		return null

	var shape_xform: Transform3D = best.transform
	var radius := _round_shape_radius(best.shape)
	# The axis a fist wraps AROUND: the shape's own long axis (Y for cylinder
	# and capsule). A sphere has none, so the hint direction supplies one.
	var axis: Vector3 = (shape_xform.basis * Vector3.UP).normalized()

	# The authored node position is the hint: which side to approach from,
	# taken perpendicular to the axis so it names a direction around the
	# barrel rather than a point along it.
	var hint: Vector3 = transform.origin - shape_xform.origin
	var radial := hint - axis * hint.dot(axis)
	if radial.length_squared() < 0.000001:
		# No usable hint (point on the axis): approach from whichever way the
		# authored basis was already facing, so the answer stays stable.
		radial = transform.basis.z - axis * transform.basis.z.dot(axis)
	if radial.length_squared() < 0.000001:
		radial = Vector3.RIGHT if absf(axis.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	radial = radial.normalized()

	# Palm ON the surface. The fingers curl from here around the barrel: at a
	# 3.2 cm radius the far side is ~6.4 cm away and a full curl reaches
	# ~5.7 cm, which is why a wrap closes at all.
	var palm: Vector3 = shape_xform.origin + radial * radius
	# Fist axis points along the barrel (thumb toward one end); fingers run
	# tangentially. Which tangent sign wraps and which curls away is
	# handedness, so it is MEASURED below rather than derived.
	# ORIENTATION IS AUTHORED, POSITION IS SOLVED - and the split is where it
	# is because of what each source can actually know. A collider knows where
	# its surface is, so the palm lands on it and the 13.6 cm anchor drift
	# cannot come back. A collider does NOT know that a spray can is held
	# nozzle-up with the index on the trigger; that is intent, and no amount
	# of geometry recovers it.
	#
	# Scoring orientations by finger contact was tried and is wrong at the
	# objective: many orientations wrap a cylinder equally well and most of
	# them look nothing like a hand holding a can, so the scorer keeps
	# choosing plausible-to-arithmetic, absurd-to-a-person. Contact measures
	# whether fingers reach, never whether the hold reads.
	# Where the can must LIE for this hand to be holding it, measured off the
	# hand instead of argued about. Wrap your hand round a can and the four
	# fingers stack ALONG it - index at the top, pinky at the bottom - so the
	# barrel's axis runs in the index->pinky direction, and the barrel's centre
	# sits off the palm toward where the curled fingers close. Both are read
	# from the bind skeleton below. I had the axis on "up out of the fist",
	# which is why every attempt came out rolled a quarter turn: that axis
	# points out of the SIDE of a hand holding a can, not along it.
	var wrap := _measure_wrap_frame()
	if wrap.is_empty():
		return [Transform3D(transform.basis.orthonormalized(), palm)]

	# The can expressed in the hand's frame: its own +Y (the cylinder axis)
	# laid along the measured stack direction, centred where the fingers close.
	var can_axis: Vector3 = wrap["axis"]
	var toward: Vector3 = wrap["toward"]
	# ROLL about the barrel is a third degree of freedom, and deriving it from
	# where the fingers close only fixed which side of the palm the object sits
	# on - its FACING stayed arbitrary, and landed a quarter turn off, aiming
	# along the hand's +X (out to the right) instead of forward. The convention
	# already in this file answers it: -Z is the aim direction, for grab points
	# and grip poses alike, so an object's -Z lines up with the hand's -Z and a
	# spray can points where the hand points.
	var front := Vector3.BACK - can_axis * Vector3.BACK.dot(can_axis)
	if front.length_squared() < 0.000001:
		# Barrel already along the aim axis: nothing to align, so fall back to
		# the finger-closure direction rather than picking a roll at random.
		front = toward
	front = front.normalized()
	var side := can_axis.cross(front).normalized()
	if side.length_squared() < 0.000001:
		return [Transform3D(transform.basis.orthonormalized(), palm)]
	var can_in_hand := Transform3D(
			Basis(side, can_axis, front).orthonormalized(),
			toward * radius)
	# The grab point IS the hand's frame in the object's coordinates, so it is
	# that relationship inverted - then carried into the shape's own frame, in
	# case the collider is not at the body's origin.
	return [shape_xform * can_in_hand.affine_inverse()]


## The barrel a wrapped hand forms, in GRIP space: which way it runs, and which
## way it sits from the palm. Measured off the bundled hand's bind skeleton
## with the fingers curled, so it describes this hand rather than a convention.
func _measure_wrap_frame() -> Dictionary:
	var math := _pose_math()
	if math == null:
		return {}
	if _bind_cache.is_empty():
		_bind_cache = math.load_bind_skeletons()
	if not _bind_cache.has(1):
		return {}
	var rel: Array = _bind_cache[1]["rel"]
	var to_grip := _grip_frame_in_wrist(rel).affine_inverse()

	# The stack direction: the line the fingers are arrayed along, which is the
	# barrel's axis. Pointing PINKY->INDEX, not the other way, and the sign is
	# not arbitrary: an object's own +Y is its business end (a can's nozzle, a
	# torch's lamp), and you hold those with the working end at the INDEX side
	# because the index is the finger that reaches the trigger. Signed toward
	# the pinky instead, every object comes out nozzle-down - which is exactly
	# how it presented.
	var index_mc: Vector3 = to_grip * (rel[XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL] as Transform3D).origin
	var pinky_mc: Vector3 = to_grip * (rel[XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL] as Transform3D).origin
	var axis := (index_mc - pinky_mc)
	if axis.length_squared() < 0.000001:
		return {}
	axis = axis.normalized()

	# Where the barrel sits: curl the fingers and take where their tips close.
	# The palm is the grip origin, so the direction to that closure - with the
	# stack component removed - is the direction the held object lies in.
	var curled: Array = math.fk_pose(rel, _bind_cache[1]["curl_axes"],
			{"thumb": 0.6, "index": 1.1, "middle": 1.2, "ring": 1.2, "pinky": 1.2})
	var chains: Array = math.FINGER_CHAINS
	var closure := Vector3.ZERO
	var counted := 0
	for f in range(1, chains.size()):
		var tip: int = chains[f][chains[f].size() - 1]
		closure += to_grip * (curled[tip] as Transform3D).origin
		counted += 1
	if counted == 0:
		return {}
	closure /= float(counted)
	var toward := closure - axis * closure.dot(axis)
	if toward.length_squared() < 0.000001:
		return {}
	return {"axis": axis, "toward": toward.normalized()}


## Assemble the grip basis the way the runtime and the editor ghost both do,
## so a solved placement is expressed in the one convention everything reads.
func _grip_basis(up: Vector3, forward: Vector3) -> Basis:
	return Basis(up.cross(-forward).normalized(), up, -forward).orthonormalized()


func _round_shape_size(shape: Shape3D) -> float:
	if shape is SphereShape3D:
		return (shape as SphereShape3D).radius
	if shape is CapsuleShape3D:
		return (shape as CapsuleShape3D).radius
	if shape is CylinderShape3D:
		return (shape as CylinderShape3D).radius
	return -1.0


func _round_shape_radius(shape: Shape3D) -> float:
	return maxf(_round_shape_size(shape), 0.001)


## Name a grip recorded for THIS object would be saved under. Derived from the
## scene file the object came from, so the recording station and the grab point
## agree without either storing a reference to the other - record a grip for
## spray_can.tscn and every spray can in every scene picks it up.
func recorded_grip_name() -> String:
	var scene_path := ""
	var cursor: Node = self
	while cursor != null:
		if not cursor.scene_file_path.is_empty():
			scene_path = cursor.scene_file_path
			break
		cursor = cursor.get_parent()
	if scene_path.is_empty():
		return ""
	return "grip_" + scene_path.get_file().get_basename()


## Settle an imported or recorded grip onto THIS object's actual surface.
##
## A grip from a photograph carries the things a solver cannot invent - splay,
## thumb opposition, per-joint variation - and, because a single image has no
## reliable absolute depth, gets the distances approximately. A grip from
## another object's recording has the same problem for a different reason. So
## take the human structure from the pose and the dimensions from the collider:
## move each fingertip the small amount that puts it ON the surface, and carry
## the joints above it along in proportion, which bends the finger rather than
## detaching it.
##
## Deliberately gentle. Anything past a couple of centimetres is not a depth
## error, it is a different grip, and dragging it into contact would destroy
## the pose that made importing worth doing.
const _SNAP_LIMIT := 0.022

func _snap_to_surface(joints: Array, rel: Array) -> Array:
	if not auto_place or joints.is_empty():
		return joints
	var shapes := _collect_fit_shapes(rel)
	if shapes.is_empty():
		return joints
	var math := _pose_math()
	if math == null:
		return joints
	var out := joints.duplicate()
	for chain in math.FINGER_CHAINS:
		var tip: int = chain[chain.size() - 1]
		var tip_pose: Transform3D = out[tip]
		var distance := _surface_distance(tip_pose.origin, shapes)
		if not is_finite(distance) or absf(distance) > _SNAP_LIMIT or absf(distance) < 0.001:
			continue
		# Toward the surface along the steepest descent of the distance field,
		# sampled rather than differentiated analytically - the shapes are a
		# mixed set and a numeric gradient handles all of them alike.
		var step := 0.0015
		var gradient := Vector3(
				_surface_distance(tip_pose.origin + Vector3(step, 0, 0), shapes) - distance,
				_surface_distance(tip_pose.origin + Vector3(0, step, 0), shapes) - distance,
				_surface_distance(tip_pose.origin + Vector3(0, 0, step), shapes) - distance)
		if gradient.length_squared() < 0.000000001:
			continue
		var correction := -gradient.normalized() * (distance - _FIT_PAD)
		# Distribute along the finger: the tip takes the whole correction, each
		# joint above it proportionally less, so the finger flexes instead of
		# translating off its knuckle.
		for i in range(1, chain.size()):
			var share := float(i) / float(chain.size() - 1)
			var pose: Transform3D = out[chain[i]]
			out[chain[i]] = Transform3D(pose.basis, pose.origin + correction * share)
	return out


func _recorded_grip_for_object(math: Object) -> Object:
	var wanted := recorded_grip_name()
	return null if wanted.is_empty() else _find_pose(wanted, math)


## ---- Auto-fit: curl each finger onto the object's collision shapes ---------

## Per-finger curls that wrap THIS object: sweep each finger's curl and stop
## at first contact with any collision shape (plus the skin pad). The sweep is
## sampled rather than binary-searched on purpose - contact distance is not
## monotonic once a finger passes a surface tangentially, and 24 FK poses are
## effectively free.
## Pick the candidate frame whose fingers close on the most surface. Costs one
## fit per candidate, once, at grab time - and replaces a guess that has been
## wrong in two different ways with a number.
func _choose_frame(rel: Array, axes: Array, math: Object, count: int) -> int:
	var best := 0
	var best_contact := INF
	for candidate in count:
		var contact := _fit_contact(rel, axes, math, candidate)
		if contact < best_contact:
			best_contact = contact
			best = candidate
	return best


## Total fingertip-to-surface distance for one candidate frame: lower wraps.
func _fit_contact(rel: Array, axes: Array, math: Object, candidate: int) -> float:
	_frame_choice = candidate
	var shapes := _collect_fit_shapes(rel)
	if shapes.is_empty():
		return INF
	var chains: Array = math.FINGER_CHAINS
	var names: Array = math.FINGER_NAMES
	var total := 0.0
	for f in names.size():
		var curl: float = _fit_one_finger(rel, axes, math, chains[f], names[f], shapes)
		var posed: Array = math.fk_pose(rel, axes, {names[f]: curl})
		var tip: int = chains[f][chains[f].size() - 1]
		total += absf(_surface_distance((posed[tip] as Transform3D).origin, shapes))
	return total


## Which candidate frame grip_transform() currently reports - set while the
## candidates are being scored, then left on the winner.
var _frame_choice := 0


func _fit_curls(rel: Array, axes: Array, math: Object) -> Dictionary:
	var shapes := _collect_fit_shapes(rel)
	if shapes.is_empty():
		return _BUILTIN["Relaxed Grip"]
	var chains: Array = math.FINGER_CHAINS
	var names: Array = math.FINGER_NAMES
	var curls := {}
	for f in names.size():
		if (reach_fingers & (1 << f)) != 0:
			# Reaching, not wrapping: laid along the barrel toward the control.
			curls[names[f]] = reach_curl
			continue
		# The thumb's FK spans 1.7 rad against the fingers' 3.6, so the same
		# sweep range covers a proportionally similar arc.
		curls[names[f]] = _fit_one_finger(rel, axes, math, chains[f], names[f], shapes)
	return curls


func _fit_one_finger(rel: Array, axes: Array, math: Object, chain: Array, finger: String, shapes: Array) -> float:
	var best_curl := 0.35
	var best_distance := INF
	var previous := INF
	var curl_max: float = _FIT_THUMB_MAX if finger == "thumb" else _FIT_CURL_MAX
	for step in _FIT_STEPS + 1:
		var curl := 0.05 + (curl_max - 0.05) * float(step) / float(_FIT_STEPS)
		var posed: Array = math.fk_pose(rel, axes, {finger: curl})
		# Sampled ALONG the bones, not just at the joints. A joint-only test
		# lets a bone pass clean through a surface between its two ends, which
		# is exactly how the thumb - whose FK spans a shorter arc, so it turns
		# further per unit curl - drove itself into the can while every sampled
		# point still read clear.
		var distance := INF
		for i in range(maxi(chain.size() - 3, 1), chain.size()):
			var here: Vector3 = (posed[chain[i]] as Transform3D).origin
			distance = minf(distance, _surface_distance(here, shapes))
			if i > 0:
				var previous_joint: Vector3 = (posed[chain[i - 1]] as Transform3D).origin
				for t in [0.33, 0.66]:
					distance = minf(distance, _surface_distance(previous_joint.lerp(here, t), shapes))
		if distance <= _FIT_PAD:
			# Contact: settle halfway back toward the previous (clear) sample
			# so the finger rests ON the pad rather than inside the surface.
			return curl if previous > _FIT_PAD * 2.0 else curl - (curl_max - 0.05) / float(_FIT_STEPS) * 0.5
		if distance < best_distance:
			best_distance = distance
			best_curl = curl
		previous = distance
	# Never touched (object thinner than the closed hand, or shapes far from
	# this finger): the closest approach still reads as an intentional wrap.
	return best_curl


## Collision shapes of the body this point is authored inside, expressed in
## GRIP space - the frame the fingers are posed in, where the palm anchor sits
## at this grab point. Shape offsets from the point are rigid scene data, so
## this works identically in the editor ghost and at grab time.
func _collect_fit_shapes(rel: Array) -> Array:
	var body := get_parent()
	while body != null and not (body is CollisionObject3D):
		body = body.get_parent()
	if body == null:
		return []
	var grip_from_point := _grip_frame_in_wrist(rel)
	var out := []
	for child in body.get_children():
		var col := child as CollisionShape3D
		if col == null or col.disabled or col.shape == null:
			continue
		# Through grip_transform(), not global_transform: with auto_place the
		# palm is solved from the shape, and fitting fingers against the
		# authored transform instead would pose them for a hold that is not
		# the one happening.
		var shape_in_point := grip_transform().affine_inverse() * col.global_transform
		out.append({"shape": col.shape, "xform": grip_from_point * shape_in_point})
	return out


## Where the grip frame (palm anchor, grip basis) sits in the WRIST frame of
## the bind - built from the bind joints with the same metacarpal convention
## the runtime and the editor ghost use, so all three agree by construction.
func _grip_frame_in_wrist(rel: Array) -> Transform3D:
	var wrist_p := Vector3.ZERO
	var index_p: Vector3 = (rel[XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL] as Transform3D).origin
	var pinky_p: Vector3 = (rel[XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL] as Transform3D).origin
	var palm_p: Vector3 = (rel[XRHandTracker.HAND_JOINT_PALM] as Transform3D).origin
	var forward := (index_p - wrist_p).normalized()
	var across := pinky_p - index_p
	var up := forward.cross(across.normalized()).normalized()
	return Transform3D(Basis(up.cross(-forward).normalized(), up, -forward).orthonormalized(), palm_p)


## Signed distance from a point to a shape's surface (negative = inside).
## Analytic for the primitives the samples use; unknown shapes are skipped.
func _surface_distance(point: Vector3, shapes: Array) -> float:
	var best := INF
	for entry in shapes:
		var q: Vector3 = (entry["xform"] as Transform3D).affine_inverse() * point
		var shape: Shape3D = entry["shape"]
		var d := INF
		if shape is SphereShape3D:
			d = q.length() - (shape as SphereShape3D).radius
		elif shape is CapsuleShape3D:
			var cap := shape as CapsuleShape3D
			var half := maxf(cap.height * 0.5 - cap.radius, 0.0)
			var on_axis := Vector3(0.0, clampf(q.y, -half, half), 0.0)
			d = q.distance_to(on_axis) - cap.radius
		elif shape is CylinderShape3D:
			var cyl := shape as CylinderShape3D
			var radial := Vector2(q.x, q.z).length() - cyl.radius
			var axial := absf(q.y) - cyl.height * 0.5
			if radial <= 0.0 and axial <= 0.0:
				d = maxf(radial, axial)
			else:
				d = Vector2(maxf(radial, 0.0), maxf(axial, 0.0)).length()
		elif shape is BoxShape3D:
			var half_size: Vector3 = (shape as BoxShape3D).size * 0.5
			var outside := (q.abs() - half_size).maxf(0.0)
			var inside := minf(maxf(q.abs().x - half_size.x, maxf(q.abs().y - half_size.y, q.abs().z - half_size.z)), 0.0)
			d = outside.length() + inside
		best = minf(best, d)
	return best


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
	# Against the SOLVED grip when auto_place is on, so the ghost previews the
	# hold that will actually happen rather than the authored hint.
	ghost.global_transform = grip_transform() * grip_rel_hand.affine_inverse()
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
	if preview_pose == AUTO_POSE:
		# The same solve the runtime runs, against the same scene shapes - the
		# ghost previews the FITTED grip on the actual item.
		posed = math.fk_pose(bind, curl_axes, _fit_curls(bind, curl_axes, math))
	elif _BUILTIN.has(preview_pose):
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
