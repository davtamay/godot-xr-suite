class_name XRThumbMicrogestureRecognizer
extends XRMicrogestureSource

## Clean-room joint recognizer for thumb tap and index-surface swipes. The
## horizontal coordinate follows the curved index finger from its proximal
## joint (0) to fingertip (1), then maps either hand into the canonical,
## wearer-relative microgesture vocabulary.

# Compatibility enum and signals retained for existing scenes. New consumers
# should use XRMicrogestureSource.Gesture and gesture_* signals.
enum Direction { LEFT, RIGHT, UP, DOWN, TAP }
enum Phase { READY, TRACKING, WAITING_FOR_RELEASE }

## The frame time contact_position_smoothing is expressed against: 72 Hz, the
## rate every current value was earned in at on Quest over Link. At this dt the
## exact-dt alpha equals contact_position_smoothing verbatim, so on-device
## behaviour at 72 Hz is bit-compatible with the per-frame code this replaced.
const REFERENCE_DT := 1.0 / 72.0

signal microgesture_candidate(direction: Direction, hand: int, progress: float)
signal microgesture_performed(direction: Direction, hand: int, confidence: float)

@export var gesture_runtime_path: NodePath
@export_enum("Any:-1", "Left:0", "Right:1") var hand := -1
@export_range(0.05, 1.5, 0.01) var contact_threshold := 0.40
@export_range(0.05, 2.0, 0.01) var release_threshold := 0.46
## ---- adaptive contact calibration -------------------------------------------
##
## thumb_index_side_distance is normalized by palm width, so it already survives
## hand SIZE. It does NOT survive a different joint SKELETON: measured on device,
## the same physical pinch reads 0.09-0.39 on Meta and 0.40-1.11 on Android XR,
## because the runtimes place the thumb tip differently relative to the index
## surface. A fixed 0.40 gate therefore fires on nearly every Meta attempt and
## roughly one Android XR attempt in four.
##
## Rather than table a scale per runtime -- which needs a hand-written entry for
## every device, does nothing on any runtime not in the list, and still ignores
## that hands differ between PEOPLE -- the gate calibrates itself from what this
## hand actually does. The absolute distance is not comparable across rigs, but
## its SHAPE is: the value collapses when thumb meets index and rises when they
## part. So we track that envelope per hand and place the gate inside it.
##
## Cold start uses the authored thresholds unchanged, and adaptation only engages
## once the observed range is wide enough to be a real open/closed excursion --
## so a rig that works today keeps working, and an unknown rig converges instead
## of failing.
@export var adaptive_contact := true
## Where the contact gate sits within the observed open..closed range.
@export_range(0.05, 0.9, 0.01) var contact_fraction := 0.35
## Extra fraction of the range before release, so contact does not chatter.
@export_range(0.0, 0.5, 0.01) var release_margin := 0.15
## The envelope must span at least this much before it is trusted. Guards the
## degenerate case: a hand held still never separates open from closed, and
## adapting to that noise band would fire the gesture on jitter alone.
@export_range(0.05, 2.0, 0.01) var adaptive_minimum_span := 0.25
## Seconds for the envelope to forget. Long enough to survive a slow gesture,
## short enough to re-converge if the wearer or the runtime changes.
@export_range(0.5, 60.0, 0.5) var adaptation_seconds := 8.0
## Percentiles the envelope tracks instead of raw extremes, so occlusion spikes
## (the thumb's own reading degrades when it touches the index) cannot define
## the range. 0.15/0.85 keeps the useful excursion and discards the tails.
@export_range(0.0, 0.49, 0.01) var low_quantile := 0.15
@export_range(0.51, 1.0, 0.01) var high_quantile := 0.85
## Ring length. At ~72 Hz this is a couple of seconds of gesture posture --
## long enough to contain several open/close excursions, short enough to
## re-converge if the wearer or the runtime changes.
@export_range(30, 600, 10) var calibration_samples := 150
## Below this the ring is not evidence yet and the authored gate stays in force.
@export_range(10, 300, 5) var minimum_samples := 60
## Frames between percentile recomputes.
@export_range(1, 30, 1) var recompute_interval := 6

## Envelope per hand: {low, high, valid}. Kept off the phase state so it
## survives the resets that a dropout or a failed attempt triggers -- the
## calibration is a property of the RIG, not of one gesture attempt.
var _envelope := {}

func _envelope_for(p_hand: int) -> Dictionary:
    if not _envelope.has(p_hand):
        _envelope[p_hand] = {"samples": PackedFloat32Array(), "cursor": 0, "filled": false,
                             "low": NAN, "high": NAN, "since": 0}
    return _envelope[p_hand]

## Feeds one observation into a fixed-size ring of recent samples.
##
## A RING plus percentiles, not a running min/max, and not a stochastic
## quantile. Measured on device, the thumb's own tracked position degrades
## exactly when it touches the index -- the finger occludes it -- and the
## reading spikes to 1.5-1.9 palm widths for a few frames. A min/max envelope
## latched onto those spikes and floated the gate up to ~0.84, which is why
## detection was "better but not reliable": it was calibrated against garbage.
## Percentiles discard those tails by construction, and a bounded ring converges
## in a known number of samples rather than crawling toward the answer.
func observe_contact_distance(p_hand: int, distance: float, _delta: float) -> void:
    var env := _envelope_for(p_hand)
    var samples: PackedFloat32Array = env["samples"]
    if samples.size() < calibration_samples:
        samples.append(distance)
    else:
        samples[int(env["cursor"])] = distance
        env["cursor"] = (int(env["cursor"]) + 1) % calibration_samples
        env["filled"] = true
    env["samples"] = samples
    env["since"] = int(env["since"]) + 1
    # Recomputing every frame would sort on every sample for no benefit; the
    # percentiles cannot move far in a handful of frames.
    if int(env["since"]) >= recompute_interval:
        env["since"] = 0
        _recompute_envelope(env)

func _recompute_envelope(env: Dictionary) -> void:
    var samples: PackedFloat32Array = env["samples"]
    # Too few samples is not a narrow hand -- it is no evidence. Leaving the
    # envelope NAN keeps the authored thresholds in force.
    if samples.size() < minimum_samples:
        env["low"] = NAN
        env["high"] = NAN
        return
    var sorted := samples.duplicate()
    sorted.sort()
    var last := sorted.size() - 1
    env["low"] = sorted[clampi(int(round(low_quantile * last)), 0, last)]
    env["high"] = sorted[clampi(int(round(high_quantile * last)), 0, last)]

## Whether this frame says anything about thumb-to-index-SIDE distance.
##
## thumb_index_contact_position is the closest point along the index polyline,
## clamped to [0,1]. Pinned at exactly 0 or 1 means the closest point is an
## ENDPOINT -- the thumb is off the base or past the fingertip -- so the
## "distance" is to a corner, not to the finger's side, and is unbounded. On
## device those frames read 1.0 with side distances of 1.4-1.9, and feeding them
## to the envelope is what let it drift. They are excluded from CALIBRATION only;
## the gesture gates still see every frame.
func _is_calibration_sample(features: XRHandFeatures) -> bool:
    var position: float = features.thumb_index_contact_position
    return position > 0.001 and position < 0.999

## The observed range, or -1.0 when it is not yet trustworthy.
func contact_span(p_hand: int) -> float:
    var env := _envelope_for(p_hand)
    if not is_finite(float(env["low"])) or not is_finite(float(env["high"])):
        return -1.0
    var span := float(env["high"]) - float(env["low"])
    return span if span >= adaptive_minimum_span else -1.0

func effective_contact_threshold(p_hand: int) -> float:
    var span := contact_span(p_hand)
    if not adaptive_contact or span < 0.0:
        return contact_threshold
    return float(_envelope_for(p_hand)["low"]) + contact_fraction * span

func effective_release_threshold(p_hand: int) -> float:
    var span := contact_span(p_hand)
    if not adaptive_contact or span < 0.0:
        return release_threshold
    # Derived from the SAME envelope as contact, so the hysteresis band cannot
    # invert (release below contact) however the envelope moves.
    return float(_envelope_for(p_hand)["low"]) + (contact_fraction + release_margin) * span

@export_range(0.0, 1.0, 0.01) var minimum_finger_curl := 0.28
@export_range(0.0, 1.0, 0.01) var minimum_index_curl := 0.16
@export_range(0.0, 1.0, 0.01) var start_zone_minimum := 0.12
@export_range(0.0, 1.0, 0.01) var start_zone_maximum := 0.88
@export_range(0.02, 0.8, 0.01) var minimum_index_travel := 0.12
@export_range(0.02, 0.8, 0.01) var confident_commit_travel := 0.22
@export_range(0.0, 0.3, 0.01) var minimum_swipe_duration := 0.03
@export_range(0.05, 1.5, 0.01) var maximum_duration := 0.85
@export_range(0.0, 0.5, 0.01) var minimum_tap_duration := 0.04
@export_range(0.01, 0.5, 0.01) var maximum_tap_travel := 0.09
@export_range(0.0, 2.0, 0.01) var cooldown := 0.18
@export_range(0.0, 1.0, 0.01) var minimum_tracking_quality := 0.36
@export_range(0.0, 1.0, 0.01) var tracking_gate_release := 0.42
## Per-REFERENCE_DT smoothing ratio for the contact position. The value keeps
## its on-device-tuned meaning at 72 Hz exactly (alpha(1/72) == this), and the
## exact closed form below reproduces that same behaviour per unit TIME at any
## other rate -- previously this was applied per FRAME, so 90/120 Hz smoothed
## the same physical swipe less per unit time than the 72 Hz it was tuned at,
## and the travel thresholds silently depended on the device's refresh rate.
@export_range(0.0, 1.0, 0.01) var contact_position_smoothing := 0.48
## Consecutive below-quality frames tolerated INSIDE a gesture before the
## gesture aborts (no emit). Mirrors the confidence gate's reacquire_frames
## debounce: a tracking flicker is a few frames, a real loss is not.
@export_range(0, 30, 1) var quality_grace_frames := 3

var _runtime: XRGestureRuntime
var _hands := {}

func _ready() -> void:
    _runtime = get_node_or_null(gesture_runtime_path) as XRGestureRuntime
    if _runtime != null:
        _runtime.hand_features_updated.connect(process_features)

func process_features(p_hand: int, features: XRHandFeatures) -> void:
    if hand >= 0 and p_hand != hand:
        return
    if not _hands.has(p_hand):
        _hands[p_hand] = _new_state()  # lazy: .get()'s default arg allocated every call
    var state: Dictionary = _hands[p_hand]
    if features == null or not features.valid or features.tracking_quality < minimum_tracking_quality:
        # SUSPEND, do not reset. The old _reset_state here meant one bad frame
        # zeroed the cooldown (the double-fire guard died the instant it was
        # needed most), zeroed last_timestamp (so the next delta was 0 and the
        # cooldown could never tick across the gap), and re-armed mid-gesture.
        # A 40ms tracking flicker forgot the swipe in flight AND that one just
        # fired. Instead: tolerate a short burst inside a gesture, abort the
        # gesture (no emit) only when the burst outlasts the grace, and leave
        # the cooldown and timestamp alone -- last_timestamp surviving is what
        # makes the next good frame's delta span the gap, so cooldown time
        # keeps passing at wall rate through the dropout.
        state["bad_frames"] = int(state.get("bad_frames", 0)) + 1
        if int(state["phase"]) == Phase.TRACKING and int(state["bad_frames"]) > quality_grace_frames:
            state["phase"] = Phase.WAITING_FOR_RELEASE
        return
    state["bad_frames"] = 0

    var timestamp := features.timestamp_usec
    var delta := 0.0
    if int(state["last_timestamp"]) > 0:
        delta = maxf(float(timestamp - int(state["last_timestamp"])) / 1000000.0, 0.0)
    state["last_timestamp"] = timestamp
    state["cooldown_left"] = maxf(float(state["cooldown_left"]) - delta, 0.0)

    # A discontinuity frame carries a real pose that is NOT continuous with the
    # last one -- reacquisition after an FOV freeze being the measured case.
    # Any travel already accumulated is unattributable to the thumb, and the
    # jump itself must not be read as motion: it can exceed
    # confident_commit_travel in a single frame and early-commit a phantom
    # swipe at confidence 0.86. Abort silently (rejection feedback is tier 2,
    # deliberately not smuggled in here) and skip arming this frame too, so a
    # jumped pose cannot start a gesture either.
    if features.discontinuity:
        if int(state["phase"]) == Phase.TRACKING:
            state["phase"] = Phase.WAITING_FOR_RELEASE
        return

    var posture_score := gate_score(features)
    # Learn the envelope only in gesture POSTURE. An open, relaxed hand spends
    # most of its time far from the index and would drag `high` up until the
    # gate sat in empty space.
    if posture_score >= 0.999 and _is_calibration_sample(features):
        observe_contact_distance(p_hand, features.thumb_index_side_distance, delta)
    match int(state["phase"]):
        Phase.READY:
            if float(state["cooldown_left"]) <= 0.0 and posture_score >= 0.999 and _can_start(features, p_hand):
                _start_tracking(state, features)
        Phase.TRACKING:
            state["elapsed"] = float(state["elapsed"]) + delta
            if posture_score < tracking_gate_release or float(state["elapsed"]) > maximum_duration:
                state["phase"] = Phase.WAITING_FOR_RELEASE
                return
            _update_tracking(state, features, p_hand, delta)
            if int(state["phase"]) != Phase.TRACKING:
                return
            if features.thumb_index_side_distance >= effective_release_threshold(p_hand):
                _finish_contact(state, p_hand)
        Phase.WAITING_FOR_RELEASE:
            if features.thumb_index_side_distance >= effective_release_threshold(p_hand) and float(state["cooldown_left"]) <= 0.0:
                state["phase"] = Phase.READY

func gate_score(features: XRHandFeatures) -> float:
    if features == null or not features.valid:
        return 0.0
    var curl_average := 0.0
    for finger in range(XRHandFeatures.Finger.INDEX, XRHandFeatures.Finger.PINKY + 1):
        curl_average += features.finger_curls[finger]
    curl_average /= 4.0
    var average_score := clampf(curl_average / maxf(minimum_finger_curl, 0.001), 0.0, 1.0)
    var index_score := clampf(
        features.finger_curls[XRHandFeatures.Finger.INDEX] / maxf(minimum_index_curl, 0.001),
        0.0,
        1.0
    )
    return minf(average_score, index_score)

func direction_name(direction: int) -> String:
    return gesture_name(direction)

func reset() -> void:
    for state in _hands.values():
        _reset_state(state)

func _can_start(features: XRHandFeatures, p_hand: int) -> bool:
    return features.thumb_index_side_distance <= effective_contact_threshold(p_hand) \
        and features.thumb_index_contact_position >= start_zone_minimum \
        and features.thumb_index_contact_position <= start_zone_maximum

func _start_tracking(state: Dictionary, features: XRHandFeatures) -> void:
    state["phase"] = Phase.TRACKING
    state["elapsed"] = 0.0
    state["start_contact_position"] = features.thumb_index_contact_position
    state["smoothed_contact_position"] = features.thumb_index_contact_position
    state["peak_semantic_delta"] = 0.0

func _update_tracking(state: Dictionary, features: XRHandFeatures, p_hand: int, delta: float) -> void:
    # Exact frame-rate compensation, same closed form as XRAimStabilizer: a
    # per-reference-frame ratio r composed over delta/REFERENCE_DT frames
    # leaves (1-r)^n, so alpha = 1 - (1-r)^(delta/ref). Identical smoothing
    # per unit TIME at 72, 90, 120 Hz or a browser's variable rate, instead of
    # per frame -- delta = 0 (a duplicate timestamp) holds, delta = ref is
    # verbatim r.
    var alpha := 1.0 - pow(1.0 - contact_position_smoothing, delta / REFERENCE_DT)
    var smoothed := lerpf(
        float(state["smoothed_contact_position"]),
        features.thumb_index_contact_position,
        alpha
    )
    state["smoothed_contact_position"] = smoothed
    var surface_delta := smoothed - float(state["start_contact_position"])
    # Mirroring produces wearer-relative events: an equivalent physical
    # gesture has the same meaning regardless of which hand performs it.
    var semantic_delta := surface_delta if p_hand == 1 else -surface_delta
    if absf(semantic_delta) > absf(float(state["peak_semantic_delta"])):
        state["peak_semantic_delta"] = semantic_delta
    var peak := float(state["peak_semantic_delta"])
    var progress := clampf(absf(peak) / minimum_index_travel, 0.0, 1.0)
    if progress > 0.05:
        var direction := Gesture.LEFT if peak > 0.0 else Gesture.RIGHT
        gesture_candidate.emit(direction, p_hand, progress)
        microgesture_candidate.emit(direction, p_hand, progress)
    if float(state["elapsed"]) >= minimum_swipe_duration and absf(peak) >= confident_commit_travel:
        _perform_swipe(state, p_hand, peak, true)

func _finish_contact(state: Dictionary, p_hand: int) -> void:
    var peak := float(state["peak_semantic_delta"])
    var travel := absf(peak)
    var elapsed := float(state["elapsed"])
    if travel >= minimum_index_travel:
        _perform_swipe(state, p_hand, peak, false)
        return
    elif elapsed >= minimum_tap_duration and elapsed <= maximum_duration and travel <= maximum_tap_travel:
        var duration_score := 1.0 - clampf(elapsed / maximum_duration, 0.0, 1.0)
        var travel_score := 1.0 - clampf(travel / maximum_tap_travel, 0.0, 1.0)
        var confidence := 0.7 + 0.15 * duration_score + 0.15 * travel_score
        gesture_performed.emit(Gesture.TAP, p_hand, confidence)
        microgesture_performed.emit(Direction.TAP, p_hand, confidence)
        state["cooldown_left"] = cooldown
    state["phase"] = Phase.WAITING_FOR_RELEASE

func _perform_swipe(state: Dictionary, p_hand: int, peak: float, early_commit: bool) -> void:
    var travel := absf(peak)
    var direction := Gesture.LEFT if peak > 0.0 else Gesture.RIGHT
    var travel_score := clampf(travel / maxf(minimum_index_travel * 1.8, 0.001), 0.0, 1.0)
    var time_score := 1.0 - clampf(float(state["elapsed"]) / maximum_duration, 0.0, 1.0)
    var confidence := 0.65 + 0.25 * travel_score + 0.10 * time_score
    if early_commit:
        confidence = maxf(confidence, 0.86)
    gesture_performed.emit(direction, p_hand, confidence)
    microgesture_performed.emit(direction, p_hand, confidence)
    state["cooldown_left"] = cooldown
    state["phase"] = Phase.WAITING_FOR_RELEASE

func _new_state() -> Dictionary:
    return {
        "phase": Phase.READY,
        "elapsed": 0.0,
        "cooldown_left": 0.0,
        "last_timestamp": 0,
        "start_contact_position": 0.5,
        "smoothed_contact_position": 0.5,
        "peak_semantic_delta": 0.0,
        "bad_frames": 0,
    }

## Full reset -- the public reset() API and nothing else. Deliberately NOT
## called on bad frames any more (see process_features): zeroing cooldown_left
## and last_timestamp on a quality flicker is precisely the bug that made one
## bad frame both forget an in-flight swipe and disarm the double-fire guard.
func _reset_state(state: Dictionary) -> void:
    state["phase"] = Phase.READY
    state["elapsed"] = 0.0
    state["cooldown_left"] = 0.0
    state["last_timestamp"] = 0
    state["start_contact_position"] = 0.5
    state["smoothed_contact_position"] = 0.5
    state["peak_semantic_delta"] = 0.0
    state["bad_frames"] = 0
