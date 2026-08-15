extends XRSceneProvider

const _EXTENSION := "OpenXRAndroidEnvironmentDepthExtension"
const _DEPTH_NODE := "OpenXRAndroidEnvironmentDepth"
const _DEBUG_SHADER := preload(
	"res://addons/godot_xr_scene_understanding/runtime/android_xr_depth_debug.gdshader"
)
const _HAND_OCCLUDER_SHADER := preload(
	"res://addons/godot_xr_scene_understanding/runtime/tracked_hand_occluder.gdshader"
)
const _HAND_VISUALIZER_PATH := \
	"res://addons/godot_xr_hands/runtime/xr_hand_mesh_visualizer.gd"

var _extension: Object
var _depth_node: Node3D
var _debug_mesh: MeshInstance3D
var _hand_occluder: Node3D
var _started_here := false
var _occlusion_enabled := false
var _debug_enabled := false
var _selected_resolution := 320
var _smooth_enabled := true


func _init() -> void:
	provider_id = "openxr_android_xr"
	provider_label = "Android XR environment depth"


func start() -> bool:
	if OS.has_feature("web") or not ClassDB.class_exists(_DEPTH_NODE):
		return false
	_extension = Engine.get_singleton(_EXTENSION)
	if _extension == null or not bool(_extension.call("is_environment_depth_supported")):
		return false
	var camera := _find_xr_camera()
	if camera == null:
		return false
	_depth_node = ClassDB.instantiate(_DEPTH_NODE) as Node3D
	if _depth_node == null:
		return false
	_depth_node.name = "OpenXRAndroidEnvironmentDepth"
	camera.add_child(_depth_node)
	set_resolution_level(int(options.get("depth_resolution", 1)))
	_debug_mesh = _create_debug_mesh(_selected_resolution)
	camera.add_child(_debug_mesh)
	var origin := _find_xr_origin()
	if origin:
		_hand_occluder = _create_hand_occluder()
		if _hand_occluder:
			origin.add_child(_hand_occluder)
			_configure_hand_occluder_modality.call_deferred()
	enable_native_passthrough()
	_occlusion_enabled = bool(options.get("occlude", false))
	_debug_enabled = bool(options.get("debug_depth_visualization", false))
	_apply_enabled()
	return true


func stop() -> void:
	if _started_here and _extension and bool(_extension.call("is_environment_depth_started")):
		_extension.call("stop_environment_depth")
	_started_here = false
	if _debug_mesh and is_instance_valid(_debug_mesh):
		_debug_mesh.queue_free()
	_debug_mesh = null
	if _hand_occluder and is_instance_valid(_hand_occluder):
		_hand_occluder.queue_free()
	_hand_occluder = null


func get_status() -> String:
	if _extension == null:
		return "Android XR environment depth: extension unavailable."
	if bool(_extension.call("is_environment_depth_started")):
		if _debug_enabled:
			return "Depth Scan: Android XR raw live depth (sensor FOV only)."
		if _occlusion_enabled:
			if _hand_occluder:
				return "Depth occlusion: Android XR environment + tracked hands active."
			return "Depth occlusion: Android XR live environment depth active."
		return "Environment depth: Android XR stream ready."
	return "Environment depth: Android XR available; Show or Occlude to start."


func set_resolution_level(level: int) -> void:
	if _extension == null:
		return
	var resolutions: Array = _extension.call("get_supported_resolutions")
	if resolutions.is_empty():
		return
	# Manager levels 0..4 map onto the extension's 80, 160 and 320 square
	# resolutions. Clamp to values the runtime actually advertised.
	var desired := 0 if level <= 0 else (1 if level <= 2 else 2)
	if not resolutions.has(desired):
		desired = int(resolutions[resolutions.size() - 1])
	if bool(_extension.call("set_resolution", desired)):
		_selected_resolution = [80, 160, 320][desired]
	if bool(_extension.call("set_smooth", true)):
		_smooth_enabled = true


func set_occlusion(enabled: bool) -> void:
	_occlusion_enabled = enabled
	_apply_enabled()


func set_visualize(enabled: bool) -> void:
	_debug_enabled = enabled
	_apply_enabled()


func set_debug_visualization(enabled: bool) -> void:
	set_visualize(enabled)


func set_ext_harvest(enabled: bool) -> void:
	if enabled:
		set_occlusion(true)


func _apply_enabled() -> void:
	if _extension == null or _depth_node == null:
		return
	var enabled := _occlusion_enabled or _debug_enabled
	# Raw depth preserves close, dynamic detail for the visible diagnostic map.
	# Smoothed depth is the steadier input expected by invisible occlusion.
	var want_smooth := not _debug_enabled
	if enabled and want_smooth != _smooth_enabled:
		if bool(_extension.call("set_smooth", want_smooth)):
			_smooth_enabled = want_smooth
	# The vendor node is an invisible depth-buffer punch. Keep it exclusive
	# to Occlude; Show uses the colored point-cloud reprojection mesh.
	_depth_node.visible = _occlusion_enabled
	if _debug_mesh:
		_debug_mesh.visible = _debug_enabled
	if _hand_occluder:
		_hand_occluder.visible = _occlusion_enabled
	if enabled and not bool(_extension.call("is_environment_depth_started")):
		if bool(_extension.call("start_environment_depth")):
			_started_here = true
	elif not enabled and _started_here and bool(_extension.call("is_environment_depth_started")):
		_extension.call("stop_environment_depth")
		_started_here = false


func _create_debug_mesh(resolution: int) -> MeshInstance3D:
	# The shader positions one point per depth texel using VERTEX_ID. This
	# matches the vendor reprojection mesh and keeps the depth texture on-GPU.
	var vertices := PackedVector3Array()
	vertices.resize(resolution * resolution)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	mesh.custom_aabb = AABB(
		Vector3(-1000, -1000, -1000),
		Vector3(2000, 2000, 2000)
	)
	var material := ShaderMaterial.new()
	material.shader = _DEBUG_SHADER
	material.render_priority = 1
	var instance := MeshInstance3D.new()
	instance.name = "AndroidXRDepthDebugVisualization"
	instance.mesh = mesh
	instance.material_override = material
	instance.visible = false
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _create_hand_occluder() -> Node3D:
	# The Android XR vendor plugin currently exposes environment depth but not
	# XR_ANDROID_hand_mesh as a Godot node. Reuse our cross-runtime rigged hand
	# mesh, driven by XR_EXT_hand_tracking joints, until that native mesh is
	# available. This is only instantiated by the Android XR provider.
	if not ResourceLoader.exists(_HAND_VISUALIZER_PATH):
		return null
	var visualizer_script := load(_HAND_VISUALIZER_PATH) as Script
	if visualizer_script == null:
		return null
	var visualizer := visualizer_script.new() as Node3D
	if visualizer == null:
		return null
	var material := ShaderMaterial.new()
	material.shader = _HAND_OCCLUDER_SHADER
	# Match the vendor depth reprojection's early-render approach (-50), with
	# hands just ahead of it so virtual color has not already been drawn.
	material.render_priority = -60
	visualizer.set("hand_material", material)
	visualizer.name = "AndroidXRTrackedHandOccluder"
	visualizer.visible = false
	return visualizer


func _configure_hand_occluder_modality() -> void:
	if _hand_occluder == null or not is_instance_valid(_hand_occluder):
		return
	var manager := get_tree().get_first_node_in_group(&"xr_input_modality_manager")
	if manager == null:
		# The visualizer still follows per-hand XRHandTracker availability.
		return
	if manager.has_signal("modality_changed"):
		manager.connect("modality_changed", _on_hand_occluder_modality_changed)
	if manager.has_method("get_modality"):
		for hand in 2:
			_on_hand_occluder_modality_changed(hand, int(manager.call("get_modality", hand)))


func _on_hand_occluder_modality_changed(hand: int, modality: int) -> void:
	if _hand_occluder == null:
		return
	# "%sHandTracking" mirrors XRHandIdentity.hand_tracking_root_name() in the
	# toolkit. Kept inline HERE ONLY because this provider must parse when the
	# toolkit addon is absent; every other producer/consumer of this node-name
	# contract goes through that one symbol.
	var side := "Right" if hand == 1 else "Left"
	var hand_root := _hand_occluder.get_node_or_null("%sHandTracking" % side)
	if hand_root == null:
		return
	# XRInputModalityManager.Modality.CONTROLLER is 1. Use the dynamic contract
	# here so this provider still parses when the optional kit addon is absent.
	var render_hand := modality != 1
	for visual in hand_root.find_children("*", "VisualInstance3D", true, false):
		(visual as VisualInstance3D).layers = 1 if render_hand else 0


func _find_xr_camera() -> XRCamera3D:
	var scene := _own_scene_root()
	var cameras := scene.find_children("*", "XRCamera3D", true, false)
	if cameras.is_empty():
		return null
	return cameras[0] as XRCamera3D


func _find_xr_origin() -> XROrigin3D:
	var scene := _own_scene_root()
	var origins := scene.find_children("*", "XROrigin3D", true, false)
	if origins.is_empty():
		return null
	return origins[0] as XROrigin3D


func _own_scene_root() -> Node:
	var node: Node = self
	var tree_root := get_tree().root
	while node.get_parent() != null and node.get_parent() != tree_root:
		node = node.get_parent()
	return node
