class_name XRInteractionArbiter
extends Node

## One explicit interaction mode per hand, so "when can I do each action" is a
## single testable rule instead of suppression booleans scattered across three
## interactors. See docs/interaction-arbitration-design.md.
##
## OPT-IN: with no arbiter in the scene every interactor keeps its existing
## suppression behaviour exactly. Adding this node is what changes anything.
##
## Deliberately NOT a proximity query of its own. XRDirectInteractor already
## sphere-queries at the grip pose every frame with a tuned hover_radius; this
## reads that result. So there is no second radius to keep in sync with a
## value that was earned on-device, and the hysteresis lives in TIME instead.

const XRInputAdapter := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_input_adapter.gd")

const GROUP := "xr_interaction_arbiter"

enum Mode { NONE, NEAR, FAR, TELEPORT }

@export var enabled := true
## How long NEAR survives after its candidate disappears. A hand resting at the
## edge of a table makes the direct interactor's candidate flicker frame to
## frame; without this the far ray strobes on and off. Entering NEAR is
## immediate -- latency on the way IN reads as unresponsive, latency on the way
## OUT reads as stable, so the damping is one-sided by design.
@export_range(0.0, 1.0, 0.01) var near_release_dwell_sec := 0.12

var _mode := [Mode.NONE, Mode.NONE]
var _time_since_candidate := [INF, INF]
var _near_interactors: Array[XRDirectInteractor] = []

func _ready() -> void:
	add_to_group(GROUP)
	var scene := get_tree().current_scene if get_tree() else null
	_collect_near_interactors(scene if scene != null else get_tree().root)

## The whole rule, as a pure function: no node state, no scene, no engine
## singletons, so every transition and the hysteresis band are provable
## headless. Order is load-bearing and is asserted by the tests.
static func resolve_mode(
		previous: int,
		hand_tracked: bool,
		near_candidate: bool,
		teleport_active: bool,
		time_since_candidate: float,
		minimum_dwell_sec: float) -> int:
	# No hand, no interaction -- this outranks even teleport, because an
	# untracked hand cannot be aiming anything.
	if not hand_tracked:
		return Mode.NONE
	# Teleport is exclusive and wins from every other mode, INCLUDING while a
	# near candidate is present: reaching past a table must not veto a
	# deliberate teleport. It is checked before proximity for exactly that
	# reason, and it is left the instant the driver stops aiming -- the arc
	# cannot outlive a state that owns both its entry and its exit.
	if teleport_active:
		return Mode.TELEPORT
	if near_candidate:
		return Mode.NEAR
	# Releasing NEAR waits out the dwell; every other transition is immediate.
	# The clock measures time since the candidate was last SEEN, not time in
	# the mode: a candidate flickering at the edge of the hover sphere never
	# changes the mode, so a time-in-mode clock would run out anyway and drop
	# to FAR mid-flicker -- which is the strobing this exists to prevent.
	if previous == Mode.NEAR and time_since_candidate < minimum_dwell_sec:
		return Mode.NEAR
	return Mode.FAR

func _process(delta: float) -> void:
	if not enabled:
		return
	for hand in [XRInputAdapter.Hand.LEFT, XRInputAdapter.Hand.RIGHT]:
		var candidate := _has_near_candidate(hand)
		# Reset on SIGHT, accumulate on absence -- see resolve_mode.
		_time_since_candidate[hand] = 0.0 if candidate else _time_since_candidate[hand] + delta
		_mode[hand] = resolve_mode(
			_mode[hand],
			_hand_tracked(hand),
			candidate,
			_is_teleport_aiming(hand),
			_time_since_candidate[hand],
			near_release_dwell_sec)

func mode_for(hand: int) -> int:
	if hand < 0 or hand >= _mode.size():
		return Mode.NONE
	return _mode[hand]

## The question every interactor asks. While disabled the arbiter answers true
## for everything, so a scene can A/B the whole state machine by flipping one
## flag without any interactor changing its own logic.
func is_mode_active(hand: int, mode: int) -> bool:
	if not enabled:
		return true
	return mode_for(hand) == mode

## Shared discovery, so three interactors do not each grow their own lookup.
static func find_in_tree(node: Node) -> XRInteractionArbiter:
	if node == null or not node.is_inside_tree():
		return null
	var found := node.get_tree().get_first_node_in_group(GROUP)
	return found as XRInteractionArbiter

func _hand_tracked(hand: int) -> bool:
	var tracker := XRHandTrackerResolver.get_tracker(hand)
	return tracker != null and tracker.has_tracking_data

## Reads the near-field interactor's ALREADY-COMPUTED candidate rather than
## running a second query with a second radius. A SELECTED object counts as a
## candidate too: a held object may be carried outside the hover sphere, and
## the far ray must not reappear mid-grab.
func _has_near_candidate(hand: int) -> bool:
	for interactor in _near_interactors:
		if not is_instance_valid(interactor) or int(interactor.hand) != hand:
			continue
		if interactor.get_selected() != null or interactor.get_hovered() != null:
			return true
	return false

## Cached at _ready: the direct interactors are rig children that do not come
## and go, and a per-frame tree walk for two nodes is waste.
func _collect_near_interactors(root: Node) -> void:
	if root is XRDirectInteractor:
		_near_interactors.append(root)
	for child in root.get_children():
		_collect_near_interactors(child)

func _is_teleport_aiming(hand: int) -> bool:
	for node in get_tree().get_nodes_in_group(XRLocomotion.GROUP):
		var locomotion := node as XRLocomotion
		if locomotion != null and locomotion.is_aiming(hand):
			return true
	return false
