extends SceneTree

## Headless tests that the derived hand ray behaves identically for both hands.
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_interaction_toolkit/tests/test_hand_ray_symmetry.gd
##
## Exists because it did not. The pitch axis is anatomical (index knuckle ->
## pinky knuckle) and therefore MIRRORS between hands, which the pitch sign
## flip in get_hand_ray_pose compensates for. The fallback axis, fwd.cross(UP),
## has FIXED chirality and does not mirror -- so whenever the fallback was
## taken the two hands tilted in opposite directions. The fallback is taken
## when the outer knuckles stop being reported, i.e. when a hand is leaving
## camera view, which is exactly when it was reported on device as one hand
## feeling less stable than the other.

const XRHandGestureProviderScript := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_gesture_provider.gd")

const VALID_AND_TRACKED := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED

## Joints that carry a correctly-mirroring pitch axis. Dropping ALL of them is
## what forces get_hand_ray_pose onto its world-derived last resort.
const ACROSS_JOINTS := [
	XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL,
	XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL,
	XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL,
	XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL,
]


func _init() -> void:
	var failures: Array[String] = []
	_test_anatomical_axis_is_symmetric(failures)
	_test_fallback_axis_is_symmetric(failures)
	_test_fallback_is_actually_being_exercised(failures)
	_test_ray_survives_losing_the_pinky(failures)

	if failures.is_empty():
		print("XR hand ray symmetry: PASS")
		quit(0)
	else:
		for f in failures:
			push_error(f)
		print("XR hand ray symmetry: FAIL (%d)" % failures.size())
		quit(1)


## A hand posed identically apart from being mirrored across X must produce a
## ray that is likewise mirrored across X. Any other outcome means one hand is
## being tilted differently from the other.
func _mirrored_pair(drop_across_joints: bool) -> Array:
	return [
		_make_hand(XRPositionalTracker.TRACKER_HAND_LEFT, -1.0, drop_across_joints),
		_make_hand(XRPositionalTracker.TRACKER_HAND_RIGHT, 1.0, drop_across_joints),
	]


## `side` is -1 for left, +1 for right; every X coordinate is multiplied by it,
## so the two hands are exact mirror images -- the same physical pose, one on
## each side of the body. Anatomy mirrors too: the pinky sits OUTBOARD of the
## index knuckle on both hands, which is why the anatomical axis flips sign and
## the pitch flip in get_hand_ray_pose cancels it.
func _make_hand(hand: int, side: float, drop_across_joints: bool) -> XRHandTracker:
	var tracker := XRHandTracker.new()
	tracker.hand = hand
	tracker.has_tracking_data = true

	var positions := {
		XRHandTracker.HAND_JOINT_WRIST: Vector3(0.10 * side, 1.00, -0.20),
		XRHandTracker.HAND_JOINT_PALM: Vector3(0.10 * side, 1.03, -0.26),
		XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL: Vector3(0.08 * side, 1.05, -0.30),
		XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL: Vector3(0.09 * side, 1.03, -0.25),
		# Outboard of the index knuckle -- further from the body centreline.
		XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL: Vector3(0.14 * side, 1.05, -0.29),
		XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL: Vector3(0.13 * side, 1.03, -0.24),
		XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL: Vector3(0.12 * side, 1.05, -0.30),
		XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL: Vector3(0.10 * side, 1.05, -0.31),
	}

	for joint in positions:
		if drop_across_joints and joint in ACROSS_JOINTS:
			tracker.set_hand_joint_flags(joint, 0)
			continue
		tracker.set_hand_joint_transform(joint, Transform3D(Basis.IDENTITY, positions[joint]))
		tracker.set_hand_joint_flags(joint, VALID_AND_TRACKED)

	return tracker


func _check_symmetry(failures: Array[String], label: String, drop_across_joints: bool) -> void:
	var pair := _mirrored_pair(drop_across_joints)
	var left: Dictionary = XRHandGestureProviderScript.get_hand_ray_pose(pair[0])
	var right: Dictionary = XRHandGestureProviderScript.get_hand_ray_pose(pair[1])

	if left.is_empty() or right.is_empty():
		failures.append("%s: expected a ray for both hands, got left_empty=%s right_empty=%s" % [
				label, left.is_empty(), right.is_empty()])
		return

	var left_dir: Vector3 = left["direction"]
	var right_dir: Vector3 = right["direction"]
	# Mirror the right hand's ray back across X; it must then match the left's.
	var mirrored_right := Vector3(-right_dir.x, right_dir.y, right_dir.z)
	var disagreement := rad_to_deg(left_dir.angle_to(mirrored_right))

	if disagreement > 1.0:
		failures.append("%s: mirrored hands must produce mirrored rays, but they differ by %.2f deg (left=%s right=%s). A pitch applied in opposite directions shows up here." % [
				label, disagreement, left_dir.snappedf(0.001), mirrored_right.snappedf(0.001)])

	# Pitch must go DOWN for both, not down for one and up for the other --
	# the specific failure the fallback had.
	if signf(left_dir.y) != signf(mirrored_right.y):
		failures.append("%s: the two hands pitch in OPPOSITE vertical directions (left y=%.3f, mirrored right y=%.3f)" % [
				label, left_dir.y, mirrored_right.y])


func _test_anatomical_axis_is_symmetric(failures: Array[String]) -> void:
	_check_symmetry(failures, "anatomical axis (outer knuckles tracked)", false)


func _test_fallback_axis_is_symmetric(failures: Array[String]) -> void:
	_check_symmetry(failures, "fallback axis (outer knuckles dropped)", true)


## Guard the guard: if a future change kept some other knuckle alive, the
## fallback test above would silently stop testing the fallback and would pass
## for the wrong reason.
func _test_fallback_is_actually_being_exercised(failures: Array[String]) -> void:
	var tracker := _make_hand(XRPositionalTracker.TRACKER_HAND_LEFT, -1.0, true)
	for joint in ACROSS_JOINTS:
		if XRHandGestureProviderScript.joint_position_valid(tracker, joint):
			failures.append("the fallback fixture still reports joint %d as valid, so the fallback path is not being exercised" % joint)


## Losing the pinky alone must NOT drop to the world-derived axis: the ring and
## middle knuckles carry the same mirroring and are more reliably tracked.
func _test_ray_survives_losing_the_pinky(failures: Array[String]) -> void:
	var tracker := _make_hand(XRPositionalTracker.TRACKER_HAND_LEFT, -1.0, false)
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL, 0)
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL, 0)

	var full := _make_hand(XRPositionalTracker.TRACKER_HAND_LEFT, -1.0, false)
	var with_pinky: Dictionary = XRHandGestureProviderScript.get_hand_ray_pose(full)
	var without_pinky: Dictionary = XRHandGestureProviderScript.get_hand_ray_pose(tracker)

	if with_pinky.is_empty() or without_pinky.is_empty():
		failures.append("losing the pinky must not lose the ray entirely")
		return

	var drift := rad_to_deg((with_pinky["direction"] as Vector3).angle_to(without_pinky["direction"] as Vector3))
	if drift > 10.0:
		failures.append("losing the pinky swung the ray by %.2f deg; the ring/middle knuckles should carry the axis instead" % drift)
