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


func _ready() -> void:
	set_process(false)
	if not enabled:
		return
	var target := _resolve_endpoint()
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


## The endpoint comes from the RUN, not the scene: `?operator=` on web,
## `--operator=` elsewhere. A scene-fixed endpoint is possible but defeats
## the ship-inert property, so it is the exception.
func _resolve_endpoint() -> String:
	if not endpoint.is_empty():
		return endpoint
	if OS.has_feature("web"):
		var js := JavaScriptBridge.eval("new URLSearchParams(location.search).get('operator') || ''", true)
		return str(js) if js != null else ""
	for arg in OS.get_cmdline_args():
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
			_publish_pose(hand, pos, _vec(action["aim"]) if action.has("aim") else pos)
			_last_pos[clampi(hand, 0, 1)] = pos
		"move":
			var mhand := int(action.get("hand", 1))
			_move = {
				"hand": mhand,
				"from": _vec(action["from"]) if action.has("from") else _last_pos[clampi(mhand, 0, 1)],
				"to": _vec(action.get("to", [0, 1.4, 0])),
				"aim": _vec(action["aim"]) if action.has("aim") else Vector3.INF,
				"frames": maxi(2, int(action.get("frames", 30))),
				"step": 0,
			}
		"input":
			var tracker := _tracker(int(action.get("hand", 1)))
			if tracker:
				tracker.set_input(StringName(str(action.get("action", "select"))), action.get("value", true))
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
		"frame": Engine.get_process_frames(),
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
	if _ws:
		_ws.close()
