@tool
extends EditorExportPlugin

## Adds a preset-local WebGPU toggle to Web exports. WebGPU and WebXR remain
## independent: each Web preset can choose WebGL or WebGPU, with or without XR.
## When enabled, shader baking is implied and the web build selects WebGPU.

const OPT := "webgpu/enabled"
const FP16 := "webgpu/bake_fp16_variants"
const STATUS := "webgpu/status"
const SHADER_BAKER := "shader_baker/enabled"

var editor_plugin: EditorPlugin
var _last_on := false
var _last_status_text := ""


func _get_name() -> String:
	return "WebGPU"


func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform != null and platform.get_os_name() == "Web"


func _get_export_options(platform: EditorExportPlatform) -> Array[Dictionary]:
	if not _supports_platform(platform):
		return []
	return [
		{
			"option": {"name": OPT, "type": TYPE_BOOL},
			"default_value": false,
			"update_visibility": true,
		},
		{
			# Bake the half-precision (FP16) shader variants alongside FP32.
			# Devices reporting shader-f16 (Quest, Galaxy XR, modern desktop
			# GPUs) then run the faster half-float shaders; others fall back
			# to FP32. Costs pck size (~+3.7 MB on the demo suite) - turn off
			# for size-critical exports.
			"option": {"name": FP16, "type": TYPE_BOOL},
			"default_value": true,
		},
		{
			"option": {
				"name": STATUS,
				"type": TYPE_STRING,
				"usage": PROPERTY_USAGE_DEFAULT | PROPERTY_USAGE_READ_ONLY,
			},
			"default_value": "Applied preset: WebGPU ON",
		},
	]


func _should_update_export_options(platform: EditorExportPlatform) -> bool:
	if not _supports_platform(platform):
		return false
	var now := _is_on(OPT)
	var on_changed := now != _last_on
	var changed := on_changed
	_last_on = now
	var status_text := _selection_status_text()
	if status_text != _last_status_text:
		if _update_current_preset_status(status_text):
			_last_status_text = status_text
			changed = true
	if on_changed and now and not _base_ok() and editor_plugin != null:
		editor_plugin.call_deferred("show_setup_popup")
	return changed


func _get_export_option_visibility(
	platform: EditorExportPlatform,
	option: String
) -> bool:
	if not _supports_platform(platform):
		return false
	if option == SHADER_BAKER:
		return false
	if option == STATUS:
		return _is_on(OPT) and _base_ok()
	if option == FP16:
		return _is_on(OPT)
	return true


func _get_export_options_overrides(
	platform: EditorExportPlatform
) -> Dictionary:
	if not _supports_platform(platform):
		return {}
	# The active Web preset owns the renderer choice. This plugin only supplies
	# the hidden shader-baker plumbing implied by that preset-local choice.
	if _is_on(OPT):
		return {SHADER_BAKER: true}
	return {}


func _get_export_option_warning(
	platform: EditorExportPlatform,
	option: String
) -> String:
	if option == OPT and _is_on(OPT) and not _base_ok():
		return (
			"Not set up for WebGPU rendering. Re-tick WebGPU to open the "
			+ "one-click setup (or set Project Settings > Rendering > "
			+ "Renderer > Mobile and restart)."
		)
	return ""


func _export_begin(
	features: PackedStringArray,
	is_debug: bool,
	path: String,
	flags: int
) -> void:
	if not _is_on(OPT):
		return
	ProjectSettings.set_setting("rendering/renderer/rendering_method.web", "mobile")
	ProjectSettings.set_setting("rendering/rendering_device/driver.web", "webgpu")
	ProjectSettings.set_setting("xr/shaders/enabled", false)
	# Read by the engine's WebGPU shader baker (skips FP16 variant groups
	# when false). Transient: set for this export only, defaults to true
	# when absent so stock projects keep the perf-first behavior.
	var bake_fp16: Variant = get_option(FP16)
	ProjectSettings.set_setting("rendering/webgpu/bake_fp16_shader_variants", bake_fp16 == null or bool(bake_fp16))


func _base_ok() -> bool:
	return RenderingServer.get_rendering_device() != null


func _is_on(option: String) -> bool:
	if get_export_preset() == null:
		return false
	var value: Variant = get_option(option)
	return value != null and bool(value)


func _selection_status_text() -> String:
	return "Applied preset: WebGPU %s" % (
		"ON" if _raw_preset_enabled() else "OFF"
	)


func _raw_preset_enabled() -> bool:
	if get_export_preset() == null:
		return false
	var value: Variant = get_option(OPT)
	return value != null and bool(value)


func _update_current_preset_status(status_text: String) -> bool:
	var preset := get_export_preset()
	var platform := get_export_platform()
	if (
		preset == null
		or platform == null
		or platform.get_os_name() != "Web"
		or not preset.has(STATUS)
	):
		return false
	if str(preset.get(STATUS)) != status_text:
		preset.set(STATUS, status_text)
		preset.notify_property_list_changed()
	return true
