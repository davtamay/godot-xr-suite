@tool
extends RefCounted

## Export-only overrides must not leak into the next preset or editor session.
var _previous: Dictionary = {}


func apply(values: Dictionary) -> void:
	for key in values:
		if not _previous.has(key):
			_previous[key] = {
				"exists": ProjectSettings.has_setting(key),
				"value": ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null,
			}
		ProjectSettings.set_setting(key, values[key])


func restore() -> void:
	for key in _previous:
		var prior: Dictionary = _previous[key]
		ProjectSettings.set_setting(key, prior.value if prior.exists else null)
	_previous.clear()
