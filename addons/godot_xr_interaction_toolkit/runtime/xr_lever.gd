@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg")
class_name XRLever
extends XRConstrainedInteractable

## A lever / hinged handle: grab and swing it around a hinge axis between a min
## and max angle. Unity XRI's Lever. value is 0 at min_angle, 1 at max_angle.

## Hinge axis in the target's LOCAL space.
@export var hinge_axis := Vector3(1.0, 0.0, 0.0)
@export_range(-180.0, 180.0, 1.0) var min_angle_deg := -45.0
@export_range(-180.0, 180.0, 1.0) var max_angle_deg := 45.0

var _zero_basis := Basis.IDENTITY
var _grab_hand_dir := Vector3.ZERO
var _grab_value := 0.0


func _capture_rest() -> void:
	var moved := target()
	if moved == null:
		return
	# The authored basis corresponds to default_value; back out to the value=0
	# (min_angle) basis so _apply_value can rebuild any angle.
	var angle0 := deg_to_rad(lerpf(min_angle_deg, max_angle_deg, default_value))
	_zero_basis = moved.transform.basis * Basis(_axis(), -angle0)


func _apply_value() -> void:
	var moved := target()
	if moved:
		moved.transform.basis = _zero_basis * Basis(_axis(), deg_to_rad(lerpf(min_angle_deg, max_angle_deg, value)))


func _on_grab() -> void:
	_grab_hand_dir = _hand_world() - target().global_position
	_grab_value = value


func _on_update(hand: Vector3) -> void:
	var range_deg := max_angle_deg - min_angle_deg
	if absf(range_deg) < 0.001:
		return
	var delta := _signed_angle_around(_grab_hand_dir, hand - target().global_position, _axis_world())
	var grab_angle := deg_to_rad(lerpf(min_angle_deg, max_angle_deg, _grab_value))
	var new_angle := grab_angle + delta
	set_value((rad_to_deg(new_angle) - min_angle_deg) / range_deg)


func _axis() -> Vector3:
	return hinge_axis if hinge_axis.length_squared() > 1e-8 else Vector3.RIGHT


## The hinge axis in world space (fixed as the lever swings around it).
func _axis_world() -> Vector3:
	return (target().global_transform.basis * _axis()).normalized()


## Swing the handle through the bulk of its arc, around the hinge.
func drive_travel() -> Vector3:
	var moved := target()
	if moved == null:
		return drive_point()
	var pivot := moved.global_position
	var arm := drive_point() - pivot
	var sweep := deg_to_rad((max_angle_deg - min_angle_deg) * 0.55)
	return pivot + Basis(drive_axis_world(hinge_axis), sweep) * arm
