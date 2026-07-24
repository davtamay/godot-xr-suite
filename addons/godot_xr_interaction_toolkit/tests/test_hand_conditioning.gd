extends SceneTree

## Headless tests for the hand conditioning layer.
## Run: godot --headless --path <demo> --script res://addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd

func _init() -> void:
	var failures: Array[String] = []
	_test_joint_hierarchy(failures)
	if failures.is_empty():
		print("XR hand conditioning: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	print("XR hand conditioning: FAIL (%d)" % failures.size())
	quit(1)

func _test_joint_hierarchy(failures: Array[String]) -> void:
	var parent := XRHandJointHierarchy.PARENT
	if parent.size() != XRHandTracker.HAND_JOINT_MAX:
		failures.append("hierarchy covers %d joints, expected %d" % [parent.size(), XRHandTracker.HAND_JOINT_MAX])
		return

	if parent[XRHandTracker.HAND_JOINT_WRIST] != -1:
		failures.append("wrist must be the root")

	# Every joint reaches the wrist without cycling.
	for joint in range(XRHandTracker.HAND_JOINT_MAX):
		var cursor := joint
		var hops := 0
		while cursor != -1 and hops <= XRHandTracker.HAND_JOINT_MAX:
			cursor = parent[cursor]
			hops += 1
		if cursor != -1:
			failures.append("joint %d never reaches the root (cycle or orphan)" % joint)

	# Spot-check chain structure.
	if parent[XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL] != XRHandTracker.HAND_JOINT_WRIST:
		failures.append("index metacarpal must parent to the wrist")
	if parent[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP] != XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL:
		failures.append("index tip must parent to the index distal phalanx")
	if parent[XRHandTracker.HAND_JOINT_PALM] != XRHandTracker.HAND_JOINT_WRIST:
		failures.append("palm must parent to the wrist")

	# Tips: exactly five, and none is any joint's parent.
	var tip_count := 0
	for joint in range(XRHandTracker.HAND_JOINT_MAX):
		if XRHandJointHierarchy.IS_TIP[joint] == 1:
			tip_count += 1
			if parent.has(joint):
				failures.append("joint %d is marked a tip but has children" % joint)
	if tip_count != 5:
		failures.append("expected 5 fingertips, found %d" % tip_count)

	# ORDER must list every parent before its children.
	var seen := {}
	for joint in XRHandJointHierarchy.ORDER:
		var p: int = parent[joint]
		if p != -1 and not seen.has(p):
			failures.append("ORDER lists joint %d before its parent %d" % [joint, p])
		seen[joint] = true
	if seen.size() != XRHandTracker.HAND_JOINT_MAX:
		failures.append("ORDER covers %d joints, expected %d" % [seen.size(), XRHandTracker.HAND_JOINT_MAX])
