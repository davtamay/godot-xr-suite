extends Node3D
func _ready() -> void:
	var scene = load("res://addons/godot_webxr_kit/samples/webxr_starter.tscn").instantiate()
	add_child(scene)
	for i in range(30):
		await get_tree().process_frame
	var manager = get_tree().get_first_node_in_group("xr_interaction_manager")
	var report = {"version":Engine.get_version_info(),"renderer":WebXRRenderer.active(),"driver":RenderingServer.get_current_rendering_driver_name(),"interactables":manager.get_interactables().size(),"webxr_adapter":scene.find_child("WebXRInputAdapter",true,false)!=null,"hands_installed":DirAccess.dir_exists_absolute("res://addons/godot_xr_hands")}
	JavaScriptBridge.eval("window.__portableReport=" + JSON.stringify(report),true)
	print("PORTABLE_WEBXR_RUNTIME=" + JSON.stringify(report))
