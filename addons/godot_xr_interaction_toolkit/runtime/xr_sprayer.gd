@tool
@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_ui_canvas_interactable.svg")
class_name XRSprayer
extends Node

## Turns a grabbable into a spray can - the CONTINUOUS twin of XRBlaster. While
## the object is ACTIVATED (a controller trigger held, or a bare-hand pull via an
## XRHandActivator set to CONTINUOUS), it sprays from the nozzle: raycasts
## forward and paints any XRDrawingSurface it hits, and shows an optional spray
## visual. Same grab-it-then-use-it parts as the blaster; here the effect is
## continuous paint instead of a one-shot projectile - proof the pieces compose.

## The Node3D the spray leaves; it sprays along its -Z (forward).
@export var nozzle_path: NodePath
@export var spray_color := Color(0.9, 0.2, 0.28, 0.5)
## How far the spray reaches (metres).
@export_range(0.1, 6.0, 0.05) var spray_range := 2.5
## Spray cone half-angle (degrees): the paint disc widens with distance, like a
## real can - close up it's tight, farther away it fans out and thins.
@export_range(0.5, 20.0, 0.5) var spray_cone_deg := 4.5
## Soft droplets stamped each frame - the grainy spray that builds up on a sweep.
@export_range(1, 24, 1) var droplets := 8
## Each droplet's soft radius in the surface's texture pixels.
@export_range(1, 20, 1) var droplet_radius_px := 4
@export_flags_3d_physics var collision_mask := 1
## Optional mesh/particles shown ONLY while spraying (the visible mist/cone).
@export var spray_visual_path: NodePath

signal spray_started()
signal spray_stopped()

var _interactable: Node
var _nozzle: Node3D
var _visual: Node3D
var _spraying := false
var _exclude: Array[RID] = []


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	var cursor := get_parent()
	while cursor != null and not cursor.has_signal("activated"):
		cursor = cursor.get_parent()
	_interactable = cursor
	_nozzle = get_node_or_null(nozzle_path) as Node3D
	_visual = get_node_or_null(spray_visual_path) as Node3D
	if _visual:
		_visual.visible = false
	# Aim the nozzle (and its mist) along the GRIP forward, not the can's own axis,
	# so the spray goes where the hand points no matter how the grab is tuned or
	# tilted. Done once from the grab point's rest orientation - both are rigid on
	# the can, so the alignment holds when it's picked up.
	_align_nozzle_to_grip()
	# Don't let the ray hit the can it's mounted on.
	if _interactable and _interactable.has_method("get_colliders"):
		for c in _interactable.get_colliders():
			if c:
				_exclude.append((c as CollisionObject3D).get_rid())
	# Spray while the interactable is held-active (activate_entered/exited comes
	# from a held controller trigger OR an XRHandActivator in CONTINUOUS mode).
	if _interactable and _interactable.has_signal("activate_entered"):
		_interactable.activate_entered.connect(func(_i): _set_spraying(true))
		_interactable.activate_exited.connect(func(_i): _set_spraying(false))
	set_physics_process(true)


func _align_nozzle_to_grip() -> void:
	if _nozzle == null or _interactable == null:
		return
	for node in _interactable.find_children("*", "Node3D", true, false):
		var script := node.get_script()
		if script and (script as Resource).resource_path.ends_with("xr_grab_point.gd"):
			var t := _nozzle.global_transform
			t.basis = (node as Node3D).global_transform.basis.orthonormalized()
			_nozzle.global_transform = t
			return


func _set_spraying(on: bool) -> void:
	if on == _spraying:
		return
	_spraying = on
	if _visual:
		_visual.visible = on
	if on:
		spray_started.emit()
	else:
		spray_stopped.emit()


func _physics_process(_delta: float) -> void:
	if not _spraying or _nozzle == null:
		return
	var world := _nozzle.get_world_3d()
	if world == null:
		return
	var basis := _nozzle.global_transform.basis
	var from := _nozzle.global_position
	var dir := (-basis.z).normalized()
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * spray_range, collision_mask)
	query.exclude = _exclude
	var hit := world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	var surface := _find_surface(hit.get("collider"))
	if surface == null:
		return
	# Scatter soft droplets over a disc that widens with distance (the cone), most
	# landing near the aim point - a grainy spray that builds up as you sweep,
	# instead of a single hard splat.
	var hit_pos: Vector3 = hit["position"]
	var spread: float = from.distance_to(hit_pos) * tan(deg_to_rad(spray_cone_deg))
	for i in droplets:
		var ang := randf() * TAU
		var rad := randf() * spread  # linear radius -> denser toward the centre
		var offset := basis.x * (cos(ang) * rad) + basis.y * (sin(ang) * rad)
		surface.paint_at_world(hit_pos + offset, droplet_radius_px, spray_color)


## Locate an XRDrawingSurface at/around a hit collider (the surface itself, a
## sibling under a StaticBody, or an ancestor).
func _find_surface(collider) -> Node:
	var node := collider as Node
	while node != null:
		if node is XRDrawingSurface:
			return node
		for child in node.get_children():
			if child is XRDrawingSurface:
				return child
		node = node.get_parent()
	return null


func _get_configuration_warnings() -> PackedStringArray:
	var cursor := get_parent()
	while cursor != null:
		if cursor.has_signal("activated"):
			return PackedStringArray()
		cursor = cursor.get_parent()
	return PackedStringArray(["Place this INSIDE a grab interactable (any ancestor)."])
