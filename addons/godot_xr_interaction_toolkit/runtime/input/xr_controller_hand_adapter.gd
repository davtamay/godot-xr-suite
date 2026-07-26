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
## false: prefer the controller aim ray. true: prefer the hand-joint ray.
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

## Diagnostic for the platform-aim question -- see _probe_platform_aim. OFF by
## default; it costs nothing until switched on.
##
## The question is only half answered. Measured over Quest Link (Oculus runtime
## 1.205.0): platform=false on every sample including while hand_live=true, and
## the boot log never mentions the profile, because Godot registers
## /interaction_profiles/ext/hand_interaction_ext only when the runtime
## advertises XR_EXT_hand_interaction and that runtime does not. So the binding
## is inert over Link and the derived ray is still what ships there. Turn this
## back on when running STANDALONE, or on Android XR / Pico / SteamVR, to find
## out whether the profile activates and whether the runtime's aim differs from
## ours. That is the measurement this exists for; do not delete it until it has
## been taken on a runtime that advertises the extension.
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
	for hand_id in [Hand.LEFT, Hand.RIGHT]:
		if _select_down.get(hand_id, false):
			_select_held_time[hand_id] = _select_held_time.get(hand_id, 0.0) + _delta
		else:
			_select_held_time[hand_id] = 0.0
	if synthesize_pinch_select:
		_update_synthetic_pinch_select(Hand.LEFT)
		_update_synthetic_pinch_select(Hand.RIGHT)
	if debug_platform_aim:
		_probe_platform_aim(Hand.LEFT)
		_probe_platform_aim(Hand.RIGHT)


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
	var key := "%d|%s|%s|%s" % [hand_id, hand_live, has_platform, pose_name]
	var moved := separation >= 0.0 and absf(separation - _probe_last_separation.get(hand_id, -999.0)) >= 2.0
	if key == _probe_last_key.get(hand_id, "") and not moved:
		return
	_probe_last_key[hand_id] = key
	_probe_last_separation[hand_id] = separation

	print("[aim-probe] hand=%d hand_live=%s platform=%s pose=%s platform_dir=%s derived_dir=%s sep_deg=%.1f" % [
		hand_id, hand_live, has_platform, pose_name,
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


func _hand_aim_pose(hand_id: int) -> Dictionary:
	if not _valid_hand(hand_id) or _origin == null:
		return {}

	var tracker := XRHandTrackerResolver.get_tracker(hand_id)
	var local_pose := XRHandGestureProvider.get_hand_ray_pose(tracker)
	if local_pose.is_empty():
		# Dropped. Clear history so reacquisition SNAPS to the recovered pose
		# instead of slewing across the gap from where the hand used to be --
		# the same reason XRHandConfidenceGate raises a discontinuity.
		_aim_stabilizer.reset(hand_id)
		return {}

	var origin_xf := _origin.global_transform
	var direction := (origin_xf.basis * (local_pose["direction"] as Vector3)).normalized()
	var ray_origin: Vector3 = origin_xf * (local_pose["origin"] as Vector3)

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
