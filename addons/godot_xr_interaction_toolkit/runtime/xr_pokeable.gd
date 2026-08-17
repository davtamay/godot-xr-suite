@tool
@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_poke_interactor.svg")
class_name XRPokeable
extends Node3D

## Makes an object POKEABLE (Unity's XRPokeFilter equivalent): parent this
## inside anything with a CollisionObject3D and a fingertip pushing into the
## chosen face emits pressed / released. The XRPokeInteractor finds pokeables
## by PHYSICS (a sphere around the fingertip), so a scene can hold many poke
## targets and only the ones near a finger cost anything - Unity-style scaling.
##
## Self-wiring like the affordances: walks up to the collision body and marks
## it. Per-object poke direction + depth live here, so different buttons can
## face different ways.
##
## PLACEMENT: the press plane is this node's OWN origin plane (local z = 0 for
## poke_face's normal), not the body's centre. Place this node ON the visible
## face you want pokeable, not at the middle of the box/body it is parented
## to - three targets in XRPokeStation shipped at the body centre by mistake
## before this was written down, which fires the press before a finger
## visually reaches the surface and clamps the marker pin to a plane inside
## the body.

## Which local face the finger approaches from (the outward normal). Default
## +Z = the front of a panel/button facing -Z.
enum Face { X_PLUS, X_MINUS, Y_PLUS, Y_MINUS, Z_PLUS, Z_MINUS }

signal pressed(hand: int)
signal released(hand: int)
## An aborted press: the fingertip left the face while still down. Buttons
## conventionally fire on RELEASE, so without this a slide-off ACTIVATES them.
signal cancelled(hand: int)
## Opt-in drag reporting, in metres along the face's own u/v axes.
signal dragged(hand: int, delta: Vector2)
## A drag ended (retracted past release_depth) without activating. Distinct
## from `released`/`cancelled` because interpret_drag suppresses those on a
## drag's terminal retraction - without THIS signal nothing tells a consumer
## the drag is over at all.
signal drag_ended(hand: int)

const _Evaluator := preload("res://addons/godot_xr_interaction_toolkit/runtime/poke/xr_poke_evaluator.gd")

@export var poke_face := Face.Z_PLUS

@export_group("Poke Feel")
## Assign to take press depth and the approach gate from one project-wide
## resource. When set it WINS over the exports below.
@export var poke_profile: XRPokeProfile
## Finger must come within this depth of the surface to press, and retract past
## the second to release (hysteresis stops flicker). Metres.
@export var press_depth := 0.012
@export var release_depth := 0.04
## Half-extents of the pokeable face (metres) - a poke outside this rectangle is
## ignored. Zero = no bounds (the whole plane pokes).
@export var half_size := Vector2(0.05, 0.05)
## Require the fingertip to have been seen in FRONT of this face before it can
## press, so a hand sweeping sideways across a row of buttons does not press
## each one it crosses.
@export var require_entry_through_face := true
## Travel must point inward within this angle at the moment of crossing.
@export_range(0.0, 90.0, 1.0) var max_approach_angle := 60.0
## Below this displacement the direction is noise and the angle test abstains.
@export_range(0.0, 0.02, 0.0005) var min_approach_travel := 0.003
## Report drags instead of activating on let-go - for handles, not buttons.
@export var interpret_drag := false
@export_range(0.001, 0.1, 0.001) var drag_threshold := 0.01
## Widens half_size by this factor for the bounds test, but ONLY once a
## source is pressed - entry always uses half_size exactly, so approaching
## still requires landing squarely on the face and neighbouring targets
## cannot steal a press. Raise this for a target whose visible body is much
## narrower than the finger's natural drift while sliding along it (a drag
## handle), so wandering off the narrow body mid-drag is not read as a
## deliberate slide-off-to-cancel. Leave at 1.0 (a no-op) for anything meant
## to cancel on slide-off, including buttons and panels - see
## XRPokeEvaluator.bounds_retain_scale for why the default must stay 1.0.
@export_range(1.0, 6.0, 0.1) var bounds_retain_scale := 1.0

var _body: CollisionObject3D
var _evaluator: XRPokeEvaluator
var _pins := {}  # hand -> world-space pinned point


func _sync_evaluator() -> void:
	if _evaluator == null:
		_evaluator = _Evaluator.new()
	_evaluator.press_depth = press_depth
	_evaluator.release_depth = release_depth
	_evaluator.half_size = half_size
	_evaluator.require_entry_through_face = require_entry_through_face
	_evaluator.max_approach_angle = max_approach_angle
	_evaluator.min_approach_travel = min_approach_travel
	_evaluator.interpret_drag = interpret_drag
	_evaluator.drag_threshold = drag_threshold
	_evaluator.bounds_retain_scale = bounds_retain_scale
	_evaluator.apply_profile(poke_profile)


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		return
	var cursor := get_parent()
	while cursor != null and not (cursor is CollisionObject3D):
		cursor = cursor.get_parent()
	_body = cursor as CollisionObject3D
	if _body:
		_body.set_meta("xr_pokeable", self)


func _exit_tree() -> void:
	if _body and is_instance_valid(_body) and _body.get_meta("xr_pokeable", null) == self:
		_body.remove_meta("xr_pokeable")


func _get_configuration_warnings() -> PackedStringArray:
	var cursor := get_parent()
	while cursor != null:
		if cursor is CollisionObject3D:
			return PackedStringArray()
		cursor = cursor.get_parent()
	return PackedStringArray(["Place this inside a body with a collider (StaticBody3D/Area3D)."])


## Where a drive should put a fingertip, straight from the evaluator's own
## contract: the surface is this node's plane (z = 0 along the face normal),
## a press fires at z <= press_depth, re-arms above release_depth, and
## cancels below -release_depth. So: approach from outside release_depth
## ALONG THE NORMAL (which is also what require_entry_through_face demands),
## press to half press_depth - inside the firing band, far from the cancel
## floor - and retract well clear. XRPokeButton has described itself this
## way since the hint system landed; this block never did, which left every
## runtime-built pokeable invisible to a sweep.
func drive_hint() -> Dictionary:
	var normal := _local_normal()
	return {
		"kind": "poke",
		"gesture": "point",
		"point": to_global(normal * (press_depth * 0.5)),
		"approach": to_global(normal * (release_depth + 0.03)),
		"release": to_global(normal * (release_depth + 0.06)),
	}


## Driven by the interactor with the world-space fingertip.
func poke_update(hand: int, world_point: Vector3) -> void:
	_sync_evaluator()
	var local := global_transform.affine_inverse() * world_point
	var normal := _local_normal()
	var u_axis := _plane_u(normal)
	var v_axis := _plane_v(normal)
	var depth := local.dot(normal)
	var planar := local - normal * depth
	# Canonical frame: +Z outward, z = distance in front of the surface.
	var canonical := Vector3(planar.dot(u_axis), planar.dot(v_axis), depth)
	var result: Dictionary = _evaluator.evaluate(hand, canonical)
	var pinned: Vector3 = result["pinned_point"]
	if pinned == Vector3.INF:
		_pins.erase(hand)
	else:
		_pins[hand] = global_transform * (u_axis * pinned.x + v_axis * pinned.y + normal * pinned.z)
	_emit(hand, result)


## The poke source lost its point (hand untracked / moved away).
func poke_end(hand: int) -> void:
	if _evaluator == null:
		return
	_pins.erase(hand)
	var event: int = _evaluator.forget(hand)
	if event == _Evaluator.Event.CANCELLED:
		cancelled.emit(hand)


func is_pressed() -> bool:
	return _evaluator != null and _evaluator.is_pressed()


## The world-space point where the source currently registers on this face:
## the raw point while the source is in front of the surface, clamped onto
## the surface (z = 0) once the source pushes past it. Vector3.INF whenever
## the source is off the face entirely - outside the bounds rectangle or
## outside the working z-band - so a marker never snaps onto the face for a
## point that is actually beside it.
func get_poke_pin(hand: int) -> Vector3:
	return _pins.get(hand, Vector3.INF)


func _emit(hand: int, result: Dictionary) -> void:
	match int(result["event"]):
		_Evaluator.Event.PRESSED:
			pressed.emit(hand)
		_Evaluator.Event.RELEASED:
			released.emit(hand)
		_Evaluator.Event.CANCELLED:
			_pins.erase(hand)
			cancelled.emit(hand)
		_Evaluator.Event.DRAG:
			dragged.emit(hand, result["drag_delta"])
		_Evaluator.Event.DRAG_ENDED:
			drag_ended.emit(hand)


## Outward face normal in local space (the finger presses toward -normal).
func _local_normal() -> Vector3:
	match poke_face:
		Face.X_PLUS: return Vector3.RIGHT
		Face.X_MINUS: return Vector3.LEFT
		Face.Y_PLUS: return Vector3.UP
		Face.Y_MINUS: return Vector3.DOWN
		Face.Z_MINUS: return Vector3.FORWARD  # -Z
		_: return Vector3.BACK                # Z_PLUS = +Z


func _plane_u(normal: Vector3) -> Vector3:
	var up := Vector3.UP if absf(normal.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	# up.cross(normal), not normal.cross(up): for the default Z_PLUS face the
	# latter yields u = -X, v = -Y - a 180 degree rotation about the normal
	# from the body's own frame, so a drag reported world +X came back
	# negated. up.cross(normal) gives u = +X, v = +Y for Z_PLUS, still
	# right-handed (u.cross(v) == normal), and the drag axes now agree with
	# the body's own.
	return up.cross(normal).normalized()


func _plane_v(normal: Vector3) -> Vector3:
	return normal.cross(_plane_u(normal)).normalized()
