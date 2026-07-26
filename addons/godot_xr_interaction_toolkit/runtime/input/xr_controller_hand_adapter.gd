extends "res://addons/godot_xr_interaction_toolkit/runtime/input/xr_input_adapter.gd"

const XRAimStabilizerScript := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_aim_stabilizer.gd")

## Shared base for controller + hand-tracking input adapters. This is the single
## source of truth for the platform-agnostic behavior: reading XRController3D aim
## poses, the XRHandTracker hand-ray + grip poses, synthesized bare-hand
## pinch-select, optional hand-select stabilization, and the select/activate state
## machine. Platform subclasses add ONLY their select source - see
## WebXRInputAdapter (browser interface events) and OpenXRInputAdapter (action-map
## button signals). Both call _resolve_rig() from their _ready.

const XRHandGestureProvider := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_gesture_provider.gd")
const XRHandTrackerResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")

## Internal source markers so a real hardware select (trigger / browser select)
## and a synthesized bare-hand pinch never fight over the same hand.
const HARDWARE_SELECT := "hardware"
const SYNTHETIC_SELECT := "synthetic"

@export_group("Rig")
@export var xr_origin_path: NodePath
@export var left_controller_path: NodePath
@export var right_controller_path: NodePath

@export_group("Ray Source")
## false: prefer the controller node's raw aim pose whenever it has tracking
## data. true: prefer the hand-modality ray from _hand_aim_pose -- which is
## the platform aim pose when the runtime publishes one (see
## prefer_platform_aim), the derived joint ray otherwise, and EITHER way runs
## through the aim stabilizer and pinch-select anchoring that were tuned on
## device. A held physical controller is unaffected by this flag: the hand
## tracker has no data then, so the hand path yields nothing and the
## controller pose drives regardless.
##
## The 2026-07-03 on-device decision set this false because the OS aim pose
## was steadier than the derived prototype ray. With prefer_platform_aim the
## hand path now sources that same OS pose, so the shipped rig flips this to
## true to get the OS pose PLUS the tuned conditioning, instead of the OS
## pose raw and unanchored. The class default stays false so existing scenes
## keep their measured behaviour until deliberately switched.
@export var prefer_hand_ray := false

@export_group("Pinch Select")
@export var synthesize_pinch_select := true
@export_range(0.001, 0.2, 0.001, "or_greater") var pinch_start_distance := 0.035
@export_range(0.001, 0.2, 0.001, "or_greater") var pinch_end_distance := 0.055

@export_group("Select Stabilization")
## Keeps a hand ray from jumping when thumb/index pinch geometry changes.
## Anchors to the last pose from a frame the hand was NOT selecting -- the
## PRE-pinch aim -- because the hand drifts while the fingers are closing, well
## before the pinch threshold trips. That anchor then translates with the palm,
## so dragging still follows the hand while the aim direction stays put.
##
## Enabled in the shipped rig as of 2026-07-25 (David reported the cursor
## moving during the pinch). Still exported so a project can turn it off.
@export var stabilize_hand_select := false
## How long the anchor holds after a select starts. It exists to absorb the
## PINCH TRANSIENT -- the drift while the fingers close -- not the whole hold:
## anchoring for the full grab freezes the aim direction, so a far-grabbed
## object cannot be turned or steered and the grab feels rigid. After this
## window the ray is live again and manoeuvring works normally.
@export_range(0.0, 1.0, 0.01) var stabilize_hand_select_sec := 0.18

@export_group("Hand Ray Smoothing")
## Adaptive (One Euro) smoothing over the derived hand-ray DIRECTION, applied
## on EVERY frame -- unlike Select Stabilization above, this is not bounded to
## the pinch transient and does not require a select to be down.
##
## Why this exists: a hand tracked in PERIPHERAL vision can report every
## liveness flag healthy (valid/tracked/confidence-gate all true, measured on
## Quest over Link) while the JOINT POSE ITSELF is noisy -- no tracking-flag
## gate can see that, because there is nothing untracked to gate on. The ray
## direction is knuckle-minus-wrist, an ~8cm baseline (see
## XRHandGestureProvider.get_hand_ray_pose), so a few mm of independent joint
## jitter becomes several degrees of angular error, which is tens of cm of
## swing at a multi-metre ray -- the geometry amplifies the noise.
##
## David has already rejected an over-stabilized aim once, on device, in this
## codebase ("their movement is more rigid, i cant manuever things" --
## stabilize_hand_select_sec above exists because of that report). This must
## not repeat it: default conservatively, and prefer raising hand_aim_beta
## over lowering hand_aim_min_cutoff if smoothing ever reads as laggy.
@export var smooth_hand_aim := true
## Cutoff in Hz at (near) zero hand speed -- how hard a STILL hand is
## smoothed. This is where the peripheral jitter lives, so it is kept low:
## lower = steadier while still, at the cost of more lag in the instant a
## still hand starts moving (the adaptive beta term below takes a few frames
## to catch up once real motion starts).
@export_range(0.05, 5.0, 0.01) var hand_aim_min_cutoff := 0.4
## How fast the cutoff rises with hand speed. This is the dial for "rigid,
## can't manoeuvre": raise it if deliberate aiming ever feels laggy, rather
## than lowering min_cutoff (which would let more peripheral jitter back in
## at rest). Measured (see docs/ray-smoothing-report.md): at the shipped
## defaults a fast ~horizontal sweep lags the raw pose by 1-2 frames (~14-28ms
## at 72Hz), while a stationary hand's jitter variance drops to roughly 3% of
## unfiltered.
@export_range(0.0, 5.0, 0.01) var hand_aim_beta := 1.2
## Cutoff for smoothing the internal speed estimate the beta term reads.
## Matches XRHandFilter's un-overridden default; rarely needs tuning.
@export_range(0.1, 5.0, 0.01) var hand_aim_d_cutoff := 1.0

## Per-hand One Euro filter over the derived aim direction. ONE instance,
## two channels (Hand.LEFT = 0, Hand.RIGHT = 1) -- not two instances, not a
## shared single channel -- so each hand seeds and adapts independently and a
## hand cannot see the other's history (XROneEuroFilter's channels are
## independent by construction; see test_hand_conditioning.gd).
var _hand_aim_direction_filter := _make_hand_aim_direction_filter()
# dt for the aim filter comes from _process's engine-provided delta, not a
# per-hand wall-clock read: get_aim_pose has no delta parameter (ray/grab
# interactors just call it whenever they update), and _process already runs
# once a frame for the select-hold-time accounting below.
var _last_process_delta := 1.0 / 72.0

## Which stabilization the derived hand ray gets. ON is XRAimStabilizer: an
## endpoint-anchored, range-scaled deadband (see that class). OFF restores the
## One Euro direction filter and every value in the "Hand Ray Smoothing" group
## above, unchanged.
##
## Both paths are kept deliberately. The One Euro values were tuned from
## repeated on-device sessions and one over-stabilized aim has already been
## rejected in-headset in this codebase; per CLAUDE.md's on-device earn-in rule
## the incumbent is the baseline to BEAT, not something to delete on the
## strength of a better-looking design. Flip this to compare the two on the
## same build, and keep whichever wins in the headset.
@export var use_aim_stabilizer := true
## Prefer the runtime's own aim pose for a TRACKED HAND over the ray derived
## from wrist->knuckle joints. The derivation turns millimetres of joint noise
## into degrees of ray angle across an ~8 cm baseline and lands differently on
## every runtime; the platform pose is the ergonomic, runtime-stabilized ray
## the mature stacks ship (Unity XRI/XR Hands read it from
## XR_EXT_hand_interaction / XR_FB_hand_tracking_aim -- see
## docs/XR_INPUT_PRACTICES.md Practice 3 in Godot_WebXR_gh). WebXR publishes it
## unconditionally (targetRaySpace); OpenXR publishes it when the runtime
## advertises XR_EXT_hand_interaction -- measured live on standalone Quest 3
## (runtime 205.206.0): platform aim present on >95% of tracked-hand samples,
## 30-48 deg mean separation from the derived ray. Runtimes without it (Quest
## Link 1.205.0) never produce the pose, so they keep today's derived ray --
## the fallback is load-bearing, not decorative.
@export var prefer_platform_aim := true
## How long the platform-aim ray survives a FULL tracking loss (the tracker
## itself reporting no data), in seconds. Measured on standalone Quest 3: when
## a hand leaves the user's view the runtime's last frames are extrapolated
## garbage -- the wrist wanders while staying inside any plausible view cone,
## the joint count collapses, then data stops -- so the FOV gate reads an
## in-cone loss, calls the hand gone, and the ray VANISHES on look-away
## (reported on device for the left hand, whose loss windows dominate 24:2).
## On inside-out tracking a VISIBLE hand never loses data, so a full loss
## while hands are the modality almost always means unobservable, not gone:
## park the ray where it was aimed and let it expire only after this grace.
## 0 restores expire-on-loss. Applies to both hands identically.
@export_range(0.0, 60.0, 0.5, "or_greater") var platform_aim_hold_sec := 10.0
## How far back the parked ray reaches when the pose stream goes bad, in
## seconds. Measured on standalone Quest 3: a dying hand's last ~0.4 s of
## PUBLISHED poses wander with the terminal extrapolation, and the
## withhold/republish dance that follows burns another ~0.3-0.5 s before the
## data finally stops -- so the park must reach back past the whole tail.
## Parking at the newest sample OLDER than this window parks where the user
## was actually aiming ("it shifts a little when I go out of view" was the
## park landing inside the wander).
@export_range(0.0, 3.0, 0.05) var platform_aim_park_backtime_sec := 1.0
## How long a gap in the pose stream is bridged with the LAST published pose
## before the display switches to the aged park pose. Short withholds are
## routine even on a well-tracked hand and must be invisible; a gap that
## outlives this window is the hand genuinely going unobservable, where the
## last pose is already the terminal wander and the aged pose is the honest
## one. There is deliberately NO hysteresis on the way back: the instant a
## pose is published again it drives the ray -- that is the entire algorithm
## of the right hand, whose behaviour is the on-device role model, and two
## machineries that tried to be smarter than it (park-on-any-withhold, and a
## continuous-health resume clock) were both rejected in the headset within
## minutes ("stuck"; "ray independent of the hand").
@export_range(0.0, 2.0, 0.05) var platform_aim_fill_sec := 0.25
## How far the last published pose may disagree with the aged history before
## a long gap parks on the HISTORY instead of the last pose. Measured on the
## left hand: an ordinary look-away gap has a near-stationary tail (~2 deg
## from the aged pose) where parking on the aged pose is a visible backward
## hop for no benefit, while the terminal-wander tail disagrees by 40-60 deg
## and NEEDS the correction. Below this angle the two agree and the last
## pose wins (zero seam); above it the history is the honest one.
@export_range(0.0, 45.0, 0.5) var platform_aim_wander_threshold_deg := 5.0
## Per-hand, two channels (Hand.LEFT = 0, Hand.RIGHT = 1), same construction as
## _hand_aim_direction_filter -- each hand adapts independently and cannot see
## the other's history.
##
## preload rather than the global class_name: a global name only resolves once
## the editor has written it into the class cache, so a NEW script referenced
## by name fails to parse in a fresh headless run (`--script`, i.e. every test
## suite). preload is what the rest of this codebase uses for the same reason.
var _aim_stabilizer = XRAimStabilizerScript.new(2)
## Latest ray endpoint per hand, set by interactors -- see set_aim_endpoint.
var _aim_endpoint_hint := {}
## Platform-aim continuity, per hand: whether the runtime has published an
## aim pose this session, and the last ray it published. Exists because a
## runtime that publishes CAN also withhold per frame when it stops trusting
## the hand -- measured on standalone Quest 3 as look-away windows, 24 of 26
## on the left hand -- and switching to the derived ray for those frames
## swings the visible line by the full platform-vs-derived separation.
var _platform_aim_seen := {}
var _held_platform_aim := {}
## Seconds since this hand's tracker last had data, accumulated in _process
## (single authority; _hand_aim_pose is called several times per frame and
## must not double-count). INF until the hand has ever been live.
var _hand_loss_elapsed := {}
## Gap-filling state, per hand, all written ONLY in _process so
## _hand_aim_pose stays a pure reader however many times a frame calls it.
## _aim_buffer is the short history of settled platform poses whose FRONT
## entry -- the newest sample older than platform_aim_park_backtime_sec --
## is the park pose for long gaps (see _bad_frame_platform_aim).
var _aim_buffer := {}
## Continuous published time; zeroed by any withheld or lost frame. Gates
## history pushes (>= _AIM_PUSH_WARMUP_SEC) so the first frames after any
## hiccup -- the loss dance's garbage republish bursts included -- never
## enter the buffer and can never become a future park pose.
var _aim_healthy_streak := {}
## Continuous NOT-published time (withheld or lost); zeroed by any published
## frame. Below platform_aim_fill_sec the display bridges with the last
## pose; at or above it, the aged park pose.
var _aim_bad_elapsed := {}
## Hand-anchor position (world) captured at the moment a gap begins, so a
## gap pose can TRANSLATE with a hand that is still tracked -- the same
## palm-anchored delta the pinch-select stabilizer uses. Without it a long
## gap on a visible hand parks the ray in space while the hand walks away
## from it ("the left ray and cursor were separate from the hand").
var _aim_gap_anchor := {}
## Palm-local aim direction captured at the same moment: the calibrated
## OFFSET between the palm frame and the platform ray. During a gap on a
## live hand the displayed direction is palm_now * this offset, so the ray
## keeps MOVING with the hand instead of freezing. Measured need: the left
## aim stream churns (11 withhold/republish cycles in 27 s of ordinary use
## against zero on the right), and a direction frozen once per churn cycle
## is a visible stutter no seam-polishing can hide.
var _aim_gap_offset_dir := {}
## The pose shown during the current gap, computed ONCE per frame in
## _process and left untouched on frames where the hand blips to not-live.
## The measured gaps contain one-frame liveness blips, and recomputing the
## translation around them popped the origin -- part of the residual
## "slight movement" the left showed on look-away.
var _aim_gap_pose := {}
var _aim_clock := 0.0

const _AIM_PUSH_WARMUP_SEC := 0.3

## Diagnostic for the platform-aim question -- see _probe_platform_aim. OFF by
## default; it costs nothing until switched on.
##
## The question is ANSWERED for standalone Quest 3 (runtime 205.206.0):
## platform=true on >95% of tracked-hand samples, 29.5/48.1 deg mean
## separation from the derived ray (right/left). Quest Link (1.205.0) remains
## a no: it does not advertise XR_EXT_hand_interaction at all. Two switches
## were both required and only one was documented anywhere: the profile bound
## in the action map AND the project setting
## xr/openxr/extensions/hand_interaction_profile, which is what makes Godot
## request the extension (openxr_hand_interaction_extension.cpp:59).
##
## Still open, which is why the probe stays: attributing the pose to the
## profile actually serving it (the first standalone run measured a live aim
## pose while the ext profile was provably skipped), and the same measurement
## under WebXR and on Android XR / Pico / SteamVR.
@export var debug_platform_aim := false
var _probe_last_key := {}
var _probe_last_separation := {}

var _origin: Node3D
var _controllers := {}
var _select_down := {
	Hand.LEFT: false,
	Hand.RIGHT: false,
}
var _select_source := {
	Hand.LEFT: "",
	Hand.RIGHT: "",
}
# Synthetic pinch re-arm state: cleared when any select starts, set once the
# fingers open past pinch_end_distance (see _update_synthetic_pinch_select).
var _synthetic_armed := {
	Hand.LEFT: true,
	Hand.RIGHT: true,
}
var _activate_down := {
	Hand.LEFT: false,
	Hand.RIGHT: false,
}
var _activate_source := {
	Hand.LEFT: "",
	Hand.RIGHT: "",
}
var _last_free_hand_pose := {
	Hand.LEFT: {},
	Hand.RIGHT: {},
}
var _last_free_hand_anchor := {
	Hand.LEFT: null,
	Hand.RIGHT: null,
}
var _select_anchor_pose := {
	Hand.LEFT: {},
	Hand.RIGHT: {},
}
var _select_anchor_hand_anchor := {
	Hand.LEFT: null,
	Hand.RIGHT: null,
}
# Time spent selecting, so stabilization can be bounded to the pinch transient.
var _select_held_time := {
	Hand.LEFT: 0.0,
	Hand.RIGHT: 0.0,
}


## Subclasses call this from their _ready() before wiring their select source.
func _resolve_rig() -> void:
	_origin = get_node_or_null(xr_origin_path) as Node3D
	_controllers[Hand.LEFT] = get_node_or_null(left_controller_path) as XRController3D
	_controllers[Hand.RIGHT] = get_node_or_null(right_controller_path) as XRController3D


func _process(_delta: float) -> void:
	_last_process_delta = _delta
	_aim_clock += _delta
	for hand_id in [Hand.LEFT, Hand.RIGHT]:
		if _select_down.get(hand_id, false):
			_select_held_time[hand_id] = _select_held_time.get(hand_id, 0.0) + _delta
		else:
			_select_held_time[hand_id] = 0.0
		_update_platform_aim_state(hand_id, _delta)
	if synthesize_pinch_select:
		_update_synthetic_pinch_select(Hand.LEFT)
		_update_synthetic_pinch_select(Hand.RIGHT)
	if debug_platform_aim:
		_probe_platform_aim(Hand.LEFT)
		_probe_platform_aim(Hand.RIGHT)


## The single writer for every piece of platform-aim state -- liveness clock,
## healthy-pose history, park capture, suspect/resume. Runs once per hand per
## frame from _process; _hand_aim_pose only READS, because interactors and
## get_source_kind call it several times a frame and any write there would
## double-count time or double-push samples.
func _update_platform_aim_state(hand_id: int, delta: float) -> void:
	var tracker := XRHandTrackerResolver.get_tracker(hand_id)
	var hand_live := tracker != null and tracker.has_tracking_data
	if hand_live:
		_hand_loss_elapsed[hand_id] = 0.0
	else:
		_hand_loss_elapsed[hand_id] = _hand_loss_elapsed.get(hand_id, INF) + delta

	if not prefer_platform_aim:
		return

	var platform := _platform_aim_pose(hand_id) if hand_live else {}
	if not platform.is_empty():
		_platform_aim_seen[hand_id] = true
		_aim_bad_elapsed[hand_id] = 0.0
		_aim_gap_pose.erase(hand_id)
		_aim_healthy_streak[hand_id] = _aim_healthy_streak.get(hand_id, 0.0) + delta
		_held_platform_aim[hand_id] = platform
		if _aim_healthy_streak[hand_id] >= _AIM_PUSH_WARMUP_SEC:
			var buffer: Array = _aim_buffer.get(hand_id, [])
			buffer.push_back({
				"t": _aim_clock,
				"origin": platform["origin"], "direction": platform["direction"],
			})
			# Keep the FRONT entry as the park candidate: the newest sample
			# already older than the backtime window.
			while buffer.size() >= 2 and _aim_clock - (buffer[1]["t"] as float) >= platform_aim_park_backtime_sec:
				buffer.pop_front()
			_aim_buffer[hand_id] = buffer
		return

	_aim_healthy_streak[hand_id] = 0.0
	if not _platform_aim_seen.get(hand_id, false):
		return
	var prev_bad: float = _aim_bad_elapsed.get(hand_id, 0.0)
	if prev_bad == 0.0:
		# First frame of a gap: remember where the hand is and the palm-local
		# aim offset, so the gap pose can keep MOVING with the hand while it
		# stays tracked. Null when the hand died outright -- then there is
		# nothing to follow and the pose parks in space, which is right for
		# an invisible hand.
		var anchor = _hand_anchor_global(hand_id)
		if anchor != null:
			_aim_gap_anchor[hand_id] = anchor
		else:
			_aim_gap_anchor.erase(hand_id)
		_aim_gap_offset_dir.erase(hand_id)
		var palm = _hand_anchor_basis_global(hand_id)
		var held: Dictionary = _held_platform_aim.get(hand_id, {})
		if palm != null and not held.is_empty():
			_aim_gap_offset_dir[hand_id] = ((palm as Basis).transposed() * (held["direction"] as Vector3)).normalized()
	_aim_bad_elapsed[hand_id] = prev_bad + delta
	if hand_live and prev_bad < platform_aim_fill_sec \
			and _aim_bad_elapsed[hand_id] >= platform_aim_fill_sec:
		# The gap outlived the fill window. If the tail the offset was
		# calibrated from disagrees with the aged history, the tail was the
		# terminal wander -- recalibrate the offset to the history once, the
		# honest correction. A stable tail stays calibrated to itself.
		var buffer: Array = _aim_buffer.get(hand_id, [])
		var held: Dictionary = _held_platform_aim.get(hand_id, {})
		if not buffer.is_empty() and not held.is_empty():
			var aged_dir: Vector3 = (buffer[0] as Dictionary)["direction"]
			if rad_to_deg((held["direction"] as Vector3).angle_to(aged_dir)) > platform_aim_wander_threshold_deg:
				var palm = _hand_anchor_basis_global(hand_id)
				if palm != null:
					_aim_gap_offset_dir[hand_id] = ((palm as Basis).transposed() * aged_dir).normalized()
	if hand_live or not _aim_gap_pose.has(hand_id):
		# Recompute the gap display only while the hand is live (or on the
		# gap's very first frame): a not-live blip must NOT move the pose
		# for a frame -- it simply stays where it last was.
		var gap_pose := _live_gap_aim(hand_id) if hand_live else {}
		if gap_pose.is_empty():
			gap_pose = _bad_frame_platform_aim(hand_id)
			if hand_live and not gap_pose.is_empty():
				var gap_anchor = _aim_gap_anchor.get(hand_id)
				var current_anchor = _hand_anchor_global(hand_id)
				if gap_anchor != null and current_anchor != null:
					gap_pose = _offset_pose_by_anchor_delta(gap_pose, gap_anchor, current_anchor)
		if not gap_pose.is_empty():
			_aim_gap_pose[hand_id] = gap_pose
	if _hand_loss_elapsed.get(hand_id, INF) > platform_aim_hold_sec:
		# Lost for longer than the ray is allowed to survive: this aiming
		# episode is over. Clearing everything makes the eventual
		# reacquisition a clean slate -- live pose immediately, no stale park.
		_platform_aim_seen.erase(hand_id)
		_held_platform_aim.erase(hand_id)
		_aim_healthy_streak.erase(hand_id)
		_aim_bad_elapsed.erase(hand_id)
		_aim_gap_anchor.erase(hand_id)
		_aim_gap_offset_dir.erase(hand_id)
		_aim_gap_pose.erase(hand_id)
		_aim_buffer.erase(hand_id)


## What the ray shows on a frame with NO published pose, given how long the
## stream has been bad: the last pose while the gap is short (invisible
## bridging), the aged pre-wander pose once it is not (the honest park).
## Empty when nothing was ever published.
## The gap display for a hand that is STILL TRACKED: the palm frame drives
## the ray with the offset calibrated at gap start (or recalibrated to the
## aged history at the fill boundary if the tail was wander). Continuity at
## gap entry is exact by construction, the ray keeps moving with the hand
## through the gap -- the measured left-hand churn (a gap every ~2 s in
## ordinary use) makes any frozen-direction gap display a visible stutter.
## Empty when the palm or the offset is unavailable; callers then fall back
## to the static _bad_frame_platform_aim.
func _live_gap_aim(hand_id: int) -> Dictionary:
	var offset = _aim_gap_offset_dir.get(hand_id)
	var held: Dictionary = _held_platform_aim.get(hand_id, {})
	if offset == null or held.is_empty():
		return {}
	var palm = _hand_anchor_basis_global(hand_id)
	if palm == null:
		return {}
	var origin: Vector3 = held["origin"]
	var gap_anchor = _aim_gap_anchor.get(hand_id)
	var current_anchor = _hand_anchor_global(hand_id)
	if gap_anchor != null and current_anchor != null:
		origin += (current_anchor as Vector3) - (gap_anchor as Vector3)
	return {
		"origin": origin,
		"direction": ((palm as Basis) * (offset as Vector3)).normalized(),
	}


func _bad_frame_platform_aim(hand_id: int) -> Dictionary:
	var held: Dictionary = _held_platform_aim.get(hand_id, {})
	if _aim_bad_elapsed.get(hand_id, 0.0) < platform_aim_fill_sec:
		return held
	var buffer: Array = _aim_buffer.get(hand_id, [])
	if buffer.is_empty():
		return held
	var entry: Dictionary = buffer[0]
	if not held.is_empty():
		var disagreement := rad_to_deg((held["direction"] as Vector3).angle_to(entry["direction"] as Vector3))
		if disagreement <= platform_aim_wander_threshold_deg:
			# The tail agrees with the history: nothing wandered, and
			# switching to the aged pose would be a visible backward hop for
			# no benefit -- the residual "slight movement" on look-away.
			return held
		# Genuine wander: direction from before it; origin from the gap
		# start so the anchor delta can glue the ray to a tracked hand.
		return {
			"origin": held.get("origin", entry["origin"]),
			"direction": entry["direction"],
		}
	return {"origin": entry["origin"], "direction": entry["direction"]}


## TEMPORARY measurement, to be deleted once the platform-aim question is
## settled. Answers two things nothing else can: whether the runtime publishes
## an aim pose for a TRACKED HAND at all (on OpenXR that requires the
## hand-interaction profile to be bound AND advertised by the runtime; over
## Link that is unverified), and whether that pose differs materially from the
## wrist-to-knuckle direction we derive today. Logs raw -- NOT the smoothed
## direction -- because the comparison is about the source, not the filter.
func _probe_platform_aim(hand_id: int) -> void:
	if not _valid_hand(hand_id) or _origin == null:
		return

	var tracker := XRHandTrackerResolver.get_tracker(hand_id)
	var hand_live := tracker != null and tracker.has_tracking_data

	var controller := _controllers.get(hand_id) as XRController3D
	var has_platform := controller != null and controller.get_is_active() \
			and controller.get_has_tracking_data()
	var pose_name := controller.pose if controller != null else "<no controller>"

	# WHICH profile is feeding the pose matters as much as whether one is: on
	# standalone Quest the first probe run measured platform=true while the
	# ext hand-interaction profile was provably skipped (extension advertised
	# but not enabled -- Godot gates it on the hand_interaction_profile
	# project setting), so the pose had to be coming from somewhere else.
	var profile := "<none>"
	if controller != null:
		var positional := XRServer.get_tracker(controller.tracker) as XRPositionalTracker
		if positional != null and not String(positional.profile).is_empty():
			profile = String(positional.profile)

	var platform_dir := Vector3.ZERO
	if has_platform:
		platform_dir = (-controller.global_transform.basis.z).normalized()

	var derived_dir := Vector3.ZERO
	var local_pose := XRHandGestureProvider.get_hand_ray_pose(tracker)
	if not local_pose.is_empty():
		derived_dir = (_origin.global_transform.basis * (local_pose["direction"] as Vector3)).normalized()

	var separation := -1.0
	if platform_dir != Vector3.ZERO and derived_dir != Vector3.ZERO:
		separation = rad_to_deg(platform_dir.angle_to(derived_dir))

	# Change-gated so this cannot repeat the 91k-line eye-height flood. Emits on
	# a state change or a meaningful shift in either direction.
	var key := "%d|%s|%s|%s|%s" % [hand_id, hand_live, has_platform, pose_name, profile]
	var moved := separation >= 0.0 and absf(separation - _probe_last_separation.get(hand_id, -999.0)) >= 2.0
	if key == _probe_last_key.get(hand_id, "") and not moved:
		return
	_probe_last_key[hand_id] = key
	_probe_last_separation[hand_id] = separation

	print("[aim-probe] hand=%d hand_live=%s platform=%s pose=%s profile=%s platform_dir=%s derived_dir=%s sep_deg=%.1f" % [
		hand_id, hand_live, has_platform, pose_name, profile,
		platform_dir.snappedf(0.001), derived_dir.snappedf(0.001), separation,
	])


## Field-initializer helper for _hand_aim_direction_filter (GDScript field
## defaults run before _ready, so this cannot depend on _resolve_rig having
## run -- tests new the adapter directly without a scene tree, same as
## resolve_grip_anchor's callers do).
static func _make_hand_aim_direction_filter() -> XROneEuroFilter:
	var filter := XROneEuroFilter.new()
	filter.resize(2)  # Hand.LEFT, Hand.RIGHT
	return filter


func get_aim_pose(hand_id: int) -> Dictionary:
	if not _valid_hand(hand_id):
		return {}

	var hand_pose := _hand_aim_pose(hand_id)
	if not hand_pose.is_empty():
		hand_pose = _stabilized_hand_pose(hand_id, hand_pose)

	if prefer_hand_ray:
		return hand_pose if not hand_pose.is_empty() else _controller_aim_pose(hand_id)

	var controller_pose := _controller_aim_pose(hand_id)
	return controller_pose if not controller_pose.is_empty() else hand_pose


func get_grip_pose(hand_id: int) -> Dictionary:
	if not _valid_hand(hand_id):
		return {}

	var hand_pose := _hand_grip_pose(hand_id)
	return hand_pose if not hand_pose.is_empty() else _controller_aim_pose(hand_id)


func is_select_down(hand_id: int) -> bool:
	return _valid_hand(hand_id) and _select_down.get(hand_id, false)


func get_source_kind(hand_id: int) -> int:
	if not _valid_hand(hand_id):
		return SourceKind.NONE

	var hand_tracked := not _hand_aim_pose(hand_id).is_empty()
	var controller_tracked := not _controller_aim_pose(hand_id).is_empty()
	if prefer_hand_ray and hand_tracked:
		return SourceKind.HAND
	if controller_tracked:
		return SourceKind.CONTROLLER
	if hand_tracked:
		return SourceKind.HAND
	return SourceKind.NONE


func _controller_aim_pose(hand_id: int) -> Dictionary:
	if not _valid_hand(hand_id):
		return {}

	var controller := _controllers.get(hand_id) as XRController3D
	if controller == null or not controller.get_is_active() or not controller.get_has_tracking_data():
		return {}

	var xf := controller.global_transform
	return {
		"origin": xf.origin,
		"direction": (-xf.basis.z).normalized(),
		"basis": xf.basis.orthonormalized(),
	}


## The aim pose the RUNTIME published for this hand, world space, or {} when
## there is none this frame. Reads the same XRController3D node as the
## controller path because that is where Godot surfaces it: the rig binds the
## node to the left_hand/right_hand tracker with pose="aim", which the
## hand-interaction profile (OpenXR) or targetRaySpace (WebXR) populates for
## tracked hands. Callers gate on hand liveness -- see _hand_aim_pose.
## Overridable seam so tests can inject a platform pose headless.
func _platform_aim_pose(hand_id: int) -> Dictionary:
	return _controller_aim_pose(hand_id)


func _hand_aim_pose(hand_id: int) -> Dictionary:
	if not _valid_hand(hand_id) or _origin == null:
		return {}

	var tracker := XRHandTrackerResolver.get_tracker(hand_id)
	var ray_origin := Vector3.ZERO
	var direction := Vector3.ZERO

	# Platform first, derived fallback (XR_INPUT_PRACTICES.md Practice 3). The
	# hand-liveness gate is what keeps this a HAND pose: the same controller
	# node carries the aim pose of a physically held controller, and without
	# the gate a held controller would masquerade as a tracked hand here.
	# The right hand is the on-device role model and this IS its algorithm:
	# a published pose drives the ray the instant it exists, memory only
	# fills the gaps. Anything cleverer has been tried and rejected in the
	# headset -- and falling back to the derived ray during a gap swings the
	# line by the measured 40-52 deg platform-vs-derived separation.
	var hand_live := tracker != null and tracker.has_tracking_data
	if prefer_platform_aim:
		var platform := _platform_aim_pose(hand_id) if hand_live else {}
		if not platform.is_empty():
			ray_origin = platform["origin"]
			direction = platform["direction"]
		elif _platform_aim_seen.get(hand_id, false) \
				and (hand_live or _hand_loss_elapsed.get(hand_id, INF) <= platform_aim_hold_sec):
			# _process computed this frame's gap display (translated with the
			# tracked palm, sticky across liveness blips); the fallback only
			# covers a read arriving before _process on the gap's first frame.
			var gap_pose: Dictionary = _aim_gap_pose.get(hand_id, _bad_frame_platform_aim(hand_id))
			if not gap_pose.is_empty():
				ray_origin = gap_pose["origin"]
				direction = gap_pose["direction"]

	if direction == Vector3.ZERO:
		var local_pose := XRHandGestureProvider.get_hand_ray_pose(tracker)
		if local_pose.is_empty():
			# Dropped. Clear history so reacquisition SNAPS to the recovered
			# pose instead of slewing across the gap from where the hand used
			# to be -- the same reason XRHandConfidenceGate raises a
			# discontinuity.
			_aim_stabilizer.reset(hand_id)
			return {}
		var origin_xf := _origin.global_transform
		direction = (origin_xf.basis * (local_pose["direction"] as Vector3)).normalized()
		ray_origin = origin_xf * (local_pose["origin"] as Vector3)

	# Settled BEFORE the basis is built, so every ray consumer (hover, select,
	# _stabilized_hand_pose downstream) inherits the settled direction rather
	# than each needing its own pass over the raw one.
	if use_aim_stabilizer:
		var settled: Dictionary = _aim_stabilizer.stabilize(
				hand_id, ray_origin, direction,
				_aim_endpoint_hint.get(hand_id), _last_process_delta)
		ray_origin = settled["origin"]
		direction = settled["direction"]
	else:
		direction = _smoothed_hand_aim_direction(hand_id, direction)

	return {
		"origin": ray_origin,
		"direction": direction,
		"basis": XRHandGestureProvider.basis_from_forward(direction),
	}


## Where this hand's ray currently terminates, in world space -- the hit point
## or cursor. Lets the stabilizer scale its angular budget by how far the ray
## actually reaches and cancel jitter at the END of the ray rather than at the
## hand. Interactors call this each frame; passing null (or never calling it)
## falls back to a nominal range, which still stabilizes, just less precisely.
func set_aim_endpoint(hand_id: int, endpoint) -> void:
	if _valid_hand(hand_id):
		_aim_endpoint_hint[hand_id] = endpoint


## Adaptive smoothing on the derived hand-ray direction -- see the "Hand Ray
## Smoothing" export group above for why this exists and the constraint it
## must respect. `dt` is exposed as a parameter (rather than read internally
## from a clock) specifically so this is unit-testable headless with
## controlled, deterministic timing -- see test_hand_conditioning.gd.
func _smoothed_hand_aim_direction(hand_id: int, direction: Vector3, dt: float = _last_process_delta) -> Vector3:
	if not smooth_hand_aim or not _valid_hand(hand_id):
		return direction

	_hand_aim_direction_filter.min_cutoff = hand_aim_min_cutoff
	_hand_aim_direction_filter.beta = hand_aim_beta
	_hand_aim_direction_filter.d_cutoff = hand_aim_d_cutoff
	# hand_id IS the channel: Hand.LEFT = 0, Hand.RIGHT = 1 (see Hand enum in
	# xr_input_adapter.gd), so this can never accidentally alias both hands
	# onto the same channel.
	return _hand_aim_direction_filter.filter(hand_id, direction, dt)


## Palm-first, wrist-fallback grip joint selection, in TRACKER-LOCAL space
## (no XROrigin transform applied - callers world-transform the result
## themselves). Static so it is testable headless without a live rig; see
## tests/test_grab_feel.gd.
static func resolve_grip_anchor(tracker: XRHandTracker) -> Transform3D:
	if tracker == null:
		return Transform3D.IDENTITY
	var joint := XRHandTracker.HAND_JOINT_PALM
	if not XRHandGestureProvider.joint_position_valid(tracker, joint):
		joint = XRHandTracker.HAND_JOINT_WRIST
		# Both current callers gate on tracking first, but this is a public
		# static: with neither joint valid, hand back identity rather than
		# whatever stale transform the tracker still holds.
		if not XRHandGestureProvider.joint_position_valid(tracker, joint):
			return Transform3D.IDENTITY
	return tracker.get_hand_joint_transform(joint)


func _hand_grip_pose(hand_id: int) -> Dictionary:
	if not _valid_hand(hand_id) or _origin == null:
		return {}

	var tracker := XRHandTrackerResolver.get_tracker(hand_id)
	if tracker == null:
		return {}

	if not XRHandGestureProvider.joint_position_valid(tracker, XRHandTracker.HAND_JOINT_PALM) \
			and not XRHandGestureProvider.joint_position_valid(tracker, XRHandTracker.HAND_JOINT_WRIST):
		return {}

	var grip_transform := _origin.global_transform * resolve_grip_anchor(tracker)
	var origin: Vector3 = grip_transform.origin

	# Godot re-bases joint ORIENTATIONS into a humanoid convention (a held
	# object's grab point ends up aimed at the fingers/knuckles, not settled in
	# the fist). Joint POSITIONS are reliable, so build a controller-style grip
	# basis from them instead: -Z = pointing (wrist -> index knuckle), +Y = out
	# of the fist (palm normal). This matches the controller grip convention, so
	# grab points behave the same on hands and controllers.
	# Use the METACARPALS (palm bones) for direction, not the finger knuckles -
	# knuckles curl when you pinch, which would twist the grip by pose. Palm bones
	# hold still, so the held orientation matches the (open-hand) editor preview.
	var wrist := XRHandTracker.HAND_JOINT_WRIST
	var index := XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL
	var pinky := XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL
	if XRHandGestureProvider.joint_position_valid(tracker, wrist) \
			and XRHandGestureProvider.joint_position_valid(tracker, index) \
			and XRHandGestureProvider.joint_position_valid(tracker, pinky):
		var o := _origin.global_transform
		var wrist_p: Vector3 = (o * tracker.get_hand_joint_transform(wrist)).origin
		var index_p: Vector3 = (o * tracker.get_hand_joint_transform(index)).origin
		var pinky_p: Vector3 = (o * tracker.get_hand_joint_transform(pinky)).origin
		# ANCHOR HISTORY (origin only - the basis math below is unaffected either
		# way, it never read the midpoint):
		# - 2026-07-19 (15d3783, v1.43.0): origin moved OFF the tracker's PALM
		#   joint onto the wrist<->middle-metacarpal midpoint, to match the
		#   editor Preview Hand / pose-math convention (raw PALM sat elsewhere).
		# - 2026-07-24 (David, grab-feel design + on-device feel-check): that
		#   midpoint is what made grabbed objects read as pulled to the wrist -
		#   grip anchor is back on resolve_grip_anchor()'s PALM-first result
		#   (computed above into `origin`); this block no longer overrides it.
		#   Deliberate reversal, not a drive-by: authored grips (blaster/pen/
		#   spray) may shift as a result and are re-verified on-device in the
		#   grab-feel plan's Task 6 earn-in gate before this ships.
		var forward := index_p - wrist_p
		var across := pinky_p - index_p
		if forward.length_squared() > 0.000001 and across.length_squared() > 0.000001:
			forward = forward.normalized()
			var up := forward.cross(across.normalized()).normalized()
			if tracker.hand == XRPositionalTracker.TRACKER_HAND_LEFT:
				up = -up
			if up.length_squared() > 0.000001:
				var basis := Basis(up.cross(-forward).normalized(), up, -forward).orthonormalized()
				return {"origin": origin, "basis": basis}

	return {
		"origin": origin,
		"basis": grip_transform.basis.orthonormalized(),
	}


func _stabilized_hand_pose(hand_id: int, raw_pose: Dictionary) -> Dictionary:
	if not stabilize_hand_select:
		# The remembered pose/anchor are only ever read when stabilization is
		# on - skip the per-frame dict duplicate + extra tracker resolve.
		return raw_pose

	if not _select_down.get(hand_id, false):
		_remember_free_hand_pose(hand_id, raw_pose)
		return raw_pose

	# Bounded to the pinch transient. Holding the anchor for the whole grab
	# froze the aim direction, so a far-held object could not be steered --
	# David, on device: "their movement is more rigid, i cant manuever things".
	var held_time: float = _select_held_time.get(hand_id, 0.0)
	if stabilize_hand_select_sec > 0.0 and held_time > stabilize_hand_select_sec:
		return raw_pose

	var anchor_pose: Dictionary = _select_anchor_pose.get(hand_id, {})
	if anchor_pose.is_empty():
		_begin_select_stabilization(hand_id, raw_pose)
		anchor_pose = _select_anchor_pose.get(hand_id, {})
	if anchor_pose.is_empty():
		return raw_pose

	var start_anchor = _select_anchor_hand_anchor.get(hand_id)
	var current_anchor = _hand_anchor_global(hand_id)
	if start_anchor == null or current_anchor == null:
		return anchor_pose
	return _offset_pose_by_anchor_delta(anchor_pose, start_anchor, current_anchor)


func _remember_free_hand_pose(hand_id: int, pose: Dictionary) -> void:
	_last_free_hand_pose[hand_id] = pose.duplicate()
	_last_free_hand_anchor[hand_id] = _hand_anchor_global(hand_id)


func _begin_select_stabilization(hand_id: int, fallback_pose := {}) -> void:
	if not stabilize_hand_select or not _valid_hand(hand_id):
		return

	var pose: Dictionary = _last_free_hand_pose.get(hand_id, {})
	if pose.is_empty() and not fallback_pose.is_empty():
		pose = fallback_pose
	if pose.is_empty():
		pose = _hand_aim_pose(hand_id)

	_select_anchor_pose[hand_id] = pose.duplicate() if not pose.is_empty() else {}
	var anchor = _last_free_hand_anchor.get(hand_id)
	_select_anchor_hand_anchor[hand_id] = anchor if anchor != null else _hand_anchor_global(hand_id)


func _end_select_stabilization(hand_id: int) -> void:
	if not _valid_hand(hand_id):
		return
	_select_anchor_pose[hand_id] = {}
	_select_anchor_hand_anchor[hand_id] = null


func _hand_anchor_global(hand_id: int):
	if not _valid_hand(hand_id) or _origin == null:
		return null

	var tracker := XRHandTrackerResolver.get_tracker(hand_id)
	if tracker == null:
		return null

	if not XRHandGestureProvider.joint_position_valid(tracker, XRHandTracker.HAND_JOINT_PALM) \
			and not XRHandGestureProvider.joint_position_valid(tracker, XRHandTracker.HAND_JOINT_WRIST):
		return null

	return _origin.global_transform * resolve_grip_anchor(tracker).origin


## World-space palm (wrist-fallback) orientation, or null on the same
## conditions _hand_anchor_global returns null. The rotation companion to
## that positional anchor, used to drive the gap ray's direction.
func _hand_anchor_basis_global(hand_id: int):
	if not _valid_hand(hand_id) or _origin == null:
		return null

	var tracker := XRHandTrackerResolver.get_tracker(hand_id)
	if tracker == null:
		return null

	if not XRHandGestureProvider.joint_position_valid(tracker, XRHandTracker.HAND_JOINT_PALM) \
			and not XRHandGestureProvider.joint_position_valid(tracker, XRHandTracker.HAND_JOINT_WRIST):
		return null

	return (_origin.global_transform.basis * resolve_grip_anchor(tracker).basis).orthonormalized()


func _offset_pose_by_anchor_delta(pose: Dictionary, start_anchor: Vector3, current_anchor: Vector3) -> Dictionary:
	var translated_pose := pose.duplicate()
	translated_pose["origin"] = (pose["origin"] as Vector3) + (current_anchor - start_anchor)
	return translated_pose


func _valid_hand(hand_id: int) -> bool:
	return hand_id == Hand.LEFT or hand_id == Hand.RIGHT


func _update_synthetic_pinch_select(hand_id: int) -> void:
	if not _valid_hand(hand_id):
		return
	if _select_source.get(hand_id, "") == HARDWARE_SELECT:
		return

	var distance := _pinch_distance(hand_id)
	if distance < 0.0:
		if _select_source.get(hand_id, "") == SYNTHETIC_SELECT:
			_emit_select_ended(hand_id, SYNTHETIC_SELECT)
		_synthetic_armed[hand_id] = true
		return

	# Re-arm hysteresis: after ANY select ends, the synthetic detector must not
	# start again until the fingers have physically OPENED past the end
	# threshold. Without it, a select that ends while the fingers are still
	# closed (the browser's recognizer releases early - tap-proven at 3.2cm on
	# Galaxy) re-presses instantly = a second click from one pinch.
	if distance >= pinch_end_distance:
		_synthetic_armed[hand_id] = true

	if not _select_down.get(hand_id, false) and distance <= pinch_start_distance and _synthetic_armed.get(hand_id, true):
		_emit_select_started(hand_id, SYNTHETIC_SELECT)
	elif _select_source.get(hand_id, "") == SYNTHETIC_SELECT and distance >= pinch_end_distance:
		_emit_select_ended(hand_id, SYNTHETIC_SELECT)


func _pinch_distance(hand_id: int) -> float:
	if not _valid_hand(hand_id):
		return -1.0

	var tracker := XRHandTrackerResolver.get_tracker(hand_id)
	if tracker == null:
		return -1.0

	var index_tip := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
	var thumb_tip := XRHandTracker.HAND_JOINT_THUMB_TIP
	if not XRHandGestureProvider.joint_position_valid(tracker, index_tip):
		return -1.0
	if not XRHandGestureProvider.joint_position_valid(tracker, thumb_tip):
		return -1.0

	var index_position := tracker.get_hand_joint_transform(index_tip).origin
	var thumb_position := tracker.get_hand_joint_transform(thumb_tip).origin
	return index_position.distance_to(thumb_position)


func _emit_select_started(hand_id: int, source: String) -> void:
	if not _valid_hand(hand_id) or _select_down.get(hand_id, false):
		return
	_begin_select_stabilization(hand_id)
	_select_down[hand_id] = true
	_select_source[hand_id] = source
	# Any select (either source) disarms the synthetic detector until the
	# fingers reopen - one pinch can never produce a second synthetic press.
	_synthetic_armed[hand_id] = false
	select_started.emit(hand_id)


func _emit_select_ended(hand_id: int, source: String) -> void:
	if not _valid_hand(hand_id) or not _select_down.get(hand_id, false):
		return
	# A select only ends from the source that started it (same rule as activate).
	# The old one-way guard let the browser's EARLY selectend (its pinch
	# recognizer releases while the fingers are still closed) kill our synthetic
	# select mid-pinch - the synthetic detector then instantly re-pressed, giving
	# TWO full clicks per pinch (tap-proven: every pinch double-toggled UI).
	if source != _select_source.get(hand_id, ""):
		return
	_select_down[hand_id] = false
	_select_source[hand_id] = ""
	_end_select_stabilization(hand_id)
	select_ended.emit(hand_id)


func _broadcast_select_started(source: String) -> void:
	_emit_select_started(Hand.LEFT, source)
	_emit_select_started(Hand.RIGHT, source)


func _broadcast_select_ended(source: String) -> void:
	_emit_select_ended(Hand.LEFT, source)
	_emit_select_ended(Hand.RIGHT, source)


func _emit_activate_started(hand_id: int, source: String) -> void:
	if not _valid_hand(hand_id) or _activate_down.get(hand_id, false):
		return
	_activate_down[hand_id] = true
	_activate_source[hand_id] = source
	activate_started.emit(hand_id)


func _emit_activate_ended(hand_id: int, source: String) -> void:
	if not _valid_hand(hand_id) or not _activate_down.get(hand_id, false):
		return
	if source != _activate_source.get(hand_id, ""):
		return
	_activate_down[hand_id] = false
	_activate_source[hand_id] = ""
	activate_ended.emit(hand_id)


func _broadcast_activate_started(source: String) -> void:
	_emit_activate_started(Hand.LEFT, source)
	_emit_activate_started(Hand.RIGHT, source)


func _broadcast_activate_ended(source: String) -> void:
	_emit_activate_ended(Hand.LEFT, source)
	_emit_activate_ended(Hand.RIGHT, source)
