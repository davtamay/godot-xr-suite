@icon("res://addons/godot_xr_interaction_toolkit/icons/xr_ray_interactor.svg")
class_name XRGazeInteractor
extends "res://addons/godot_xr_interaction_toolkit/runtime/xr_ray_interactor.gd"

## Gaze and pinch: the eyes choose a target, a pinch from EITHER hand commits.
## One session-wide far pointer, for devices that have no controllers and whose
## gaze source raises no select events of its own (Meta VR Glasses). Everything
## past the pointer is an ordinary ray, so grabbables, mechanisms and UI panels
## work with no gaze-specific code on them.
##
## Drop one anywhere in a scene that has a rig. It finds the rig's input adapter
## itself, and adds its session features through the feature-provider contract.
## It is opt-in, not part of the rig: every feature a session requests has a
## cost, and an app that never uses gaze should not ask for eye tracking.
##
## Priority, in order:
## 1. An active near grab or touch on either hand yields gaze: direct wins.
## 2. A tracked gaze source owns far targeting, so hand and controller rays
##    stand down (XRRayInteractor.suppress_on_gaze).
## 3. When the source disconnects, those rays come back at once.
## 4. A lost pose clears the target straight away but keeps ownership for
##    tracking_loss_grace_seconds, so a blink does not flash rays on.
##
## Missing gaze is never replaced by head pose: a headset without eye tracking
## simply keeps its hand rays. head_directed_preview is an explicit development
## option, and tests plumbing, not gaze.
##
## There is no cursor by default. What is about to be selected shows through the
## target's own hover feedback.

const XRHandGestureProvider := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_gesture_provider.gd")

## The group rays and tools find this node by. Spelled out in XRRayInteractor,
## which this script extends.
const GROUP := "xr_gaze_interactor"
## Optional, always: a required feature would refuse the whole session on any
## browser without it. Same strings as WebXRFeatures, which this addon cannot
## reference because that kit depends on this one.
const _WEBXR_OPTIONAL_FEATURES := ["gaze-tracking", "eye-tracking"]
const _RESOLVE_INTERVAL_SEC := 0.5

## Off = this node does nothing and hand rays keep far targeting.
@export var enabled := true

@export_group("Targeting")
## How far off the gaze ray a target can sit and still be chosen. The ray itself
## wins first; this only helps a look that lands just beside something.
@export_range(0.5, 45.0, 0.5) var cone_angle_degrees := 5.0
## Maximum reach of the ray and the cone, in metres. Replaces the inherited
## max_distance, whose 6 m default is tuned for hands.
@export_range(1.0, 200.0, 1.0, "or_greater") var max_gaze_distance := 30.0
## Eyes dart. A target has to hold the most time in this window to take over, so
## a glance across the room does not change what a pinch would select. It also
## covers the look-away that tends to come just before a pinch. 0 = each frame's
## winner.
@export_range(0.0, 1.0, 0.01) var dwell_window_seconds := 0.15
## Yield while either hand has an active near grab or touch.
@export var suppress_when_direct_active := true
## Keep ownership across a lost pose for this long before rays may resume.
@export_range(0.0, 30.0, 0.5) var tracking_loss_grace_seconds := 5.0

@export_group("Filtering")
## One Euro cutoff at rest. Lower is steadier, with more lag.
@export_range(0.01, 10.0, 0.01) var filter_min_cutoff := 1.5
## One Euro speed coefficient. Higher reacts faster to large eye movements.
@export_range(0.0, 5.0, 0.01) var filter_beta := 0.05

@export_group("Development")
## Use the HEAD as the gaze source when the platform has none, so the plumbing
## can be tried on a headset without eye tracking. Validates feature negotiation
## and interaction flow, not eye-tracking accuracy. Never a fallback: it does
## nothing unless set, and a real gaze source still wins.
@export var head_directed_preview := false
## Show a hit reticle. Production gaze has no cursor.
@export var show_debug_reticle := false

var _connected := false
var _tracked := false
var _owns_far := false
var _loss_elapsed := 0.0
var _gaze_pose := {}
var _direction_filter := XROneEuroFilter.new()
var _dwell_samples: Array = []
var _dwell_key := 0
var _dwell_hits := {}
## The ray at the moment of commit, and how far the committing hand has moved
## since. The eyes are free again once something is held.
var _hold_pose := {}
var _hold_grip_origin = null
var _hold_offset := Vector3.ZERO
var _resolve_timer := 0.0
var _debug_last_line := ""


func _enter_tree() -> void:
	super()
	add_to_group(GROUP)
	add_to_group("webxr_feature_provider")


func _ready() -> void:
	super()
	# Ownership has to be settled before the rays ask for it. In tree order a ray
	# ticks first, so on the tick gaze appears it would hover for one step.
	process_physics_priority = -1
	max_distance = max_gaze_distance
	_direction_filter.resize(1)
	if show_debug_reticle:
		add_child(XRReticleVisual.new())
	if head_directed_preview:
		push_warning("XRGazeInteractor: head_directed_preview is on. The head is standing in for the eyes.")


## webxr_feature_provider contract, collected by webxr_bootstrap.gd before the
## session request.
func get_webxr_optional_features(_session_mode: String) -> PackedStringArray:
	return PackedStringArray(_WEBXR_OPTIONAL_FEATURES)


## Whether hand and controller far rays must stand down. Stays true while gaze
## yields to a near grab, so rays do not flash on during one.
func owns_far_targeting() -> bool:
	return enabled and _owns_far


func get_gaze_status() -> Dictionary:
	return {"connected": _connected, "tracked": _tracked, "owns_far_targeting": owns_far_targeting()}


func _physics_process(delta: float) -> void:
	if not enabled:
		if _owns_far or _hovered != null or _selected != null:
			_owns_far = false
			_gaze_pose = {}
			_release_select()
			_set_hovered(null)
		return
	_resolve_links(delta)
	_update_gaze(delta)
	super(delta)


## The rig may be a sibling added after this node, and the simulator and the
## actuator only re-point interactors that carry an adapter path, so a dropped
## block looks its links up itself, by the same rule webxr_rig.gd uses.
func _resolve_links(delta: float) -> void:
	if _adapter != null and is_instance_valid(_adapter) and _is_manager_valid():
		return
	_resolve_timer -= delta
	if _resolve_timer > 0.0:
		return
	_resolve_timer = _RESOLVE_INTERVAL_SEC
	if not _is_manager_valid():
		_resolve_manager()
	var origin := XRRigResolver.find_origin(self)
	if origin == null or origin.get_parent() == null:
		return
	var wanted := "WebXRInputAdapter" if OS.has_feature("web") else "OpenXRInputAdapter"
	var adapter := origin.get_parent().get_node_or_null(wanted)
	if adapter != null:
		set_input_adapter(adapter)


func _update_gaze(delta: float) -> void:
	var state := _read_gaze_state()
	var connected: bool = state.get("connected", false)
	var tracked: bool = state.get("tracked", false)
	if tracked:
		if not _tracked:
			_direction_filter.reset_all()
		_direction_filter.min_cutoff = filter_min_cutoff
		_direction_filter.beta = filter_beta
		var direction: Vector3 = _direction_filter.filter(0, state["direction"], delta).normalized()
		_gaze_pose = {
			"origin": state["origin"],
			"direction": direction,
			"basis": XRHandGestureProvider.basis_from_forward(direction),
		}
		_owns_far = true
		_loss_elapsed = 0.0
	else:
		_gaze_pose = {}
		_clear_dwell()
		if not connected:
			_owns_far = false
			_loss_elapsed = 0.0
		elif _owns_far:
			_loss_elapsed += delta
			if _loss_elapsed > tracking_loss_grace_seconds:
				_owns_far = false
	_connected = connected
	_tracked = tracked
	if debug_log:
		_log_state()


func _read_gaze_state() -> Dictionary:
	var state: Dictionary = {"connected": false, "tracked": false}
	if _adapter != null and _adapter.has_method("get_gaze_state"):
		state = _adapter.get_gaze_state()
	if head_directed_preview and not state.get("connected", false):
		return _head_directed_state()
	return state


func _head_directed_state() -> Dictionary:
	var camera := XRRigResolver.find_camera(self)
	if camera == null:
		return {"connected": false, "tracked": false}
	var xf := camera.global_transform
	return {
		"connected": true,
		"tracked": true,
		"origin": xf.origin,
		"direction": (-xf.basis.z).normalized(),
		"basis": xf.basis.orthonormalized(),
	}


func _log_state() -> void:
	var line := "[gaze] connected=%s tracked=%s owns_far=%s hovered=%s selected=%s adapter=%s" % [
		_connected, _tracked, _owns_far, _hovered, _selected, _adapter != null]
	if line != _debug_last_line:
		_debug_last_line = line
		print(line)


func _aim_pose() -> Dictionary:
	if _selected != null:
		return _held_ray_pose()
	return _gaze_pose


## While something is held the ray stops following the eyes and moves with the
## hand that committed, by its position delta. Looking around does not drag the
## object, and the object does not snap to the hand.
func _held_ray_pose() -> Dictionary:
	if _hold_pose.is_empty():
		return {}
	if _adapter != null and _hold_grip_origin != null:
		var grip: Dictionary = _adapter.get_grip_pose(hand)
		if not grip.is_empty():
			_hold_offset = (grip["origin"] as Vector3) - (_hold_grip_origin as Vector3)
	var held := _hold_pose.duplicate()
	held["origin"] = (_hold_pose["origin"] as Vector3) + _hold_offset
	return held


## The eye ray must not feed the hand stabilizer: that state belongs to the hand
## ray this one displaced.
func _report_aim_endpoint(_end: Vector3) -> void:
	pass


## A ray hit on an interactable wins. A look that lands beside one takes the
## closest in the cone, then the dwell window decides what actually changes.
func _intersect(origin: Vector3, direction: Vector3) -> Dictionary:
	var centre := super._intersect(origin, direction)
	var candidate := centre
	if _hit_interactable(centre) == null:
		var coned := _cone_candidate(origin, direction)
		if not coned.is_empty():
			candidate = coned
	return _dwell_filtered(candidate)


func _hit_interactable(hit: Dictionary):
	if hit.is_empty() or _manager == null:
		return null
	var interactable = _manager.get_interactable_for_collider(hit.get("collider"))
	return interactable if interactable != null and interactable.can_hover(self) else null


func _cone_candidate(origin: Vector3, direction: Vector3) -> Dictionary:
	if not _is_manager_valid():
		return {}
	var limit := cos(deg_to_rad(cone_angle_degrees))
	var inside: Array = []
	for interactable in _manager.get_interactables():
		# Panels are out: a cone hit lands on the panel's centre, and a click
		# there is a click on whatever control happens to be in the middle.
		if not is_instance_valid(interactable) or interactable.is_in_group("xr_ui_canvas"):
			continue
		if not interactable.can_hover(self):
			continue
		var to_point: Vector3 = interactable.drive_point() - origin
		var distance := to_point.length()
		if distance < 0.001 or distance > max_distance:
			continue
		var alignment := direction.dot(to_point / distance)
		if alignment >= limit:
			inside.append({"alignment": alignment, "interactable": interactable, "to_point": to_point})
	inside.sort_custom(func(a, b): return a["alignment"] > b["alignment"])
	for entry in inside:
		# Line of sight, closest first: something near the ray but behind a wall
		# must not be selectable through it.
		var sight := super._intersect(origin, (entry["to_point"] as Vector3).normalized())
		if _hit_interactable(sight) == entry["interactable"]:
			return sight
	return {}


func _dwell_filtered(candidate: Dictionary) -> Dictionary:
	if dwell_window_seconds <= 0.0:
		return candidate
	var interactable = _hit_interactable(candidate)
	var key: int = interactable.get_instance_id() if interactable != null else 0
	var now := XRClock.now_seconds()
	_dwell_samples.append({"t": now, "key": key})
	_dwell_hits[key] = candidate
	while _dwell_samples.size() > 1 and now - float(_dwell_samples[0]["t"]) > dwell_window_seconds:
		_dwell_samples.pop_front()
	_dwell_key = dwell_winner(_dwell_samples, _dwell_key)
	var winner: Dictionary = _dwell_hits.get(_dwell_key, {})
	# A stored hit can outlive its object by a frame or two of the window.
	if winner.has("collider") and not is_instance_valid(winner["collider"]):
		_dwell_hits.erase(_dwell_key)
		return {}
	return winner


## Which key holds the most time across the samples, each owning the gap back to
## the one before it. Ties stay with the current winner. Pure, so the consensus
## can be tested without a clock.
static func dwell_winner(samples: Array, current: int) -> int:
	if samples.size() == 1:
		return int(samples[0]["key"])
	var held := {}
	for i in range(1, samples.size()):
		var key: int = samples[i]["key"]
		held[key] = float(held.get(key, 0.0)) + float(samples[i]["t"]) - float(samples[i - 1]["t"])
	var best := current
	var best_time: float = held.get(current, 0.0)
	for key in held:
		if float(held[key]) > best_time:
			best = key
			best_time = held[key]
	return best


func _clear_dwell() -> void:
	_dwell_samples.clear()
	_dwell_hits.clear()
	_dwell_key = 0


## Gaze's own suppression. Not the arbiter's NEAR: that includes a hover, and a
## hand resting beside an object would pin gaze off. A poke button is not in
## this check, because it drives itself rather than through the poke interactor,
## and a fingertip pressing one cannot pinch anyway.
func _is_suppressed_by_linked_interactor() -> bool:
	if not suppress_when_direct_active or not is_inside_tree():
		return false
	for node in get_tree().get_nodes_in_group(XRDirectInteractor.GROUP):
		if (node as XRDirectInteractor).get_selected() != null:
			return true
	for node in get_tree().get_nodes_in_group(XRPokeInteractor.GROUP):
		for poke_hand in 2:
			if (node as XRPokeInteractor).is_pressing(poke_hand):
				return true
	return false


## Near wins the moment of commit too. A hovered near object is not active enough
## to yield gaze, but the same pinch reaches the direct interactor, and without
## this one pinch would take both objects.
func _hand_has_near_target(hand_id: int) -> bool:
	for node in get_tree().get_nodes_in_group(XRDirectInteractor.GROUP):
		var direct := node as XRDirectInteractor
		if direct == null or int(direct.hand) != hand_id:
			continue
		if direct.get_selected() != null:
			return true
		if direct.get_hovered() != null and bool(direct.get_direct_state().get("valid", false)):
			return true
	for node in get_tree().get_nodes_in_group(XRPokeInteractor.GROUP):
		var poke := node as XRPokeInteractor
		if poke != null and poke.is_poking(hand_id):
			return true
	return false


## Either hand commits. From here on `hand` is the committing hand, which is what
## makes the rest of the ray work unchanged: select end, is_select_down, the grip
## an ATTRACT grab flies to, and which hand a grab point poses.
func _on_adapter_select_started(event_hand: int) -> void:
	if _selected != null or _hovered == null or _hand_has_near_target(event_hand):
		return
	hand = event_hand as XRInputAdapter.Hand
	_try_select()


func _on_adapter_activate_started(event_hand: int) -> void:
	if _selected != null:
		super(event_hand)
		return
	if _activated != null or _hovered == null or _hand_has_near_target(event_hand):
		return
	hand = event_hand as XRInputAdapter.Hand
	_try_activate()


func _notify_select_granted(interactable) -> void:
	_capture_hold()
	super(interactable)


func _notify_select_released(interactable) -> void:
	super(interactable)
	_hold_pose = {}
	_hold_grip_origin = null
	_hold_offset = Vector3.ZERO
	_clear_dwell()


func _capture_hold() -> void:
	_hold_pose = {}
	_hold_grip_origin = null
	_hold_offset = Vector3.ZERO
	if not _ray_state.get("valid", false):
		return
	var origin: Vector3 = _ray_state["origin"]
	# Aim the held ray at the point actually hit, not along the eye ray: a cone
	# pick sits off-axis, and the first held frame would jump the object sideways
	# by the difference.
	var direction: Vector3 = (_ray_state["end"] as Vector3) - origin
	direction = direction.normalized() if direction.length_squared() > 0.000001 else _ray_state["direction"]
	_hold_pose = {
		"origin": origin,
		"direction": direction,
		"basis": XRHandGestureProvider.basis_from_forward(direction),
	}
	if _adapter != null:
		var grip: Dictionary = _adapter.get_grip_pose(hand)
		if not grip.is_empty():
			_hold_grip_origin = grip["origin"]
