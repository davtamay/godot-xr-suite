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
    _test_dead_band_rejects_instead_of_vanishing(failures)
    _test_tap_too_quick_rejects(failures)
    _test_too_slow_and_posture_lost_are_distinct(failures)
    _test_quality_and_discontinuity_aborts_carry_reasons(failures)
    _test_success_emits_no_rejection(failures)
    _test_supported_gestures_are_honest(failures)
    _test_swipe_after_a_long_rest_commits(failures)
    _test_lifting_a_rested_thumb_is_neither_tap_nor_rejection(failures)
    _test_out_of_zone_contact_is_reported_once_per_episode(failures)
    _test_high_rest_start_arms_and_commits(failures)
    _test_hover_sweep_reports_contact_too_light(failures)
    _test_approach_hover_does_not_haunt_a_successful_gesture(failures)
    _test_bad_posture_contact_reports_posture_not_ready(failures)

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


## -- Tier 2: never fail silently ------------------------------------------


func _features_with_curl(timestamp_usec: int, side_distance: float, contact_position: float,
        curl: float) -> XRHandFeatures:
    var features := _features(timestamp_usec, side_distance, contact_position)
    for finger in range(XRHandFeatures.Finger.INDEX, XRHandFeatures.Finger.PINKY + 1):
        features.finger_curls[finger] = curl
    return features


func _recognizer_with_rejections(performed: Array, rejections: Array) -> XRThumbMicrogestureRecognizer:
    var recognizer := XRThumbMicrogestureRecognizer.new()
    recognizer.gesture_performed.connect(func(gesture: int, _hand: int, _confidence: float) -> void:
        performed.append(gesture)
    )
    recognizer.gesture_rejected.connect(func(_hand: int, reason: int, _attempted: int) -> void:
        rejections.append(reason)
    )
    return recognizer


## The dead band made a fumbled swipe a SILENT miss: travel past the tap
## ceiling (0.09) but short of the swipe floor (0.12) emitted nothing at all.
## It must now emit exactly one rejection naming the problem -- and still no
## gesture, because resolving the band to a gesture would manufacture the
## phantom swipes tier 1 just removed.
func _test_dead_band_rejects_instead_of_vanishing(failures: Array[String]) -> void:
    var performed: Array = []
    var rejections: Array = []
    var attempted: Array = []
    var recognizer := _recognizer_with_rejections(performed, rejections)
    recognizer.gesture_rejected.connect(func(_hand: int, _reason: int, direction: int) -> void:
        attempted.append(direction)
    )
    var t := 1_000_000
    recognizer.process_features(1, _features(t, 0.2, 0.50))
    # One 72 Hz step toward a 0.21 contact move covers 48%: peak 0.1008 --
    # inside (0.09, 0.12), the measured dead band. The RELEASE frame runs the
    # smoothing update before the release check, so its contact value must
    # hold the smoothed position steady (0.60 ~ the current smoothed value)
    # or that final update itself would push the travel out of the band.
    recognizer.process_features(1, _features(t + DT72_USEC, 0.2, 0.71))
    recognizer.process_features(1, _features(t + 2 * DT72_USEC, 0.8, 0.60))
    if not performed.is_empty():
        failures.append("dead-band travel must not resolve to a gesture, got %s" % [performed])
    if rejections != [XRMicrogestureSource.RejectReason.SWIPE_TOO_SHORT]:
        failures.append("dead-band travel must emit exactly one SWIPE_TOO_SHORT rejection, got %s" % [rejections])
    # Contact position INCREASING on the right hand is semantically LEFT --
    # the same mapping a successful commit uses. Per-direction rejection
    # counts are what answered "swiping right seems more reliable than
    # swiping left" on device; an unattributed or misattributed direction
    # makes that question unanswerable again.
    if attempted != [XRMicrogestureSource.Gesture.LEFT]:
        failures.append("the rejection must carry the ATTEMPTED direction (LEFT for rising contact on the right hand), got %s" % [attempted])
    recognizer.free()


## Releasing a clean contact before a tap's minimum duration used to vanish
## the same way.
func _test_tap_too_quick_rejects(failures: Array[String]) -> void:
    var performed: Array = []
    var rejections: Array = []
    var recognizer := _recognizer_with_rejections(performed, rejections)
    var t := 1_000_000
    recognizer.process_features(1, _features(t, 0.2, 0.50))
    # Released after one 13.9ms frame: under minimum_tap_duration (0.04).
    recognizer.process_features(1, _features(t + DT72_USEC, 0.8, 0.50))
    if not performed.is_empty():
        failures.append("a too-quick contact must not emit a gesture, got %s" % [performed])
    if rejections != [XRMicrogestureSource.RejectReason.TAP_TOO_QUICK]:
        failures.append("a too-quick release must emit exactly one TAP_TOO_QUICK, got %s" % [rejections])
    recognizer.free()


## The two mid-track aborts need DIFFERENT user corrections ("keep your hand
## curled" vs "don't linger"), so they must carry distinct reasons.
func _test_too_slow_and_posture_lost_are_distinct(failures: Array[String]) -> void:
    # TOO_SLOW needs travel IN FLIGHT: swipe partway (0.15 -- past the swipe
    # floor, under the early-commit bar) and then stall without releasing.
    # A STILL thumb deliberately no longer times out at all -- that is the
    # rest re-anchor, tested separately below.
    var slow_perf: Array = []
    var slow_rej: Array = []
    var slow := _recognizer_with_rejections(slow_perf, slow_rej)
    var t := 1_000_000
    slow.process_features(1, _features(t, 0.2, 0.50))
    for i in range(1, 64):  # 63 further frames = ~0.875s > maximum_duration 0.85
        slow.process_features(1, _features(t + i * DT72_USEC, 0.2, 0.65))
    if slow_rej != [XRMicrogestureSource.RejectReason.TOO_SLOW]:
        failures.append("a stalled swipe outliving maximum_duration must emit exactly one TOO_SLOW, got %s" % [slow_rej])
    if not slow_perf.is_empty():
        failures.append("a stalled swipe must not emit a gesture, got %s" % [slow_perf])
    slow.free()

    var posture_perf: Array = []
    var posture_rej: Array = []
    var posture := _recognizer_with_rejections(posture_perf, posture_rej)
    posture.process_features(1, _features(t, 0.2, 0.50))
    # Hand opens mid-track: curls collapse below the tracking release gate.
    posture.process_features(1, _features_with_curl(t + DT72_USEC, 0.2, 0.50, 0.02))
    if posture_rej != [XRMicrogestureSource.RejectReason.POSTURE_LOST]:
        failures.append("losing gesture posture mid-track must emit exactly one POSTURE_LOST, got %s" % [posture_rej])
    posture.free()


## The tier-1 aborts stay, and now say why: sustained low quality and a
## tracking discontinuity each carry their reason, exactly once.
func _test_quality_and_discontinuity_aborts_carry_reasons(failures: Array[String]) -> void:
    var quality_perf: Array = []
    var quality_rej: Array = []
    var quality := _recognizer_with_rejections(quality_perf, quality_rej)
    var t := 1_000_000
    quality.process_features(1, _features(t, 0.2, 0.50))
    quality.process_features(1, _features(t + DT72_USEC, 0.2, 0.74))
    for i in range(4):
        quality.process_features(1, _features(t + (2 + i) * DT72_USEC, 0.2, 0.74, false))
    if quality_rej != [XRMicrogestureSource.RejectReason.LOW_QUALITY]:
        failures.append("a grace-exceeded abort must emit exactly one LOW_QUALITY, got %s" % [quality_rej])
    quality.free()

    var disc_perf: Array = []
    var disc_rej: Array = []
    var disc := _recognizer_with_rejections(disc_perf, disc_rej)
    disc.process_features(1, _features(t, 0.2, 0.50))
    disc.process_features(1, _features(t + DT72_USEC, 0.2, 0.95, true, true))
    if disc_rej != [XRMicrogestureSource.RejectReason.DISCONTINUITY]:
        failures.append("a discontinuity abort must emit exactly one DISCONTINUITY, got %s" % [disc_rej])
    if not disc_perf.is_empty():
        failures.append("the discontinuity abort must still not emit a gesture, got %s" % [disc_perf])
    disc.free()


## Success and rejection are mutually exclusive per attempt -- a swipe that
## fires must not ALSO complain.
func _test_success_emits_no_rejection(failures: Array[String]) -> void:
    var performed: Array = []
    var rejections: Array = []
    var recognizer := _recognizer_with_rejections(performed, rejections)
    var t := 1_000_000
    recognizer.process_features(1, _features(t, 0.2, 0.50))
    recognizer.process_features(1, _features(t + DT72_USEC, 0.2, 0.80))
    recognizer.process_features(1, _features(t + 2 * DT72_USEC, 0.8, 0.80))
    if performed.size() != 1:
        failures.append("fixture broken: the swipe must commit exactly once, got %s" % [performed])
    if not rejections.is_empty():
        failures.append("a successful gesture must not also emit a rejection, got %s" % [rejections])
    recognizer.free()

    # And the TAP path separately -- it has its own emit site, and a mutation
    # that complained on tap success slipped past a swipe-only version of
    # this test.
    var tap_perf: Array = []
    var tap_rej: Array = []
    var tap := _recognizer_with_rejections(tap_perf, tap_rej)
    var t2 := 2_000_000
    tap.process_features(1, _features(t2, 0.2, 0.50))
    tap.process_features(1, _features(t2 + 4 * DT72_USEC, 0.2, 0.50))
    tap.process_features(1, _features(t2 + 5 * DT72_USEC, 0.8, 0.50))
    if tap_perf != [XRMicrogestureSource.Gesture.TAP]:
        failures.append("fixture broken: the tap must commit exactly once, got %s" % [tap_perf])
    if not tap_rej.is_empty():
        failures.append("a successful TAP must not also emit a rejection, got %s" % [tap_rej])
    tap.free()


## THE left-swipe fix, measured from David's session telemetry: every LEFT
## miss was TOO_SLOW, because maximum_duration ran from CONTACT start and a
## thumb resting past it armed a trap -- the eventual swipe was eaten until
## release. Resting is the canonical microgesture posture; the window must
## bound the SWIPE. Rest ~1.4s (well past the 0.85s ceiling), then swipe:
## the swipe must commit, and the rest itself must produce no rejection.
func _test_swipe_after_a_long_rest_commits(failures: Array[String]) -> void:
    var performed: Array = []
    var rejections: Array = []
    var recognizer := _recognizer_with_rejections(performed, rejections)
    var t := 1_000_000
    recognizer.process_features(1, _features(t, 0.2, 0.50))
    for i in range(1, 101):  # ~1.39s of resting contact, no travel
        recognizer.process_features(1, _features(t + i * DT72_USEC, 0.2, 0.50))
    recognizer.process_features(1, _features(t + 101 * DT72_USEC, 0.2, 0.80))
    recognizer.process_features(1, _features(t + 102 * DT72_USEC, 0.2, 0.80))
    recognizer.process_features(1, _features(t + 103 * DT72_USEC, 0.8, 0.80))
    if performed != [XRMicrogestureSource.Gesture.LEFT]:
        failures.append("a swipe after a long rest must commit (the window bounds the SWIPE, not the rest), got %s" % [performed])
    if not rejections.is_empty():
        failures.append("resting is not an attempt and must emit no rejection, got %s" % [rejections])
    recognizer.free()


## The guard the re-anchor needs: a lift after a long rest is NOT a quick
## touch, so it must not fire the TAP that arms/commits teleport -- and it is
## not a failed attempt either, so it must not emit a rejection. This is the
## one silence that is correct.
func _test_lifting_a_rested_thumb_is_neither_tap_nor_rejection(failures: Array[String]) -> void:
    var performed: Array = []
    var rejections: Array = []
    var recognizer := _recognizer_with_rejections(performed, rejections)
    var t := 1_000_000
    recognizer.process_features(1, _features(t, 0.2, 0.50))
    for i in range(1, 101):
        recognizer.process_features(1, _features(t + i * DT72_USEC, 0.2, 0.50))
    recognizer.process_features(1, _features(t + 101 * DT72_USEC, 0.8, 0.50))
    if not performed.is_empty():
        failures.append("lifting a rested thumb must not be read as a gesture (phantom TAP arms teleport), got %s" % [performed])
    if not rejections.is_empty():
        failures.append("lifting a rested thumb is not a failed attempt and must stay silent, got %s" % [rejections])
    recognizer.free()


## The blind spot behind "swiping left is not very reliable" with
## clean-looking counters: a contact in good posture starting OUTSIDE the
## arming zone (thumb resting near the fingertip, position > 0.88) never
## armed and produced NOTHING. It must now emit OUT_OF_START_ZONE -- once per
## contact episode, not per frame, and a new episode after release reports
## again. An in-zone start must stay clean.
func _test_out_of_zone_contact_is_reported_once_per_episode(failures: Array[String]) -> void:
    var performed: Array = []
    var rejections: Array = []
    var recognizer := _recognizer_with_rejections(performed, rejections)
    var t := 1_000_000
    # Contact held for several frames at position 0.99 -- above even the
    # widened ceiling (0.98), i.e. effectively pinned at the fingertip.
    for i in range(5):
        recognizer.process_features(1, _features(t + i * DT72_USEC, 0.2, 0.99))
    if rejections != [XRMicrogestureSource.RejectReason.OUT_OF_START_ZONE]:
        failures.append("an out-of-zone contact must report OUT_OF_START_ZONE exactly ONCE per episode, got %s" % [rejections])
    # Release, recontact out of zone: a NEW episode reports again.
    recognizer.process_features(1, _features(t + 5 * DT72_USEC, 0.8, 0.99))
    for i in range(6, 9):
        recognizer.process_features(1, _features(t + i * DT72_USEC, 0.2, 0.05))
    if rejections.size() != 2:
        failures.append("a new out-of-zone contact episode after release must report again, got %s" % [rejections])
    if not performed.is_empty():
        failures.append("out-of-zone contacts must not arm anything, got %s" % [performed])
    recognizer.free()

    # An in-zone contact stays clean: no OUT_OF_START_ZONE noise on the path
    # that arms normally.
    var clean_perf: Array = []
    var clean_rej: Array = []
    var clean := _recognizer_with_rejections(clean_perf, clean_rej)
    clean.process_features(1, _features(t, 0.2, 0.50))
    clean.process_features(1, _features(t + DT72_USEC, 0.2, 0.80))
    clean.process_features(1, _features(t + 2 * DT72_USEC, 0.8, 0.80))
    if not clean_rej.is_empty():
        failures.append("an in-zone start must not emit OUT_OF_START_ZONE, got %s" % [clean_rej])
    clean.free()


## The measured fix for "swiped left 12 times, only 7 successful": the LEFT
## thumb's natural rest reads 0.84-0.96 along the index, above the old 0.88
## arming ceiling, and every such attempt died at the gate. A start at 0.95
## (dead center of the measured rest band) must now arm and the swipe toward
## the base must commit -- on the LEFT hand, position decreasing is
## semantically LEFT, exactly the user's failing gesture.
func _test_high_rest_start_arms_and_commits(failures: Array[String]) -> void:
    var performed: Array = []
    var rejections: Array = []
    var recognizer := _recognizer_with_rejections(performed, rejections)
    var t := 1_000_000
    recognizer.process_features(0, _features(t, 0.2, 0.95))
    recognizer.process_features(0, _features(t + DT72_USEC, 0.2, 0.55))
    recognizer.process_features(0, _features(t + 2 * DT72_USEC, 0.2, 0.55))
    recognizer.process_features(0, _features(t + 3 * DT72_USEC, 0.8, 0.55))
    if performed != [XRMicrogestureSource.Gesture.LEFT]:
        failures.append("a swipe starting at the measured rest position (0.95) must arm and commit LEFT, got %s" % [performed])
    if XRMicrogestureSource.RejectReason.OUT_OF_START_ZONE in rejections:
        failures.append("0.95 is a real measured rest, not an out-of-zone position -- it must not be reported as one")
    recognizer.free()


## The measured left-swipe killer on the right hand: the thumb EXTENDS
## leftward, the press lightens, and the whole sweep rides just above the
## contact gate (median 0.46 vs gate 0.40) -- a swipe's worth of lateral
## travel that never armed and never reported. It must report
## CONTACT_TOO_LIGHT exactly once, at episode end (the lift), and a hover
## that never sweeps must stay silent (resting NEAR the surface is normal).
func _test_hover_sweep_reports_contact_too_light(failures: Array[String]) -> void:
    var performed: Array = []
    var rejections: Array = []
    var recognizer := _recognizer_with_rejections(performed, rejections)
    var t := 1_000_000
    # Sweep at side 0.43 -- above contact (0.40), below release (0.46) --
    # with a full swipe's worth of position travel, then lift.
    recognizer.process_features(1, _features(t, 0.43, 0.70))
    recognizer.process_features(1, _features(t + DT72_USEC, 0.43, 0.50))
    recognizer.process_features(1, _features(t + 2 * DT72_USEC, 0.43, 0.30))
    recognizer.process_features(1, _features(t + 3 * DT72_USEC, 0.8, 0.30))
    if rejections != [XRMicrogestureSource.RejectReason.CONTACT_TOO_LIGHT]:
        failures.append("a hover sweep that never pressed in must report exactly one CONTACT_TOO_LIGHT at lift, got %s" % [rejections])
    if not performed.is_empty():
        failures.append("a hover sweep must not commit anything, got %s" % [performed])
    recognizer.free()

    # A motionless hover, then lift: near-surface resting is normal, silence
    # is correct.
    var still_perf: Array = []
    var still_rej: Array = []
    var still := _recognizer_with_rejections(still_perf, still_rej)
    for i in range(5):
        still.process_features(1, _features(t + i * DT72_USEC, 0.43, 0.60))
    still.process_features(1, _features(t + 5 * DT72_USEC, 0.8, 0.60))
    if not still_rej.is_empty():
        failures.append("a motionless hover must stay silent, got %s" % [still_rej])
    still.free()


## The approach to a real gesture passes through the hover band on the way
## in. That travel is SPENT once the gesture arms: without the reset in
## _start_tracking, it survived the whole gesture and fired a phantom
## CONTACT_TOO_LIGHT at the release of a SUCCESSFUL swipe -- complaining
## about the very gesture that just worked.
func _test_approach_hover_does_not_haunt_a_successful_gesture(failures: Array[String]) -> void:
    var performed: Array = []
    var rejections: Array = []
    var recognizer := _recognizer_with_rejections(performed, rejections)
    var t := 1_000_000
    # Approach: sweep THROUGH the hover band (side 0.43) with a swipe's worth
    # of travel...
    recognizer.process_features(1, _features(t, 0.43, 0.80))
    recognizer.process_features(1, _features(t + DT72_USEC, 0.43, 0.50))
    # ...then press in, swipe, and release: a clean successful gesture.
    recognizer.process_features(1, _features(t + 2 * DT72_USEC, 0.2, 0.50))
    recognizer.process_features(1, _features(t + 3 * DT72_USEC, 0.2, 0.80))
    recognizer.process_features(1, _features(t + 4 * DT72_USEC, 0.8, 0.80))
    # ...and stay released past the cooldown, back into READY: the phantom
    # fired there, on the first open-hand frame after the cooldown expired --
    # a fixture that stops at the commit never reaches it and proves nothing.
    for i in range(5, 25):
        recognizer.process_features(1, _features(t + i * DT72_USEC, 0.8, 0.80))
    if performed != [XRMicrogestureSource.Gesture.LEFT]:
        failures.append("fixture broken: the pressed swipe must commit, got %s" % [performed])
    if not rejections.is_empty():
        failures.append("approach-hover travel must be spent once the gesture arms -- a successful swipe must not be haunted by a CONTACT_TOO_LIGHT after its release, got %s" % [rejections])
    recognizer.free()


## The other formerly-silent arming gate: contact made but posture below the
## near-exact arming bar. Once per episode, like the zone report.
func _test_bad_posture_contact_reports_posture_not_ready(failures: Array[String]) -> void:
    var performed: Array = []
    var rejections: Array = []
    var recognizer := _recognizer_with_rejections(performed, rejections)
    var t := 1_000_000
    for i in range(5):
        recognizer.process_features(1, _features_with_curl(t + i * DT72_USEC, 0.2, 0.50, 0.10))
    if rejections != [XRMicrogestureSource.RejectReason.POSTURE_NOT_READY]:
        failures.append("an in-contact hand below arming posture must report POSTURE_NOT_READY exactly once, got %s" % [rejections])
    if not performed.is_empty():
        failures.append("a below-posture contact must not arm, got %s" % [performed])
    recognizer.free()


## Capability honesty: the portable recognizer must not claim the
## FORWARD/BACKWARD it cannot derive; the native source must claim all five;
## the base default stays the full set (the claim every pre-contract source
## implicitly made).
func _test_supported_gestures_are_honest(failures: Array[String]) -> void:
    var recognizer := XRThumbMicrogestureRecognizer.new()
    var portable: Array = recognizer.get_supported_gestures()
    if XRMicrogestureSource.Gesture.FORWARD in portable or XRMicrogestureSource.Gesture.BACKWARD in portable:
        failures.append("the portable recognizer must not claim FORWARD/BACKWARD -- it has one contact axis and nothing to derive them from")
    if portable != [XRMicrogestureSource.Gesture.LEFT, XRMicrogestureSource.Gesture.RIGHT, XRMicrogestureSource.Gesture.TAP]:
        failures.append("the portable recognizer must claim exactly LEFT/RIGHT/TAP, got %s" % [portable])
    recognizer.free()

    var native: Node = (load("res://addons/godot_xr_hands/runtime/recognition/xr_native_microgesture_source.gd") as GDScript).new()
    if native.get_supported_gestures().size() != XRMicrogestureSource.Gesture.size():
        failures.append("the native source must claim the full vocabulary, got %s" % [native.get_supported_gestures()])
    native.free()

    var base := XRMicrogestureSource.new()
    if base.get_supported_gestures().size() != XRMicrogestureSource.Gesture.size():
        failures.append("the base default must stay the full vocabulary -- it is the claim every pre-contract source implicitly made")
    base.free()
