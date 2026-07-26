class_name XREyeHeightCalibrator
extends Node

## Corrects a runtime whose floor is calibrated wrong, by shifting the XROrigin
## so the wearer's eyes land at a plausible height.
##
## Measured on Galaxy XR (Android XR 1.0, play_area_mode = STAGE): a SEATED
## wearer reported camera_y = 0.80 m. A floor-referenced space should put seated
## eyes near 1.15-1.25 m and standing eyes near 1.6 m, so the runtime's floor sat
## roughly 0.4 m high -- putting the wearer under the tables with the menu
## overhead. The same build on Meta reports normal heights, so this is the
## runtime's floor estimate, not our reference-space choice (we do get a
## floor-based space; that was verified on device).
##
## Deliberately conservative: it only acts on heights that are not physically
## plausible for someone wearing a headset upright. A correctly calibrated
## runtime -- standing OR seated -- never trips it, so devices that work today
## are untouched. That is the same "additive only, never regress what works"
## rule the microgesture runtime calibration follows.

## Below this the measurement is treated as a broken floor rather than a short
## or reclining wearer. Seated eyes sit near 1.15 m even for a small adult, so
## 1.00 leaves real headroom before we intervene.
@export_range(0.0, 1.6, 0.01) var implausible_below := 1.00
## Below THIS the reading is not a floor problem at all - it means no real head
## pose has arrived and the camera is still sitting on the origin. Measured on
## device: a Quest Link session reported 0.01 m for two consecutive windows, so
## the calibrator "corrected" a broken floor by raising the origin 1.19 m and
## the wearer spent the whole session a metre in the air. The liveness check
## does not catch this - a near-zero reading that jitters by more than
## live_epsilon looks live. Treat it as not-yet-tracking and keep waiting.
@export_range(0.0, 0.8, 0.01) var tracking_absent_at_or_below := 0.30
## What we correct TO. Seated rather than standing on purpose: lifting a seated
## wearer to standing eye height would over-correct and float them above the
## scene, which is the same class of error in the other direction.
@export_range(0.5, 2.2, 0.01) var corrected_eye_height := 1.20
## Frames of agreement required before acting. Head tracking reports a default
## height (1.5 on the device measured) for the first frames of a session, and a
## single frame mid-blink or mid-lean is not evidence of a broken floor.
@export_range(1, 600, 1) var settle_frames := 90
## Consecutive low windows required before correcting. One window is a lean;
## two is a floor.
@export_range(1, 10, 1) var required_low_windows := 2
## Frames sampled once tracking is LIVE. Small on purpose: the long window
## exists to outlast the startup default, and detecting liveness directly makes
## that wait unnecessary. ~0.15 s at 72 Hz, which is below the threshold at
## which a height change reads as a pop rather than as the scene appearing.
@export_range(2, 120, 1) var live_settle_frames := 10
## How much the reported height must move between frames to prove tracking is
## live. The startup default is a CONSTANT, so any real motion exceeds this.
@export_range(0.0001, 0.05, 0.0001) var live_epsilon := 0.002
@export var enabled := true
@export var debug_log := true

signal calibrated(measured_height: float, applied_offset: float)

## Shared for the whole app run, not per rig. XRSceneRouter rebuilds the rig
## for every scene, so without this each scene switch repeats the measure-then-
## correct and the wearer sees the world drop and lift again on every load.
## David, on device: "starts off wrong and then corrects" -- once per scene.
static var _session_offset := 0.0
static var _session_valid := false

## Clears the shared calibration (new wearer, new device, or a test).
static func reset_session_calibration() -> void:
	_session_offset = 0.0
	_session_valid = false

var _origin: XROrigin3D
var _live := false
## Metres of change before the "still watching" line is worth reprinting.
const _LOG_EPSILON := 0.01

var _last_height := NAN
## Last value actually logged, so a steady measurement prints once, not forever.
var _last_logged := NAN
var _samples: Array[float] = []
var _applied := false
var _consecutive_low := 0
var _offset := 0.0
## The origin Y we last WROTE. Anything else means someone moved us.
var _expected_origin_y := NAN

## Applies an already-earned calibration before the first frame of a new scene
## is drawn. Waiting for _process cost one visible frame at the old height on
## every scene load -- David, on device: "we now do see a fast for a second when
## we go to a scene".
func _ready() -> void:
	if _session_valid:
		_apply_offset(_session_offset)

func _apply_offset(offset: float) -> void:
	# The DECISION is recorded whether or not an origin is reachable this frame.
	# Losing a hard-won measurement because the rig was momentarily unresolvable
	# would send us back to re-measuring, and the wearer back to the wrong height.
	_applied = true
	_offset = offset
	_session_offset = offset
	_session_valid = true
	_origin = _resolve_origin()
	if _origin == null:
		return
	if _offset != 0.0:
		_origin.position.y += _offset
	_expected_origin_y = _origin.position.y

## Re-applies the correction after anything else moves the origin.
##
## Teleport sets the origin's Y to the TARGET FLOOR (xr_locomotion.gd: `_origin
## .global_position += target - camera_floor`, whose y term is the origin's own
## y). That write discards the floor correction, so every teleport dropped the
## wearer back to the runtime's wrong height. Rather than teach locomotion about
## calibration -- there are several movers and each would have to remember --
## the invariant is maintained here: whatever anyone sets the origin to is
## treated as a floor placement that still needs the correction on top.
func _maintain_offset() -> void:
	if _origin == null or not is_instance_valid(_origin) or _offset == 0.0:
		return
	# Compared against what WE last wrote, not against a previous frame, so a
	# mover that writes every frame gets the offset applied once per write
	# instead of accumulating it.
	if is_nan(_expected_origin_y) or is_equal_approx(_origin.position.y, _expected_origin_y):
		return
	_origin.position.y += _offset
	_expected_origin_y = _origin.position.y

func _process(_delta: float) -> void:
	if _applied:
		_maintain_offset()
		return
	if not enabled:
		return
	var viewport := get_viewport()
	if viewport == null or not viewport.use_xr:
		return
	var camera := viewport.get_camera_3d()
	if camera == null:
		return
	_origin = _resolve_origin()
	if _origin == null:
		return

	# Height measured RELATIVE TO THE ORIGIN, not in world space: the origin may
	# already have been moved by locomotion, and only the head-above-floor part
	# of the world position is evidence about the runtime's floor.
	var height := camera.global_position.y - _origin.global_position.y

	# A calibration already earned this run applies on the FIRST frame of every
	# later scene, so only the very first scene ever pays for measuring.
	if _session_valid:
		_applied = true
		_offset = _session_offset
		if _offset != 0.0 and _origin != null and is_instance_valid(_origin):
			_origin.position.y += _offset
		return

	# Wait for tracking to be LIVE rather than for a fixed number of frames. The
	# startup value is a frozen constant (1.50 on the device measured), so the
	# first frame that moves at all proves real poses are arriving -- and from
	# there a tenth of a second is enough to decide.
	if not _live:
		if not is_nan(_last_height) and absf(height - _last_height) > live_epsilon:
			_live = true
		_last_height = height
		if not _live:
			return

	_samples.append(height)
	if _samples.size() < live_settle_frames:
		return
	_evaluate_window()

## The decision, separated from the sampling so it is drivable headless: an XR
## session cannot be stood up in a test, and this is the part that was wrong.
func _evaluate_window() -> void:
	if _samples.is_empty():
		return

	# Median, not mean: leaning, a blink of bad tracking, or the startup default
	# are outliers, and one of them should not decide a permanent offset.
	var sorted := _samples.duplicate()
	sorted.sort()
	var measured: float = sorted[sorted.size() / 2]
	_samples.clear()

	# Checked BEFORE the floor test: a near-zero height is absent tracking, not a
	# mis-calibrated floor, and correcting on it floats the wearer by nearly the
	# whole corrected_eye_height. Reset the low streak so a real low reading
	# still needs its own consecutive windows.
	if measured <= tracking_absent_at_or_below:
		_consecutive_low = 0
		if debug_log and (is_nan(_last_logged) or absf(measured - _last_logged) >= _LOG_EPSILON):
			_last_logged = measured
			print("[eye-height] measured %.2f m - no head pose yet, not correcting" % measured)
		return

	if measured >= implausible_below:
		# Deliberately NOT latching here. Head tracking reports a fixed default
		# (1.50 on the device measured) for the first stretch of a session, and
		# an early window can consist entirely of it. Latching "plausible" on
		# that reading is a permanent wrong answer -- observed on device: the
		# launcher logged 'measured 1.50 - plausible' and never corrected, while
		# a later scene measured 0.82 and did. Keep watching instead.
		_consecutive_low = 0
		# CHANGE-GATED. This branch is the HEALTHY path -- a correctly calibrated
		# floor never leaves it -- and _evaluate_window runs every
		# live_settle_frames (10). Printing unconditionally produced 91,530 lines
		# in one Link session, 99.7% of all stdout, which buries every other
		# diagnostic and costs string formatting plus I/O forever. Log only when
		# the measurement actually moves.
		if debug_log and (is_nan(_last_logged) or absf(measured - _last_logged) >= _LOG_EPSILON):
			_last_logged = measured
			print("[eye-height] measured %.2f m - plausible, still watching" % measured)
		return

	# Two windows in a row, so leaning down to look at something cannot be
	# mistaken for a broken floor.
	_consecutive_low += 1
	if _consecutive_low < required_low_windows:
		if debug_log:
			print("[eye-height] measured %.2f m - low, awaiting confirmation (%d/%d)" % [
				measured, _consecutive_low, required_low_windows])
		return

	_apply_offset(corrected_eye_height - measured)
	if debug_log:
		print("[eye-height] measured %.2f m (below %.2f) - raised origin by %.2f m" % [
			measured, implausible_below, _offset])
	calibrated.emit(measured, _offset)

## Undoes the correction, for an A/B in-headset without relaunching.
func revert() -> void:
	if not _applied or _origin == null or not is_instance_valid(_origin):
		return
	_origin.position.y -= _offset
	_offset = 0.0
	_applied = false
	_samples.clear()
	reset_session_calibration()

func get_applied_offset() -> float:
	return _offset

func _resolve_origin() -> XROrigin3D:
	if _origin != null and is_instance_valid(_origin):
		return _origin
	var parent := get_parent()
	while parent != null:
		if parent is XROrigin3D:
			return parent as XROrigin3D
		parent = parent.get_parent()
	# Ancestry above is the normal path. The tree-wide sweep is a fallback for a
	# calibrator parented outside the origin, and it is only legal while we are
	# actually in the tree -- get_tree() on a detached node errors.
	if not is_inside_tree():
		return null
	var found := get_tree().root.find_children("*", "XROrigin3D", true, false)
	return found[0] as XROrigin3D if not found.is_empty() else null
