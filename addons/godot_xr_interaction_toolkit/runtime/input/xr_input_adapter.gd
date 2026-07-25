class_name XRInputAdapter
extends Node

## Abstract input source for interactors. Interaction logic must never know
## whether poses/select events come from WebXR or OpenXR; subclasses do.

enum Hand { LEFT = 0, RIGHT = 1 }
enum SourceKind { NONE, CONTROLLER, HAND }

signal select_started(hand: int)
signal select_ended(hand: int)
signal activate_started(hand: int)
signal activate_ended(hand: int)

## Returns {origin: Vector3, direction: Vector3, basis: Basis} in GLOBAL space,
## or {} when this hand has no tracked aim pose.
func get_aim_pose(_hand: int) -> Dictionary:
    return {}

## Returns {origin: Vector3, basis: Basis} in GLOBAL space for near/direct
## grabbing. Default falls back to aim so simple adapters only implement one
## pose path.
func get_grip_pose(hand: int) -> Dictionary:
    return get_aim_pose(hand)

func is_hand_active(hand: int) -> bool:
    return not get_aim_pose(hand).is_empty()

## Whether a select is currently held for this hand. Interactors use it to
## detect a WEDGED selection -- believing they hold something the input says
## was already let go -- and recover instead of going deaf to hover and select.
func is_select_down(_hand: int) -> bool:
    return false

func get_source_kind(_hand: int) -> int:
    return SourceKind.NONE
