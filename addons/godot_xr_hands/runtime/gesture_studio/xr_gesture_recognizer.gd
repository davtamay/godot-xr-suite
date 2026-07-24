@tool
@icon("res://addons/godot_xr_hands/icons/xr_gesture_recognizer.svg")
class_name XRGestureRecognizer
extends Node

const XRHandFeatureExtractor := preload("res://addons/godot_xr_hands/runtime/gesture_studio/xr_hand_feature_extractor.gd")
const _DebugPanel := preload("res://addons/godot_xr_hands/runtime/gesture_studio/xr_gesture_debug_panel.gd")
const XRHandTrackerResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")

## Drop-in hand gesture recognition: assign XRHandGesture resources (or use
## the presets in runtime/gestures/presets/) and connect to the signals. Both
## hands are tracked independently; the same gesture resource matches either
## hand (features are chirality-corrected in the extractor).
##
## Reliability built in: entry tolerance + hysteresis on release (per
## gesture), hold-time debounce, and tracking-loss ends active gestures
## cleanly. show_debug displays every feature value live - the fastest way to
## tune a gesture's numbers on-headset.

## A gesture began / ended on a hand (0 = left, 1 = right).
signal gesture_started(gesture_name: String, hand: int)
signal gesture_ended(gesture_name: String, hand: int)
## A motion sequence (swipe, tap - see XRHandSequence) completed on a hand.
signal sequence_performed(sequence_name: String, hand: int)

@export var enabled := true

## The gesture library this recognizer matches.
@export var gestures: Array[XRHandGesture] = []

## Motion sequences (thumb swipes/taps) matched alongside the static poses.
@export var sequences: Array[XRHandSequence] = []

## Camera (head) used for the palm_toward_head feature; found automatically
## when left empty.
@export var camera_path: NodePath

## Live per-feature readout on a head-anchored label - the tuning tool.
@export var show_debug := false

## When set, the debug bars validate against THIS gesture (by name) instead
## of the nearest miss - select-a-reference workflows point it at the pose
## the user is trying to match.
@export var focus_gesture_name := ""

var _camera: Camera3D
var _origin: Node3D
var _active := [{}, {}]
var _hold := [{}, {}]
var _features := [{}, {}]
var _nearest := [{}, {}]
var _panels := [null, null]
var _sequence_state := [{}, {}]


func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return


func _process(delta: float) -> void:
	if not enabled:
		return
	_resolve_scene_refs()
	for hand in 2:
		var tracker := XRHandTrackerResolver.get_tracker(hand)
		var origin_xf := _origin.global_transform if _origin else Transform3D.IDENTITY
		var head: Variant = _camera.global_transform if _camera else null
		_features[hand] = XRHandFeatureExtractor.extract(tracker, hand, origin_xf, head)
		_update_hand(hand, delta)
		_update_sequences(hand, delta)
		if show_debug:
			_update_debug_panel(hand, tracker, origin_xf)
		elif _panels[hand]:
			(_panels[hand] as Node3D).visible = false


## The live feature dictionary for a hand ({} while untracked) - the recorder
## and debug tooling read this.
func get_features(hand: int) -> Dictionary:
	return _features[hand] if hand >= 0 and hand < 2 else {}


## Names of the gestures currently active on a hand.
func get_active_gestures(hand: int) -> Array:
	return _active[hand].keys() if hand >= 0 and hand < 2 else []


func _update_hand(hand: int, delta: float) -> void:
	var features: Dictionary = _features[hand]
	var nearest := {}
	for gesture in gestures:
		if gesture == null or gesture.gesture_name.is_empty():
			continue
		var name := gesture.gesture_name
		var is_active: bool = _active[hand].has(name)
		var failing := gesture.failing_features(features, is_active)
		# Debug HUD reference: the focused gesture when one is set, else the
		# closest non-matching gesture ("this is what blocks it" coloring).
		if name == focus_gesture_name and not features.is_empty():
			nearest = {"name": name, "failing": failing, "conditions": gesture.conditions, "focused": true}
		elif focus_gesture_name.is_empty() and not failing.is_empty() and not features.is_empty():
			if nearest.is_empty() or failing.size() < (nearest["failing"] as PackedStringArray).size():
				nearest = {"name": name, "failing": failing, "conditions": gesture.conditions}
		if failing.is_empty() and not gesture.conditions.is_empty():
			if is_active:
				continue
			var held: float = _hold[hand].get(name, 0.0) + delta
			_hold[hand][name] = held
			if held >= gesture.min_hold_seconds:
				_active[hand][name] = true
				gesture_started.emit(name, hand)
		else:
			_hold[hand].erase(name)
			if is_active:
				_active[hand].erase(name)
				gesture_ended.emit(name, hand)
	_nearest[hand] = nearest


## ---- sequences (motion gestures: swipes, taps) --------------------------------

func _update_sequences(hand: int, delta: float) -> void:
	var features: Dictionary = _features[hand]
	for sequence in sequences:
		if sequence == null or sequence.sequence_name.is_empty() or sequence.stages.is_empty():
			continue
		var states: Dictionary = _sequence_state[hand]
		var state: Dictionary = states.get_or_add(sequence.sequence_name, {"stage": 0, "time": 0.0, "motion_start": 0.0, "cooldown": 0.0})
		if state["cooldown"] > 0.0:
			state["cooldown"] = maxf(state["cooldown"] - delta, 0.0)
			continue
		if features.is_empty():
			_reset_sequence(state)
			continue
		var stage_index: int = state["stage"]
		var stage: Dictionary = sequence.stages[stage_index]
		if not sequence.stage_conditions_hold(stage_index, features):
			# Stage 0 simply waits for its entry conditions; later stages fail.
			# Either way the timer resets, so the motion baseline is recaptured
			# fresh when the entry conditions next hold.
			_reset_sequence(state)
			continue
		var motion_feature: String = stage.get("motion_feature", "")
		if state["time"] == 0.0 and not motion_feature.is_empty():
			state["motion_start"] = features.get(motion_feature, 0.0)
		state["time"] += delta
		var complete := true
		if not motion_feature.is_empty():
			var min_delta: float = stage.get("motion_min_delta", 0.3)
			var moved: float = (features.get(motion_feature, 0.0) as float) - (state["motion_start"] as float)
			complete = (moved >= min_delta) if min_delta >= 0.0 else (moved <= min_delta)
		if complete:
			state["stage"] = stage_index + 1
			state["time"] = 0.0
			if state["stage"] >= sequence.stages.size():
				state["stage"] = 0
				state["cooldown"] = sequence.cooldown_seconds
				sequence_performed.emit(sequence.sequence_name, hand)
		elif state["time"] > (stage.get("max_seconds", 0.5) as float):
			_reset_sequence(state)


func _reset_sequence(state: Dictionary) -> void:
	state["stage"] = 0
	state["time"] = 0.0


func _resolve_scene_refs() -> void:
	if _camera == null or not is_instance_valid(_camera):
		_camera = get_node_or_null(camera_path) as Camera3D
		if _camera == null:
			_camera = get_viewport().get_camera_3d()
	if _origin == null or not is_instance_valid(_origin):
		var cursor: Node = _camera
		while cursor != null and not (cursor is XROrigin3D):
			cursor = cursor.get_parent()
		_origin = cursor


## ---- debug HUD ----------------------------------------------------------------

## Per-hand bar panel above the wrist: five curl bars + pinch dot. Bars are
## green inside the nearest gesture's band, red when they block it.
func _update_debug_panel(hand: int, tracker: XRHandTracker, origin_xf: Transform3D) -> void:
	if _panels[hand] == null:
		_panels[hand] = _DebugPanel.new()
		add_child(_panels[hand])
	var panel: Node3D = _panels[hand]
	if tracker == null or not tracker.has_tracking_data:
		panel.visible = false
		return
	var anchor := origin_xf * tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST)
	panel.update_panel(anchor, _camera, _features[hand], get_active_gestures(hand), _nearest[hand])
