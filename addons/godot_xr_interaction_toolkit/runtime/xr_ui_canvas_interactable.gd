@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_ui_canvas_interactable.svg")
class_name XRUICanvasInteractable
extends "res://addons/godot_xr_interaction_toolkit/runtime/xr_base_interactable.gd"

## 3D interactable surface that forwards XR ray hover/select to a SubViewport
## as mouse input, letting ordinary Godot Control buttons/sliders work in XR.

## Preloaded so the shader baker can precompile it for web/WebGPU exports.
const PANEL_MATERIAL := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_ui_panel_material.tres")

@export_group("Panel")
@export var viewport_path: NodePath
@export var panel_mesh_path: NodePath
@export var camera_path: NodePath
@export var panel_size := Vector2(1.6, 0.9)
@export var viewport_pixel_size := Vector2i(1024, 640)

## EXPERIMENTAL A/B (headset-gated optimization): render the SubViewport only
## while its texture is on screen, skipping renders when the panel mesh is
## frustum-culled. Zero visual change is expected but 3D-mesh visibility
## detection is unverified on-device - flip ON during a headset pass to A/B.
## Default OFF ships today's always-render behavior.
@export var render_only_when_visible := false

@export_group("Screen Pointer")
@export var screen_pointer_enabled := true
@export var consume_screen_pointer_events := true

var _viewport: SubViewport
var _panel_mesh: MeshInstance3D
## Every interactor currently hovering this panel, in the order they arrived
## (most recent last). A SubViewport has exactly ONE mouse cursor, so only one
## of these can drive it -- but which one has to stay RECOVERABLE. This used to
## be a single slot, and two rays on one panel wedged it: the second hand
## overwrote the slot, then its exit cleared it to null while the first hand was
## still hovering. The first hand never re-entered (it never left), so nothing
## drove the viewport from it again and its buttons stopped highlighting for the
## rest of the scene. David, on device: "when using both cursors one stops
## working in producing hovers". A stack hands ownership back instead.
var _ui_hovering: Array[Node] = []
var _pressing_interactor: Node
var _pointer_down := false
var _screen_pointer_down := false
var _screen_pointer_index := -1
var _last_pointer_position := Vector2.ZERO
var _last_motion_position := Vector2.ZERO
var _has_motion_position := false

func _ready() -> void:
	super()
	add_to_group("xr_ui_canvas")  # Legacy group; the poke interactor now finds
	# panels by PHYSICS via this meta tag on the collider bodies.
	for body in find_children("*", "CollisionObject3D", true, false):
		(body as CollisionObject3D).set_meta("xr_poke_canvas", self)
	_viewport = get_node_or_null(viewport_path) as SubViewport
	_panel_mesh = get_node_or_null(panel_mesh_path) as MeshInstance3D
	if _viewport:
		_viewport.size = viewport_pixel_size
		if render_only_when_visible:
			_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_apply_viewport_material()

	hover_entered.connect(_on_hover_entered)
	hover_exited.connect(_on_hover_exited)
	select_entered.connect(_on_select_entered)
	select_exited.connect(_on_select_exited)

func _process(_delta: float) -> void:
	var interactor := get_pointer_driver()
	if interactor != null:
		_update_pointer(interactor)

## ---- poke (fingertip) input ---------------------------------------------------
## Driven by XRPokeInteractor: the fingertip presses the panel DIRECTLY -
## crossing the press plane presses at the projected pixel, staying pressed
## while touching (drag = sliders work by touch), retracting releases.

@export_group("Poke Feel")
## Assign to take press depth and the approach gate from one project-wide
## resource. When set it WINS over the exports below.
@export var poke_profile: XRPokeProfile
## How deep (metres) a fingertip must push past the surface to register a
## press, and how far it must retract to release (hysteresis stops flicker).
@export var poke_press_depth := 0.012
@export var poke_release_depth := 0.04
## Max distance in front of the panel that still counts as poking it.
@export var poke_range := 0.09
## Require the fingertip to have been seen in FRONT of the panel before it can
## press, so a hand sweeping across the panel does not press what it crosses.
@export var poke_require_entry_through_face := true
@export_range(0.0, 90.0, 1.0) var poke_max_approach_angle := 60.0
@export_range(0.0, 0.02, 0.0005) var poke_min_approach_travel := 0.003

const _PokeEvaluator := preload("res://addons/godot_xr_interaction_toolkit/runtime/poke/xr_poke_evaluator.gd")
## Far outside any panel: where a CANCELLED release is delivered, so Godot
## Controls clear their pressed state without emitting. This is the standard
## Control contract - a Button fires only when the release lands in its rect.
const _OFF_PANEL := Vector2(-10000.0, -10000.0)

var _poke_evaluator: XRPokeEvaluator
var _poke_pins := {}


func _sync_poke_evaluator() -> void:
	if _poke_evaluator == null:
		_poke_evaluator = _PokeEvaluator.new()
	_poke_evaluator.press_depth = poke_press_depth
	_poke_evaluator.release_depth = poke_release_depth
	_poke_evaluator.half_size = panel_size * 0.5
	_poke_evaluator.require_entry_through_face = poke_require_entry_through_face
	_poke_evaluator.max_approach_angle = poke_max_approach_angle
	_poke_evaluator.min_approach_travel = poke_min_approach_travel
	_poke_evaluator.interpret_drag = false  # The viewport already drags on motion.
	_poke_evaluator.apply_profile(poke_profile)


## World-space fingertip update from a poke source (source_id per hand).
func poke_update(source_id: int, world_point: Vector3) -> void:
	if _viewport == null:
		return
	_sync_poke_evaluator()
	var local := global_transform.affine_inverse() * world_point
	# The panel owns its own REACH test; the evaluator owns the face rectangle.
	if local.z > poke_range or local.z < -0.06:
		poke_end(source_id)
		return
	var result: Dictionary = _poke_evaluator.evaluate(source_id, local)
	var pinned: Vector3 = result["pinned_point"]
	if pinned == Vector3.INF:
		_poke_pins.erase(source_id)
	else:
		_poke_pins[source_id] = global_transform * pinned
	var pixels := map_local_point_to_viewport(local)
	match int(result["event"]):
		_PokeEvaluator.Event.PRESSED:
			_push_mouse_motion(pixels)
			_push_mouse_button(pixels, true)
			_last_pointer_position = pixels
		_PokeEvaluator.Event.RELEASED:
			_push_mouse_motion(pixels)
			_push_mouse_button(pixels, false)
			_last_pointer_position = pixels
		_PokeEvaluator.Event.CANCELLED:
			_poke_pins.erase(source_id)
			_push_mouse_motion(_OFF_PANEL)
			_push_mouse_button(_OFF_PANEL, false)
		_:
			# Per SOURCE, not is_pressed(): with two hands on the panel, one
			# pressed hand would otherwise drag the cursor for the idle one.
			if _poke_evaluator.is_source_pressed(source_id):
				_push_mouse_motion(pixels)  # Drag: sliders track the finger.
				_last_pointer_position = pixels


## The poke source lost its point (hand untracked / moved away).
func poke_end(source_id: int) -> void:
	if _poke_evaluator == null:
		return
	_poke_pins.erase(source_id)
	if _poke_evaluator.forget(source_id) == _PokeEvaluator.Event.CANCELLED:
		_push_mouse_motion(_OFF_PANEL)
		_push_mouse_button(_OFF_PANEL, false)


## World-space point pinned to the panel face while in contact: the raw point
## while the source is in front of the surface, clamped onto the surface
## (z = 0) once it pushes past it. Vector3.INF whenever the source is off the
## face entirely - outside the panel rectangle or outside the working z-band.
func get_poke_pin(source_id: int) -> Vector3:
	return _poke_pins.get(source_id, Vector3.INF)


func _unhandled_input(event: InputEvent) -> void:
	if not screen_pointer_enabled or _viewport == null:
		return

	if event is InputEventMouseMotion:
		_handle_screen_motion(event.position, _screen_pointer_down)
	elif event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			_handle_screen_button(mouse_event.position, mouse_event.pressed)
	elif event is InputEventScreenTouch:
		var touch_event := event as InputEventScreenTouch
		_handle_screen_touch(touch_event.index, touch_event.position, touch_event.pressed)
	elif event is InputEventScreenDrag:
		var drag_event := event as InputEventScreenDrag
		if _screen_pointer_down and drag_event.index == _screen_pointer_index:
			_handle_screen_motion(drag_event.position, true)

func map_local_point_to_viewport(local_point: Vector3) -> Vector2:
	var u := clampf(local_point.x / panel_size.x + 0.5, 0.0, 1.0)
	var v := clampf(0.5 - local_point.y / panel_size.y, 0.0, 1.0)
	return Vector2(u * viewport_pixel_size.x, v * viewport_pixel_size.y)

func map_screen_point_to_viewport(screen_position: Vector2) -> Dictionary:
	var camera := _get_pointer_camera()
	if camera == null:
		return {}

	return map_ray_to_viewport(camera.project_ray_origin(screen_position), camera.project_ray_normal(screen_position))

func map_ray_to_viewport(ray_origin: Vector3, ray_direction: Vector3) -> Dictionary:
	var inv := global_transform.affine_inverse()
	var local_origin: Vector3 = inv * ray_origin
	var local_direction := (global_transform.basis.inverse() * ray_direction).normalized()
	if absf(local_direction.z) < 0.00001:
		return {}

	var distance := -local_origin.z / local_direction.z
	if distance < 0.0:
		return {}

	var local_point := local_origin + local_direction * distance
	var inside := absf(local_point.x) <= panel_size.x * 0.5 and absf(local_point.y) <= panel_size.y * 0.5
	return {
		"position": map_local_point_to_viewport(local_point),
		"inside": inside,
	}

func _apply_viewport_material() -> void:
	if _viewport == null or _panel_mesh == null:
		return

	# Preloaded so the shader baker can precompile it for web/WebGPU exports;
	# the viewport texture is a uniform, so assigning it keeps the baked hash.
	var material := PANEL_MATERIAL.duplicate() as StandardMaterial3D
	material.albedo_texture = _viewport.get_texture()
	_panel_mesh.set_surface_override_material(0, material)

func _get_pointer_camera() -> Camera3D:
	if not camera_path.is_empty():
		var configured_camera := get_node_or_null(camera_path) as Camera3D
		if configured_camera != null:
			return configured_camera
	return get_viewport().get_camera_3d()

## The single interactor allowed to move the viewport's mouse right now: a press
## always wins (you must not lose the cursor mid-click to the other hand), else
## the most recent hand to arrive. Freed interactors are dropped here rather
## than on a signal -- a scene change frees them without ever emitting exit.
func get_pointer_driver() -> Node:
	if _pressing_interactor != null and is_instance_valid(_pressing_interactor):
		return _pressing_interactor
	while not _ui_hovering.is_empty():
		# Deliberately untyped: a freed node still sits in the array, and
		# assigning one to a `Node`-typed local is itself an error in GDScript.
		var candidate = _ui_hovering.back()
		if is_instance_valid(candidate):
			return candidate
		_ui_hovering.pop_back()
	return null

func _push_ui_hover(interactor) -> void:
	# Erase-then-append, so a re-entering hand goes back on TOP instead of
	# sitting under a stale duplicate of itself.
	_ui_hovering.erase(interactor)
	_ui_hovering.append(interactor)

func _on_hover_entered(interactor) -> void:
	_push_ui_hover(interactor)
	_update_pointer(interactor)

func _on_hover_exited(interactor) -> void:
	_ui_hovering.erase(interactor)
	# Hand the cursor straight back to whoever is still on the panel. Without
	# this the surviving hand keeps a drawn ray and reticle but stops moving the
	# viewport mouse, which reads as "that hand can no longer hover anything".
	var next := get_pointer_driver()
	if next != null:
		_update_pointer(next)

func _on_select_entered(interactor) -> void:
	_pressing_interactor = interactor
	# A press also claims hover ownership, so releasing leaves the cursor with
	# the hand that just clicked rather than snapping back to the idle hand.
	_push_ui_hover(interactor)
	if _update_pointer(interactor):
		_push_mouse_button(_last_pointer_position, true)
		_push_mouse_motion(_last_pointer_position)

func _on_select_exited(interactor) -> void:
	if interactor == _pressing_interactor:
		_update_pointer(interactor)
		_push_mouse_button(_last_pointer_position, false)
		_pressing_interactor = null

func _update_pointer(interactor: Node) -> bool:
	# Both branches below map through global_transform, which on an out-of-tree
	# panel returns IDENTITY rather than failing -- so the cursor would be
	# placed by treating the panel as if it sat at the world origin. A scene
	# change reaches here: tearing the scene down emits hover_exited, and the
	# handback hands the cursor to the next interactor on a panel that is
	# already leaving. _push_mouse_button carries the same guard for the same
	# reason; this is the read side of it.
	if _viewport == null or not is_inside_tree():
		return false
	if interactor == null or not interactor.has_method("get_ray_state"):
		return false

	var ray_state: Dictionary = interactor.get_ray_state()
	if not ray_state.get("valid", false):
		return false

	# Map from the ACTUAL hit point (where the reticle sits), not by re-
	# intersecting the flat mesh plane. Re-intersecting put the click cursor
	# off from the reticle by the collider's depth at glancing angles - with
	# the hand ray's downward pitch that read as a vertical offset.
	if ray_state.get("hit", false) and ray_state.has("end"):
		var local: Vector3 = global_transform.affine_inverse() * (ray_state["end"] as Vector3)
		_last_pointer_position = map_local_point_to_viewport(local)
	else:
		var mapped := map_ray_to_viewport(ray_state["origin"], ray_state["direction"])
		if mapped.is_empty():
			return false
		_last_pointer_position = mapped["position"]
	_push_mouse_motion(_last_pointer_position)
	return true

func _handle_screen_motion(screen_position: Vector2, dragging: bool) -> void:
	var mapped := map_screen_point_to_viewport(screen_position)
	if mapped.is_empty():
		return
	if not dragging and not mapped.get("inside", false):
		return

	_last_pointer_position = mapped["position"]
	_push_mouse_motion(_last_pointer_position)
	_mark_screen_input_handled()

func _handle_screen_button(screen_position: Vector2, pressed: bool) -> void:
	var mapped := map_screen_point_to_viewport(screen_position)
	if pressed:
		if mapped.is_empty() or not mapped.get("inside", false):
			return
		_screen_pointer_down = true
	elif not _screen_pointer_down:
		return

	if not mapped.is_empty():
		_last_pointer_position = mapped["position"]
		_push_mouse_motion(_last_pointer_position)
	_push_mouse_button(_last_pointer_position, pressed)
	if pressed:
		_push_mouse_motion(_last_pointer_position)
	_screen_pointer_down = pressed
	_mark_screen_input_handled()

func _handle_screen_touch(index: int, screen_position: Vector2, pressed: bool) -> void:
	if pressed:
		if _screen_pointer_down:
			return
		var mapped := map_screen_point_to_viewport(screen_position)
		if mapped.is_empty() or not mapped.get("inside", false):
			return
		_screen_pointer_down = true
		_screen_pointer_index = index
		_last_pointer_position = mapped["position"]
		_push_mouse_motion(_last_pointer_position)
		_push_mouse_button(_last_pointer_position, true)
		_push_mouse_motion(_last_pointer_position)
		_mark_screen_input_handled()
	elif _screen_pointer_down and index == _screen_pointer_index:
		var mapped := map_screen_point_to_viewport(screen_position)
		if not mapped.is_empty():
			_last_pointer_position = mapped["position"]
			_push_mouse_motion(_last_pointer_position)
		_push_mouse_button(_last_pointer_position, false)
		_screen_pointer_down = false
		_screen_pointer_index = -1
		_mark_screen_input_handled()

func _mark_screen_input_handled() -> void:
	if consume_screen_pointer_events:
		get_viewport().set_input_as_handled()

func _push_mouse_motion(position: Vector2) -> void:
	if _viewport == null or not _viewport.is_inside_tree():
		return

	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	event.relative = position - _last_motion_position if _has_motion_position else Vector2.ZERO
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if _pointer_down else 0
	_viewport.push_input(event, true)
	_last_motion_position = position
	_has_motion_position = true

func _push_mouse_button(position: Vector2, pressed: bool) -> void:
	# A deselect can arrive after the panel (and its viewport) has left the tree -
	# e.g. the scene changes while a grab/select is still held. push_input on an
	# out-of-tree viewport errors, so bail; there is nothing to release anyway.
	if _viewport == null or not _viewport.is_inside_tree() or _pointer_down == pressed:
		return

	_pointer_down = pressed
	var event := InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.pressed = pressed
	_viewport.push_input(event, true)
