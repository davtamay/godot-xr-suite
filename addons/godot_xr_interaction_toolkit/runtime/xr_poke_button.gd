@tool
@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_poke_interactor.svg")
class_name XRPokeButton
extends Node3D

## A physical 3D push-button: the cap visibly DEPRESSES under any poke point
## (fingertip or controller tip via XRPokeInteractor) and fires at a travel
## threshold, with hysteresis so it cannot chatter at the boundary. Drop it
## anywhere - it builds its own base + cap meshes (bake-safe materials) and
## finds the scene's poke sources by group.
##
## Local +Y is the press axis (cap on top); tilt the node toward the user.

signal pressed
signal released

const _LINE_MATERIAL := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_line_material.tres")
const _PokeEvaluator := preload("res://addons/godot_xr_interaction_toolkit/runtime/poke/xr_poke_evaluator.gd")

const _FINGER_RADIUS := 0.008
const _BASE_HEIGHT := 0.012

@export var enabled := true

## How far the cap travels to bottom out.
@export_range(0.005, 0.06, 0.001) var travel := 0.022

## Fraction of travel that fires `pressed` (releases at half of it).
@export_range(0.3, 1.0, 0.05) var press_fraction := 0.7

@export_range(0.015, 0.1, 0.005) var cap_radius := 0.035

@export var cap_color := Color(0.3, 0.75, 1.0, 1.0)
@export var pressed_color := Color(0.3, 1.0, 0.55, 1.0)

## Assign to take the approach gate from one project-wide resource. The cap's
## own travel and press_fraction still set its depth - a button's throw is
## geometry, not project feel.
@export var poke_profile: XRPokeProfile

var _cap: MeshInstance3D
var _cap_material: StandardMaterial3D
var _cap_rest_y := 0.0
var _cap_height := 0.014
var _is_pressed := false

var _evaluator: XRPokeEvaluator
var _pressed_sources := {}
var _pins := {}
var _penetrations := {}


func _ready() -> void:
	_build_visuals()
	if Engine.is_editor_hint():
		set_physics_process(false)


func is_pressed() -> bool:
	return _is_pressed


## The cap's firing point expressed in the evaluator's canonical frame, where
## the surface is the BOTTOMED-OUT cap: z = travel - penetration.
func canonical_press_depth() -> float:
	return travel * (1.0 - press_fraction)


func canonical_release_depth() -> float:
	return travel * (1.0 - press_fraction * 0.5)


func _sync_evaluator() -> void:
	if _evaluator == null:
		_evaluator = _PokeEvaluator.new()
	_evaluator.press_depth = canonical_press_depth()
	_evaluator.release_depth = canonical_release_depth()
	_evaluator.half_size = Vector2.ZERO  # Round cap: the button bounds it below.
	_evaluator.interpret_drag = false
	# Gate only: a cap's throw is geometry (travel, press_fraction), so a
	# shared project profile must not overwrite the depths derived above.
	_evaluator.apply_profile(poke_profile, false)


## One poke point, in world space, from one source. Public so the button can
## be driven by a test or a custom dispatcher as well as by _physics_process.
func poke_update(source_id: int, world_point: Vector3) -> void:
	_sync_evaluator()
	var local := global_transform.affine_inverse() * world_point
	# Round cap: the button owns this bounds test, the evaluator owns the
	# rest. Leaving the cap's radius is a SHAPE exit, not a reach exit - the
	# finger is still nearby, just off the round cap the evaluator's own
	# half_size can't describe - so it must keep sample history the same way
	# the evaluator's own rectangular-bounds exit does, or a fast approach
	# whose previous sample fell outside the cap can never be rescued by the
	# angle test.
	if Vector2(local.x, local.z).length() > cap_radius + _FINGER_RADIUS:
		_leave_shape(source_id)
		return
	var cap_rest_top := _cap_rest_y + _cap_height * 0.5
	var finger_bottom := local.y - _FINGER_RADIUS
	# Genuinely out of reach (more than 5 cm above the cap) - the source is
	# gone, not merely beside the shape, so this forgets it outright.
	if finger_bottom > cap_rest_top + 0.05:
		poke_end(source_id)
		return
	# Penetration into the cap, clamped. The clamp is the fast-poke fix: a
	# fingertip already below the base is BOTTOMED OUT, not absent, and the
	# old `local.y < -0.01: continue` threw that sample away.
	var penetration := clampf(cap_rest_top - finger_bottom, 0.0, travel)
	_penetrations[source_id] = penetration
	var canonical := Vector3(local.x, local.z, travel - penetration)
	var result: Dictionary = _evaluator.evaluate(source_id, canonical)
	var pinned: Vector3 = result["pinned_point"]
	if pinned == Vector3.INF:
		_pins.erase(source_id)
	else:
		_pins[source_id] = global_transform * Vector3(local.x, cap_rest_top - travel, local.z)
	match int(result["event"]):
		_PokeEvaluator.Event.PRESSED:
			_pressed_sources[source_id] = true
		_PokeEvaluator.Event.RELEASED, _PokeEvaluator.Event.CANCELLED:
			_pressed_sources.erase(source_id)
	_update_pressed_state()


func poke_end(source_id: int) -> void:
	_penetrations.erase(source_id)
	_pins.erase(source_id)
	if _evaluator != null:
		_evaluator.forget(source_id)
		_pressed_sources.erase(source_id)
	_update_pressed_state()


## The source left the cap's round SHAPE but may still be nearby (unlike
## poke_end, which means the source is gone). Keeps the evaluator's sample
## history via leave_bounds() instead of wiping it via forget().
func _leave_shape(source_id: int) -> void:
	_penetrations.erase(source_id)
	_pins.erase(source_id)
	if _evaluator != null:
		var event: int = _evaluator.leave_bounds(source_id)
		if event == _PokeEvaluator.Event.CANCELLED:
			_pressed_sources.erase(source_id)
	_update_pressed_state()


func get_poke_pin(source_id: int) -> Vector3:
	return _pins.get(source_id, Vector3.INF)


## Fires pressed/released on the transitions of _pressed_sources' emptiness.
## Called from poke_update/poke_end directly - not deferred to
## _physics_process - so a caller driving the button straight through
## poke_update (a test, or a custom dispatcher) sees the signal on the same
## call that caused it, exactly like XRPokeable and XRUICanvasInteractable.
func _update_pressed_state() -> void:
	var now_pressed := not _pressed_sources.is_empty()
	if now_pressed and not _is_pressed:
		_is_pressed = true
		_cap_material.albedo_color = pressed_color
		pressed.emit()
	elif not now_pressed and _is_pressed:
		_is_pressed = false
		_cap_material.albedo_color = cap_color
		released.emit()


func _physics_process(_delta: float) -> void:
	if not enabled or _cap == null:
		return
	var source_id := 0
	for source in get_tree().get_nodes_in_group(XRPokeInteractor.GROUP):
		for hand in 2:
			var point: Vector3 = source.get_poke_point(hand)
			if point == Vector3.INF:
				poke_end(source_id)
			else:
				poke_update(source_id, point)
			source_id += 1

	var depth := 0.0
	for penetration in _penetrations.values():
		depth = maxf(depth, penetration)
	_cap.position.y = _cap_rest_y - depth


func _build_visuals() -> void:
	if _cap:
		return
	var base := MeshInstance3D.new()
	base.name = "Base"
	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = cap_radius + 0.01
	base_mesh.bottom_radius = cap_radius + 0.012
	base_mesh.height = _BASE_HEIGHT
	base.mesh = base_mesh
	base.position.y = _BASE_HEIGHT * 0.5
	var base_material := _LINE_MATERIAL.duplicate() as StandardMaterial3D
	base_material.albedo_color = Color(0.2, 0.24, 0.3, 1.0)
	base.material_override = base_material
	add_child(base)

	_cap = MeshInstance3D.new()
	_cap.name = "Cap"
	var cap_mesh := CylinderMesh.new()
	cap_mesh.top_radius = cap_radius
	cap_mesh.bottom_radius = cap_radius + 0.003
	cap_mesh.height = _cap_height
	_cap.mesh = cap_mesh
	_cap_rest_y = _BASE_HEIGHT + travel + _cap_height * 0.5
	_cap.position.y = _cap_rest_y
	_cap_material = _LINE_MATERIAL.duplicate() as StandardMaterial3D
	_cap_material.albedo_color = cap_color
	_cap.material_override = _cap_material
	add_child(_cap)
