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
## MEASURED on Quest over Link, not guessed: the raw tracker reports
## valid=26 permanently (so POSITION_VALID carries no information at all),
## while tracked swings between 26 and 2 frame to frame. A threshold of 1
## therefore passed continuously -- the gate said "tracked" throughout every
## dropout, which is why four successive fixes for a drifting out-of-view ray
## changed nothing. A majority of the 26 joints separates the two states
## cleanly in that data.
@export var min_tracked_joints := 13
## Consecutive good frames required to LEAVE the lost state. Without this a
## single good frame inside a flicker burst cleared the hold timer, so the
## timer never expired and the gate oscillated between held and live --
## reported on device as the hand going "crazy" when looking away from it.
## Dropping is still immediate-then-held; only reacquisition is debounced.
@export_range(1, 30, 1) var reacquire_frames := 3

var _inner: XRHandPoseSource
var _raw := XRHandFrame.new()
var _last_good: Array[XRHandFrame] = []
var _has_good := [false, false]
var _lost_since_usec := [-1, -1]
## Consecutive frames the raw source has met min_tracked_joints, per hand.
var _good_streak := [0, 0]
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
		_good_streak[hand] += 1
		# Debounced reacquisition. A lone good frame inside a flicker burst
		# used to clear the hold timer, so with tracked swinging 26 <-> 2 the
		# timer never expired and the held pose was replaced by whichever
		# garbage frame happened to pass. Keep holding until the recovery is
		# actually sustained. Only reacquisition is debounced -- going lost is
		# still immediate-then-held, so a real dropout is caught on frame one.
		if _has_good[hand] and _lost_since_usec[hand] >= 0 \
				and _good_streak[hand] < reacquire_frames:
			_last_good[hand].copy_into(target)
			target.timestamp_usec = now
			return true
		if not _has_good[hand] or _lost_since_usec[hand] >= 0:
			# First acquisition also counts: the filter has no history either way.
			_discontinuity[hand] = true
		_lost_since_usec[hand] = -1
		_has_good[hand] = true
		_raw.copy_into(_last_good[hand])
		_raw.copy_into(target)
		return true

	_good_streak[hand] = 0

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
