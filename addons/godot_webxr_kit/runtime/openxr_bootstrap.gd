@icon("res://addons/godot_webxr_kit/icons/openxr_bootstrap.svg")
class_name OpenXRBootstrap
extends Node

## Drop-in sibling of WebXRBootstrap for EDITOR-TIME / NATIVE testing on a real
## headset via Meta Quest Link, SteamVR, or Android XR's OpenXR runtime.
##
## Press Play and the SAME scene renders to the headset - no export, no browser.
## It just starts the OpenXR session and turns on XR rendering; the standard XR
## nodes (XROrigin3D / XRController3D / XRHandModifier3D) do the rest, so hands,
## controllers, and the interaction toolkit all work exactly as they do on WebXR.
##
## Inert on web exports (the WebXR bootstrap owns the browser path), so you can
## leave both bootstraps in every scene and each activates on its own platform.
##
## One-time project setup: Project Settings > XR > OpenXR > Enabled = on, then
## restart the editor. Have a runtime running (Quest Link / SteamVR) before Play.

## Session lifecycle, matching WebXRBootstrap's signals so a scene connects
## once and works on both platforms. mode is "immersive-ar" in passthrough,
## "immersive-vr" otherwise - the same strings the browser reports.
signal session_started(mode: String)
signal session_ended
signal session_failed(message: String)

## Hide nodes in this group while the session is active (mirrors the WebXR
## bootstrap so 2D HUDs don't composite into both eyes).
@export var session_hide_group := WebXRBootstrap.GROUP_SESSION_HIDDEN

## Runtime-configurable master switch. This node is always inert in web
## exports, even when enabled, so it is safe to ship beside WebXRBootstrap.
@export var enabled := true

## Start native OpenXR in passthrough AR. Capability-based: Quest and Android
## XR use alpha-blended composition; runtimes without it stay in opaque VR.
## WebXR session mode remains owned by WebXRBootstrap and is unaffected.
@export var start_in_passthrough := true

## Ask the runtime to track hands AND controllers at the same time, so each
## hand can hold a controller or go bare independently (Unity-XRI-style
## multimodal). Needs the godot_openxr_vendors plugin in the project AND a
## runtime that ships XR_META_simultaneous_hands_and_controllers (Quest 3 /
## Touch Pro, incl. over Link). Silently no-ops everywhere else - without it,
## platforms keep their own all-or-nothing hands<->controllers transition.
##
## Off by default for the portable Quest + Android XR baseline. Some runtimes
## keep a controller-like aim source alive while a bare hand points, causing
## controller models to replace the tracked hand. Enable this only for a scene
## that intentionally needs mixed per-hand input and has been tested per device.
@export var simultaneous_hands_and_controllers := false

## Seconds to wait for the headset to actually present before falling back to
## flat/desktop mode. SteamVR / Quest Link can leave OpenXR "initialized" with
## the headset idle; without this, the viewport would sit frozen on an XR display
## that never shows. When it falls back, the XR Simulator takes over the scene.
@export_range(0.5, 10.0, 0.5) var headset_present_timeout := 2.5

const _MULTIMODAL_CLASS := &"OpenXRMetaSimultaneousHandsAndControllersExtension"
const _META_PASSTHROUGH_CLASS := &"OpenXRFbPassthroughExtension"
const _ACTIVE_BOOTSTRAP_GROUP := &"openxr_active_bootstrap"
const _PASSTHROUGH_CLAIM_GROUP := &"xr_native_passthrough_provider"
const _AUTO_PERMISSION_SETTING := "xr/openxr/extensions/automatically_request_runtime_permissions"
const _PASSTHROUGH_RETRY_LIMIT := 20

var _xr: XRInterface
var _presented := false
var _passthrough_claimed := false
var _passthrough_retry_count := 0
var _passthrough_retry_pending := false
static var _android_permissions_requested := false


func _enter_tree() -> void:
	add_to_group(_ACTIVE_BOOTSTRAP_GROUP)


func _ready() -> void:
	if not enabled or OS.has_feature("web"):
		set_process(false)
		return  # WebXR bootstrap handles the browser path.

	_request_android_runtime_permissions()

	_xr = XRServer.find_interface("OpenXR")
	if _xr == null:
		push_warning("OpenXRBootstrap: no OpenXR interface. Enable Project Settings > XR > OpenXR and restart the editor.")
		return
	if not _xr.is_initialized():
		push_warning("OpenXRBootstrap: OpenXR is not initialized. Start a runtime (Quest Link / SteamVR) before pressing Play.")
		_xr = null
		return

	if start_in_passthrough:
		if _xr.has_signal("session_begun"):
			_xr.session_begun.connect(_on_native_session_begun)
		if not _claim_native_passthrough():
			_schedule_passthrough_retry()
	else:
		_set_native_opaque()
	_set_group_hidden(true)
	get_viewport().use_xr = true
	session_started.emit(WebXRFeatures.MODE_AR if _passthrough_claimed else WebXRFeatures.MODE_VR)

	# Only KEEP XR if a headset actually presents; otherwise this is a desktop
	# run with a runtime idling in the background - go flat so the simulator runs.
	if _xr.has_signal("session_visible"):
		_xr.session_visible.connect(_on_presented)
	if _xr.has_signal("session_focused"):
		_xr.session_focused.connect(_on_presented)
	get_tree().create_timer(headset_present_timeout).timeout.connect(_check_flat_fallback)

	if simultaneous_hands_and_controllers:
		# The session may already be running (editor Play initializes OpenXR at
		# startup) or begin later - cover both.
		_resume_multimodal()
		if _xr.has_signal("session_begun"):
			_xr.session_begun.connect(_resume_multimodal)


## The official vendors AAR normally performs this step. Universal XR exports
## deliberately avoid that vendor-specific loader, so use Godot's built-in
## Android permission API instead. Android filters this to dangerous permissions
## declared by the app and defined by the current device: Meta-only names are
## ignored on Android XR and Android-XR-only names are ignored on Quest.
func _request_android_runtime_permissions() -> void:
	if not OS.has_feature("android"):
		return
	if not bool(ProjectSettings.get_setting(_AUTO_PERMISSION_SETTING, true)):
		return
	if _android_permissions_requested:
		return
	_android_permissions_requested = true
	var already_granted := OS.request_permissions()
	if already_granted:
		print_verbose("OpenXRBootstrap: Android XR runtime permissions already granted.")
	else:
		print_verbose("OpenXRBootstrap: requested Android XR runtime permissions.")


func _claim_native_passthrough() -> bool:
	if _xr == null or _passthrough_claimed:
		return _passthrough_claimed
	var modes: Array = _xr.get_supported_environment_blend_modes()
	var alpha_supported := XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in modes
	if not alpha_supported and Engine.has_singleton(_META_PASSTHROUGH_CLASS):
		var meta_wrapper := Engine.get_singleton(_META_PASSTHROUGH_CLASS)
		if (
			meta_wrapper != null
			and meta_wrapper.has_method("is_passthrough_supported")
			and meta_wrapper.is_passthrough_supported()
		):
			# Quest exposes passthrough through XR_FB_passthrough and Godot's
			# vendors extension emulates alpha composition after session setup.
			if meta_wrapper.has_method("start_passthrough"):
				meta_wrapper.start_passthrough()
			alpha_supported = true
	if not alpha_supported:
		return false
	if not _xr.set_environment_blend_mode(XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND):
		return false
	get_viewport().transparent_bg = true
	add_to_group(_PASSTHROUGH_CLAIM_GROUP)
	_passthrough_claimed = true
	print_verbose("OpenXRBootstrap: native passthrough AR enabled.")
	return true


func _on_native_session_begun() -> void:
	if not start_in_passthrough or _passthrough_claimed:
		return
	_passthrough_retry_count = 0
	if not _claim_native_passthrough():
		_schedule_passthrough_retry()


func _schedule_passthrough_retry() -> void:
	if _passthrough_retry_pending or _passthrough_claimed:
		return
	if _passthrough_retry_count >= _PASSTHROUGH_RETRY_LIMIT:
		print_verbose("OpenXRBootstrap: passthrough is unavailable; staying in opaque VR.")
		return
	_passthrough_retry_pending = true
	get_tree().create_timer(0.1).timeout.connect(_retry_native_passthrough)


func _retry_native_passthrough() -> void:
	_passthrough_retry_pending = false
	if not is_inside_tree() or not start_in_passthrough or _passthrough_claimed:
		return
	_passthrough_retry_count += 1
	if not _claim_native_passthrough():
		_schedule_passthrough_retry()


func _release_native_passthrough() -> void:
	if not _passthrough_claimed:
		return
	remove_from_group(_PASSTHROUGH_CLAIM_GROUP)
	_passthrough_claimed = false
	if get_tree() and not get_tree().get_nodes_in_group(_PASSTHROUGH_CLAIM_GROUP).is_empty():
		return
	_set_native_opaque()


func _set_native_opaque() -> void:
	if _xr:
		var modes: Array = _xr.get_supported_environment_blend_modes()
		if XRInterface.XR_ENV_BLEND_MODE_OPAQUE in modes:
			_xr.set_environment_blend_mode(XRInterface.XR_ENV_BLEND_MODE_OPAQUE)
	if get_viewport():
		get_viewport().transparent_bg = false


## Turn on simultaneous hands + controllers via the vendors plugin's extension
## wrapper (registered as an Engine singleton). Looked up by name so this
## script parses and runs in projects without the plugin installed.
func _resume_multimodal() -> void:
	if not Engine.has_singleton(_MULTIMODAL_CLASS):
		return
	var wrapper := Engine.get_singleton(_MULTIMODAL_CLASS)
	if wrapper == null or not wrapper.has_method("is_simultaneous_hands_and_controllers_supported"):
		return
	if not wrapper.is_simultaneous_hands_and_controllers_supported():
		print_verbose("OpenXRBootstrap: simultaneous hands+controllers not supported by this runtime.")
		return
	wrapper.resume_simultaneous_hands_and_controllers_tracking()
	print_verbose("OpenXRBootstrap: simultaneous hands+controllers tracking resumed.")


func _on_presented() -> void:
	_presented = true  # a headset is actually showing the scene - stay in XR.


## Is the HMD actually tracking right now? The most reliable "headset is on"
## signal - the session_visible/focused signal often fires before we connect
## (the editor inits OpenXR at startup), so we can't rely on the flag alone.
func _hmd_tracking() -> bool:
	var head := XRServer.get_tracker(&"head") as XRPositionalTracker
	if head == null:
		return false
	var pose := head.get_pose(&"default")
	return pose != null and pose.has_tracking_data


## No headset showed up in time: revert to flat/desktop so the XR Simulator can
## drive the scene instead of leaving the viewport stuck on a dead XR display.
func _check_flat_fallback() -> void:
	if _xr == null or get_viewport() == null or get_viewport().use_xr == false:
		return
	if _presented or _hmd_tracking():
		return  # a headset is on and presenting - stay in XR.
	_release_native_passthrough()
	get_viewport().use_xr = false
	_set_group_hidden(false)
	_xr = null  # released - _exit_tree won't re-toggle
	session_ended.emit()
	print_verbose("OpenXRBootstrap: no headset presented; running flat with the XR Simulator.")


func _exit_tree() -> void:
	if _xr != null and get_viewport() != null:
		_release_native_passthrough()
		# XRSceneRouter adds the incoming scene before releasing this one. Do
		# not drop viewport.use_xr when another initialized bootstrap has
		# already claimed it, or the compositor flashes its previous frame.
		var replacement_is_active := false
		for bootstrap in get_tree().get_nodes_in_group(_ACTIVE_BOOTSTRAP_GROUP):
			if bootstrap != self and bootstrap.get("_xr") != null:
				replacement_is_active = true
				break
		if not replacement_is_active:
			get_viewport().use_xr = false
			_set_group_hidden(false)


func _set_group_hidden(hidden: bool) -> void:
	if session_hide_group.is_empty():
		return
	for node in get_tree().get_nodes_in_group(session_hide_group):
		if node is CanvasItem:
			node.visible = not hidden
