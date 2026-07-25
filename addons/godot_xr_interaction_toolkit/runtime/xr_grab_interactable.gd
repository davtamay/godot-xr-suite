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

@export_group("Target")
## Node3D to move. Empty = this node.
@export var target_path: NodePath

@export_group("Grab")
## Bare-hand grab gesture: PINCH (default) or GRIP (curl the lower fingers, index
## free). See HandGrab. A gun/blaster uses GRIP so the index can pull a trigger.
@export var hand_grab_style: HandGrab = HandGrab.PINCH

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
@export_range(0.1, 10.0, 0.1) var transit_speed := 1.5

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

func get_target() -> Node3D:
	if target_path.is_empty():
		return self
	return get_node_or_null(target_path) as Node3D

func can_select(interactor) -> bool:
	if not can_hover(interactor) or _grabbers.has(interactor):
		return false
	if not two_hand_grab_enabled:
		return super(interactor)
	return _grabbers.size() < 2

func _notify_select_entered(interactor) -> void:
	if _grabbers.has(interactor):
		return
	super(interactor)
	_grabbers.append(interactor)
	if _grabbers.size() == 1:
		_grabbing = interactor
		_grab_offset = _compute_grab_offset(interactor)
		_two_hand_active = false
		_set_body_frozen(true)
		_reset_throw_sample(_attach_pose_for(interactor))
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
		released.emit(interactor)
		return

	_grabbing = _grabbers[0]
	_grab_offset = _compute_grab_offset(_grabbing)
	_two_hand_active = false
	_reset_throw_sample(_attach_pose_for(_grabbing))

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

	var attach_pose := _attach_pose_for(_grabbing)
	var desired: Transform3D = attach_pose * _grab_offset
	var follow_rotation := track_rotation or _point_grab
	_apply_movement(target, desired, delta, follow_rotation, track_position or _point_grab)
	if not follow_rotation:
		attach_pose.basis = _last_throw_pose.basis
	_sample_throw_velocity(attach_pose, delta)

func _compute_grab_offset(interactor) -> Transform3D:
	var target := get_target()
	_point_grab = false
	if target == null:
		return Transform3D.IDENTITY
	var point := _best_grab_point(interactor)
	if point != null:
		# Point grabs are authored grips: the object snaps so the point lands
		# in the hand, position AND rotation, regardless of the free-grab
		# track_* defaults.
		_point_grab = true
		var offset := point.global_transform.affine_inverse() * target.global_transform
		return _mirror_offset(point, interactor, offset)
	if snap_to_attach:
		var attach_node := get_node_or_null(attach_transform_path) as Node3D
		if attach_node:
			return attach_node.global_transform.affine_inverse() * target.global_transform
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
	var linear_vel := throw_consensus(_throw_linear_samples, throw_deadzone_frames, throw_consensus_tolerance)
	var sliced_angular := _throw_angular_samples.slice(0, maxi(0, _throw_angular_samples.size() - throw_deadzone_frames))
	var angular_vel := _average_throw_samples(sliced_angular)
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

## Consensus throw-velocity estimate (technique: Meta ISDK release filtering,
## as publicly described; implementation ours - see docs/grab-feel-design.md).
## Drops the newest deadzone_frames samples (release corruption), then returns
## the mean of the largest set of mutually agreeing samples. Two samples agree
## when their difference is under tolerance * median sample magnitude. Ties go
## to the more recent set. Fewer than 4 usable samples: plain mean of them.
static func throw_consensus(samples: Array[Vector3], deadzone_frames: int, tolerance: float) -> Vector3:
	if samples.is_empty():
		return Vector3.ZERO
	var usable := samples.slice(0, maxi(0, samples.size() - deadzone_frames))
	if usable.is_empty():
		usable = samples.duplicate()
	if usable.size() < 4:
		return _mean_of(usable)

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
	return _mean_of(best_set)

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
