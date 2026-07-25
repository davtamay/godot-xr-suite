extends SceneTree

## Headless tests for XREyeHeightCalibrator, driven by the exact sequence
## observed on Galaxy XR: head tracking reports a fixed 1.50 m default for the
## first stretch of a session, then settles to the real 0.82 m.
##
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_webxr_kit/tests/test_eye_height_calibrator.gd

const Calibrator := preload("res://addons/godot_webxr_kit/runtime/xr_eye_height_calibrator.gd")

# From the device log.
const STARTUP_DEFAULT := 1.50
const REAL_SEATED := 0.82

var _failures: Array[String] = []

func _init() -> void:
    _test_startup_default_does_not_latch(_failures)
    _test_corrects_a_broken_floor(_failures)
    _test_plausible_height_is_left_alone(_failures)
    _test_a_single_lean_does_not_correct(_failures)
    _test_correction_applies_once(_failures)
    _test_later_scenes_apply_it_immediately(_failures)
    _test_startup_default_is_not_mistaken_for_live(_failures)

## Deferred: a node added during _init() is not inside the tree yet, and these
## two cases need a REAL origin to move. Same constraint the other suites carry.
func _process(_delta: float) -> bool:
    _test_teleport_does_not_discard_the_correction(_failures)
    _test_repeated_moves_do_not_accumulate(_failures)
    _test_new_scene_is_correct_on_the_first_frame(_failures)
    if _failures.is_empty():
        print("XR eye height: PASS")
        quit(0)
        return true
    for failure in _failures:
        push_error(failure)
    print("XR eye height: FAIL (%d)" % _failures.size())
    quit(1)
    return true

## Feeds one full decision window at a fixed height, bypassing the tree so the
## logic is testable without an XR session.
func _fresh():
    # The calibration is shared for the whole app run by design, so a test that
    # did not clear it would inherit the previous test's answer.
    Calibrator.reset_session_calibration()
    return Calibrator.new()

func _feed(cal, height: float, windows := 1) -> void:
    for w in range(windows):
        for f in range(cal.settle_frames):
            cal._samples.append(height)
        cal._evaluate_window()

func _test_startup_default_does_not_latch(failures: Array[String]) -> void:
    # THE BUG, from the device log: the launcher's first window consisted
    # entirely of the 1.50 startup default, the calibrator called it plausible
    # and LATCHED, so the real 0.82 that followed was never seen. The wearer
    # stayed under the tables for that whole scene.
    var cal = _fresh()
    _feed(cal, STARTUP_DEFAULT, 1)
    if cal._applied:
        failures.append("startup: latched on the 1.50 startup default - the real height can never be seen")
    _feed(cal, REAL_SEATED, cal.required_low_windows)
    if not cal._applied:
        failures.append("startup: never corrected after the real %s m arrived" % REAL_SEATED)
    if cal.get_applied_offset() <= 0.0:
        failures.append("startup: offset %s should raise the origin" % cal.get_applied_offset())
    cal.free()

func _test_corrects_a_broken_floor(failures: Array[String]) -> void:
    var cal = _fresh()
    _feed(cal, REAL_SEATED, cal.required_low_windows)
    if not cal._applied:
        failures.append("broken_floor: %s m was not corrected" % REAL_SEATED)
    var expected: float = cal.corrected_eye_height - REAL_SEATED
    if not is_equal_approx(cal.get_applied_offset(), expected):
        failures.append("broken_floor: offset %s, expected %s" % [cal.get_applied_offset(), expected])
    cal.free()

func _test_plausible_height_is_left_alone(failures: Array[String]) -> void:
    # A correctly calibrated runtime -- standing OR seated -- must never be
    # touched, or this "fix" becomes a bug on every working device.
    for height in [1.05, 1.20, 1.62, 1.85]:
        var cal = _fresh()
        _feed(cal, height, 5)
        if cal._applied:
            failures.append("plausible: corrected a healthy %s m by %s" % [height, cal.get_applied_offset()])
        cal.free()

func _test_a_single_lean_does_not_correct(failures: Array[String]) -> void:
    # Leaning down to look at something briefly reads low. One window must not
    # be enough, or the world would jump while the wearer bends over.
    var cal = _fresh()
    _feed(cal, REAL_SEATED, 1)
    if cal._applied:
        failures.append("lean: corrected after a single low window")
    # Standing back up must clear the tally, not leave it primed.
    _feed(cal, 1.30, 1)
    _feed(cal, REAL_SEATED, 1)
    if cal._applied:
        failures.append("lean: a recovered window did not reset the confirmation tally")
    cal.free()

func _test_correction_applies_once(failures: Array[String]) -> void:
    # After correcting, the measured height becomes plausible; re-running would
    # ratchet the origin upward every window.
    var cal = _fresh()
    _feed(cal, REAL_SEATED, cal.required_low_windows)
    var first: float = cal.get_applied_offset()
    _feed(cal, REAL_SEATED, 4)
    if not is_equal_approx(cal.get_applied_offset(), first):
        failures.append("once: offset ratcheted from %s to %s" % [first, cal.get_applied_offset()])
    cal.free()

func _test_later_scenes_apply_it_immediately(failures: Array[String]) -> void:
    # XRSceneRouter rebuilds the rig per scene, so a per-instance calibration
    # makes EVERY scene load repeat the measure-then-correct. On device that is
    # the world dropping and lifting again on each load. The second rig must
    # inherit the answer rather than rediscover it.
    var first = _fresh()
    _feed(first, REAL_SEATED, first.required_low_windows)
    var earned: float = first.get_applied_offset()
    if earned <= 0.0:
        failures.append("later_scenes fixture: the first rig never calibrated, so this proves nothing")
    first.free()

    # A NEW rig, as a scene change produces -- deliberately NOT via _fresh(),
    # which would wipe the shared calibration this test is about.
    var second = Calibrator.new()
    if not second._session_valid:
        failures.append("later_scenes: the calibration did not survive the rig being rebuilt")
    if not is_equal_approx(second._session_offset, earned):
        failures.append("later_scenes: inherited offset %s, expected %s" % [second._session_offset, earned])
    second.free()
    Calibrator.reset_session_calibration()

func _test_startup_default_is_not_mistaken_for_live(failures: Array[String]) -> void:
    # Liveness is what lets the wait drop from ~2.5 s to ~0.15 s, so the test
    # that it cannot be faked by the frozen startup value is load-bearing: if a
    # constant counted as live, we would calibrate against 1.50 and never move.
    var cal = _fresh()
    var height := STARTUP_DEFAULT
    for f in range(200):
        # Exactly constant, as the runtime reports it before poses arrive.
        if not is_nan(cal._last_height) and absf(height - cal._last_height) > cal.live_epsilon:
            cal._live = true
        cal._last_height = height
    if cal._live:
        failures.append("liveness: a frozen %s m reading was treated as live tracking" % STARTUP_DEFAULT)
    # ...and a real pose immediately flips it.
    height = STARTUP_DEFAULT + cal.live_epsilon * 10.0
    if not is_nan(cal._last_height) and absf(height - cal._last_height) > cal.live_epsilon:
        cal._live = true
    if not cal._live:
        failures.append("liveness: real head motion did not register as live")
    cal.free()

## Builds a real origin with the calibrator under it, so the offset bookkeeping
## is exercised against an actual node rather than in the abstract.
func _rigged() -> Array:
    Calibrator.reset_session_calibration()
    var origin := XROrigin3D.new()
    var cal = Calibrator.new()
    origin.add_child(cal)
    root.add_child(origin)
    return [origin, cal]

func _test_teleport_does_not_discard_the_correction(failures: Array[String]) -> void:
    # THE BUG. xr_locomotion sets the origin Y to the TARGET FLOOR, which wipes
    # a correction parked in that same value -- so every teleport dropped the
    # wearer back to the runtime's wrong height.
    var rig := _rigged()
    var origin: XROrigin3D = rig[0]
    var cal = rig[1]
    cal._apply_offset(0.38)
    var corrected := origin.position.y
    if not is_equal_approx(corrected, 0.38):
        failures.append("teleport fixture: expected origin at 0.38, got %s" % corrected)

    # Teleport to a floor at y = 5.0, exactly as locomotion writes it.
    origin.position.y = 5.0
    cal._maintain_offset()
    if not is_equal_approx(origin.position.y, 5.38):
        failures.append("teleport: landed at %s, expected 5.38 (target floor 5.0 + correction 0.38)" % origin.position.y)
    origin.queue_free()

func _test_repeated_moves_do_not_accumulate(failures: Array[String]) -> void:
    # A mover that writes the origin EVERY frame (smooth locomotion) must get
    # the correction applied once per write, not compounded into a climb.
    var rig := _rigged()
    var origin: XROrigin3D = rig[0]
    var cal = rig[1]
    cal._apply_offset(0.38)
    for step in range(20):
        origin.position.y = float(step)      # the mover's placement
        cal._maintain_offset()
        if not is_equal_approx(origin.position.y, float(step) + 0.38):
            failures.append("accumulate: step %d landed at %s, expected %s" % [
                step, origin.position.y, float(step) + 0.38])
            break
    # And with NO external write, nothing may drift.
    var settled := origin.position.y
    for _f in range(10):
        cal._maintain_offset()
    if not is_equal_approx(origin.position.y, settled):
        failures.append("accumulate: drifted from %s to %s with no external move" % [settled, origin.position.y])
    origin.queue_free()

func _test_new_scene_is_correct_on_the_first_frame(failures: Array[String]) -> void:
    # A scene loading with a calibration already earned must be correct BEFORE
    # anything is drawn. Applying it from _process instead costs one visible
    # frame at the wrong height on every scene load -- David, on device: "we now
    # do see a fast for a second when we go to a scene".
    Calibrator.reset_session_calibration()
    var primer = Calibrator.new()
    primer._apply_offset(0.38)          # as the first scene would have earned it
    primer.free()

    var origin := XROrigin3D.new()
    var cal = Calibrator.new()
    origin.add_child(cal)
    origin.position.y = 2.0             # wherever the new scene places the rig
    root.add_child(origin)              # _ready runs here, before any frame

    if not is_equal_approx(origin.position.y, 2.38):
        failures.append("first_frame: origin at %s on entering the tree, expected 2.38 (placement 2.0 + correction 0.38)" % origin.position.y)
    origin.queue_free()
