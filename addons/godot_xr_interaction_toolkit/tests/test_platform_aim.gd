extends SceneTree

## Headless tests for platform-first hand aim in XRControllerHandAdapter.
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_interaction_toolkit/tests/test_platform_aim.gd
##
## The contract under test (XR_INPUT_PRACTICES.md Practice 3): when the
## runtime publishes its own aim pose for a TRACKED hand, _hand_aim_pose uses
## it; when it does not, the wrist->knuckle derivation is the fallback and
## must behave exactly as before. The liveness gate matters because the same
## controller node carries a physically held controller's aim pose -- without
## the gate a held controller would masquerade as a hand ray.

const XRControllerHandAdapterScript := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_controller_hand_adapter.gd")
const XRHandGestureProviderScript := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_gesture_provider.gd")
const XRHandTrackerResolverScript := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")

const VALID_AND_TRACKED := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED

const DT := 1.0 / 72.0

## A pose no derivation of the fixture joints could produce, so equality with
## it proves the platform path was taken and inequality proves it was not.
const PLATFORM_ORIGIN := Vector3(0.05, 1.10, -0.15)
const PLATFORM_DIRECTION := Vector3(0.6, -0.4, -0.7)

var _was_conditioned := true
var _ran := false


## Overrides the runtime-read seam only. The hand-liveness gate stays in
## _hand_aim_pose, where the real code has it, so these tests exercise it.
class _StubAdapter extends XRControllerHandAdapterScript:
	var platform_pose := {}

	func _platform_aim_pose(_hand_id: int) -> Dictionary:
		return platform_pose


## Runs on the first frame, NOT in _init: the derived-ray fallback reads
## _origin.global_transform, which requires the origin to be inside the tree,
## and SceneTree::initialize() fires script virtuals BEFORE root enters the
## tree (root->_set_tree comes after MainLoop::initialize() -- read from
## source, scene/main/scene_tree.cpp:586-591). By the first process frame the
## root is live and in-tree fixtures work.
func _process(_delta: float) -> bool:
	if _ran:
		return false
	_ran = true
	_run_all()
	return false


func _run_all() -> void:
	_was_conditioned = XRHandTrackerResolverScript.is_conditioned()
	XRHandTrackerResolverScript._conditioned = false
	XRHandTrackerResolverScript._cache_frame = -1

	var failures: Array[String] = []
	_test_platform_pose_wins_when_hand_live(failures)
	_test_derived_fallback_when_platform_absent(failures)
	_test_toggle_off_keeps_derived(failures)
	_test_platform_pose_needs_live_hand(failures)
	_test_withheld_platform_holds_last_ray(failures)
	_test_full_loss_within_grace_holds_ray(failures)
	_test_full_loss_beyond_grace_expires(failures)
	_test_micro_withhold_resumes_instantly(failures)
	_test_park_predates_the_terminal_wander(failures)
	_test_republish_after_park_resumes_instantly(failures)
	_test_gap_ray_follows_the_live_hand(failures)
	_test_gap_ray_rotates_with_the_live_hand(failures)
	_test_stable_gap_parks_on_the_last_pose(failures)
	_test_live_blip_does_not_pop_the_gap_pose(failures)

	XRHandTrackerResolverScript._conditioned = _was_conditioned
	XRHandTrackerResolverScript._cache_frame = -1

	if failures.is_empty():
		print("XR platform aim: PASS")
		quit(0)
	else:
		for f in failures:
			push_error(f)
		print("XR platform aim: FAIL (%d)" % failures.size())
		quit(1)


## Joint layout borrowed from test_hand_ray_symmetry's right hand: a plausible
## pointing pose whose wrist->knuckle derivation yields a real, non-degenerate
## ray for the fallback assertions.
func _make_tracker(live: bool) -> XRHandTracker:
	var tracker := XRHandTracker.new()
	tracker.name = XRHandTrackerResolverScript.TRACKER_PATHS[XRControllerHandAdapterScript.Hand.RIGHT]
	tracker.hand = XRPositionalTracker.TRACKER_HAND_RIGHT
	tracker.has_tracking_data = live

	var positions := {
		XRHandTracker.HAND_JOINT_WRIST: Vector3(0.10, 1.00, -0.20),
		XRHandTracker.HAND_JOINT_PALM: Vector3(0.10, 1.03, -0.26),
		XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL: Vector3(0.08, 1.05, -0.30),
		XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL: Vector3(0.09, 1.03, -0.25),
		XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL: Vector3(0.14, 1.05, -0.29),
		XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL: Vector3(0.13, 1.03, -0.24),
		XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL: Vector3(0.12, 1.05, -0.30),
		XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL: Vector3(0.10, 1.05, -0.31),
	}
	for joint in positions:
		tracker.set_hand_joint_transform(joint, Transform3D(Basis(), positions[joint]))
		tracker.set_hand_joint_flags(joint, VALID_AND_TRACKED)
	return tracker


## Builds the adapter + origin + registered tracker every test uses. Filters
## are off so the pose that comes back IS the source pose and equality
## assertions are exact rather than threshold-dependent.
func _arrange(live_hand: bool, prefer_platform: bool, platform_pose: Dictionary) -> Dictionary:
	var origin := Node3D.new()
	root.add_child(origin)

	var adapter := _StubAdapter.new()
	adapter.use_aim_stabilizer = false
	adapter.smooth_hand_aim = false
	adapter.prefer_platform_aim = prefer_platform
	adapter.platform_pose = platform_pose
	adapter._origin = origin

	var tracker := _make_tracker(live_hand)
	XRServer.add_tracker(tracker)
	XRHandTrackerResolverScript._cache_frame = -1

	return {"adapter": adapter, "origin": origin, "tracker": tracker}


func _teardown(fixture: Dictionary) -> void:
	XRServer.remove_tracker(fixture["tracker"])
	XRHandTrackerResolverScript._cache_frame = -1
	(fixture["origin"] as Node3D).get_parent().remove_child(fixture["origin"])
	(fixture["origin"] as Node3D).free()
	(fixture["adapter"] as Node).free()


func _platform_stub_pose() -> Dictionary:
	var direction := PLATFORM_DIRECTION.normalized()
	return {
		"origin": PLATFORM_ORIGIN,
		"direction": direction,
		"basis": XRHandGestureProviderScript.basis_from_forward(direction),
	}


func _test_platform_pose_wins_when_hand_live(failures: Array[String]) -> void:
	var fixture := _arrange(true, true, _platform_stub_pose())
	var pose: Dictionary = fixture["adapter"]._hand_aim_pose(XRControllerHandAdapterScript.Hand.RIGHT)

	if pose.is_empty():
		failures.append("platform pose available and hand live, but _hand_aim_pose returned nothing")
	elif not (pose["direction"] as Vector3).is_equal_approx(PLATFORM_DIRECTION.normalized()):
		failures.append("hand live with a platform pose available must return the platform direction, got %s" % pose["direction"])
	elif not (pose["origin"] as Vector3).is_equal_approx(PLATFORM_ORIGIN):
		failures.append("hand live with a platform pose available must return the platform origin, got %s" % pose["origin"])
	_teardown(fixture)


func _test_derived_fallback_when_platform_absent(failures: Array[String]) -> void:
	var fixture := _arrange(true, true, {})
	var pose: Dictionary = fixture["adapter"]._hand_aim_pose(XRControllerHandAdapterScript.Hand.RIGHT)
	var expected: Dictionary = XRHandGestureProviderScript.get_hand_ray_pose(fixture["tracker"])

	if pose.is_empty() or expected.is_empty():
		failures.append("no platform pose must fall back to the derived ray, not to nothing")
	elif not (pose["direction"] as Vector3).is_equal_approx(expected["direction"] as Vector3):
		failures.append("fallback direction must be the derived ray's, got %s expected %s" % [pose["direction"], expected["direction"]])
	_teardown(fixture)


func _test_toggle_off_keeps_derived(failures: Array[String]) -> void:
	var fixture := _arrange(true, false, _platform_stub_pose())
	var pose: Dictionary = fixture["adapter"]._hand_aim_pose(XRControllerHandAdapterScript.Hand.RIGHT)
	var expected: Dictionary = XRHandGestureProviderScript.get_hand_ray_pose(fixture["tracker"])

	if pose.is_empty() or expected.is_empty():
		failures.append("prefer_platform_aim=false must still produce the derived ray")
	elif not (pose["direction"] as Vector3).is_equal_approx(expected["direction"] as Vector3):
		failures.append("prefer_platform_aim=false must ignore the platform pose, got %s" % pose["direction"])
	_teardown(fixture)


## The on-device left-hand bug: a runtime that HAS been publishing withholds
## the pose for frames it does not trust (hand leaving view). Switching to
## the derived ray for those frames swings the visible line by the measured
## 40-52 deg separation -- so the ray must park on the platform pose instead.
## A never-published runtime (Link) must keep the derived fallback; that path
## is pinned by _test_derived_fallback_when_platform_absent above.
## State is driven through _process because that is the single writer the
## real frame loop uses; _hand_aim_pose is a pure reader.
func _test_withheld_platform_holds_last_ray(failures: Array[String]) -> void:
	var fixture := _arrange(true, true, _platform_stub_pose())
	var adapter: _StubAdapter = fixture["adapter"]

	adapter._process(DT)
	var first: Dictionary = adapter._hand_aim_pose(XRControllerHandAdapterScript.Hand.RIGHT)
	adapter.platform_pose = {}
	adapter._process(DT)
	var second: Dictionary = adapter._hand_aim_pose(XRControllerHandAdapterScript.Hand.RIGHT)

	if first.is_empty() or second.is_empty():
		failures.append("hold test fixture produced an empty pose where both calls must yield one")
	elif not (second["direction"] as Vector3).is_equal_approx(PLATFORM_DIRECTION.normalized()):
		failures.append("a withheld platform pose must park on the platform ray, not swing to the derived ray -- got %s" % second["direction"])
	elif not (second["origin"] as Vector3).is_equal_approx(PLATFORM_ORIGIN):
		failures.append("a withheld platform pose must park on the platform origin, got %s" % second["origin"])
	_teardown(fixture)


## Makes the fixture's tracker look like a REAL full loss: no tracking data
## and no usable joints, which is what the runtime reports once a hand has
## left the user's view (measured: valid=0 tracked=0).
func _lose_tracking(tracker: XRHandTracker) -> void:
	tracker.has_tracking_data = false
	for joint in range(XRHandTracker.HAND_JOINT_MAX):
		tracker.set_hand_joint_flags(joint, 0)
	XRHandTrackerResolverScript._cache_frame = -1


## The on-device disappearance: a hand out of view loses ALL tracker data,
## the FOV gate misreads the extrapolated terminal frames as an in-view loss
## and expires the hand, and the ray vanished. Within the grace window the
## ray must stay parked on the platform aim instead.
func _test_full_loss_within_grace_holds_ray(failures: Array[String]) -> void:
	var fixture := _arrange(true, true, _platform_stub_pose())
	var adapter: _StubAdapter = fixture["adapter"]

	adapter._process(DT)
	var first: Dictionary = adapter._hand_aim_pose(XRControllerHandAdapterScript.Hand.RIGHT)
	_lose_tracking(fixture["tracker"])
	adapter._process(DT)
	adapter._hand_loss_elapsed[XRControllerHandAdapterScript.Hand.RIGHT] = 1.0
	var lost: Dictionary = adapter._hand_aim_pose(XRControllerHandAdapterScript.Hand.RIGHT)

	if first.is_empty() or lost.is_empty():
		failures.append("a full loss within the grace window must keep the ray, not hide it")
	elif not (lost["direction"] as Vector3).is_equal_approx(PLATFORM_DIRECTION.normalized()):
		failures.append("the ray held across a full loss must be the parked platform ray, got %s" % lost["direction"])
	_teardown(fixture)


## And the bound: a hand that stays lost past the grace window is genuinely
## gone, and the ray must hide -- holding forever would park a ray in the
## scene after the user lowered their hand for good.
func _test_full_loss_beyond_grace_expires(failures: Array[String]) -> void:
	var fixture := _arrange(true, true, _platform_stub_pose())
	var adapter: _StubAdapter = fixture["adapter"]

	adapter._process(DT)
	_lose_tracking(fixture["tracker"])
	adapter._process(DT)
	adapter._hand_loss_elapsed[XRControllerHandAdapterScript.Hand.RIGHT] = adapter.platform_aim_hold_sec + 1.0
	var lost: Dictionary = adapter._hand_aim_pose(XRControllerHandAdapterScript.Hand.RIGHT)

	if not lost.is_empty():
		failures.append("a loss beyond the grace window must hide the ray, got %s" % [lost])
	_teardown(fixture)


## The on-device "stuck" regression, pinned so it cannot come back: a short
## withhold on an otherwise well-tracked hand is ROUTINE, and it must coast
## on the last pose and go straight back to live on the next published
## frame. Parking it -- and demanding a resume window before trusting the
## stream again -- froze the ray in ordinary use.
func _test_micro_withhold_resumes_instantly(failures: Array[String]) -> void:
	var fixture := _arrange(true, true, _platform_stub_pose())
	var adapter: _StubAdapter = fixture["adapter"]
	var moved_direction := Vector3(-0.4, 0.1, -0.9).normalized()

	adapter._process(DT)
	adapter.platform_pose = {}
	adapter._process(DT)  # one withheld frame: bridge, must NOT park
	adapter.platform_pose = {
		"origin": PLATFORM_ORIGIN,
		"direction": moved_direction,
		"basis": XRHandGestureProviderScript.basis_from_forward(moved_direction),
	}
	adapter._process(DT)
	var resumed: Dictionary = adapter._hand_aim_pose(XRControllerHandAdapterScript.Hand.RIGHT)

	if resumed.is_empty() or not (resumed["direction"] as Vector3).is_equal_approx(moved_direction):
		failures.append("one withheld frame must resume on the very next published pose, got %s" % [resumed])
	_teardown(fixture)


## The residual artifact after the holds above: the runtime's LAST published
## poses before it withholds are extrapolated garbage (measured: the left
## aim swung ~60 deg upward across ~0.4 s while the wrist hallucinated
## movement), so parking on the newest pose parks displaced -- "it shifts a
## little when I go out of view". The park must come from BEFORE that
## window: the newest buffered sample older than
## platform_aim_park_backtime_sec.
func _test_park_predates_the_terminal_wander(failures: Array[String]) -> void:
	var fixture := _arrange(true, true, _platform_stub_pose())
	var adapter: _StubAdapter = fixture["adapter"]
	var wander_direction := Vector3(0.05, 0.95, -0.10).normalized()

	# A healthy, aimed pose from a settled stream ages past the backtime
	# window (streak preset past the push warmup, as minutes of tracking
	# would leave it)...
	adapter._aim_healthy_streak[XRControllerHandAdapterScript.Hand.RIGHT] = 1.0
	adapter._process(DT)
	adapter._aim_clock += adapter.platform_aim_park_backtime_sec + 0.1
	# ...then the terminal wander publishes garbage right before the loss.
	adapter.platform_pose = {
		"origin": PLATFORM_ORIGIN,
		"direction": wander_direction,
		"basis": XRHandGestureProviderScript.basis_from_forward(wander_direction),
	}
	adapter._process(DT)
	adapter.platform_pose = {}
	adapter._process(DT)  # gap starts: offset calibrated from the wander tail
	adapter._aim_bad_elapsed[XRControllerHandAdapterScript.Hand.RIGHT] = adapter.platform_aim_fill_sec - DT * 0.5
	adapter._process(DT)  # crosses the fill boundary: wander recalibration fires
	var parked: Dictionary = adapter._hand_aim_pose(XRControllerHandAdapterScript.Hand.RIGHT)

	if parked.is_empty():
		failures.append("the park test must yield a parked pose, got nothing")
	elif (parked["direction"] as Vector3).is_equal_approx(wander_direction):
		failures.append("the ray parked ON the terminal wander -- it must park on the pose from before the backtime window")
	elif not (parked["direction"] as Vector3).is_equal_approx(PLATFORM_DIRECTION.normalized()):
		failures.append("the parked direction must be the aged healthy pose, got %s" % parked["direction"])
	_teardown(fixture)


## The second on-device rejection, pinned: after the ray has parked, the
## very next published pose must drive it -- no resume clock, no
## prove-you-are-healthy window. The version that demanded a continuous
## healthy streak before un-parking left the left ray floating detached
## from a perfectly tracked hand ("the ray was independent of the hand"),
## because dirty-but-usable streams never satisfied the streak.
func _test_republish_after_park_resumes_instantly(failures: Array[String]) -> void:
	var fixture := _arrange(true, true, _platform_stub_pose())
	var adapter: _StubAdapter = fixture["adapter"]
	var return_direction := Vector3(-0.3, 0.2, -0.9).normalized()

	adapter._process(DT)
	adapter.platform_pose = {}
	adapter._aim_bad_elapsed[XRControllerHandAdapterScript.Hand.RIGHT] = adapter.platform_aim_fill_sec
	adapter._process(DT)  # gap past the fill window: parked
	adapter.platform_pose = {
		"origin": PLATFORM_ORIGIN,
		"direction": return_direction,
		"basis": XRHandGestureProviderScript.basis_from_forward(return_direction),
	}
	adapter._process(DT)
	var resumed: Dictionary = adapter._hand_aim_pose(XRControllerHandAdapterScript.Hand.RIGHT)

	if resumed.is_empty() or not (resumed["direction"] as Vector3).is_equal_approx(return_direction):
		failures.append("the first republished pose after a park must drive the ray immediately, got %s" % [resumed])
	_teardown(fixture)


## The third on-device report: "the left ray and cursor were separate from
## the hand". A long gap on a hand that is STILL TRACKED parks the ray in
## space while the visible hand walks away from it. The gap pose must
## translate with the hand (palm-anchored delta, the pinch stabilizer's own
## mechanism); only the direction is held.
func _test_gap_ray_follows_the_live_hand(failures: Array[String]) -> void:
	var fixture := _arrange(true, true, _platform_stub_pose())
	var adapter: _StubAdapter = fixture["adapter"]
	var tracker: XRHandTracker = fixture["tracker"]
	var shift := Vector3(0.25, 0.0, 0.1)

	adapter._process(DT)
	adapter.platform_pose = {}
	adapter._process(DT)  # gap starts; anchor captured from the palm
	for joint in [XRHandTracker.HAND_JOINT_PALM, XRHandTracker.HAND_JOINT_WRIST]:
		var joint_transform := tracker.get_hand_joint_transform(joint)
		joint_transform.origin += shift
		tracker.set_hand_joint_transform(joint, joint_transform)
	XRHandTrackerResolverScript._cache_frame = -1
	adapter._process(DT)  # next frame: gap display recomputed from the moved palm
	var followed: Dictionary = adapter._hand_aim_pose(XRControllerHandAdapterScript.Hand.RIGHT)

	if followed.is_empty():
		failures.append("a gap on a live hand must still yield a pose")
	elif not (followed["origin"] as Vector3).is_equal_approx(PLATFORM_ORIGIN + shift):
		failures.append("the gap ray must translate with the tracked hand, got origin %s expected %s" % [followed["origin"], PLATFORM_ORIGIN + shift])
	elif not (followed["direction"] as Vector3).is_equal_approx(PLATFORM_DIRECTION.normalized()):
		failures.append("the gap ray's direction must stay held while the origin follows, got %s" % followed["direction"])
	_teardown(fixture)


## The measured left-hand churn (a gap every ~2 s in ordinary use, zero on
## the right) means the gap display must keep MOVING with a tracked hand,
## not freeze: the palm frame drives the direction through the calibrated
## gap-start offset. A palm rotation during the gap must rotate the ray.
func _test_gap_ray_rotates_with_the_live_hand(failures: Array[String]) -> void:
	var fixture := _arrange(true, true, _platform_stub_pose())
	var adapter: _StubAdapter = fixture["adapter"]
	var tracker: XRHandTracker = fixture["tracker"]
	var turn := Basis(Vector3.UP, deg_to_rad(30.0))

	adapter._process(DT)
	adapter.platform_pose = {}
	adapter._process(DT)  # gap starts; offset calibrated against identity palm
	for joint in [XRHandTracker.HAND_JOINT_PALM, XRHandTracker.HAND_JOINT_WRIST]:
		var joint_transform := tracker.get_hand_joint_transform(joint)
		joint_transform.basis = turn
		tracker.set_hand_joint_transform(joint, joint_transform)
	XRHandTrackerResolverScript._cache_frame = -1
	adapter._process(DT)
	var followed: Dictionary = adapter._hand_aim_pose(XRControllerHandAdapterScript.Hand.RIGHT)
	var expected := (turn * PLATFORM_DIRECTION.normalized()).normalized()

	if followed.is_empty():
		failures.append("a gap on a live hand must still yield a pose")
	elif not (followed["direction"] as Vector3).is_equal_approx(expected):
		failures.append("the gap ray must rotate with the tracked palm, got %s expected %s" % [followed["direction"], expected])
	_teardown(fixture)


## Seam removed after "there is a slight movement that the left does when
## looking away": the measured look-away gap has a near-stationary tail
## (~2 deg from the aged history), and hopping to the aged pose at the fill
## boundary moved the ray backward for no benefit. When tail and history
## agree, the tail wins and there is NO seam; the aged pose is only for the
## genuine wander (pinned by _test_park_predates_the_terminal_wander).
func _test_stable_gap_parks_on_the_last_pose(failures: Array[String]) -> void:
	var fixture := _arrange(true, true, _platform_stub_pose())
	var adapter: _StubAdapter = fixture["adapter"]
	var drifted_direction := PLATFORM_DIRECTION.normalized().rotated(Vector3.UP, deg_to_rad(2.0))

	adapter._aim_healthy_streak[XRControllerHandAdapterScript.Hand.RIGHT] = 1.0
	adapter._process(DT)  # history: the original pose, aged below
	adapter._aim_clock += adapter.platform_aim_park_backtime_sec + 0.1
	adapter.platform_pose = {
		"origin": PLATFORM_ORIGIN,
		"direction": drifted_direction,
		"basis": XRHandGestureProviderScript.basis_from_forward(drifted_direction),
	}
	adapter._process(DT)  # tail: 2 deg away -- ordinary aim drift, not wander
	adapter.platform_pose = {}
	adapter._process(DT)  # gap starts: offset calibrated from the stable tail
	adapter._aim_bad_elapsed[XRControllerHandAdapterScript.Hand.RIGHT] = adapter.platform_aim_fill_sec - DT * 0.5
	adapter._process(DT)  # crosses the fill boundary: tail agrees, no recalibration
	var parked: Dictionary = adapter._hand_aim_pose(XRControllerHandAdapterScript.Hand.RIGHT)

	if parked.is_empty() or not (parked["direction"] as Vector3).is_equal_approx(drifted_direction):
		failures.append("a stable tail must park on the LAST pose, not hop back to the aged history -- got %s" % [parked.get("direction")])
	_teardown(fixture)


## The measured gaps contain one-frame liveness blips (hand_live flickers
## false mid-gap). The displayed gap pose must not move on such a frame --
## recomputing it without the palm translation popped the origin, part of
## the residual "slight movement".
func _test_live_blip_does_not_pop_the_gap_pose(failures: Array[String]) -> void:
	var fixture := _arrange(true, true, _platform_stub_pose())
	var adapter: _StubAdapter = fixture["adapter"]
	var tracker: XRHandTracker = fixture["tracker"]
	var shift := Vector3(0.25, 0.0, 0.1)

	adapter._process(DT)
	adapter.platform_pose = {}
	adapter._process(DT)
	for joint in [XRHandTracker.HAND_JOINT_PALM, XRHandTracker.HAND_JOINT_WRIST]:
		var joint_transform := tracker.get_hand_joint_transform(joint)
		joint_transform.origin += shift
		tracker.set_hand_joint_transform(joint, joint_transform)
	XRHandTrackerResolverScript._cache_frame = -1
	adapter._process(DT)
	var before_blip: Dictionary = adapter._hand_aim_pose(XRControllerHandAdapterScript.Hand.RIGHT)

	tracker.has_tracking_data = false
	XRHandTrackerResolverScript._cache_frame = -1
	adapter._process(DT)  # the blip frame
	var during_blip: Dictionary = adapter._hand_aim_pose(XRControllerHandAdapterScript.Hand.RIGHT)

	if before_blip.is_empty() or during_blip.is_empty():
		failures.append("the blip test must yield a pose on both sides of the blip")
	elif not (during_blip["origin"] as Vector3).is_equal_approx(before_blip["origin"] as Vector3):
		failures.append("a liveness blip must not move the gap pose: origin popped from %s to %s" % [before_blip["origin"], during_blip["origin"]])
	_teardown(fixture)


## The gate. A registered tracker with no tracking data is exactly what a
## physically held controller session looks like to this code path: the
## controller node has an aim pose, the hand tracker exists but is not live.
## The platform pose must NOT leak through as a hand ray.
func _test_platform_pose_needs_live_hand(failures: Array[String]) -> void:
	var fixture := _arrange(false, true, _platform_stub_pose())
	var pose: Dictionary = fixture["adapter"]._hand_aim_pose(XRControllerHandAdapterScript.Hand.RIGHT)

	if not pose.is_empty() and (pose["direction"] as Vector3).is_equal_approx(PLATFORM_DIRECTION.normalized()):
		failures.append("a non-live hand took the platform pose -- a held controller would masquerade as a hand ray")
	_teardown(fixture)
