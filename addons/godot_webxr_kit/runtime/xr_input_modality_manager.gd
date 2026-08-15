@tool
@icon("res://addons/godot_webxr_kit/icons/xr_input_modality_manager.svg")
class_name XRInputModalityManager
extends Node

## Per-hand input modality (Unity XRI's XRInputModalityManager, as a block):
## each hand independently switches between CONTROLLER and tracked HAND, with
## the matching visuals - controller models appear when you pick controllers
## up, hand meshes return when you set them down (the hand visualizer already
## self-hides per hand without tracking data; this block adds the controller
## side and the explicit signal).
##
## Controller models are PROFILE-MATCHED: the WebXR Input Profiles registry
## models bundled in controller_models/ (MIT) are picked by the profile ids
## the runtime reports (browser input-source profiles on WebXR, interaction
## profile paths on OpenXR), attached at the GRIP pose like the web's own
## controller-model factory. Unknown controllers fall back to the generic
## registry model, then to built-in stylized primitives. Bundled = imported =
## the materials bake for WebGPU exports like any scene asset.
##
## Built into WebXRRig, so every rig/prefab scene has it BY DEFAULT - turn it
## off with [member enabled], or pin a modality with [member forced_modality].

## A hand's modality changed. hand: 0 = left, 1 = right.
signal modality_changed(hand: int, modality: Modality)

enum Modality { NONE, CONTROLLER, HAND }
enum ForcedModality { AUTO, CONTROLLER, HAND }

const _MODEL_MATERIAL := preload("res://addons/godot_webxr_kit/runtime/controller_model_material.tres")
const _MODELS_DIR := "res://addons/godot_webxr_kit/controller_models"
const _GENERIC_PROFILE := "generic-trigger-squeeze-thumbstick"
## OpenXR interaction-profile paths -> registry profile ids (extend as needed).
const _OPENXR_PROFILE_MAP := {
	"/interaction_profiles/oculus/touch_controller": "oculus-touch-v3",
	"/interaction_profiles/meta/touch_controller_plus": "oculus-touch-v3",
	"/interaction_profiles/meta/touch_pro_controller": "oculus-touch-v3",
	"/interaction_profiles/khr/simple_controller": _GENERIC_PROFILE,
}
## A reading must hold this long before the modality switches (transitions
## flicker while the platform hands over between sources).
const _DEBOUNCE_SECONDS := 0.25

## Master switch. Off = no detection, no signals, controller models hidden
## (hand visuals then behave exactly as before this block existed).
@export var enabled := true:
	set(value):
		enabled = value
		if not enabled:
			_set_controller_visuals(0, false)
			_set_controller_visuals(1, false)

## AUTO follows the live trackers per hand. CONTROLLER / HAND pins BOTH hands
## to one modality (visuals only show when that source actually tracks).
@export var forced_modality: ForcedModality = ForcedModality.AUTO

## Show controller models while a hand is in CONTROLLER modality.
@export var show_controller_models := true

## Match the model to the reported controller profile. Off = always the
## built-in stylized primitives.
@export var use_profile_models := true

## Prefer real optical hand joints over a controller-like aim tracker when both
## are reported for one side. Quest can keep a stale Touch interaction profile
## bound while a bare hand points; without this, pointing swaps the hand mesh
## for a controller model. When the optical hand disappears, the live controller
## pose takes over normally. Turn off only for an intentionally simultaneous
## hands+controllers experience where physical controllers must always win.
@export var prefer_optically_tracked_hands := true

## Fetch device-specific models at runtime from the registry repository and
## cache them in user:// (downloads once per device). Off = only bundled
## models (the generic fallback ships in controller_models/).
@export var fetch_profile_models := true

## Where device models are fetched from - the WebXR Input Profiles assets
## layout (<url>/<profile-id>/<left|right>.glb). Point at your own copy of
## @webxr-input-profiles/assets/dist/profiles to self-host.
@export var model_repository_url := "https://cdn.jsdelivr.net/npm/@webxr-input-profiles/assets/dist/profiles"

## The rig's XRController3D nodes (aim pose), used for the primitive fallback
## models and to locate the XROrigin3D for grip attachment. OPTIONAL: empty
## paths self-resolve - drop the node anywhere in a scene with an XR rig.
@export var left_controller_path: NodePath
@export var right_controller_path: NodePath

const _RigResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_rig_resolver.gd")

var _modality := [Modality.NONE, Modality.NONE]
var _pending := [Modality.NONE, Modality.NONE]
var _pending_time := [0.0, 0.0]
var _fallback_models: Array[Node3D] = [null, null]
var _profile_models: Array[Node3D] = [null, null]
var _grip_nodes: Array[XRController3D] = [null, null]
var _resolved_profile := ["", ""]

## Discovery group other blocks use to find the manager (joined in _enter_tree
## so it is ready-order-proof - e.g. XRHandsMount hides a hand's virtual mesh
## while that hand holds a controller).
const GROUP := "xr_input_modality_manager"


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		add_to_group(GROUP)


func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return
	var controllers := [get_node_or_null(left_controller_path), get_node_or_null(right_controller_path)]
	for hand in 2:
		if controllers[hand] == null:
			controllers[hand] = _RigResolver.find_controller(self, hand)
	if show_controller_models:
		for hand in 2:
			_fallback_models[hand] = _build_fallback_model(controllers[hand])
			_grip_nodes[hand] = _build_grip_node(controllers[hand], hand)
	_install_webxr_profiles_hook()


## The hand's current modality (0 = left, 1 = right).
func get_modality(hand: int) -> Modality:
	return _modality[hand] if hand >= 0 and hand < 2 else Modality.NONE


## The registry profile id whose model this hand is showing ("" = fallback).
func get_resolved_profile(hand: int) -> String:
	return _resolved_profile[hand] if hand >= 0 and hand < 2 else ""


func _process(delta: float) -> void:
	if not enabled:
		return
	# Outside an XR session (flat page after exit) trackers can keep serving
	# stale "live" poses - force NONE so controller models never linger frozen
	# in the scene.
	var in_xr := get_viewport().use_xr
	for hand in 2:
		var detected := _detect(hand) if in_xr else Modality.NONE
		if detected == _modality[hand]:
			_pending[hand] = detected
			_pending_time[hand] = 0.0
			continue
		if detected != _pending[hand]:
			_pending[hand] = detected
			_pending_time[hand] = 0.0
			continue
		_pending_time[hand] += delta
		if _pending_time[hand] < _DEBOUNCE_SECONDS:
			continue
		_modality[hand] = detected
		if detected == Modality.CONTROLLER and _profile_models[hand] == null:
			_try_resolve_profile_model(hand)
		_set_controller_visuals(hand, detected == Modality.CONTROLLER)
		modality_changed.emit(hand, detected)


const _HAND_TRACKER_NAMES := [&"/user/hand_tracker/left", &"/user/hand_tracker/right"]

func _detect(hand: int) -> Modality:
	var hand_tracker := XRServer.get_tracker(_HAND_TRACKER_NAMES[hand]) as XRHandTracker
	var hand_live := hand_tracker != null and hand_tracker.has_tracking_data
	# Controller-driven "hands" (emulated joints from a held controller) count
	# as CONTROLLER modality, matching Unity's rule.
	if hand_live and hand_tracker.hand_tracking_source == XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER:
		hand_live = false

	var controller_live := false
	var controller_tracker := XRServer.get_tracker(&"left_hand" if hand == 0 else &"right_hand") as XRPositionalTracker
	if controller_tracker:
		var pose := controller_tracker.get_pose(&"aim")
		if pose == null:
			pose = controller_tracker.get_pose(&"default")
		controller_live = pose != null and pose.has_tracking_data

	match forced_modality:
		ForcedModality.CONTROLLER:
			return Modality.CONTROLLER if controller_live else Modality.NONE
		ForcedModality.HAND:
			return Modality.HAND if hand_live else Modality.NONE
		_:
			# A controller IDENTIFIED in this hand wins (Unity's rule). With
			# multimodal (simultaneous hands + controllers) the runtime serves
			# real hand joints OVER a held controller, so hand-presence alone
			# cannot discriminate. The tracker's bound interaction profile can:
			# a physical controller reads e.g. .../oculus/touch_controller
			# (OpenXR) or oculus-touch-v3 (WebXR, via the profiles hook), while
			# bare-hand sources read hand profiles or none. Trackers that are
			# live but carry no profile (plain WebXR without the hook) keep the
			# old hand-first behavior.
			return choose_auto_modality(
				hand_live,
				controller_live,
				controller_tracker.profile if controller_tracker else "",
				prefer_optically_tracked_hands
			)


## Pure arbitration helper kept separate so the runtime edge cases are unit
## tested without needing a physical XRServer tracker in the test process.
static func choose_auto_modality(
	hand_live: bool,
	controller_live: bool,
	controller_profile: String,
	prefer_hand: bool = true
) -> Modality:
	if prefer_hand and hand_live:
		return Modality.HAND
	if controller_live and _profile_is_controller(controller_profile):
		return Modality.CONTROLLER
	if hand_live:
		return Modality.HAND
	if controller_live:
		return Modality.CONTROLLER
	return Modality.NONE


## True when a tracker's bound interaction profile identifies a physical
## controller rather than a bare-hand source ("/interaction_profiles/none",
## ".../ext/hand_interaction_ext", "generic-hand-select", ...) or nothing.
static func _profile_is_controller(profile: String) -> bool:
	if profile.is_empty() or profile.ends_with("/none"):
		return false
	return not profile.contains("hand")


## ---- profile-matched models -------------------------------------------------

const _REMAP_MATERIAL := preload("res://addons/godot_webxr_kit/runtime/gltf_remap_material.tres")
const _REMAP_MATERIAL_TEXTURED := preload("res://addons/godot_webxr_kit/runtime/gltf_remap_material_textured.tres")

var _fetching := [false, false]
var _fetch_queue: Array[Array] = [[], []]


func _fetch_next(hand: int) -> void:
	if _fetching[hand] or _fetch_queue[hand].is_empty():
		return
	_fetch_model(hand, str(_fetch_queue[hand].pop_front()))

func _try_resolve_profile_model(hand: int) -> void:
	if not use_profile_models or _grip_nodes[hand] == null:
		return
	var candidates := _candidate_profiles(hand)
	var side := "left" if hand == 0 else "right"
	# Best BUNDLED match attaches instantly (usually the generic fallback)...
	for profile in candidates:
		var path := "%s/%s/%s.glb" % [_MODELS_DIR, profile, side]
		if not ResourceLoader.exists(path):
			continue
		var scene := load(path) as PackedScene
		if scene:
			_attach_profile_model(hand, (scene.instantiate() as Node3D), profile)
			break
	# ...and the best DEVICE-SPECIFIC profile upgrades it from cache/repository.
	# The whole candidate list queues: registries lack assets for some ids a
	# device reports first (Quest 3 lists meta-touch-plus before
	# oculus-touch-v3), so a miss moves to the next candidate.
	if fetch_profile_models:
		_fetch_queue[hand].clear()
		for candidate in candidates:
			var id := str(candidate)
			if id != _resolved_profile[hand] and id != _GENERIC_PROFILE:
				_fetch_queue[hand].append(id)
		_fetch_next(hand)


func _attach_profile_model(hand: int, model: Node3D, profile: String) -> void:
	if _profile_models[hand]:
		_profile_models[hand].queue_free()
	model.name = "ProfileControllerModel"
	_grip_nodes[hand].add_child(model)
	_profile_models[hand] = model
	_resolved_profile[hand] = profile
	_set_controller_visuals(hand, _modality[hand] == Modality.CONTROLLER)


func _fetch_model(hand: int, profile: String) -> void:
	if _fetching[hand]:
		return
	var side := "left" if hand == 0 else "right"
	var cache_path := "user://controller_models/%s_%s.glb" % [profile, side]
	if FileAccess.file_exists(cache_path):
		_attach_gltf_bytes(hand, profile, FileAccess.get_file_as_bytes(cache_path))
		return
	_fetching[hand] = true
	var request := HTTPRequest.new()
	add_child(request)
	request.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
		request.queue_free()
		_fetching[hand] = false
		if code != 200 or body.is_empty():
			print_verbose("XRInputModalityManager: model fetch miss '%s' %s (result %d, HTTP %d) - trying next candidate." % [profile, side, result, code])
			_fetch_next(hand)  # asset miss for this id: try the next candidate
			return
		DirAccess.make_dir_recursive_absolute("user://controller_models")
		var file := FileAccess.open(cache_path, FileAccess.WRITE)
		if file:
			file.store_buffer(body)
			file.close()
		_attach_gltf_bytes(hand, profile, body))
	if request.request("%s/%s/%s.glb" % [model_repository_url, profile, side]) != OK:
		request.queue_free()
		_fetching[hand] = false


func _attach_gltf_bytes(hand: int, profile: String, bytes: PackedByteArray) -> void:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var parse_error := doc.append_from_buffer(bytes, "", state)
	if parse_error != OK:
		push_warning("XRInputModalityManager: glTF parse failed for '%s' (error %d)." % [profile, parse_error])
		return
	var model := doc.generate_scene(state) as Node3D
	if model == null:
		push_warning("XRInputModalityManager: glTF scene generation failed for '%s'." % profile)
		return
	print_verbose("XRInputModalityManager: controller model '%s' attached (%d bytes)." % [profile, bytes.size()])
	# Runtime-parsed glTF creates fresh materials whose shader variants are NOT
	# in a WebGPU export's baked cache (they render invisible there). Remap
	# every surface onto duplicates of one small PRE-BAKED template, copying
	# colour/texture/metallic/roughness as uniforms - uniform changes reuse the
	# baked shader, so the fetched model is guaranteed to render.
	_remap_materials(model)
	_attach_profile_model(hand, model, profile)


func _remap_materials(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		for surface in mesh_instance.get_surface_override_material_count():
			var source := mesh_instance.get_active_material(surface)
			# Texture PRESENCE is shader codegen in BaseMaterial3D (WebGPU-
			# proven: textured remaps hit "missing from the baked shader
			# cache"), so textured surfaces duplicate the TEXTURED template
			# (baked with a placeholder albedo) and only SWAP the texture -
			# a uniform change that reuses the baked shader.
			var has_texture: bool = source is BaseMaterial3D and (source as BaseMaterial3D).albedo_texture != null
			var template := _REMAP_MATERIAL_TEXTURED if has_texture else _REMAP_MATERIAL
			var remapped := template.duplicate() as StandardMaterial3D
			if source is BaseMaterial3D:
				var base := source as BaseMaterial3D
				remapped.albedo_color = base.albedo_color
				if has_texture:
					remapped.albedo_texture = base.albedo_texture
				remapped.metallic = base.metallic
				remapped.roughness = base.roughness
			mesh_instance.set_surface_override_material(surface, remapped)
	for child in node.get_children():
		_remap_materials(child)


func _candidate_profiles(hand: int) -> PackedStringArray:
	var candidates := PackedStringArray()
	# WebXR: the browser reports an ordered list per input source (specific ->
	# generic), captured by the JS hook below.
	if OS.has_feature("web") and Engine.has_singleton("JavaScriptBridge"):
		var js := Engine.get_singleton("JavaScriptBridge")
		var side := "left" if hand == 0 else "right"
		var raw := str(js.eval("JSON.stringify((window.GodotXRProfiles && window.GodotXRProfiles.%s) || [])" % side, true))
		var parsed = JSON.parse_string(raw)
		if parsed is Array:
			for entry in parsed:
				var id := str(entry)
				# The registry also ships HAND meshes (generic-hand). Models here
				# represent physical controllers only - during the browser's
				# controller->hands handover the profiles store can already hold
				# the hand list while the controller pose is still "live", and
				# without this filter that race fetches a hand mesh as a
				# "controller model".
				if id.contains("hand"):
					continue
				candidates.append(id)
	# OpenXR: the tracker carries the bound interaction profile path.
	var tracker := XRServer.get_tracker(&"left_hand" if hand == 0 else &"right_hand") as XRPositionalTracker
	if tracker and not tracker.profile.is_empty():
		var mapped: String = _OPENXR_PROFILE_MAP.get(tracker.profile, "")
		if not mapped.is_empty():
			candidates.append(mapped)
	candidates.append(_GENERIC_PROFILE)
	return candidates


func _install_webxr_profiles_hook() -> void:
	if not OS.has_feature("web") or not Engine.has_singleton("JavaScriptBridge"):
		return
	Engine.get_singleton("JavaScriptBridge").eval("""
(function () {
	if (window.GodotXRProfiles) { return; }
	window.GodotXRProfiles = { left: [], right: [] };
	if (typeof XRSession === 'undefined') { return; }
	const originalRAF = XRSession.prototype.requestAnimationFrame;
	XRSession.prototype.requestAnimationFrame = function (callback) {
		return originalRAF.call(this, function (time, frame) {
			try {
				for (const source of frame.session.inputSources) {
					if (source.handedness === 'left' || source.handedness === 'right') {
						const store = window.GodotXRProfiles[source.handedness];
						if (source.profiles && source.profiles.length && store[0] !== source.profiles[0]) {
							window.GodotXRProfiles[source.handedness] = Array.from(source.profiles);
						}
					}
				}
			} catch (e) { /* never break the frame loop */ }
			callback(time, frame);
		});
	};
}())
""", true)


func _build_grip_node(controller: Node3D, hand: int) -> XRController3D:
	if controller == null or controller.get_parent() == null:
		return null
	# Registry models are authored for the GRIP space (the web's controller-
	# model factory attaches them there); the rig's controllers sit at the AIM
	# pose, so the model rides its own grip-pose node.
	var grip := XRController3D.new()
	grip.name = "GripModelAnchor%s" % ("Left" if hand == 0 else "Right")
	grip.tracker = &"left_hand" if hand == 0 else &"right_hand"
	grip.pose = &"grip"
	controller.get_parent().add_child(grip)
	return grip


## ---- fallback primitives ----------------------------------------------------

func _build_fallback_model(controller: Node3D) -> Node3D:
	if controller == null:
		return null
	var model := Node3D.new()
	model.name = "ControllerModel"
	# The controller node sits at the AIM pose (pointer tip, -Z forward); the
	# grip body sits behind and below it, pitched like a held controller.
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.021
	capsule.height = 0.115
	body.mesh = capsule
	body.material_override = _MODEL_MATERIAL
	body.position = Vector3(0, -0.03, 0.06)
	body.rotation_degrees = Vector3(-60, 0, 0)
	model.add_child(body)
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.028
	torus.outer_radius = 0.036
	torus.rings = 24
	torus.ring_segments = 10
	ring.mesh = torus
	ring.material_override = _MODEL_MATERIAL
	ring.position = Vector3(0, -0.012, 0.035)
	ring.rotation_degrees = Vector3(25, 0, 0)
	model.add_child(ring)
	controller.add_child(model)
	model.visible = false
	return model


func _set_controller_visuals(hand: int, on: bool) -> void:
	# Profile model preferred; primitives only when no profile model resolved.
	if _profile_models[hand]:
		_profile_models[hand].visible = on
		if _fallback_models[hand]:
			_fallback_models[hand].visible = false
	elif _fallback_models[hand]:
		_fallback_models[hand].visible = on


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if show_controller_models and (left_controller_path.is_empty() or right_controller_path.is_empty()):
		warnings.append("Point Left/Right Controller Path at the rig's XRController3D nodes for controller models.")
	return warnings
