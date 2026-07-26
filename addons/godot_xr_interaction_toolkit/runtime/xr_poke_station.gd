@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_poke_interactor.svg")
class_name XRPokeStation
extends Node3D

## A self-contained fingertip-poke demo station: three physical 3D push-buttons
## (counter, momentary light, colour cycle) + a touch panel whose buttons and
## slider you press by TOUCH, all driving a demo orb. Packaged as one droppable
## block (like XRLightLab) so it can share a scene with other control blocks.
##
## Expected children (built into the scene): Stand/CounterButton,
## Stand/LightButton, Stand/ColorButton (XRPokeButton), Stand/CounterLabel,
## Orb (+ Orb/OrbLight), TouchPanel (an xr_ui_panel with Viewport/Root).

const _ORB_MATERIAL := preload("res://addons/godot_xr_interaction_toolkit/runtime/highlight_affordance_material.tres")
const _COLORS := [Color(0.3, 0.8, 1.0), Color(1.0, 0.55, 0.2), Color(0.5, 1.0, 0.5), Color(1.0, 0.4, 0.8)]

# Gate demo: bake-safe material (see XRPokeButton._build_visuals) and the
# sample geometry's tuning constants.
const _LINE_MATERIAL := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_line_material.tres")
const _GATE_DEMO_POSITION := Vector3(0.95, 1.0, -0.3)
const _KEY_COUNT := 5
const _KEY_SPACING := 0.035
const _KEY_SIZE := Vector3(0.03, 0.03, 0.01)
const _HANDLE_SIZE := Vector3(0.12, 0.02, 0.01)
const _CANCEL_SIZE := Vector3(0.06, 0.06, 0.01)

var _counter_button: XRPokeButton
var _light_button: XRPokeButton
var _color_button: XRPokeButton
var _counter_label: Label3D
var _orb: MeshInstance3D
var _orb_light: OmniLight3D

var _count := 0
var _color_index := 0
var _orb_material: StandardMaterial3D
var _slider_label: Label


func _ready() -> void:
	_counter_button = get_node_or_null("Stand/CounterButton")
	_light_button = get_node_or_null("Stand/LightButton")
	_color_button = get_node_or_null("Stand/ColorButton")
	_counter_label = get_node_or_null("Stand/CounterLabel")
	_orb = get_node_or_null("Orb")
	_orb_light = get_node_or_null("Orb/OrbLight")

	_build_gate_demo()

	if _orb:
		_orb_material = _ORB_MATERIAL.duplicate() as StandardMaterial3D
		_orb_material.albedo_color = _COLORS[0]
		_orb.set_surface_override_material(0, _orb_material)

	if _counter_button:
		_counter_button.pressed.connect(func() -> void:
			_count += 1
			if _counter_label:
				_counter_label.text = "POKES: %d" % _count)
	if _light_button and _orb_light:
		_light_button.pressed.connect(func() -> void: _orb_light.visible = true)
		_light_button.released.connect(func() -> void: _orb_light.visible = false)
	if _color_button:
		_color_button.pressed.connect(func() -> void:
			_color_index = (_color_index + 1) % _COLORS.size()
			if _orb_material:
				_orb_material.albedo_color = _COLORS[_color_index]
			if _orb_light:
				_orb_light.light_color = _COLORS[_color_index])

	_build_panel_ui()


func _build_panel_ui() -> void:
	var root: Control = get_node_or_null("TouchPanel/Viewport/Root")
	if root == null or _orb == null:
		return
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 24)
	root.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	margin.add_child(column)

	var title := Label.new()
	title.text = "TOUCH PANEL - poke the buttons, DRAG the slider with your fingertip"
	title.add_theme_font_size_override("font_size", 24)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	column.add_child(row)
	for entry in [["BIGGER", 1.25], ["SMALLER", 0.8]]:
		var button := Button.new()
		button.text = entry[0]
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.custom_minimum_size = Vector2(0, 72)
		button.add_theme_font_size_override("font_size", 26)
		button.pressed.connect(func() -> void:
			_orb.scale = (_orb.scale * (entry[1] as float)).clamp(Vector3.ONE * 0.4, Vector3.ONE * 2.5))
		row.add_child(button)

	_slider_label = Label.new()
	_slider_label.text = "ORB HEIGHT: 50%"
	_slider_label.add_theme_font_size_override("font_size", 24)
	column.add_child(_slider_label)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 100.0
	slider.value = 50.0
	slider.custom_minimum_size = Vector2(0, 64)
	slider.value_changed.connect(func(value: float) -> void:
		_slider_label.text = "ORB HEIGHT: %d%%" % int(value)
		_orb.position.y = 1.0 + value * 0.012)
	column.add_child(slider)


## The three first consumers of XRPokeable in the whole suite. Each exists to
## make one gate behaviour visible in-headset rather than only in a test:
## a row too dense to sweep without the approach gate, a handle whose drag
## suppresses the terminal release, and a target that shows a slide-off
## cancels instead of firing. Built in code - the precedent is
## XRPokeButton._build_visuals() - so the station stays a self-contained
## droppable block instead of depending on hand-authored scene children.
## Placed clear of Stand/TouchPanel/Orb: Stand's buttons span roughly
## x in [-0.21, 0.21] at this node's local (0, ~1.03, ~-0.54), and TouchPanel
## sits near local x = 0 too, so _GATE_DEMO_POSITION's x = 0.95 clears both.
func _build_gate_demo() -> void:
	var group := Node3D.new()
	group.name = "GateDemo"
	group.position = _GATE_DEMO_POSITION
	add_child(group)
	_build_dense_row(group)
	_build_drag_handle(group)
	_build_cancel_target(group)


## A body pokeable can attach to: a box mesh + matching box shape, on the
## poke_collision_mask default layer (1) so XRPokeInteractor's sphere query
## actually finds it. Returns the mesh and material directly (rather than
## making every caller re-fetch and re-cast the mesh's material_override)
## since every caller's whole reason for building this body is to recolor -
## or, for the drag handle, also reposition - that mesh from a signal.
func _make_gate_body(node_name: String, size: Vector3, color: Color) -> Dictionary:
	var body := StaticBody3D.new()
	body.name = node_name
	body.collision_layer = 1

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Mesh"
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh_instance.mesh = box_mesh
	var material := _LINE_MATERIAL.duplicate() as StandardMaterial3D
	material.albedo_color = color
	mesh_instance.material_override = material
	body.add_child(mesh_instance)

	var collision := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	collision.shape = box_shape
	body.add_child(collision)

	return {"body": body, "material": material, "mesh": mesh_instance}


func _make_gate_caption(text: String, at: Vector3) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.position = at
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = 0.0012
	label.font_size = 22
	label.outline_size = 8
	return label


## Five keys 0.035 m apart - closer together than their own 0.03 m width - so
## a hand sweeping across the row cannot press one without the approach gate
## (require_entry_through_face / max_approach_angle) rejecting the sweep.
func _build_dense_row(parent: Node3D) -> void:
	var row := Node3D.new()
	row.name = "DenseRow"
	row.position = Vector3(0, 0.3, 0)
	parent.add_child(row)

	var rest_color := Color(0.3, 0.8, 1.0)
	var pressed_color := Color(0.4, 1.0, 0.6)
	var span := float(_KEY_COUNT - 1) * _KEY_SPACING
	for i in _KEY_COUNT:
		var made := _make_gate_body("Key%d" % i, _KEY_SIZE, rest_color)
		var body: StaticBody3D = made["body"]
		var material: StandardMaterial3D = made["material"]
		body.position = Vector3(i * _KEY_SPACING - span * 0.5, 0, 0)
		row.add_child(body)

		var pokeable := XRPokeable.new()
		pokeable.poke_face = XRPokeable.Face.Z_PLUS
		pokeable.half_size = Vector2(0.015, 0.015)
		body.add_child(pokeable)

		pokeable.pressed.connect(func(_hand: int) -> void: material.albedo_color = pressed_color)
		pokeable.released.connect(func(_hand: int) -> void: material.albedo_color = rest_color)

	row.add_child(_make_gate_caption("SWEEP ME - only a poke through the face presses", Vector3(0, 0.045, 0)))


## interpret_drag = true: dragging the handle reports `dragged` and suppresses
## the terminal `released` - a handle is not a button, so let-go must not fire.
func _build_drag_handle(parent: Node3D) -> void:
	var rest_color := Color(1.0, 0.7, 0.2)
	var held_color := Color(1.0, 0.35, 0.1)
	var made := _make_gate_body("DragHandle", _HANDLE_SIZE, rest_color)
	var body: StaticBody3D = made["body"]
	var material: StandardMaterial3D = made["material"]
	var mesh_instance: MeshInstance3D = made["mesh"]
	body.position = Vector3(0, 0.05, 0)
	parent.add_child(body)

	var pokeable := XRPokeable.new()
	pokeable.interpret_drag = true
	pokeable.drag_threshold = 0.01
	pokeable.half_size = Vector2(0.06, 0.01)
	body.add_child(pokeable)

	pokeable.pressed.connect(func(_hand: int) -> void: material.albedo_color = held_color)
	pokeable.released.connect(func(_hand: int) -> void: material.albedo_color = rest_color)
	pokeable.cancelled.connect(func(_hand: int) -> void: material.albedo_color = rest_color)
	# The visible payload: the cap slides along the face's own u-axis as you
	# drag, and - the whole point of this target - let-go never fires
	# pressed/released once dragging has started (see the evaluator's
	# interpret_drag branch), so nothing here waits for a terminal signal.
	# `dragged`'s delta is the CUMULATIVE offset since the press began (the
	# evaluator captures press_planar once, at press, and every subsequent
	# poke_update - one per physics tick while held - re-emits point - that
	# same fixed origin), not a per-tick increment. So this SETS the position
	# from a fixed rest_x captured once, rather than accumulating delta on
	# every tick: accumulating would advance by ~delta.x per frame even while
	# the finger is motionless, saturating the clamp in a handful of frames.
	var rest_x := mesh_instance.position.x
	pokeable.dragged.connect(func(_hand: int, delta: Vector2) -> void:
		mesh_instance.position.x = clampf(rest_x + delta.x, -0.04, 0.04))

	body.add_child(_make_gate_caption("DRAG ME - a handle does not fire on let-go", Vector3(0, 0.035, 0)))


## Default XRPokeable settings: this is the plain gate, no per-target
## overrides. Pressing all the way through and releasing shows green (fired);
## pressing then sliding off the face shows red (cancelled, never fired).
## Deliberate: the default half_size (0.05) is left as-is, so the poke
## rectangle extends ~0.02 m past each edge of the visible 0.06 m box - this
## is what "default settings" means here, not an oversight, but it does mean
## the finger has to slide further than the box looks like it should before
## a poke leaving the rectangle counts as a slide-off.
func _build_cancel_target(parent: Node3D) -> void:
	var rest_color := Color(0.8, 0.8, 0.85)
	var fired_color := Color(0.4, 1.0, 0.6)
	var cancelled_color := Color(1.0, 0.3, 0.3)
	var made := _make_gate_body("CancelTarget", _CANCEL_SIZE, rest_color)
	var body: StaticBody3D = made["body"]
	var material: StandardMaterial3D = made["material"]
	body.position = Vector3(0, -0.25, 0)
	parent.add_child(body)

	var pokeable := XRPokeable.new()
	body.add_child(pokeable)

	pokeable.released.connect(func(_hand: int) -> void: material.albedo_color = fired_color)
	pokeable.cancelled.connect(func(_hand: int) -> void: material.albedo_color = cancelled_color)

	body.add_child(_make_gate_caption("PRESS THEN SLIDE OFF - it cancels, it does not fire", Vector3(0, 0.045, 0)))
