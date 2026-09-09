@tool
extends EditorExportPlugin

## Adds a preset-local WebGPU toggle to Web exports. WebGPU and WebXR remain
## independent: each Web preset can choose WebGL or WebGPU, with or without XR.
## When enabled, shader baking is implied and the web build selects WebGPU.

const OPT := "webgpu/enabled"
const FP16 := "webgpu/bake_fp16_variants"
const STATUS := "webgpu/status"
const SHADER_BAKER := "shader_baker/enabled"
const FALLBACK := "webgpu/bake_mobile_fallback"
const FALLBACK_ENV := "GODOT_WEBGPU_FALLBACK_BAKE"
# A custom template built against an engine build profile carries that profile
# beside it, written by misc/webgpu_scripts/build-web-profiled.sh.
const PROFILE_SUFFIX := ".build"

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
			# Forward+ projects: also bake the Mobile scene shaders, so a device
			# that cannot bind Forward+ (the engine drops to Mobile below 48
			# sampled textures per stage) finds baked shaders instead of failing
			# with missing ones. About +5 MB of pack. Off by default: Chrome
			# reports either 48 (Forward+ runs) or the 16 floor (where today's
			# Mobile shaders do not bind either), so the bake only pays on
			# browsers that report native limits in between (wgpu/WebKit). No
			# effect on projects whose renderer is already Mobile.
			"option": {"name": FALLBACK, "type": TYPE_BOOL},
			"default_value": false,
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
	if option == FP16 or option == FALLBACK:
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
	# The web build follows the project's renderer (Forward+ or Mobile); the
	# engine's own default for the web feature tag is GL Compatibility, which
	# would silently override it.
	var method := _project_rendering_method()
	ProjectSettings.set_setting("rendering/renderer/rendering_method.web", method)
	ProjectSettings.set_setting("rendering/rendering_device/driver.web", "webgpu")
	ProjectSettings.set_setting("xr/shaders/enabled", false)
	# Read by the engine's WebGPU shader baker (skips FP16 variant groups
	# when false). Transient: set for this export only, defaults to true
	# when absent so stock projects keep the perf-first behavior.
	var bake_fp16: Variant = get_option(FP16)
	ProjectSettings.set_setting("rendering/webgpu/bake_fp16_shader_variants", bake_fp16 == null or bool(bake_fp16))
	if method == "forward_plus" and _is_on(FALLBACK) and OS.get_environment(FALLBACK_ENV) == "":
		_bake_mobile_fallback()
	_check_build_profile()


func _project_rendering_method() -> String:
	var base := str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "forward_plus"))
	return base if base in ["forward_plus", "mobile"] else "mobile"


## Runs a second export-pack in a child editor set to the Mobile renderer and
## adds its baked scene shaders (the classes the host renderer does not bake)
## to this export. The child skips this step through FALLBACK_ENV.
func _bake_mobile_fallback() -> void:
	var preset := get_export_preset()
	if preset == null:
		return
	var tmp := OS.get_temp_dir().path_join("godot_webgpu_mobile_fallback_%d.pck" % OS.get_process_id())
	var args := PackedStringArray([
		"--path", ProjectSettings.globalize_path("res://"),
		"--rendering-method", "mobile",
		"--rendering-driver", RenderingServer.get_current_rendering_driver_name(),
		"--export-pack", preset.get_preset_name(), tmp,
	])
	OS.set_environment(FALLBACK_ENV, "1")
	var output: Array = []
	var rc := OS.execute(OS.get_executable_path(), args, output, true)
	OS.unset_environment(FALLBACK_ENV)
	if rc != 0 or not FileAccess.file_exists(tmp):
		push_warning("WebGPU: the Mobile fallback bake failed (exit %d); the export carries Forward+ shaders only." % rc)
		return
	var added := _merge_shader_cache(tmp)
	DirAccess.remove_absolute(tmp)
	print("WebGPU: Mobile fallback shaders baked, %d entries added to the export." % added)


func _merge_shader_cache(pck_path: String) -> int:
	var f := FileAccess.open(pck_path, FileAccess.READ)
	if f == null or f.get_32() != 0x43504447: # "GDPC"
		return 0
	var version := f.get_32()
	f.get_32(); f.get_32(); f.get_32() # engine version
	f.get_32() # pack flags
	var file_base := f.get_64()
	if version >= 3:
		f.seek(f.get_64()) # directory offset
	else:
		for i in 16:
			f.get_32() # reserved
	var count := f.get_32()
	var entries: Array = []
	for i in count:
		var raw := f.get_buffer(f.get_32())
		var n := raw.size()
		while n > 0 and raw[n - 1] == 0:
			n -= 1
		var path := raw.slice(0, n).get_string_from_utf8()
		var ofs := f.get_64()
		var size := f.get_64()
		f.get_buffer(16) # md5
		if version >= 2:
			f.get_32() # file flags
		entries.append([path, ofs, size])
	var host_cache := ProjectSettings.globalize_path("res://.godot/shader_cache")
	var added := 0
	for e in entries:
		var rel: String = str(e[0]).trim_prefix("res://")
		if not rel.begins_with(".godot/shader_cache/"):
			continue
		# Skip only what the host already baked, file by file. Judging by class
		# was too coarse: a class the host also bakes (the skeleton and canvas
		# SDF shaders, say) still has group files of its own under the other
		# renderer, because the defines differ and the group file is named by
		# their hash, and those were dropped along with the duplicates.
		if FileAccess.file_exists(host_cache.path_join(rel.trim_prefix(".godot/shader_cache/"))):
			continue
		f.seek(file_base + int(e[1]))
		add_file("res://" + rel, f.get_buffer(int(e[2])), false)
		added += 1
	return added


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


## Reports classes this project now needs that its template was built without.
##
## A template built against a build profile has the engine's unused half
## compiled out, which makes it much smaller and ties it to one project: the
## classes it left out are gone, so a project that has grown since fails when
## the scene loads, with no sign of it at export time. The template says so
## itself by carrying its profile beside it, so this costs nothing on an
## ordinary template.
func _check_build_profile() -> void:
	var preset := get_export_preset()
	if preset == null:
		return
	var template := str(preset.get("custom_template/release"))
	if template.is_empty():
		return
	var profile_path := template + PROFILE_SUFFIX
	if not FileAccess.file_exists(profile_path):
		return

	var stale := _stale_profile_classes(profile_path)
	if stale.is_empty():
		print_verbose("WebGPU: build profile still fits this project.")
		return
	push_error(
		"WebGPU: this project now uses %d class(es) its template was built without: %s. "
		% [stale.size(), ", ".join(stale)]
		+ "The export will fail to load them. Rebuild the template: "
		+ "bash misc/webgpu_scripts/build-web-profiled.sh <project>"
	)


## Re-runs the editor's own detection and returns the classes the stored
## profile disables that the project has since started using.
##
## Detection writes into the build-profile dialog's working copy, which is the
## only way to reach it; a profile left unsaved in that dialog is replaced.
func _stale_profile_classes(profile_path: String) -> PackedStringArray:
	var stale := PackedStringArray()
	var text := FileAccess.get_file_as_string(profile_path)
	if text.is_empty():
		return stale
	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("WebGPU: could not read the template's build profile at %s." % profile_path)
		return stale
	var disabled: Array = (data as Dictionary).get("disabled_classes", [])
	if disabled.is_empty():
		return stale

	var base: Control = EditorInterface.get_base_control() if Engine.is_editor_hint() else null
	if base == null:
		# A headless export cannot reach the editor's detection. Loading the
		# export is the check that still applies, and it is the stronger one.
		return stale
	var manager := _find_node_of_class(base, "EditorBuildProfileManager")
	if manager == null or not manager.has_method("detect_from_project"):
		push_warning("WebGPU: this editor cannot re-check the template's build profile.")
		return stale

	manager.detect_from_project()
	var fresh: Object = manager.get_current_profile()
	if fresh == null:
		return stale
	for entry in disabled:
		var class_name_string := str(entry)
		if ClassDB.class_exists(class_name_string) and not fresh.is_class_disabled(class_name_string):
			stale.append(class_name_string)
	return stale


func _find_node_of_class(node: Node, wanted: String) -> Node:
	if node.get_class() == wanted:
		return node
	for child in node.get_children():
		var found := _find_node_of_class(child, wanted)
		if found != null:
			return found
	return null
