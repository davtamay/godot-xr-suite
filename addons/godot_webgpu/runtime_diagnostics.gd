extends Node

## Add as an autoload in projects that collect browser XR test reports.
func _ready() -> void:
	if not OS.has_feature("web"):
		return
	var build: Variant = null
	if FileAccess.file_exists("res://xr_build_provenance.json"):
		build = JSON.parse_string(FileAccess.get_file_as_string("res://xr_build_provenance.json"))
	var data := {
		"engine": Engine.get_version_info(),
		"driver": "webgpu" if RenderingServer.get_rendering_device() != null else "opengl3",
		"reported_driver": RenderingServer.get_current_rendering_driver_name(),
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"build": build,
	}
	JavaScriptBridge.eval(
		"if (typeof window.godotXRRuntimeReport === 'function') window.godotXRRuntimeReport(%s);"
		% JSON.stringify(JSON.stringify(data)), true
	)
