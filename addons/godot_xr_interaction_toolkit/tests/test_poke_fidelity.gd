extends SceneTree

## Headless tests for poke fidelity (docs/poke-fidelity-design.md).
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_interaction_toolkit/tests/test_poke_fidelity.gd

const XRPokeEvaluator := preload("res://addons/godot_xr_interaction_toolkit/runtime/poke/xr_poke_evaluator.gd")
const XRPokeProfile := preload("res://addons/godot_xr_interaction_toolkit/runtime/poke/xr_poke_profile.gd")
const XRPokeableScript := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_pokeable.gd")
const XRUICanvasScript := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_ui_canvas_interactable.gd")
const XRPokeButtonScript := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_poke_button.gd")
const XRPokeInteractorScript := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_poke_interactor.gd")
const XRPokeStationScript := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_poke_station.gd")

## Records every mouse motion the panel pushes into its viewport -- used by
## the two-source drag test to prove the poke_update drag branch (its `_:`
## default case) gates on is_source_pressed(source_id), not is_pressed().
## _last_pointer_position is not usable for that assertion: finding 1 makes
## it track unconditionally on every in-range call regardless of WHICH
## source called poke_update, so it always reflects whichever source called
## in last and cannot distinguish "source 1 was merely looked at" from
## "source 1 dragged the cursor". Only the actual InputEventMouseMotion
## reaching the viewport proves whether the cursor moved.
class _MotionProbe extends Control:
	var positions: Array[Vector2] = []

	func _input(event: InputEvent) -> void:
		if event is InputEventMouseMotion:
			positions.append((event as InputEventMouseMotion).position)

var _failures: Array[String] = []
var _tree_tests_done := false


func _init() -> void:
	_test_normal_approach_presses_once(_failures)
	_test_lateral_sweep_never_presses(_failures)
	_test_slow_creep_abstains_and_presses(_failures)
	_test_slide_off_cancels_not_releases(_failures)
	_test_jitter_does_not_chatter(_failures)
	_test_fast_pass_through_presses_once(_failures)
	_test_pinned_point_clamps_to_surface(_failures)
	_test_drag_on_suppresses_release(_failures)
	_test_drag_off_still_releases(_failures)
	_test_steep_poke_rescued_by_entry(_failures)
	_test_fast_diagonal_rescued_by_angle(_failures)
	_test_forget_clears_history(_failures)
	_test_forget_return_values(_failures)
	_test_apply_profile_include_depth_true(_failures)
	_test_apply_profile_include_depth_false(_failures)
	_test_apply_profile_null_changes_nothing(_failures)
	_test_mixed_axis_half_size(_failures)


func _process(_delta: float) -> bool:
	if _tree_tests_done:
		return true
	_tree_tests_done = true
	_test_pokeable_emits_cancelled_on_slide_off(_failures)
	_test_pokeable_reports_a_pin(_failures)
	_test_pokeable_x_face_presses_and_cancels(_failures)
	_test_pokeable_pin_is_inf_without_contact(_failures)
	_test_pokeable_pin_is_inf_when_off_face(_failures)
	_test_pokeable_pin_is_inf_when_beyond_band(_failures)
	_test_pokeable_drag_delta_is_cumulative_since_press(_failures)
	_test_station_drag_handle_uses_absolute_offset_not_accumulated(_failures)
	_test_canvas_cancel_pushes_the_release_off_panel(_failures)
	_test_canvas_press_fires_the_control(_failures)
	_test_canvas_hover_tracks_last_pointer_position(_failures)
	_test_canvas_out_of_bounds_does_not_move_last_pointer_position(_failures)
	_test_canvas_drag_is_gated_per_source(_failures)
	_test_poke_button_fires_on_a_fast_poke(_failures)
	_test_poke_button_thresholds_are_unchanged(_failures)
	_test_poke_button_lateral_sweep_never_presses(_failures)
	_test_poke_button_fast_diagonal_rescued_by_history(_failures)
	_test_poke_button_source_ids_survive_group_reordering(_failures)
	_test_marker_prefers_the_pinned_point(_failures)
	_test_marker_falls_back_when_pin_is_inf(_failures)
	if _failures.is_empty():
		print("XR poke fidelity: PASS")
		quit(0)
		return true
	for failure in _failures:
		printerr("FAIL: %s" % failure)
	printerr("XR poke fidelity: %d FAILURE(S)" % _failures.size())
	quit(1)
	return true


## Build a pokeable at the origin, facing the given face (default +Z),
## parented to a body so its self-wiring finds one.
func _make_pokeable(face := XRPokeableScript.Face.Z_PLUS) -> Node3D:
	var body := StaticBody3D.new()
	get_root().add_child(body)
	var pokeable := Node3D.new()
	pokeable.set_script(XRPokeableScript)
	pokeable.poke_face = face
	body.add_child(pokeable)
	return pokeable


func _test_pokeable_emits_cancelled_on_slide_off(failures: Array[String]) -> void:
	var pokeable := _make_pokeable()
	var seen := {"pressed": 0, "released": 0, "cancelled": 0}
	pokeable.pressed.connect(func(_hand): seen["pressed"] += 1)
	pokeable.released.connect(func(_hand): seen["released"] += 1)
	pokeable.cancelled.connect(func(_hand): seen["cancelled"] += 1)
	# Face normal is +Z by default, so world +Z is "in front".
	pokeable.poke_update(0, Vector3(0.0, 0.0, 0.050))
	pokeable.poke_update(0, Vector3(0.0, 0.0, 0.008))
	pokeable.poke_update(0, Vector3(0.080, 0.0, 0.008))
	_check(failures, seen["pressed"] == 1,
			"pokeable: expected 1 pressed, got %d" % seen["pressed"])
	_check(failures, seen["cancelled"] == 1,
			"pokeable: expected 1 cancelled, got %d" % seen["cancelled"])
	_check(failures, seen["released"] == 0,
			"pokeable: a slide-off must NOT emit released, got %d" % seen["released"])
	pokeable.get_parent().queue_free()


## The body sits on a transform with BOTH a translation and a rotation, so the
## test pins down the WHOLE world-space formula, not just its z-component. A
## default (Z_PLUS, identity-transform) fixture cannot distinguish u_axis from
## v_axis: both are perpendicular to the normal, so world z depends only on
## normal.z * pinned.z regardless of which of u_axis/v_axis carries pinned.x
## vs pinned.y. Swap u_axis and v_axis in the round-trip line and a z-only
## assertion still passes; a full world-space comparison does not.
##
## The expected value is derived WITHOUT using u_axis/v_axis at all: for the
## default Z_PLUS face, the face plane IS the local z = 0 plane, so the
## surface point pinned under a fingertip sits directly at that fingertip's
## own local x/y, at local z = 0. That is independent geometric reasoning,
## not a copy of the production round-trip line.
func _test_pokeable_reports_a_pin(failures: Array[String]) -> void:
	var pokeable := _make_pokeable()
	var body: Node3D = pokeable.get_parent()
	body.transform = Transform3D(
			Basis.from_euler(Vector3(0.0, deg_to_rad(35.0), 0.0)),
			Vector3(0.4, 0.2, -0.3))
	# First sample well in front (arms the entry gate); second sample laterally
	# off-center (x != y, so a u/v swap changes the result) and pushed past
	# the surface (negative local z), so the pin clamps onto the face.
	var local_front := Vector3(0.0, 0.0, 0.050)
	var local_behind := Vector3(0.012, -0.006, -0.020)
	pokeable.poke_update(0, body.transform * local_front)
	pokeable.poke_update(0, body.transform * local_behind)
	var pin: Vector3 = pokeable.get_poke_pin(0)
	var expected: Vector3 = body.transform * Vector3(local_behind.x, local_behind.y, 0.0)
	_check(failures, pin != Vector3.INF,
			"pokeable: expected a pin while in contact")
	_check(failures, pin.is_equal_approx(expected),
			"pokeable: expected pin at %s, got %s" % [expected, pin])
	pokeable.get_parent().queue_free()


## A NON-default face. The default (Z_PLUS) fixture above cannot catch a bug
## that globally inverts the normal for every face - X_PLUS and Z_PLUS need
## OPPOSITE handling (see _local_normal's fix history), so a mistake that
## flips all six faces the same way still passes the Z-only fixture while
## breaking this one.
func _test_pokeable_x_face_presses_and_cancels(failures: Array[String]) -> void:
	var pokeable := _make_pokeable(XRPokeableScript.Face.X_PLUS)
	var seen := {"pressed": 0, "cancelled": 0}
	pokeable.pressed.connect(func(_hand): seen["pressed"] += 1)
	pokeable.cancelled.connect(func(_hand): seen["cancelled"] += 1)
	# Face normal is +X for this face, so world +X is "in front".
	pokeable.poke_update(0, Vector3(0.050, 0.0, 0.0))
	pokeable.poke_update(0, Vector3(0.008, 0.0, 0.0))
	pokeable.poke_update(0, Vector3(0.008, 0.080, 0.0))
	_check(failures, seen["pressed"] == 1,
			"pokeable X_PLUS: expected 1 pressed, got %d" % seen["pressed"])
	_check(failures, seen["cancelled"] == 1,
			"pokeable X_PLUS: expected 1 cancelled, got %d" % seen["cancelled"])
	pokeable.get_parent().queue_free()


func _test_pokeable_pin_is_inf_without_contact(failures: Array[String]) -> void:
	var pokeable := _make_pokeable()
	var pin: Vector3 = pokeable.get_poke_pin(0)
	_check(failures, pin == Vector3.INF,
			"pokeable: expected Vector3.INF for a hand with no contact, got %s" % [pin])
	pokeable.get_parent().queue_free()


## The source is OUTSIDE the face rectangle (x beyond half_size) AND deeper
## than the surface (negative z) - a fingertip beside the button, not over it.
## A single sample is enough: this is the source's FIRST ever sample, so the
## evaluator was never pressed and the exit path returns NONE (not
## CANCELLED), meaning _emit's CANCELLED-branch erase never runs - the only
## thing that can stop a stale pin here is the evaluator itself returning
## Vector3.INF from the bounds-exit path.
func _test_pokeable_pin_is_inf_when_off_face(failures: Array[String]) -> void:
	var pokeable := _make_pokeable()
	pokeable.poke_update(0, Vector3(0.080, 0.0, -0.005))
	var pin: Vector3 = pokeable.get_poke_pin(0)
	_check(failures, pin == Vector3.INF,
			"pokeable: an off-face point behind the surface must not get a pin, got %s" % [pin])
	pokeable.get_parent().queue_free()


## The source is INSIDE the face rectangle but far outside the working
## z-band (deeper than -release_depth) - isolates the band-exit path from the
## bounds-exit path covered above.
func _test_pokeable_pin_is_inf_when_beyond_band(failures: Array[String]) -> void:
	var pokeable := _make_pokeable()
	pokeable.poke_update(0, Vector3(0.010, 0.010, -0.500))
	var pin: Vector3 = pokeable.get_poke_pin(0)
	_check(failures, pin == Vector3.INF,
			"pokeable: a point beyond the working z-band must not get a pin, got %s" % [pin])
	pokeable.get_parent().queue_free()


## Pins down the contract a consumer MUST get right: `dragged`'s delta is the
## CUMULATIVE planar offset since the press began (press_planar is captured
## ONCE, at the moment of pressing), not a per-call increment. A consumer that
## accumulates delta on every call - rather than treating it as an absolute
## offset from the press point - double-counts, because poke_update fires
## every physics tick while held, re-delivering the same cumulative value on
## ticks where the finger hasn't moved at all. Moving to +0.02 then +0.03 must
## report delta 0.02 then 0.03 - NOT 0.02 then 0.05 (which is what a
## per-call-accumulating consumer would wrongly derive if this ever reported
## a per-tick increment instead).
##
## Captured state lives in a Dictionary, not plain locals: GDScript lambdas
## close over outer locals BY VALUE, so a plain `var` assigned to inside the
## closure never propagates back out (every other closure-capturing test in
## this file mutates a Dictionary/Array for the same reason).
##
## World x is fed NEGATIVE (-0.02, then -0.03): the default Z_PLUS face's
## u-axis is world -X (normal.cross(UP) for normal = +Z), so canonical planar
## x is the NEGATION of world x. Feeding negative world x keeps the delta
## values below matching the cumulative amounts in the doc comment above
## (0.02, then 0.03) instead of introducing an unrelated sign flip.
func _test_pokeable_drag_delta_is_cumulative_since_press(failures: Array[String]) -> void:
	var pokeable := _make_pokeable()
	pokeable.interpret_drag = true
	pokeable.drag_threshold = 0.010
	var drag := {"count": 0, "last_delta": Vector2.INF}
	pokeable.dragged.connect(func(_hand: int, delta: Vector2) -> void:
		drag["count"] += 1
		drag["last_delta"] = delta)
	# Face normal is +Z by default: arm entry well in front, then cross the
	# press plane at planar origin (x=0, y=0) - this is the press point every
	# later delta must be measured from.
	pokeable.poke_update(0, Vector3(0.0, 0.0, 0.050))
	pokeable.poke_update(0, Vector3(0.0, 0.0, 0.008))
	pokeable.poke_update(0, Vector3(-0.020, 0.0, 0.008))
	_check(failures, drag["count"] >= 1,
			"pokeable drag: expected at least 1 DRAG after moving to +0.02, got %d" % drag["count"])
	_check(failures, (drag["last_delta"] as Vector2).is_equal_approx(Vector2(0.020, 0.0)),
			"pokeable drag: expected delta (0.02, 0.0) after moving to +0.02, got %s" % [drag["last_delta"]])
	pokeable.poke_update(0, Vector3(-0.030, 0.0, 0.008))
	_check(failures, (drag["last_delta"] as Vector2).is_equal_approx(Vector2(0.030, 0.0)),
			"pokeable drag: expected CUMULATIVE delta (0.03, 0.0) after moving to +0.03 (not 0.05), got %s" % [drag["last_delta"]])
	pokeable.get_parent().queue_free()


## Closes the gap the test above cannot: that one proves XRPokeable's
## `dragged` SIGNAL is cumulative; it says nothing about whether a CONSUMER
## reads it correctly. XRPokeStation._build_drag_handle wired `dragged` to
## `mesh_instance.position.x`, and a consumer that accumulates the (already
## cumulative) delta on every call double-counts. This drives the REAL
## station's REAL DragHandle (built by XRPokeStation._build_gate_demo, not a
## hand-rolled fixture) through a press-then-slide-twice sequence and asserts
## the mesh's absolute position, not the signal - so a future handler
## regression that reintroduces accumulation fails HERE, not only in a mental
## review. `XRPokeStation._build_gate_demo()` runs unconditionally from
## `_ready()`, before any of the station's optional Stand/Orb/TouchPanel
## lookups, so a bare station node (no children authored) still builds it.
func _test_station_drag_handle_uses_absolute_offset_not_accumulated(failures: Array[String]) -> void:
	var station := Node3D.new()
	station.set_script(XRPokeStationScript)
	get_root().add_child(station)

	var drag_handle: StaticBody3D = station.get_node_or_null("GateDemo/DragHandle")
	if drag_handle == null:
		_check(failures, false, "station: GateDemo/DragHandle not found (station structure changed)")
		station.queue_free()
		return
	var mesh: MeshInstance3D = drag_handle.get_node_or_null("Mesh")
	var pokeable = drag_handle.get_meta("xr_pokeable", null)
	if mesh == null or pokeable == null:
		_check(failures, false, "station: DragHandle missing its Mesh child or xr_pokeable meta")
		station.queue_free()
		return

	var rest_x: float = mesh.position.x
	# Same world-x-negated convention as the pokeable test above: the default
	# Z_PLUS face's u-axis is world -X, and the body carries no rotation here,
	# so world -0.02/-0.03 arrive at the handler as canonical delta.x = +0.02/+0.03.
	var origin: Vector3 = drag_handle.global_transform.origin
	pokeable.poke_update(0, origin + Vector3(0.0, 0.0, 0.050))
	pokeable.poke_update(0, origin + Vector3(0.0, 0.0, 0.008))
	pokeable.poke_update(0, origin + Vector3(-0.020, 0.0, 0.008))
	_check(failures, is_equal_approx(mesh.position.x, rest_x + 0.020),
			"station drag handle: expected mesh x = rest + 0.02 = %f after the first slide, got %f" % [
				rest_x + 0.020, mesh.position.x])
	pokeable.poke_update(0, origin + Vector3(-0.030, 0.0, 0.008))
	_check(failures, is_equal_approx(mesh.position.x, rest_x + 0.030),
			"station drag handle: expected mesh x = rest + 0.03 = %f (ABSOLUTE, not rest + 0.02 + 0.03) after the second slide, got %f" % [
				rest_x + 0.030, mesh.position.x])
	station.queue_free()


## A poke that slides off the panel while pressed must CANCEL, not release at
## the last in-panel pixel - that pixel sits inside whatever Control happens
## to be there, so releasing there would fire it. Godot Controls only fire on
## a release that lands in their own rect, so the fix is to deliver the
## release far off-panel instead.
func _test_canvas_cancel_pushes_the_release_off_panel(failures: Array[String]) -> void:
	var panel := Node3D.new()
	panel.set_script(XRUICanvasScript)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(256, 256)
	panel.add_child(viewport)
	panel.viewport_path = panel.get_path_to(viewport)
	panel.panel_size = Vector2(0.4, 0.4)
	get_root().add_child(panel)

	var button := Button.new()
	button.anchor_right = 1.0
	button.anchor_bottom = 1.0
	viewport.add_child(button)
	var fired := {"count": 0}
	button.pressed.connect(func(): fired["count"] += 1)

	panel.poke_update(0, Vector3(0.0, 0.0, 0.050))
	panel.poke_update(0, Vector3(0.0, 0.0, 0.008))
	panel.poke_update(0, Vector3(0.300, 0.0, 0.008))  # slide off the panel
	_check(failures, fired["count"] == 0,
			"canvas: an aborted poke must not fire the Control, fired %d" % fired["count"])
	panel.queue_free()


## The positive mirror of the cancel test above: a straight-on poke arms the
## entry gate, crosses the press plane (PRESSED), then retracts past
## release_depth while still over the panel (RELEASED). The release must land
## inside the Button's rect and fire it - proving the cancel test isn't
## passing merely because poke_update never presses anything at all.
func _test_canvas_press_fires_the_control(failures: Array[String]) -> void:
	var panel := Node3D.new()
	panel.set_script(XRUICanvasScript)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(256, 256)
	panel.add_child(viewport)
	panel.viewport_path = panel.get_path_to(viewport)
	panel.panel_size = Vector2(0.4, 0.4)
	get_root().add_child(panel)

	var button := Button.new()
	button.anchor_right = 1.0
	button.anchor_bottom = 1.0
	viewport.add_child(button)
	var fired := {"count": 0}
	button.pressed.connect(func(): fired["count"] += 1)

	panel.poke_update(0, Vector3(0.0, 0.0, 0.050))  # in front, arms entry
	panel.poke_update(0, Vector3(0.0, 0.0, 0.008))  # cross the press plane
	panel.poke_update(0, Vector3(0.0, 0.0, 0.050))  # retract past release_depth, still over the panel
	_check(failures, fired["count"] == 1,
			"canvas: a straight-on poke through the panel must fire the Control, fired %d" % fired["count"])
	panel.queue_free()


## Finding 1: _last_pointer_position must track on EVERY in-range poke_update
## call, including a pure hover -- in front of the panel, in range, but has
## NOT yet crossed the press plane (event NONE, no PRESSED/RELEASED/CANCELLED
## and not pressed, so the drag branch does not fire either). Before the fix
## this variable was only assigned inside the PRESSED/RELEASED branches and
## the pressed-only default branch, so a lone hover sample left it at its
## initial Vector2.ZERO instead of the hover's own projected pixel.
func _test_canvas_hover_tracks_last_pointer_position(failures: Array[String]) -> void:
	var panel := Node3D.new()
	panel.set_script(XRUICanvasScript)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(256, 256)
	panel.add_child(viewport)
	panel.viewport_path = panel.get_path_to(viewport)
	panel.panel_size = Vector2(0.4, 0.4)
	get_root().add_child(panel)

	# In front (z=0.050 > press_depth) and inside the face rectangle, so this
	# is the source's very first sample: in_front arms, event is NONE, and
	# the source was never pressed. A pure hover, nothing else.
	var hover_point := Vector3(0.050, 0.0, 0.050)
	panel.poke_update(0, hover_point)
	var expected: Vector2 = panel.map_local_point_to_viewport(hover_point)
	_check(failures, panel._last_pointer_position.is_equal_approx(expected),
			"hover: _last_pointer_position must track a pure hover frame, expected %s got %s" % [expected, panel._last_pointer_position])
	panel.queue_free()


## Finding 1 (pass 3): the evaluator, not the adapter, owns the face
## rectangle since this conversion - so a sample that is still within the
## adapter's own z-reach test but OUTSIDE the panel's x/y rectangle (a
## slide-off, same geometry as the cancel test below) reaches the
## unconditional _last_pointer_position assignment unless the adapter also
## checks bounds itself. map_local_point_to_viewport clamps u/v, so without
## that check an out-of-panel sample would store a spurious clamped-to-edge
## pixel instead of leaving the cursor at its last real position - exactly
## what the pre-conversion code (bounds test gating the assignment) never
## did.
func _test_canvas_out_of_bounds_does_not_move_last_pointer_position(failures: Array[String]) -> void:
	var panel := Node3D.new()
	panel.set_script(XRUICanvasScript)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(256, 256)
	panel.add_child(viewport)
	panel.viewport_path = panel.get_path_to(viewport)
	panel.panel_size = Vector2(0.4, 0.4)
	get_root().add_child(panel)

	# First sample: in front and inside the rectangle -- establishes a known
	# _last_pointer_position to check the next sample did NOT disturb.
	var in_bounds_point := Vector3(0.0, 0.0, 0.050)
	panel.poke_update(0, in_bounds_point)
	var expected: Vector2 = panel.map_local_point_to_viewport(in_bounds_point)
	_check(failures, panel._last_pointer_position.is_equal_approx(expected),
			"out of bounds: setup must land the cursor at the in-bounds sample first")

	# Second sample: still within the adapter's own z-reach (poke_range
	# default 0.09, floor -0.06) but outside the panel's x half-size -- the
	# same slide-off geometry the cancel test uses.
	panel.poke_update(0, Vector3(0.300, 0.0, 0.008))
	_check(failures, panel._last_pointer_position.is_equal_approx(expected),
			"out of bounds: an out-of-panel sample must not move _last_pointer_position, expected %s got %s" % [expected, panel._last_pointer_position])
	panel.queue_free()


## Named correctness requirement: the drag branch in poke_update's `_:`
## default case must check is_source_pressed(source_id), not is_pressed().
## is_pressed() answers "is ANY source pressed", so with two hands on one
## panel a held source would drag the viewport cursor for an idle one.
##
## Source 0 presses through the face and holds (stays pressed). Source 1 is
## then fed a clearly different, in-range, in-front point that has NOT
## crossed the press plane -- a pure hover, not a press. With the correct
## per-source gate, source 1's hover must push NOTHING into the viewport:
## it is not pressed, so the default branch's `if is_source_pressed(1):`
## is false. A regression to is_pressed() would see source 0's held press
## and push a motion event at source 1's hover position instead, which
## the probe below would catch.
func _test_canvas_drag_is_gated_per_source(failures: Array[String]) -> void:
	var panel := Node3D.new()
	panel.set_script(XRUICanvasScript)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(256, 256)
	panel.add_child(viewport)
	panel.viewport_path = panel.get_path_to(viewport)
	panel.panel_size = Vector2(0.4, 0.4)
	get_root().add_child(panel)

	var probe := _MotionProbe.new()
	viewport.add_child(probe)

	# Source 0: arm entry, cross the press plane, and hold -- still pressed.
	panel.poke_update(0, Vector3(-0.100, 0.0, 0.050))
	panel.poke_update(0, Vector3(-0.100, 0.0, 0.008))
	_check(failures, panel._poke_evaluator.is_source_pressed(0),
			"two sources: source 0 must be pressed before the drag probe runs")

	probe.positions.clear()

	# Source 1: a different pixel (x=0.100 vs source 0's x=-0.100), in range
	# and in front of the panel, but has NOT crossed the press plane.
	panel.poke_update(1, Vector3(0.100, 0.0, 0.050))
	_check(failures, not panel._poke_evaluator.is_source_pressed(1),
			"two sources: source 1 must not be pressed -- this is a pure hover")

	_check(failures, probe.positions.is_empty(),
			"two sources: an idle hand's hover pushed viewport motion at %s -- it dragged the held hand's cursor" % [probe.positions])
	panel.queue_free()


## A default evaluator: XRPokeable's shipped thresholds.
func _make() -> RefCounted:
	var evaluator = XRPokeEvaluator.new()
	evaluator.press_depth = 0.012
	evaluator.release_depth = 0.04
	evaluator.half_size = Vector2(0.05, 0.05)
	return evaluator


## A profile whose values are ALL distinct from XRPokeEvaluator's defaults
## (and from XRPokeProfile's own defaults, which deliberately match them).
## A default-valued profile would make the apply_profile tests pass whether
## or not apply_profile does anything at all.
func _make_profile() -> Resource:
	var profile := XRPokeProfile.new()
	profile.press_depth = 0.030
	profile.release_depth = 0.060
	profile.require_entry_through_face = false
	profile.max_approach_angle = 80.0
	profile.min_approach_travel = 0.001
	return profile


## Feed a point sequence, collect the event per sample.
func _run(evaluator, points: Array) -> Array:
	var events := []
	for point in points:
		events.append(evaluator.evaluate(0, point)["event"])
	return events


func _count(events: Array, event: int) -> int:
	var total := 0
	for candidate in events:
		if candidate == event:
			total += 1
	return total


func _check(failures: Array[String], condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _test_normal_approach_presses_once(failures: Array[String]) -> void:
	var evaluator = _make()
	var events := _run(evaluator, [
		Vector3(0.0, 0.0, 0.100),
		Vector3(0.0, 0.0, 0.060),
		Vector3(0.0, 0.0, 0.030),
		Vector3(0.0, 0.0, 0.008),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.PRESSED) == 1,
			"normal approach: expected exactly 1 PRESSED, got %s" % [events])


func _test_lateral_sweep_never_presses(failures: Array[String]) -> void:
	# Enters from OUTSIDE the face rectangle, already at press depth, and
	# sweeps across. This is the failure the gate exists to prevent.
	var evaluator = _make()
	var events := _run(evaluator, [
		Vector3(0.200, 0.0, 0.008),
		Vector3(0.030, 0.0, 0.008),
		Vector3(0.000, 0.0, 0.008),
		Vector3(-0.030, 0.0, 0.008),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.PRESSED) == 0,
			"lateral sweep: expected no PRESSED, got %s" % [events])


## Isolates the ABSTAIN rule. Two constraints make this test actually test it:
## the entry test must stay REQUIRED (so it cannot supply the pass), and the
## motion must carry a LATERAL component. A purely axial creep satisfies the
## angle test at any magnitude, so an axial fixture would pass with the
## abstain deleted - which is exactly the mutation this must catch.
func _test_slow_creep_abstains_and_presses(failures: Array[String]) -> void:
	var evaluator = _make()
	evaluator.require_entry_through_face = true
	evaluator.min_approach_travel = 0.003
	# Both samples are already at press depth, so in_front is never set and
	# only the angle test can arm. Window travel is 1.5 mm, mostly sideways.
	var events := _run(evaluator, [
		Vector3(0.0000, 0.0, 0.0110),
		Vector3(0.0015, 0.0, 0.0108),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.PRESSED) == 1,
			"slow creep: expected 1 PRESSED via abstain, got %s" % [events])


func _test_slide_off_cancels_not_releases(failures: Array[String]) -> void:
	var evaluator = _make()
	var events := _run(evaluator, [
		Vector3(0.0, 0.0, 0.050),
		Vector3(0.0, 0.0, 0.008),
		Vector3(0.080, 0.0, 0.008),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.CANCELLED) == 1,
			"slide off: expected 1 CANCELLED, got %s" % [events])
	_check(failures, _count(events, XRPokeEvaluator.Event.RELEASED) == 0,
			"slide off: expected no RELEASED, got %s" % [events])


func _test_jitter_does_not_chatter(failures: Array[String]) -> void:
	var evaluator = _make()
	var events := _run(evaluator, [
		Vector3(0.0, 0.0, 0.050),
		Vector3(0.0, 0.0, 0.008),
		Vector3(0.0, 0.0, 0.014),
		Vector3(0.0, 0.0, 0.010),
		Vector3(0.0, 0.0, 0.013),
		Vector3(0.0, 0.0, 0.009),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.PRESSED) == 1,
			"jitter: expected 1 PRESSED, got %s" % [events])
	_check(failures, _count(events, XRPokeEvaluator.Event.RELEASED) == 0,
			"jitter: expected no RELEASED, got %s" % [events])


func _test_fast_pass_through_presses_once(failures: Array[String]) -> void:
	# One sample in front, the next already past the surface.
	var evaluator = _make()
	var events := _run(evaluator, [
		Vector3(0.0, 0.0, 0.200),
		Vector3(0.0, 0.0, -0.020),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.PRESSED) == 1,
			"fast pass-through: expected 1 PRESSED, got %s" % [events])


func _test_pinned_point_clamps_to_surface(failures: Array[String]) -> void:
	var evaluator = _make()
	evaluator.evaluate(0, Vector3(0.0, 0.0, 0.050))
	var result: Dictionary = evaluator.evaluate(0, Vector3(0.010, 0.020, -0.030))
	var pinned: Vector3 = result["pinned_point"]
	_check(failures, is_equal_approx(pinned.z, 0.0),
			"pinned point: expected z clamped to 0, got %f" % pinned.z)
	_check(failures, is_equal_approx(pinned.x, 0.010) and is_equal_approx(pinned.y, 0.020),
			"pinned point: planar coordinates must pass through, got %s" % [pinned])


func _test_drag_on_suppresses_release(failures: Array[String]) -> void:
	var evaluator = _make()
	evaluator.interpret_drag = true
	evaluator.drag_threshold = 0.010
	var events := _run(evaluator, [
		Vector3(0.0, 0.0, 0.050),
		Vector3(0.0, 0.0, 0.008),
		Vector3(0.020, 0.0, 0.008),
		Vector3(0.020, 0.0, 0.050),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.DRAG) >= 1,
			"drag on: expected at least 1 DRAG, got %s" % [events])
	_check(failures, _count(events, XRPokeEvaluator.Event.RELEASED) == 0,
			"drag on: RELEASED must be suppressed, got %s" % [events])


func _test_drag_off_still_releases(failures: Array[String]) -> void:
	var evaluator = _make()
	evaluator.interpret_drag = false
	var events := _run(evaluator, [
		Vector3(0.0, 0.0, 0.050),
		Vector3(0.0, 0.0, 0.008),
		Vector3(0.020, 0.0, 0.008),
		Vector3(0.020, 0.0, 0.050),
	])
	_check(failures, _count(events, XRPokeEvaluator.Event.DRAG) == 0,
			"drag off: expected no DRAG, got %s" % [events])
	_check(failures, _count(events, XRPokeEvaluator.Event.RELEASED) == 1,
			"drag off: expected 1 RELEASED, got %s" % [events])


## RESCUE CASE A. A deliberate poke ~50 deg off the normal, at a 45 deg limit.
## The angle test rejects it; the entry test must rescue it.
##
## TRAP: do NOT isolate by setting require_entry_through_face = false. That
## OPENS the gate unconditionally (_entry_passes returns true), so the press
## would still happen and the test would assert the opposite of what it looks
## like it asserts. Isolate instead by making the FIRST sample land outside
## the face, so in_front is never set and only the angle test remains.
func _test_steep_poke_rescued_by_entry(failures: Array[String]) -> void:
	var armed_evaluator = _make()
	armed_evaluator.half_size = Vector2(0.200, 0.200)
	armed_evaluator.max_approach_angle = 45.0
	var armed := _run(armed_evaluator, [
		Vector3(0.000, 0.0, 0.050),
		Vector3(0.060, 0.0, 0.000),
	])
	_check(failures, _count(armed, XRPokeEvaluator.Event.PRESSED) == 1,
			"steep poke: the entry test must rescue it, got %s" % [armed])

	var blocked_evaluator = _make()
	blocked_evaluator.half_size = Vector2(0.200, 0.200)
	blocked_evaluator.max_approach_angle = 45.0
	var blocked := _run(blocked_evaluator, [
		Vector3(0.300, 0.0, 0.050),
		Vector3(0.060, 0.0, 0.000),
	])
	_check(failures, _count(blocked, XRPokeEvaluator.Event.PRESSED) == 0,
			"steep poke: without entry through the face there must be no press, got %s" % [blocked])


## RESCUE CASE B. A fast diagonal whose PREVIOUS sample fell outside the face
## rectangle, so the entry test never armed. The angle test must rescue it.
func _test_fast_diagonal_rescued_by_angle(failures: Array[String]) -> void:
	var points := [
		Vector3(0.060, 0.0, 0.050),
		Vector3(0.000, 0.0, -0.001),
	]
	var with_angle = _make()
	var armed := _run(with_angle, points)
	_check(failures, _count(armed, XRPokeEvaluator.Event.PRESSED) == 1,
			"fast diagonal: angle test must rescue it, got %s" % [armed])

	var without_angle = _make()
	without_angle.max_approach_angle = 0.0
	var blocked := _run(without_angle, points)
	_check(failures, _count(blocked, XRPokeEvaluator.Event.PRESSED) == 0,
			"fast diagonal: with the angle test closed there must be no press, got %s" % [blocked])


## forget() is the ONLY path that clears history (the bounds/band exits keep
## it). Reuses the fast-diagonal-rescue geometry from the test above: the
## first sample lands outside the face, the second is the fast diagonal that
## only the angle test can rescue. Calling forget() between the two must wipe
## the first sample from history, leaving the second sample alone in the
## window - too few points for the angle test, and in_front was never set, so
## there must be no press. Without the forget() call (the test above) there
## IS a press; that contrast is what proves history was actually cleared.
func _test_forget_clears_history(failures: Array[String]) -> void:
	var evaluator = _make()
	evaluator.evaluate(0, Vector3(0.060, 0.0, 0.050))
	evaluator.forget(0)
	var result: Dictionary = evaluator.evaluate(0, Vector3(0.000, 0.0, -0.001))
	_check(failures, result["event"] == XRPokeEvaluator.Event.NONE,
			"forget: history must be cleared, expected NONE, got %s" % [result["event"]])


func _test_forget_return_values(failures: Array[String]) -> void:
	var evaluator = _make()
	_check(failures, evaluator.forget(0) == XRPokeEvaluator.Event.NONE,
			"forget: an unknown source must return NONE")

	evaluator.evaluate(0, Vector3(0.0, 0.0, 0.050))
	evaluator.evaluate(0, Vector3(0.0, 0.0, 0.008))
	_check(failures, evaluator.is_source_pressed(0),
			"forget: setup must be mid-press before forget is called")
	_check(failures, evaluator.forget(0) == XRPokeEvaluator.Event.CANCELLED,
			"forget: mid-press must return CANCELLED")
	_check(failures, evaluator.forget(0) == XRPokeEvaluator.Event.NONE,
			"forget: an idle known source must return NONE")


## include_depth defaulting to true copies all five profile properties.
func _test_apply_profile_include_depth_true(failures: Array[String]) -> void:
	var evaluator = _make()
	var profile := _make_profile()
	evaluator.apply_profile(profile)
	_check(failures, is_equal_approx(evaluator.press_depth, profile.press_depth),
			"apply_profile: include_depth=true must copy press_depth")
	_check(failures, is_equal_approx(evaluator.release_depth, profile.release_depth),
			"apply_profile: include_depth=true must copy release_depth")
	_check(failures, evaluator.require_entry_through_face == profile.require_entry_through_face,
			"apply_profile: must copy require_entry_through_face")
	_check(failures, is_equal_approx(evaluator.max_approach_angle, profile.max_approach_angle),
			"apply_profile: must copy max_approach_angle")
	_check(failures, is_equal_approx(evaluator.min_approach_travel, profile.min_approach_travel),
			"apply_profile: must copy min_approach_travel")


## include_depth=false copies only the three approach-gate fields; a button
## cap's throw (press_depth/release_depth) is geometry, not project feel, and
## a shared profile must not overwrite it.
func _test_apply_profile_include_depth_false(failures: Array[String]) -> void:
	var evaluator = _make()
	var prior_press_depth: float = evaluator.press_depth
	var prior_release_depth: float = evaluator.release_depth
	var profile := _make_profile()
	evaluator.apply_profile(profile, false)
	_check(failures, is_equal_approx(evaluator.press_depth, prior_press_depth),
			"apply_profile: include_depth=false must leave press_depth untouched")
	_check(failures, is_equal_approx(evaluator.release_depth, prior_release_depth),
			"apply_profile: include_depth=false must leave release_depth untouched")
	_check(failures, evaluator.require_entry_through_face == profile.require_entry_through_face,
			"apply_profile: include_depth=false must still copy require_entry_through_face")
	_check(failures, is_equal_approx(evaluator.max_approach_angle, profile.max_approach_angle),
			"apply_profile: include_depth=false must still copy max_approach_angle")
	_check(failures, is_equal_approx(evaluator.min_approach_travel, profile.min_approach_travel),
			"apply_profile: include_depth=false must still copy min_approach_travel")


func _test_apply_profile_null_changes_nothing(failures: Array[String]) -> void:
	var evaluator = _make()
	var prior_press_depth: float = evaluator.press_depth
	var prior_release_depth: float = evaluator.release_depth
	var prior_require_entry: bool = evaluator.require_entry_through_face
	var prior_max_angle: float = evaluator.max_approach_angle
	var prior_min_travel: float = evaluator.min_approach_travel
	evaluator.apply_profile(null)
	var unchanged: bool = (
			is_equal_approx(evaluator.press_depth, prior_press_depth)
			and is_equal_approx(evaluator.release_depth, prior_release_depth)
			and evaluator.require_entry_through_face == prior_require_entry
			and is_equal_approx(evaluator.max_approach_angle, prior_max_angle)
			and is_equal_approx(evaluator.min_approach_travel, prior_min_travel)
	)
	_check(failures, unchanged, "apply_profile: a null profile must change nothing")


## Pins down BOTH halves of "zero on an axis = unbounded there" for a
## half_size with only ONE axis unbounded. The old all-or-nothing guard
## treated any bounded axis as if it bounded every axis, so a point far
## outside half_size.x = 0.0 was wrongly rejected; the per-axis guard must let
## it through while half_size.y = 0.05 keeps rejecting on y as before.
func _test_mixed_axis_half_size(failures: Array[String]) -> void:
	# x unbounded: far off-axis in x, approaching through the face and
	# crossing the press plane, must still PRESS.
	var unbounded_x = _make()
	unbounded_x.half_size = Vector2(0.0, 0.05)
	var x_events := _run(unbounded_x, [
		Vector3(0.500, 0.0, 0.100),
		Vector3(0.500, 0.0, 0.008),
	])
	_check(failures, _count(x_events, XRPokeEvaluator.Event.PRESSED) == 1,
			"mixed axis: half_size.x = 0 must not reject a far off-axis point, got %s" % [x_events])

	# y still bounded: press, then slide past |y| > 0.05, must still CANCEL.
	var bounded_y = _make()
	bounded_y.half_size = Vector2(0.0, 0.05)
	var y_events := _run(bounded_y, [
		Vector3(0.0, 0.0, 0.050),
		Vector3(0.0, 0.0, 0.008),
		Vector3(0.0, 0.080, 0.008),
	])
	_check(failures, _count(y_events, XRPokeEvaluator.Event.CANCELLED) == 1,
			"mixed axis: half_size.y = 0.05 must still bound y and cancel, got %s" % [y_events])


## Both samples land within the reach window (cap_rest_top ~= 0.048, reach
## guard 0.098), so this isolates the fast-poke bottoming-out fix from the
## reach/entry gate: sample 1 (y=0.060) is in front (arms in_front, no
## penetration), sample 2 (y=-0.020, ~8 cm lower - a hard slap, ~4.8 m/s at
## 60 Hz) lands fully bottomed out in ONE step - the sample the old
## `local.y < -0.01: continue` guard threw away. entry_passes (in_front, set
## by sample 1) rescues the press; the clamp is what lets it register as
## bottomed out instead of "absent."
func _test_poke_button_fires_on_a_fast_poke(failures: Array[String]) -> void:
	var button := Node3D.new()
	button.set_script(XRPokeButtonScript)
	get_root().add_child(button)
	var fired := {"count": 0}
	button.pressed.connect(func(): fired["count"] += 1)
	button.poke_update(0, button.global_transform * Vector3(0.0, 0.060, 0.0))
	button.poke_update(0, button.global_transform * Vector3(0.0, -0.020, 0.0))
	_check(failures, fired["count"] == 1,
			"poke button: a fast poke must fire once, fired %d" % fired["count"])
	button.queue_free()


## A lateral sweep through the cap at a CONSTANT, already-bottomed-out depth,
## entering and leaving through the round shape rather than approaching from
## above. require_entry_through_face must reject this (in_front is never set,
## since every in-radius sample is already past press_depth) and the angle
## test must independently reject it too (the travel between in-radius
## samples is almost pure lateral, z-component ~0, failing max_approach_angle
## well before the 60 degree limit). This is the behaviour the restored gate
## exists to provide - nothing previously asserted it for the button.
func _test_poke_button_lateral_sweep_never_presses(failures: Array[String]) -> void:
	var button := Node3D.new()
	button.set_script(XRPokeButtonScript)
	get_root().add_child(button)
	var fired := {"count": 0}
	button.pressed.connect(func(): fired["count"] += 1)
	button.poke_update(0, button.global_transform * Vector3(-0.100, -0.020, 0.0))
	button.poke_update(0, button.global_transform * Vector3(-0.020, -0.020, 0.0))
	button.poke_update(0, button.global_transform * Vector3(0.000, -0.020, 0.0))
	button.poke_update(0, button.global_transform * Vector3(0.020, -0.020, 0.0))
	button.poke_update(0, button.global_transform * Vector3(0.100, -0.020, 0.0))
	_check(failures, fired["count"] == 0,
			"poke button: a lateral sweep through the cap must not press, fired %d" % fired["count"])
	button.queue_free()


## The fast-diagonal-rescue-via-history case, for the round cap specifically.
## Sample A lands inside the cap's radius, in front (arms in_front, and is
## the evaluator's first-ever history entry for this source). Sample B lands
## OUTSIDE the radius - a shape exit - which must keep that history entry
## alive (and, like any exit, clears in_front). Sample C lands back inside
## the radius, bottomed out: entry_passes is false (in_front was cleared by
## B), so only the angle test - comparing C against the SURVIVING sample A,
## skipping B entirely - can rescue the press. If the radius exit forgets
## instead of merely leaving bounds, A is wiped along with B and there is
## nothing left for the angle test to compare against.
func _test_poke_button_fast_diagonal_rescued_by_history(failures: Array[String]) -> void:
	var button := Node3D.new()
	button.set_script(XRPokeButtonScript)
	get_root().add_child(button)
	var fired := {"count": 0}
	button.pressed.connect(func(): fired["count"] += 1)
	button.poke_update(0, button.global_transform * Vector3(0.000, 0.060, 0.0))  # A: inside, in front
	button.poke_update(0, button.global_transform * Vector3(0.100, 0.060, 0.0))  # B: outside the radius
	button.poke_update(0, button.global_transform * Vector3(0.010, -0.020, 0.0))  # C: inside, bottomed out
	_check(failures, fired["count"] == 1,
			"poke button: a fast diagonal rescued via surviving history must fire once, fired %d" % fired["count"])
	button.queue_free()


## Drives the button through its REAL _physics_process group-iteration path
## (not poke_update directly) with two real XRPokeInteractor nodes, to prove
## source_id stays tied to a given (interactor, hand) pair even when the
## interactor SET's membership changes between frames - the scenario
## position-based ids (assigned by loop order) cannot survive.
##
## Tick 1: interactor A alone in the group; its hand 0 gets a sample that is
## IN FRONT (arms in_front for A's source_id) but not deep enough to press.
## A then leaves the group WITHOUT ever reporting Vector3.INF first (a
## controller reconnecting, an interactor freed) - nothing tells the button
## A's source is gone, so its armed state simply sits there.
##
## Tick 2: a brand-new interactor B is now the sole (and therefore
## first-by-position) group member. Its hand 0 sends a single DEEP sample -
## its very first contact ever. Under position-keying this lands on the SAME
## source_id A's hand 0 used in tick 1 (both are "the first (source, hand)
## pair found"), inheriting A's leftover in_front=true and pressing off a
## single sample B never itself approached through - a wrong-hand press.
## Under stable per-(interactor, hand) ids, B gets its own fresh id with no
## armed in_front and no history, so a lone deep sample cannot press.
func _test_poke_button_source_ids_survive_group_reordering(failures: Array[String]) -> void:
	var button := Node3D.new()
	button.set_script(XRPokeButtonScript)
	get_root().add_child(button)
	var fired := {"count": 0}
	button.pressed.connect(func(): fired["count"] += 1)

	var interactor_a := Node.new()
	interactor_a.set_script(XRPokeInteractorScript)
	get_root().add_child(interactor_a)
	interactor_a.set_physics_process(false)  # deterministic: no real XR tracking to overwrite _points
	interactor_a._points[0] = button.global_transform * Vector3(0.0, 0.060, 0.0)
	interactor_a._points[1] = Vector3.INF
	button._physics_process(0.0)
	_check(failures, fired["count"] == 0,
			"reordering setup: arming in_front alone must not press, fired %d" % fired["count"])

	interactor_a.remove_from_group(XRPokeInteractorScript.GROUP)
	var interactor_b := Node.new()
	interactor_b.set_script(XRPokeInteractorScript)
	get_root().add_child(interactor_b)
	interactor_b.set_physics_process(false)
	interactor_b._points[0] = button.global_transform * Vector3(0.0, -0.020, 0.0)
	interactor_b._points[1] = Vector3.INF
	button._physics_process(0.0)
	_check(failures, fired["count"] == 0,
			"reordering: a new source must not inherit another source's armed state after a group-membership change, fired %d" % fired["count"])

	button.queue_free()
	interactor_a.queue_free()
	interactor_b.queue_free()


## Task 6: the aiming dot must stop ON the surface once the target reports a
## pin instead of sinking to the raw fingertip depth. The pokeable only starts
## pinning once the finger has crossed the surface, so the sequence below
## first arms entry with a sample in front, then pushes past the surface to
## get a pin - the same geometry _test_pokeable_reports_a_pin uses.
func _test_marker_prefers_the_pinned_point(failures: Array[String]) -> void:
	var interactor := Node.new()
	interactor.set_script(XRPokeInteractorScript)
	get_root().add_child(interactor)
	var pokeable := _make_pokeable()
	pokeable.poke_update(0, Vector3(0.0, 0.0, 0.050))
	pokeable.poke_update(0, Vector3(0.0, 0.0, -0.030))
	# GDScript has no true privacy - the underscore is convention - so the test
	# sets the dispatch state directly rather than adding a test seam to
	# production code.
	interactor._active[0] = {pokeable: true}
	interactor._points[0] = Vector3(0.0, 0.0, -0.030)
	var marker: Vector3 = interactor.get_marker_point(0)
	_check(failures, is_equal_approx(marker.z, 0.0),
			"marker: expected the pinned point on the surface, got z=%f" % marker.z)
	interactor.queue_free()
	pokeable.get_parent().queue_free()


## Companion to the test above: an active target whose pin is Vector3.INF (no
## contact yet, per _test_pokeable_pin_is_inf_without_contact) must NOT freeze
## the marker at INF - it must fall through to the raw fingertip point. This
## is what actually exercises the INF guard: without this case, a mutation
## that returned the pin unconditionally (dropping the `pin != Vector3.INF`
## check) would still pass the test above, since that test's pokeable DOES
## have a pin.
func _test_marker_falls_back_when_pin_is_inf(failures: Array[String]) -> void:
	var interactor := Node.new()
	interactor.set_script(XRPokeInteractorScript)
	get_root().add_child(interactor)
	var pokeable := _make_pokeable()
	# No poke_update at all, so pokeable.get_poke_pin(0) is Vector3.INF.
	interactor._active[0] = {pokeable: true}
	var raw_point := Vector3(0.020, 0.030, 0.008)
	interactor._points[0] = raw_point
	var marker: Vector3 = interactor.get_marker_point(0)
	_check(failures, marker.is_equal_approx(raw_point),
			"marker: expected fallback to the raw point when the pin is INF, got %s" % [marker])
	interactor.queue_free()
	pokeable.get_parent().queue_free()


func _test_poke_button_thresholds_are_unchanged(failures: Array[String]) -> void:
	var button := Node3D.new()
	button.set_script(XRPokeButtonScript)
	get_root().add_child(button)
	# travel 0.022, press_fraction 0.7 -> press at p >= 0.0154, re-arm at
	# p <= 0.0077. Expressed canonically: press_depth 0.0066, release 0.0143.
	_check(failures, is_equal_approx(button.canonical_press_depth(), 0.0066),
			"poke button: press_depth must be travel * (1 - press_fraction), got %f"
					% button.canonical_press_depth())
	_check(failures, is_equal_approx(button.canonical_release_depth(), 0.0143),
			"poke button: release_depth must be travel * (1 - press_fraction * 0.5), got %f"
					% button.canonical_release_depth())
	button.queue_free()
