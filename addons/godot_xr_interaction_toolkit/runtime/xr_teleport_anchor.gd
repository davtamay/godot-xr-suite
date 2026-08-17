@tool
@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_locomotion.svg")
class_name XRTeleportAnchor
extends Node3D

## A FIXED teleport destination - Unity XRI's TeleportationAnchor as a drop-in
## block. Where the free teleport arc lets you land anywhere on a surface, an
## anchor is a discrete spot: aim the arc at it and you SNAP to this exact
## point, optionally turned to FACE the anchor's forward (-Z). Great for seats,
## viewpoints, doorways, puzzle stations - anywhere the author wants a precise,
## repeatable stance instead of "somewhere over there".
##
## Drop it anywhere in a scene that has an XRLocomotion (every rig/prefab does).
## It self-wires: builds its own collider on the teleport layer, and the
## locomotion arc recognises it with zero setup. The node's ORIGIN is the
## landing point; its blue arrow shows the forward the user will face.
##
## Place it standing ON the floor. Rotate the whole node to aim the facing.

## Off = the anchor is inert (no collider, invisible); the arc ignores it and
## falls through to normal free-surface teleport.
@export var enabled := true:
	set(value):
		enabled = value
		_rebuild()

## Landing radius. Bigger = easier to hit with the arc; the ring shows it.
@export_range(0.15, 1.5, 0.05) var anchor_radius := 0.4:
	set(value):
		anchor_radius = value
		_rebuild()

## Turn the rig so the camera faces this anchor's forward (-Z) on arrival.
## Off = keep the user's current facing, just move them here.
@export var force_facing := true:
	set(value):
		force_facing = value
		_rebuild()

## Physics layer the collider sits on; must intersect the locomotion's
## teleport collision_mask (default layer 1) for the arc to hit it.
@export_flags_3d_physics var collision_layer := 1:
	set(value):
		collision_layer = value
		_rebuild()

@export_group("Appearance")
@export var idle_color := Color(0.3, 0.55, 1.0, 0.85):
	set(value):
		idle_color = value
		_apply_colors()
## Colour while the arc is aimed at this anchor (about to land here).
@export var active_color := Color(0.35, 1.0, 0.6, 0.95):
	set(value):
		active_color = value
		_apply_colors()

const _META_KEY := "xr_teleport_anchor"

var _body: StaticBody3D
var _ring: MeshInstance3D
var _arrow: Node3D
var _ring_material: StandardMaterial3D
var _arrow_material: StandardMaterial3D
var _highlighted := false


## An anchor is a place, not a thing to hold: it is reached by aiming a teleport
## arc at it and letting the stick go. The point is where a driver should AIM,
## so it is the anchor's own landing spot rather than a collider centre.
func drive_hint() -> Dictionary:
	return {
		"kind": "teleport",
		"gesture": "stick",
		"point": global_position,
		"radius": anchor_radius,
	}


func _ready() -> void:
	_rebuild()


## The exact world point the camera lands on (floor-plane height = this Y).
func snap_position() -> Vector3:
	return global_position


## Horizontal forward the rig turns to face on arrival.
func facing_forward() -> Vector3:
	return -global_transform.basis.z


## Whether locomotion should apply the forced facing.
func wants_facing() -> bool:
	return force_facing


## Called by XRLocomotion when the arc hovers/leaves this anchor.
func set_highlighted(on: bool) -> void:
	if _highlighted == on:
		return
	_highlighted = on
	_apply_colors()


func _rebuild() -> void:
	if not is_node_ready():
		return
	# Clear anything we generated previously (idempotent across edits).
	for child in [_body, _ring, _arrow]:
		if child and is_instance_valid(child):
			child.queue_free()
	_body = null
	_ring = null
	_arrow = null
	if not enabled:
		return

	# Visible landing ring (both editor + runtime = authors see the spot).
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = anchor_radius * 0.82
	ring_mesh.outer_radius = anchor_radius
	ring_mesh.rings = 32
	ring_mesh.ring_segments = 8
	_ring = MeshInstance3D.new()
	_ring.name = "AnchorRing"
	_ring.mesh = ring_mesh
	_ring.position.y = 0.01
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring_material = _make_material()
	_ring.material_override = _ring_material
	add_child(_ring)

	# Bold facing arrow (flat on the floor, pointing -Z = the way you'll face),
	# shown only when facing is forced. Shaft + head, opaque and bright, its
	# tip reaching past the ring so the direction is unmistakable.
	if force_facing:
		_arrow_material = _make_arrow_material()
		_arrow = Node3D.new()
		_arrow.name = "AnchorArrow"

		var shaft_mesh := BoxMesh.new()
		shaft_mesh.size = Vector3(0.05, 0.014, anchor_radius * 0.9)
		var shaft := MeshInstance3D.new()
		shaft.mesh = shaft_mesh
		shaft.position = Vector3(0.0, 0.025, -anchor_radius * 0.45)
		shaft.material_override = _arrow_material
		shaft.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_arrow.add_child(shaft)

		var head_mesh := PrismMesh.new()
		head_mesh.size = Vector3(0.2, 0.014, 0.24)
		var head := MeshInstance3D.new()
		head.mesh = head_mesh
		# Prism apex points +Y; -90 deg about X lays it flat pointing -Z.
		head.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
		head.position = Vector3(0.0, 0.025, -anchor_radius - 0.02)
		head.material_override = _arrow_material
		head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_arrow.add_child(head)

		add_child(_arrow)

	# Collider the teleport arc hits - runtime only, tagged so locomotion
	# recognises this as an anchor without any manager or wiring.
	if not Engine.is_editor_hint():
		var shape := CylinderShape3D.new()
		shape.radius = anchor_radius
		shape.height = 0.08
		var collision := CollisionShape3D.new()
		collision.shape = shape
		collision.position.y = 0.04
		_body = StaticBody3D.new()
		_body.name = "AnchorBody"
		_body.collision_layer = collision_layer
		_body.collision_mask = 0
		_body.set_meta(_META_KEY, self)
		_body.add_child(collision)
		add_child(_body)

	_apply_colors()


func _make_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = idle_color
	material.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
	return material


## The arrow reads as a solid, bright directional cue - opaque, no fade.
func _make_arrow_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(idle_color.r, idle_color.g, idle_color.b, 1.0)
	return material


func _apply_colors() -> void:
	var color := active_color if _highlighted else idle_color
	if _ring_material:
		_ring_material.albedo_color = color
	if _arrow_material:
		_arrow_material.albedo_color = Color(color.r, color.g, color.b, 1.0)
