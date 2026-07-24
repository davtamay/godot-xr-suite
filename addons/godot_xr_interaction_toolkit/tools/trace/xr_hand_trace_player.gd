class_name XRHandTracePlayer
extends XRHandPoseSource

## Replays a recorded trace through the acquisition seam, so the whole
## conditioning chain runs headless with no headset attached.

var _trace: XRHandTrace
var _index := 0

func _init(trace: XRHandTrace = null) -> void:
	_trace = trace

func rewind() -> void:
	_index = 0

func remaining() -> int:
	if _trace == null:
		return 0
	return maxi(0, _trace.size() - _index)

## Ignores the passed timestamp and uses the recorded one, so replay reproduces
## the original frame pacing exactly -- which the filter depends on.
func capture(hand: int, _timestamp_usec: int, target: XRHandFrame) -> bool:
	if _trace == null or _index >= _trace.size():
		return false

	var entry: Dictionary = _trace.frames[_index]
	_index += 1

	target.begin_capture(hand, int(entry["timestamp_usec"]), _index)
	var transforms: Array = entry["transforms"]
	var radii: PackedFloat32Array = entry["radii"]
	var flags: PackedInt32Array = entry["flags"]
	for joint in range(XRHandFrame.JOINT_COUNT):
		target.set_joint(joint, transforms[joint], radii[joint], flags[joint])

	target.tracking_valid = bool(entry["tracking_valid"])
	return target.tracking_valid
