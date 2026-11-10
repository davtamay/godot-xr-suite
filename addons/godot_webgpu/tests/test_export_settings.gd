extends SceneTree

const Overrides := preload("res://addons/godot_webgpu/editor/export_settings.gd")


func _initialize() -> void:
	var setting := "rendering/renderer/rendering_method.web"
	var existed := ProjectSettings.has_setting(setting)
	var original: Variant = ProjectSettings.get_setting(setting) if existed else null
	var temporary := "webgpu_test/transient_export_setting"
	assert(not ProjectSettings.has_setting(temporary))
	var overrides := Overrides.new()
	overrides.apply({setting: "mobile", temporary: true})
	assert(ProjectSettings.get_setting(setting) == "mobile")
	overrides.apply({setting: "forward_plus"})
	assert(ProjectSettings.get_setting(setting) == "forward_plus")
	overrides.restore()
	assert(ProjectSettings.has_setting(setting) == existed)
	assert(ProjectSettings.get_setting(setting) == original if existed else not ProjectSettings.has_setting(setting))
	assert(not ProjectSettings.has_setting(temporary))
	overrides.restore()
	print("PASS: export overrides restore original values, remove temporary keys and are idempotent")
	quit(0)
