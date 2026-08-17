@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_grab_interactable.svg")
class_name XRDrawer
extends XRConstrainedInteractable

## A drawer / linear slider: grab and pull along one axis between closed (0)
## and open (1). Unity XRI's Drawer. Wire value_changed to anything.

## Slide direction in the PARENT's local space; length set by travel.
@export var slide_axis := Vector3(0.0, 0.0, 1.0)
## How far it slides, in metres, from closed to open.
@export_range(0.02, 2.0, 0.01) var travel := 0.3

var _rest_position := Vector3.ZERO
var _grab_projection := 0.0
var _grab_value := 0.0


func _capture_rest() -> void:
	var moved := target()
	if moved:
		# The authored position corresponds to default_value along the axis.
		_rest_position = moved.position - _axis().normalized() * (default_value * travel)


func _apply_value() -> void:
	var moved := target()
	if moved:
		moved.position = _rest_position + _axis().normalized() * (value * travel)


func _on_grab() -> void:
	_grab_projection = _project(_hand_world())
	_grab_value = value


func _on_update(hand: Vector3) -> void:
	if travel <= 0.0:
		return
	set_value(_grab_value + (_project(hand) - _grab_projection) / travel)


func _axis() -> Vector3:
	return slide_axis if slide_axis.length_squared() > 1e-8 else Vector3.FORWARD


## Hand position projected onto the slide axis, in the parent's local space.
func _project(hand_world: Vector3) -> float:
	var moved := target()
	var parent := moved.get_parent() as Node3D if moved else null
	var local := parent.to_local(hand_world) if parent else hand_world
	return local.dot(_axis().normalized())


## Pull it most of the way open along its slide.
func drive_travel() -> Vector3:
	return drive_point() + drive_axis_world(slide_axis) * (travel * 0.6)
