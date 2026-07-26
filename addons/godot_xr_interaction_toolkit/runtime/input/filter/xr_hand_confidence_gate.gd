class_name XRHandConfidenceGate
extends XRHandPoseSource

## Tracking-loss policy in one place instead of the dozen ad-hoc
## has_tracking_data checks scattered across the suite.
##
## Sits UPSTREAM of the filter deliberately. Filtering first would make a
## dropout interpolate smoothly INTO the garbage pose and smoothly back out --
## a visible lurch in both directions, worse than the pop it replaced.

const _HANDS := 2

## How long a lost hand keeps reporting its last good pose before going invalid.
@export var hold_duration_sec := 0.25
## Below this many TRACKED joints (POSITION_VALID and POSITION_TRACKED both
## set -- see XRHandTrackerResolver.joint_position_tracked, the per-joint
## primitive this mirrors at the frame level) the hand counts as lost.
## Deliberately NOT valid_joint_count: OpenXR sets POSITION_VALID on a joint it
## is merely PREDICTING, so a hand out of view keeps every joint "valid" for
## as long as it stays unseen -- checking valid_joint_count here meant this
## gate never fired for exactly the case it exists to catch (confirmed
## empirically; see .superpowers/sdd/ray-through-conditioning-report.md).
@export var min_tracked_joints := 1

var _inner: XRHandPoseSource
var _raw := XRHandFrame.new()
var _last_good: Array[XRHandFrame] = []
var _has_good := [false, false]
var _lost_since_usec := [-1, -1]
var _discontinuity := [false, false]

func _init(inner: XRHandPoseSource = null) -> void:
	_inner = inner
	for hand in range(_HANDS):
		_last_good.append(XRHandFrame.new())

## True once per reacquisition. The filter resets on it so it snaps to the
## recovered pose rather than slewing from the stale held one.
func consume_discontinuity(hand: int) -> bool:
	if hand < 0 or hand >= _HANDS or not _discontinuity[hand]:
		return false
	_discontinuity[hand] = false
	return true

func capture(hand: int, timestamp_usec: int, target: XRHandFrame) -> bool:
	if _inner == null or hand < 0 or hand >= _HANDS:
		return false

	var tracked := _inner.capture(hand, timestamp_usec, _raw)
	if tracked and _raw.tracked_joint_count < min_tracked_joints:
		tracked = false

	var now := _raw.timestamp_usec if _raw.timestamp_usec > 0 else timestamp_usec

	if tracked:
		if not _has_good[hand] or _lost_since_usec[hand] >= 0:
			# First acquisition also counts: the filter has no history either way.
			_discontinuity[hand] = true
		_lost_since_usec[hand] = -1
		_has_good[hand] = true
		_raw.copy_into(_last_good[hand])
		_raw.copy_into(target)
		return true

	if not _has_good[hand]:
		_raw.copy_into(target)
		target.tracking_valid = false
		return false

	if _lost_since_usec[hand] < 0:
		_lost_since_usec[hand] = now

	var held_for := float(now - _lost_since_usec[hand]) / 1_000_000.0
	if held_for > hold_duration_sec:
		_raw.copy_into(target)
		target.tracking_valid = false
		return false

	_last_good[hand].copy_into(target)
	target.timestamp_usec = now
	return true
