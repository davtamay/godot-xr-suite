@icon("res://addons/godot_webxr_kit/icons/webxr_input_adapter.svg")
class_name WebXRInputAdapter
extends "res://addons/godot_xr_interaction_toolkit/runtime/input/xr_controller_hand_adapter.gd"

## WebXR select source. Resolves the browser interface's selectstart / selectend /
## squeezestart / squeezeend to handedness and feeds them into the shared
## controller + hand adapter base. Poses, hand ray, bare-hand pinch, and
## stabilization all live in the base (XRControllerHandAdapter) - this file only
## adds where select/activate come from on WebXR. Inert outside web exports.

var _webxr

# Active transient pointers (visionOS gaze+pinch) per hand: while one is
# pinching, its target ray IS the user's gaze and outranks every hand- or
# controller-derived ray. Value = the input source's tracker.
var _transient_trackers := {}

# The persistent gaze source (Meta VR Glasses): targetRayMode 'gaze', no select
# events, no gamepad, in a generic slot from 2 up. Searched at a slow rate and
# checked every frame once found, so a device with no gaze pays only the scan.
const _GAZE_TARGET_RAY_MODE := 1
const _FIRST_GENERIC_SLOT := 2
const _LAST_SLOT := 15
const _GAZE_SCAN_MSEC := 500
const _GAZE_BRIDGE := "GodotWebXRGazeBridge"
var _gaze_slot := -1
var _gaze_next_scan_msec := 0
var _gaze_seen := false
var _gaze_listed := false
var _gaze_bridge_installed := false


func _ready() -> void:
	_resolve_rig()
	if not OS.has_feature("web"):
		# The OpenXR adapter owns the native path. Also stop the base's
		# _process, or BOTH adapters run the synthetic pinch detector in
		# parallel (duplicate events/compute).
		set_process(false)
		return

	_webxr = XRServer.find_interface("WebXR")
	if _webxr == null:
		return

	_connect_interface_signal(&"selectstart", _on_selectstart)
	_connect_interface_signal(&"selectend", _on_selectend)
	_connect_interface_signal(&"squeezestart", _on_squeezestart)
	_connect_interface_signal(&"squeezeend", _on_squeezeend)


func _connect_interface_signal(signal_name: StringName, callback: Callable) -> void:
	if not _webxr.has_signal(signal_name):
		push_warning("WebXR signal unavailable in this Godot build: %s" % signal_name)
		return
	if not _webxr.is_connected(signal_name, callback):
		_webxr.connect(signal_name, callback)


func _on_selectstart(input_source_id: int) -> void:
	var hand_id := _hand_for_input_source(input_source_id)
	if hand_id >= 0:
		if _is_transient_pointer(input_source_id):
			# Capture the gaze ray BEFORE emitting: interactors read the aim
			# pose while handling the select, and it must already be the
			# transient ray, not the hand's.
			_transient_trackers[hand_id] = _webxr.get_input_source_tracker(input_source_id)
		_emit_select_started(hand_id, HARDWARE_SELECT)
	else:
		_broadcast_select_started(HARDWARE_SELECT)


func _on_selectend(input_source_id: int) -> void:
	var hand_id := _hand_for_input_source(input_source_id)
	if hand_id >= 0:
		_emit_select_ended(hand_id, HARDWARE_SELECT)
		# Released AFTER the emit so the release still resolves against the
		# gaze ray it was aimed with.
		_transient_trackers.erase(hand_id)
	else:
		_broadcast_select_ended(HARDWARE_SELECT)


func _is_transient_pointer(input_source_id: int) -> bool:
	if not _webxr.has_method("get_input_source_target_ray_mode"):
		return false
	# 4 = TARGET_RAY_MODE_TRANSIENT_POINTER. Numeric so the suite still runs
	# on engines whose WebXRInterface predates the constant (stock Godot
	# reports such sources as UNKNOWN and never returns 4).
	return _webxr.get_input_source_target_ray_mode(input_source_id) == 4


## While a transient pointer is pinching, its target ray outranks the base's
## hand/controller resolution for that hand.
func get_aim_pose(hand_id: int) -> Dictionary:
	var transient := _transient_aim_pose(hand_id)
	if not transient.is_empty():
		return transient
	return super.get_aim_pose(hand_id)


func _transient_aim_pose(hand_id: int) -> Dictionary:
	var tracker: XRPositionalTracker = _transient_trackers.get(hand_id)
	if tracker == null or _origin == null:
		return {}
	var pose := tracker.get_pose(&"default")
	if pose == null or not pose.has_tracking_data:
		return {}
	var xf := _origin.global_transform * pose.transform
	return {
		"origin": xf.origin,
		"direction": (-xf.basis.z).normalized(),
		"basis": xf.basis.orthonormalized(),
	}


## The glue drops a source for any frame getPose() returns null and removes its
## tracker, so from here a blink looks exactly like the source being unplugged.
## The two must stay apart: a blink keeps gaze in charge for a grace period, a
## disconnect hands far targeting back at once. Only the browser's own list can
## tell them apart, so while a source that was seen has no slot,
## session.inputSources decides.
func get_gaze_state() -> Dictionary:
	if _webxr == null:
		return super()
	# Ending a session stops updating input sources but leaves their trackers, so
	# the last gaze pose would read as live on the flat page.
	if not _webxr.is_initialized():
		_gaze_slot = -1
		_gaze_seen = false
		_gaze_listed = false
		return super()
	_install_gaze_bridge()
	if _gaze_slot >= 0 and not _webxr.is_input_source_active(_gaze_slot):
		_gaze_slot = -1
		_gaze_next_scan_msec = 0
	var now := XRClock.now_msec()
	if _gaze_slot < 0 and now >= _gaze_next_scan_msec:
		_gaze_next_scan_msec = now + _GAZE_SCAN_MSEC
		_gaze_slot = _find_gaze_slot()
		if _gaze_slot >= 0:
			_gaze_seen = true
			_gaze_listed = true
		else:
			_gaze_listed = _gaze_seen and _browser_lists_gaze_source()
			_gaze_seen = _gaze_listed
	if _gaze_slot >= 0:
		return _gaze_state_from(_webxr.get_input_source_tracker(_gaze_slot))
	if _gaze_listed:
		return {"connected": true, "tracked": false}
	# Not the browser's: the actuator can publish on a device with no gaze.
	return super()


func _find_gaze_slot() -> int:
	for slot in range(_FIRST_GENERIC_SLOT, _LAST_SLOT + 1):
		if _webxr.get_input_source_target_ray_mode(slot) == _GAZE_TARGET_RAY_MODE:
			return slot
	return -1


## Installed on first use, so a scene without a gaze block never wraps the frame.
func _install_gaze_bridge() -> void:
	if _gaze_bridge_installed:
		return
	_gaze_bridge_installed = true
	XRWebJSHook.install(_GAZE_BRIDGE, "{session: null}", "", "bridge.session = frame.session;")


func _browser_lists_gaze_source() -> bool:
	return bool(JavaScriptBridge.eval("""
(function () {
	const bridge = window.%s;
	const session = bridge && bridge.session;
	if (!session) { return false; }
	for (const source of session.inputSources) {
		if (source.targetRayMode === 'gaze') { return true; }
	}
	return false;
}())
""" % _GAZE_BRIDGE, true))


func _on_squeezestart(input_source_id: int) -> void:
	var hand_id := _hand_for_input_source(input_source_id)
	if hand_id >= 0:
		_emit_activate_started(hand_id, HARDWARE_SELECT)
	else:
		_broadcast_activate_started(HARDWARE_SELECT)


func _on_squeezeend(input_source_id: int) -> void:
	var hand_id := _hand_for_input_source(input_source_id)
	if hand_id >= 0:
		_emit_activate_ended(hand_id, HARDWARE_SELECT)
	else:
		_broadcast_activate_ended(HARDWARE_SELECT)


func _hand_for_input_source(input_source_id: int) -> int:
	if _webxr == null:
		return -1

	var tracker = _webxr.get_input_source_tracker(input_source_id)
	if tracker == null:
		return -1

	var hand_id := XRHandIdentity.from_tracker_hand(tracker.hand)
	if XRHandIdentity.is_valid(hand_id):
		return hand_id
	# TRACKER_HAND_UNKNOWN: fall back to the tracker NAME ("left_hand",
	# "/user/hand_tracker/left"...). The old fallback stringified the enum
	# INT and searched it for "left" - a digit never contains a side word,
	# so it had never fired and every unknown-handed source broadcast its
	# selects to BOTH hands.
	return XRHandIdentity.from_text(str(tracker.name))
