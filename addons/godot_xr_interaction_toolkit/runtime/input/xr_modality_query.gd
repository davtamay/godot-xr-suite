class_name XRModalityQuery
extends RefCounted

## Asks "is this hand holding a controller, or is it bare?" in one place.
##
## The answer lives in godot_webxr_kit's XRInputModalityManager, which the
## toolkit must not depend on: the toolkit is the foundation and the kit sits
## above it. So the lookup goes through a group, the way every other
## cross-addon reach in this suite does - but the group name, the enum values
## and the "no manager present" policy were repeated at six call sites, each
## with its own raw integer and its own fallback. A manager that renamed its
## enum would have been caught in none of them.
##
## Interactors call these instead. With no manager in the scene every query
## returns "unknown", and callers treat unknown as "do not filter" - which is
## what a scene without modality management should do.

## Mirrors XRInputModalityManager.Modality. Duplicated deliberately: the
## toolkit cannot preload a script from an addon that may not be installed.
enum Modality { NONE, CONTROLLER, HAND }

const GROUP := &"xr_input_modality_manager"


## The manager node, or null when the scene has none.
static func find_manager(node: Node) -> Node:
	if node == null or not node.is_inside_tree():
		return null
	var manager := node.get_tree().get_first_node_in_group(GROUP)
	if manager != null and manager.has_method(&"get_modality"):
		return manager
	return null


## The reported modality for a hand, or NONE when unknown.
static func modality_of(node: Node, hand: int) -> Modality:
	var manager := find_manager(node)
	if manager == null:
		return Modality.NONE
	return manager.call(&"get_modality", hand) as Modality


## True only when the hand is KNOWN to hold a controller.
static func is_controller(node: Node, hand: int) -> bool:
	return modality_of(node, hand) == Modality.CONTROLLER


## True only when the hand is KNOWN to be tracked bare.
static func is_hand(node: Node, hand: int) -> bool:
	return modality_of(node, hand) == Modality.HAND


## True when some modality has been resolved for this hand. Callers that
## filter behavior by modality should treat false as "do not filter": an
## unmanaged scene must keep working.
static func is_resolved(node: Node, hand: int) -> bool:
	return modality_of(node, hand) != Modality.NONE
