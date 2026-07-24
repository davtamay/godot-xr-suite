@tool
class_name XRHandTraceRecorder
extends Node

## Drop into a running scene to capture RAW hand frames to disk. Records
## upstream of all conditioning, so a trace stays a valid baseline no matter
## how the filter is later retuned.

## 0 = left, 1 = right.
@export var hand := 1
@export var auto_start := false
## Where stop_and_save writes by default.
@export var output_path := "user://hand_traces/trace.res"

var _trace: XRHandTrace
var _source: XRTrackerHandPoseSource
var _frame := XRHandFrame.new()
var _recording := false
var _last_wrist_transform := Transform3D.IDENTITY
var _has_wrist_sample := false

func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return
	_source = XRTrackerHandPoseSource.new()
	if auto_start:
		start()

func start() -> void:
	_trace = XRHandTrace.new()
	_has_wrist_sample = false
	_recording = true

func is_recording() -> bool:
	return _recording

func frame_count() -> int:
	return _trace.size() if _trace else 0

func stop_and_save(path := "") -> Error:
	_recording = false
	if _trace == null or _trace.size() == 0:
		push_warning("XRHandTraceRecorder: nothing recorded")
		return ERR_DOES_NOT_EXIST
	var target := path if not path.is_empty() else output_path
	DirAccess.make_dir_recursive_absolute(target.get_base_dir())
	var result := _trace.save(target)
	if result == OK:
		print("XRHandTraceRecorder: wrote %d frames to %s" % [_trace.size(), target])
	return result

## Dedup gate: true (and records the sample as "last seen") the first time a
## wrist pose is observed and every time it differs from the previously kept
## one; false when the wrist joint is unchanged. Kept as a small standalone
## method -- rather than inlined in _process -- so it can be exercised
## directly in tests without a live tracker.
func _should_record(frame: XRHandFrame) -> bool:
	var wrist := frame.joint_transforms[XRHandTracker.HAND_JOINT_WRIST]
	if _has_wrist_sample and wrist.is_equal_approx(_last_wrist_transform):
		return false
	_last_wrist_transform = wrist
	_has_wrist_sample = true
	return true

func _process(_delta: float) -> void:
	if not _recording or _source == null:
		return
	var timestamp := Time.get_ticks_usec()
	if not _source.capture(hand, timestamp, _frame):
		return
	# The raw tracker can be polled faster than it updates; do not record a
	# frame twice or the replayed pacing stops matching reality. Dedup on the
	# raw wrist transform, not the timestamp: XRTrackerHandPoseSource.capture()
	# writes back whatever timestamp the caller passed, and _process passes a
	# fresh Time.get_ticks_usec() on every tick, so the timestamp is unique by
	# construction and can never detect a repeated sample. The timestamp
	# itself is still correct to record -- it is when this new sample was
	# observed, which is exactly the pacing a replay must reproduce.
	if not _should_record(_frame):
		return
	_trace.append_frame(_frame)
