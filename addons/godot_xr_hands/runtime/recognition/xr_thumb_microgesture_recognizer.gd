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
## 0.44/0.50, raised from 0.40/0.46 against the measured press distribution
## (2026-07-30): the right thumb's near-contact side distance had median
## 0.46 with light (leftward-extension) sweeps riding 0.42-0.55, and 9
## CONTACT_TOO_LIGHT in one stationary-gate session were sweeps the 0.40
## gate never saw. A modest raise, deliberately NOT to the hover median:
## arming at 0.46+ would put ordinary hovering inside the gate and
## manufacture phantom taps. Watch the TAP count on device after this
## change -- it is the canary for having gone too far.
## Third measured step (2026-07-30): 0.40 -> 0.44 -> 0.46, now AT the
## measured hover median. Closing the travel dead band invited gentler
## swipes, and gentler swipes press lighter: CONTACT_TOO_LIGHT jumped 3 ->
## 16 in the first closed-band session, concentrated on rightward pulls.
## This is the LAST flat-gate step that makes sense -- at the median, half
## of near-contact time is inside the gate, and any further raise trades
## light-press catches for phantom taps one-for-one. Past this the fix is
## the press-mode envelope redesign (tier 3), not this dial.
@export_range(0.05, 1.5, 0.01) var contact_threshold := 0.46
@export_range(0.05, 2.0, 0.01) var release_threshold := 0.52
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
## OFF as of 2026-07-30, measured live: the envelope floated the contact
## gate to 0.81 (left hand) and 0.65 (right) MID-SESSION, at which point
## ordinary hovering armed constantly, taps fired from grazes, and the user
## reported "way worse, left and right both unreliable". The flaw is in what
## it samples: posture gates on finger CURLS, so a curled hand with a lifted
## thumb feeds OPEN-AIR distances into the ring, and the quantiles drift the
## gate toward hover space as a session progresses -- a NONSTATIONARY gate,
## which on device reads as "sometimes works, sometimes doesn't". The
## machinery stays for the tier-3 redesign (it must sample the PRESS mode,
## not everything in posture); until that exists, a stationary authored gate
## is the baseline that works. Per the suite's standing rollback rule:
## working code is not discarded for purity -- and not kept for it either.
@export var adaptive_contact := false
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
## 0.98, raised from 0.88 against on-device measurement (2026-07-30): the
## left thumb's natural rest reads 0.74-1.00 along the index, repeatedly at
## 0.84-0.96, and every rest above the old ceiling died silently at the
## arming gate -- OUT_OF_START_ZONE counted 5 in the exact session the user
## reported 5 misses in 12 left swipes. 0.98 clears every measured non-pinned
## rest while still excluding the truly pinned endpoint (position clamped to
## 1.0 means the closest point is a CORNER and the geometry is unbounded --
## the same reason _is_calibration_sample excludes pins).
@export_range(0.0, 1.0, 0.01) var start_zone_maximum := 0.98
## 0.10, the resting point of three measured moves (2026-07-30): 0.12 ate
## ten gentle swipes a session; 0.09 (floor == tap ceiling, band closed)
## produced WRONG-DIRECTION snaps -- many swipes begin with a small
## opposite-direction wind-up, and with the floor at 0.09 a wind-up could
## become the recorded peak and win the direction when the main stroke
## lifted early. A wrong action is worse than a missed one (the same
## principle that made phantom swipes tier 1's target), so the band
## reopens to (0.09, 0.10): gentle strokes there reject VISIBLY as
## SWIPE_TOO_SHORT instead of committing a coin-flip. The real resolution
## -- committing on net displacement that AGREES with the peak, so a
## wind-up can never win -- is a recognition-logic change that waits for
## the replay corpus, not another value move.
@export_range(0.02, 0.8, 0.01) var minimum_index_travel := 0.10
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
## A PINCH is not a microgesture: thumb-tip-to-index-tip at or below this
## vetoes arming outright. Found on device (2026-07-30): widening the start
## zone to 0.98 for high thumb rests also let PINCH contacts (thumb near the
## index tip) arm, and a pinch armed-and-released reads as a TAP -- which
## toggles the teleport arc, felt as "switching from fist to pinching
## doesn't remove the arc" because the pinch kept turning it back on. Meta
## suppresses microgesture recognition during pinch for the same reason:
## pinch is the higher-priority interaction, and the index-curl posture gate
## cannot catch it (a pinching index curls partway, above the arming
## minimum). Distances are palm-width-normalized; a true pinch reads well
## under this, the microgesture rest (thumb on the index SIDE, tips apart)
## well over it.
@export_range(0.0, 1.0, 0.01) var pinch_veto_distance := 0.18

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
            gesture_rejected.emit(p_hand, RejectReason.LOW_QUALITY, _attempted_direction(state))
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
            gesture_rejected.emit(p_hand, RejectReason.DISCONTINUITY, -1)
        return

    var posture_score := gate_score(features)
    # Learn the envelope only in gesture POSTURE. An open, relaxed hand spends
    # most of its time far from the index and would drag `high` up until the
    # gate sat in empty space.
    if posture_score >= 0.999 and _is_calibration_sample(features):
        observe_contact_distance(p_hand, features.thumb_index_side_distance, delta)
    match int(state["phase"]):
        Phase.READY:
            var side := features.thumb_index_side_distance
            var in_contact := side <= effective_contact_threshold(p_hand)
            # A pinching hand skips arming AND the near-miss reporters: a
            # pinch is a deliberate act of a DIFFERENT interaction, not a
            # failed microgesture attempt, so it must produce neither a
            # gesture nor rejection noise. Episode-end bookkeeping below
            # still runs, so a pinch also clears any stale latches.
            var pinching := features.pinch_distance <= pinch_veto_distance
            if not pinching and float(state["cooldown_left"]) <= 0.0 and posture_score >= 0.999 and _can_start(features, p_hand):
                _start_tracking(state, features)
                return
            if not pinching and float(state["cooldown_left"]) <= 0.0 and in_contact and posture_score >= 0.999 \
                    and not bool(state.get("zone_blocked", false)):
                # Contact made, posture good, cooldown clear -- the ONE gate
                # refusing to arm is the start zone. Before this emission the
                # attempt produced nothing at all, which is how "swiping left
                # is not very reliable" coexisted with clean-looking counters:
                # a thumb resting near the fingertip starts LEFT swipes above
                # start_zone_maximum and they died in silence. Latched per
                # contact episode (cleared on release below), because emitting
                # per frame would fire dozens of times per touch.
                state["zone_blocked"] = true
                gesture_rejected.emit(p_hand, RejectReason.OUT_OF_START_ZONE, -1)
            elif not pinching and float(state["cooldown_left"]) <= 0.0 and in_contact and posture_score < 0.999 \
                    and not bool(state.get("posture_blocked", false)):
                # Contact made but the posture score flunks the (near-exact)
                # arming bar. The other formerly-silent arming gate.
                state["posture_blocked"] = true
                gesture_rejected.emit(p_hand, RejectReason.POSTURE_NOT_READY, -1)
            elif not pinching and not in_contact and side <= effective_release_threshold(p_hand) and posture_score >= 0.999:
                # HOVERING just above the contact gate, in posture. Accumulate
                # the lateral travel of the hover: a sweep's worth of motion
                # that never pressed in is an attempt the contact gate ate --
                # MEASURED as the left-swipe killer on the right hand, where
                # extension lightens the press and the whole swipe rides
                # 0.42-0.55 against a 0.40 gate. Reported once, at episode end
                # below, so a resting hover that never sweeps stays silent.
                state["hover_low"] = minf(float(state.get("hover_low", INF)), features.thumb_index_contact_position)
                state["hover_high"] = maxf(float(state.get("hover_high", -INF)), features.thumb_index_contact_position)
            if pinching or side >= effective_release_threshold(p_hand):
                # Episode over: the thumb left the surface region entirely,
                # or committed to a PINCH -- either way this contact episode
                # is not a microgesture attempt any more.
                state["zone_blocked"] = false
                state["posture_blocked"] = false
                var hover_range := float(state.get("hover_high", -INF)) - float(state.get("hover_low", INF))
                state["hover_low"] = INF
                state["hover_high"] = -INF
                # Not when the episode ended BY pinching: hover travel on the
                # way into a pinch was a pinch approach, not a failed swipe.
                if not pinching and hover_range >= minimum_index_travel and float(state["cooldown_left"]) <= 0.0:
                    gesture_rejected.emit(p_hand, RejectReason.CONTACT_TOO_LIGHT, -1)
        Phase.TRACKING:
            state["elapsed"] = float(state["elapsed"]) + delta
            # Split so the rejection can carry the SPECIFIC cause -- "hand
            # opened up" and "thumb lingered too long" need different user
            # corrections, and a merged reason would teach neither.
            if posture_score < tracking_gate_release:
                state["phase"] = Phase.WAITING_FOR_RELEASE
                gesture_rejected.emit(p_hand, RejectReason.POSTURE_LOST, _attempted_direction(state))
                return
            # A RESTING thumb is the canonical microgesture posture -- rest on
            # the index, then swipe -- but maximum_duration used to run from
            # CONTACT start, so resting past it armed a trap: the eventual
            # swipe was eaten until release. Measured on device as exactly the
            # left-swipe unreliability being chased (session telemetry: every
            # LEFT miss was TOO_SLOW; nine of the first session's rejections
            # were this, mostly resting-thumb noise). While no travel beyond
            # tap-noise has accumulated, slide the window: the ceiling then
            # bounds the SWIPE, which was always its intent, and a rest of any
            # length stays silent -- a rest is not an attempt. Checked at half
            # the window so a swipe begun late in a rest still gets at least
            # half a window before the re-anchor could clip it, and the
            # re-anchor is peak-gated so it can never clip a swipe already in
            # flight (its accumulated travel blocks the re-anchor).
            if absf(float(state["peak_semantic_delta"])) <= maximum_tap_travel \
                    and float(state["elapsed"]) > maximum_duration * 0.5:
                _reanchor_rest(state)
            if float(state["elapsed"]) > maximum_duration:
                state["phase"] = Phase.WAITING_FOR_RELEASE
                gesture_rejected.emit(p_hand, RejectReason.TOO_SLOW, _attempted_direction(state))
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

## Honest capability set: the contact position is ONE axis (along the index
## finger), so this recognizer has nothing to derive FORWARD/BACKWARD from.
## Consumers adapt via this instead of discovering it by dead air; whether a
## second axis is measurable is an open investigation
## (docs/microgesture-hardening-design.md, tier 2), not a promise.
func get_supported_gestures() -> Array:
    return [Gesture.LEFT, Gesture.RIGHT, Gesture.TAP]

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
    state["reanchored"] = false
    # The approach hover is spent: without this reset, hover travel
    # accumulated on the way IN to a successful gesture survived the gesture
    # and fired a phantom CONTACT_TOO_LIGHT at the eventual release.
    state["hover_low"] = INF
    state["hover_high"] = -INF

## Slides the gesture window to NOW: the thumb has been resting (no travel
## beyond tap noise), so the time already spent is rest, not gesture. Start
## re-seeds to the settled position so slow drift during the rest is not
## counted as travel either. `reanchored` marks the attempt so a later LIFT
## is not read as a tap -- a tap is a quick touch, and a touch that rested
## first is just a thumb leaving its resting place.
func _reanchor_rest(state: Dictionary) -> void:
    state["elapsed"] = 0.0
    state["start_contact_position"] = float(state["smoothed_contact_position"])
    state["peak_semantic_delta"] = 0.0
    state["reanchored"] = true

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
    elif bool(state.get("reanchored", false)) and travel <= maximum_tap_travel:
        # Lifting a thumb that had been RESTING. Not a tap (a tap is a quick
        # touch; this touch rested first) and not a failed attempt either --
        # the user was not attempting anything, so this is the one silent
        # path that is CORRECT to keep silent: rejections are for attempts.
        pass
    elif elapsed >= minimum_tap_duration and elapsed <= maximum_duration and travel <= maximum_tap_travel:
        var duration_score := 1.0 - clampf(elapsed / maximum_duration, 0.0, 1.0)
        var travel_score := 1.0 - clampf(travel / maximum_tap_travel, 0.0, 1.0)
        var confidence := 0.7 + 0.15 * duration_score + 0.15 * travel_score
        gesture_performed.emit(Gesture.TAP, p_hand, confidence)
        microgesture_performed.emit(Direction.TAP, p_hand, confidence)
        state["cooldown_left"] = cooldown
    else:
        # A contact that armed, moved, released, and produced NOTHING. This
        # used to be silence -- and the SWIPE_TOO_SHORT case is the measured
        # dead band (travel past maximum_tap_travel yet short of
        # minimum_index_travel), where a fumbled swipe simply vanished. The
        # user did something; say what was wrong with it. elapsed >
        # maximum_duration cannot reach here (TRACKING already exits on it),
        # so the only tap failure left is releasing too quickly.
        if travel > maximum_tap_travel:
            gesture_rejected.emit(p_hand, RejectReason.SWIPE_TOO_SHORT, _attempted_direction(state))
        else:
            gesture_rejected.emit(p_hand, RejectReason.TAP_TOO_QUICK, Gesture.TAP)
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
        "reanchored": false,
        "zone_blocked": false,
        "posture_blocked": false,
        "hover_low": INF,
        "hover_high": -INF,
    }

## The Gesture this attempt's travel was heading toward when it died, for
## rejection telemetry: LEFT/RIGHT by the sign of the accumulated peak, -1
## when the travel is too small to attribute. Reads the same
## peak_semantic_delta the commit paths read, so the attribution can never
## disagree with what a successful commit would have called the direction.
func _attempted_direction(state: Dictionary) -> int:
    var peak := float(state.get("peak_semantic_delta", 0.0))
    if absf(peak) < 0.01:
        return -1
    return Gesture.LEFT if peak > 0.0 else Gesture.RIGHT

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
    state["reanchored"] = false
    state["zone_blocked"] = false
    state["posture_blocked"] = false
    state["hover_low"] = INF
    state["hover_high"] = -INF
