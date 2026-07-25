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
## Prints a line whenever a hand changes mode, naming the evidence that caused
## it. Change-gated, so it is quiet until something actually moves. For live
## on-device diagnosis; leave off in shipping scenes.
@export var debug_log := false

var _mode := [Mode.NONE, Mode.NONE]
var _time_since_candidate := [INF, INF]

func _ready() -> void:
	add_to_group(GROUP)

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

func _physics_process(delta: float) -> void:
	# Resolves even while disabled: `enabled` gates ANSWERS at is_mode_active,
	# not the resolution itself, so the in-headset mode readout stays truthful
	# during the arbiter-OFF leg of the A/B -- which is the leg being compared.
	# Runs in _physics_process because every consumer reads it there; resolving
	# in _process left the mode stale on extra physics ticks and accumulated the
	# dwell in a different clock domain from the one that consumes it.
	for hand in [XRInputAdapter.Hand.LEFT, XRInputAdapter.Hand.RIGHT]:
		var candidate := _has_near_candidate(hand)
		# Reset on SIGHT, accumulate on absence -- see resolve_mode.
		_time_since_candidate[hand] = 0.0 if candidate else _time_since_candidate[hand] + delta
		var previous: int = _mode[hand]
		var tracked := _hand_tracked(hand)
		var teleporting := _is_teleport_aiming(hand)
		_mode[hand] = resolve_mode(
			previous,
			tracked,
			candidate,
			teleporting,
			_time_since_candidate[hand],
			near_release_dwell_sec)
		if debug_log and _mode[hand] != previous:
			print("[arbiter] hand=%d %s -> %s | %s" % [
				hand, _mode_name(previous), _mode_name(_mode[hand]),
				_evidence(hand, tracked, candidate, teleporting)])

func _mode_name(mode: int) -> String:
	match mode:
		Mode.NEAR: return "NEAR"
		Mode.FAR: return "FAR"
		Mode.TELEPORT: return "TELEPORT"
		_: return "NONE"

## Names every input the decision was made from, so a stuck mode says WHICH
## piece of evidence is holding it rather than only that it is stuck.
func _evidence(hand: int, tracked: bool, candidate: bool, teleporting: bool) -> String:
	var direct_selected := false
	var direct_hovered := false
	var direct_valid := false
	for node in get_tree().get_nodes_in_group(XRDirectInteractor.GROUP):
		var direct := node as XRDirectInteractor
		if direct == null or int(direct.hand) != hand:
			continue
		direct_selected = direct_selected or direct.get_selected() != null
		direct_hovered = direct_hovered or direct.get_hovered() != null
		direct_valid = direct_valid or bool(direct.get_direct_state().get("valid", false))
	var poking := false
	for node in get_tree().get_nodes_in_group(XRPokeInteractor.GROUP):
		var poke := node as XRPokeInteractor
		poking = poking or (poke != null and poke.is_poking(hand))
	return "tracked=%s near=%s tele=%s | direct sel=%s hov=%s valid=%s | poking=%s" % [
		tracked, candidate, teleporting, direct_selected, direct_hovered, direct_valid, poking]

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

## "Does this hand have INPUT", not "does this hand have a hand tracker". A
## controller-driven hand has no XRHandTracker at all, so a tracker-only test
## pinned it in NONE forever and suppressed both ray and poke -- a terminal
## state on any controller rig. The modality manager is the authority when
## present (resolved by group, so no addon dependency is created); the hand
## tracker and the controller are each sufficient on their own otherwise.
func _hand_tracked(hand: int) -> bool:
	var manager := get_tree().get_first_node_in_group("xr_input_modality_manager")
	if manager != null and manager.has_method("get_modality"):
		# Any resolved modality means this hand is driving something.
		return int(manager.get_modality(hand)) >= 0
	var tracker := XRHandTrackerResolver.get_tracker(hand)
	if tracker != null and tracker.has_tracking_data:
		return true
	var controller := XRRigResolver.find_controller(self, hand)
	return controller != null and controller.get_is_active()

## Reads the near-field interactor's ALREADY-COMPUTED candidate rather than
## running a second query with a second radius. A SELECTED object counts as a
## candidate too: a held object may be carried outside the hover sphere, and
## the far ray must not reappear mid-grab.
func _has_near_candidate(hand: int) -> bool:
	# LIVE group lookup, deliberately -- this used to be a list cached at
	# _ready, which was built before the scene existed. Whatever it captured
	# (stale nodes from the outgoing scene) made it non-empty, so the "rescan
	# while empty" guard never fired and every entry failed is_instance_valid.
	# Grabbing therefore NEVER registered as near, while poke did, because poke
	# was already a live lookup. Symptom on device: the ray and cursor vanished
	# over UI but stayed drawn while holding a grabbed object.
	for node in get_tree().get_nodes_in_group(XRDirectInteractor.GROUP):
		var direct := node as XRDirectInteractor
		if direct == null or int(direct.hand) != hand:
			continue
		# A HELD object is near-evidence unconditionally.
		if direct.get_selected() != null:
			return true
		# A hover is only evidence while the interactor is CURRENTLY valid.
		# It stops refreshing _hovered while it holds something, and keeps the
		# last value when the grip pose goes away, so a stale hover could pin a
		# hand to NEAR forever -- and a pinned NEAR is a ray that can never
		# hover again. David, on device: one hand's cursor "stops working" and
		# will not hover any more. Near-ness must be true NOW, not last seen.
		if direct.get_hovered() != null and bool(direct.get_direct_state().get("valid", false)):
			return true
	# Poke reach counts as near-field too. NEAR cannot be derived from the GRAB
	# interactor alone: UI panels and poke buttons are not grab interactables,
	# so a hand reaching for a slider produced NO near candidate and the far
	# ray stayed drawn over the panel the finger was already touching. This is
	# the union of near-field evidence, which is what the mode is supposed to
	# mean -- the old rig got it from suppress_on_poke, and that wiring is gone.
	for node in get_tree().get_nodes_in_group(XRPokeInteractor.GROUP):
		var poke := node as XRPokeInteractor
		if poke != null and poke.is_poking(hand):
			return true
	return false


func _is_teleport_aiming(hand: int) -> bool:
	for node in get_tree().get_nodes_in_group(XRLocomotion.GROUP):
		var locomotion := node as XRLocomotion
		if locomotion != null and locomotion.is_aiming(hand):
			return true
	return false
