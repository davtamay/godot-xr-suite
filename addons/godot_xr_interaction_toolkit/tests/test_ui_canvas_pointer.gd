extends SceneTree

## Headless tests for XRUICanvasInteractable's pointer OWNERSHIP: which of the
## several interactors that may be hovering one panel is allowed to drive the
## SubViewport's single mouse cursor, and -- the part that actually broke --
## whether ownership comes BACK when the current owner leaves.
##
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_interaction_toolkit/tests/test_ui_canvas_pointer.gd

const Canvas := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_ui_canvas_interactable.gd")

var _failures: Array[String] = []

## A ray interactor stand-in: the panel only ever asks for get_ray_state(), and
## giving each hand a different hit point is what makes the recorded cursor
## position identify WHICH hand drove it.
class FakeRay extends Node3D:
	var interaction_layers := 1
	var _end := Vector3.ZERO
	var _valid := true

	func _init(end: Vector3) -> void:
		_end = end

	func get_ray_state() -> Dictionary:
		if not _valid:
			return {"valid": false}
		return {
			"valid": true,
			"origin": _end + Vector3(0.0, 0.0, 1.0),
			"direction": Vector3.FORWARD,
			"hit": true,
			"end": _end,
		}

## Records every mouse motion the panel pushes into its viewport, so the test
## asserts on real InputEvents rather than on the panel's private bookkeeping.
class Probe extends Control:
	var positions: Array[Vector2] = []

	# _input, not _gui_input: gui routing needs a laid-out rect and mouse
	# capture, which would make the probe measure Control layout instead of
	# what this suite is about -- whether the panel pushed the event at all.
	func _input(event: InputEvent) -> void:
		if event is InputEventMouseMotion:
			positions.append((event as InputEventMouseMotion).position)

func _init() -> void:
	pass

## Deferred to _process: nodes added during _init() are not inside the tree yet,
## and the panel's _ready needs to run. Same constraint the other suites document.
func _process(_delta: float) -> bool:
	_test_second_hand_takes_the_cursor(_failures)
	_test_owner_leaving_hands_the_cursor_back(_failures)
	_test_press_outranks_a_newly_arriving_hand(_failures)
	_test_press_keeps_ownership_after_release(_failures)
	_test_freed_interactor_does_not_wedge_the_panel(_failures)
	_test_a_departed_hand_cannot_keep_the_cursor(_failures)
	_test_reentry_returns_to_the_top(_failures)
	_test_teardown_does_not_map_through_a_dead_transform(_failures)
	if _failures.is_empty():
		print("XR UI canvas pointer: PASS")
		quit(0)
		return true
	for failure in _failures:
		push_error(failure)
	print("XR UI canvas pointer: FAIL (%d)" % _failures.size())
	quit(1)
	return true

## Builds a panel whose viewport records motion. Returns {panel, probe}.
func _make_panel() -> Dictionary:
	var panel := Node3D.new()
	panel.set_script(Canvas)
	panel.panel_size = Vector2(2.0, 2.0)
	panel.viewport_pixel_size = Vector2i(100, 100)
	panel.screen_pointer_enabled = false

	var viewport := SubViewport.new()
	viewport.name = "Viewport"
	panel.add_child(viewport)
	var probe := Probe.new()
	viewport.add_child(probe)
	panel.viewport_path = NodePath("Viewport")

	get_root().add_child(panel)
	return {"panel": panel, "probe": probe}

## panel_size 2x2 mapped onto 100x100 px: local x -0.5 -> 25px, +0.5 -> 75px.
func _left_ray() -> FakeRay:
	return FakeRay.new(Vector3(-0.5, 0.0, 0.0))

func _right_ray() -> FakeRay:
	return FakeRay.new(Vector3(0.5, 0.0, 0.0))

const LEFT_PX := 25.0
const RIGHT_PX := 75.0

func _last_x(probe: Probe) -> float:
	if probe.positions.is_empty():
		return NAN
	return probe.positions.back().x

## Drives one frame of the panel's own per-frame pointer update, which is what
## keeps the cursor tracking a stationary hover between events.
func _tick(panel: Node) -> void:
	panel._process(0.016)

func _test_second_hand_takes_the_cursor(failures: Array[String]) -> void:
	var built := _make_panel()
	var panel: Node = built["panel"]
	var probe: Probe = built["probe"]
	var left := _left_ray()
	var right := _right_ray()

	panel._notify_hover_entered(left)
	_tick(panel)
	if not is_equal_approx(_last_x(probe), LEFT_PX):
		failures.append("second_hand: left should own the cursor first, got x=%s" % _last_x(probe))

	# One viewport has one mouse, so the most recent hand takes it. That part
	# was never broken; it is asserted so the fallback fix cannot regress it
	# into "the first hand keeps the cursor forever".
	panel._notify_hover_entered(right)
	_tick(panel)
	if not is_equal_approx(_last_x(probe), RIGHT_PX):
		failures.append("second_hand: right should take the cursor, got x=%s" % _last_x(probe))
	panel.free()

func _test_owner_leaving_hands_the_cursor_back(failures: Array[String]) -> void:
	# THE REGRESSION. Both hands point at the menu, the second one leaves, and
	# the first -- which never stopped hovering, so it never re-enters -- must
	# get the cursor back. It previously went to null and that hand's buttons
	# stopped highlighting for the rest of the scene.
	var built := _make_panel()
	var panel: Node = built["panel"]
	var probe: Probe = built["probe"]
	var left := _left_ray()
	var right := _right_ray()

	panel._notify_hover_entered(left)
	panel._notify_hover_entered(right)

	# Measured across the exit ITSELF with no frame in between: the handback has
	# to be immediate. A cursor that only catches up on the next _process leaves
	# the viewport holding the departed hand's last position for a frame, which
	# is long enough for a click arriving with the exit to land in the wrong place.
	probe.positions.clear()
	panel._notify_hover_exited(right)

	if panel.get_pointer_driver() != left:
		failures.append("hand_back: left still hovers, so it must own the cursor after right leaves")
	if probe.positions.is_empty():
		failures.append("hand_back: nothing pushed on exit -- the surviving hand waits a frame for the cursor")
	elif not is_equal_approx(_last_x(probe), LEFT_PX):
		failures.append("hand_back: cursor should return to left (%s), got x=%s" % [LEFT_PX, _last_x(probe)])

	# ...and it keeps driving on subsequent frames, not just the one event.
	probe.positions.clear()
	_tick(panel)
	if probe.positions.is_empty() or not is_equal_approx(_last_x(probe), LEFT_PX):
		failures.append("hand_back: left stopped driving the cursor after the handback, x=%s" % _last_x(probe))
	panel.free()

func _test_press_outranks_a_newly_arriving_hand(failures: Array[String]) -> void:
	# You must not lose the cursor mid-click because the other hand drifted onto
	# the panel: the press would land wherever that hand happened to point.
	var built := _make_panel()
	var panel: Node = built["panel"]
	var probe: Probe = built["probe"]
	var left := _left_ray()
	var right := _right_ray()

	panel._notify_hover_entered(left)
	panel._notify_select_entered(left)
	panel._notify_hover_entered(right)

	if panel.get_pointer_driver() != left:
		failures.append("press_outranks: the pressing hand must keep the cursor while held")
	probe.positions.clear()
	_tick(panel)
	if not is_equal_approx(_last_x(probe), LEFT_PX):
		failures.append("press_outranks: cursor moved off the press to x=%s" % _last_x(probe))
	panel.free()

func _test_press_keeps_ownership_after_release(failures: Array[String]) -> void:
	# Releasing should leave the cursor with the hand that just clicked, not
	# snap it to whichever hand happens to also be resting on the panel.
	var built := _make_panel()
	var panel: Node = built["panel"]
	var probe: Probe = built["probe"]
	var left := _left_ray()
	var right := _right_ray()

	# left hovers FIRST and right arrives after, so left is at the BOTTOM of the
	# stack when it clicks. Only the press claiming ownership can leave it there
	# after the release -- if the press did not, the idle right hand would take
	# the cursor the instant the click ended.
	panel._notify_hover_entered(left)
	panel._notify_hover_entered(right)
	panel._notify_select_entered(left)
	panel._notify_select_exited(left)

	if panel.get_pointer_driver() != left:
		failures.append("after_release: the hand that clicked should still own the cursor")
	probe.positions.clear()
	_tick(panel)
	if not is_equal_approx(_last_x(probe), LEFT_PX):
		failures.append("after_release: cursor jumped to x=%s" % _last_x(probe))
	panel.free()

func _test_freed_interactor_does_not_wedge_the_panel(failures: Array[String]) -> void:
	# A scene change frees interactors without ever emitting hover_exited, so a
	# dead node can sit on top of the stack. It must be skipped, not returned.
	var built := _make_panel()
	var panel: Node = built["panel"]
	var probe: Probe = built["probe"]
	var left := _left_ray()
	var right := _right_ray()

	panel._notify_hover_entered(left)
	panel._notify_hover_entered(right)
	right.free()

	if panel.get_pointer_driver() != left:
		failures.append("freed: a freed owner must fall through to the live hand")
	probe.positions.clear()
	_tick(panel)
	if probe.positions.is_empty() or not is_equal_approx(_last_x(probe), LEFT_PX):
		failures.append("freed: cursor did not fall back to left, got x=%s" % _last_x(probe))
	panel.free()

func _test_a_departed_hand_cannot_keep_the_cursor(failures: Array[String]) -> void:
	# Click a button then sweep that hand off the panel. The click pushes the
	# hand onto the stack a SECOND time, and Array.erase only removes the first
	# occurrence -- so without erase-before-append the departed hand is left on
	# top and keeps driving a cursor it can no longer aim.
	var built := _make_panel()
	var panel: Node = built["panel"]
	var probe: Probe = built["probe"]
	var left := _left_ray()
	var right := _right_ray()

	panel._notify_hover_entered(left)
	panel._notify_hover_entered(right)
	panel._notify_select_entered(left)
	panel._notify_select_exited(left)
	panel._notify_hover_exited(left)

	if panel.get_pointer_driver() != right:
		failures.append("departed: the hand that left the panel is still driving the cursor")
	probe.positions.clear()
	_tick(panel)
	if not is_equal_approx(_last_x(probe), RIGHT_PX):
		failures.append("departed: cursor should be right's (%s), got x=%s" % [RIGHT_PX, _last_x(probe)])
	panel.free()

func _test_reentry_returns_to_the_top(failures: Array[String]) -> void:
	# Sweeping off the panel and back on must make that hand the owner again;
	# a plain append would leave it buried under its own stale entry.
	var built := _make_panel()
	var panel: Node = built["panel"]
	var probe: Probe = built["probe"]
	var left := _left_ray()
	var right := _right_ray()

	panel._notify_hover_entered(left)
	panel._notify_hover_entered(right)
	panel._notify_hover_exited(left)
	panel._notify_hover_entered(left)

	if panel.get_pointer_driver() != left:
		failures.append("reentry: the re-entering hand should be back on top")
	probe.positions.clear()
	_tick(panel)
	if not is_equal_approx(_last_x(probe), LEFT_PX):
		failures.append("reentry: cursor x=%s" % _last_x(probe))
	panel.free()

func _test_teardown_does_not_map_through_a_dead_transform(failures: Array[String]) -> void:
	# A scene change tears the panel out while hands are still on it, and the
	# exit signals arrive AFTER it has left the tree. global_transform there
	# returns IDENTITY instead of failing, so the handback re-maps the cursor as
	# though the panel sat at the world origin and overwrites the cached pointer
	# position with garbage -- which _push_mouse_button then uses as the pixel
	# for the release click. Nothing pushes at teardown (the viewport is out of
	# the tree too, so the send side is already guarded), which is exactly why
	# the CACHED POSITION is the thing to assert on: it is the damage that
	# outlives the frame.
	var built := _make_panel()
	var panel: Node = built["panel"]
	var left := _left_ray()
	var right := _right_ray()

	# The panel must NOT sit at the origin, or an identity mapping would land on
	# the same pixel as the correct one and the bug would be invisible.
	panel.position = Vector3(1.0, 0.5, -2.0)
	left._end = panel.position + Vector3(-0.5, 0.0, 0.0)
	right._end = panel.position + Vector3(0.5, 0.0, 0.0)

	panel._notify_hover_entered(right)
	panel._notify_hover_entered(left)
	_tick(panel)
	if not is_equal_approx(panel._last_pointer_position.x, LEFT_PX):
		failures.append("teardown fixture: expected the cursor on left (%s) before teardown, got %s" % [LEFT_PX, panel._last_pointer_position.x])

	get_root().remove_child(panel)

	panel._notify_hover_exited(right)
	if not is_equal_approx(panel._last_pointer_position.x, LEFT_PX):
		failures.append("teardown: the handback re-mapped through an out-of-tree transform, cursor moved to x=%s" % panel._last_pointer_position.x)

	# The per-frame path has to hold the same line -- _process keeps running for
	# whatever part of the frame remains after the panel is detached.
	_tick(panel)
	if not is_equal_approx(panel._last_pointer_position.x, LEFT_PX):
		failures.append("teardown: _process re-mapped through a dead transform, cursor moved to x=%s" % panel._last_pointer_position.x)
	panel.free()
