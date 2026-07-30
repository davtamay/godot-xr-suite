extends SceneTree

## Headless tests for the microgesture recognizer's SELF-CALIBRATING contact
## gate. The point of the design is that no device is named anywhere: the gate
## is placed inside whatever open..closed range this hand actually produces, so
## a rig nobody has tested converges on its own.
##
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_hands/tests/test_adaptive_contact.gd

const Recognizer := preload("res://addons/godot_xr_hands/runtime/recognition/xr_thumb_microgesture_recognizer.gd")

const FRAME := 1.0 / 72.0

# Measured on device, and the whole reason this exists. Same physical pinch,
# two runtimes, non-overlapping ranges.
const META_OPEN := 0.50
const META_CLOSED := 0.09
const ANDROID_XR_OPEN := 1.05
const ANDROID_XR_CLOSED := 0.42

var _failures: Array[String] = []

## Mechanism tests opt IN to adaptation explicitly. The shipped default is
## OFF -- measured live 2026-07-30, the envelope floated the contact gate to
## 0.81/0.65 mid-session because its sampling admits in-posture HOVER, not
## just press, and the drifting gate read as "sometimes works, sometimes
## doesn't". These tests exercise the machinery for the tier-3 redesign;
## _test_adaptive_ships_disabled pins the default so turning it back on is a
## deliberate act with on-device evidence, not an inheritance accident.
func _adaptive_recognizer():
    var rec = Recognizer.new()
    rec.adaptive_contact = true
    return rec

func _init() -> void:
    _test_adaptive_ships_disabled(_failures)
    _test_cold_start_is_unchanged(_failures)
    _test_meta_range_still_detects(_failures)
    _test_android_xr_range_detects_where_fixed_gate_fails(_failures)
    _test_still_hand_does_not_adapt(_failures)
    _test_release_never_inverts(_failures)
    _test_hands_calibrate_independently(_failures)
    _test_occlusion_spikes_do_not_corrupt(_failures)
    _test_endpoint_frames_are_not_calibration(_failures)
    _test_too_few_samples_is_not_evidence(_failures)
    _test_reconverges_when_the_rig_changes(_failures)
    if _failures.is_empty():
        print("XR adaptive contact: PASS")
        quit(0)
        return
    for failure in _failures:
        push_error(failure)
    print("XR adaptive contact: FAIL (%d)" % _failures.size())
    quit(1)

## The envelope SHIPS OFF. It floated the contact gate to 0.81 (left hand)
## and 0.65 (right) mid-session on device, arming on ordinary hover and
## firing taps from grazes -- a nonstationary gate that made BOTH directions
## unreliable. Its sampling must learn the PRESS mode, not everything in
## posture, before it earns the default back.
func _test_adaptive_ships_disabled(failures: Array[String]) -> void:
    var rec = Recognizer.new()
    if rec.adaptive_contact:
        failures.append("adaptive_contact must ship DISABLED until its sampling distinguishes press from hover -- it drifted the gate to 0.81 mid-session on device and broke both directions")
    rec.free()

## Drives one open/close cycle repeatedly, the way a wearer flexing the thumb
## against the index would, so the envelope sees both extremes.
func _train(rec, hand: int, closed: float, open_value: float, cycles: int) -> void:
    for i in range(cycles):
        for _f in range(6):
            rec.observe_contact_distance(hand, open_value, FRAME)
        for _f in range(3):
            rec.observe_contact_distance(hand, closed, FRAME)

func _test_cold_start_is_unchanged(failures: Array[String]) -> void:
    # A rig that works today must not change behaviour before any evidence
    # arrives -- the authored values are on-device-tuned and are the baseline.
    var rec = _adaptive_recognizer()
    if not is_equal_approx(rec.effective_contact_threshold(0), rec.contact_threshold):
        failures.append("cold_start: contact should be the authored %s, got %s" % [
            rec.contact_threshold, rec.effective_contact_threshold(0)])
    if not is_equal_approx(rec.effective_release_threshold(0), rec.release_threshold):
        failures.append("cold_start: release should be the authored %s, got %s" % [
            rec.release_threshold, rec.effective_release_threshold(0)])
    if rec.contact_span(0) >= 0.0:
        failures.append("cold_start: span must report untrusted before any observation")
    rec.free()

func _test_meta_range_still_detects(failures: Array[String]) -> void:
    # The runtime that already works must keep working after adaptation kicks in.
    var rec = _adaptive_recognizer()
    _train(rec, 0, META_CLOSED, META_OPEN, 40)
    var contact: float = rec.effective_contact_threshold(0)
    if not (META_CLOSED < contact and contact < META_OPEN):
        failures.append("meta: gate %s must sit strictly between closed %s and open %s" % [
            contact, META_CLOSED, META_OPEN])
    if META_CLOSED > contact:
        failures.append("meta: a real pinch would no longer register")
    if META_OPEN <= contact:
        failures.append("meta: an OPEN hand would register as contact -- false positives")
    rec.free()

func _test_android_xr_range_detects_where_fixed_gate_fails(failures: Array[String]) -> void:
    # THE BUG. With the fixed 0.40 gate, a genuine Android XR pinch at 0.42
    # reads as "not touching", which on device was "snap does not work at all".
    # The gate is pinned to the HISTORICAL 0.40/0.46 this scenario was
    # measured against: the shipped defaults have since moved (0.44 as of
    # 2026-07-30, which incidentally puts the 0.42 Android pinch inside the
    # fixed gate), and this test is about the MECHANISM rescuing a range the
    # fixed gate misses, not about tracking whatever the defaults become.
    var rec = _adaptive_recognizer()
    rec.contact_threshold = 0.40
    rec.release_threshold = 0.46
    if ANDROID_XR_CLOSED <= rec.contact_threshold:
        failures.append("fixture: android closed %s must exceed the fixed gate %s, else this test proves nothing" % [
            ANDROID_XR_CLOSED, rec.contact_threshold])
    _train(rec, 0, ANDROID_XR_CLOSED, ANDROID_XR_OPEN, 40)
    var contact: float = rec.effective_contact_threshold(0)
    if ANDROID_XR_CLOSED > contact:
        failures.append("android: a real pinch at %s still fails the adapted gate %s" % [
            ANDROID_XR_CLOSED, contact])
    if ANDROID_XR_OPEN <= contact:
        failures.append("android: an open hand at %s passes the gate %s -- false positives" % [
            ANDROID_XR_OPEN, contact])
    rec.free()

func _test_still_hand_does_not_adapt(failures: Array[String]) -> void:
    # The degenerate case that makes naive auto-gain dangerous: a hand held
    # still produces a narrow noise band, and normalizing THAT would place the
    # gate inside the noise and fire the gesture continuously.
    var rec = _adaptive_recognizer()
    for i in range(400):
        rec.observe_contact_distance(0, 0.55 + (0.01 if i % 2 == 0 else -0.01), FRAME)
    if rec.contact_span(0) >= 0.0:
        failures.append("still_hand: a %s-wide noise band was accepted as calibration" % 0.02)
    if not is_equal_approx(rec.effective_contact_threshold(0), rec.contact_threshold):
        failures.append("still_hand: must fall back to the authored gate, got %s" % rec.effective_contact_threshold(0))
    # ...and with the fallback in force, that resting distance must NOT count as
    # contact, or the hand would gesture by sitting there.
    if 0.55 <= rec.effective_contact_threshold(0):
        failures.append("still_hand: a resting hand registers as contact")
    rec.free()

func _test_release_never_inverts(failures: Array[String]) -> void:
    # Release below contact would latch the recognizer: it would enter contact
    # and never see a release, killing every subsequent gesture.
    var rec = _adaptive_recognizer()
    for pair in [[META_CLOSED, META_OPEN], [ANDROID_XR_CLOSED, ANDROID_XR_OPEN], [0.30, 0.62]]:
        _train(rec, 1, pair[0], pair[1], 40)
        if rec.effective_release_threshold(1) <= rec.effective_contact_threshold(1):
            failures.append("inversion: release %s <= contact %s for range %s" % [
                rec.effective_release_threshold(1), rec.effective_contact_threshold(1), str(pair)])
    rec.free()

func _test_hands_calibrate_independently(failures: Array[String]) -> void:
    # Left and right are tracked separately by the runtime and can differ; one
    # shared envelope would let a well-seen hand mis-calibrate the other.
    var rec = _adaptive_recognizer()
    _train(rec, 0, META_CLOSED, META_OPEN, 40)
    _train(rec, 1, ANDROID_XR_CLOSED, ANDROID_XR_OPEN, 40)
    var left: float = rec.effective_contact_threshold(0)
    var right: float = rec.effective_contact_threshold(1)
    if is_equal_approx(left, right):
        failures.append("independence: both hands resolved to the same gate %s" % left)
    if not (META_CLOSED < left and left < META_OPEN):
        failures.append("independence: left gate %s left its own range" % left)
    if not (ANDROID_XR_CLOSED < right and right < ANDROID_XR_OPEN):
        failures.append("independence: right gate %s left its own range" % right)
    rec.free()

func _test_occlusion_spikes_do_not_corrupt(failures: Array[String]) -> void:
    # THE RELIABILITY BUG. On device the thumb's tracked position degrades at
    # the exact moment it touches the index -- the finger occludes it -- and the
    # reading spikes to 1.4-1.9 palm widths for a few frames. A min/max envelope
    # latched onto those and floated the gate to ~0.84, which fires on a hand
    # that is nowhere near contact. Percentiles must ignore them.
    var rec = _adaptive_recognizer()
    for i in range(60):
        for _f in range(6):
            rec.observe_contact_distance(0, ANDROID_XR_OPEN, FRAME)
        for _f in range(3):
            rec.observe_contact_distance(0, ANDROID_XR_CLOSED, FRAME)
        # One spike per cycle -- roughly the rate seen on device.
        rec.observe_contact_distance(0, 1.86, FRAME)
    var contact: float = rec.effective_contact_threshold(0)
    # The gate must stay nearer the CLOSED end than the OPEN end. Merely being
    # below `open` is not enough: a gate at 0.92 of a 0.42..1.05 range sits in
    # the noise around a resting hand and fires on it.
    var midpoint := (ANDROID_XR_CLOSED + ANDROID_XR_OPEN) * 0.5
    if contact >= midpoint:
        failures.append("occlusion: spikes dragged the gate to %s, past the midpoint %s of the real %s..%s range" % [
            contact, midpoint, ANDROID_XR_CLOSED, ANDROID_XR_OPEN])
    if ANDROID_XR_CLOSED > contact:
        failures.append("occlusion: real pinch %s no longer passes gate %s" % [ANDROID_XR_CLOSED, contact])
    rec.free()

func _test_endpoint_frames_are_not_calibration(failures: Array[String]) -> void:
    # thumb_index_contact_position pinned at 0 or 1 means the closest point is
    # an ENDPOINT: the thumb is off the end of the finger, so the distance is to
    # a corner and is unbounded. Those frames must not reach the envelope.
    var rec = _adaptive_recognizer()
    var features := XRHandFeatures.new()
    features.valid = true
    features.thumb_index_contact_position = 1.0
    if rec._is_calibration_sample(features):
        failures.append("endpoint: position 1.0 (past the fingertip) accepted as calibration")
    features.thumb_index_contact_position = 0.0
    if rec._is_calibration_sample(features):
        failures.append("endpoint: position 0.0 (below the base) accepted as calibration")
    features.thumb_index_contact_position = 0.45
    if not rec._is_calibration_sample(features):
        failures.append("endpoint: a genuine mid-finger contact at 0.45 was rejected")
    rec.free()

func _test_too_few_samples_is_not_evidence(failures: Array[String]) -> void:
    # A handful of samples can span a wide range by luck. Acting on that would
    # calibrate the gate off two frames of noise, so the authored value must
    # stay in force until there is enough evidence.
    var rec = _adaptive_recognizer()
    var few: int = rec.minimum_samples - 10
    for i in range(few):
        rec.observe_contact_distance(0, 0.10 if i % 2 == 0 else 1.90, FRAME)
    if rec.contact_span(0) >= 0.0:
        failures.append("too_few: %d samples were accepted as calibration" % few)
    if not is_equal_approx(rec.effective_contact_threshold(0), rec.contact_threshold):
        failures.append("too_few: gate moved to %s before there was evidence" % rec.effective_contact_threshold(0))
    rec.free()

func _test_reconverges_when_the_rig_changes(failures: Array[String]) -> void:
    # The ring must actually recycle. If the cursor never wraps, the first
    # calibration is frozen forever -- so swapping headsets, or handing the
    # device to someone with different hands, would keep the old gate for the
    # rest of the session.
    var rec = _adaptive_recognizer()
    _train(rec, 0, META_CLOSED, META_OPEN, 60)
    var before: float = rec.effective_contact_threshold(0)
    # Now feed a thoroughly different rig for well over one ring length.
    _train(rec, 0, ANDROID_XR_CLOSED, ANDROID_XR_OPEN, 120)
    var after: float = rec.effective_contact_threshold(0)
    if is_equal_approx(before, after):
        failures.append("reconverge: gate stuck at %s after the range changed entirely" % before)
    if ANDROID_XR_CLOSED > after:
        failures.append("reconverge: a pinch at %s fails the re-converged gate %s" % [ANDROID_XR_CLOSED, after])
    if after >= ANDROID_XR_OPEN:
        failures.append("reconverge: gate %s reaches the open hand %s" % [after, ANDROID_XR_OPEN])
    rec.free()
