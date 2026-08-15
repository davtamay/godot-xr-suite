@tool
@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_ui_canvas_interactable.svg")
class_name XRDrawingSurface
extends MeshInstance3D

## A notepad you can draw on with a pen. Drop it, give it a PlaneMesh, and any
## node in the "xr_pen_tip" group (a Pen's nib) paints ink where it touches the
## surface. The paper is a runtime ImageTexture swapped onto a pre-baked
## material, so it renders on WebGPU exports too.
##
## The pen tip draws when it comes within `draw_distance` of the plane's face
## and inside its extents; strokes are interpolated so fast lines stay solid.

## Group a pen's tip node joins so drawing surfaces find it.
const PEN_TIP_GROUP := "xr_pen_tip"
const _BASE_MATERIAL := preload("res://addons/godot_xr_interaction_toolkit/runtime/drawing_surface_material.tres")

## Pixels along the longer edge of the paper.
@export var draw_resolution := 512
## Paper (background) colour.
@export var paper_color := Color(0.98, 0.97, 0.94)
## Ink colour a pen lays down.
@export var ink_color := Color(0.1, 0.14, 0.32)
## Brush radius in pixels.
@export_range(1, 24) var ink_radius_px := 4
## How close (metres) the pen tip must be to the surface to draw.
@export var draw_distance := 0.012

var _image: Image
var _texture: ImageTexture
var _size := Vector2(0.3, 0.4)
var _img_w := 1
var _img_h := 1
var _last := {}       # tip instance id -> last pixel (Vector2i)
var _painted := false
var _dirty := false
var _material: StandardMaterial3D


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	var plane := mesh as PlaneMesh
	if plane == null:
		plane = PlaneMesh.new()
		plane.size = _size
		mesh = plane
	_size = plane.size
	var longest := maxf(_size.x, _size.y)
	_img_w = maxi(1, int(draw_resolution * _size.x / longest))
	_img_h = maxi(1, int(draw_resolution * _size.y / longest))
	_image = Image.create(_img_w, _img_h, false, Image.FORMAT_RGBA8)
	_image.fill(paper_color)
	_texture = ImageTexture.create_from_image(_image)
	_material = _BASE_MATERIAL.duplicate() as StandardMaterial3D
	_material.albedo_texture = _texture
	material_override = _material
	set_process(true)


## Wipe the paper back to blank.
func clear() -> void:
	if _image == null:
		return
	_image.fill(paper_color)
	_last.clear()
	_refresh()


## Rebuild the texture from the image and re-point the material at it. In-place
## ImageTexture.update() does NOT reliably refresh a live material here, so we
## recreate the texture (a fresh GPU upload) once per frame when something drew.
func _refresh() -> void:
	_texture = ImageTexture.create_from_image(_image)
	if _material:
		_material.albedo_texture = _texture
	_dirty = false


func _process(_delta: float) -> void:
	_painted = false
	var active := {}
	for tip in get_tree().get_nodes_in_group(PEN_TIP_GROUP):
		var node := tip as Node3D
		if node == null:
			continue
		var local := to_local(node.global_position)
		if absf(local.y) > draw_distance:
			continue
		var u := local.x / _size.x + 0.5
		var v := local.z / _size.y + 0.5
		if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
			continue
		var pixel := Vector2i(int(u * _img_w), int(v * _img_h))
		var id := node.get_instance_id()
		active[id] = pixel
		if _last.has(id):
			_stroke(_last[id], pixel)
		else:
			_dot(pixel)
	_last = active
	# Refresh once per frame if a pen (_painted) or a sprayer (_dirty) drew.
	if _painted or _dirty:
		_refresh()


## Paint a soft mark where a world-space point projects onto the surface, for
## sprayers / decals / splats (no touching needed). Soft, alpha-blended edges so
## overlapping sprays build up. Returns true if it landed on the paper.
func paint_at_world(world_pos: Vector3, radius_px: int, color: Color) -> bool:
	if _image == null:
		return false
	var local := to_local(world_pos)
	var u := local.x / _size.x + 0.5
	var v := local.z / _size.y + 0.5
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		return false
	_soft_dot(Vector2i(int(u * _img_w), int(v * _img_h)), radius_px, color)
	_dirty = true
	return true


func _soft_dot(center: Vector2i, r: int, color: Color) -> void:
	var r2 := float(maxi(1, r * r))
	for dy in range(-r, r + 1):
		var yy := center.y + dy
		if yy < 0 or yy >= _img_h:
			continue
		for dx in range(-r, r + 1):
			var xx := center.x + dx
			if xx < 0 or xx >= _img_w:
				continue
			var d2 := float(dx * dx + dy * dy)
			if d2 > r2:
				continue
			var a := color.a * (1.0 - d2 / r2)
			_image.set_pixel(xx, yy, _image.get_pixel(xx, yy).lerp(color, clampf(a, 0.0, 1.0)))
	_painted = true


func _stroke(from_pixel: Vector2i, to_pixel: Vector2i) -> void:
	var span := (Vector2(to_pixel) - Vector2(from_pixel)).length()
	var steps := maxi(1, int(span))
	for i in steps + 1:
		_dot(Vector2i(Vector2(from_pixel).lerp(Vector2(to_pixel), float(i) / steps)))


func _dot(center: Vector2i) -> void:
	var r := ink_radius_px
	var r2 := r * r
	for dy in range(-r, r + 1):
		var yy := center.y + dy
		if yy < 0 or yy >= _img_h:
			continue
		for dx in range(-r, r + 1):
			var xx := center.x + dx
			if xx < 0 or xx >= _img_w:
				continue
			if dx * dx + dy * dy <= r2:
				_image.set_pixel(xx, yy, ink_color)
	_painted = true
