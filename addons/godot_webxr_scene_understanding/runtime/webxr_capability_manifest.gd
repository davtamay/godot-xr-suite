extends Node

## Declares the WebXR capability union used by scenes reachable from a
## multi-scene launcher. WebXR session features cannot be added after a session
## starts, so applications that keep one session alive across scene changes
## must request future-scene capabilities up front.
##
## This component lives in the optional WebXR provider package. Loading it by a
## soft runtime path lets native exports strip the package and every request.


func _enter_tree() -> void:
	add_to_group("webxr_feature_provider")


func get_webxr_required_features(_session_mode: String) -> PackedStringArray:
	return PackedStringArray()


func get_webxr_optional_features(session_mode: String) -> PackedStringArray:
	if session_mode != "immersive-ar":
		return PackedStringArray()
	return PackedStringArray([
		WebXRFeatures.MESH_DETECTION,
		WebXRFeatures.PLANE_DETECTION,
		WebXRFeatures.DEPTH_SENSING,
		WebXRFeatures.HIT_TEST,
		WebXRFeatures.ANCHORS,
		WebXRFeatures.LIGHT_ESTIMATION,
	])
