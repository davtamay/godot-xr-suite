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

## FOV liveness test. MEASURED on Quest over Link (see class doc / the probe
## in XRConditionedHandPublisher): a hand out of the headset's cameras keeps
## reporting POSITION_TRACKED on a majority of joints while the runtime
## extrapolates it smoothly toward a neutral rest pose -- wrist moved 34cm/24cm
## across six consecutive frames with tracked=26 throughout. No combination of
## flags or thresholds on them can catch this; it is a geometric fact about
## the sensor (the cameras only see roughly the frontal hemisphere), not
## something the runtime chooses to report. Off switch restores today's
## behaviour EXACTLY -- suppressing a hand the user can actually see is a
## worse bug than the drift this exists to fix, so this must be trivial to
## disable in full.
@export var fov_gate_enabled := true
## Half-angle, in degrees, of the cone around the camera's forward axis a
## wrist must stay inside to count as observable. Quest hand-tracking cameras
## cover well over 100 degrees -- considerably wider than the display -- so 80
## is a conservative starting point: a hand near the edge of what the user can
## SEE on screen is still well inside this cone. Narrow this only after
## on-device verification (CLAUDE.md's on-device-earn-in rule): a value this
## load-bearing is exactly the kind of tuned constant that rule protects.
## MEASURED on device, not reasoned from the display FOV: hands in ORDINARY
## use sit at 50-92 degrees off the head's forward axis, because a hand at
## your waist or out to your side is far off-centre even while you are looking
## straight ahead. An 80 degree cone therefore cut into normal use and
## suppressed hands the user could see -- the exact regression this value's
## own warning predicted. Quest carries downward- and outward-facing cameras
## specifically to see hands at waist height, so real coverage is far wider
## than the display. A hand genuinely behind the user is ~180 degrees, so 120
## still catches the drift case with a wide margin on either side.
@export_range(1.0, 179.0, 0.5) var fov_half_angle_deg := 120.0

var _inner: XRHandPoseSource
var _raw := XRHandFrame.new()
var _last_good: Array[XRHandFrame] = []
var _has_good := [false, false]
var _lost_since_usec := [-1, -1]
## Consecutive frames the raw source has met min_tracked_joints, per hand.
var _good_streak := [0, 0]
## True while this hand's loss is attributable to the FOV cone rather than to
## the source going silent. Decides whether the hold EXPIRES (data loss: the
## hand may genuinely be gone) or FREEZES indefinitely (out of view: the hand
## is still on the user and must not vanish).
var _lost_to_fov := [false, false]
var _discontinuity := [false, false]

## The head pose the FOV test measures against, ALREADY in XROrigin3D space --
## the same space XRHandTracker.get_hand_joint_transform() reports joints in.
## This is a RefCounted with no tree access (see class doc), so it cannot
## resolve the camera itself; XRConditionedHandPublisher resolves it and calls
## set_head_pose() every publish. _has_head_pose false (the default, and
## whatever a caller that never resolved a rig leaves it at) makes the FOV
## test inert -- a missing rig must never blind every hand.
var _has_head_pose := false
var _head_transform := Transform3D.IDENTITY

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

## Given, not resolved -- see the class doc on _has_head_pose. `head_transform`
## must already be converted into XROrigin3D space by the caller
## (origin.global_transform.affine_inverse() * camera.global_transform); this
## gate has no tree access to do that conversion itself. `has_head` false
## makes the FOV test inert regardless of `head_transform`'s contents.
func set_head_pose(has_head: bool, head_transform: Transform3D) -> void:
	_has_head_pose = has_head
	_head_transform = head_transform

## Angle in degrees between the head pose's forward axis (-Z, this codebase's
## forward convention -- see xr_blaster.gd, xr_locomotion.gd) and the direction
## from the head to `wrist_origin_space`. Both must already be in the same
## space (XROrigin3D space); see set_head_pose. INF when no head pose has been
## given, so a caller (the diagnostic probe) can tell "inert" apart from "0
## degrees, dead ahead" without a second query. Shared by _fails_fov_gate and
## the probe so the two can never read the geometry differently.
func head_to_wrist_angle_deg(wrist_origin_space: Vector3) -> float:
	if not _has_head_pose:
		return INF
	var to_wrist := wrist_origin_space - _head_transform.origin
	if to_wrist.length_squared() < 0.000001:
		return 0.0
	var forward := -_head_transform.basis.z
	return rad_to_deg(forward.angle_to(to_wrist))

## Hard sensor constraint, not a heuristic (see fov_gate_enabled doc): a wrist
## outside the cone is necessarily an extrapolated pose, regardless of what
## POSITION_TRACKED claims. Reads the WRIST specifically -- the joint the
## measured drift and every fixture in this file's tests is keyed on -- and is
## a no-op whenever the wrist itself was not reported this frame, the test is
## disabled, or no head pose was ever given.
func _fails_fov_gate(raw: XRHandFrame) -> bool:
	if not fov_gate_enabled or not _has_head_pose:
		return false
	if not raw.has_joint(XRHandTracker.HAND_JOINT_WRIST):
		return false
	var angle := head_to_wrist_angle_deg(raw.joint_transforms[XRHandTracker.HAND_JOINT_WRIST].origin)
	return angle > fov_half_angle_deg

func capture(hand: int, timestamp_usec: int, target: XRHandFrame) -> bool:
	if _inner == null or hand < 0 or hand >= _HANDS:
		return false

	var tracked := _inner.capture(hand, timestamp_usec, _raw)
	if tracked and _raw.tracked_joint_count < min_tracked_joints:
		tracked = false
	# Out of FOV is NOT the same verdict as no data, and conflating them was a
	# regression: the hand expired after hold_duration_sec and VANISHED.
	# David, on device: "now you make the left hand disapear... you dont
	# correct the stabalization".
	#
	# A hand outside the cameras' cone is still ON THE USER -- we simply cannot
	# see it. Meta's LastKnownGoodHand draws exactly this line: bad data while
	# the hand is CONNECTED substitutes the last good pose and keeps reporting
	# tracked; only a DISCONNECTED hand reports untracked. The suite's own
	# handoff reaches the same conclusion about hands vanishing mid-gesture --
	# bridge the dropout, do not hide faster.
	#
	# So FOV loss FREEZES indefinitely (the hand stays put, visibly, where it
	# was last seen) while a genuine data loss still expires, because a hand
	# that stopped reporting really may be gone.
	var out_of_fov := tracked and _fails_fov_gate(_raw)
	if out_of_fov:
		tracked = false
	_lost_to_fov[hand] = out_of_fov or (not tracked and _lost_to_fov[hand])

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
		_lost_to_fov[hand] = false
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

	# A hand lost to the FOV cone never expires: it is still on the user, just
	# unobservable, so it stays frozen where it was last seen rather than
	# disappearing. Only a hand that stopped reporting altogether times out.
	var held_for := float(now - _lost_since_usec[hand]) / 1_000_000.0
	if not _lost_to_fov[hand] and held_for > hold_duration_sec:
		_raw.copy_into(target)
		target.tracking_valid = false
		return false

	_last_good[hand].copy_into(target)
	target.timestamp_usec = now
	return true
