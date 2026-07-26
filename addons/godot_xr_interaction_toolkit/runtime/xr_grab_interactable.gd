@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg")
class_name XRGrabInteractable
extends "res://addons/godot_xr_interaction_toolkit/runtime/xr_base_interactable.gd"

## Interactable that follows its selecting interactor's attach pose.
## Movement modes: INSTANT (set transform), KINEMATIC_SMOOTH (exponential
## lerp), VELOCITY_TRACKED (drive RigidBody3D.linear_velocity; falls back to
## INSTANT for non-rigid targets).

enum MovementType { INSTANT, KINEMATIC_SMOOTH, VELOCITY_TRACKED }
## How a BARE HAND grabs this: PINCH (thumb+index, the default) or GRIP (curl
## middle/ring/pinky, leaving the index free for a trigger - the way you hold a
## gun or drill). GRIP is honored only on bare hands; controllers always use the
## grip button. Far-ray grabbing is unaffected either way.
enum HandGrab { PINCH, GRIP }

## Grab-specific lifecycle on top of the base select_entered/select_exited
## (which fire per interactor): grabbed = the object went free -> held,
## released = held -> free, thrown = release applied throw velocities.
signal grabbed(interactor)
signal released(interactor)
signal thrown(linear_velocity: Vector3, angular_velocity: Vector3)
## Analog USE strength, 0..1, while held. Separate from grabbing and from the
## binary activated/deactivated pair: a prop reads this to vary what it does
## (spray rate, trigger pull) without caring what is holding it. Emitted only
## when the value actually changes.
signal use_changed(value: float)

@export_group("Target")
## Node3D to move. Empty = this node.
@export var target_path: NodePath

@export_group("Grab")
## What a FAR (ray) grab does with this object. Near/direct grab is unaffected.
## ATTRACT: comes to your hand and stays - the common "I want that thing".
## FIXED: holds the distance it was grabbed at and follows your aim.
## REEL: hand motion along the ray winds it in and out.
## TWIST: wrist roll away from the roll captured at grab maps ABSOLUTELY to a
## distance OFFSET from the distance held at that moment - roll one way to pull
## in, the other to push out, and rolling back to neutral retraces to that
## engagement distance. Needs a bare hand and an XRPinchTwistDistanceDriver
## parented inside this interactable (godot_xr_hands required). Held by a
## controller (no wrist joint) it simply holds its distance, like FIXED. See
## docs/far-grab-modes-design.md, "Phase 2: TWIST" and its "TWIST correction:
## absolute, not a throttle" amendment.
enum FarGrabMode { ATTRACT, FIXED, REEL, TWIST }
@export var far_grab_mode := FarGrabMode.ATTRACT

## Metres of PERCEIVED distance per second for an ATTRACT far-grab's transit
## specifically -- separate from transit_speed (Movement, below) because that
## value is shared with near-grab feel already earned in on device, and moving
## it would drag settled behaviour along with it. Default picked from the
## complaint, not from feel: David, on device, "as far as fast, anything
## appealing to the eye, it is too snappy, maybe thats something to expose an
## authoring field". transit_speed (1.5 m/s) gives a 3 m attract ~2 s, which is
## the reported problem, not a fix; Meta's distance grab lands nearer 0.5 s.
## 3.0 m / 0.5 s = 6.0 m/s.
@export_range(0.1, 20.0, 0.1, "or_greater") var far_grab_attract_speed := 6.0

## Metres a FREE ATTRACT far-grab's destination sits forward of the grip pose
## (along the GRIP's own forward axis, not the ray -- rotating the wrist after
## the grab rotates the standoff with it). Landing exactly ON the grip
## overcorrected: object and hand occupy the same space and it reads badly on
## device. David: "with attach i guess we can leave an offset, i see how
## overlaping hand completely can be a problem, maybe we just give it the
## offset like before or closer?". The OLD behaviour (parking at
## min_grab_distance, 0.25 m) was too far AND sat exactly on the ray-hide
## boundary below, so the cursor stayed visible; this is the middle ground.
## Ignored for an object with an authored grab point -- that placement is
## deliberate and a standoff would fight it (see _movement_target_pose_for).
##
## CONSTRAINT, ENCODED (not just respected once): this must stay strictly
## LESS than XRRayInteractor.hide_ray_when_held_within (default 0.25 m, see
## its doc comment there), which hides the far ray by comparing the held
## object's position against this SAME adapter grip origin. A standoff at or
## past that threshold means a held object still draws a ray at you -- the
## exact symptom that started this thread (f9a2230's "grip_latched", which
## turned out to be dead code once this was traced back far enough).
## test_far_grab_modes.gd asserts this relationship directly so a future
## tuning pass on either number cannot silently reintroduce it.
##
## Default 0.12 m: roughly half of hide_ray_when_held_within's 0.25 m, so
## there is real headroom rather than a hair's-width margin, and in the
## neighbourhood of where a held object naturally sits forward of an open
## palm (a closed fist's grip point is a few centimetres in front of the
## wrist; 0.12 m clears the palm without floating the object visibly off the
## hand). Picked from geometry, not feel -- earn-in owed on device.
@export_range(0.0, 0.5, 0.01) var far_grab_attract_standoff := 0.12

## Bare-hand grab gesture: PINCH (default) or GRIP (curl the lower fingers, index
## free). See HandGrab. A gun/blaster uses GRIP so the index can pull a trigger.
@export var hand_grab_style: HandGrab = HandGrab.PINCH

## Grabbing a held object with the OTHER hand takes it over, instead of the
## second hand being refused and the object staying stuck to the first. This is
## the single-hand counterpart to two-hand grabbing, and it is what passing an
## object between your hands is expected to do. Ignored when
## two_hand_grab_enabled is on -- there the second hand JOINS rather than taking
## over.
@export var allow_grab_swap := true

## Whether a bare hand grabs this by gripping the lower fingers instead of
## pinching. Queried by the direct interactor.
func uses_grip_grab() -> bool:
	return hand_grab_style == HandGrab.GRIP

@export_group("Attach")
## Optional grip-point child. Only used when snap_to_attach is true.
@export var attach_transform_path: NodePath
## true: the attach point snaps onto the interactor's attach pose (XRITK-style
## grip). false (default): the object keeps its pose relative to the ray point.
@export var snap_to_attach := false

@export_group("Movement")
@export var movement_type := MovementType.INSTANT
@export_range(0.0, 60.0, 0.1, "or_greater") var smoothing_speed := 12.0
## false: keep the current world position while selected. Useful for rotation-
## only handles and constrained test objects.
@export var track_position := true
## false (default): position-only follow, world rotation preserved; stable for
## hand rays. true: follow the attach pose's rotation too.
@export var track_rotation := false
@export_range(0.0, 100.0, 0.1, "or_greater") var max_tracked_speed := 20.0
## Metres of PERCEIVED distance per second for the attach transit (rotation
## counts toward that distance, so a flip and a comparable move take similar
## time). 0 disables transit for this object: it snaps as it did before.
@export_range(0.0, 10.0, 0.1) var transit_speed := 1.5

@export_group("Throw")
## Applies the sampled attach-pose velocity to a RigidBody3D target when the
## final selecting interactor releases. This mirrors XRITK throw-on-release
## behavior without requiring engine-level input velocity APIs.
@export var throw_on_release := true
@export_range(0.0, 10.0, 0.01, "or_greater") var throw_velocity_scale := 1.0
@export_range(0.0, 100.0, 0.1, "or_greater") var max_throw_speed := 14.0
@export_range(1, 30, 1, "or_greater") var throw_sample_frames := 10
@export_range(0.0, 10.0, 0.01, "or_greater") var throw_angular_velocity_scale := 1.0
@export_range(0.0, 100.0, 0.1, "or_greater") var max_throw_angular_speed := 18.0
@export_range(0, 5, 1) var throw_deadzone_frames := 2
@export_range(0.05, 2.0, 0.05) var throw_consensus_tolerance := 0.35
## How far the estimate leans from the cluster MEAN toward its FASTEST sample.
## The dead-zone drops the newest frames, which on an accelerating throw are
## the fastest ones -- so a pure mean systematically under-throws (measured
## ~12% on a 0.4->4.0 m/s ramp). Leaning toward the peak of the CLEAN samples
## recovers that without letting the corrupted release frames back in.
## 0 = mean (pre-bias behaviour), 1 = the fastest clean sample.
@export_range(0.0, 1.0, 0.05) var throw_peak_bias := 0.8  # David: 80% confirmed good, 2026-07-25

@export_group("Two Hand Grab")
## Allows a second interactor to select the same object. The second hand rotates
## around the hand-to-hand axis change, and can uniformly scale by hand distance.
@export var two_hand_grab_enabled := false
@export var two_hand_track_position := true
@export var two_hand_rotate := true
@export var two_hand_scale := true
@export_range(0.01, 10.0, 0.01, "or_greater") var two_hand_min_scale_multiplier := 0.25
@export_range(0.01, 10.0, 0.01, "or_greater") var two_hand_max_scale_multiplier := 4.0

var _grab_offset := Transform3D.IDENTITY
var _grab_points: Array = []
var _point_grab := false
var _grabbing: Node
var _grabbers: Array[Node] = []
var _two_hand_active := false
var _two_hand_start_midpoint := Vector3.ZERO
var _two_hand_start_vector := Vector3.RIGHT
var _two_hand_start_distance := 1.0
var _two_hand_start_transform := Transform3D.IDENTITY
var _last_throw_pose := Transform3D.IDENTITY
var _throw_linear_velocity := Vector3.ZERO
var _throw_angular_velocity := Vector3.ZERO
var _throw_linear_samples: Array[Vector3] = []
var _throw_angular_samples: Array[Vector3] = []
var _has_throw_sample := false
## Analog use strength, 0..1. Read-only to consumers; drivers call
## set_use_value(). Zero whenever nothing is driving it, so a prop can never
## latch a stale pull after release.
var use_value := 0.0
var _transit_time_left := 0.0
var _transit_duration := 0.0
var _transit_from := Transform3D.IDENTITY
## Whether the CURRENTLY ARMED transit is an ATTRACT delivery, so
## _physics_process can ease only that one -- transit_blend/transit_duration
## are shared with authored-grip/snap_to_attach transits already earned in on
## device, and easing them too is a feel change nobody has verified.
var _transit_is_attract := false

## Called by whatever is driving USE on this object -- today the bare-hand
## XRHandActivator, which already computes a normalized pull. `source_hand` is
## the hand supplying it; a push from a hand that is not the PRIMARY grabber is
## ignored, so a second hand resting on a two-handed tool cannot fight the
## hand actually working it. Pass -1 to drive it unconditionally.
func set_use_value(value: float, source_hand: int = -1) -> void:
	if source_hand >= 0 and not _is_primary_hand(source_hand):
		return
	var clamped := clampf(value, 0.0, 1.0)
	if is_equal_approx(clamped, use_value):
		return
	use_value = clamped
	use_changed.emit(use_value)

## The first grabber owns the axis; on a two-hand -> one-hand handoff the
## remaining hand takes it over, because _grabbers[0] is then that hand.
func _is_primary_hand(source_hand: int) -> bool:
	if _grabbers.is_empty():
		return false
	var primary = _grabbers[0]
	return primary != null and "hand" in primary and int(primary.hand) == source_hand

## True when this object is held, and every holder is a DIFFERENT hand from the
## incoming interactor. An interactor with no hand (a screen/mouse ray) never
## swaps, because there is no hand to swap away from.
func _held_by_other_hand(interactor) -> bool:
	if _grabbers.is_empty() or interactor == null or not ("hand" in interactor):
		return false
	for holder in _grabbers:
		if holder == null or not ("hand" in holder):
			return false
		if int(holder.hand) == int(interactor.hand):
			return false
	return true

func get_target() -> Node3D:
	if target_path.is_empty():
		return self
	return get_node_or_null(target_path) as Node3D

func can_select(interactor) -> bool:
	if not can_hover(interactor) or _grabbers.has(interactor):
		return false
	if not two_hand_grab_enabled:
		# A different HAND may take over a held object; _notify_select_entered
		# releases the previous holder. Deliberately hand-based, not
		# interactor-based: allowing any other interactor let the SAME hand's
		# far ray hover and steal what its own near grab was holding, which
		# also kept the ray cursor drawn over an object already in the hand.
		if allow_grab_swap and _held_by_other_hand(interactor):
			return true
		return super(interactor)
	return _grabbers.size() < 2

func _notify_select_entered(interactor) -> void:
	if _grabbers.has(interactor):
		return
	# Hand-to-hand swap: the previous holder lets go first, so exactly one hand
	# owns the object and the offset/transit/use-axis state is rebuilt against
	# the hand that now has it.
	if allow_grab_swap and not two_hand_grab_enabled and _held_by_other_hand(interactor):
		for previous in _grabbers.duplicate():
			if previous != null and previous.has_method("_release_select"):
				# Through the INTERACTOR, never _notify_select_exited directly:
				# the latter leaves the old interactor still believing it holds
				# this object, which wedges it in a selected state and is
				# exactly how a ray ends up unable to hover anything again.
				previous._release_select()
	super(interactor)
	_grabbers.append(interactor)
	if _grabbers.size() == 1:
		_grabbing = interactor
		_grab_offset = _compute_grab_offset(interactor)
		_two_hand_active = false
		_set_body_frozen(true)
		_reset_throw_sample(_movement_target_pose_for(interactor))
		_arm_transit(interactor)
		grabbed.emit(interactor)
	elif _grabbers.size() == 2:
		_begin_two_hand_grab()

func _notify_select_exited(interactor) -> void:
	super(interactor)
	if _grabbers.has(interactor):
		_grabbers.erase(interactor)

	if _grabbers.is_empty():
		_set_body_frozen(false)
		_apply_throw_on_release()
		_grabbing = null
		_two_hand_active = false
		_has_throw_sample = false
		_point_grab = false
		_transit_duration = 0.0
		_transit_time_left = 0.0
		set_use_value(0.0)
		released.emit(interactor)
		return

	# Two-hand -> one-hand handoff: _grab_offset is about to be recomputed
	# against the remaining interactor's CURRENT pose and the object's
	# CURRENT (post-two-hand) transform. A transit left in flight from before
	# the two-hand grab began would blend from a STALE _transit_from (its
	# scale/position captured long before the two-hand session moved/scaled
	# the object) toward a target built from the new offset -- transit_blend's
	# exactness at alpha=1 depends on `from`/`to` sharing the same object
	# scale, which a stale `from` cannot guarantee. Re-arm (not just clear):
	# authored/snap grabs are meant to tween, and a hand-count change is
	# exactly the kind of pose discontinuity the transit phase exists to
	# smooth over, rather than pop through in one instant frame.
	_grabbing = _grabbers[0]
	_grab_offset = _compute_grab_offset(_grabbing)
	_two_hand_active = false
	_reset_throw_sample(_movement_target_pose_for(_grabbing))
	_arm_transit(_grabbing)

func _physics_process(delta: float) -> void:
	if _grabbers.is_empty():
		return

	var target := get_target()
	if target == null:
		return

	if two_hand_grab_enabled and _grabbers.size() >= 2:
		if not _two_hand_active:
			_begin_two_hand_grab()
		if _two_hand_active:
			var desired := _compute_two_hand_transform()
			_apply_movement(target, desired, delta, true, two_hand_track_position)
			_sample_throw_velocity(desired, delta)
		return

	if _grabbing == null:
		return

	var attach_pose := _movement_target_pose_for(_grabbing)
	var desired: Transform3D = attach_pose * _grab_offset
	var follow_rotation := track_rotation or _point_grab
	if _transit_time_left > 0.0:
		_transit_time_left = maxf(0.0, _transit_time_left - delta)
		var alpha := 1.0 - (_transit_time_left / _transit_duration)
		# Eased ONLY for the ATTRACT delivery -- transit_blend/transit_duration
		# are shared with authored-grip/snap_to_attach transits already earned
		# in on device at a linear pace, and this must not touch their feel.
		if _transit_is_attract:
			alpha = ease_out_cubic(alpha)
		var blended := transit_blend(_transit_from, desired, alpha)
		_apply_movement(target, blended, delta, follow_rotation, track_position or _point_grab)
	else:
		_apply_movement(target, desired, delta, follow_rotation, track_position or _point_grab)
	if not follow_rotation:
		attach_pose.basis = _last_throw_pose.basis
	_sample_throw_velocity(attach_pose, delta)

## Whether the target is currently mid-tween from its pre-grab pose onto the
## live attach target (authored grips / snap_to_attach only; observability
## for tests and any UI that wants to know the object isn't "settled" yet).
func in_transit() -> bool:
	return _transit_time_left > 0.0

## Arms a transit for authored grips (point grabs) and snap_to_attach offsets
## only; free grabs hold wherever they were grabbed (no transit). Called on
## every path that recomputes `_grab_offset` -- a fresh single-hand grab and
## a two-hand -> one-hand handoff -- so a transit is always measured against
## the offset that is actually in effect afterward, never a stale one.
func _arm_transit(interactor) -> void:
	_transit_duration = 0.0
	_transit_time_left = 0.0
	_transit_is_attract = false
	# ATTRACT is a travel operation by definition, so it needs the tween even
	# with no authored grip. The original guard only armed for point grabs and
	# snap_to_attach, because an ordinary grab keeps the object where it already
	# sits relative to the hand and has nothing to travel. That made the design
	# claim "ATTRACT composes the existing transit" true only for authored
	# grips - a plain grabbable armed no transit at all and jumped. David, on
	# device: "it feels like a snap near the hand".
	var attracting: bool = interactor is XRRayInteractor and far_grab_mode == FarGrabMode.ATTRACT
	if not (_point_grab or (snap_to_attach and _grab_points.is_empty()) or attracting):
		return
	var target_node := get_target()
	# Same out-of-tree hazard as _compute_grab_offset, and this one is reached
	# on the very next line of the handoff. Arming a transit FROM identity would
	# make the object tween in from world origin the moment it was re-parented.
	if target_node == null or not target_node.is_inside_tree():
		return
	# _movement_target_pose_for, not _attach_pose_for: for ATTRACT this is what
	# actually makes the transit travel. _compute_grab_offset already collapsed
	# _grab_offset to IDENTITY (free grab) or to the authored-point offset for
	# an ATTRACT far-grab -- either way `desired` here is now genuinely
	# different from the object's CURRENT transform, where the un-collapsed
	# free-grab offset made them identical by construction (see the comment on
	# _compute_grab_offset's ATTRACT branch).
	var desired := _movement_target_pose_for(interactor) * _grab_offset
	_transit_from = target_node.global_transform
	# When this grab does not follow rotation, _apply_movement discards the
	# blended basis anyway -- so letting the rotation term set the pace would
	# stretch the tween for a turn the object never makes. Time the travel the
	# object will actually perform.
	var timed_to := desired
	if not (track_rotation or _point_grab):
		timed_to.basis = _transit_from.basis
	# far_grab_attract_speed, not the shared transit_speed, whenever this is an
	# ATTRACT far-grab (point or free) -- see far_grab_attract_speed's doc
	# comment for the arithmetic behind its default.
	var speed := far_grab_attract_speed if attracting else transit_speed
	_transit_duration = transit_duration(_transit_from, timed_to, speed)
	_transit_time_left = _transit_duration
	_transit_is_attract = attracting

func _compute_grab_offset(interactor) -> Transform3D:
	var target := get_target()
	# A release can arrive while the object is already OUT of the tree: a scene
	# change frees a held object and the deselect follows it down. Node3D does
	# not merely complain about global_transform there -- it RETURNS IDENTITY,
	# so recomputing would quietly install a garbage offset that snaps the
	# object to the hand's origin if anything still draws or reuses it. Keep the
	# offset that is actually in effect; there is nothing meaningful to
	# recompute against a transform that no longer exists. David, on device
	# (Quest 3 APK): 'Condition "!is_inside_tree()" is true' raised from the
	# two-hand -> one-hand handoff below.
	if target != null and not target.is_inside_tree():
		return _grab_offset
	_point_grab = false
	if target == null:
		return Transform3D.IDENTITY
	var point := _best_grab_point(interactor)
	if point != null and not point.is_inside_tree():
		return _grab_offset
	if point != null:
		# Point grabs are authored grips: the object snaps so the point lands
		# in the hand, position AND rotation, regardless of the free-grab
		# track_* defaults.
		_point_grab = true
		var offset := point.global_transform.affine_inverse() * target.global_transform
		return _mirror_offset(point, interactor, offset)
	if snap_to_attach:
		var attach_node := get_node_or_null(attach_transform_path) as Node3D
		if attach_node != null and not attach_node.is_inside_tree():
			return _grab_offset
		if attach_node:
			return attach_node.global_transform.affine_inverse() * target.global_transform
		return Transform3D.IDENTITY
	if interactor is XRRayInteractor and far_grab_mode == FarGrabMode.ATTRACT:
		# ATTRACT is snap_to_attach for far grabs: the destination is the
		# grip itself, not wherever the object happened to be relative to
		# the ray when grabbed. The free-grab formula below,
		# `interactor.get_attach_pose()^-1 * target.global_transform`,
		# preserves the object's CURRENT displacement from the ray EXACTLY
		# -- for a 3 m far grab that displacement IS the 3 m gap ATTRACT
		# exists to close, and _arm_transit's `desired` collapses right
		# back to the object's own current transform
		# (A * (A^-1 * X) == X for any A, X), leaving nothing to travel
		# and a duration of exactly zero (confirmed empirically -- see
		# far-grab-guards-report.md). Collapsing the offset to IDENTITY,
		# the same way snap_to_attach does with no attach_node, is what
		# gives the transit real distance to cover: _movement_target_pose_for
		# supplies the actual destination (the adapter's grip pose) for
		# both this line and _arm_transit/_physics_process.
		return Transform3D.IDENTITY
	return interactor.get_attach_pose().affine_inverse() * target.global_transform

## A grip authored for one hand mirrors for the other: reflect the object's pose
## relative to the grip across the grip's sagittal plane (local X), so the other
## hand holds it as a mirror image instead of a wrongly-rotated copy.
func _mirror_offset(point: Node, interactor, offset: Transform3D) -> Transform3D:
	if not bool(point.get("mirror_to_other_hand")) or not ("hand" in interactor):
		return offset
	if int(interactor.hand) == int(point.get("authored_hand")):
		return offset
	var flip := Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))
	return Transform3D(flip * offset.basis * flip, flip * offset.origin)


## Grab points self-register from _enter_tree (see XRGrabPoint).
func register_grab_point(point: Node3D) -> void:
	if not _grab_points.has(point):
		_grab_points.append(point)

func unregister_grab_point(point: Node3D) -> void:
	_grab_points.erase(point)

func _best_grab_point(interactor) -> Node3D:
	if _grab_points.is_empty():
		return null
	var interactor_hand := -1
	if interactor != null and "hand" in interactor:
		interactor_hand = interactor.hand
	var attach_origin := _attach_pose_for(interactor).origin
	var best: Node3D = null
	var best_priority := -2147483648
	var best_distance := INF
	for point_entry in _grab_points:
		var point := point_entry as Node3D
		if point == null or not is_instance_valid(point) or not point.is_inside_tree():
			continue
		if point.has_method("matches_hand") and not point.matches_hand(interactor_hand):
			continue
		var point_priority := int(point.get("priority")) if point.get("priority") != null else 0
		var distance := attach_origin.distance_squared_to(point.global_transform.origin)
		if point_priority > best_priority or (point_priority == best_priority and distance < best_distance):
			best = point
			best_priority = point_priority
			best_distance = distance
	return best

func _begin_two_hand_grab() -> void:
	# A second hand joining recomputes how the object is tracked entirely
	# (midpoint/rotation/scale instead of a single-hand _grab_offset); any
	# transit armed during the single-hand phase is no longer measuring
	# anything meaningful and must not survive into two-hand tracking.
	# Cleared unconditionally, before the distance/grabber-count guards below,
	# so a degenerate two-hand attempt (hands coincident) can't leave it
	# armed-but-frozen while _physics_process's two-hand branch skips the
	# code that would otherwise decrement it.
	_transit_duration = 0.0
	_transit_time_left = 0.0
	var target := get_target()
	if target == null or _grabbers.size() < 2:
		_two_hand_active = false
		return

	var first_pose := _attach_pose_for(_grabbers[0])
	var second_pose := _attach_pose_for(_grabbers[1])
	var vector := second_pose.origin - first_pose.origin
	var distance := vector.length()
	if distance < 0.001:
		_two_hand_active = false
		return

	_two_hand_start_midpoint = (first_pose.origin + second_pose.origin) * 0.5
	_two_hand_start_vector = vector
	_two_hand_start_distance = distance
	_two_hand_start_transform = target.global_transform
	_two_hand_active = true

func _compute_two_hand_transform() -> Transform3D:
	var first_pose := _attach_pose_for(_grabbers[0])
	var second_pose := _attach_pose_for(_grabbers[1])
	var current_vector := second_pose.origin - first_pose.origin
	var current_distance := current_vector.length()
	if current_distance < 0.001:
		current_vector = _two_hand_start_vector
		current_distance = _two_hand_start_distance

	var midpoint := (first_pose.origin + second_pose.origin) * 0.5
	var rotation := _rotation_between_vectors(_two_hand_start_vector, current_vector) if two_hand_rotate else Basis.IDENTITY
	var scale_multiplier := 1.0
	if two_hand_scale:
		scale_multiplier = clampf(
			current_distance / maxf(_two_hand_start_distance, 0.001),
			two_hand_min_scale_multiplier,
			two_hand_max_scale_multiplier
		)

	var midpoint_offset := _two_hand_start_transform.origin - _two_hand_start_midpoint
	midpoint_offset = rotation * midpoint_offset
	midpoint_offset *= scale_multiplier

	var desired := _two_hand_start_transform
	desired.origin = midpoint + midpoint_offset
	desired.basis = rotation * _two_hand_start_transform.basis
	desired.basis = desired.basis.scaled(Vector3.ONE * scale_multiplier)
	return desired

func _attach_pose_for(interactor) -> Transform3D:
	if interactor != null and interactor.has_method("get_attach_pose"):
		return interactor.get_attach_pose()
	return Transform3D.IDENTITY

## The per-frame pose XRGrabInteractable's OWN movement/transit code tracks --
## deliberately NOT the same thing as _attach_pose_for, which _best_grab_point
## (matching which authored point the ray is nearest) and the two-hand math
## also call, for their own unrelated purposes, and which must keep seeing the
## interactor's raw attach pose there.
##
## For an ATTRACT far-grab this is the adapter's own grip pose -- the physical
## hand/controller transform -- rather than a point along the ray:
## _resolve_grab_pose's reel-to-grip blend sources its target from
## suppress_interactor_path, which is set in no scene in this repository, so
## it never actually delivers the object to the hand (see
## docs/far-grab-modes-design.md's "Amendment" section). The adapter's grip
## pose needs no scene wiring and is available whenever the hand/controller is
## tracked. Falls back to the interactor's normal attach pose whenever the
## grip pose isn't available (not ATTRACT, not a ray, or genuinely untracked),
## so ATTRACT degrades to "follow the ray" rather than freezing.
##
## A FREE grab (no authored point -- _point_grab false) lands
## far_grab_attract_standoff forward of the grip along the grip pose's OWN
## basis, not the ray's: `grip_basis * Vector3.FORWARD` is the grip's local
## -Z in world space (the same "pointing" convention _hand_grip_pose/
## _controller_aim_pose already use), so rotating the wrist after the grab
## rotates the standoff with it -- a ray-relative offset would instead hang
## in a fixed world direction as the hand turns, which reads as the object
## NOT being held. An authored grab point's placement is deliberate (an
## authored mug handle, a blaster grip) and keeps landing exactly on the grip
## pose, unchanged -- the standoff would fight it.
func _movement_target_pose_for(interactor) -> Transform3D:
	if interactor is XRRayInteractor and far_grab_mode == FarGrabMode.ATTRACT \
			and interactor.has_method("get_hand_grip_pose"):
		var grip: Dictionary = interactor.get_hand_grip_pose()
		if grip.get("valid", false):
			var grip_basis: Basis = grip.get("basis", Basis.IDENTITY)
			var grip_origin: Vector3 = grip["origin"]
			if _point_grab:
				return Transform3D(grip_basis, grip_origin)
			var standoff := (grip_basis * Vector3.FORWARD) * far_grab_attract_standoff
			return Transform3D(grip_basis, grip_origin + standoff)
	return _attach_pose_for(interactor)

func _rotation_between_vectors(from_vector: Vector3, to_vector: Vector3) -> Basis:
	var from_dir := from_vector.normalized()
	var to_dir := to_vector.normalized()
	if from_dir.length_squared() < 0.000001 or to_dir.length_squared() < 0.000001:
		return Basis.IDENTITY

	var dot := clampf(from_dir.dot(to_dir), -1.0, 1.0)
	if dot > 0.9999:
		return Basis.IDENTITY

	var axis := from_dir.cross(to_dir)
	if axis.length_squared() < 0.000001:
		axis = from_dir.cross(Vector3.UP)
		if axis.length_squared() < 0.000001:
			axis = from_dir.cross(Vector3.RIGHT)
	return Basis(axis.normalized(), acos(dot))

func _apply_movement(target: Node3D, desired: Transform3D, delta: float, apply_basis := true, apply_origin := true) -> void:
	if not apply_origin:
		desired.origin = target.global_transform.origin
	if not apply_basis:
		desired.basis = target.global_transform.basis

	match movement_type:
		MovementType.INSTANT:
			target.global_transform = desired
		MovementType.KINEMATIC_SMOOTH:
			var weight := 1.0 - exp(-smoothing_speed * delta)
			var xf := target.global_transform
			xf.origin = xf.origin.lerp(desired.origin, weight)
			if apply_basis:
				xf.basis = _interpolate_basis(xf.basis, desired.basis, weight)
			target.global_transform = xf
		MovementType.VELOCITY_TRACKED:
			var body := target as RigidBody3D
			if body == null:
				target.global_transform = desired
				return
			var velocity := (desired.origin - body.global_position) / maxf(delta, 0.0001)
			body.linear_velocity = velocity.limit_length(max_tracked_speed)
			if apply_basis:
				var body_transform := body.global_transform
				body_transform.basis = desired.basis
				body.global_transform = body_transform

func _reset_throw_sample(pose: Transform3D) -> void:
	_last_throw_pose = pose
	_throw_linear_velocity = Vector3.ZERO
	_throw_angular_velocity = Vector3.ZERO
	_throw_linear_samples.clear()
	_throw_angular_samples.clear()
	_has_throw_sample = true

func _sample_throw_velocity(pose: Transform3D, delta: float) -> void:
	if not throw_on_release or delta <= 0.0:
		return
	if not _has_throw_sample:
		_reset_throw_sample(pose)
		return

	var velocity := (pose.origin - _last_throw_pose.origin) / maxf(delta, 0.0001)
	var angular_velocity := _angular_velocity_between(_last_throw_pose.basis, pose.basis, delta)
	_push_throw_sample(_throw_linear_samples, velocity.limit_length(max_throw_speed))
	_push_throw_sample(_throw_angular_samples, angular_velocity.limit_length(max_throw_angular_speed))
	_throw_linear_velocity = _average_throw_samples(_throw_linear_samples).limit_length(max_throw_speed)
	_throw_angular_velocity = _average_throw_samples(_throw_angular_samples).limit_length(max_throw_angular_speed)
	_last_throw_pose = pose

## Freeze a RigidBody3D target (kinematic) while it's held, so gravity doesn't
## fight the grab; unfreezing on release lets the thrown velocity carry it with
## real physics. No-op for non-rigid targets (the common case).
func _set_body_frozen(frozen: bool) -> void:
	var body := get_target() as RigidBody3D
	if body == null:
		return
	if frozen:
		body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body.freeze = frozen


func _apply_throw_on_release() -> void:
	var body := get_target() as RigidBody3D
	if not throw_on_release or not _has_throw_sample:
		# Not thrown: drop from REST. A body moved kinematically inherits the
		# hand's motion as velocity when unfrozen - releasing while pushing the
		# pen down at the desk would fling it through the surface. Zero it so it
		# just settles.
		if body:
			body.linear_velocity = Vector3.ZERO
			body.angular_velocity = Vector3.ZERO
		return

	if body == null:
		return

	body.sleeping = false
	var linear_vel := throw_consensus(_throw_linear_samples, throw_deadzone_frames, throw_consensus_tolerance, throw_peak_bias)
	var angular_vel := _average_throw_samples(_deadzone_slice(_throw_angular_samples, throw_deadzone_frames))
	body.linear_velocity = (linear_vel * throw_velocity_scale).limit_length(max_throw_speed)
	body.angular_velocity = (angular_vel * throw_angular_velocity_scale).limit_length(max_throw_angular_speed)
	thrown.emit(body.linear_velocity, body.angular_velocity)

func _push_throw_sample(samples: Array[Vector3], velocity: Vector3) -> void:
	samples.append(velocity)
	while samples.size() > throw_sample_frames:
		samples.pop_front()

func _average_throw_samples(samples: Array[Vector3]) -> Vector3:
	if samples.is_empty():
		return Vector3.ZERO
	var total := Vector3.ZERO
	for sample in samples:
		total += sample
	return total / float(samples.size())

## Drops the newest `deadzone_frames` samples -- the frames where the fingers
## are peeling off and the tracked velocity is corrupted. A small buffer cannot
## afford the full dead-zone: slicing blindly can leave a single stale sample,
## or none at all, which is worse than the plain mean it replaced. So the
## dead-zone shrinks to keep at least 3 samples, and never empties a non-empty
## buffer. BOTH the linear and angular estimates go through here -- an earlier
## revision guarded only the linear path, which silently starved the angular
## estimate on any prefab shipping a short throw_sample_frames buffer.
static func _deadzone_slice(samples: Array[Vector3], deadzone_frames: int) -> Array[Vector3]:
	if samples.is_empty():
		return []
	var deadzone := mini(deadzone_frames, maxi(0, samples.size() - 3))
	var usable := samples.slice(0, maxi(0, samples.size() - deadzone))
	if usable.is_empty():
		return samples.duplicate()
	return usable

## Consensus throw-velocity estimate (technique: Meta ISDK release filtering,
## as publicly described; implementation ours - see docs/grab-feel-design.md).
## After the dead-zone, returns the mean of the largest cluster: for each
## sample, every other sample within tolerance * MEDIAN magnitude of it, and
## the biggest such group wins. That is a ball around one anchor, not a
## mutually-agreeing clique -- two members can differ by up to 2 * the radius.
## The approximation is deliberate: it is linear in the buffer and the buffer
## is ~10 samples. Ties go to the more recent anchor, which sits closer to the
## actual release. Fewer than 4 usable samples: plain mean of them.
## The dead-zone itself shrinks when the buffer is too small to afford it (at
## least 3 samples stay usable), so a small throw_sample_frames buffer is
## never starved down to a single stale sample.
static func throw_consensus(samples: Array[Vector3], deadzone_frames: int, tolerance: float, peak_bias := 0.0) -> Vector3:
	if samples.is_empty():
		return Vector3.ZERO
	var usable := _deadzone_slice(samples, deadzone_frames)
	if usable.size() < 4:
		return _lean_to_peak(_mean_of(usable), usable, peak_bias)

	var magnitudes: Array[float] = []
	for sample in usable:
		magnitudes.append(sample.length())
	magnitudes.sort()
	var median: float = magnitudes[magnitudes.size() / 2]
	var limit := maxf(tolerance * median, 0.0001)

	var best_set: Array[Vector3] = []
	var best_anchor := -1
	for anchor_index in range(usable.size()):
		var agreeing: Array[Vector3] = []
		for sample in usable:
			if sample.distance_to(usable[anchor_index]) <= limit:
				agreeing.append(sample)
		if agreeing.size() > best_set.size() or (agreeing.size() == best_set.size() and anchor_index > best_anchor):
			best_set = agreeing
			best_anchor = anchor_index
	return _lean_to_peak(_mean_of(best_set), best_set, peak_bias)

## Leans an estimate from the cluster mean toward the cluster's fastest sample.
## Only ever speeds the throw up, never reverses or redirects it: the peak is a
## member of the same agreeing cluster, so it points the same way.
static func _lean_to_peak(mean: Vector3, cluster: Array[Vector3], peak_bias: float) -> Vector3:
	if peak_bias <= 0.0 or cluster.is_empty():
		return mean
	var peak := mean
	for sample in cluster:
		if sample.length_squared() > peak.length_squared():
			peak = sample
	return mean.lerp(peak, clampf(peak_bias, 0.0, 1.0))

static func _mean_of(samples: Array[Vector3]) -> Vector3:
	if samples.is_empty():
		return Vector3.ZERO
	var total := Vector3.ZERO
	for sample in samples:
		total += sample
	return total / float(samples.size())

## Perceived-distance transit timing (technique: ISDK tweened grab movement,
## publicly described; implementation ours). A 180-degree flip counts as
## 0.25 m so rotation-dominant attaches do not pop.
static func transit_duration(from: Transform3D, to: Transform3D, speed: float) -> float:
	if speed <= 0.0:
		return 0.0
	var translation := (to.origin - from.origin).length()
	var rotation_deg := rad_to_deg(from.basis.get_rotation_quaternion().angle_to(to.basis.get_rotation_quaternion()))
	# The 0.5/360 factor comes from Meta's published description and is a
	# sanity check, not a shipped constant: it is ours to retune on device.
	var perceived := maxf(translation, rotation_deg * 0.5 / 360.0)
	if perceived < 0.0005:
		return 0.0
	return perceived / speed

static func transit_blend(from: Transform3D, to: Transform3D, alpha: float) -> Transform3D:
	var t := clampf(alpha, 0.0, 1.0)
	var from_rotation := from.basis.orthonormalized()
	var to_rotation := to.basis.orthonormalized()
	# Scale rides through untouched rather than being decomposed: a transit
	# moves an object, it never resizes one, so `from` and `to` carry the same
	# object scale. orthonormalized().inverse() * basis is the exact local
	# scale/shear for ANY basis -- where get_scale() + scaled() round-tripping
	# silently permutes which local axis gets which magnitude once the basis is
	# rotated and the scale is non-uniform.
	var local_scale := from_rotation.inverse() * from.basis
	var blended := Basis(from_rotation.get_rotation_quaternion().slerp(to_rotation.get_rotation_quaternion(), t))
	return Transform3D(blended * local_scale, from.origin.lerp(to.origin, t))

## Cubic ease-out: fast start, soft settle into the hand -- reads as arriving
## rather than colliding. David, on device, on the linear pace transit_blend
## gives every transit: "too snappy". Applied ONLY to the ATTRACT transit's
## alpha (see _transit_is_attract in _physics_process); transit_blend itself
## stays linear and untouched so authored-grip/snap_to_attach transits already
## earned in on device keep their existing pace.
static func ease_out_cubic(t: float) -> float:
	var clamped := clampf(t, 0.0, 1.0)
	return 1.0 - pow(1.0 - clamped, 3.0)

func _angular_velocity_between(from_basis: Basis, to_basis: Basis, delta: float) -> Vector3:
	if delta <= 0.0:
		return Vector3.ZERO

	var from_rotation := from_basis.orthonormalized().get_rotation_quaternion()
	var to_rotation := to_basis.orthonormalized().get_rotation_quaternion()
	var delta_rotation := (to_rotation * from_rotation.inverse()).normalized()
	if delta_rotation.w < 0.0:
		delta_rotation = Quaternion(-delta_rotation.x, -delta_rotation.y, -delta_rotation.z, -delta_rotation.w)

	var w := clampf(delta_rotation.w, -1.0, 1.0)
	var angle := 2.0 * acos(w)
	if angle > PI:
		angle -= TAU

	var sin_half_angle := sqrt(maxf(0.0, 1.0 - w * w))
	if sin_half_angle < 0.0001:
		return Vector3.ZERO

	var axis := Vector3(delta_rotation.x, delta_rotation.y, delta_rotation.z) / sin_half_angle
	return axis * (angle / delta)

func _interpolate_basis(from_basis: Basis, to_basis: Basis, weight: float) -> Basis:
	var from_scale := from_basis.get_scale()
	var to_scale := to_basis.get_scale()
	var from_rotation := from_basis.orthonormalized().get_rotation_quaternion()
	var to_rotation := to_basis.orthonormalized().get_rotation_quaternion()
	return Basis(from_rotation.slerp(to_rotation, weight)).scaled(from_scale.lerp(to_scale, weight))
