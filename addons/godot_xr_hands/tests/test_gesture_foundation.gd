extends SceneTree

const VALID := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID

func _init() -> void:
    var failures: Array[String] = []
    _test_feature_extraction(failures)
    _test_runtime_source_selection(failures)
    _test_condition_scoring(failures)
    _test_pose_presets(failures)
    _test_state_machine(failures)
    _test_thumb_microgestures(failures)
    _test_handedness_normalization(failures)
    _test_teleport_trajectory(failures)
    if failures.is_empty():
        print("XR gesture foundation: PASS")
        quit(0)
        return
    for failure in failures:
        push_error(failure)
    print("XR gesture foundation: FAIL (%d)" % failures.size())
    quit(1)

func _test_feature_extraction(failures: Array[String]) -> void:
    var frame := XRHandFrame.new()
    frame.begin_capture(0, 1000000, 1)
    _joint(frame, XRHandTracker.HAND_JOINT_WRIST, Vector3(0, 0, 0))
    _joint(frame, XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL, Vector3(-0.04, 0, 0.05))
    _joint(frame, XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL, Vector3(0.04, 0, 0.05))
    _joint(frame, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL, Vector3(0, 0, 0.10))
    _joint(frame, XRHandTracker.HAND_JOINT_THUMB_TIP, Vector3(0.035, 0, 0.12))
    _joint(frame, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP, Vector3(0.040, 0, 0.12))
    frame.tracking_valid = true
    var features := XRHandFeatureExtractor.new().extract(frame)
    if not features.valid:
        failures.append("feature extractor rejected a valid synthetic palm")
    if not is_equal_approx(features.palm_width, 0.08):
        failures.append("palm width was not measured correctly: %.4f" % features.palm_width)
    if features.pinch_distance >= 0.1:
        failures.append("pinch distance was not normalized: %.4f" % features.pinch_distance)

func _test_condition_scoring(failures: Array[String]) -> void:
    var features := XRHandFeatures.new()
    features.valid = true
    features.tracking_quality = 1.0
    features.pinch_distance = 0.2
    var condition := XRFeatureRangeCondition.new()
    condition.feature = XRHandFeatures.Feature.PINCH_DISTANCE
    condition.minimum = 0.0
    condition.maximum = 0.3
    if condition.evaluate(features) < 0.999:
        failures.append("feature range did not fully score an in-range pinch")

func _test_pose_presets(failures: Array[String]) -> void:
    var open_palm := load("res://addons/godot_xr_hands/presets/open_palm.tres") as XRGestureDefinition
    var fist := load("res://addons/godot_xr_hands/presets/fist.tres") as XRGestureDefinition
    var point := load("res://addons/godot_xr_hands/presets/point.tres") as XRGestureDefinition
    var pinch := load("res://addons/godot_xr_hands/presets/pinch.tres") as XRGestureDefinition
    if open_palm == null or fist == null or point == null or pinch == null:
        failures.append("one or more authored pose presets failed to load")
        return

    var open_features := _pose_features([0.15, 0.08, 0.1, 0.12, 0.14], 0.9)
    var fist_features := _pose_features([0.65, 0.82, 0.88, 0.8, 0.76], 0.5)
    var point_features := _pose_features([0.3, 0.1, 0.78, 0.82, 0.74], 0.85)
    var pinch_features := _pose_features([0.35, 0.25, 0.3, 0.3, 0.3], 0.18)
    if open_palm.evaluate(open_features) < 0.99:
        failures.append("open-palm preset rejected an open hand")
    if fist.evaluate(fist_features) < 0.99:
        failures.append("fist preset rejected a closed hand")
    if point.evaluate(point_features) < 0.99:
        failures.append("point preset rejected an extended index pose")
    if pinch.evaluate(pinch_features) < 0.99:
        failures.append("pinch preset rejected a close thumb/index pose")
    if open_palm.evaluate(fist_features) > 0.2:
        failures.append("open-palm preset also strongly matched a fist")

func _pose_features(curls: Array, pinch_distance: float) -> XRHandFeatures:
    var features := XRHandFeatures.new()
    features.valid = true
    features.tracking_quality = 1.0
    features.pinch_distance = pinch_distance
    for index in range(mini(curls.size(), features.finger_curls.size())):
        features.finger_curls[index] = float(curls[index])
    return features

func _test_state_machine(failures: Array[String]) -> void:
    var definition := XRGestureDefinition.new()
    definition.activation_threshold = 0.8
    definition.release_threshold = 0.5
    definition.activation_time = 0.05
    definition.release_time = 0.04
    definition.cooldown = 0.1
    var machine := XRGestureStateMachine.new()
    if machine.update(0.9, 0.01, definition) != XRGestureStateMachine.Transition.STARTED:
        failures.append("state machine did not enter candidate")
    if machine.update(0.9, 0.06, definition) != XRGestureStateMachine.Transition.PERFORMED:
        failures.append("state machine did not perform after activation hold")
    machine.update(0.0, 0.01, definition)
    if machine.update(0.0, 0.05, definition) != XRGestureStateMachine.Transition.ENDED:
        failures.append("state machine did not end after release hold")

func _test_thumb_microgestures(failures: Array[String]) -> void:
    var swipe := XRThumbMicrogestureRecognizer.new()
    var swipe_events: Array[int] = []
    swipe.microgesture_performed.connect(func(direction: int, _hand: int, _confidence: float) -> void:
        swipe_events.append(direction)
    )
    swipe.process_features(1, _micro_features(1000000, Vector3.ZERO, 0.5, 0.2, 0.45))
    swipe.process_features(1, _micro_features(1080000, Vector3(0.24, 0.0, 0.01), 0.5, 0.2, 0.72))
    swipe.process_features(1, _micro_features(1120000, Vector3(0.24, 0.0, 0.01), 0.5, 0.8, 0.72))
    if swipe_events != [XRThumbMicrogestureRecognizer.Direction.LEFT]:
        failures.append("palm-local thumb travel did not produce one left swipe")
    swipe.free()

    var early_swipe := XRThumbMicrogestureRecognizer.new()
    var early_events: Array[int] = []
    early_swipe.gesture_performed.connect(func(direction: int, _hand: int, _confidence: float) -> void:
        early_events.append(direction)
    )
    early_swipe.process_features(1, _micro_features(1500000, Vector3.ZERO, 0.5, 0.2, 0.45))
    early_swipe.process_features(1, _micro_features(1580000, Vector3.ZERO, 0.5, 0.2, 0.95))
    early_swipe.process_features(1, _micro_features(1660000, Vector3.ZERO, 0.5, 0.2, 0.95))
    if early_events != [XRMicrogestureSource.Gesture.LEFT]:
        failures.append("high-confidence swipe did not commit once before release")
    early_swipe.free()

    var tap := XRThumbMicrogestureRecognizer.new()
    var tap_events: Array[int] = []
    tap.microgesture_performed.connect(func(direction: int, _hand: int, _confidence: float) -> void:
        tap_events.append(direction)
    )
    tap.process_features(1, _micro_features(2000000, Vector3(0.1, 0.0, 0.1), 0.5, 0.2))
    tap.process_features(1, _micro_features(2080000, Vector3(0.105, 0.0, 0.1), 0.5, 0.8))
    if tap_events != [XRThumbMicrogestureRecognizer.Direction.TAP]:
        failures.append("short thumb contact did not produce one tap")
    tap.free()

    var rejected_pinch := XRThumbMicrogestureRecognizer.new()
    var pinch_events: Array[int] = []
    rejected_pinch.microgesture_performed.connect(func(direction: int, _hand: int, _confidence: float) -> void:
        pinch_events.append(direction)
    )
    var pinch := _micro_features(3000000, Vector3.ZERO, 0.1, 0.2, 0.98)
    pinch.finger_curls[XRHandFeatures.Finger.INDEX] = 0.05
    rejected_pinch.process_features(1, pinch)
    pinch = _micro_features(3080000, Vector3(0.3, 0.0, 0.0), 0.1, 0.2, 0.98)
    pinch.finger_curls[XRHandFeatures.Finger.INDEX] = 0.05
    rejected_pinch.process_features(1, pinch)
    if not pinch_events.is_empty():
        failures.append("ordinary pinch incorrectly passed the curled-hand microgesture gate")
    rejected_pinch.free()

    var pose := XRThumbPoseRecognizer.new()
    pose.activation_time = 0.1
    var pose_events: Array[int] = []
    var pose_end_events: Array[int] = []
    pose.pose_performed.connect(func(direction: int, _hand: int, _confidence: float) -> void:
        pose_events.append(direction)
    )
    pose.pose_ended.connect(func(direction: int, _hand: int) -> void:
        pose_end_events.append(direction)
    )
    var up := _micro_features(4000000, Vector3.ZERO, 0.7, 0.7)
    up.thumb_direction_origin = Vector3(0.0, 0.95, 0.0)
    up.finger_curls[XRHandFeatures.Finger.THUMB] = 0.05
    pose.process_features(1, up)
    up.timestamp_usec = 4120000
    pose.process_features(1, up)
    if pose_events != [XRThumbPoseRecognizer.Pose.UP]:
        failures.append("held fist plus extended thumb did not produce thumbs-up")
    var down := _micro_features(4450000, Vector3.ZERO, 0.7, 0.7)
    down.thumb_direction_origin = Vector3(0.0, -0.95, 0.0)
    down.finger_curls[XRHandFeatures.Finger.THUMB] = 0.05
    pose.process_features(1, down)
    down.timestamp_usec = 4570000
    pose.process_features(1, down)
    down.timestamp_usec = 4690000
    pose.process_features(1, down)
    if pose_events != [XRThumbPoseRecognizer.Pose.UP, XRThumbPoseRecognizer.Pose.DOWN]:
        failures.append("opposite thumb pose did not rearm without a neutral frame")
    if pose_end_events != [XRThumbPoseRecognizer.Pose.UP]:
        failures.append("thumb pose lifecycle did not end the previous maintained pose")
    var neutral := _micro_features(4900000, Vector3.ZERO, 0.2, 0.8)
    neutral.thumb_direction_origin = Vector3.ZERO
    neutral.finger_curls[XRHandFeatures.Finger.THUMB] = 1.0
    pose.process_features(1, neutral)
    if pose_end_events != [XRThumbPoseRecognizer.Pose.UP, XRThumbPoseRecognizer.Pose.DOWN]:
        failures.append("thumb pose lifecycle did not end when returning to neutral")
    pose.free()

    var tolerant_pose := XRThumbPoseRecognizer.new()
    tolerant_pose.activation_time = 0.09
    var tolerant_events: Array[int] = []
    tolerant_pose.pose_performed.connect(func(direction: int, _hand: int, _confidence: float) -> void:
        tolerant_events.append(direction)
    )
    var stable := _micro_features(7000000, Vector3.ZERO, 0.7, 0.7)
    stable.thumb_direction_origin = Vector3(0.0, 0.95, 0.0)
    stable.finger_curls[XRHandFeatures.Finger.THUMB] = 0.05
    tolerant_pose.process_features(1, stable)
    var dropout := _micro_features(7050000, Vector3.ZERO, 0.7, 0.7)
    dropout.thumb_direction_origin = Vector3.ZERO
    dropout.finger_curls[XRHandFeatures.Finger.THUMB] = 0.05
    tolerant_pose.process_features(1, dropout)
    dropout.timestamp_usec = 7100000
    tolerant_pose.process_features(1, dropout)
    stable.timestamp_usec = 7150000
    tolerant_pose.process_features(1, stable)
    if tolerant_events != [XRThumbPoseRecognizer.Pose.UP]:
        failures.append("brief thumb-pose tracking dropout restarted activation")
    tolerant_pose.free()

    var aim_pose := XRThumbPoseRecognizer.new()
    var aim_pose_end_events: Array[int] = []
    aim_pose.pose_ended.connect(func(direction: int, _hand: int) -> void:
        aim_pose_end_events.append(direction)
    )
    var aim_up := _micro_features(8000000, Vector3.ZERO, 0.7, 0.7)
    aim_up.thumb_direction_origin = Vector3(0.0, 0.95, 0.0)
    aim_up.finger_curls[XRHandFeatures.Finger.THUMB] = 0.05
    aim_pose.process_features(1, aim_up)
    aim_up.timestamp_usec = 8100000
    aim_pose.process_features(1, aim_up)
    var pitched_aim := _micro_features(8200000, Vector3.ZERO, 0.7, 0.7)
    pitched_aim.thumb_direction_origin = Vector3(0.0, 0.10, -0.995)
    pitched_aim.finger_curls[XRHandFeatures.Finger.THUMB] = 0.05
    aim_pose.process_features(1, pitched_aim)
    if not aim_pose_end_events.is_empty():
        failures.append("pitching the maintained thumbs-up pose incorrectly ended teleport aim")
    var open_aim := _micro_features(8300000, Vector3.ZERO, 0.7, 0.7)
    open_aim.thumb_direction_origin = Vector3(0.0, 0.10, -0.995)
    open_aim.finger_curls.fill(0.05)
    aim_pose.process_features(1, open_aim)
    if aim_pose_end_events != [XRThumbPoseRecognizer.Pose.UP]:
        failures.append("opening the hand did not end the maintained teleport pose")
    aim_pose.free()

    var angled_left_pose := XRThumbPoseRecognizer.new()
    var angled_left_events: Array[int] = []
    angled_left_pose.pose_performed.connect(func(direction: int, hand: int, _confidence: float) -> void:
        angled_left_events.append(direction if hand == 0 else -1)
    )
    var angled_left := _micro_features(8500000, Vector3.ZERO, 0.7, 0.7)
    angled_left.thumb_direction_origin = Vector3(-0.75, 0.32, -0.58).normalized()
    angled_left.finger_curls[XRHandFeatures.Finger.THUMB] = 0.10
    angled_left_pose.process_features(0, angled_left)
    angled_left.timestamp_usec = 8570000
    angled_left_pose.process_features(0, angled_left)
    if angled_left_events != [XRThumbPoseRecognizer.Pose.UP]:
        failures.append("naturally angled left thumb did not produce thumbs-up")
    angled_left_pose.free()

func _test_handedness_normalization(failures: Array[String]) -> void:
    var recognizer := XRThumbMicrogestureRecognizer.new()
    var events: Array[Array] = []
    recognizer.gesture_performed.connect(func(gesture: int, hand: int, _confidence: float) -> void:
        events.append([gesture, hand])
    )
    # Toward the fingertip is mirrored anatomically, but must produce the same
    # wearer-relative LEFT event for both hands.
    recognizer.process_features(1, _micro_features(5000000, Vector3.ZERO, 0.5, 0.2, 0.45))
    recognizer.process_features(1, _micro_features(5080000, Vector3.ZERO, 0.5, 0.2, 0.72))
    recognizer.process_features(1, _micro_features(5120000, Vector3.ZERO, 0.5, 0.8, 0.72))
    recognizer.process_features(0, _micro_features(6000000, Vector3.ZERO, 0.5, 0.2, 0.45))
    recognizer.process_features(0, _micro_features(6080000, Vector3.ZERO, 0.5, 0.2, 0.18))
    recognizer.process_features(0, _micro_features(6120000, Vector3.ZERO, 0.5, 0.8, 0.18))
    var expected := [
        [XRMicrogestureSource.Gesture.LEFT, 1],
        [XRMicrogestureSource.Gesture.LEFT, 0],
    ]
    if events != expected:
        failures.append("left/right hand normalization produced different gesture semantics: %s" % [events])
    recognizer.free()

func _test_teleport_trajectory(failures: Array[String]) -> void:
    var near := XRHandTeleportTrajectory.solve(
        Vector3(0.0, 1.0, 0.0),
        Vector3(0.0, -0.75, -0.661).normalized(),
        null,
        0.0,
        10.5,
        10.0,
        2.0,
        80,
        1,
        0.55
    )
    var far := XRHandTeleportTrajectory.solve(
        Vector3(0.0, 1.0, 0.0),
        Vector3(0.0, 0.45, -0.893).normalized(),
        null,
        0.0,
        10.5,
        10.0,
        2.0,
        80,
        1,
        0.55
    )
    if not bool(near["valid"]) or not bool(far["valid"]):
        failures.append("projectile teleport arc did not reach the floor")
        return
    var near_distance := Vector3(near["target"]).length()
    var far_distance := Vector3(far["target"]).length()
    if near_distance >= 1.5:
        failures.append("downward hand pitch could not place a teleport target within 1.5 meters")
    if far_distance <= near_distance + 6.0:
        failures.append("hand pitch did not provide meaningful near/far teleport control")

func _micro_features(timestamp_usec: int, thumb_position: Vector3, pinch_distance: float, side_distance: float, contact_position := 0.5) -> XRHandFeatures:
    var features := XRHandFeatures.new()
    features.valid = true
    features.tracking_quality = 1.0
    features.timestamp_usec = timestamp_usec
    features.thumb_tip_local = thumb_position
    features.pinch_distance = pinch_distance
    features.thumb_index_side_distance = side_distance
    features.thumb_index_contact_position = contact_position
    for finger in range(XRHandFeatures.Finger.INDEX, XRHandFeatures.Finger.PINKY + 1):
        features.finger_curls[finger] = 0.8
    return features

func _joint(frame: XRHandFrame, joint: int, position: Vector3) -> void:
    frame.set_joint(joint, Transform3D(Basis.IDENTITY, position), 0.008, VALID)

func _test_runtime_source_selection(failures: Array[String]) -> void:
    # The gesture runtime used to hard-code XRTrackerHandPoseSource, which
    # Task 9 pointed at resolve_raw -- so recognition read RAW joints while
    # every other consumer had moved to conditioned. The choice is now
    # explicit and switchable, because the recognizers' thresholds were tuned
    # against raw data and which one wins is an on-device question.
    var conditioned := XRGestureRuntime.default_pose_source(true)
    if not (conditioned is XRConditionedHandPoseSource):
        failures.append("conditioned selection must yield XRConditionedHandPoseSource, got %s" % conditioned)
    var raw := XRGestureRuntime.default_pose_source(false)
    if not (raw is XRTrackerHandPoseSource):
        failures.append("raw selection must yield XRTrackerHandPoseSource, got %s" % raw)
    if raw is XRConditionedHandPoseSource:
        failures.append("the raw source must not be the conditioned one -- the A/B would compare a thing with itself")

    # Flipping at runtime must actually swap the source, and a repeat of the
    # same value must not rebuild it (a caller driving this per frame would
    # otherwise thrash acquisition).
    var runtime := XRGestureRuntime.new()
    runtime.use_conditioned_hands = false
    runtime.set_pose_source(XRGestureRuntime.default_pose_source(false))
    var before = runtime._pose_source
    runtime.set_use_conditioned_hands(true)
    if runtime._pose_source == before:
        failures.append("flipping the flag must swap the acquisition source")
    if not (runtime._pose_source is XRConditionedHandPoseSource):
        failures.append("flipping to conditioned must install the conditioned source")
    var after = runtime._pose_source
    runtime.set_use_conditioned_hands(true)
    if runtime._pose_source != after:
        failures.append("repeating the same value must not rebuild the source")
    runtime.free()
