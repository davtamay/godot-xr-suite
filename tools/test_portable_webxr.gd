extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var activator = load("res://addons/godot_xr_interaction_toolkit/runtime/xr_hand_activator.gd").new()
	assert(activator.activate_gesture == null)
	if ResourceLoader.exists("res://addons/godot_xr_hands/runtime/gesture_studio/xr_hand_gesture.gd"):
		var gesture = load("res://addons/godot_xr_hands/runtime/gesture_studio/xr_hand_gesture.gd").new()
		activator.activate_gesture = gesture
		assert(activator.activate_gesture == gesture)
	activator.free()
	var packed = load("res://addons/godot_webxr_kit/samples/webxr_starter.tscn")
	assert(packed is PackedScene)
	var scene = packed.instantiate()
	var prefab = scene.get_node("XRPrefab")
	var config = load("res://addons/godot_webxr_kit/runtime/default_xr_runtime_config.tres").duplicate()
	config.openxr_enabled = false
	prefab.runtime_config = config
	root.add_child(scene)
	await process_frame
	await process_frame
	var manager = get_first_node_in_group("xr_interaction_manager")
	assert(manager != null, "Toolkit manager was not instantiated")
	assert(manager.get_interactables().size() > 0, "Starter grabbable did not register")
	assert(scene.find_child("WebXRInputAdapter", true, false) != null, "WebXR input adapter is missing")
	assert(not bool(WebXRRenderer.webgpu_supported()), "Native preview must not advertise browser WebGPU")
	print("PORTABLE_WEBXR_SMOKE=" + JSON.stringify({"passed":true,"engine":Engine.get_version_info(),"interactables":manager.get_interactables().size(),"hands_installed":DirAccess.dir_exists_absolute("res://addons/godot_xr_hands")}))
	scene.queue_free()
	await process_frame
	quit(0)
