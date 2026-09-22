extends Node3D

## XRPrefab - the one-drop-in XR setup. Instance this scene under any scene's
## root and you get WebXR (browser) AND OpenXR (Quest Link / SteamVR / Android XR):
## controllers, hands, and grab with zero wiring. On Web, the prefab
## automatically creates the browser Enter VR/AR UI. Native OpenXR starts
## directly without that browser UI.
##
## Drops into EXISTING scenes without fighting your camera - if the scene already
## has a Camera3D it stays the flat view, and the XR camera takes over only
## in-session. To make an object grabbable, add an XRGrabInteractable (with a
## CollisionObject3D child) anywhere in your scene.

## Hands and controllers are configured on VISIBLE NODES inside the rig, so
## the fields live where you'd look for them: expand WebXRRig/XROrigin3D and
## select the "Hands" node (show mode, procedural/realistic, custom models),
## or the "XRInputModalityManager" node (controller models). This prefab just
## instances that rig and handles the camera hand-off.

var _xr_cam: XRCamera3D
var _flat_cam: Camera3D
var _was_xr := false

const DEFAULT_RUNTIME_CONFIG := preload(
	"res://addons/godot_webxr_kit/runtime/default_xr_runtime_config.tres"
)

## Edit the shared default resource for a project-wide policy, or assign a
## duplicated XRRuntimeConfig here for a per-scene override.
@export var runtime_config: XRRuntimeConfig = DEFAULT_RUNTIME_CONFIG


func _enter_tree() -> void:
	_apply_runtime_config()


func _ready() -> void:
	# Existing-scene camera: keep the scene's own camera for the flat view; the XR
	# camera drives only in-session (toggled in _process). A bare scene with no
	# camera keeps the rig's camera as its flat view.
	_xr_cam = get_node_or_null("WebXRRig/XROrigin3D/XRCamera3D") as XRCamera3D
	_flat_cam = _find_scene_camera(_xr_cam)
	if _flat_cam and _xr_cam:
		_adopt_scene_camera()
	elif _xr_cam:
		# A child's _ready runs before its parent's, so a scene that builds its
		# camera in the root's _ready has no camera yet at this point. Look once
		# more after the whole tree has readied; without this the flat camera
		# stays current in-session and the eye buffer never renders (GL logs a
		# view_count mismatch every frame).
		_late_find_scene_camera.call_deferred()


func _late_find_scene_camera() -> void:
	if _flat_cam != null or _xr_cam == null:
		return
	_flat_cam = _find_scene_camera(_xr_cam)
	if _flat_cam:
		_adopt_scene_camera()


func _adopt_scene_camera() -> void:
	# A scene streamed in while a session is already running must not show
	# the flat camera for even one frame: the renderer draws whatever camera
	# is current, so that frame is the scene camera's authored view, tilted
	# and head-locked, and it stays up for as long as the scene's first
	# frame takes to compile. Start on the camera the session already
	# calls for.
	_was_xr = get_viewport().use_xr
	_xr_cam.current = _was_xr
	var flat_ctrl := get_node_or_null("WebXRRig/FlatscreenCamera")
	if flat_ctrl:
		flat_ctrl.set("enabled", false)  # let the scene's own camera drive flat


func _process(_delta: float) -> void:
	# Only relevant when we deferred to a scene camera: hand the view to the XR
	# camera when a session starts, and back to the scene camera on exit.
	if _flat_cam == null or _xr_cam == null:
		return
	var xr := get_viewport().use_xr
	if xr and not _was_xr:
		_xr_cam.current = true
	elif not xr and _was_xr:
		_flat_cam.current = true
	_was_xr = xr


func _apply_runtime_config() -> void:
	if runtime_config == null:
		return
	var web_bootstrap := get_node_or_null("WebXRBootstrap")
	if web_bootstrap:
		web_bootstrap.set("enabled", runtime_config.webxr_enabled)
		web_bootstrap.set("require_hand_tracking", runtime_config.webxr_require_hand_tracking)
	var openxr_bootstrap := get_node_or_null("OpenXRBootstrap")
	if openxr_bootstrap:
		openxr_bootstrap.set("enabled", runtime_config.openxr_enabled)
		openxr_bootstrap.set(
			"start_in_passthrough",
			runtime_config.openxr_start_in_passthrough
		)
		openxr_bootstrap.set(
			"simultaneous_hands_and_controllers",
			runtime_config.openxr_simultaneous_hands_and_controllers
		)
		openxr_bootstrap.set(
			"headset_present_timeout",
			runtime_config.native_headset_present_timeout
		)


func _find_scene_camera(exclude: Camera3D) -> Camera3D:
	# XRSceneRouter briefly overlaps incoming and outgoing scenes. During the
	# incoming prefab's _ready(), current_scene can still be the outgoing one,
	# so search only the scene that actually owns this prefab.
	var scene := _own_scene_root()
	if scene == null:
		return null
	for cam in scene.find_children("*", "Camera3D", true, false):
		if cam != exclude:
			return cam as Camera3D
	return null


func _own_scene_root() -> Node:
	var node: Node = self
	var tree_root := get_tree().root
	while node.get_parent() != null and node.get_parent() != tree_root:
		node = node.get_parent()
	return node
