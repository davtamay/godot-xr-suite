@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg")
class_name XRDial
extends XRConstrainedInteractable

## A dial / rotary knob: grab it and orbit your grab around it to sweep a value
## 0..1. This follows Unity XRI's XRKnob position tracking - the knob turns to
## match the angle of your GRAB POINT around the spin axis, so orbiting your
## grab is 1:1 with the knob (grab the pointer, move it around, the knob
## follows). The grab point is on the knob itself (a near grab, or where the far
## ray hits it), so it works near or far. Optional detents; wire value_changed
## to volume, brightness, anything.

## Spin axis in the knob's LOCAL space (default: its up axis).
@export var spin_axis := Vector3(0.0, 1.0, 0.0)
## Flip which twist direction raises the value (the knob still follows your
## wrist either way; this only swaps increase/decrease). Turn this on if
## "clockwise = more" feels backwards for how the knob is mounted.
@export var invert := false
## Total sweep from value 0 to value 1, in degrees.
@export_range(15.0, 1440.0, 5.0) var range_degrees := 270.0
## Turn gain: the knob rotates this many times the angle your hand sweeps
## around it. 1 = exactly follows your hand (a full turn needs a full hand
## circle); >1 lets a comfortable arc do more, which suits far-ray grabbing.
@export_range(0.25, 8.0, 0.25) var sensitivity := 1.0
## Higher = smoother/heavier (eases toward the target and filters hand jitter);
## 0 = instant/snappy. Around 0.6 feels smooth but responsive.
@export_range(0.0, 0.95, 0.05) var smoothing := 0.6
## 0 = smooth. >0 = snap to this many detents (e.g. 10 = eleven positions).
@export_range(0, 64, 1) var snap_steps := 0

# The grab point must be at least this far from the knob axis for the angle to
# be stable - near the centre the angle flips wildly, which is what made a
# controller grab (whose point wanders through the centre) stick or spin.
const _MIN_RADIUS := 0.02
# Cap on one frame's turn, so a near-centre flip can never jump the dial.
const _MAX_STEP_DEG := 20.0

var _zero_basis := Basis.IDENTITY
var _prev_dir := Vector3.ZERO
var _accum_degrees := 0.0
var _grab_value := 0.0
var _target_value := 0.0


func _capture_rest() -> void:
	var moved := target()
	if moved:
		_zero_basis = moved.transform.basis * Basis(_axis(), -deg_to_rad(default_value * range_degrees))


func _apply_value() -> void:
	var moved := target()
	if moved:
		moved.transform.basis = _zero_basis * Basis(_axis(), deg_to_rad(value * range_degrees))


func _on_grab() -> void:
	_prev_dir = _grab_dir()
	_accum_degrees = 0.0
	_grab_value = value
	_target_value = value


func _on_update(_hand: Vector3) -> void:
	if range_degrees < 0.001:
		return
	# Unity XRKnob's position tracking: the knob follows the angle of the GRAB
	# POINT around the spin axis, so orbiting your grab is 1:1 with the knob.
	# Only track while the grab point has a stable radius - near the axis the
	# angle flips, so HOLD the last good direction there (don't update it) and
	# clamp any single frame, so a controller grab whose point wanders through
	# the centre can't stick or spin. Accumulate from grab (no jump, past 180).
	var cur := _grab_dir()
	if cur.length() > _MIN_RADIUS:
		if _prev_dir.length() > _MIN_RADIUS:
			var step := sensitivity * rad_to_deg(_signed_angle_around(_prev_dir, cur, _axis_world()))
			_accum_degrees += clampf(step, -_MAX_STEP_DEG, _MAX_STEP_DEG)
		_prev_dir = cur
	_target_value = _grab_value + _accum_degrees / range_degrees
	if snap_steps > 0:
		_target_value = roundf(clampf(_target_value, 0.0, 1.0) * snap_steps) / float(snap_steps)
	# Ease the value toward its target so the knob glides instead of snapping.
	set_value(lerpf(value, _target_value, 1.0 - smoothing))


## Direction from the knob centre to the GRAB POINT, in the plane perpendicular
## to the spin axis. The grab point is the interactor's attach pose - ON the
## knob for a far-ray grab, at the hand for a near grab - so orbiting the grab
## sweeps this direction and turns the knob with it.
func _grab_dir() -> Vector3:
	var v := _grab_point() - target().global_position
	var n := _axis_world()
	return v - n * v.dot(n)


func _grab_point() -> Vector3:
	# Far ray: the ray's hit point, which sits on the knob.
	if _grabber.has_method("get_ray_state"):
		var ray: Dictionary = _grabber.get_ray_state()
		if ray.get("valid", false) and not ray.get("suppressed", false):
			return (_grabber.get_attach_pose() as Transform3D).origin
	# Near: the poke tip - the fingertip (hands) or controller tip - a stable
	# point at the tip, so a controller turns the dial just like a fingertip
	# instead of riding the wandering grip.
	if "hand" in _grabber:
		var poke := get_tree().get_first_node_in_group("xr_poke_interactor")
		if poke and poke.has_method("get_poke_point"):
			var tip: Vector3 = poke.get_poke_point(int(_grabber.hand))
			if tip != Vector3.INF:
				return tip
	if _grabber.has_method("get_attach_pose"):
		return (_grabber.get_attach_pose() as Transform3D).origin
	return _hand_world()


func _axis() -> Vector3:
	var axis := spin_axis if spin_axis.length_squared() > 1e-8 else Vector3.UP
	return -axis if invert else axis


func _axis_world() -> Vector3:
	return (target().global_transform.basis * _axis()).normalized()


## Orbit the grip around the spin axis. A knob's collider is usually centred ON
## that axis, and a hand there has no angle to turn - so the grip is pushed out
## to the rim first, exactly the correction a person makes without thinking.
func drive_travel() -> Vector3:
	var moved := target()
	if moved == null:
		return drive_point()
	var pivot := moved.global_position
	var axis := drive_axis_world(spin_axis)
	var arm := drive_point() - pivot
	arm -= axis * arm.dot(axis)
	if arm.length() < 0.015:
		var side := moved.global_transform.basis.x
		if absf(side.dot(axis)) > 0.9:
			side = moved.global_transform.basis.z
		arm = (side - axis * side.dot(axis)).normalized() * _RIM_RADIUS
	var sweep := deg_to_rad(minf(range_degrees * 0.35, 80.0))
	return pivot + Basis(axis, sweep) * arm


## Where to hold a knob whose collider sits on its own axis.
const _RIM_RADIUS := 0.045
