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
	_test_trace_round_trip(failures)
	_test_recorder_dedup_guard(failures)
	_test_trace_metrics(failures)
	_test_hand_filter(failures)
	_test_hand_filter_dedup(failures)
	_test_confidence_gate(failures)
	_test_publisher(failures)
	_test_publisher_republish_cache(failures)
	_test_publisher_tracker_registration(failures)
	_test_publisher_null_contract(failures)
	_test_resolver_conditioned_routing(failures)
	_test_resolver_toggle_resets_chain(failures)
	_test_pose_source_reads_raw_across_frames(failures)
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

	# Double cover: a negated quaternion is the SAME rotation, so filtering
	# toward -target must converge to the same rotation as filtering toward
	# target. Compare with angle_to (not raw components) since the two
	# results may legitimately differ in sign while representing the same
	# rotation.
	var target := Quaternion(Vector3.UP, 0.2)
	var negated := -target
	var filter_pos := XROneEuroRotationFilter.new()
	filter_pos.resize(1)
	filter_pos.filter(0, start, dt)
	var filter_neg := XROneEuroRotationFilter.new()
	filter_neg.resize(1)
	filter_neg.filter(0, start, dt)
	var out_pos := Quaternion.IDENTITY
	var out_neg := Quaternion.IDENTITY
	for step in range(5):
		out_pos = filter_pos.filter(0, target, dt)
		out_neg = filter_neg.filter(0, negated, dt)
	var out := out_pos
	if out_pos.angle_to(out_neg) > deg_to_rad(0.01):
		failures.append("filtering toward target and -target diverged: angle_to = %.6f deg" % rad_to_deg(out_pos.angle_to(out_neg)))

	# Output stays normalized.
	var settle := Quaternion(Vector3.RIGHT, 1.0).normalized()
	for step in range(10):
		out = filter.filter(0, settle, dt)
	if not is_equal_approx(out.length(), 1.0):
		failures.append("rotation filter output drifted off unit length: %.6f" % out.length())

func _test_trace_round_trip(failures: Array[String]) -> void:
	var trace := XRHandTrace.new()
	for step in range(5):
		var frame := XRHandFrame.new()
		frame.begin_capture(0, 1000 * step, step)
		frame.set_joint(
			XRHandTracker.HAND_JOINT_WRIST,
			Transform3D(Basis.IDENTITY, Vector3(0.01 * step, 0, 0)),
			0.01,
			XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
		frame.tracking_valid = true
		trace.append_frame(frame)

	if trace.size() != 5:
		failures.append("trace recorded %d frames, expected 5" % trace.size())

	# Everything below touches a temp file on disk. Nest instead of early-
	# returning on failure so cleanup at the bottom always runs, even when a
	# save/reload/replay step fails.
	var path := "user://test_hand_trace.res"
	if trace.save(path) != OK:
		failures.append("failed to save the trace")
	else:
		var loaded := XRHandTrace.load_trace(path)
		if loaded == null or loaded.size() != 5:
			failures.append("failed to reload the trace")
		else:
			# Replay it through the pose-source seam.
			var player := XRHandTracePlayer.new(loaded)
			var target := XRHandFrame.new()
			var positions: Array[float] = []
			while player.remaining() > 0:
				if player.capture(0, 0, target):
					positions.append(target.joint_transforms[XRHandTracker.HAND_JOINT_WRIST].origin.x)

			if positions.size() != 5:
				failures.append("replayed %d frames, expected 5" % positions.size())
			else:
				for step in range(5):
					if not is_equal_approx(positions[step], 0.01 * step):
						failures.append("replayed frame %d had x=%.5f, expected %.5f" % [step, positions[step], 0.01 * step])

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func _test_recorder_dedup_guard(failures: Array[String]) -> void:
	# Regression for the recorder's duplicate-frame guard: it must dedup on
	# the raw wrist transform, not the frame timestamp (the timestamp is
	# stamped fresh by the caller on every _process tick, so comparing it
	# can never detect a repeated tracker sample). Drive the decision
	# through _should_record directly so this does not need a live tracker
	# or a running _process loop.
	var recorder := XRHandTraceRecorder.new()
	recorder.start()

	var kept := 0
	if recorder._should_record(_wrist_frame(0.0)):
		kept += 1
	if recorder._should_record(_wrist_frame(0.0)):  # unchanged: must be dropped
		kept += 1
	if recorder._should_record(_wrist_frame(0.01)):  # changed: must be kept
		kept += 1
	recorder.free()

	if kept != 2:
		failures.append("recorder dedup guard kept %d frames for [same, same, changed], expected 2" % kept)

func _wrist_frame(wrist_x: float) -> XRHandFrame:
	var frame := XRHandFrame.new()
	frame.begin_capture(0, Time.get_ticks_usec(), 0)
	frame.set_joint(
		XRHandTracker.HAND_JOINT_WRIST,
		Transform3D(Basis.IDENTITY, Vector3(wrist_x, 0, 0)),
		0.01,
		XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
	frame.tracking_valid = true
	return frame

func _test_trace_metrics(failures: Array[String]) -> void:
	# Jitter: a constant signal has zero spread; a noisy one does not.
	var still := PackedVector3Array()
	for i in range(20):
		still.append(Vector3(0.5, 0.5, 0.5))
	if not is_zero_approx(XRHandTraceMetrics.rest_jitter(still)):
		failures.append("a constant signal must have zero rest jitter")

	var noisy := PackedVector3Array()
	for i in range(20):
		noisy.append(Vector3(0.5 + (0.01 if i % 2 == 0 else -0.01), 0.5, 0.5))
	var noisy_jitter := XRHandTraceMetrics.rest_jitter(noisy)
	if not is_equal_approx(noisy_jitter, 0.01):
		failures.append("expected 0.01 m rest jitter, got %.5f" % noisy_jitter)

	# Lag: a signal delayed by a known number of frames must be measured back.
	var dt := 1.0 / 72.0
	var raw := PackedVector3Array()
	var delayed := PackedVector3Array()
	var shift := 3
	for i in range(60):
		raw.append(Vector3(sin(i * 0.2), 0, 0))
		delayed.append(Vector3(sin((i - shift) * 0.2), 0, 0))
	var measured := XRHandTraceMetrics.motion_lag_seconds(raw, delayed, dt, 10)
	if not is_equal_approx(measured, shift * dt):
		failures.append("expected %.5f s of lag, measured %.5f s" % [shift * dt, measured])

	# Bone length: a rigid chain has zero deviation, a stretching one does not.
	var rigid := _bone_frames([0.03, 0.03, 0.03, 0.03])
	if not is_zero_approx(XRHandTraceMetrics.bone_length_deviation(rigid, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP)):
		failures.append("a rigid bone must have zero length deviation")

	var stretching := _bone_frames([0.03, 0.04, 0.03, 0.04])
	if XRHandTraceMetrics.bone_length_deviation(stretching, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP) <= 0.0:
		failures.append("a stretching bone must report non-zero length deviation")

## Builds trace-shaped frames where the index tip sits `lengths[i]` from its parent.
func _bone_frames(lengths: Array) -> Array:
	var parent_joint: int = XRHandJointHierarchy.PARENT[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP]
	var built: Array = []
	for length in lengths:
		var transforms: Array[Transform3D] = []
		transforms.resize(XRHandFrame.JOINT_COUNT)
		for joint in range(XRHandFrame.JOINT_COUNT):
			transforms[joint] = Transform3D.IDENTITY
		transforms[parent_joint] = Transform3D(Basis.IDENTITY, Vector3.ZERO)
		transforms[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP] = Transform3D(Basis.IDENTITY, Vector3(0, 0, length))
		var flags := PackedInt32Array()
		flags.resize(XRHandFrame.JOINT_COUNT)
		flags.fill(XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
		built.append({"transforms": transforms, "flags": flags})
	return built

## Builds a pose source emitting a wrist-plus-index-tip hand with optional noise.
func _noisy_source(sample_count: int, noise: float) -> XRHandTracePlayer:
	var trace := XRHandTrace.new()
	var tip_offset := Vector3(0, 0, 0.03)
	for step in range(sample_count):
		var frame := XRHandFrame.new()
		frame.begin_capture(1, step * 13888, step)  # ~72 Hz in microseconds
		var wobble := Vector3(noise if step % 2 == 0 else -noise, 0, 0)
		var wrist := Transform3D(Basis.IDENTITY, wobble)
		frame.set_joint(XRHandTracker.HAND_JOINT_WRIST, wrist, 0.01, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
		frame.set_joint(
			XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL,
			Transform3D(Basis.IDENTITY, wobble),
			0.008, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
		frame.set_joint(
			XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,
			Transform3D(Basis.IDENTITY, wobble + tip_offset),
			0.008, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
		frame.tracking_valid = true
		trace.append_frame(frame)
	return XRHandTracePlayer.new(trace)

func _test_hand_filter(failures: Array[String]) -> void:
	# 1. Filtering attenuates wrist jitter.
	var raw_samples := PackedVector3Array()
	var raw_player := _noisy_source(40, 0.004)
	var raw_frame := XRHandFrame.new()
	while raw_player.remaining() > 0:
		if raw_player.capture(1, 0, raw_frame):
			raw_samples.append(raw_frame.joint_transforms[XRHandTracker.HAND_JOINT_WRIST].origin)

	var filtered_samples := PackedVector3Array()
	var filter := XRHandFilter.new(_noisy_source(40, 0.004))
	filter.position_min_cutoff = 1.0
	filter.position_beta = 0.0
	var out_frame := XRHandFrame.new()
	for step in range(40):
		if filter.capture(1, 0, out_frame):
			filtered_samples.append(out_frame.joint_transforms[XRHandTracker.HAND_JOINT_WRIST].origin)

	if filtered_samples.size() < 30:
		failures.append("hand filter produced only %d frames" % filtered_samples.size())
		return

	var raw_jitter := XRHandTraceMetrics.rest_jitter(raw_samples)
	var filtered_jitter := XRHandTraceMetrics.rest_jitter(filtered_samples)
	if filtered_jitter >= raw_jitter:
		failures.append("filter did not reduce jitter (raw %.5f, filtered %.5f)" % [raw_jitter, filtered_jitter])

	# 2. RIGIDITY. The central guarantee: no parameters, however extreme, may
	#    change a bone length. This must hold by construction, not by tuning.
	#
	#    A synthetic pose that stays symmetric (the same alternating +/-noise
	#    on every joint, identity bases everywhere, only 3 of 26 joints even
	#    populated) lets decomposition bugs cancel out by accident: reversing
	#    the traversal order anchors joints on an uninitialised identity
	#    transform -- the most severe decomposition bug possible -- and that
	#    still measured exactly 0.000000 deviation here, because Euclidean
	#    length is sign-insensitive and every joint wobbled by the exact same
	#    +/-noise. _articulated_hand_source below gives every joint its own
	#    unequal bone length, its own fixed rotation, and independently
	#    seeded asymmetric noise, while the whole hand translates and
	#    rotates -- so a wrong parent anchor moves a different amount than
	#    the correct one and there is nothing left for a bug to hide behind.
	var warmup_steps := 20
	var total_steps := 60
	var extreme := XRHandFilter.new(_articulated_hand_source(total_steps, 0.02))
	extreme.position_min_cutoff = 0.01
	extreme.position_beta = 0.0
	extreme.rotation_min_cutoff = 0.01
	extreme.bone_min_cutoff = 0.01
	var captured: Array = []
	var rigid_frame := XRHandFrame.new()
	for step in range(total_steps):
		if not extreme.capture(1, 0, rigid_frame):
			continue
		if step < warmup_steps:
			continue  # let the heavily-smoothed bone-offset filter settle first.
		var transforms: Array[Transform3D] = []
		transforms.resize(XRHandFrame.JOINT_COUNT)
		for joint in range(XRHandFrame.JOINT_COUNT):
			transforms[joint] = rigid_frame.joint_transforms[joint]
		captured.append({"transforms": transforms, "flags": rigid_frame.joint_flags.duplicate()})

	# Several bones, at several depths in the hierarchy, not just one tip.
	var bones_to_check := [
		XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL,
		XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE,
		XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL,
		XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,
		XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL,
		XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP,
		XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL,
		XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP,
	]
	for joint in bones_to_check:
		var deviation := XRHandTraceMetrics.bone_length_deviation(captured, joint)
		if deviation > 0.0025:
			failures.append("bone length varied by %.6f m under extreme filtering for joint %d (limit 0.0025)" % [deviation, joint])

	# 3. enabled = false is a true pass-through.
	var bypass := XRHandFilter.new(_noisy_source(6, 0.01))
	bypass.enabled = false
	var bypass_frame := XRHandFrame.new()
	bypass.capture(1, 0, bypass_frame)
	bypass.capture(1, 0, bypass_frame)
	var expected := Vector3(-0.01, 0, 0)  # step 1 of the alternating wobble
	if not bypass_frame.joint_transforms[XRHandTracker.HAND_JOINT_WRIST].origin.is_equal_approx(expected):
		failures.append("disabled filter altered the frame: %s" % str(bypass_frame.joint_transforms[XRHandTracker.HAND_JOINT_WRIST].origin))

## Fixed (noise-free) bone transform of `joint` relative to its TRUE parent,
## per XRHandJointHierarchy.PARENT. Every finger gets a distinct spread
## angle, a distinct curl, and strictly decreasing segment lengths -- unlike
## a degenerate pose, parent-local decomposition here has real rotation and
## real, unequal bone lengths to get wrong.
func _skeleton_local(joint: int) -> Transform3D:
	var chains := XRHandJointHierarchy.CHAINS
	for chain_index in range(chains.size()):
		var chain: Array = chains[chain_index]
		var depth := chain.find(joint)
		if depth == -1:
			continue
		var yaw := deg_to_rad(-30.0 + 15.0 * chain_index)
		var pitch := deg_to_rad(-10.0 - 8.0 * depth + 3.0 * chain_index)
		var roll := deg_to_rad(4.0 * chain_index - 2.0 * depth)
		var basis := Basis.from_euler(Vector3(pitch, yaw, roll))
		if depth == 0:
			# Metacarpal: root of the chain, spread laterally off the wrist.
			return Transform3D(basis, basis * Vector3(0.018 * (chain_index - 2), 0.0, 0.05))
		var length: float = maxf(0.045 - 0.008 * depth - 0.002 * chain_index, 0.012)
		return Transform3D(basis, basis * Vector3(0.0, 0.0, length))
	if joint == XRHandTracker.HAND_JOINT_PALM:
		return Transform3D(Basis.IDENTITY, Vector3(0.0, -0.005, 0.03))
	return Transform3D.IDENTITY

## The whole hand's world pose at `step`: a real path, not a hold-still
## point, so the filter is actually doing work rather than sitting at rest.
func _wrist_world(step: int) -> Transform3D:
	var t := float(step) / 12.0
	var origin := Vector3(0.10 * sin(t), 0.03 * t, 0.05 * cos(t * 0.7))
	var basis := Basis.from_euler(Vector3(0.15 * sin(t * 0.5), 0.25 * t, 0.10 * cos(t * 0.9)))
	return Transform3D(basis, origin)

## A full 26-joint, genuinely hierarchical, moving hand with asymmetric,
## per-joint, deterministic noise. Every joint is populated (unlike
## _noisy_source's 3-of-26), so every joint actually exercises parent-local
## decomposition instead of the "missing parent" raw-copy fallback. Noise is
## drawn from a seeded RandomNumberGenerator, not randf(), so the trace is
## reproducible across runs.
func _articulated_hand_source(sample_count: int, noise: float) -> XRHandTracePlayer:
	var rng := RandomNumberGenerator.new()
	rng.seed = 724026
	var trace := XRHandTrace.new()
	var wrist_id := XRHandTracker.HAND_JOINT_WRIST
	for step in range(sample_count):
		var frame := XRHandFrame.new()
		frame.begin_capture(1, step * 13888, step)  # ~72 Hz in microseconds

		var wrist_noise := Vector3(
			rng.randf_range(-noise, noise * 1.6),
			rng.randf_range(-noise * 0.7, noise),
			rng.randf_range(-noise, noise * 0.5))
		var wrist_transform := _wrist_world(step) * Transform3D(Basis.IDENTITY, wrist_noise)
		frame.set_joint(wrist_id, wrist_transform, 0.012, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)

		var world: Array[Transform3D] = []
		world.resize(XRHandFrame.JOINT_COUNT)
		world[wrist_id] = wrist_transform

		for joint in XRHandJointHierarchy.ORDER:
			if joint == wrist_id:
				continue
			var parent_joint: int = XRHandJointHierarchy.PARENT[joint]
			var local := _skeleton_local(joint)
			var offset_noise := Vector3(
				rng.randf_range(-noise, noise * 1.3),
				rng.randf_range(-noise * 1.1, noise * 0.6),
				rng.randf_range(-noise * 0.8, noise))
			var angle_noise := rng.randf_range(-noise * 3.0, noise * 4.0)
			var axis := Vector3(
				rng.randf_range(-1.0, 1.0),
				rng.randf_range(-1.0, 1.0),
				rng.randf_range(-1.0, 1.0))
			if axis.length_squared() < 0.0001:
				axis = Vector3.UP
			var noisy_local := Transform3D(
				local.basis.rotated(axis.normalized(), angle_noise),
				local.origin + offset_noise)
			var joint_world: Transform3D = world[parent_joint] * noisy_local
			world[joint] = joint_world
			frame.set_joint(joint, joint_world, 0.008, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)

		frame.tracking_valid = true
		trace.append_frame(frame)
	return XRHandTracePlayer.new(trace)

func _test_hand_filter_dedup(failures: Array[String]) -> void:
	# Regression for the filter's own duplicate-frame guard (capture()'s
	# early-return that replays _output[hand] when the raw wrist transform
	# repeats). Its sibling in XRHandTraceRecorder has
	# _test_recorder_dedup_guard; this had zero coverage before. Frame 1
	# repeats frame 0's wrist exactly but moves the index finger a long way
	# -- if the guard fires, that finger motion must be invisible in the
	# output (replay, not refilter). Frame 2 moves the wrist for real,
	# proving the filter is not simply stuck.
	var trace := XRHandTrace.new()
	trace.append_frame(_dedup_probe_frame(0.05, 0.03, 0))
	trace.append_frame(_dedup_probe_frame(0.05, 0.09, 1))  # wrist unchanged, tip jumps
	trace.append_frame(_dedup_probe_frame(0.09, 0.03, 2))  # wrist changed for real

	var filter := XRHandFilter.new(XRHandTracePlayer.new(trace))
	var out0 := XRHandFrame.new()
	var out1 := XRHandFrame.new()
	var out2 := XRHandFrame.new()
	filter.capture(1, 0, out0)
	filter.capture(1, 0, out1)
	filter.capture(1, 0, out2)

	var tip_id := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
	var wrist_id := XRHandTracker.HAND_JOINT_WRIST
	if not out1.joint_transforms[tip_id].is_equal_approx(out0.joint_transforms[tip_id]):
		failures.append("duplicate raw wrist sample was not suppressed: tip output moved from %s to %s" % [
			str(out0.joint_transforms[tip_id].origin), str(out1.joint_transforms[tip_id].origin)])
	if not out1.joint_transforms[wrist_id].origin.is_equal_approx(out0.joint_transforms[wrist_id].origin):
		failures.append("duplicate raw wrist sample was not suppressed: wrist output changed")
	if out2.joint_transforms[wrist_id].origin.is_equal_approx(out1.joint_transforms[wrist_id].origin):
		failures.append("filter appears stuck: a genuinely new wrist sample produced no change")

func _dedup_probe_frame(wrist_x: float, tip_z: float, step: int) -> XRHandFrame:
	var frame := XRHandFrame.new()
	frame.begin_capture(1, step * 13888, step)  # ~72 Hz in microseconds
	frame.set_joint(
		XRHandTracker.HAND_JOINT_WRIST,
		Transform3D(Basis.IDENTITY, Vector3(wrist_x, 0, 0)),
		0.01, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
	frame.set_joint(
		XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL,
		Transform3D(Basis.IDENTITY, Vector3(0.02, 0.0, 0.0)),
		0.008, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
	frame.set_joint(
		XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,
		Transform3D(Basis.IDENTITY, Vector3(0.02, 0.0, tip_z)),
		0.008, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
	frame.tracking_valid = true
	return frame

## Pose source emitting a scripted validity pattern: `pattern[i]` true = tracked.
class _ScriptedSource extends XRHandPoseSource:
	var pattern: Array = []
	var index := 0
	var step_usec := 13888

	func capture(hand: int, _timestamp_usec: int, target: XRHandFrame) -> bool:
		if index >= pattern.size():
			return false
		var valid: bool = pattern[index]
		target.begin_capture(hand, index * step_usec, index)
		index += 1
		if valid:
			target.set_joint(
				XRHandTracker.HAND_JOINT_WRIST,
				Transform3D(Basis.IDENTITY, Vector3(0.5, 0, 0)),
				0.01, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
			target.tracking_valid = true
			return true
		target.tracking_valid = false
		return false

func _test_confidence_gate(failures: Array[String]) -> void:
	var first_source := _ScriptedSource.new()
	first_source.pattern = [true, true]
	var first_gate := XRHandConfidenceGate.new(first_source)
	var first_frame := XRHandFrame.new()

	# First acquisition alone must raise a discontinuity: the filter has no
	# history yet, so it must SEED from this first sample rather than blend
	# against uninitialised state. Checked in isolation, on its own gate, so a
	# later reacquisition's discontinuity cannot mask a missing one here.
	if not first_gate.capture(1, 0, first_frame):
		failures.append("gate rejected the very first tracked frame")
	if not first_gate.consume_discontinuity(1):
		failures.append("gate did not raise a discontinuity on first acquisition")
	if first_gate.consume_discontinuity(1):
		failures.append("first-acquisition discontinuity was not cleared after being consumed")

	# A discontinuity must fire once per acquisition event, not on every frame:
	# a second consecutive tracked frame with no dropout must not re-raise it.
	if not first_gate.capture(1, 0, first_frame):
		failures.append("gate rejected a normal consecutive tracked frame")
	if first_gate.consume_discontinuity(1):
		failures.append("gate raised a discontinuity on a normal frame with no dropout")

	var source := _ScriptedSource.new()
	# tracked, tracked, LOST, LOST, tracked
	source.pattern = [true, true, false, false, true]

	var gate := XRHandConfidenceGate.new(source)
	gate.hold_duration_sec = 0.25   # ~18 frames at 72 Hz, so both gaps are held
	var frame := XRHandFrame.new()

	if not gate.capture(1, 0, frame):
		failures.append("gate rejected a tracked frame")
	gate.capture(1, 0, frame)

	# During the dropout the gate must hold the last good pose, not vanish.
	if not gate.capture(1, 0, frame):
		failures.append("gate did not hold the last good frame through a dropout")
	if not frame.joint_transforms[XRHandTracker.HAND_JOINT_WRIST].origin.is_equal_approx(Vector3(0.5, 0, 0)):
		failures.append("held frame did not carry the last good pose")
	gate.capture(1, 0, frame)

	# Reacquisition must raise a discontinuity exactly once.
	gate.capture(1, 0, frame)
	if not gate.consume_discontinuity(1):
		failures.append("gate did not raise a discontinuity on reacquisition")
	if gate.consume_discontinuity(1):
		failures.append("discontinuity was not cleared after being consumed")

	# Past the hold window the gate must report invalid rather than hold forever.
	var expiring_source := _ScriptedSource.new()
	expiring_source.pattern = [true, false, false, false, false, false]
	var expiring := XRHandConfidenceGate.new(expiring_source)
	expiring.hold_duration_sec = 0.02   # ~1.4 frames at 72 Hz
	var expiring_frame := XRHandFrame.new()
	expiring.capture(1, 0, expiring_frame)
	expiring.capture(1, 0, expiring_frame)
	var still_valid := true
	for step in range(4):
		still_valid = expiring.capture(1, 0, expiring_frame)
	if still_valid:
		failures.append("gate held past hold_duration_sec instead of reporting invalid")

func _test_publisher(failures: Array[String]) -> void:
	var frame := XRHandFrame.new()
	frame.begin_capture(1, 12345, 1)
	frame.set_joint(
		XRHandTracker.HAND_JOINT_WRIST,
		Transform3D(Basis.IDENTITY, Vector3(0.25, 0.5, 0.75)),
		0.011,
		XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID)
	frame.tracking_valid = true

	var tracker := XRHandTracker.new()
	XRConditionedHandPublisher.write_frame_to_tracker(frame, tracker, XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED)

	if not tracker.has_tracking_data:
		failures.append("publisher did not mark the shadow tracker as tracking")
	var origin := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST).origin
	if not origin.is_equal_approx(Vector3(0.25, 0.5, 0.75)):
		failures.append("publisher wrote the wrong wrist origin: %s" % str(origin))
	if not is_equal_approx(tracker.get_hand_joint_radius(XRHandTracker.HAND_JOINT_WRIST), 0.011):
		failures.append("publisher did not carry the joint radius through")
	if (tracker.get_hand_joint_flags(XRHandTracker.HAND_JOINT_WRIST) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) == 0:
		failures.append("publisher did not carry joint flags through")
	# hand_tracking_source must survive, or the modality manager stops working.
	if tracker.hand_tracking_source != XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED:
		failures.append("publisher did not carry hand_tracking_source through")

	# An invalid frame must clear the tracking flag rather than freeze.
	var lost := XRHandFrame.new()
	lost.begin_capture(1, 12400, 2)
	lost.tracking_valid = false
	XRConditionedHandPublisher.write_frame_to_tracker(lost, tracker, XRHandTracker.HAND_TRACKING_SOURCE_UNKNOWN)
	if tracker.has_tracking_data:
		failures.append("publisher left has_tracking_data set after an invalid frame")

func _test_publisher_republish_cache(failures: Array[String]) -> void:
	# Regression for get_conditioned's per-render-frame memoization. That gate
	# is load-bearing, not incidental: it is what makes stale data structurally
	# impossible (access is what triggers a run) and what stops a second
	# consumer in the same render frame from re-driving the One Euro filter a
	# second time, which would corrupt its derivative estimate. get_conditioned
	# itself needs a live XRServer, which this headless suite has none of, so
	# drive the decision through _should_republish directly -- same shape as
	# XRHandTraceRecorder._should_record and XRHandConfidenceGate.consume_discontinuity.
	if not XRConditionedHandPublisher._should_republish(0, 100):
		failures.append("first call for a new frame number must republish")
	if XRConditionedHandPublisher._should_republish(0, 100):
		failures.append("second call with the same frame number must be suppressed")
	if not XRConditionedHandPublisher._should_republish(0, 101):
		failures.append("a new frame number must republish again")

	# The two hands cache independently: hand 1 must not be blocked by hand
	# 0's cached frame number, and must be suppressed by its own.
	if not XRConditionedHandPublisher._should_republish(1, 101):
		failures.append("hand 1 must not be blocked by hand 0's cached frame")
	if XRConditionedHandPublisher._should_republish(1, 101):
		failures.append("hand 1's second call with the same frame number must be suppressed")

func _test_publisher_tracker_registration(failures: Array[String]) -> void:
	# Regression for the missing tracker.name: unnamed shadow trackers all
	# default to "Unknown", collide inside XRServer's registry (publishing
	# hand 1 silently overwrites hand 0's entry), and are unreachable via the
	# documented TRACKER_NAMES contract that consumers rely on. Go through
	# XRServer.get_tracker by the documented name -- the exact path a
	# consumer would use -- rather than trusting the return value alone.
	var left: XRHandTracker = XRConditionedHandPublisher._ensure_tracker(0)
	var right: XRHandTracker = XRConditionedHandPublisher._ensure_tracker(1)

	var looked_up_left := XRServer.get_tracker(XRConditionedHandPublisher.TRACKER_NAMES[0])
	var looked_up_right := XRServer.get_tracker(XRConditionedHandPublisher.TRACKER_NAMES[1])

	if looked_up_left == null:
		failures.append("XRServer.get_tracker found no left conditioned tracker by name")
	if looked_up_right == null:
		failures.append("XRServer.get_tracker found no right conditioned tracker by name")
	if looked_up_left != null and looked_up_right != null and looked_up_left == looked_up_right:
		failures.append("left and right conditioned trackers collided into the same XRServer entry")
	if looked_up_left != left:
		failures.append("XRServer's left lookup did not match the tracker _ensure_tracker returned")
	if looked_up_right != right:
		failures.append("XRServer's right lookup did not match the tracker _ensure_tracker returned")
	if left != null and left.hand != XRPositionalTracker.TRACKER_HAND_LEFT:
		failures.append("left conditioned tracker has the wrong hand chirality")
	if right != null and right.hand != XRPositionalTracker.TRACKER_HAND_RIGHT:
		failures.append("right conditioned tracker has the wrong hand chirality")

	# Clean up: unregister from XRServer and reset the publisher's static
	# cache so this test leaves no global state behind and is safe to run
	# again in the same process.
	if XRServer.get_tracker(XRConditionedHandPublisher.TRACKER_NAMES[0]) != null:
		XRServer.remove_tracker(left)
	if XRServer.get_tracker(XRConditionedHandPublisher.TRACKER_NAMES[1]) != null:
		XRServer.remove_tracker(right)
	XRConditionedHandPublisher._trackers[0] = null
	XRConditionedHandPublisher._trackers[1] = null

func _test_publisher_null_contract(failures: Array[String]) -> void:
	# Regression: get_conditioned's cache-hit path used to return whatever
	# object sat in _trackers[hand], even when the publish() that cached it
	# was untracked. A consumer got null on a miss and a live tracker on the
	# very next call in the same render frame, purely depending on call
	# order. Reset the relevant static state first so this does not depend
	# on what earlier tests left behind and is safe to run twice.
	var hand := 0
	XRConditionedHandPublisher._published_frame[hand] = -1
	XRConditionedHandPublisher._last_tracked[hand] = false
	XRConditionedHandPublisher._trackers[hand] = null
	XRConditionedHandPublisher._frames[hand] = null

	# No raw hand tracker is registered anywhere in this headless run, so the
	# pose-source chain reports untracked. The first call is a genuine cache
	# MISS (it drives publish()); the second call, same process frame, is a
	# genuine cache HIT. Both go through the real get_conditioned code path.
	var miss_result := XRConditionedHandPublisher.get_conditioned(hand)
	var hit_result := XRConditionedHandPublisher.get_conditioned(hand)

	if miss_result != null:
		failures.append("expected an untracked cache miss to return null")
	if hit_result != null:
		failures.append("cache hit returned a tracker even though the publish that filled the cache was untracked")

	# Force a tracked outcome into the cache directly, through the same seam
	# get_conditioned itself reads, and confirm a hit then returns the
	# tracker rather than null -- proving the fix is a real per-hand
	# decision, not "always return null."
	XRConditionedHandPublisher._last_tracked[hand] = true
	XRConditionedHandPublisher._trackers[hand] = XRHandTracker.new()
	var tracked_hit := XRConditionedHandPublisher.get_conditioned(hand)
	if tracked_hit == null:
		failures.append("cache hit returned null even though the last publish was tracked")

	# Clean up: unregister whatever publish() actually added to XRServer and
	# reset static state so this test leaves no global state behind.
	var registered := XRServer.get_tracker(XRConditionedHandPublisher.TRACKER_NAMES[hand])
	if registered != null:
		XRServer.remove_tracker(registered)
	XRConditionedHandPublisher._trackers[hand] = null
	XRConditionedHandPublisher._frames[hand] = null
	XRConditionedHandPublisher._published_frame[hand] = -1
	XRConditionedHandPublisher._last_tracked[hand] = false

## Registers a raw hand tracker under the canonical path with joints the
## resolver will actually score as valid. The resolver only counts a joint when
## POSITION_VALID is set AND the origin is off the world origin, so degenerate
## zero transforms would score 0 and resolve to null.
func _make_raw_tracker(hand: int) -> XRHandTracker:
	var tracker := XRHandTracker.new()
	tracker.name = XRConditionedHandPublisher._RAW_NAMES[hand]
	tracker.hand = XRPositionalTracker.TRACKER_HAND_LEFT if hand == 0 else XRPositionalTracker.TRACKER_HAND_RIGHT
	tracker.has_tracking_data = true
	for joint in range(XRHandTracker.HAND_JOINT_MAX):
		tracker.set_hand_joint_transform(joint, Transform3D(Basis(), Vector3(0.1 + 0.001 * joint, 0.2, -0.3)))
		tracker.set_hand_joint_radius(joint, 0.01)
		tracker.set_hand_joint_flags(joint,
			XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID)
	XRServer.add_tracker(tracker)
	return tracker

func _clear_conditioning_state(hand: int) -> void:
	XRConditionedHandPublisher._published_frame[hand] = -1
	XRConditionedHandPublisher._last_tracked[hand] = false
	XRConditionedHandPublisher._frames[hand] = null
	var shadow := XRServer.get_tracker(XRConditionedHandPublisher.TRACKER_NAMES[hand])
	if shadow != null:
		XRServer.remove_tracker(shadow)
	XRConditionedHandPublisher._trackers[hand] = null
	XRHandTrackerResolver._cache_frame = -1

func _test_resolver_conditioned_routing(failures: Array[String]) -> void:
	# Task 9's whole claim in one test: a consumer calling get_tracker receives
	# the CONDITIONED shadow tracker, while the conditioning chain itself still
	# reads raw. If those two ever return the same object, the filter is
	# consuming its own output and the conditioning is silently a no-op.
	var hand := 0
	var was_conditioned := XRHandTrackerResolver.is_conditioned()
	var was_enabled := XRConditionedHandPublisher.is_enabled()
	var raw := _make_raw_tracker(hand)
	_clear_conditioning_state(hand)

	XRHandTrackerResolver._conditioned = true
	XRConditionedHandPublisher._enabled = true
	XRHandTrackerResolver._cache_frame = -1

	var resolved := XRHandTrackerResolver.get_tracker(hand)
	var raw_path := XRHandTrackerResolver.resolve_raw(hand)

	if raw_path != raw:
		failures.append("resolve_raw did not return the registered raw tracker")
	if resolved == null:
		failures.append("get_tracker returned null while a raw tracker was live and conditioning was on")
	elif resolved == raw:
		failures.append("get_tracker returned the RAW tracker while conditioning was on -- conditioning never reaches consumers")
	elif str(resolved.name) != str(XRConditionedHandPublisher.TRACKER_NAMES[hand]):
		failures.append("get_tracker returned '%s', expected the conditioned shadow tracker" % resolved.name)

	# Conditioning OFF must hand back the raw tracker -- this is the A/B leg,
	# and it is what makes the toggle a real comparison rather than a label.
	_clear_conditioning_state(hand)
	XRHandTrackerResolver._conditioned = false
	XRHandTrackerResolver._cache_frame = -1
	var off := XRHandTrackerResolver.get_tracker(hand)
	if off != raw:
		failures.append("with conditioning off, get_tracker must return the raw tracker")

	# Conditioning ON but the publisher yielding nothing must fall back to raw
	# rather than to null: consumers keep working when the chain is disabled.
	_clear_conditioning_state(hand)
	XRHandTrackerResolver._conditioned = true
	XRConditionedHandPublisher.set_enabled(false)
	XRHandTrackerResolver._cache_frame = -1
	var fallback := XRHandTrackerResolver.get_tracker(hand)
	if fallback != raw:
		failures.append("get_tracker must fall back to the raw tracker when the publisher yields nothing")

	# NOTE: resolve_raw's _valid_hand guard is deliberately NOT asserted here.
	# It is real and worth keeping -- it turns a bad hand id into a clean early
	# return instead of an invalid-key fault on TRACKER_PATHS plus a pointless
	# full-tracker scan -- but it is not observable through the return value:
	# mutation-testing the guard away leaves resolve_raw(7) still resolving to
	# null, just noisily. An assertion here would be one that cannot fail, so
	# this is recorded as an untested property rather than faked coverage.

	XRConditionedHandPublisher.set_enabled(was_enabled)
	XRHandTrackerResolver._conditioned = was_conditioned
	_clear_conditioning_state(hand)
	XRServer.remove_tracker(raw)

func _test_resolver_toggle_resets_chain(failures: Array[String]) -> void:
	# Carry-over from the Task 8 review. The chain only runs while conditioning
	# is ON, so across an off-leg the filter's timestamp and dedup wrist age by
	# the entire length of that leg. Without a reset, the first frame back
	# computes dt against the stale stamp, and the dedup shortcut can replay a
	# seconds-old output frame without even updating the timestamp.
	var hand := 0
	var was_conditioned := XRHandTrackerResolver.is_conditioned()
	var filter := XRConditionedHandPublisher.filter()

	XRHandTrackerResolver._conditioned = true
	filter._last_timestamp[hand] = 123456
	filter._has_output[hand] = true
	XRConditionedHandPublisher._published_frame[hand] = 99
	XRConditionedHandPublisher._last_tracked[hand] = true

	XRHandTrackerResolver.set_conditioned(false)

	if filter._last_timestamp[hand] != -1:
		failures.append("toggling conditioning left the filter's stale timestamp in place")
	if filter._has_output[hand]:
		failures.append("toggling conditioning left the filter's dedup output live")
	if XRConditionedHandPublisher._published_frame[hand] != -1:
		failures.append("toggling conditioning left the publisher's per-frame memo set")
	if XRConditionedHandPublisher._last_tracked[hand]:
		failures.append("toggling conditioning left the publisher's last-tracked flag set")

	# Idempotence matters: set_conditioned is a plain setter a caller may well
	# drive every frame from a UI toggle. Repeating the SAME value must not
	# reset, or the filter would be wiped every frame and never accumulate.
	filter._last_timestamp[hand] = 777
	XRHandTrackerResolver.set_conditioned(false)
	if filter._last_timestamp[hand] != 777:
		failures.append("set_conditioned reset the chain on a no-op repeat of the same value")

	XRHandTrackerResolver._conditioned = was_conditioned
	_clear_conditioning_state(hand)

func _test_pose_source_reads_raw_across_frames(failures: Array[String]) -> void:
	# The feedback loop this guards against does NOT show up on the first
	# publish: _last_tracked is still false then, so a re-entrant get_conditioned
	# returns null and falls back to raw by accident. It only bites from the
	# SECOND frame, once _last_tracked is true and the re-entrant call hands back
	# the shadow tracker -- at which point the filter is reading its own previous
	# output. So drive two frames and MOVE the raw pose between them: reading raw
	# tracks the move, consuming its own output cannot.
	var hand := 0
	var was_conditioned := XRHandTrackerResolver.is_conditioned()
	var was_enabled := XRConditionedHandPublisher.is_enabled()
	var wrist := XRHandTracker.HAND_JOINT_WRIST
	var raw := _make_raw_tracker(hand)
	_clear_conditioning_state(hand)
	XRHandTrackerResolver._conditioned = true
	XRConditionedHandPublisher._enabled = true

	# Frame 1: seeds the filter and, crucially, sets _last_tracked.
	XRConditionedHandPublisher._published_frame[hand] = -1
	XRHandTrackerResolver._cache_frame = -1
	var shadow := XRConditionedHandPublisher.get_conditioned(hand)
	if shadow == null:
		failures.append("frame 1 published nothing, so the two-frame feedback check cannot run")
		XRConditionedHandPublisher.set_enabled(was_enabled)
		XRHandTrackerResolver._conditioned = was_conditioned
		_clear_conditioning_state(hand)
		XRServer.remove_tracker(raw)
		return
	var after_first := shadow.get_hand_joint_transform(wrist).origin

	# Move the raw hand well clear of where it was.
	for joint in range(XRHandTracker.HAND_JOINT_MAX):
		var moved := raw.get_hand_joint_transform(joint)
		moved.origin += Vector3(0.25, 0.0, 0.0)
		raw.set_hand_joint_transform(joint, moved)

	# Frame 2: the frame that exposes the loop.
	XRConditionedHandPublisher._published_frame[hand] = -1
	XRHandTrackerResolver._cache_frame = -1
	XRConditionedHandPublisher.get_conditioned(hand)
	var after_second := shadow.get_hand_joint_transform(wrist).origin

	if after_second.distance_to(after_first) <= 0.0001:
		failures.append(
			"conditioned wrist did not move (%.5f m) after the raw hand moved 0.25 m -- " % after_second.distance_to(after_first)
			+ "the pose source is reading the conditioned tracker, so the filter is consuming its own output")

	XRConditionedHandPublisher.set_enabled(was_enabled)
	XRHandTrackerResolver._conditioned = was_conditioned
	_clear_conditioning_state(hand)
	XRServer.remove_tracker(raw)
