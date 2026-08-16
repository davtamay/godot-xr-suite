class_name XRHandPoseMath
extends RefCounted

## Shared hand-pose math - the single home for turning a SAVED pose (an
## XRHandGesture .tres: a recorded joint snapshot, or curl conditions) into
## per-joint transforms. The Gesture Studio simulator and the grab-point
## Preview Hand both use this so a pose looks identical everywhere.
##
## It is convention-agnostic: the caller passes a BIND as wrist-relative
## Transform3Ds per joint (measured however that caller represents its
## skeleton), and gets wrist-relative posed transforms back. Positions AND
## authored orientations rotate together, so the skin stays coherent.

const FINGER_NAMES := ["thumb", "index", "middle", "ring", "pinky"]
const FINGER_CHAINS := [
	[XRHandTracker.HAND_JOINT_THUMB_METACARPAL, XRHandTracker.HAND_JOINT_THUMB_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_THUMB_TIP],
	[XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP],
	[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP],
	[XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_RING_FINGER_TIP],
	[XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP],
]

const PRESET_DIR := "res://addons/godot_xr_hands/runtime/gesture_studio/presets"
const USER_DIR := "user://gestures"


## Every saved pose (XRHandGesture .tres) from the shipped presets and the
## user's recordings: [{name, resource}].
static func list_poses() -> Array:
	var out: Array = []
	for dir_path in [PRESET_DIR, USER_DIR]:
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		for file in dir.get_files():
			if not file.ends_with(".tres"):
				continue
			var res := load(dir_path.path_join(file))
			if res == null:
				continue
			var pose_name: String = res.get("gesture_name") if res.get("gesture_name") else file.get_basename()
			out.append({"name": pose_name, "resource": res})
	return out


## Per-finger curl HINGE axes measured from the bind (palm_normal x bone; the
## thumb is opposition, across the palm), chirality-corrected by the thumb side.
static func measure_curl_axes(bind: Array) -> Array:
	var index_o: Vector3 = (bind[XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL] as Transform3D).origin
	var pinky_o: Vector3 = (bind[XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL] as Transform3D).origin
	var thumb_o: Vector3 = (bind[XRHandTracker.HAND_JOINT_THUMB_METACARPAL] as Transform3D).origin
	var normal := index_o.cross(pinky_o).normalized()
	if normal.dot(thumb_o - (index_o + pinky_o) * 0.5) > 0.0:
		normal = -normal
	var axes: Array = []
	for f in FINGER_CHAINS.size():
		var chain: Array = FINGER_CHAINS[f]
		var mc: Vector3 = (bind[chain[0]] as Transform3D).origin
		var proximal: Vector3 = (bind[chain[1]] as Transform3D).origin
		var bone := (proximal - mc).normalized()
		if f == 0:
			axes.append(bone.cross((pinky_o - mc).normalized()).normalized())
		else:
			axes.append(normal.cross(bone).normalized())
	return axes


## Turn a saved pose into wrist-relative joint transforms. Recorded snapshots go
## through reframe+retarget; condition-only presets synthesize an FK curl.
static func pose_joints(bind: Array, curl_axes: Array, gesture: Object, hand := 1) -> Array:
	var snapshot: PackedVector3Array = gesture.get("joint_snapshot") if gesture.get("joint_snapshot") is PackedVector3Array else PackedVector3Array()
	if snapshot.size() >= XRHandTracker.HAND_JOINT_MAX:
		var recorded: Variant = gesture.get("recorded_hand")
		var native: int = recorded if recorded is int and recorded >= 0 else 1
		var positions := snapshot if hand == native else mirrored(snapshot)
		return rel_from_recorded(bind, positions)
	return fk_pose(bind, curl_axes, curls_from_conditions(gesture.get("conditions")))


static func curls_from_conditions(conditions: Variant) -> Dictionary:
	var curls := {}
	if conditions is Dictionary:
		for f in FINGER_NAMES:
			var key := "curl_%s" % f
			if (conditions as Dictionary).has(key):
				curls[f] = ((conditions as Dictionary)[key] as Vector2).x
	return curls


## Same-axis FK: each finger's bends rotate around its bind hinge axis with an
## accumulating angle, positions and orientations together. `curls` is per-finger
## 0..1 (missing = 0.15 relaxed, matching the studio's open hand).
static func fk_pose(bind: Array, curl_axes: Array, curls: Dictionary) -> Array:
	var out := bind.duplicate()
	for f in FINGER_CHAINS.size():
		var chain: Array = FINGER_CHAINS[f]
		var curl: float = curls.get(FINGER_NAMES[f], 0.15)
		var total := curl * (1.7 if f == 0 else 3.6)
		var per_joint := total / maxf(chain.size() - 2, 1.0)
		var axis: Vector3 = curl_axes[f]
		var angle := 0.0
		for i in range(1, chain.size()):
			angle += per_joint
			var rotation := Basis(axis, angle)
			var previous_out: Transform3D = out[chain[i - 1]]
			var bind_step: Vector3 = (bind[chain[i]] as Transform3D).origin - (bind[chain[i - 1]] as Transform3D).origin
			out[chain[i]] = Transform3D(rotation * (bind[chain[i]] as Transform3D).basis,
					previous_out.origin + Basis(axis, angle - per_joint) * bind_step)
	return out


## Recorded snapshots are POSITIONS only, in the recorder's wrist frame; align
## both wrist frames the SAME way (removing the free chirality sign), reframe the
## positions, then RETARGET each authored bind frame onto the recorded bone
## direction so recorded and FK poses share one convention.
static func rel_from_recorded(bind: Array, positions: PackedVector3Array) -> Array:
	var f_rec := measure_wrist_frame(func(j): return positions[j])
	var f_bind := measure_wrist_frame(func(j): return (bind[j] as Transform3D).origin)
	var convert := f_bind * f_rec.inverse()
	var wrist_pos := positions[XRHandTracker.HAND_JOINT_WRIST]
	var reframed := PackedVector3Array()
	reframed.resize(positions.size())
	for joint in positions.size():
		reframed[joint] = convert * (positions[joint] - wrist_pos)
	var rel: Array = []
	rel.resize(positions.size())
	for joint in positions.size():
		rel[joint] = Transform3D((bind[joint] as Transform3D).basis, reframed[joint])
	for chain in FINGER_CHAINS:
		for i in range(chain.size() - 1):
			var joint: int = chain[i]
			var bind_bone: Vector3 = ((bind[chain[i + 1]] as Transform3D).origin - (bind[joint] as Transform3D).origin)
			var rec_bone: Vector3 = reframed[chain[i + 1]] - reframed[joint]
			rel[joint] = Transform3D(rotation_between(bind_bone, rec_bone) * (bind[joint] as Transform3D).basis, reframed[joint])
		var tip: int = chain[chain.size() - 1]
		var parent: int = chain[chain.size() - 2]
		rel[tip] = Transform3D((rel[parent] as Transform3D).basis, reframed[tip])
	return rel


static func rotation_between(from_dir: Vector3, to_dir: Vector3) -> Basis:
	var a := from_dir.normalized()
	var b := to_dir.normalized()
	if a.length_squared() < 0.000001 or b.length_squared() < 0.000001:
		return Basis.IDENTITY
	var dot := clampf(a.dot(b), -1.0, 1.0)
	if dot > 0.9999:
		return Basis.IDENTITY
	var axis := a.cross(b)
	if axis.length_squared() < 0.000001:
		axis = a.cross(Vector3.UP)
		if axis.length_squared() < 0.000001:
			axis = a.cross(Vector3.RIGHT)
	return Basis(axis.normalized(), acos(dot))


## Wrist frame from joint positions, measured identically for recorded and bind
## data (fingers = middle-metacarpal dir, palm normal = index x pinky with the
## thumb-side correction). The shared correction removes the free chirality sign.
static func measure_wrist_frame(get_pos: Callable) -> Basis:
	var wrist: Vector3 = get_pos.call(XRHandTracker.HAND_JOINT_WRIST)
	var index: Vector3 = get_pos.call(XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL)
	var pinky: Vector3 = get_pos.call(XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL)
	var thumb: Vector3 = get_pos.call(XRHandTracker.HAND_JOINT_THUMB_METACARPAL)
	var normal := (index - wrist).cross(pinky - wrist).normalized()
	if normal.dot(thumb - (index + pinky) * 0.5) > 0.0:
		normal = -normal
	var fingers: Vector3 = (get_pos.call(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL) - wrist).normalized()
	return basis_from_bone(fingers, normal)


static func basis_from_bone(y_dir: Vector3, reference_normal: Vector3) -> Basis:
	if y_dir.length_squared() < 0.000001:
		return Basis.IDENTITY
	var x_axis := reference_normal.cross(y_dir)
	if x_axis.length_squared() < 0.000001:
		x_axis = y_dir.cross(Vector3.UP)
		if x_axis.length_squared() < 0.000001:
			x_axis = Vector3.RIGHT
	x_axis = x_axis.normalized()
	var z_axis := x_axis.cross(y_dir).normalized()
	return Basis(x_axis, y_dir, z_axis)


static func mirrored(snapshot: PackedVector3Array) -> PackedVector3Array:
	var flipped := PackedVector3Array()
	flipped.resize(snapshot.size())
	for i in snapshot.size():
		var p := snapshot[i]
		flipped[i] = Vector3(-p.x, p.y, p.z)
	return flipped

## Constants and the bind-skeleton reader, shared by everything that
## synthesizes hand joints (the desktop simulator and the remote actuator).
## The asset's own bind pose IS the open hand, so poses built from it are
## skin-perfect by construction rather than by tuning.
const HAND_MODEL_PATHS := [
	"res://addons/godot_xr_hands/models/generic_hand/left.glb",
	"res://addons/godot_xr_hands/models/generic_hand/right.glb",
]
## Godot re-bases hand-tracker joint orientations into its Humanoid
## convention; joints published from asset-frame poses carry this to land
## in that convention.
const GODOT_HAND_REBASE := Basis(Vector3(-1, 0, 0), Vector3(0, 0, -1), Vector3(0, -1, 0))



## Maps the standard WebXR joint bone names onto XRHandTracker joint ids.
static func joint_name_map() -> Dictionary:
	var map := {"wrist": XRHandTracker.HAND_JOINT_WRIST}
	var segments := {
		"thumb": ["metacarpal", "phalanx-proximal", "phalanx-distal", "tip"],
		"index-finger": ["metacarpal", "phalanx-proximal", "phalanx-intermediate", "phalanx-distal", "tip"],
		"middle-finger": ["metacarpal", "phalanx-proximal", "phalanx-intermediate", "phalanx-distal", "tip"],
		"ring-finger": ["metacarpal", "phalanx-proximal", "phalanx-intermediate", "phalanx-distal", "tip"],
		"pinky-finger": ["metacarpal", "phalanx-proximal", "phalanx-intermediate", "phalanx-distal", "tip"],
	}
	var chain_index := 0
	for finger in segments:
		var chain: Array = FINGER_CHAINS[chain_index]
		for i in (segments[finger] as Array).size():
			map["%s-%s" % [finger, segments[finger][i]]] = chain[i]
		chain_index += 1
	return map


## Same-axis FK: real knuckle hinges are parallel, so each finger's bends all
## rotate around its bind hinge axis with accumulating angle - positions AND
## authored orientations rotate together (the skin stays coherent).
## Shared pose math (godot_xr_hands). Loaded at runtime so the simulator still
## works controller-only when godot_xr_hands is absent.
var _pose_math_cache: Object

## Reads both hand models' bind skeletons. Returns {} when the hands addon
## (or its models) is absent - callers treat that as "no synthetic hands".
static func load_bind_skeletons() -> Dictionary:
	var bind := {}
	for hand in 2:
		var path: String = HAND_MODEL_PATHS[hand]
		if not ResourceLoader.exists(path):
			return {}
		var model := (load(path) as PackedScene).instantiate()
		var skeletons := model.find_children("*", "Skeleton3D", true, false)
		var meshes := model.find_children("*", "MeshInstance3D", true, false)
		if skeletons.is_empty() or meshes.is_empty():
			model.free()
			return {}
		var skeleton := skeletons[0] as Skeleton3D
		var skin: Skin = (meshes[0] as MeshInstance3D).skin
		var joint_by_bone := joint_name_map()
		var wrist_rest := Vector3.ZERO
		for bone in skeleton.get_bone_count():
			if skeleton.get_bone_name(bone) == "wrist":
				wrist_rest = skeleton.get_bone_rest(bone).origin
		# Skin stores one transform per bind; whether it is the bind or its
		# inverse differs by importer path - the wrist vote picks the reading
		# whose origin matches the bone rest (the glb node translation), then
		# all binds are read with the winning interpretation.
		var bind_world := {}
		var wrist_bind := Transform3D.IDENTITY
		var use_inverse := true
		for b in skin.get_bind_count():
			var bone := skin.get_bind_bone(b)
			if bone < 0:
				bone = skeleton.find_bone(skin.get_bind_name(b))
			if skeleton.get_bone_name(bone) == "wrist":
				var sb := skin.get_bind_pose(b)
				use_inverse = sb.affine_inverse().origin.distance_to(wrist_rest) <= sb.origin.distance_to(wrist_rest)
				wrist_bind = sb.affine_inverse() if use_inverse else sb
		for b in skin.get_bind_count():
			var bone := skin.get_bind_bone(b)
			if bone < 0:
				bone = skeleton.find_bone(skin.get_bind_name(b))
			var joint: int = joint_by_bone.get(skeleton.get_bone_name(bone), -1)
			if joint < 0:
				continue
			var sb := skin.get_bind_pose(b)
			bind_world[joint] = sb.affine_inverse() if use_inverse else sb
		model.free()
		if bind_world.size() < 25:
			return {}

		var to_wrist := wrist_bind.affine_inverse()
		var rel := []
		rel.resize(XRHandTracker.HAND_JOINT_MAX)
		for joint in XRHandTracker.HAND_JOINT_MAX:
			rel[joint] = to_wrist * bind_world[joint] if bind_world.has(joint) else Transform3D.IDENTITY
		var middle_origin: Vector3 = (rel[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL] as Transform3D).origin
		# OpenXR's real XR_HAND_JOINT_PALM_EXT sits at the CENTER of the middle
		# metacarpal BONE - the midpoint between that metacarpal's own joint and
		# the middle finger's proximal phalanx joint (Meta's OpenXR SDK computes
		# it the same way when a runtime has no native palm joint). A
		# wrist<->metacarpal midpoint reads too close to the wrist - that
		# convention was retired from the live grip anchor 2026-07-24 for
		# exactly that reason (xr_controller_hand_adapter.gd); fabricate the
		# simulator's fake PALM the correct way so it matches a real one.
		var middle_proximal_origin: Vector3 = (rel[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL] as Transform3D).origin
		rel[XRHandTracker.HAND_JOINT_PALM] = Transform3D(Basis.IDENTITY, (middle_origin + middle_proximal_origin) * 0.5)

		# Hand axes measured FROM the bind (no convention guessing): finger
		# direction, chirality-corrected palm normal (the thumb metacarpal
		# sits palm-side of the finger plane), per-finger curl hinge axes.
		var fingers_dir := middle_origin.normalized()
		var index_origin: Vector3 = (rel[XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL] as Transform3D).origin
		var pinky_origin: Vector3 = (rel[XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL] as Transform3D).origin
		var thumb_origin: Vector3 = (rel[XRHandTracker.HAND_JOINT_THUMB_METACARPAL] as Transform3D).origin
		# Sign: the thumb metacarpal sits toward the BACK-of-hand side of the
		# finger plane in this asset's bind (David-calibrated: the first guess
		# put palms up and curls backward - both symptoms of this one sign).
		var normal := index_origin.cross(pinky_origin).normalized()
		if normal.dot(thumb_origin - (index_origin + pinky_origin) * 0.5) > 0.0:
			normal = -normal
		# Per-finger curl hinge axes come from the shared pose math (same result).
		var curl_axes: Array = measure_curl_axes(rel)

		# View alignment measured from the same axes: fingers -> view forward
		# (-Z), palm -> view down (-Y).
		var z_local := (-fingers_dir).normalized()
		var y_local := (-(normal - z_local * normal.dot(z_local))).normalized()
		var local_frame := Basis(y_local.cross(z_local), y_local, z_local)
		var target_frame := Basis(Vector3(-1, 0, 0), Vector3(0, -1, 0), Vector3(0, 0, 1))
		# Recorded Gesture Studio snapshots use fingers +Y / palm +Z wrist-
		# local; this maps them into the bind wrist frame.
		var rec_x := fingers_dir.cross(normal).normalized()
		bind[hand] = {
			"rel": rel,
			"curl_axes": curl_axes,
			"align": target_frame * local_frame.transposed(),
			"rec_convert": Basis(rec_x, fingers_dir, rec_x.cross(fingers_dir)),
		}
	return bind


## MICROGESTURES are motions, not poses: the thumb travels along the side of
## the index finger while touching it, and the recognizer reads that path
## over time (contact distance, then direction). Snapping to a "swipe pose"
## produces nothing, because there is no such pose - which is why this
## returns a thumb-tip OFFSET for a moment in the motion rather than a hand.
##
## kind: "tap", "swipe_forward", "swipe_backward", "swipe_left", "swipe_right"
## progress: 0..1 through the motion.
## Returns the offset to add to the thumb tip, in the same wrist-local space
## the bind pose uses. Both the desktop simulator (keyboard-driven) and the
## remote actuator (script-driven) play the same path through here.
static func microgesture_offset(bind: Array, kind: String, progress: float) -> Vector3:
	if bind.size() <= HAND_JOINT_REF_INDEX_TIP:
		return Vector3.ZERO
	var t := clampf(progress, 0.0, 1.0)
	var index_base: Vector3 = (bind[XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL] as Transform3D).origin
	var index_tip: Vector3 = (bind[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP] as Transform3D).origin
	var thumb_tip: Vector3 = (bind[XRHandTracker.HAND_JOINT_THUMB_TIP] as Transform3D).origin
	var along := (index_tip - index_base)
	var length := along.length()
	if length < 0.0001:
		return Vector3.ZERO
	along /= length
	# Across the finger, in the plane of the hand: the axis a left/right
	# swipe travels, and the one a tap approaches along.
	var palm_normal := (index_base - (bind[XRHandTracker.HAND_JOINT_WRIST] as Transform3D).origin).cross(along).normalized()
	var across := along.cross(palm_normal).normalized()

	# Contact rides just off the surface; the recognizer's threshold is a
	# fraction of palm width, so this stays comfortably inside it.
	var contact := 0.004
	match kind:
		"tap":
			# In and out: touch the middle of the finger and release, which
			# is a contact pulse with no travel.
			var press := sin(t * PI)
			return (index_base + along * (length * 0.5)) - thumb_tip + across * (contact + 0.012 * (1.0 - press))
		"swipe_forward", "swipe_backward":
			# Travel from base to tip (or back) while touching.
			var u: float = t if kind == "swipe_forward" else 1.0 - t
			var slide: float = length * lerpf(0.25, 0.85, u)
			return (index_base + along * slide) - thumb_tip + across * contact
		"swipe_left", "swipe_right":
			# Travel ACROSS the finger at mid-length.
			var v: float = t if kind == "swipe_right" else 1.0 - t
			var lateral: float = lerpf(-0.018, 0.018, v)
			return (index_base + along * (length * 0.5) + palm_normal * lateral) - thumb_tip + across * contact
		_:
			return Vector3.ZERO


## The gesture posture a microgesture is performed FROM: a relaxed hand with
## the thumb free, which is what the recognizer's posture gate expects.
const MICROGESTURE_CURLS := {"thumb": 0.15, "index": 0.35, "middle": 0.6, "ring": 0.65, "pinky": 0.65}
const HAND_JOINT_REF_INDEX_TIP := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
