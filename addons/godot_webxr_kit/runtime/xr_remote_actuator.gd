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
##   app -> {"type":"event",...}           every interaction signal, live,
##          plus anything a `report` action reads back out of the scene
##   app -> {"type":"done","applied":N}    when the queue empties
##
## COORDINATES: drives are authored in WORLD space - the space scene_dump
## reports and a person reads off a scene - and converted here. Tracker
## poses are published in play space (origin-local), which is what a
## runtime provides and what consumers like the poke interactor assume when
## they resolve a point as origin.global_transform * joint. The two coincide
## only while the origin sits at identity, so doing this conversion is what
## makes the same drive work in a scene whose origin has moved.
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
const _GAZE_TRACKER := &"gaze"

var _ws: WebSocketPeer = null
var _queue: Array = []
var _applied := 0
var _wait_frames := 0
## Seconds still to hold, for waits authored in wall time.
var _wait_seconds := 0.0
## Last driven viewpoint, re-applied every frame. The flat camera controller
## writes its own transform each frame, so a viewpoint set once is overwritten
## before it can be seen - the same staleness that poses and inputs both hit.
var _held_view := {}
var _move := {}
var _last_pos: Array[Vector3] = [Vector3(0, 1.4, 0), Vector3(0, 1.4, 0)]
var _owned_trackers: Array[XRControllerTracker] = []
var _signals_wired := false
var _done_sent := false
## Frames since the drive began, so events align with the action list.
var _drive_frame := 0
## Last driven aim per hand, re-published every frame (see _tick_queue).
var _held_aim := {}
## Last driven input per hand, {hand: {action: value}}, re-published every
## frame for the same reason poses are: a runtime reports button and stick
## state CONTINUOUSLY, and anything else driving the same tracker overwrites
## a value that was only set once. Measured: the desktop simulator writes
## thumbstick every frame from keyboard state - zero, headless - so a stick
## set once by a drive was erased before locomotion sampled it, and teleport
## passed or failed by a race (about two runs in three).
var _held_input := {}
## Last driven gaze, {at, tracked}, re-published every frame for the same reason.
var _held_gaze := {}

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
## Pose fades in flight, per hand: {from, to, elapsed, seconds, easing}.
var _fade := {}
## Pinned hand points, per hand: {anchor, target}. The named point stays on
## `target` while the hand changes shape around it: a pinch closes onto the thing
## it was placed on instead of dragging the grasp point away.
var _pin := {}
## Hand orientation set by directions rather than by an aim point.
var _held_basis := {}
var _grasp_points := {}
## Process frames left to run in a `step`, with the tree otherwise paused.
var _step_left := 0
## Named property captures for `diff`, oldest first.
var _snapshots := {}
const _MAX_SNAPSHOTS := 20
const _CURL_POSES := ["open", "fist", "point", "pinch", "grip"]
var _origin: XROrigin3D = null


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
		# A URL parameter is not an opt-in by the person running the app - it is
		# an opt-in by whoever sent them the link. On the command line the
		# argument really is the operator's own choice, but on the web anyone
		# can append one, so a RELEASE build ignores it entirely: a shipped
		# product must not be drivable, or have its interaction stream shipped
		# somewhere, because a user clicked a crafted link.
		if not enabled and not OS.is_debug_build():
			push_warning("XRRemoteActuator: ignoring ?operator= in a release build. Set enabled to allow it.")
			return ""
		if raw.begins_with("ws://") or raw.begins_with("wss://"):
			# An absolute endpoint names an arbitrary host, which is the part
			# worth refusing: it turns the parameter into "stream this session
			# to me". Only an author who set `enabled` can point the app off
			# its own origin; everyone else gets the same-origin relay below.
			if not enabled:
				push_warning("XRRemoteActuator: refusing an absolute ?operator= endpoint; using the page's own origin.")
			else:
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
	_step_fades(get_process_delta_time())
	_resolve_pins()
	for hand in _held_aim:
		if _move.is_empty() or int(_move.get("hand", -1)) != hand:
			_publish_pose(hand, _last_pos[clampi(hand, 0, 1)], _held_aim[hand])
	if not _held_view.is_empty():
		_apply_view(_held_view["eye"], _held_view["target"])
	for hand in _held_input:
		var tracker := _tracker(hand)
		if tracker != null:
			for action_name in _held_input[hand]:
				tracker.set_input(action_name, _held_input[hand][action_name])
	for hand in _hand_state:
		_publish_hand(hand)
	if not _held_gaze.is_empty():
		_publish_gaze()
	if _step_left > 0:
		_step_left -= 1
		if _step_left == 0:
			get_tree().paused = true
			_send_reading("stepped")
		return
	if not _move.is_empty():
		_step_move()
		return
	# Seconds first: anything consumed in _physics_process is sampled on
	# a FIXED clock while this queue advances on IDLE frames, so a hold
	# measured in frames can slip between two physics ticks and never be
	# seen. Measured as a thumbstick teleport that passed or failed run
	# to run with nothing changed in between.
	if _wait_seconds > 0.0:
		_wait_seconds -= get_process_delta_time()
		return
	if _wait_frames > 0:
		_wait_frames -= 1
		return
	if _queue.is_empty():
		# Done fires HERE, not on the last apply: a queue ending in a wait
		# or a move is only finished once that tail action has played out.
		if _applied > 0 and not _done_sent:
			_done_sent = true
			get_tree().paused = false
			_send({"type": "done", "applied": _applied})
		return
	_done_sent = false
	var action: Dictionary = _queue.pop_front()
	_apply(action)
	_applied += 1


func _apply(action: Dictionary) -> void:
	match str(action.get("type", "")):
		"wait":
			if action.has("seconds"):
				_wait_seconds = maxf(0.0, float(action["seconds"]))
			else:
				_wait_frames = int(action.get("frames", 10))
		"pose":
			var hand := int(action.get("hand", 1))
			var pos := _vec(action.get("position", [0, 1.4, 0]))
			var aim_at := _vec(action["aim"]) if action.has("aim") else pos
			if action.has("orient"):
				_held_basis[hand] = _orient_basis(hand, action["orient"], pos)
			elif action.has("aim"):
				_held_basis.erase(hand)
			if action.has("anchor"):
				var pin_anchor := str(action["anchor"])
				if not _can_anchor(hand, pin_anchor):
					return
				# Orientation first: where the wrist goes depends on it.
				_publish_pose(hand, pos, aim_at)
				_pin[hand] = {"anchor": pin_anchor, "target": pos}
				pos = _wrist_for(hand, pin_anchor, pos)
				if not action.has("aim"):
					aim_at = pos
			else:
				_pin.erase(hand)
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
				"easing": str(action.get("easing", "smooth")),
			}
			_pin.erase(mhand)
			if action.has("seconds"):
				_move["seconds"] = maxf(0.05, float(action["seconds"]))
				_move["elapsed"] = 0.0
			if action.has("aim"):
				_held_basis.erase(mhand)
			if action.has("orient"):
				_move["basis_from"] = _hand_world_basis(mhand)
				_move["basis_to"] = _orient_basis(mhand, action["orient"], _vec(action.get("to", [0, 1.4, 0])))
			if action.has("anchor"):
				var move_anchor := str(action["anchor"])
				if not _can_anchor(mhand, move_anchor):
					_move = {}
					return
				_move["anchor"] = move_anchor
				_move["anchor_from"] = _hand_world(mhand) * _anchor_local(mhand, move_anchor)
				_move["anchor_to"] = _vec(action.get("to", [0, 1.4, 0]))
		"view":
			# Move the VIEWPOINT. A drive moves hands; without this the camera
			# stays wherever the rig was left, so a station being worked on can be
			# entirely off-screen - fine for asserting on signals, useless for
			# showing someone what happened. Positions whichever camera is actually
			# rendering, so it works on the flat view and in a session alike.
			_stand_down_simulator()
			# The flat camera controller writes its own transform every frame, and
			# node order decides who wins - so take it out of the loop rather than
			# racing it. Same reasoning as the simulator: whoever is really driving
			# owns the viewpoint.
			for node in get_tree().root.find_children("*", "", true, false):
				if node.get_script() != null 						and str(node.get_script().get_global_name()) == "FlatscreenCamera" 						and node.is_processing():
					node.set_process(false)
			var camera := get_viewport().get_camera_3d() if get_viewport() != null else null
			if camera == null:
				_send({"type": "event", "error": "no active camera to place"})
				return
			var eye := _vec(action.get("position", [0, 1.6, 0]))
			var target := _vec(action["look_at"]) if action.has("look_at") else eye + Vector3(0, 0, -1)
			_held_view = {"eye": eye, "target": target}
			_apply_view(eye, target)
			_send({"type": "event", "view": String(camera.name),
					"at": [camera.global_position.x, camera.global_position.y, camera.global_position.z]})
		"screenshot":
			# Proof you can LOOK at. Signals say an interaction fired; a frame says
			# what it looked like when it did - which is the difference between a
			# green test and being able to show someone the hand doing the thing.
			# Needs a rendering run (drive_session visible:true); headless has no
			# viewport texture and says so rather than writing a black file.
			var shot_path := str(action.get("path", ""))
			if shot_path.is_empty():
				_send({"type": "event", "error": "screenshot needs a path"})
				return
			var viewport := get_viewport()
			var texture := viewport.get_texture() if viewport != null else null
			var image := texture.get_image() if texture != null else null
			if image == null or image.is_empty():
				_send({"type": "event", "error": "no viewport image - run with visible:true"})
				return
			DirAccess.make_dir_recursive_absolute(shot_path.get_base_dir())
			var err := image.save_png(shot_path)
			_send({"type": "event", "shot": shot_path, "ok": err == OK,
					"label": str(action.get("label", ""))})
		"report":
			# Read a value back OUT of the scene, onto the same channel as the
			# signals. Signals cover most of what a drive needs to assert, but
			# not everything an interaction DOES is announced: two-hand scaling
			# only changes a transform, so a case watching signals alone could
			# not tell a two-hand scale from an ordinary one-hand grab - both
			# report exactly `grabbed`. Reporting the property makes that state
			# assertable instead of assumed.
			var report_path := str(action.get("path", ""))
			var subject := _find_node(report_path)
			if subject == null:
				_send({"type": "event", "error": "report: no node at %s" % report_path})
				return
			# get_indexed, so a case can ask for `scale:x` and get back a NUMBER
			# rather than a vector string it would have to parse apart again.
			var prop := str(action.get("property", "scale"))
			var read: Variant = subject.get_indexed(NodePath(prop))
			if read == null:
				_send({"type": "event", "error": "report: %s has no %s" % [report_path, prop]})
				return
			_send({
				"type": "event",
				"signal": "report %s%s=%s" % [
					prop,
					("[%s]" % str(action["label"])) if action.has("label") else "",
					str(read),
				],
				"node": report_path,
				"frame": _drive_frame,
				"engine_frame": Engine.get_process_frames(),
			})
		"input":
			var tracker := _tracker(int(action.get("hand", 1)))
			if tracker:
				var value: Variant = action.get("value", true)
				# JSON has no vector, so a two-number ARRAY becomes one: the
				# locomotion blocks read get_vector2("thumbstick"), so without
				# this a drive simply could not express a stick - teleport and
				# snap turn were undrivable rather than broken.
				if value is Array and (value as Array).size() == 2:
					value = Vector2(float(value[0]), float(value[1]))
				_stand_down_simulator()
				var action_name := StringName(str(action.get("action", "select")))
				tracker.set_input(action_name, value)
				var hand_index := int(action.get("hand", 1))
				if not _held_input.has(hand_index):
					_held_input[hand_index] = {}
				_held_input[hand_index][action_name] = value
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
			elif action.has("fingers") and not action.has("pose") and not action.has("curls") and _hand_state.has(hhand):
				# Fingers alone reshape the hand already being held, including
				# one still fading toward its pose.
				joints = _fade[hhand]["to"] if _fade.has(hhand) else _hand_state[hhand]["joints"]
				pose_name = str(_hand_state[hhand]["pose"])
			else:
				var curls: Dictionary = action.get("curls", {})
				if action.has("pose"):
					curls = _curls_for(pose_name)
				joints = _pose_math.fk_pose(_bind[hhand]["rel"], _bind[hhand]["curl_axes"], curls)
				if pose_name == "pinch":
					# Close the pinch by ROTATION (thumb solved to the index
					# tip), not by dragging tip positions: a positional morph
					# is a bone-length change, and the conditioning chain
					# low-passes those over seconds - measured as a pinch that
					# selected ~5 s late, i.e. never within a normal hold.
					# Same root cause and same cure as the microgesture.
					joints = _pose_math.pinch_pose(joints)
			if action.has("fingers"):
				joints = _with_fingers(hhand, joints, action["fingers"])
				if joints.is_empty():
					return
			_show_pose(hhand, joints, pose_name, action)
		"hand_state":
			# What the hand IS, as a number: where its points are and which way
			# it faces, read from the joints being published. A pose that looks
			# right in a capture says nothing a case can assert on.
			var state_hand := int(action.get("hand", 1))
			if not _hand_state.has(state_hand):
				_send({"type": "event", "error": "hand_state: no hand pose has been driven on hand %d" % state_hand})
				return
			_send_reading("hand_state%s %s" % [
				("[%s]" % str(action["label"])) if action.has("label") else "",
				JSON.stringify(_read_hand(state_hand))], str(state_hand))
		"pause":
			# Stops the scene, not this node: the drive has to keep running to
			# inspect a paused world and to step it.
			process_mode = Node.PROCESS_MODE_ALWAYS
			get_tree().paused = true
			_send_reading("paused")
		"step":
			process_mode = Node.PROCESS_MODE_ALWAYS
			_step_left = maxi(1, int(action.get("frames", 1)))
			get_tree().paused = false
		"resume":
			get_tree().paused = false
			_send_reading("resumed")
		"snapshot":
			_take_snapshot(action)
		"diff":
			_send_diff(str(action.get("from", "")), str(action.get("to", "")))
		"gaze":
			# The eyes, as a runtime would serve them: a tracker with a pose, no
			# buttons. `at` is where to look; tracked:false keeps the source but
			# loses its pose; connected:false removes the source.
			_apply_gaze(action)
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
			# The recognizer LEARNS its contact envelope from sustained
			# samples while the hand holds gesture posture, and guards with
			# cooldowns - so a motion that arrives cold is measured against
			# nothing and rejected. Hold the posture first, then travel.
			var warmup := maxi(0, int(action.get("warmup_frames", 100)))
			var frames := maxi(6, int(action.get("frames", 24)))
			_micro[mghand] = {
				"kind": str(action.get("gesture", "tap")).replace("thumb_", ""),
				"step": -warmup,
				"frames": frames,
				"elapsed": 0.0,
				# SECONDS, not frames, is what the recognizer reasons in: it
				# re-anchors an attempt that spends longer than half its window
				# below tap travel, reading it as a RESTING thumb rather than a
				# swipe. Measured: the same motion recognized on a 90 fps host
				# stretched to ~1 s on a 39 fps headless one and was correctly
				# discarded as a rest. A real thumb swipe is ~0.3 s, so drive it
				# in wall time and let the frame rate fall where it may.
				"seconds": maxf(0.05, float(action.get("seconds", 0.3))),
			}
			# The motion owns the queue while it plays, like a move does.
			_wait_frames = warmup + int(_micro[mghand]["frames"])
		_:
			_send({"type": "event", "error": "unknown action type %s" % action.get("type", "")})


func _step_move() -> void:
	# Progress by TIME when the caller asked for it. A frame-counted travel runs
	# at whatever rate the host manages, and anything sampling it on the fixed
	# physics clock - the poke interactor's shape query, for one - sees a
	# different motion each run. That is a race, and it read as an interaction
	# that worked about half the time.
	var timed := _move.has("seconds")
	if timed:
		_move.elapsed = float(_move.get("elapsed", 0.0)) + get_process_delta_time()
	var t := 0.0
	if timed:
		t = float(_move.elapsed) / float(_move.seconds)
	else:
		t = float(_move.step) / float(_move.frames)
	t = clampf(t, 0.0, 1.0)
	var e := ease_value(str(_move.get("easing", "smooth")), t)
	var moving := int(_move.hand)
	if _move.has("basis_to"):
		_held_basis[moving] = (_move.basis_from as Basis).slerp(_move.basis_to, e)
	var pos: Vector3 = (_move.from as Vector3).lerp(_move.to, e)
	var aim: Vector3 = _move.aim
	_publish_pose(moving, pos, aim if aim.is_finite() else pos)
	if _move.has("anchor"):
		var along: Vector3 = (_move.anchor_from as Vector3).lerp(_move.anchor_to, e)
		pos = _wrist_for(moving, str(_move.anchor), along)
		_publish_pose(moving, pos, aim if aim.is_finite() else pos)
	# The joints follow from here, or the hand would stay put and jump on
	# arrival while its controller pose travelled.
	_last_pos[clampi(moving, 0, 1)] = pos
	_move.step += 1
	# Both paths must hand the destination over to the HELD pose, or the next
	# frame's republish restores where the hand was before the move and it
	# snaps back - which reads as the interaction never happening.
	var done := false
	if timed:
		done = float(_move.elapsed) >= float(_move.seconds)
	else:
		done = _move.step > int(_move.frames)
	if done:
		if _move.has("anchor"):
			_pin[moving] = {"anchor": _move.anchor, "target": _move.anchor_to}
		else:
			_last_pos[clampi(moving, 0, 1)] = _move.to
		_held_aim[clampi(moving, 0, 1)] = aim if aim.is_finite() else _last_pos[clampi(moving, 0, 1)]
		_move = {}


## How a timed drive moves through its span. `smooth` is what moves have always
## used. `minimum-jerk` is the start and stop of a human reach.
static func ease_value(easing: String, t: float) -> float:
	var c := clampf(t, 0.0, 1.0)
	match easing:
		"linear":
			return c
		"minimum-jerk":
			return c * c * c * (10.0 + c * (-15.0 + 6.0 * c))
		_:
			return c * c * (3.0 - 2.0 * c)


func _send_reading(text: String, node := "") -> void:
	_send({"type": "event", "signal": text, "node": node, "frame": _drive_frame,
			"engine_frame": Engine.get_process_frames()})


func _find_node(path: String) -> Node:
	var root := get_tree().current_scene if get_tree().current_scene else get_tree().root
	var found: Node = root.get_node_or_null(NodePath(path))
	if found == null:
		# Fall back to a name search: hints and dumps quote paths relative to
		# whichever root they walked, and a drive should not fail because two
		# roots disagree about a prefix.
		found = root.find_child(path.get_file(), true, false)
	return found


## A named pose as joints: the curl poses, then the gesture library.
func _named_pose(hand: int, pose_name: String) -> Array:
	if pose_name in _CURL_POSES:
		var joints: Array = _pose_math.fk_pose(_bind[hand]["rel"], _bind[hand]["curl_axes"], _curls_for(pose_name))
		return _pose_math.pinch_pose(joints) if pose_name == "pinch" else joints
	return _gesture_joints(hand, pose_name)


## `fingers` = {ring: "fist", index: {to: "point", weight: 0.5}, thumb: {curl: 0.2}}.
## Empty on any name it cannot resolve, after saying which.
func _with_fingers(hand: int, base: Array, fingers: Dictionary) -> Array:
	var targets := {}
	for finger in fingers:
		if not (finger in _pose_math.FINGER_NAMES):
			_send({"type": "event", "error": "no finger named '%s'" % finger})
			return []
		var spec: Variant = fingers[finger]
		var target: Dictionary = spec if spec is Dictionary else {"to": spec}
		var to: Array = []
		if target.has("curl"):
			to = _pose_math.fk_pose(_bind[hand]["rel"], _bind[hand]["curl_axes"], {finger: float(target["curl"])})
		else:
			to = _named_pose(hand, str(target.get("to", "")))
		if to.is_empty():
			_send({"type": "event", "error": "no pose named '%s' for %s" % [target.get("to", ""), finger]})
			return []
		targets[finger] = {"joints": to, "weight": float(target.get("weight", 1.0))}
	return _pose_math.blend_pose(base, targets)


## Takes a pose at once, or fades to it over `seconds` while the queue waits, the
## way a move holds it.
func _show_pose(hand: int, joints: Array, pose_name: String, action: Dictionary) -> void:
	var seconds := float(action.get("seconds", 0.0))
	if seconds <= 0.0 or not _hand_state.has(hand):
		_fade.erase(hand)
		_hand_state[hand] = {"joints": joints, "pose": pose_name}
	else:
		_fade[hand] = {"from": _hand_state[hand]["joints"], "to": joints, "elapsed": 0.0,
				"seconds": seconds, "easing": str(action.get("easing", "minimum-jerk"))}
		_hand_state[hand]["pose"] = pose_name
		_wait_seconds = seconds
	_publish_hand(hand)


func _step_fades(delta: float) -> void:
	for hand in _fade.keys():
		var fade: Dictionary = _fade[hand]
		fade["elapsed"] = float(fade["elapsed"]) + delta
		var t := float(fade["elapsed"]) / float(fade["seconds"])
		if t >= 1.0:
			_hand_state[hand]["joints"] = fade["to"]
			_fade.erase(hand)
			continue
		var weight := ease_value(str(fade["easing"]), t)
		var targets := {}
		for finger in _pose_math.FINGER_NAMES:
			targets[finger] = {"joints": fade["to"], "weight": weight}
		_hand_state[hand]["joints"] = _pose_math.blend_pose(fade["from"], targets)


func _resolve_pins() -> void:
	for hand in _pin:
		if _hand_state.has(hand) and (_move.is_empty() or int(_move.get("hand", -1)) != hand):
			# Publish first: the solve reads the hand's facing from the tracker,
			# and the desktop simulator writes that tracker every frame too.
			_publish_pose(hand, _last_pos[clampi(hand, 0, 1)], _held_aim.get(clampi(hand, 0, 1), _last_pos[clampi(hand, 0, 1)]))
			_last_pos[clampi(hand, 0, 1)] = _wrist_for(hand, str(_pin[hand]["anchor"]), _pin[hand]["target"])


func _can_anchor(hand: int, anchor: String) -> bool:
	if not _ensure_hands() or not _hand_state.has(hand):
		_send({"type": "event", "error": "anchor needs a hand pose: drive a `hand` action on hand %d first" % hand})
		return false
	if not _anchor_local(hand, anchor).is_finite():
		_send({"type": "event", "error": "no hand anchor named '%s'" % anchor})
		return false
	return true


## The named point in the hand's own frame, in its current shape. Any WebXR joint
## name works, plus index-tip, thumb-tip and grasp. `grasp` is where the thumb and
## index meet in a full pinch, so it stays put while the hand closes: place it on
## an object, pinch, and both fingertips arrive there with the wrist still.
func _anchor_local(hand: int, anchor: String) -> Vector3:
	var joints: Array = _hand_state[hand]["joints"]
	match anchor:
		"index-tip":
			return (joints[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP] as Transform3D).origin
		"thumb-tip":
			return (joints[XRHandTracker.HAND_JOINT_THUMB_TIP] as Transform3D).origin
		"palm":
			return (joints[XRHandTracker.HAND_JOINT_PALM] as Transform3D).origin
		"grasp":
			if not _grasp_points.has(hand):
				var pinch := _named_pose(hand, "pinch")
				_grasp_points[hand] = ((pinch[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP] as Transform3D).origin
						+ (pinch[XRHandTracker.HAND_JOINT_THUMB_TIP] as Transform3D).origin) * 0.5
			return _grasp_points[hand]
	var by_name: Dictionary = _pose_math.joint_name_map()
	if by_name.has(anchor):
		return (joints[by_name[anchor]] as Transform3D).origin
	return Vector3.INF


## The hand's wrist-relative frame in the world, as it is being published.
func _hand_world(hand: int) -> Transform3D:
	return Transform3D(_hand_world_basis(hand) * (_bind[hand]["align"] as Basis), _last_pos[clampi(hand, 0, 1)])


## Where the hand has to be for the named point to land on `target`.
func _wrist_for(hand: int, anchor: String, target: Vector3) -> Vector3:
	return target - (_hand_world_basis(hand) * (_bind[hand]["align"] as Basis)) * _anchor_local(hand, anchor)


func _read_hand(hand: int) -> Dictionary:
	var world := _hand_world(hand)
	var joints: Array = _hand_state[hand]["joints"]
	var at := func(joint: int) -> Vector3: return world * (joints[joint] as Transform3D).origin
	var as_list := func(v: Vector3) -> Array: return [snappedf(v.x, 0.0001), snappedf(v.y, 0.0001), snappedf(v.z, 0.0001)]
	var wrist: Vector3 = at.call(XRHandTracker.HAND_JOINT_WRIST)
	var points := {
		"wrist": as_list.call(wrist),
		"grasp": as_list.call(world * _anchor_local(hand, "grasp")),
		"thumb-tip": as_list.call(at.call(XRHandTracker.HAND_JOINT_THUMB_TIP)),
		"index-tip": as_list.call(at.call(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP)),
		"middle-tip": as_list.call(at.call(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP)),
		"ring-tip": as_list.call(at.call(XRHandTracker.HAND_JOINT_RING_FINGER_TIP)),
		"pinky-tip": as_list.call(at.call(XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP)),
	}
	# Measured from the joints, so a case checks the hand and not the request.
	var middle: Vector3 = at.call(XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL)
	var index: Vector3 = at.call(XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL)
	var pinky: Vector3 = at.call(XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL)
	return {
		"pose": _hand_state[hand]["pose"],
		"fading": _fade.has(hand),
		"pinned": str(_pin[hand]["anchor"]) if _pin.has(hand) else "",
		"points": points,
		"axes": {"fingers": as_list.call((middle - wrist).normalized()), "thumb": as_list.call((index - pinky).normalized())},
	}


## Eye, forward and right of the body: the head's yaw, ignoring pitch and roll, so
## a named direction means the same thing wherever the head is looking.
func _head_frame() -> Dictionary:
	var camera := get_viewport().get_camera_3d() if get_viewport() != null else null
	var eye := camera.global_position if camera != null else Vector3(0, 1.6, 0)
	var forward := -camera.global_basis.z if camera != null else Vector3.FORWARD
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() > 0.000001 else Vector3.FORWARD
	return {"eye": eye, "forward": forward, "right": forward.cross(Vector3.UP).normalized()}


func _direction(value: Variant, from: Vector3) -> Vector3:
	if value is Array:
		return _vec(value).normalized()
	var head := _head_frame()
	match str(value):
		"up":
			return Vector3.UP
		"down":
			return Vector3.DOWN
		"forward":
			return head["forward"]
		"back":
			return -(head["forward"] as Vector3)
		"right":
			return head["right"]
		"left":
			return -(head["right"] as Vector3)
		"toward-head":
			return ((head["eye"] as Vector3) - from).normalized()
		"away-from-head":
			return (from - (head["eye"] as Vector3)).normalized()
	_send({"type": "event", "error": "no direction named '%s'" % str(value)})
	return Vector3.FORWARD


## The tracker frame looks down -Z with the palm toward -Y.
func _palm_basis(fingers: Vector3, palm: Vector3) -> Basis:
	var z := -fingers
	var up := (-palm - z * (-palm).dot(z)).normalized()
	return Basis(up.cross(z), up, z)


## `orient` = {fingers, palm}, {fingers, thumb}, or "auto" for a relaxed reach
## toward `at`. Directions are vectors or names; see _direction.
func _orient_basis(hand: int, orient: Variant, at: Vector3) -> Basis:
	if orient is String:
		return _reach_basis(hand, at)
	var spec: Dictionary = orient
	var fingers := _direction(spec.get("fingers", "forward"), at)
	if not spec.has("thumb"):
		return _palm_basis(fingers, _direction(spec.get("palm", "down"), at))
	# The thumb side is -X on a right hand and +X on a left one.
	var thumb := _direction(spec["thumb"], at)
	var side := -thumb if hand == XRInputAdapter.Hand.RIGHT else thumb
	var z := -fingers
	var x := (side - z * side.dot(z)).normalized()
	return Basis(x, z.cross(x), z)


## Fingers along the forearm from an estimated shoulder and elbow, palm down and
## rolled a little toward thumb-up, as a relaxed arm reaches.
func _reach_basis(hand: int, at: Vector3) -> Basis:
	var head := _head_frame()
	var eye: Vector3 = head["eye"]
	var forward: Vector3 = head["forward"]
	var right: Vector3 = head["right"]
	var outward := 0.18 if hand == XRInputAdapter.Hand.RIGHT else -0.18
	var shoulder := eye + right * outward + Vector3.DOWN * 0.25 - forward * 0.05
	var elbow := shoulder + Vector3.DOWN * 0.25 + forward * 0.12
	var medial := -right if hand == XRInputAdapter.Hand.RIGHT else right
	return _palm_basis((at - elbow).normalized(), Vector3.DOWN + medial * tan(deg_to_rad(15.0)))


## Captures `properties` of every node in `paths` under `label`. A property that
## cannot be read is recorded as such, so a diff shows it rather than skips it.
func _take_snapshot(action: Dictionary) -> void:
	var label := str(action.get("label", "snapshot"))
	var values := {}
	for path in action.get("paths", []):
		var node := _find_node(str(path))
		for property in action.get("properties", ["position"]):
			var key := "%s:%s" % [path, property]
			var read: Variant = node.get_indexed(NodePath(str(property))) if node != null else null
			values[key] = str(read) if read != null else "<missing>"
	_snapshots.erase(label)
	_snapshots[label] = values
	while _snapshots.size() > _MAX_SNAPSHOTS:
		_snapshots.erase(_snapshots.keys()[0])
	_send_reading("snapshot[%s] %d values" % [label, values.size()])


func _send_diff(from_label: String, to_label: String) -> void:
	if not _snapshots.has(from_label) or not _snapshots.has(to_label):
		_send({"type": "event", "error": "diff: no snapshot named '%s'" % (to_label if _snapshots.has(from_label) else from_label)})
		return
	var before: Dictionary = _snapshots[from_label]
	var after: Dictionary = _snapshots[to_label]
	var changed := {}
	for key in after:
		if not before.has(key) or before[key] != after[key]:
			changed[key] = [before.get(key, "<absent>"), after[key]]
	_send_reading("diff[%s->%s] %s" % [from_label, to_label, JSON.stringify(changed)])


func _apply_gaze(action: Dictionary) -> void:
	if not bool(action.get("connected", true)):
		_held_gaze = {}
		var tracker := XRServer.get_tracker(_GAZE_TRACKER) as XRControllerTracker
		if tracker != null:
			XRServer.remove_tracker(tracker)
			_owned_trackers.erase(tracker)
		return
	if action.has("at"):
		_held_gaze["at"] = _vec(action["at"])
	_held_gaze["tracked"] = bool(action.get("tracked", true))
	_publish_gaze()


func _publish_gaze() -> void:
	var tracker := XRServer.get_tracker(_GAZE_TRACKER) as XRControllerTracker
	if tracker == null:
		tracker = XRControllerTracker.new()
		tracker.name = _GAZE_TRACKER
		XRServer.add_tracker(tracker)
		_owned_trackers.append(tracker)
	var camera := get_viewport().get_camera_3d() if get_viewport() != null else null
	if not bool(_held_gaze.get("tracked", true)) or camera == null or not _held_gaze.has("at"):
		tracker.invalidate_pose(&"default")
		return
	var eye := camera.global_position
	var basis := Basis.looking_at((_held_gaze["at"] as Vector3) - eye, Vector3.UP)
	tracker.set_pose(&"default", _to_play_space(Transform3D(basis, eye)), Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


## Tracker-level pose publication, identical to the headless simulator's:
## the rig binds specific pose names, so all three are published.
func _apply_view(eye: Vector3, target: Vector3) -> void:
	var camera := get_viewport().get_camera_3d() if get_viewport() != null else null
	if camera == null:
		return
	camera.global_transform = Transform3D(Basis(), eye)
	if not target.is_equal_approx(eye):
		camera.look_at(target, Vector3.UP)


func _publish_pose(hand: int, pos: Vector3, aim_target: Vector3) -> void:
	var tracker := _tracker(hand)
	if tracker == null:
		return
	var basis := Basis()
	if _held_basis.has(hand):
		basis = _held_basis[hand]
	elif not aim_target.is_equal_approx(pos):
		basis = Basis.looking_at(aim_target - pos, Vector3.UP)
	var xform := _to_play_space(Transform3D(basis, pos))
	for pose_name in [&"default", &"aim", &"grip"]:
		tracker.set_pose(pose_name, xform, Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)



## World -> play space. Tracker poses are origin-local; drives are authored
## in world, which is the space a scene is read in.
func _to_play_space(world: Transform3D) -> Transform3D:
	var origin := _origin_node()
	if origin == null:
		return world
	return origin.global_transform.affine_inverse() * world


func _origin_node() -> XROrigin3D:
	if _origin == null or not is_instance_valid(_origin):
		_origin = XRRigResolver.find_origin(self)
		if _origin == null:
			# The resolver walks up from this node and scans the current scene;
			# an INJECTED actuator has neither - its parent is the tree root and
			# the host never made the scene current. Failing to find the origin
			# is silent and wrong rather than loud: _to_play_space then returns
			# world coordinates unchanged, so every driven pose lands offset by
			# the rig's transform. Invisible in a scene whose origin sits at
			# identity, and measured as "nothing interacts at all" in one whose
			# origin does not.
			_origin = _find_origin_in_tree()
	return _origin


func _find_origin_in_tree() -> XROrigin3D:
	if get_tree() == null:
		return null
	for node in get_tree().root.find_children("*", "XROrigin3D", true, false):
		return node as XROrigin3D
	return null

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
	# Independently of the adapter: waking the runtimes is about HANDS being
	# driven, and the adapter walk above returns early on any scene without a
	# rig - which is every scene the headless host injects this node into, so
	# gating one on the other left the recognizers asleep exactly there.
	_wake_gesture_runtimes()
	return true


## Off its own platform an adapter parks its _process, so nothing runs the
## synthetic-pinch detector - joints would be published and no select would
## ever fire. Driving hands means waking the adapter that owns this platform
## and pointing the interactors at it, exactly as the desktop simulator does.
## The desktop simulator fakes the same trackers this node drives, and writes
## its inputs EVERY frame from keyboard state - zero, when nobody is at a
## keyboard. Two drivers of one tracker means the last writer wins, so a stick
## set once by a drive was erased before locomotion sampled it and teleport
## passed or failed by a race.
##
## Stood down the first time a drive writes an INPUT, and deliberately not
## restored: from that moment the operator owns this app's input for the rest
## of the run. The simulator already stands itself down for a real XR session
## on the same reasoning - whoever is really driving wins.
##
## Scoped to input on purpose. The simulator also resolves the rig and points
## interactors at the platform adapter, and drives that need none of its INPUT
## (a poke, say, which is pure hand geometry) still want those services - so
## they are left alone rather than being made to depend on this node
## reproducing everything the simulator does.
func _stand_down_simulator() -> void:
	if get_tree() == null:
		return
	for node in get_tree().root.find_children("*", "", true, false):
		if node.get_script() != null and str(node.get_script().get_global_name()) == "XRSimulator" 				and node.is_processing():
			node.set_process(false)
			# Its help overlay narrates keyboard controls nobody is pressing, and
			# sits on top of any capture of the drive.
			if node.get("show_help") != null:
				node.set("show_help", false)
			var layer = node.get("_help_layer")
			if layer != null and is_instance_valid(layer):
				(layer as CanvasLayer).visible = false


func _wake_platform_adapter() -> void:
	# Searched from the tree ROOT, not from this node's parent: an injected
	# actuator is a child of root, so the sibling lookup found nothing and
	# silently did neither half of this job. The desktop simulator happened to
	# wake the adapter too, which masked it - until the simulator was stood
	# down for the drive and poke stopped firing.
	var rig: Node = get_parent()
	var wanted := "WebXRInputAdapter" if OS.has_feature("web") else "OpenXRInputAdapter"
	var adapter: Node = rig.get_node_or_null(wanted) if rig != null else null
	if adapter == null:
		return
	adapter.set_process(true)
	var search_root: Node = rig if rig != null else get_tree().root
	for interactor in _adapter_interactors(search_root):
		if interactor.has_method(&"set_input_adapter"):
			interactor.set_input_adapter(adapter)


## Gesture runtimes skip their whole update outside an XR session, so a
## driven hand would be published and never sampled - the recognizers would
## report nothing and look broken. A hand this node is driving IS hand
## input, session or not, so the runtimes are told to run.
func _wake_gesture_runtimes() -> void:
	# The tree ROOT, not current_scene: a host that injects this node adds the
	# scene under root without making it current, and that walk found nothing.
	var scene: Node = get_tree().root if get_tree() else null
	if scene == null:
		return
	for node in scene.find_children("*", "", true, false):
		if node.get("process_without_xr") != null and not bool(node.get("process_without_xr")):
			node.set("process_without_xr", true)


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
	var basis: Basis = _hand_world_basis(hand) * (_bind[hand]["align"] as Basis)
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
	var anchor := _to_play_space(Transform3D(_hand_world_basis(hand) * align, pos + sway))
	# NOTE the pinch is closed rotationally at pose time (pinch_pose) - the
	# positional tip morph that used to live here was low-passed into
	# nothing by the conditioning chain, exactly like the microgesture's
	# stretched thumb, and the select arrived seconds late or never.
	if _micro.has(hand):
		var m: Dictionary = _micro[hand]
		# Negative steps are the warm-up: posture held, thumb resting off
		# the finger, which is the state the envelope is learned from.
		var micro_step := int(m["step"])
		if micro_step >= 0:
			m["elapsed"] = float(m["elapsed"]) + get_process_delta_time()
			var micro_t: float = clampf(float(m["elapsed"]) / float(m["seconds"]), 0.0, 1.0)
			# A POSE, not a moved fingertip: the thumb is swung by rotating
			# its joints, the only form of this motion that survives the
			# conditioning chain every recognizer reads through (see
			# XRHandPoseMath.microgesture_pose).
			joints = _pose_math.microgesture_pose(joints, str(m["kind"]), micro_t)
		m["step"] = micro_step + 1
		# Done when the MOTION is done, not when a frame budget runs out: on a
		# fast host a frame count expires mid-swipe, and the thumb never reaches
		# the lift that ends the contact episode and commits the gesture. The
		# frame cap stays as a hang guard.
		if micro_step >= 0 and (float(m["elapsed"]) >= float(m["seconds"]) 				or int(m["step"]) > int(m["frames"]) * 8):
			_micro.erase(hand)
	for joint in joints.size():
		var world: Transform3D = anchor * (joints[joint] as Transform3D)
		tracker.set_hand_joint_transform(joint,
				Transform3D(world.basis * _pose_math.GODOT_HAND_REBASE, world.origin))
		tracker.set_hand_joint_flags(joint, _JOINT_FLAGS)
	tracker.has_tracking_data = true


## The hand's world orientation: the same aim the controller pose uses, so a
## driven hand and its ray point the same way.
func _hand_world_basis(hand: int) -> Basis:
	# The tracker holds a play-space pose; the anchor is built in world and
	# converted once, so this hands back the world basis.
	var tracker := _tracker(hand)
	if tracker:
		var pose := tracker.get_pose(&"default")
		if pose:
			var origin := _origin_node()
			if origin:
				return (origin.global_transform * pose.transform).basis
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
		"teleported": true, "snap_turned": true,
		# The AIM lifecycle too: without it a teleport that engaged and then
		# failed to commit is indistinguishable from one that never armed.
		"teleport_aim_started": true, "teleport_cancelled": true,
		"climb_started": true, "climb_ended": true,
		"gesture_started": true, "gesture_ended": true,
		# The thumb recognizers use their own names; listening only for the
		# gesture_* pair made a working microgesture look like a dead one.
		"microgesture_performed": true, "microgesture_candidate": true,
		"pose_performed": true, "pose_ended": true,
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


## Wide enough for the largest signal here plus the two bound arguments:
## a 3-argument signal (microgesture_performed, gesture_started) arrives as
## FIVE, and a handler that took four made Godot refuse the call - the
## recognizer fired, the error went to a stdout the operator discards, and
## the drive reported the interaction as dead.
func _on_event(a = null, b = null, c = null, d = null, e = null, f = null) -> void:
	var args := [a, b, c, d, e, f]
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
