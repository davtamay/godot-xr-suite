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
var _last_timestamp := -1

func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return
	_source = XRTrackerHandPoseSource.new()
	if auto_start:
		start()

func start() -> void:
	_trace = XRHandTrace.new()
	_last_timestamp = -1
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

func _process(_delta: float) -> void:
	if not _recording or _source == null:
		return
	var timestamp := Time.get_ticks_usec()
	if not _source.capture(hand, timestamp, _frame):
		return
	# The raw tracker can be polled faster than it updates; do not record a
	# frame twice or the replayed pacing stops matching reality.
	if _frame.timestamp_usec == _last_timestamp:
		return
	_last_timestamp = _frame.timestamp_usec
	_trace.append_frame(_frame)
