extends SceneTree

## Headless test for the math under the actuator's hand language: easing, and
## finger blends that move fingers by rotation, keeping bone lengths. A length
## change is what the conditioning chain low-passes away, so it is the failure
## that would look right in a capture and reach a recognizer seconds late.
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_webxr_kit/tests/test_actuator_language.gd

const Actuator := preload("res://addons/godot_webxr_kit/runtime/xr_remote_actuator.gd")
const PoseMath := preload("res://addons/godot_xr_hands/runtime/xr_hand_pose_math.gd")

var _failures: Array[String] = []


func _process(_delta: float) -> bool:
	_test_easing()
	_test_blend()
	_test_blend_midway(0)
	_test_blend_midway(1)
	if _failures.is_empty():
		print("XR actuator language: PASS")
		quit(0)
		return true
	for failure in _failures:
		push_error(failure)
	print("XR actuator language: FAIL (%d)" % _failures.size())
	quit(1)
	return true


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _test_easing() -> void:
	for easing in ["smooth", "linear", "minimum-jerk"]:
		_check(is_equal_approx(Actuator.ease_value(easing, 0.0), 0.0), "%s must start at 0" % easing)
		_check(is_equal_approx(Actuator.ease_value(easing, 1.0), 1.0), "%s must end at 1" % easing)
		_check(is_equal_approx(Actuator.ease_value(easing, 0.5), 0.5), "%s must be halfway at the midpoint" % easing)
		_check(is_equal_approx(Actuator.ease_value(easing, 2.0), 1.0), "%s must clamp past the end" % easing)
	_check(is_equal_approx(Actuator.ease_value("linear", 0.1), 0.1), "linear is linear")
	# A reach starts gentler than smoothstep: 10t^3 - 15t^4 + 6t^5 at t = 0.1.
	_check(is_equal_approx(Actuator.ease_value("minimum-jerk", 0.1), 0.00856), "minimum-jerk profile")
	_check(Actuator.ease_value("minimum-jerk", 0.1) < Actuator.ease_value("smooth", 0.1), "minimum-jerk starts gentler than smooth")
	# Its velocity is zero at both ends, which is the point of it.
	var near_start: float = Actuator.ease_value("minimum-jerk", 0.001)
	_check(near_start < 0.00001, "minimum-jerk leaves rest slowly, got %f" % near_start)


func _test_blend() -> void:
	var skeletons: Dictionary = PoseMath.load_bind_skeletons()
	_check(not skeletons.is_empty(), "the bind skeletons must load")
	if skeletons.is_empty():
		return
	var bind: Array = skeletons[1]["rel"]
	var axes: Array = skeletons[1]["curl_axes"]
	var open: Array = PoseMath.fk_pose(bind, axes, {})
	var fist: Array = PoseMath.fk_pose(bind, axes, {"thumb": 0.85, "index": 0.95, "middle": 0.95, "ring": 0.95, "pinky": 0.95})
	var ring: Array = PoseMath.FINGER_CHAINS[3]

	var still: Array = PoseMath.blend_pose(open, {"ring": {"joints": fist, "weight": 0.0}})
	for joint in open.size():
		_check((still[joint] as Transform3D).is_equal_approx(open[joint]), "weight 0 must leave joint %d alone" % joint)

	var full: Array = PoseMath.blend_pose(open, {"ring": {"joints": fist, "weight": 1.0}})
	var half: Array = PoseMath.blend_pose(open, {"ring": {"joints": fist, "weight": 0.5}})
	for i in range(1, ring.size()):
		var bone_open := _bone(open, ring, i)
		var bone_full := _bone(full, ring, i)
		var bone_half := _bone(half, ring, i)
		_check(is_equal_approx(bone_open.length(), bone_full.length()), "a full blend must keep bone %d's length" % i)
		_check(is_equal_approx(bone_open.length(), bone_half.length()), "a half blend must keep bone %d's length" % i)
		_check(bone_full.normalized().dot(_bone(fist, ring, i).normalized()) > 0.9999, "a full blend must reach the target direction on bone %d" % i)

	var ring_tip: int = ring[ring.size() - 1]
	var open_reach: float = (open[ring_tip] as Transform3D).origin.length()
	var half_reach: float = (half[ring_tip] as Transform3D).origin.length()
	var full_reach: float = (full[ring_tip] as Transform3D).origin.length()
	_check(full_reach < half_reach and half_reach < open_reach, "a half weight must land between the two poses")

	for f in PoseMath.FINGER_CHAINS.size():
		if f == 3:
			continue
		for joint in PoseMath.FINGER_CHAINS[f]:
			_check((full[joint] as Transform3D).is_equal_approx(open[joint]), "another finger moved at joint %d" % joint)

	# The inputs are held poses, republished every frame.
	_check((open[ring_tip] as Transform3D).is_equal_approx(PoseMath.fk_pose(bind, axes, {})[ring_tip]), "blend must not change its input")


## Blending between two curls has to BE the curl between them, at every weight
## and on both hands. Checks at the ends of a fade cannot see a finger that swings
## backward through the middle: joints past 180 degrees in wrist space do, if the
## turn is interpolated there rather than relative to the parent joint.
func _test_blend_midway(hand: int) -> void:
	var skeletons: Dictionary = PoseMath.load_bind_skeletons()
	var bind: Array = skeletons[hand]["rel"]
	var axes: Array = skeletons[hand]["curl_axes"]
	var names: Array = PoseMath.FINGER_NAMES
	var curls_to := {}
	for finger in names:
		curls_to[finger] = 1.0 if finger != "thumb" else 0.9
	var start: Array = PoseMath.fk_pose(bind, axes, {"thumb": 0.0, "index": 0.0, "middle": 0.0, "ring": 0.0, "pinky": 0.0})
	var end: Array = PoseMath.fk_pose(bind, axes, curls_to)
	for weight in [0.25, 0.5, 0.75]:
		var targets := {}
		var curls_mid := {}
		for finger in names:
			targets[finger] = {"joints": end, "weight": weight}
			curls_mid[finger] = curls_to[finger] * weight
		var blended: Array = PoseMath.blend_pose(start, targets)
		var expected: Array = PoseMath.fk_pose(bind, axes, curls_mid)
		for chain in PoseMath.FINGER_CHAINS:
			for joint in chain:
				var got: Transform3D = blended[joint]
				var want: Transform3D = expected[joint]
				var off := got.origin.distance_to(want.origin)
				_check(off < 0.0005, "hand %d joint %d is %.4f m off the curl at weight %.2f" % [hand, joint, off, weight])
				var turn := (got.basis.get_rotation_quaternion().inverse() * want.basis.get_rotation_quaternion()).get_angle()
				turn = minf(turn, TAU - turn)
				_check(turn < 0.01, "hand %d joint %d is %.1f degrees off the curl at weight %.2f" % [hand, joint, rad_to_deg(turn), weight])


func _bone(pose: Array, chain: Array, i: int) -> Vector3:
	return (pose[chain[i]] as Transform3D).origin - (pose[chain[i - 1]] as Transform3D).origin
