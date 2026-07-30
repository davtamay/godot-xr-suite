@tool
@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_locomotion.svg")
class_name XRMicrogestureLocomotionDriver
extends Node

## Thumb-microgesture locomotion driving the SAME teleport arc, marker, and
## snap turn as the thumbsticks - one locomotion system, many inputs.
##
## Powered by the hands addon's sequence recognition (godot_xr_hands
## gesture_studio; soft dependency - inert when that addon is absent):
##   thumb swipe LEFT / RIGHT  = snap turn
##   thumb swipe FORWARD       = aim the teleport arc (hand ray)
##   thumb swipe BACKWARD      = commit
##   thumb TAP                 = aim / commit toggle
## Rest your thumb on the side of your index finger and swipe - the Meta
## microgesture vocabulary, recognized from joints, working in the browser.

## The PROVEN thumb recognizer (phase state machine with posture gating -
## refined on-headset over many sessions) stays the microgesture engine;
## the gesture_studio sequence framework serves authored motion gestures
## and replaces this only when it matches this reliability on-device.
const _RUNTIME_SCRIPT := "res://addons/godot_xr_hands/runtime/recognition/xr_gesture_runtime.gd"
const _RECOGNIZER_SCRIPT := "res://addons/godot_xr_hands/runtime/recognition/xr_thumb_microgesture_recognizer.gd"
const _NATIVE_SOURCE_SCRIPT := "res://addons/godot_xr_hands/runtime/recognition/xr_native_microgesture_source.gd"

@export var enabled := true

## PLATFORM mode: consume the RUNTIME's microgesture detector, per hand,
## once it has proven live (first native event seen for that hand) -- on
## runtimes advertising XR_META_hand_tracking_microgestures (standalone
## Quest, measured) that is the same detector Meta's own apps use, and it
## also emits FORWARD/BACKWARD, which the joint recognizer does not.
## PORTABLE mode (false, the DEFAULT): the platform source is ignored
## entirely and the joint recognizer drives -- the exact code path WebXR,
## Galaxy XR / Android XR, Link, and every non-Meta runtime run. It
## defaults OFF deliberately: this suite's target is the portable path,
## and testing on a Quest with the extension active measures Meta's
## recognizer, not ours -- a false read on what every other device ships
## (David's call, 2026-07-26). Flip it per driver here, or session-wide in
## the headset via feel_check / session_platform_override.
@export var use_platform_microgestures := false

## Session-wide A/B override for in-headset comparison (feel_check pokes
## this): -1 respects each driver's use_platform_microgestures; 0 forces
## PORTABLE; 1 forces PLATFORM. Static so the choice survives scene
## streaming within a session.
static var session_platform_override := -1

## Optional; empty resolves to the scene's XRLocomotion by group.
@export var locomotion_path: NodePath

@export_group("Detection")
## The recognizer is built at runtime; these forward its most-tuned reliability
## knobs so you can adjust feel without reaching an internal node. Contact =
## how close the thumb must come to arm a swipe (lower = easier); release above
## the second value.
@export_range(0.05, 1.5, 0.01) var contact_threshold := 0.40
@export_range(0.05, 2.0, 0.01) var release_threshold := 0.46
## Fingers must be at least this curled (fist gate) to count as a microgesture.
@export_range(0.0, 1.0, 0.01) var minimum_finger_curl := 0.28
## Hand-tracking confidence floor; raise if false swipes fire on poor tracking.
@export_range(0.0, 1.0, 0.01) var minimum_tracking_quality := 0.36
## Seconds between recognized gestures.
@export_range(0.0, 2.0, 0.01) var cooldown := 0.18

const _FORWARDED := ["contact_threshold", "release_threshold", "minimum_finger_curl",
	"minimum_tracking_quality", "cooldown"]

## Relay of the ACTIVE source's rejection feedback (see
## XRMicrogestureSource.gesture_rejected): one emission per gesture attempt
## the recognizer saw and discarded, with the reason. Consumers (feedback
## haptics, the Feel Check bench's counters) connect HERE, not to the
## driver's internal children -- the driver owns the per-hand source mux, so
## it is the only node that knows which source's chatter is authoritative.
## In platform mode a proven hand emits no rejections at all: the runtime
## detector publishes only successes.
signal source_gesture_rejected(hand: int, reason: int)

var _locomotion: Node
var _recognizer: Node
var _native: Node
## Hands the runtime detector has proven live for (first native event seen).
## Once true, joint-recognizer events for that hand are dropped -- both
## sources see the same physical gesture, and acting on both would
## double-fire every swipe.
var _platform_hands := {}


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if not ResourceLoader.exists(_RECOGNIZER_SCRIPT) or not ResourceLoader.exists(_RUNTIME_SCRIPT):
		return  # Hands addon not installed; microgesture locomotion stays off.
	var runtime: Node = (load(_RUNTIME_SCRIPT) as GDScript).new()
	runtime.name = "GestureRuntime"
	add_child(runtime)
	_recognizer = (load(_RECOGNIZER_SCRIPT) as GDScript).new()
	_recognizer.name = "ThumbRecognizer"
	_recognizer.set("hand", -1)
	_recognizer.set("gesture_runtime_path", NodePath("../GestureRuntime"))
	for prop in _FORWARDED:
		_recognizer.set(prop, get(prop))
	add_child(_recognizer)
	if _recognizer.has_signal("gesture_performed"):
		_recognizer.connect("gesture_performed", _on_recognizer_gesture)
	if _recognizer.has_signal("gesture_rejected"):
		_recognizer.connect("gesture_rejected", _on_recognizer_rejected)
	if ResourceLoader.exists(_NATIVE_SOURCE_SCRIPT):
		_native = (load(_NATIVE_SOURCE_SCRIPT) as GDScript).new()
		_native.name = "NativeMicrogestures"
		add_child(_native)
		if _native.has_signal("gesture_performed"):
			_native.connect("gesture_performed", _on_native_gesture)


## True when platform mode is in effect for this driver, override included.
func platform_mode_active() -> bool:
	if session_platform_override >= 0:
		return session_platform_override == 1
	return use_platform_microgestures


func _on_native_gesture(gesture: int, hand: int, confidence: float) -> void:
	if not platform_mode_active():
		# PORTABLE mode ignores the platform source outright -- letting both
		# through would double-fire every physical gesture on a runtime that
		# detects them too.
		return
	_platform_hands[hand] = true
	_on_gesture(gesture, hand, confidence)


func _on_recognizer_gesture(gesture: int, hand: int, confidence: float) -> void:
	if platform_mode_active() and _platform_hands.get(hand, false):
		return
	_on_gesture(gesture, hand, confidence)


func _on_recognizer_rejected(hand: int, reason: int) -> void:
	# Mirrors the performed-path mux exactly: once a hand is platform-proven,
	# the joint recognizer's rejections are as non-authoritative as its
	# successes -- relaying them would buzz the user about attempts the active
	# detector may well have accepted.
	if platform_mode_active() and _platform_hands.get(hand, false):
		return
	source_gesture_rejected.emit(hand, reason)


## Whether the source currently authoritative for `hand` can ever emit
## `gesture`. The portable recognizer has no FORWARD/BACKWARD, so in portable
## mode the aim-toggle/commit swipe mappings above are reachable only through
## TAP -- consumers use this to say "forward swipe not available here"
## instead of leaving the user swiping into dead air. Optimistic (true) when
## no source is built yet or a source predates the contract: absent evidence,
## claim what was always implicitly claimed.
func supports_gesture(gesture: int, hand: int) -> bool:
	var source: Node = _recognizer
	if platform_mode_active() and _platform_hands.get(hand, false):
		source = _native
	if source == null or not source.has_method("get_supported_gestures"):
		return true
	return gesture in source.get_supported_gestures()


func _on_gesture(gesture: int, hand: int, _confidence: float) -> void:
	if not enabled or not _resolve_locomotion():
		return
	# Gesture order matches XRMicrogestureSource.Gesture:
	# LEFT, RIGHT, FORWARD, BACKWARD, TAP.
	match gesture:
		0:
			_locomotion.do_snap_turn(1.0)
		1:
			_locomotion.do_snap_turn(-1.0)
		2:
			# Forward TOGGLES the aim, so a second swipe (or a noisy repeat)
			# dismisses the arc instead of leaving it stuck on.
			if _locomotion.is_aiming(hand):
				_locomotion.cancel_teleport(hand)
			else:
				_locomotion.begin_teleport_aim(hand)
		3:
			_locomotion.commit_teleport(hand)
		4:
			if _locomotion.is_aiming(hand):
				_locomotion.commit_teleport(hand)
			else:
				_locomotion.begin_teleport_aim(hand)


func _resolve_locomotion() -> bool:
	if _locomotion and is_instance_valid(_locomotion):
		return true
	_locomotion = get_node_or_null(locomotion_path)
	if _locomotion == null:
		_locomotion = get_tree().get_first_node_in_group(XRLocomotion.GROUP)
	return _locomotion != null
