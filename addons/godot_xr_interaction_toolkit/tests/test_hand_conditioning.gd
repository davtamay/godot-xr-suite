extends SceneTree

## Headless tests for the hand conditioning layer.
## Run: godot --headless --path <demo> --script res://addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd

func _init() -> void:
	var failures: Array[String] = []
	_test_joint_hierarchy(failures)
	_test_one_euro_alpha(failures)
	_test_one_euro_behaviour(failures)
	_test_one_euro_robustness(failures)
	_test_rotation_filter(failures)
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

func _test_one_euro_alpha(failures: Array[String]) -> void:
	# alpha = 1 / (1 + tau/dt), tau = 1/(2*pi*cutoff).
	# At cutoff = 1/(2*pi) Hz, tau = 1s; with dt = 1s, alpha = 0.5.
	var a := XROneEuroFilter.alpha(1.0 / TAU, 1.0)
	if not is_equal_approx(a, 0.5):
		failures.append("alpha(1/TAU, 1) = %.6f, expected 0.5" % a)
	# Higher cutoff => less smoothing => alpha closer to 1.
	if not (XROneEuroFilter.alpha(10.0, 0.01) > XROneEuroFilter.alpha(1.0, 0.01)):
		failures.append("alpha must increase with cutoff")

func _test_one_euro_behaviour(failures: Array[String]) -> void:
	var dt := 1.0 / 72.0

	# 1. First sample passes through untouched (seeding, not filtering).
	var seed_filter := XROneEuroFilter.new()
	seed_filter.resize(1)
	var first := seed_filter.filter(0, Vector3(1, 2, 3), dt)
	if not first.is_equal_approx(Vector3(1, 2, 3)):
		failures.append("first sample must seed, not filter: %s" % str(first))

	# 2. Noise on a stationary signal is attenuated.
	var still := XROneEuroFilter.new()
	still.resize(1)
	still.min_cutoff = 1.0
	still.beta = 0.0
	var noise := [0.01, -0.012, 0.008, -0.009, 0.011, -0.007, 0.010, -0.011]
	var raw_extent := 0.0
	var filtered_extent := 0.0
	for i in range(noise.size()):
		var sample := Vector3(noise[i], 0, 0)
		var out := still.filter(0, sample, dt)
		if i >= 2:  # skip the seeding transient
			raw_extent = maxf(raw_extent, absf(sample.x))
			filtered_extent = maxf(filtered_extent, absf(out.x))
	if filtered_extent >= raw_extent:
		failures.append("filter did not attenuate stationary noise (raw %.4f, filtered %.4f)" % [raw_extent, filtered_extent])

	# 3. Direction is preserved on diagonal motion. This is the property that
	#    per-component filtering breaks: independent alphas make the slow axis
	#    lag more, bending the path.
	var diagonal := XROneEuroFilter.new()
	diagonal.resize(1)
	diagonal.min_cutoff = 1.0
	diagonal.beta = 0.5
	var direction := Vector3(1.0, 0.25, 0.0).normalized()
	var out_vector := Vector3.ZERO
	for step in range(20):
		out_vector = diagonal.filter(0, direction * (0.02 * step), dt)
	if out_vector.length() > 0.0001:
		var angle_deg := rad_to_deg(out_vector.normalized().angle_to(direction))
		if angle_deg > 0.5:
			failures.append("filtered path bent %.3f deg off the input direction" % angle_deg)

	# 4. beta > 0 reduces lag on fast motion (the whole point of 1 euro).
	var lagged := _ramp_end(0.0, dt)
	var responsive := _ramp_end(1.0, dt)
	if not (responsive > lagged):
		failures.append("beta did not reduce lag: beta=0 ended at %.4f, beta=1 at %.4f" % [lagged, responsive])

	# 5. Channels are independent.
	var banked := XROneEuroFilter.new()
	banked.resize(2)
	banked.filter(0, Vector3(10, 0, 0), dt)
	var fresh := banked.filter(1, Vector3(0, 5, 0), dt)
	if not fresh.is_equal_approx(Vector3(0, 5, 0)):
		failures.append("channel 1 was polluted by channel 0: %s" % str(fresh))

func _ramp_end(beta: float, dt: float) -> float:
	var filter := XROneEuroFilter.new()
	filter.resize(1)
	filter.min_cutoff = 1.0
	filter.beta = beta
	var out := Vector3.ZERO
	for step in range(20):
		out = filter.filter(0, Vector3(0.05 * step, 0, 0), dt)
	return out.x

func _test_one_euro_robustness(failures: Array[String]) -> void:
	var dt := 1.0 / 72.0
	var filter := XROneEuroFilter.new()
	filter.resize(1)
	filter.filter(0, Vector3(1, 1, 1), dt)

	# Non-finite input must pass through and not poison the state.
	var nan_out := filter.filter(0, Vector3(NAN, 0, 0), dt)
	if nan_out.is_finite():
		failures.append("expected the non-finite input to pass through unchanged")
	var recovered := filter.filter(0, Vector3(2, 2, 2), dt)
	if not recovered.is_finite():
		failures.append("filter state was poisoned by a non-finite sample")

	# Zero and negative dt must not divide by zero.
	var zero_dt := filter.filter(0, Vector3(3, 3, 3), 0.0)
	if not zero_dt.is_finite():
		failures.append("dt = 0 produced a non-finite result")
	var negative_dt := filter.filter(0, Vector3(3, 3, 3), -0.5)
	if not negative_dt.is_finite():
		failures.append("negative dt produced a non-finite result")

	# reset_channel re-seeds: the next sample passes through.
	filter.reset_channel(0)
	var reseeded := filter.filter(0, Vector3(9, 9, 9), dt)
	if not reseeded.is_equal_approx(Vector3(9, 9, 9)):
		failures.append("reset_channel did not re-seed: %s" % str(reseeded))

func _test_rotation_filter(failures: Array[String]) -> void:
	var dt := 1.0 / 72.0
	var filter := XROneEuroRotationFilter.new()
	filter.resize(1)

	var start := Quaternion(Vector3.UP, 0.0)
	var seeded := filter.filter(0, start, dt)
	if not seeded.is_equal_approx(start):
		failures.append("rotation filter must seed on the first sample")

	# Hemisphere correction: a negated quaternion is the SAME rotation, so the
	# filter must not travel the long way around to reach it.
	var target := Quaternion(Vector3.UP, 0.2)
	var negated := -target
	var out := filter.filter(0, negated, dt)
	if out.angle_to(start) > deg_to_rad(90.0):
		failures.append("rotation filter took the long path across the hemisphere boundary")

	# Output stays normalized.
	var settle := Quaternion(Vector3.RIGHT, 1.0).normalized()
	for step in range(10):
		out = filter.filter(0, settle, dt)
	if not is_equal_approx(out.length(), 1.0):
		failures.append("rotation filter output drifted off unit length: %.6f" % out.length())
