@icon("res://addons/godot_webxr_kit/icons/webxr_bootstrap.svg")
class_name XRRemoteActuator
extends Node

## Lets an external operator drive this scene's XR input over a WebSocket -
## the same tracker-level injection a headset runtime performs, so the whole
## real chain runs: input adapter, interactors, interaction manager,
## interactables. Meta's operator does this through an OpenXR layer and can
## only reach native apps; this block rides the app itself, so it works
## everywhere the app does - including a browser, and including headless.
##
## SECURITY: this is a development tool - an input channel into your app.
## It activates ONLY when BOTH are true: [member enabled] is on, and the
## run names an operator endpoint (URL param `?operator=host:port` on web,
## `--operator=host:port` on the command line elsewhere). It connects OUT
## to the operator; nothing ever listens inside the app. Ship scenes with
## [member enabled] off.
##
## Protocol (JSON text frames):
##   app -> {"type":"hello","scene":...}   on connect
##   ctl -> {"type":"actions","actions":[...]}   pose/move/input/wait,
##          the same action dictionaries the headless simulate_input takes
##   app -> {"type":"event",...}           every interaction signal, live
##   app -> {"type":"done","applied":N}    when the queue empties
##
## COORDINATES: positions are ORIGIN-LOCAL (play space), the space a runtime
## publishes tracker poses in - consumers multiply by the XROrigin3D
## transform to reach world. They coincide only while the origin sits at
## identity, which is why a drive authored against world coordinates works
## in one scene and lands offset in another that moves its origin.
##
## NOTE for browser use: an https page may only open wss:// sockets, so the
## operator endpoint must speak TLS on a certificate this headset already
## accepted - the practical route is the serve relay (planned), not a raw
## host:port. Native (Link) and headless runs connect over plain ws://
## today, which is what the headless verification exercises.

## Master switch. Off = this node does nothing at all.
@export var enabled := false
## Optional fixed endpoint (host:port). Normally left empty so the run's
## URL/cmdline argument decides - which is what keeps shipped builds inert.
@export var endpoint := ""

const _HAND_TRACKERS: Array[StringName] = [&"left_hand", &"right_hand"]

var _ws: WebSocketPeer = null
var _queue: Array = []
var _applied := 0
var _wait_frames := 0
var _move := {}
var _last_pos: Array[Vector3] = [Vector3(0, 1.4, 0), Vector3(0, 1.4, 0)]
var _owned_trackers: Array[XRControllerTracker] = []
var _signals_wired := false
var _done_sent := false
## Frames since the drive began, so events align with the action list.
var _drive_frame := 0
## Last driven aim per hand, re-published every frame (see _tick_queue).
var _held_aim := {}

## Synthetic hand state, built only when a drive asks for hands.
const _POSE_MATH_PATH := "res://addons/godot_xr_hands/runtime/xr_hand_pose_math.gd"
const _JOINT_FLAGS: int = XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID \
		| XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED \
		| XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID \
		| XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_TRACKED
var _pose_math: Object = null
var _bind := {}
var _hand_trackers := {}
var _hand_state := {}
## Microgesture motions in flight, per hand.
var _micro := {}


func _ready() -> void:
	set_process(false)
	# Two independent ways to activate, and NEITHER fires in a shipped build:
	#  - a run argument names an operator (?operator= / --operator=). Its
	#    presence is itself the opt-in - a user never adds it - so it
	#    activates on its own, which is what lets the shared rig carry this
	#    node with enabled off and still be drivable when asked.
	#  - the author set a fixed `endpoint` AND turned `enabled` on.
	var target := _run_arg_endpoint()
	if target.is_empty() and enabled and not endpoint.is_empty():
		target = endpoint
	if target.is_empty():
		return
	_ws = WebSocketPeer.new()
	var url := target if target.begins_with("ws") else "ws://%s" % target
	var err := _ws.connect_to_url(url)
	if err != OK:
		push_warning("XRRemoteActuator: cannot connect to %s (error %d)" % [url, err])
		_ws = null
		return
	set_process(true)


## The endpoint from the RUN itself: `?operator=` on web, `--operator=`
## elsewhere. Empty unless a run argument names one - which is why a shipped
## build never connects.
func _run_arg_endpoint() -> String:
	if OS.has_feature("web"):
		# ?operator=<port> means "reach the operator via this origin's relay":
		# an https page can only open a wss socket, and only to a host whose
		# cert it already trusts - which is the page's own origin. The serve
		# relays /operator?p=<port> to the operator's local ws server. A full
		# ws(s):// value is honored verbatim for non-relay setups.
		var raw := str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('operator') || ''", true))
		if raw.is_empty():
			return ""
		if raw.begins_with("ws://") or raw.begins_with("wss://"):
			return raw
		var host := str(JavaScriptBridge.eval("location.host", true))
		var op_port := raw if raw.is_valid_int() else "8470"
		return "wss://%s/operator?p=%s" % [host, op_port]
	# Both the engine args and the user args (after `--`): a windowed Play
	# launch passes it as a user arg so it never collides with an engine
	# option, while a bare native run may pass it directly.
	for arg in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if str(arg).begins_with("--operator="):
			return str(arg).trim_prefix("--operator=")
	return ""


func _process(_delta: float) -> void:
	if _ws == null:
		set_process(false)
		return
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _signals_wired:
				_signals_wired = true
				_wire_signals()
				var scene := get_tree().current_scene
				_send({"type": "hello", "scene": String(scene.name) if scene else String(get_tree().root.get_child(0).name)})
			while _ws.get_available_packet_count() > 0:
				var parsed = JSON.parse_string(_ws.get_packet().get_string_from_utf8())
				if typeof(parsed) == TYPE_DICTIONARY and str(parsed.get("type", "")) == "actions":
					_queue.append_array(parsed.get("actions", []))
			_tick_queue()
		WebSocketPeer.STATE_CLOSED:
			_ws = null
			set_process(false)


func _tick_queue() -> void:
	_drive_frame += 1
	# A runtime publishes poses EVERY frame, and the interaction chain is
	# built for that: a pose written once and left alone goes stale, and the
	# interactor drops its hover a frame or two later even though nothing
	# moved. Measured before this republish existed - hover entered on drive
	# frame 64 and exited on 66 with the hand held still. So hold what was
	# last driven and re-publish it, exactly like a device would.
	for hand in _held_aim:
		if _move.is_empty() or int(_move.get("hand", -1)) != hand:
			_publish_pose(hand, _last_pos[clampi(hand, 0, 1)], _held_aim[hand])
	for hand in _hand_state:
		_publish_hand(hand)
	if not _move.is_empty():
		_step_move()
		return
	if _wait_frames > 0:
		_wait_frames -= 1
		return
	if _queue.is_empty():
		# Done fires HERE, not on the last apply: a queue ending in a wait
		# or a move is only finished once that tail action has played out.
		if _applied > 0 and not _done_sent:
			_done_sent = true
			_send({"type": "done", "applied": _applied})
		return
	_done_sent = false
	var action: Dictionary = _queue.pop_front()
	_apply(action)
	_applied += 1


func _apply(action: Dictionary) -> void:
	match str(action.get("type", "")):
		"wait":
			_wait_frames = int(action.get("frames", 10))
		"pose":
			var hand := int(action.get("hand", 1))
			var pos := _vec(action.get("position", [0, 1.4, 0]))
			var aim_at := _vec(action["aim"]) if action.has("aim") else pos
			if bool(action.get("tip", false)):
				pos = _anchor_for_tip(hand, pos)
			_publish_pose(hand, pos, aim_at)
			_last_pos[clampi(hand, 0, 1)] = pos
			_held_aim[clampi(hand, 0, 1)] = aim_at
		"move":
			var mhand := int(action.get("hand", 1))
			_move = {
				"hand": mhand,
				"from": _vec(action["from"]) if action.has("from") else _last_pos[clampi(mhand, 0, 1)],
				"to": _anchor_for_tip(mhand, _vec(action.get("to", [0, 1.4, 0]))) if bool(action.get("tip", false)) else _vec(action.get("to", [0, 1.4, 0])),
				"aim": _vec(action["aim"]) if action.has("aim") else Vector3.INF,
				"frames": maxi(2, int(action.get("frames", 30))),
				"step": 0,
			}
		"input":
			var tracker := _tracker(int(action.get("hand", 1)))
			if tracker:
				tracker.set_input(StringName(str(action.get("action", "select"))), action.get("value", true))
		"hand":
			# Publish articulated hand JOINTS, not just a controller pose:
			# what a hand-tracking runtime serves, so hand visuals render and
			# everything reading joints (pinch detection, gesture
			# recognizers, poke tips) sees a real hand.
			var hhand := int(action.get("hand", 1))
			if not _ensure_hands():
				_send({"type": "event", "error": "hand poses need the godot_xr_hands addon and its models"})
				return
			var pose_name := str(action.get("pose", "custom"))
			var joints: Array = []
			if action.has("gesture"):
				# A gesture from the library - a shipped preset or one
				# RECORDED in the Gesture Studio - so a drive can reproduce
				# the exact hand a person authored, and the recognizers see
				# what they were trained on.
				pose_name = str(action["gesture"])
				joints = _gesture_joints(hhand, pose_name)
				if joints.is_empty():
					_send({"type": "event", "error": "no gesture named '%s' - see list_gestures" % pose_name})
					return
			else:
				var curls: Dictionary = action.get("curls", {})
				if action.has("pose"):
					curls = _curls_for(pose_name)
				joints = _pose_math.fk_pose(_bind[hhand]["rel"], _bind[hhand]["curl_axes"], curls)
			_hand_state[hhand] = {"joints": joints, "pose": pose_name}
			_publish_hand(hhand)
		"microgesture":
			# A motion, not a pose: the thumb travels along the index finger
			# and the recognizer reads the path. Same helper the desktop
			# simulator plays from its arrow keys.
			var mghand := int(action.get("hand", 1))
			if not _ensure_hands():
				_send({"type": "event", "error": "microgestures need the godot_xr_hands addon"})
				return
			_hand_state[mghand] = {
				"joints": _pose_math.fk_pose(_bind[mghand]["rel"], _bind[mghand]["curl_axes"],
						_pose_math.MICROGESTURE_CURLS),
				"pose": "microgesture",
			}
			_micro[mghand] = {
				"kind": str(action.get("gesture", "tap")).replace("thumb_", ""),
				"step": 0,
				"frames": maxi(6, int(action.get("frames", 24))),
			}
			# The motion owns the queue while it plays, like a move does.
			_wait_frames = int(_micro[mghand]["frames"])
		_:
			_send({"type": "event", "error": "unknown action type %s" % action.get("type", "")})


func _step_move() -> void:
	var t: float = float(_move.step) / float(_move.frames)
	var e := t * t * (3.0 - 2.0 * t)
	var pos: Vector3 = (_move.from as Vector3).lerp(_move.to, e)
	var aim: Vector3 = _move.aim
	_publish_pose(int(_move.hand), pos, aim if aim.is_finite() else pos)
	_move.step += 1
	if _move.step > int(_move.frames):
		_last_pos[clampi(int(_move.hand), 0, 1)] = _move.to
		_held_aim[clampi(int(_move.hand), 0, 1)] = aim if aim.is_finite() else _move.to
		_move = {}


## Tracker-level pose publication, identical to the headless simulator's:
## the rig binds specific pose names, so all three are published.
func _publish_pose(hand: int, pos: Vector3, aim_target: Vector3) -> void:
	var tracker := _tracker(hand)
	if tracker == null:
		return
	var basis := Basis()
	if not aim_target.is_equal_approx(pos):
		basis = Basis.looking_at(aim_target - pos, Vector3.UP)
	var xform := Transform3D(basis, pos)
	for pose_name in [&"default", &"aim", &"grip"]:
		tracker.set_pose(pose_name, xform, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


## Loads the pose machinery and the asset bind pose once, on first use, so a
## drive that never asks for hands pays nothing.
func _ensure_hands() -> bool:
	if not _bind.is_empty():
		return true
	if not ResourceLoader.exists(_POSE_MATH_PATH):
		return false
	_pose_math = load(_POSE_MATH_PATH)
	_bind = _pose_math.load_bind_skeletons()
	if _bind.is_empty():
		return false
	_wake_platform_adapter()
	return true


## Off its own platform an adapter parks its _process, so nothing runs the
## synthetic-pinch detector - joints would be published and no select would
## ever fire. Driving hands means waking the adapter that owns this platform
## and pointing the interactors at it, exactly as the desktop simulator does.
func _wake_platform_adapter() -> void:
	var rig := get_parent()
	if rig == null:
		return
	var adapter := rig.get_node_or_null("WebXRInputAdapter" if OS.has_feature("web") else "OpenXRInputAdapter")
	if adapter == null:
		return
	adapter.set_process(true)
	for interactor in _adapter_interactors(rig):
		if interactor.has_method(&"set_input_adapter"):
			interactor.set_input_adapter(adapter)


func _adapter_interactors(root: Node) -> Array:
	var out: Array = []
	for child in root.get_children():
		if child.has_method(&"set_input_adapter"):
			var path: Variant = child.get("input_adapter_path")
			if path is NodePath and not (path as NodePath).is_empty():
				out.append(child)
		out.append_array(_adapter_interactors(child))
	return out


## Joints for a gesture from the library, by name: the shipped presets and
## anything recorded in the Gesture Studio. Recorded gestures carry real
## joint snapshots, so this reproduces the authored hand rather than an
## approximation of it.
func _gesture_joints(hand: int, gesture_name: String) -> Array:
	# Matched loosely on purpose: a preset's display name and its file name
	# can differ ("Trigger Grip" lives in trigger_grip.tres) and some presets
	# carry no display name at all, so a caller who read either listing gets
	# the gesture they asked for.
	var wanted := _gesture_key(gesture_name)
	for entry in _pose_math.list_poses():
		var res: Object = entry.get("resource")
		if res == null:
			continue
		var names := [str(entry.get("name", ""))]
		if res.resource_path:
			names.append(str(res.resource_path).get_file().get_basename())
		for candidate in names:
			if _gesture_key(candidate) == wanted:
				return _pose_math.pose_joints(_bind[hand]["rel"], _bind[hand]["curl_axes"], res, hand)
	return []


func _gesture_key(text: String) -> String:
	return text.to_lower().replace(" ", "_").replace("-", "_")


## Named poses as finger curls. The asset's bind pose IS the open hand, so
## "open" is an empty curl set rather than a tuned one.
func _curls_for(pose: String) -> Dictionary:
	match pose:
		"fist":
			return {"thumb": 0.85, "index": 0.95, "middle": 0.95, "ring": 0.95, "pinky": 0.95}
		"point":
			return {"thumb": 0.6, "index": 0.0, "middle": 0.95, "ring": 0.95, "pinky": 0.95}
		"pinch":
			# Curls shape the hand; the tips are brought together by the
			# morph in _publish_hand. Measured: curling alone bottoms out at
			# ~39mm between the tips - the thumb and index curl in different
			# planes and never converge - while the adapter's synthetic
			# pinch needs 35mm. So a pinch that relied on curls would look
			# right and never fire.
			return {"thumb": 0.62, "index": 0.72, "middle": 0.3, "ring": 0.3, "pinky": 0.3}
		"grip":
			return {"thumb": 0.7, "index": 0.8, "middle": 0.8, "ring": 0.8, "pinky": 0.8}
		_:
			return {}



## Poking is aimed with the FINGERTIP, but a drive positions the hand
## anchor, and the tip sits ~15cm further along - so "move to the button"
## puts the wrist there and the finger through it. With `tip: true` a pose
## or move names where the INDEX TIP should land and this solves back to
## the anchor that puts it there. Needs a hand pose published first; without
## one there are no joints to measure against and the position is used as-is.
func _anchor_for_tip(hand: int, tip_target: Vector3) -> Vector3:
	if not _hand_state.has(hand):
		return tip_target
	var joints: Array = _hand_state[hand]["joints"]
	if joints.size() <= XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP:
		return tip_target
	var basis: Basis = _hand_basis(hand) * (_bind[hand]["align"] as Basis)
	var local_tip: Vector3 = (joints[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP] as Transform3D).origin
	return tip_target - basis * local_tip

## Registers a hand tracker the way a hand-tracking runtime would.
func _hand_tracker(hand: int) -> XRHandTracker:
	if _hand_trackers.has(hand):
		return _hand_trackers[hand]
	var path := XRHandIdentity.hand_tracker_path(hand)
	var existing := XRServer.get_tracker(path)
	if existing is XRHandTracker:
		_hand_trackers[hand] = existing
		return existing
	var tracker := XRHandTracker.new()
	tracker.name = path
	tracker.hand = XRHandIdentity.to_tracker_hand(hand)
	# UNOBSTRUCTED = real hand tracking, which keeps the adapter's synthetic
	# pinch select armed (it ignores controller-emulated joints).
	tracker.hand_tracking_source = XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED
	XRServer.add_tracker(tracker)
	_hand_trackers[hand] = tracker
	return tracker


## Writes the current joint set into the tracker, anchored at the hand's
## driven position. Called every frame while a hand pose is held: the hand
## must follow `move` like a real one, and a bit-identical joint set trips
## the visualizer's frozen-hand watchdog.
func _publish_hand(hand: int) -> void:
	if not _hand_state.has(hand):
		return
	var joints: Array = _hand_state[hand]["joints"]
	if joints.is_empty():
		return
	var tracker := _hand_tracker(hand)
	var pos: Vector3 = _last_pos[clampi(hand, 0, 1)]
	var align: Basis = _bind[hand]["align"]
	# Sub-mm sway mimics tracking jitter; without it the visualizer's
	# frozen-hand watchdog (built for a real stale-pose bug) hides the hand.
	var t := float(Time.get_ticks_msec()) * 0.001
	var sway := Vector3(sin(t * 1.3 + hand), sin(t * 1.7), sin(t * 2.1)) * 0.0006
	var anchor := Transform3D(_hand_basis(hand) * align, pos + sway)
	# Pinch morph (positions only): the tips are pulled to meet, which is
	# what makes the ADAPTER's own synthetic-pinch detector fire - the same
	# path a real hand takes on-device, rather than a faked select.
	var morph := {}
	if _micro.has(hand):
		var m: Dictionary = _micro[hand]
		var micro_t: float = float(m["step"]) / float(m["frames"])
		morph[XRHandTracker.HAND_JOINT_THUMB_TIP] = _pose_math.microgesture_offset(
				_bind[hand]["rel"], str(m["kind"]), micro_t)
		m["step"] = int(m["step"]) + 1
		if int(m["step"]) > int(m["frames"]):
			_micro.erase(hand)
	if str(_hand_state[hand].get("pose", "")) == "pinch":
		var thumb: Vector3 = (joints[XRHandTracker.HAND_JOINT_THUMB_TIP] as Transform3D).origin
		var index: Vector3 = (joints[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP] as Transform3D).origin
		var mid := (thumb + index) * 0.5
		morph[XRHandTracker.HAND_JOINT_THUMB_TIP] = mid + (thumb - mid).normalized() * 0.008 - thumb
		morph[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP] = mid + (index - mid).normalized() * 0.008 - index
	for joint in joints.size():
		var world: Transform3D = anchor * (joints[joint] as Transform3D)
		if morph.has(joint):
			world.origin += anchor.basis * (morph[joint] as Vector3)
		tracker.set_hand_joint_transform(joint,
				Transform3D(world.basis * _pose_math.GODOT_HAND_REBASE, world.origin))
		tracker.set_hand_joint_flags(joint, _JOINT_FLAGS)
	tracker.has_tracking_data = true


## The hand's world orientation: the same aim the controller pose uses, so a
## driven hand and its ray point the same way.
func _hand_basis(hand: int) -> Basis:
	var tracker := _tracker(hand)
	if tracker:
		var pose := tracker.get_pose(&"default")
		if pose:
			return pose.transform.basis
	return Basis()


func _tracker(hand: int) -> XRControllerTracker:
	if not XRHandIdentity.is_valid(hand):
		return null
	var name: StringName = _HAND_TRACKERS[hand]
	var existing := XRServer.get_tracker(name)
	if existing != null:
		return existing as XRControllerTracker
	# No runtime is publishing trackers (headless, or flat page): supply
	# them at the same level a runtime would, so downstream is unchanged.
	var tracker := XRControllerTracker.new()
	tracker.name = name
	tracker.hand = XRHandIdentity.to_tracker_hand(hand)
	tracker.profile = "/interaction_profiles/oculus/touch_controller"
	XRServer.add_tracker(tracker)
	_owned_trackers.append(tracker)
	return tracker


## Every interaction signal in the scene streams to the operator with the
## node it fired on - the consequences an operator asserts on.
func _wire_signals() -> void:
	var of_interest := {
		"grabbed": true, "released": true, "thrown": true,
		# select_* is the raw interactor-level pair: some interactables (the
		# climb handhold) act on it directly and never emit a grab.
		"select_entered": true, "select_exited": true,
		"hover_entered": true, "hover_exited": true,
		"activated": true, "deactivated": true,
		"pressed": true, "value_changed": true,
		"object_socketed": true, "object_released": true,
		"teleported": true, "climb_started": true, "climb_ended": true,
		"gesture_started": true, "gesture_ended": true,
		"session_started": true, "session_ended": true,
	}
	var root := get_tree().current_scene if get_tree().current_scene else get_tree().root
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.push_back(child)
		for sig in node.get_signal_list():
			var sig_name := String(sig["name"])
			if of_interest.has(sig_name):
				node.connect(sig_name, _on_event.bind(sig_name, String(root.get_path_to(node))))


func _on_event(a = null, b = null, c = null, d = null) -> void:
	var args := [a, b, c, d]
	var bound := []
	for v in args:
		if v != null:
			bound.append(v)
	if bound.size() < 2:
		return
	_send({
		"type": "event",
		"signal": str(bound[bound.size() - 2]),
		"node": str(bound[bound.size() - 1]),
		# Engine frames count from process start; the drive starts whenever
		# the socket connected. Only the queue-relative number lets a caller
		# line an event up against the action that caused it.
		"frame": _drive_frame,
		"engine_frame": Engine.get_process_frames(),
	})


func _send(payload: Dictionary) -> void:
	if _ws and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(payload))


func _vec(value) -> Vector3:
	if typeof(value) == TYPE_ARRAY and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ZERO


func _exit_tree() -> void:
	for tracker in _owned_trackers:
		XRServer.remove_tracker(tracker)
	_owned_trackers.clear()
	for hand in _hand_trackers:
		XRServer.remove_tracker(_hand_trackers[hand])
	_hand_trackers.clear()
	if _ws:
		_ws.close()
