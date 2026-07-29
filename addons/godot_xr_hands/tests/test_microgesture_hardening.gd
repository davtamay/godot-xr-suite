extends SceneTree

## Headless tests for the tier-1 recognizer hardening (see
## docs/microgesture-hardening-design.md): exact frame-rate compensation,
## discontinuity consumption, and suspend-not-reset on bad frames.
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_hands/tests/test_microgesture_hardening.gd

const DT72_USEC := 13889  # one 72 Hz frame in usec, the reference rate


func _init() -> void:
    var failures: Array[String] = []
    _test_smoothing_composes_exactly_across_frame_times(failures)
    _test_reference_rate_behaviour_is_unchanged(failures)
    _test_discontinuity_frame_cannot_commit_a_phantom_swipe(failures)
    _test_discontinuity_frame_does_not_arm(failures)
    _test_bad_frame_suspends_instead_of_aborting(failures)
    _test_bad_frame_does_not_disarm_the_cooldown(failures)
    _test_grace_exceeded_aborts_without_emitting(failures)
    _test_runtime_stamps_discontinuity_from_its_source(failures)

    if failures.is_empty():
        print("XR microgesture hardening: PASS")
        quit(0)
    else:
        for f in failures:
            push_error(f)
        print("XR microgesture hardening: FAIL (%d)" % failures.size())
        quit(1)


func _features(timestamp_usec: int, side_distance: float, contact_position: float,
        p_valid := true, p_discontinuity := false) -> XRHandFeatures:
    var features := XRHandFeatures.new()
    features.valid = p_valid
    features.tracking_quality = 1.0 if p_valid else 0.0
    features.timestamp_usec = timestamp_usec
    features.thumb_index_side_distance = side_distance
    features.thumb_index_contact_position = contact_position
    features.discontinuity = p_discontinuity
    for finger in range(XRHandFeatures.Finger.INDEX, XRHandFeatures.Finger.PINKY + 1):
        features.finger_curls[finger] = 0.8
    return features


func _recognizer_with_capture(performed: Array, candidates: Array) -> XRThumbMicrogestureRecognizer:
    var recognizer := XRThumbMicrogestureRecognizer.new()
    recognizer.gesture_performed.connect(func(gesture: int, _hand: int, _confidence: float) -> void:
        performed.append(gesture)
    )
    recognizer.gesture_candidate.connect(func(_gesture: int, _hand: int, progress: float) -> void:
        candidates.append(progress)
    )
    return recognizer


## The closed-form property itself, observed through behaviour: one step of
## 2*dt must land exactly where two steps of dt land, because
## 1-(1-r)^(2dt/ref) composes from two applications of 1-(1-r)^(dt/ref).
## Per-frame smoothing (the bug this replaces) fails this by construction:
## one step moves 48% of the error, two steps move 73%, regardless of dt.
func _test_smoothing_composes_exactly_across_frame_times(failures: Array[String]) -> void:
    var one_perf: Array = []
    var one_prog: Array = []
    var one_step := _recognizer_with_capture(one_perf, one_prog)
    one_step.process_features(1, _features(1_000_000, 0.2, 0.50))
    one_step.process_features(1, _features(1_000_000 + 2 * DT72_USEC, 0.2, 0.42))

    var two_perf: Array = []
    var two_prog: Array = []
    var two_step := _recognizer_with_capture(two_perf, two_prog)
    two_step.process_features(1, _features(1_000_000, 0.2, 0.50))
    two_step.process_features(1, _features(1_000_000 + DT72_USEC, 0.2, 0.42))
    two_step.process_features(1, _features(1_000_000 + 2 * DT72_USEC, 0.2, 0.42))

    if one_prog.is_empty() or two_prog.is_empty():
        failures.append("composition fixture emitted no candidates -- sub-commit travel should still report progress")
    else:
        var difference: float = absf(float(one_prog[-1]) - float(two_prog[-1]))
        if difference > 0.0005:
            failures.append("smoothing must compose exactly across frame times: one 2dt step reached progress %.4f, two dt steps reached %.4f" % [one_prog[-1], two_prog[-1]])
    one_step.free()
    two_step.free()


## At exactly the reference rate the exact-dt alpha equals
## contact_position_smoothing verbatim, so the value keeps the meaning it was
## tuned with on device: one 72 Hz step toward a 0.08 contact move must cover
## 48% of it, making candidate progress 0.48 * 0.08 / 0.12 = 0.32.
func _test_reference_rate_behaviour_is_unchanged(failures: Array[String]) -> void:
    var performed: Array = []
    var progress: Array = []
    var recognizer := _recognizer_with_capture(performed, progress)
    recognizer.process_features(1, _features(1_000_000, 0.2, 0.50))
    recognizer.process_features(1, _features(1_000_000 + DT72_USEC, 0.2, 0.42))
    if progress.is_empty():
        failures.append("reference-rate fixture emitted no candidate")
    elif absf(float(progress[-1]) - 0.32) > 0.005:
        failures.append("one 72 Hz step must keep its tuned meaning (expected progress ~0.32, got %.4f) -- the reference-rate behaviour is the on-device baseline and must not shift" % progress[-1])
    recognizer.free()


## A reacquisition jump can exceed confident_commit_travel in a single frame.
## Flagged as a discontinuity it must abort silently; the identical stream
## WITHOUT the flag must still behave as before (scope pin: the change keys on
## the flag, not on the size of the jump).
func _test_discontinuity_frame_cannot_commit_a_phantom_swipe(failures: Array[String]) -> void:
    var performed: Array = []
    var progress: Array = []
    var flagged := _recognizer_with_capture(performed, progress)
    flagged.process_features(1, _features(1_000_000, 0.2, 0.50))
    flagged.process_features(1, _features(1_000_000 + DT72_USEC, 0.2, 0.95, true, true))
    flagged.process_features(1, _features(1_000_000 + 2 * DT72_USEC, 0.8, 0.95))
    if not performed.is_empty():
        failures.append("a discontinuity-flagged jump must not commit a gesture, got %s" % [performed])
    flagged.free()

    var control_perf: Array = []
    var control_prog: Array = []
    var control := _recognizer_with_capture(control_perf, control_prog)
    control.process_features(1, _features(1_000_000, 0.2, 0.50))
    control.process_features(1, _features(1_000_000 + DT72_USEC, 0.2, 0.95))
    control.process_features(1, _features(1_000_000 + 2 * DT72_USEC, 0.8, 0.95))
    if control_perf.is_empty():
        failures.append("scope pin broken: the identical unflagged stream must still commit a swipe -- the discontinuity handling must key on the FLAG, not on jump size")
    control.free()


## A discontinuity frame must not ARM either: the jumped pose is not evidence
## the thumb is really resting on the index. Without arming, an immediate
## release frame cannot produce the tap that an armed contact would.
func _test_discontinuity_frame_does_not_arm(failures: Array[String]) -> void:
    var performed: Array = []
    var progress: Array = []
    var recognizer := _recognizer_with_capture(performed, progress)
    recognizer.process_features(1, _features(1_000_000, 0.2, 0.50, true, true))
    recognizer.process_features(1, _features(1_000_000 + 6 * DT72_USEC, 0.8, 0.50))
    if not performed.is_empty():
        failures.append("a discontinuity frame armed a gesture (release produced %s) -- a jumped pose must not start tracking" % [performed])
    recognizer.free()


## One bad frame inside a swipe must suspend, not reset: the swipe in flight
## still completes. Under the old reset, tracking restarted at the resumed
## contact position and the accumulated travel was forgotten.
func _test_bad_frame_suspends_instead_of_aborting(failures: Array[String]) -> void:
    var performed: Array = []
    var progress: Array = []
    var recognizer := _recognizer_with_capture(performed, progress)
    var t := 1_000_000
    recognizer.process_features(1, _features(t, 0.2, 0.50))
    recognizer.process_features(1, _features(t + DT72_USEC, 0.2, 0.62))
    recognizer.process_features(1, _features(t + 2 * DT72_USEC, 0.2, 0.74, false))
    recognizer.process_features(1, _features(t + 3 * DT72_USEC, 0.2, 0.74))
    recognizer.process_features(1, _features(t + 4 * DT72_USEC, 0.8, 0.74))
    if performed != [XRMicrogestureSource.Gesture.LEFT]:
        failures.append("a swipe interrupted by ONE bad frame must still complete, got %s" % [performed])
    recognizer.free()


## A bad frame after a commit must not zero the cooldown. Under the old reset
## it did, so a tracking flicker immediately after a swipe re-armed the
## recognizer and the very next contact could double-fire.
func _test_bad_frame_does_not_disarm_the_cooldown(failures: Array[String]) -> void:
    var performed: Array = []
    var progress: Array = []
    var recognizer := _recognizer_with_capture(performed, progress)
    var t := 1_000_000
    # Commit one swipe via release.
    recognizer.process_features(1, _features(t, 0.2, 0.50))
    recognizer.process_features(1, _features(t + DT72_USEC, 0.2, 0.80))
    recognizer.process_features(1, _features(t + 2 * DT72_USEC, 0.8, 0.80))
    if performed.size() != 1:
        failures.append("fixture broken: the setup swipe must commit exactly once, got %s" % [performed])
        recognizer.free()
        return
    # Flicker, then immediately attempt a full second gesture inside the
    # cooldown window (total elapsed here ~0.07s against a 0.18s cooldown).
    recognizer.process_features(1, _features(t + 3 * DT72_USEC, 0.8, 0.80, false))
    recognizer.process_features(1, _features(t + 4 * DT72_USEC, 0.2, 0.50))
    recognizer.process_features(1, _features(t + 5 * DT72_USEC, 0.2, 0.80))
    recognizer.process_features(1, _features(t + 6 * DT72_USEC, 0.8, 0.80))
    if performed.size() != 1:
        failures.append("a bad frame zeroed the cooldown: a second gesture fired %.0f ms after the first against a 180 ms cooldown (events: %s)" % [float(6 * DT72_USEC) / 1000.0, performed])
    recognizer.free()


## Pose source that reports one discontinuity and nothing else -- the minimum
## fixture for the stamp glue below.
class _ScriptedDiscontinuitySource extends XRHandPoseSource:
    var raise_next := true

    func capture(hand: int, timestamp_usec: int, target: XRHandFrame) -> bool:
        target.begin_capture(hand, timestamp_usec, 1)
        return false

    func consume_discontinuity(_hand: int) -> bool:
        var value := raise_next
        raise_next = false
        return value


## The glue between the chain and the recognizers: XRGestureRuntime consumes
## its pose source's one-shot ON BEHALF of every recognizer it feeds and
## stamps the result onto the features -- recognizers read the stamp, they do
## not race each other for the source's destructive flag. Without this stamp
## every recognizer test above is exercising a field nothing sets in
## production.
func _test_runtime_stamps_discontinuity_from_its_source(failures: Array[String]) -> void:
    var runtime := XRGestureRuntime.new()
    runtime._ready()  # detached-node harness: initializes the frame buffers
    runtime.set_pose_source(_ScriptedDiscontinuitySource.new())
    runtime._update_hand(1, 1_000_000, 1.0 / 72.0)
    if not runtime.get_features(1).discontinuity:
        failures.append("the runtime must stamp its source's discontinuity onto the features it emits")
    runtime._update_hand(1, 1_000_000 + DT72_USEC, 1.0 / 72.0)
    if runtime.get_features(1).discontinuity:
        failures.append("the stamp must clear on the next frame -- a stale true turns every frame after a reacquisition into a discarded one")
    runtime.free()


## Sustained badness (past the grace) mid-gesture aborts WITHOUT emitting:
## the accumulated travel died with the dropout and must not fire on the
## eventual release.
func _test_grace_exceeded_aborts_without_emitting(failures: Array[String]) -> void:
    var performed: Array = []
    var progress: Array = []
    var recognizer := _recognizer_with_capture(performed, progress)
    var t := 1_000_000
    recognizer.process_features(1, _features(t, 0.2, 0.50))
    recognizer.process_features(1, _features(t + DT72_USEC, 0.2, 0.74))
    for i in range(4):  # quality_grace_frames is 3; the 4th aborts
        recognizer.process_features(1, _features(t + (2 + i) * DT72_USEC, 0.2, 0.74, false))
    recognizer.process_features(1, _features(t + 7 * DT72_USEC, 0.8, 0.74))
    if not performed.is_empty():
        failures.append("travel accumulated before a sustained dropout fired on release, got %s -- past the grace the gesture must abort silently" % [performed])
    recognizer.free()
