extends SceneTree

## Headless tests for grab feel (docs/grab-feel-design.md).
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_interaction_toolkit/tests/test_grab_feel.gd

const XRControllerHandAdapter := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_controller_hand_adapter.gd")

var _failures: Array[String] = []

func _init() -> void:
	_test_grip_anchor_prefers_palm(_failures)
	# _test_grip_pose_stays_on_palm_with_full_hand needs a live Node3D.global_transform,
	# which asserts "!is_inside_tree()" if read this early: a node added to
	# get_root() during _init() is not yet inside the tree (confirmed empirically -
	# tree membership only propagates by the first _process). Deferred there.

func _process(_delta: float) -> bool:
	_test_grip_pose_stays_on_palm_with_full_hand(_failures)
	if _failures.is_empty():
		print("XR grab feel: PASS")
		quit(0)
		return true
	for failure in _failures:
		push_error(failure)
	print("XR grab feel: FAIL (%d)" % _failures.size())
	quit(1)
	return true

func _make_tracker(palm_valid: bool) -> XRHandTracker:
	var tracker := XRHandTracker.new()
	tracker.has_tracking_data = true
	var valid := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST, Transform3D(Basis.IDENTITY, Vector3(0, 1, 0)))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_WRIST, valid)
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM, Transform3D(Basis.IDENTITY, Vector3(0, 1, -0.07)))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_PALM, valid if palm_valid else 0)
	return tracker

func _test_grip_anchor_prefers_palm(failures: Array[String]) -> void:
	var palm_anchor := XRControllerHandAdapter.resolve_grip_anchor(_make_tracker(true))
	if not palm_anchor.origin.is_equal_approx(Vector3(0, 1, -0.07)):
		failures.append("grip anchor must sit on the PALM when the palm is valid, got %s" % palm_anchor.origin)
	var wrist_anchor := XRControllerHandAdapter.resolve_grip_anchor(_make_tracker(false))
	if not wrist_anchor.origin.is_equal_approx(Vector3(0, 1, 0)):
		failures.append("grip anchor must fall back to the WRIST when the palm is invalid, got %s" % wrist_anchor.origin)

## Regression for the 2026-07-19 (15d3783) wrist<->middle-metacarpal midpoint
## that silently overrode resolve_grip_anchor()'s PALM-first choice whenever
## the metacarpals were also tracked - the normal case on real hardware, so
## the override fired on effectively every real grab. Drives the actual call
## site (get_grip_pose, via a real registered XRHandTracker), not just the
## extracted selector, since the midpoint bug lived downstream of it.
func _test_grip_pose_stays_on_palm_with_full_hand(failures: Array[String]) -> void:
	var hand_id := XRControllerHandAdapter.Hand.RIGHT
	var palm_position := Vector3(0, 1, -0.05)
	var wrist_position := Vector3(0, 1, 0)
	var midpoint := (wrist_position + Vector3(0, 1.015, -0.035)) * 0.5

	var was_conditioned := XRHandTrackerResolver.is_conditioned()
	XRHandTrackerResolver._conditioned = false
	XRHandTrackerResolver._cache_frame = -1

	var tracker := XRHandTracker.new()
	tracker.name = "/user/hand_tracker/right"
	tracker.hand = XRPositionalTracker.TRACKER_HAND_RIGHT
	tracker.has_tracking_data = true
	var valid := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST, Transform3D(Basis.IDENTITY, wrist_position))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_WRIST, valid)
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM, Transform3D(Basis.IDENTITY, palm_position))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_PALM, valid)
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL, Transform3D(Basis.IDENTITY, Vector3(0.02, 1.02, -0.03)))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL, valid)
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL, Transform3D(Basis.IDENTITY, Vector3(-0.02, 1.01, -0.03)))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL, valid)
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL, Transform3D(Basis.IDENTITY, Vector3(0, 1.015, -0.035)))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL, valid)
	XRServer.add_tracker(tracker)

	var adapter := XRControllerHandAdapter.new()
	var origin_node := Node3D.new()
	get_root().add_child(origin_node)  # global_transform asserts on an out-of-tree node
	adapter._origin = origin_node
	var pose := adapter.get_grip_pose(hand_id)

	if pose.is_empty():
		failures.append("get_grip_pose returned nothing with a fully-tracked hand")
	else:
		var origin: Vector3 = pose["origin"]
		if not origin.is_equal_approx(palm_position):
			failures.append("grip pose origin must stay on the PALM joint with a full hand tracked, got %s (palm %s, midpoint %s)" % [origin, palm_position, midpoint])
		if origin.is_equal_approx(midpoint):
			failures.append("grip pose origin regressed to the retired wrist<->metacarpal midpoint: %s" % origin)
		if origin.is_equal_approx(wrist_position):
			failures.append("grip pose origin regressed to the raw WRIST joint: %s" % origin)

	adapter.free()
	get_root().remove_child(origin_node)
	origin_node.free()
	XRServer.remove_tracker(tracker)
	XRHandTrackerResolver._conditioned = was_conditioned
	XRHandTrackerResolver._cache_frame = -1
