@icon("res://addons/godot_webxr_kit/icons/openxr_input_adapter.svg")
class_name XRSimulator
extends Node

## Desktop XR simulator: test grab, teleport, poke, and UI flat - no headset.
##
## Registers FAKE controller trackers into XRServer (only when the platform
## has none) and drives them from mouse + keyboard, so every input path in
## the suite lights up unmodified - the rig's XRController3D nodes, the input
## adapters, locomotion's thumbstick read, poke's controller tip, modality.
## The rig's FlatscreenCamera keeps head movement (WASD + drag-look).
##
## Bindings while flat (H shows them on screen):
##   Right Mouse (hold) . trigger/select on the RIGHT hand (grab, click UI)
##   F (hold) ........... grab/activate button on the RIGHT hand
##   T (hold, release) .. push right thumbstick forward = teleport aim; release commits
##   Z / C .............. snap turn left / right
##   Mouse cursor ....... aims the right controller ray
##   X .................. switch to SIMULATED HANDS (Unity XR Device
##                        Simulator-style): fake XRHandTracker joints from the
##                        gesture presets (soft-loaded from godot_xr_hands).
##                        RMB then morphs a real PINCH (thumb+index together),
##                        driving the adapter's actual synthetic pinch select -
##                        authors see exactly how hand grabs behave. F = fist.
##
## Auto-inert the moment a real XR session starts (and restores everything),
## so it is SAFE TO LEAVE IN SHIPPED SCENES - on a headset it does nothing.
## Drop anywhere; it finds the rig itself.

enum SimMode { CONTROLLER, HAND }

## How far the cursor ray probes for something to aim at, and the fallback
## distance when it finds nothing.
const _MOUSE_FALLBACK_DISTANCE := 20.0

const _HAND_TRACKER_NAMES := [&"/user/hand_tracker/left", &"/user/hand_tracker/right"]
const _POSE_PATHS := {
	"open": "res://addons/godot_xr_hands/runtime/gesture_studio/presets/open_palm.tres",
	"fist": "res://addons/godot_xr_hands/runtime/gesture_studio/presets/fist.tres",
}
const _JOINT_FLAGS: int = XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID \
		| XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED \
		| XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID \
		| XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_TRACKED

## The engine rebases hand-joint orientations into its Humanoid convention by
## right-multiplying this matrix (see xr_hand_mesh_visualizer._UNADJUST, the
## same self-inverse rotation) - the simulator applies it too, so simulated
## trackers serve exactly what real platforms serve.
const _GODOT_HAND_REBASE := Basis(Vector3(-1, 0, 0), Vector3(0, 0, -1), Vector3(0, -1, 0))
const _HAND_MODEL_PATHS := [
	"res://addons/godot_xr_hands/models/generic_hand/left.glb",
	"res://addons/godot_xr_hands/models/generic_hand/right.glb",
]
const _FINGER_NAMES := ["thumb", "index", "middle", "ring", "pinky"]

## Master switch (runtime): off = never activates.
@export var enabled := true
## Show the on-screen hotkey help while simulating (H toggles it live).
@export var show_help := true
## How far in front of the camera the simulated controllers sit.
@export var controller_distance := 0.35
## Snap-turn key pulse length (locomotion edge-detects the stick).
@export var snap_pulse_seconds := 0.2

var _origin: XROrigin3D
var _camera: Camera3D
var _openxr_adapter: Node
var _webxr_adapter: Node
var _trackers := {}          # hand -> XRControllerTracker we drive (borrowed or created)
var _created_trackers := {}  # hand -> true if WE registered it (so we remove only ours)
var _repointed: Array = []   # interactors we switched to the OpenXR adapter
var _screen_rays: Array = [] # ScreenRayInteractors we suspended
var _active := false
var _select_down := false
var _grab_down := false
var _snap_pulse := 0.0
var _snap_direction := 0.0
var _help_layer: CanvasLayer
var _help_grid: GridContainer
var _help_footer: Label
var _help_key_down := false
var _mode := SimMode.CONTROLLER
var _mode_key_down := false
var _hand_trackers := {}      # hand -> XRHandTracker WE registered
var _poses := {}              # "open"/"fist" -> per-hand Arrays of wrist-local Transform3D
var _bind := {}               # hand -> {rel, curl_axes, align, rec_convert} from the asset glb
var _pose_library: Array = [] # [{name, per_hand}] - open + presets + user recordings
var _active_pose := 0         # library index applied to the RIGHT hand (0 = open)
var _pose_key_down := -1
var _current_pose: Array = [PackedVector3Array(), PackedVector3Array()]
var _hand_visual: Node3D
var _openxr_was_processing := true


func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return
	# Desktop/native flat testing only. On the web the browser runs its own
	# flat-landing -> Enter-VR flow, and faking trackers there would collide with
	# WebXR's real ones when you enter a session - so stay out of the browser
	# entirely (and out of any real XR session; that's gated on use_xr below).
	if OS.has_feature("web"):
		set_process(false)
		return
	_resolve_rig.call_deferred()


func _resolve_rig() -> void:
	var scene := get_tree().current_scene if get_tree() else null
	var search_root: Node = scene if scene else get_tree().root
	var origins := search_root.find_children("*", "XROrigin3D", true, false)
	_origin = origins[0] as XROrigin3D if not origins.is_empty() else null
	if _origin == null:
		push_warning("XRSimulator: no XROrigin3D found - drop an XR Prefab/Rig first.")
		set_process(false)
		return
	var cameras := _origin.find_children("*", "XRCamera3D", true, false)
	_camera = cameras[0] as Camera3D if not cameras.is_empty() else null
	var rig := _origin.get_parent()
	if rig:
		_openxr_adapter = rig.get_node_or_null("OpenXRInputAdapter")
		_webxr_adapter = rig.get_node_or_null("WebXRInputAdapter")


func _process(delta: float) -> void:
	if _origin == null:
		return
	var in_xr := get_viewport().use_xr
	if _active and (in_xr or not enabled):
		_deactivate()
	elif not _active and not in_xr and enabled:
		_activate()
	if not _active:
		return

	if _mode == SimMode.CONTROLLER:
		_update_poses()
		_update_inputs(delta)
	else:
		_update_hand_poses(delta)
	_update_common_keys()


## ---- activation ---------------------------------------------------------------

func _activate() -> void:
	_add_controller_trackers()
	if _trackers.is_empty():
		return  # a real platform owns the controllers - stay passive
	_mode = SimMode.CONTROLLER
	_load_hand_poses()

	# On the web flat page the interactors point at the WebXR adapter, which
	# only emits selects inside a browser session - route them to the OpenXR
	# adapter, which listens to controller button signals (our fake inputs)
	# and runs the shared synthetic-pinch detector for simulated hands. The
	# adapter may have disabled its processing off-platform - re-enable it
	# for the simulation and restore on deactivate.
	if _openxr_adapter:
		_openxr_was_processing = _openxr_adapter.is_processing()
		_openxr_adapter.set_process(true)
		for interactor in _find_adapter_interactors(_origin.get_parent()):
			interactor.set_input_adapter(_openxr_adapter)
			_repointed.append(interactor)

	# The mouse ScreenRayInteractor duplicates our simulated ray - suspend it.
	for node in _find_screen_rays(_origin.get_parent()):
		node.process_mode = Node.PROCESS_MODE_DISABLED
		_screen_rays.append(node)

	_active = true
	if _help_layer == null:
		_build_help_overlay()
	_help_layer.visible = show_help
	print("XRSimulator: flat-testing active (RMB=trigger, F=grab, T=teleport, Z/C=snap turn, H=help).")


func _deactivate() -> void:
	_remove_controller_trackers()
	_remove_hand_trackers()
	_mode = SimMode.CONTROLLER
	if _openxr_adapter:
		_openxr_adapter.set_process(_openxr_was_processing)
	if _webxr_adapter:
		for interactor in _repointed:
			if is_instance_valid(interactor):
				interactor.set_input_adapter(_webxr_adapter)
	_repointed.clear()
	for node in _screen_rays:
		if is_instance_valid(node):
			node.process_mode = Node.PROCESS_MODE_INHERIT
	_screen_rays.clear()
	_select_down = false
	_grab_down = false
	_active = false
	if _help_layer:
		_help_layer.visible = false


func _find_adapter_interactors(root: Node) -> Array:
	var out: Array = []
	if root == null:
		return out
	for child in root.get_children():
		if child.has_method("set_input_adapter"):
			var path: Variant = child.get("input_adapter_path")
			if path is NodePath and not (path as NodePath).is_empty():
				out.append(child)
		out.append_array(_find_adapter_interactors(child))
	return out


func _find_screen_rays(root: Node) -> Array:
	var out: Array = []
	if root == null:
		return out
	for child in root.get_children():
		var script: Script = child.get_script()
		if script and script.resource_path.contains("xr_screen_ray_interactor"):
			out.append(child)
		out.append_array(_find_screen_rays(child))
	return out


## ---- per-frame simulation ------------------------------------------------------

func _update_poses() -> void:
	if _camera == null:
		return
	var to_origin := _origin.global_transform.affine_inverse()
	var cam := _camera.global_transform

	# RIGHT controller: sits at the camera's lower right, aiming at the point
	# the mouse cursor is over - the ray interactor becomes mouse-driven.
	var right_pos := cam * Vector3(0.25, -0.2, -controller_distance)
	var target := _mouse_target(right_pos)
	var right_xf := Transform3D(_basis_looking(right_pos, target), right_pos)
	_set_hand_pose(1, to_origin * right_xf)

	# LEFT controller: passive companion at the lower left, aiming forward.
	var left_pos := cam * Vector3(-0.25, -0.2, -controller_distance)
	var left_xf := Transform3D(cam.basis, left_pos)
	_set_hand_pose(0, to_origin * left_xf)


## The point the CURSOR is actually over, so the simulated ray lands where the
## mouse points at ANY depth.
##
## This used to aim at a fixed 5 m along the camera ray. The controller sits
## ~0.25 m to the side of the camera, so a fixed-depth target lines up only at
## that exact depth and parallaxes everywhere else -- badly on near UI panels,
## which is exactly where flat testing happens. Aiming at the real hit point
## makes the two rays agree at every distance.
##
## `from_position` is the controller origin: the query deliberately runs from
## the CAMERA (what the user is pointing with) and the controller then aims at
## the result, which is what keeps cursor and reticle together.
func _mouse_target(from_position: Vector3) -> Vector3:
	var mouse := get_viewport().get_mouse_position()
	var ray_origin := _camera.project_ray_origin(mouse)
	var ray_direction := _camera.project_ray_normal(mouse)
	var fallback := ray_origin + ray_direction * _MOUSE_FALLBACK_DISTANCE
	var world := _camera.get_world_3d()
	if world == null:
		return fallback
	var query := PhysicsRayQueryParameters3D.create(ray_origin, fallback)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var hit := world.direct_space_state.intersect_ray(query)
	if hit.has("position"):
		return hit["position"]
	# Nothing under the cursor: keep the ray parallel to the camera ray so it
	# still points where the user is looking, just without a convergence point.
	return fallback


func _basis_looking(from_position: Vector3, at: Vector3) -> Basis:
	var forward := (at - from_position).normalized()
	if forward.length_squared() < 0.000001:
		return _camera.global_transform.basis
	var up := Vector3.UP if absf(forward.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	return Basis.looking_at(forward, up)


func _set_hand_pose(hand: int, pose: Transform3D) -> void:
	var tracker: XRControllerTracker = _trackers.get(hand)
	if tracker == null:
		return
	for pose_name in [&"aim", &"grip", &"default"]:
		tracker.set_pose(pose_name, pose, Vector3.ZERO, Vector3.ZERO,
				XRPose.XR_TRACKING_CONFIDENCE_HIGH)


func _update_inputs(delta: float) -> void:
	var right: XRControllerTracker = _trackers.get(1)
	if right == null:
		return

	var select_now := Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	if select_now != _select_down:
		_select_down = select_now
		right.set_input(&"select", select_now)

	var grab_now := Input.is_physical_key_pressed(KEY_F)
	if grab_now != _grab_down:
		_grab_down = grab_now
		right.set_input(&"grab", grab_now)

	# Thumbstick: T holds forward (teleport aim; releasing commits), Z/C pulse
	# sideways (snap turn - locomotion edge-detects the deflection).
	var stick := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_T):
		stick.y = 1.0
	if _snap_pulse > 0.0:
		_snap_pulse -= delta
		stick.x = _snap_direction
	elif Input.is_physical_key_pressed(KEY_Z):
		_snap_pulse = snap_pulse_seconds
		_snap_direction = -1.0
	elif Input.is_physical_key_pressed(KEY_C):
		_snap_pulse = snap_pulse_seconds
		_snap_direction = 1.0
	right.set_input(&"thumbstick", stick)


func _update_common_keys() -> void:
	var help_key := Input.is_physical_key_pressed(KEY_H)
	if help_key and not _help_key_down:
		show_help = not show_help
		if _help_layer:
			_help_layer.visible = show_help
	_help_key_down = help_key

	var mode_key := Input.is_physical_key_pressed(KEY_X)
	if mode_key and not _mode_key_down and _hands_available():
		_set_mode(SimMode.HAND if _mode == SimMode.CONTROLLER else SimMode.CONTROLLER)
	_mode_key_down = mode_key

	# Number keys apply library gesture poses to the right hand (hand mode).
	if _mode == SimMode.HAND:
		var pressed := -1
		for i in range(0, mini(_pose_library.size(), 10)):
			if Input.is_physical_key_pressed(KEY_0 + i):
				pressed = i
				break
		if pressed >= 0 and pressed != _pose_key_down:
			_active_pose = 0 if pressed == _active_pose else pressed
			_update_help_text()
			print("XRSimulator: right hand pose -> %s" % _pose_library[_active_pose]["name"])
		_pose_key_down = pressed


## ---- simulated hands -----------------------------------------------------------

func _hands_available() -> bool:
	return _poses.has("open") and _poses.has("fist")


## Gesture presets carry a wrist-local joint SNAPSHOT (PackedVector3Array
## indexed by XRHandTracker joint, recorded_hand = native chirality; the other
## hand is a wrist-local x-flip - same convention as the gesture ghost hand).
## Soft-loaded so the kit never hard-depends on godot_xr_hands.
const _HAND_MESH_PATH := "res://addons/godot_xr_hands/runtime/xr_hand_mesh_visualizer.gd"

## Finger chains (XRHandTracker joint ids) for deriving per-joint
## orientations from the position snapshot: each joint aims +Y at its
## successor (Godot's Humanoid hand convention - the engine maps OpenXR
## Z+ back-along-bone to Godot Y-), so the realistic hand mesh skins
## simulated poses with proper curl instead of uniform-orientation smear.
const _FINGER_CHAINS := [
	[XRHandTracker.HAND_JOINT_THUMB_METACARPAL, XRHandTracker.HAND_JOINT_THUMB_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_THUMB_TIP],
	[XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP],
	[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP],
	[XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_RING_FINGER_TIP],
	[XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP],
]

## Poses are wrist-local Transform3D arrays built by FK-BENDING THE ASSET'S
## OWN BIND SKELETON (authored joint frames read from the glb's Skin). David's
## on-device check proved the mesh+driver correct with real tracking; the
## earlier synthesized skeleton had foreign proportions, so the skin stretched
## (banana thumb, twisted wrist). With the bind as the base, zero curl renders
## EXACTLY the authored hand, and curls rotate the authored frames.
func _load_hand_poses() -> void:
	if not _poses.is_empty():
		return
	if not _load_bind_skeletons():
		return  # hands addon absent - controller mode only
	for key in _POSE_PATHS:
		var path: String = _POSE_PATHS[key]
		if not ResourceLoader.exists(path):
			_poses.clear()
			return
		_poses[key] = _pose_from_preset(load(path))
	if _hands_available():
		_build_pose_library()
	else:
		_poses.clear()


func _load_bind_skeletons() -> bool:
	for hand in 2:
		var path: String = _HAND_MODEL_PATHS[hand]
		if not ResourceLoader.exists(path):
			return false
		var model := (load(path) as PackedScene).instantiate()
		var skeletons := model.find_children("*", "Skeleton3D", true, false)
		var meshes := model.find_children("*", "MeshInstance3D", true, false)
		if skeletons.is_empty() or meshes.is_empty():
			model.free()
			return false
		var skeleton := skeletons[0] as Skeleton3D
		var skin: Skin = (meshes[0] as MeshInstance3D).skin
		var joint_by_bone := _joint_name_map()
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
			return false

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
		var curl_axes: Array = _pose_math().measure_curl_axes(rel)

		# View alignment measured from the same axes: fingers -> view forward
		# (-Z), palm -> view down (-Y).
		var z_local := (-fingers_dir).normalized()
		var y_local := (-(normal - z_local * normal.dot(z_local))).normalized()
		var local_frame := Basis(y_local.cross(z_local), y_local, z_local)
		var target_frame := Basis(Vector3(-1, 0, 0), Vector3(0, -1, 0), Vector3(0, 0, 1))
		# Recorded Gesture Studio snapshots use fingers +Y / palm +Z wrist-
		# local; this maps them into the bind wrist frame.
		var rec_x := fingers_dir.cross(normal).normalized()
		_bind[hand] = {
			"rel": rel,
			"curl_axes": curl_axes,
			"align": target_frame * local_frame.transposed(),
			"rec_convert": Basis(rec_x, fingers_dir, rec_x.cross(fingers_dir)),
		}
	return true


func _joint_name_map() -> Dictionary:
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
		var chain: Array = _FINGER_CHAINS[chain_index]
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

func _pose_math() -> Object:
	if _pose_math_cache == null:
		var path := "res://addons/godot_xr_hands/runtime/xr_hand_pose_math.gd"
		if ResourceLoader.exists(path):
			_pose_math_cache = load(path)
	return _pose_math_cache


func _fk_pose(hand: int, curls: Dictionary) -> Array:
	return _pose_math().fk_pose(_bind[hand]["rel"], _bind[hand]["curl_axes"], curls)


func _pose_from_preset(preset: Resource) -> Array:
	var per_hand := [null, null]
	var snapshot: PackedVector3Array = preset.get("joint_snapshot") if preset.get("joint_snapshot") is PackedVector3Array else PackedVector3Array()
	if snapshot.size() >= XRHandTracker.HAND_JOINT_MAX:
		var recorded: Variant = preset.get("recorded_hand")
		var native_hand: int = recorded if recorded is int and recorded >= 0 else 1
		for hand in 2:
			var positions := snapshot if hand == native_hand else _mirrored(snapshot)
			per_hand[hand] = _rel_from_recorded(hand, positions)
	else:
		var curls := {}
		var conditions: Variant = preset.get("conditions")
		if conditions is Dictionary:
			for f in _FINGER_NAMES:
				var key := "curl_%s" % f
				if (conditions as Dictionary).has(key):
					curls[f] = ((conditions as Dictionary)[key] as Vector2).x
		for hand in 2:
			per_hand[hand] = _fk_pose(hand, curls)
	return per_hand


## Recorded snapshots are POSITIONS only, in the recorder's wrist frame; the
## bind skeleton lives in its own wrist frame. Every failed attempt guessed a
## fixed conversion (rec_convert) with a free chirality sign that kept
## flipping. Deterministic fix: measure BOTH wrist frames the SAME way (same
## thumb-side normal correction) and align them - identical measurement leaves
## no sign to guess. The reframed positions then run through the exact FK
## downstream (orientations derived in bind space), so recorded and synthesized
## poses render in one consistent convention.
func _rel_from_recorded(hand: int, positions: PackedVector3Array) -> Array:
	return _pose_math().rel_from_recorded(_bind[hand]["rel"], positions)


## The Unity-style editor gesture bench: number keys apply ANY authored
## gesture to the simulated right hand - the shipped presets plus your own
## Gesture Studio recordings (user://gestures) - so the scene's REAL
## recognizers react while you test flat. Slot 0 = open palm; capped at 9.
func _build_pose_library() -> void:
	_pose_library = [{"name": "open palm", "per_hand": [_fk_pose(0, {}), _fk_pose(1, {})]}]
	var sources: Array = []
	var preset_dir := DirAccess.open(_POSE_PATHS["open"].get_base_dir())
	if preset_dir:
		for file in preset_dir.get_files():
			if file.ends_with(".tres") and file != "open_palm.tres":
				sources.append(_POSE_PATHS["open"].get_base_dir().path_join(file))
	var user_dir := DirAccess.open("user://gestures")
	if user_dir:
		for file in user_dir.get_files():
			if file.ends_with(".tres"):
				sources.append("user://gestures".path_join(file))
	for path in sources:
		if _pose_library.size() > 9:
			break
		var preset: Resource = load(path)
		if preset == null or preset.get("stages") != null:
			continue  # sequences (motion gestures) have no static pose
		if not (preset.get("joint_snapshot") is PackedVector3Array) and not (preset.get("conditions") is Dictionary):
			continue
		var pose_name: String = preset.get("gesture_name") if preset.get("gesture_name") else str(path.get_file().get_basename()).replace("_", " ")
		_pose_library.append({"name": pose_name, "per_hand": _pose_from_preset(preset)})


func _mirrored(snapshot: PackedVector3Array) -> PackedVector3Array:
	return _pose_math().mirrored(snapshot)


func _set_mode(mode: SimMode) -> void:
	if mode == _mode:
		return
	if mode == SimMode.HAND and not _hands_available():
		return  # godot_xr_hands absent - controller simulation only
	_mode = mode
	if _mode == SimMode.HAND:
		_active_pose = 0
		# Rescan the pose library on every hand-mode entry so gestures saved
		# DURING this run (a fresh Studio recording, a deleted file) appear on
		# the number keys immediately - the list is disk-driven, never fixed.
		if _hands_available():
			_build_pose_library()
		_remove_controller_trackers()
		_add_hand_trackers()
	else:
		_remove_hand_trackers()
		_add_controller_trackers()
	_update_help_text()
	print("XRSimulator: %s mode." % ("simulated HANDS (RMB=pinch, F=fist)" if _mode == SimMode.HAND else "simulated CONTROLLERS"))


func _add_controller_trackers() -> void:
	# We only reach here when flat (use_xr == false) with no headset presenting,
	# so any existing left/right_hand tracker is an IDLE platform one (e.g.
	# SteamVR running with the headset off) that isn't driving a session - borrow
	# and drive it rather than skipping (which used to leave the sim inert). If
	# none exists, create our own. We remove only the ones we created.
	for hand in 2:
		var tracker_name := &"left_hand" if hand == 0 else &"right_hand"
		var tracker := XRServer.get_tracker(tracker_name) as XRControllerTracker
		if tracker == null:
			tracker = XRControllerTracker.new()
			tracker.name = tracker_name
			XRServer.add_tracker(tracker)
			_created_trackers[hand] = true
		_trackers[hand] = tracker


func _remove_controller_trackers() -> void:
	# Only remove trackers WE created; leave borrowed platform ones in place so a
	# real session that follows still has them.
	for hand in _trackers:
		if _created_trackers.get(hand, false):
			XRServer.remove_tracker(_trackers[hand])
	_trackers.clear()
	_created_trackers.clear()
	_select_down = false
	_grab_down = false


func _add_hand_trackers() -> void:
	for hand in 2:
		if XRServer.get_tracker(_HAND_TRACKER_NAMES[hand]) != null:
			continue
		var tracker := XRHandTracker.new()
		tracker.name = _HAND_TRACKER_NAMES[hand]
		tracker.hand = XRPositionalTracker.TRACKER_HAND_LEFT if hand == 0 else XRPositionalTracker.TRACKER_HAND_RIGHT
		# UNOBSTRUCTED = real hand tracking: keeps the adapter's synthetic
		# pinch select armed (it ignores controller-emulated joints).
		tracker.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
		XRServer.add_tracker(tracker)
		_hand_trackers[hand] = tracker
		_current_pose[hand] = (_poses["open"][hand] as Array).duplicate()
	# The procedural hand visualizer is XR-session-gated (hard-hides flat),
	# so the simulator shows the REALISTIC hand mesh - the same visual real
	# scenes use - driven by these fake trackers. Soft-loaded; without the
	# hands addon the simulated hands are input-only.
	if _hand_visual == null and _origin and ResourceLoader.exists(_HAND_MESH_PATH):
		_hand_visual = (load(_HAND_MESH_PATH) as GDScript).new()
		_hand_visual.name = "SimulatedHandMesh"
		_origin.add_child(_hand_visual)


func _remove_hand_trackers() -> void:
	for hand in _hand_trackers:
		XRServer.remove_tracker(_hand_trackers[hand])
	_hand_trackers.clear()
	if _hand_visual:
		_hand_visual.queue_free()
		_hand_visual = null


func _update_hand_poses(delta: float) -> void:
	if _camera == null:
		return
	var to_origin := _origin.global_transform.affine_inverse()
	var cam := _camera.global_transform
	var blend := clampf(delta * 12.0, 0.0, 1.0)
	for hand in 2:
		var tracker: XRHandTracker = _hand_trackers.get(hand)
		if tracker == null:
			continue
		# Pose target: the library pose selected by number key (0 = open palm);
		# F momentarily overrides the RIGHT hand with a fist.
		var target: Array
		if hand == 1 and Input.is_physical_key_pressed(KEY_F):
			target = _poses["fist"][hand]
		elif hand == 1 and _active_pose > 0 and _active_pose < _pose_library.size():
			target = _pose_library[_active_pose]["per_hand"][hand]
		else:
			target = _poses["open"][hand]
		var current: Array = _current_pose[hand]
		for i in current.size():
			var from: Transform3D = current[i]
			var to: Transform3D = target[i]
			current[i] = Transform3D(
					Basis(from.basis.get_rotation_quaternion().slerp(to.basis.get_rotation_quaternion(), blend)),
					from.origin.lerp(to.origin, blend))

		# Pinch morph (positions only): thumb+index tips meet -> the ADAPTER's
		# real synthetic-pinch detector fires select, exactly like on-device.
		var pinch_offsets := {}
		if hand == 1 and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			var thumb: Vector3 = (current[XRHandTracker.HAND_JOINT_THUMB_TIP] as Transform3D).origin
			var index: Vector3 = (current[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP] as Transform3D).origin
			var mid := (thumb + index) * 0.5
			pinch_offsets[XRHandTracker.HAND_JOINT_THUMB_TIP] = mid + (thumb - mid).normalized() * 0.008 - thumb
			pinch_offsets[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP] = mid + (index - mid).normalized() * 0.008 - index

		# Wrist anchor mirrors the controller placement; the right hand aims
		# at the mouse cursor so the hand ray is mouse-driven. The sub-mm sway
		# mimics real tracking jitter - without it the hand visualizer's
		# frozen-hand watchdog (built for Quest's stale-pose bug) classifies
		# bit-identical simulated joints as frozen and hides the hand. The
		# align basis was measured from the bind skeleton: fingers point along
		# the view forward, palm down.
		var sway_time := Time.get_ticks_msec() * 0.001
		var sway := Vector3(sin(sway_time * 1.3 + hand), sin(sway_time * 1.7), sin(sway_time * 2.1)) * 0.0006
		var anchor_pos := cam * Vector3(0.25 if hand == 1 else -0.25, -0.2, -controller_distance) + sway
		var view_basis := _basis_looking(anchor_pos, _mouse_target(anchor_pos)) if hand == 1 else cam.basis
		var anchor := to_origin * Transform3D(view_basis * (_bind[hand]["align"] as Basis), anchor_pos)
		for joint in current.size():
			var world: Transform3D = anchor * (current[joint] as Transform3D)
			if pinch_offsets.has(joint):
				world.origin += anchor.basis * (pinch_offsets[joint] as Vector3)
			tracker.set_hand_joint_transform(joint,
					Transform3D(world.basis * _GODOT_HAND_REBASE, world.origin))
			tracker.set_hand_joint_flags(joint, _JOINT_FLAGS)
		tracker.has_tracking_data = true




## Unity XR Device Simulator-style on-screen bindings help, so nobody has to
## remember the hotkeys. Built in code (no scene dep), bottom-left corner.
func _build_help_overlay() -> void:
	_help_layer = CanvasLayer.new()
	_help_layer.layer = 90
	add_child(_help_layer)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	panel.offset_left = 12.0
	panel.offset_bottom = -12.0
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.self_modulate = Color(1.0, 1.0, 1.0, 0.85)
	_help_layer.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 10)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	margin.add_child(column)

	var title := Label.new()
	title.text = "XR SIMULATOR"
	title.add_theme_font_size_override("font_size", 13)
	title.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	column.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "flat testing - no headset"
	subtitle.add_theme_font_size_override("font_size", 10)
	subtitle.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72))
	column.add_child(subtitle)

	_help_grid = GridContainer.new()
	_help_grid.columns = 2
	_help_grid.add_theme_constant_override("h_separation", 14)
	_help_grid.add_theme_constant_override("v_separation", 3)
	column.add_child(_help_grid)

	_help_footer = Label.new()
	_help_footer.add_theme_font_size_override("font_size", 12)
	_help_footer.add_theme_color_override("font_color", Color(0.45, 0.95, 0.55))
	column.add_child(_help_footer)
	_update_help_text()


func _update_help_text() -> void:
	if _help_grid == null:
		return
	for child in _help_grid.get_children():
		child.queue_free()
	var rows := [
		["W A S D · Q E", "move / fly"],
		["Left Mouse", "hold + drag to look"],
		["Mouse cursor", "aims the ray"],
	]
	if _mode == SimMode.CONTROLLER:
		rows += [
			["Right Mouse", "trigger — select / grab"],
			["F", "grab button"],
			["T", "hold to aim teleport, release to go"],
			["Z / C", "snap turn"],
		]
		if _hands_available():
			rows.append(["X", "switch to simulated hands"])
	else:
		rows += [
			["Right Mouse", "pinch — select / grab"],
			["F", "fist (hold)"],
			["X", "switch to controllers"],
		]
		for i in range(1, _pose_library.size()):
			rows.append([str(i), "pose: %s (again = open)" % _pose_library[i]["name"]])
	rows.append(["H", "hide this help"])
	for row in rows:
		var key := Label.new()
		key.text = row[0]
		key.add_theme_font_size_override("font_size", 12)
		key.add_theme_color_override("font_color", Color(0.55, 0.82, 1.0))
		key.custom_minimum_size = Vector2(104, 0)
		_help_grid.add_child(key)
		var action := Label.new()
		action.text = row[1]
		action.add_theme_font_size_override("font_size", 12)
		action.add_theme_color_override("font_color", Color(0.82, 0.86, 0.92))
		_help_grid.add_child(action)
	var holding := _mode == SimMode.HAND and _active_pose > 0 and _active_pose < _pose_library.size()
	_help_footer.visible = holding
	_help_footer.text = "holding: %s" % _pose_library[_active_pose]["name"] if holding else ""


func _exit_tree() -> void:
	if _active:
		_deactivate()
