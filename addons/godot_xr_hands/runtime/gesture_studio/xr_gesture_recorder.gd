@tool
@icon("res://addons/godot_xr_hands/icons/xr_gesture_recognizer.svg")
class_name XRGestureRecorder
extends Node

## Record-first gesture authoring: hold a pose, get a gesture. The recorder
## counts down, samples the hand's feature stream for a capture window, and
## derives an XRHandGesture whose targets are the observed means and whose
## tolerances come from YOUR OWN jitter - steadier hands make tighter
## gestures automatically. Recordings save as .tres under user://gestures and
## reload on the next run.
##
## PERSISTENCE IS PLATFORM-DEPENDENT - be explicit with users:
## - Web: user:// is the browser's site storage (IndexedDB). Recordings live
##   in THAT browser on THAT device and are erased when the user clears
##   browsing data. Good for per-user personalization, not for authoring.
## - Native / editor (incl. Quest Link): user:// is a real folder on disk -
##   recordings are ordinary .tres files. THE AUTHORING PIPELINE: record over
##   Link, copy the files into your project (or point save_directory at a
##   res:// folder while in the editor) and ship them as presets.
##
## Needs an XRGestureRecognizer in the scene (it supplies the live features -
## one extraction pass shared by recognition, debug HUD, and recording).

## state: "countdown" | "waiting" | "capturing" | "done" | "failed";
## seconds_left counts the current stage down for UI display. "waiting" =
## the countdown finished but no hand is tracked yet - the recorder holds
## until one appears (browsers hand over from controllers to hands with a
## delay of seconds; a fixed window would expire before the hand exists).
signal recording_state_changed(state: String, seconds_left: float)
## The derived gesture (already saved to save_path; "" if saving failed).
signal recording_finished(gesture: XRHandGesture, save_path: String)

const _FeatureExtractor := preload("res://addons/godot_xr_hands/runtime/gesture_studio/xr_hand_feature_extractor.gd")
const XRHandTrackerResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")

## The recognizer supplying live features (found by class in the scene when
## left empty).
@export var recognizer_path: NodePath

@export_range(1.0, 10.0, 0.5) var countdown_seconds := 3.0
@export_range(0.5, 5.0, 0.5) var capture_seconds := 2.0

## How long to WAIT for a tracked hand after the countdown before giving up
## (put-the-controller-down handovers take a few seconds on browsers).
@export_range(3.0, 30.0, 1.0) var wait_for_hand_seconds := 15.0

## Append the recorded gesture to the recognizer's library immediately - it
## is performable the moment recording ends.
@export var auto_add_to_recognizer := true

## Where recordings persist ("" = don't save).
@export var save_directory := "user://gestures"

## Reload previously saved recordings into the recognizer at startup.
@export var load_saved_on_ready := true

## Tolerances never go below this (raw jitter on a steady hand is optimistic).
@export_range(0.05, 0.4, 0.01) var min_tolerance := 0.12

## Pinch features join the gesture only when strongly expressed (mean above
## this) - a relaxed hand's incidental pinch values would over-constrain.
@export_range(0.0, 1.0, 0.05) var include_pinch_threshold := 0.7

var _recognizer: XRGestureRecognizer
var _state := ""
var _gesture_name := ""
var _hand := 0
var _time_left := 0.0
var _samples := {}
var _joint_frames: Array[PackedVector3Array] = []


## Wrist-local joint positions this frame - the gesture's visual snapshot
## (the median frame is kept, so a blink of bad tracking cannot poison it).
## In BOTH mode only the right hand feeds the snapshot (one chirality).
func _capture_joint_frame(capture_hand: int) -> void:
	if _hand == 2 and capture_hand != 1:
		return
	var tracker := XRHandTrackerResolver.get_tracker(capture_hand)
	if tracker == null or not tracker.has_tracking_data:
		return
	var wrist_inverse := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST).affine_inverse()
	var frame := PackedVector3Array()
	frame.resize(XRHandTracker.HAND_JOINT_MAX)
	for joint in XRHandTracker.HAND_JOINT_MAX:
		frame[joint] = wrist_inverse * tracker.get_hand_joint_transform(joint).origin
	_joint_frames.append(frame)


func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return
	set_process(false)
	if load_saved_on_ready:
		_load_saved.call_deferred()


func is_recording() -> bool:
	return _state == "countdown" or _state == "waiting" or _state == "capturing"


## Begin the countdown-then-capture flow. hand: 0 = left, 1 = right,
## 2 = BOTH - a symmetric pose sampled from both hands at once feeds one
## gesture with twice the data (features are chirality-agnostic), and the
## derived tolerances cover the natural left/right variation.
func start_recording(gesture_name: String, hand: int) -> void:
	if is_recording() or not _resolve_recognizer():
		return
	_gesture_name = gesture_name
	_hand = clampi(hand, 0, 2)
	_samples = {}
	_joint_frames = []
	_state = "countdown"
	_time_left = countdown_seconds
	set_process(true)
	recording_state_changed.emit(_state, _time_left)


func _process(delta: float) -> void:
	if not is_recording():
		set_process(false)
		return
	if _state == "countdown":
		_time_left -= delta
		if _time_left > 0.0:
			recording_state_changed.emit(_state, _time_left)
			return
		_state = "waiting"
		_time_left = wait_for_hand_seconds
		recording_state_changed.emit(_state, _time_left)
		return

	# waiting / capturing: sample whatever hand data exists this frame.
	var sampled := false
	var capture_hands := [0, 1] if _hand == 2 else [_hand]
	for capture_hand in capture_hands:
		var features: Dictionary = _recognizer.get_features(capture_hand)
		if features.is_empty():
			# Self-sufficient fallback: read the tracker directly, so
			# recording never depends on the recognizer's process state.
			var tracker := XRHandTrackerResolver.get_tracker(capture_hand)
			features = _FeatureExtractor.extract(tracker, capture_hand)
		for feature in features:
			if not _samples.has(feature):
				# Plain Arrays on purpose: PackedFloat32Array inside a
				# Dictionary is copy-on-write - appends land on a temporary
				# copy and VANISH (this project's oldest gotcha).
				_samples[feature] = []
			(_samples[feature] as Array).append(features[feature])
		if not features.is_empty():
			sampled = true
			_capture_joint_frame(capture_hand)

	if _state == "waiting":
		if sampled:
			# The hand arrived - NOW the capture window starts.
			_state = "capturing"
			_time_left = capture_seconds
		else:
			_time_left -= delta
			if _time_left <= 0.0:
				_state = "failed"
				set_process(false)
		recording_state_changed.emit(_state, maxf(_time_left, 0.0))
		return

	# capturing: the window only advances while data flows, so a tracking
	# blink stretches the window instead of starving it.
	if sampled:
		_time_left -= delta
	recording_state_changed.emit(_state, maxf(_time_left, 0.0))
	if _time_left <= 0.0:
		_finish()


func _finish() -> void:
	set_process(false)
	var sample_count: int = (_samples.get("curl_index", []) as Array).size()
	if sample_count < 10:
		_state = "failed"
		recording_state_changed.emit(_state, 0.0)
		return

	var gesture := XRHandGesture.new()
	gesture.gesture_name = _gesture_name
	gesture.recorded_hand = 1 if _hand == 2 else _hand
	var conditions: Dictionary[String, Vector2] = {}
	for feature in _samples:
		var values: Array = _samples[feature]
		var mean := 0.0
		var low: float = values[0]
		var high: float = values[0]
		for value in values:
			mean += value
			low = minf(low, value)
			high = maxf(high, value)
		mean /= values.size()
		# Curls define the pose; pinches join only when strongly expressed;
		# palm orientation is deliberately left out (poses should work at any
		# angle unless authored otherwise in the inspector).
		var include: bool = feature.begins_with("curl_")
		if feature.begins_with("pinch_") and mean >= include_pinch_threshold:
			include = true
		if not include:
			continue
		var tolerance := maxf(min_tolerance, (high - low) * 0.5 + 0.08)
		conditions[feature] = Vector2(snappedf(mean, 0.01), snappedf(tolerance, 0.01))
	gesture.conditions = conditions
	if not _joint_frames.is_empty():
		gesture.joint_snapshot = _joint_frames[_joint_frames.size() / 2]

	var save_path := ""
	if not save_directory.is_empty():
		DirAccess.make_dir_recursive_absolute(save_directory)
		save_path = "%s/%s.tres" % [save_directory, _gesture_name]
		if ResourceSaver.save(gesture, save_path) != OK:
			save_path = ""
	if auto_add_to_recognizer:
		# Re-recording a name replaces the old definition.
		var replaced := false
		for i in _recognizer.gestures.size():
			if _recognizer.gestures[i] and _recognizer.gestures[i].gesture_name == _gesture_name:
				_recognizer.gestures[i] = gesture
				replaced = true
				break
		if not replaced:
			_recognizer.gestures.append(gesture)

	_state = "done"
	recording_state_changed.emit(_state, 0.0)
	recording_finished.emit(gesture, save_path)


func _load_saved() -> void:
	if save_directory.is_empty() or not _resolve_recognizer():
		return
	var dir := DirAccess.open(save_directory)
	if dir == null:
		return
	var known := {}
	for existing in _recognizer.gestures:
		if existing:
			known[existing.gesture_name] = true
	for file in dir.get_files():
		if not file.ends_with(".tres"):
			continue
		var gesture := ResourceLoader.load("%s/%s" % [save_directory, file]) as XRHandGesture
		if gesture and not known.has(gesture.gesture_name):
			_recognizer.gestures.append(gesture)
			recording_finished.emit(gesture, "%s/%s" % [save_directory, file])


func _resolve_recognizer() -> bool:
	if _recognizer and is_instance_valid(_recognizer):
		return true
	_recognizer = get_node_or_null(recognizer_path) as XRGestureRecognizer
	if _recognizer == null:
		for node in get_tree().current_scene.find_children("*", "Node", true, false):
			if node is XRGestureRecognizer:
				_recognizer = node
				break
	return _recognizer != null
