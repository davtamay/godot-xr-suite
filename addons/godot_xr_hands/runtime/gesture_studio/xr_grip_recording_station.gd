@tool
@icon("res://addons/godot_xr_hands/icons/xr_gesture_recognizer.svg")
class_name XRGripRecordingStation
extends Node3D

## Record grips WITH THE OBJECT IN YOUR HAND.
##
## The Gesture Studio records poses in a vacuum: you mime holding something
## while holding nothing, and the result is a shape of a hand pretending. For
## gestures that is fine - a fist is a fist. For GRIPS it is the whole problem,
## because a grip is a hand's answer to a particular object, and you cannot
## give the answer without the question in front of you.
##
## This station puts the question there. Give it a list of objects; it presents
## them one at a time at a comfortable height, you wrap your hand around the
## real thing, and the recorded snapshot is saved under a name the matching
## grab point looks up. Nothing about the recorder changes - it still captures
## joint positions from a live hand - but now those joints were arranged by an
## actual object.
##
## Why this beats solving it: an auto-fitted grip curls each finger around one
## hinge until it touches the collider, which produces a plausible closure and
## never a human one - no splay, no thumb rolling across the barrel, no
## per-joint variation. Those are not parameters to tune, they are what a hand
## does. Recording is how you get them.
##
## Objects without a recorded grip keep working: a grab point set to
## "Auto (fit object)" fits the geometry, so the hundreds of props nobody will
## ever hand-author still get a hold. Record the hero props; let the rest fit.

## Objects to record grips for, in order. Each is instanced at the pedestal,
## recorded, then swapped for the next - so adding a tool to the session is
## adding a scene to this list, not writing anything.
@export var objects: Array[PackedScene] = []

## Where a recorded grip is looked up from. The saved name is
## "<prefix><object scene name>", so spray_can.tscn records "grip_spray_can",
## and a grab point selects that pose by the same name. Keep the prefix stable
## or previously recorded grips stop being found.
@export var grip_name_prefix := "grip_"

## Height the object is presented at - roughly where a hand rests when you are
## not reaching. Comfort matters: a grip recorded at an awkward reach is a
## record of the reach, not of the grip.
@export var present_height := 1.1

## Which hand records. The other hand's grip is mirrored from it at use time,
## the way authored grab points already mirror.
@export_enum("Left:0", "Right:1") var record_hand := 1

@export var recorder_path: NodePath

## The object currently presented, and how far through the list we are.
signal object_presented(index: int, total: int, name: String)
## A grip was recorded and saved under `grip_name`.
signal grip_recorded(grip_name: String, save_path: String)
## Every object in the list has been recorded.
signal session_finished

var _recorder: Node
var _current: Node3D = null
var _index := -1
var _pedestal: Node3D = null


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_recorder = get_node_or_null(recorder_path)
	if _recorder and _recorder.has_signal("recording_finished"):
		_recorder.recording_finished.connect(_on_recorded)
	_pedestal = Node3D.new()
	_pedestal.name = "Presented"
	_pedestal.position = Vector3(0.0, present_height, 0.0)
	add_child(_pedestal)


## Present the next object. Call again to advance; the station emits
## session_finished when the list runs out.
func present_next() -> void:
	_index += 1
	if _index >= objects.size():
		_clear_presented()
		session_finished.emit()
		return
	_present(_index)


func present_index(index: int) -> void:
	_index = clampi(index, 0, maxi(objects.size() - 1, 0))
	_present(_index)


## Record the grip for whatever is presented right now. The name comes from the
## object, so a recording always lands where the grab point will look for it.
func record_current() -> void:
	if _recorder == null or _current == null or not _recorder.has_method("start_recording"):
		return
	_recorder.start_recording(current_grip_name(), record_hand)


## The name this object's grip is saved under - derived from the scene file, so
## it is stable across sessions and needs no bookkeeping.
func current_grip_name() -> String:
	if _index < 0 or _index >= objects.size() or objects[_index] == null:
		return ""
	return grip_name_prefix + objects[_index].resource_path.get_file().get_basename()


func _present(index: int) -> void:
	_clear_presented()
	var packed: PackedScene = objects[index]
	if packed == null:
		return
	_current = packed.instantiate() as Node3D
	if _current == null:
		return
	# Presented INERT: a grabbable that can be picked up would be carried off
	# mid-recording, and a physics body would fall off the pedestal. The point
	# is to hold the shape still while a hand closes around it.
	_freeze(_current)
	_pedestal.add_child(_current)
	object_presented.emit(index, objects.size(), current_grip_name())


## Stop the presented object behaving like a prop: no gravity, no grabbing, no
## interaction. It is a reference shape for the duration.
func _freeze(node: Node) -> void:
	if node is RigidBody3D:
		(node as RigidBody3D).freeze = true
	if node.has_method("set_enabled"):
		node.set("enabled", false)
	elif "enabled" in node:
		node.set("enabled", false)
	for child in node.get_children():
		_freeze(child)


func _clear_presented() -> void:
	if _current and is_instance_valid(_current):
		_current.queue_free()
	_current = null


func _on_recorded(gesture, save_path: String) -> void:
	var recorded := ""
	if gesture and "gesture_name" in gesture:
		recorded = str(gesture.gesture_name)
	grip_recorded.emit(recorded, save_path)
