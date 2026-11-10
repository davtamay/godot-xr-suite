@tool
extends RefCounted

## Export-time facts. Unknown source state is explicitly non-reproducible.
static func collect(preset: EditorExportPreset, platform: EditorExportPlatform, is_debug: bool) -> Dictionary:
	var project := ProjectSettings.globalize_path("res://")
	var addon := ProjectSettings.globalize_path("res://addons/godot_webgpu")
	var directory := DirAccess.open(addon.get_base_dir())
	if directory != null and directory.is_link("godot_webgpu"):
		var target := directory.read_link("godot_webgpu")
		addon = target if target.is_absolute_path() else addon.get_base_dir().path_join(target)
	var template := str(preset.get("custom_template/debug" if is_debug else "custom_template/release"))
	if template.is_empty():
		var threaded := bool(preset.get("variant/thread_support"))
		var extensions := bool(preset.get("variant/extensions_support"))
		var template_name := "web%s%s_%s.zip" % ["_dlink" if extensions else "", "" if threaded else "_nothreads", "debug" if is_debug else "release"]
		template = platform.find_export_template(template_name).get("path", "")
	var demo_state := _source_state(project)
	var suite_state := _source_state(addon)
	var project_root := _git(project, PackedStringArray(["rev-parse", "--show-toplevel"]))
	var suite_root := _git(addon, PackedStringArray(["rev-parse", "--show-toplevel"]))
	# A copied addon belongs to the demo's Git tree; that revision cannot
	# establish the independently versioned suite source.
	if project_root.ok and suite_root.ok and project_root.text == suite_root.text:
		suite_state = {"revision": "unknown", "clean": false, "state": "copied-addon"}
	var engine_state := _source_state(OS.get_executable_path().get_base_dir().get_base_dir())
	var tint := OS.get_environment("GODOT_TINT_PATH")
	if tint.is_empty():
		tint = OS.get_executable_path().get_base_dir().path_join("tint.exe" if OS.get_name() == "Windows" else "tint")
	var tint_hash := FileAccess.get_sha256(tint) if FileAccess.file_exists(tint) else ""
	var template_hash := FileAccess.get_sha256(template) if FileAccess.file_exists(template) else ""
	var result := {
		"schema": 1,
		"exported_at": Time.get_datetime_string_from_system(true),
		"editor": Engine.get_version_info(),
		"editor_sha256": FileAccess.get_sha256(OS.get_executable_path()),
		"template_sha256": template_hash,
		"tint_sha256": tint_hash,
		"demo": demo_state,
		"suite": suite_state,
		"engine_source": engine_state,
		"preset": preset.get_preset_name(),
		"debug": is_debug,
		"options": {},
		"identity_complete": demo_state.clean and suite_state.clean and engine_state.clean and engine_state.revision == Engine.get_version_info().hash and not template_hash.is_empty() and (not bool(preset.get("webgpu/enabled")) or not tint_hash.is_empty()),
	}
	for option in ["webgpu/enabled", "webgpu/bake_fp16_variants", "webgpu/bake_mobile_fallback", "variant/thread_support", "shader_baker/enabled", "webxr/uses_webxr"]:
		result.options[option] = preset.get(option)
	result["build_id"] = JSON.stringify(result).sha256_text()
	return result


static func _source_state(path: String) -> Dictionary:
	var head := _git(path, PackedStringArray(["rev-parse", "HEAD"]))
	var status := _git(path, PackedStringArray(["status", "--porcelain", "--untracked-files=normal"]))
	return {
		"revision": head.text if head.ok else "unknown",
		"clean": head.ok and status.ok and status.text.is_empty(),
		"state": ("clean" if status.text.is_empty() else "dirty") if status.ok else "unknown",
	}


static func _git(path: String, arguments: PackedStringArray) -> Dictionary:
	var output: Array = []
	var command := PackedStringArray(["-C", path, "-c", "core.fsmonitor=false"])
	command.append_array(arguments)
	var result := OS.execute("git", command, output, false)
	return {"ok": result == 0, "text": "".join(output).strip_edges()}
