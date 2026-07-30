extends SceneTree

## Headless tests for the microgesture -> locomotion CONSUMER layer: the
## teleport-intent state machine's gap-proofing and the driver's
## platform-vs-recognizer source preference.
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_interaction_toolkit/tests/test_microgesture_locomotion.gd
##
## Every case here is a measured on-device failure ("teleport comes out of
## nowhere" / "the arc is not consistently removed"), not a hypothetical:
## a hidden arc kept its stale target and a later tap teleported to it; a
## gesture on the other hand silently stole the aim; a snap turn rotated
## the rig under a live arc.

const XRLocomotionScript := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_locomotion.gd")
const DriverScript := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_microgesture_locomotion_driver.gd")

const DT := 1.0 / 72.0

var _ran := false


## Records every locomotion call the driver makes, so the mux tests assert
## on WHAT reached locomotion rather than on internal driver state.
class _LocomotionStub extends Node:
	var calls: Array[String] = []
	var aiming := false

	func do_snap_turn(direction: float) -> void:
		calls.append("snap:%+d" % int(signf(direction)))

	func begin_teleport_aim(hand: int) -> void:
		aiming = true
		calls.append("aim:%d" % hand)

	func commit_teleport(hand: int) -> void:
		calls.append("commit:%d" % hand)

	func cancel_teleport(hand: int = -1) -> void:
		aiming = false
		calls.append("cancel:%d" % hand)

	func is_aiming(_hand: int = -1) -> bool:
		return aiming

	func refresh_teleport_aim(hand: int) -> void:
		calls.append("refresh:%d" % hand)


## First-frame runner: the snap-turn test needs in-tree nodes for global
## transforms, and root only enters the tree after SceneTree::initialize.
func _process(_delta: float) -> bool:
	if _ran:
		return false
	_ran = true
	_run_all()
	return false


func _run_all() -> void:
	var failures: Array[String] = []
	_test_lost_ray_kills_the_target(failures)
	_test_hand_handoff_cancels_and_invalidates(failures)
	_test_snap_turn_cancels_active_aim(failures)
	_test_disable_mid_aim_cancels(failures)
	_test_platform_gestures_win_per_hand(failures)
	_test_portable_mode_ignores_platform_source(failures)
	_test_session_override_forces_platform(failures)
	_test_rejection_relay_respects_the_mux(failures)
	_test_supports_gesture_reflects_the_active_source(failures)
	_test_leaving_posture_cancels_gesture_aim(failures)
	_test_posture_watchdog_never_touches_foreign_aim(failures)
	_test_unknown_posture_holds_the_aim(failures)
	_test_held_posture_outlives_the_intent_timeout(failures)
	_test_ambiguous_posture_neither_cancels_nor_extends(failures)

	if failures.is_empty():
		print("XR microgesture locomotion: PASS")
		quit(0)
	else:
		for f in failures:
			push_error(f)
		print("XR microgesture locomotion: FAIL (%d)" % failures.size())
		quit(1)


## Minimal stand-in for the gesture runtime: the watchdog only calls
## get_features(hand).
class _FeaturesStubRuntime extends Node:
	var features := {}

	func get_features(hand: int):
		return features.get(hand)


func _posture_features(curl: float) -> XRHandFeatures:
	var features := XRHandFeatures.new()
	features.valid = true
	features.tracking_quality = 1.0
	for finger in range(XRHandFeatures.Finger.INDEX, XRHandFeatures.Finger.PINKY + 1):
		features.finger_curls[finger] = curl
	return features


## The reported bug: tap the arc on, open the hand, arc stays forever. The
## aim a GESTURE began must end when the posture breaks -- after the grace,
## not instantly (a commit gesture in flight wobbles the posture).
func _test_leaving_posture_cancels_gesture_aim(failures: Array[String]) -> void:
	DriverScript.session_platform_override = -1
	var driver = DriverScript.new()
	var stub := _LocomotionStub.new()
	driver._locomotion = stub
	var runtime := _FeaturesStubRuntime.new()
	driver._gesture_runtime = runtime
	var recognizer: Node = (load("res://addons/godot_xr_hands/runtime/recognition/xr_thumb_microgesture_recognizer.gd") as GDScript).new()
	driver._recognizer = recognizer

	driver._on_gesture(4, 1, 1.0)  # TAP while not aiming: begins the aim
	if not stub.aiming:
		failures.append("fixture broken: the tap must begin the aim")

	# In posture: the watchdog must hold indefinitely.
	runtime.features[1] = _posture_features(0.8)
	driver._process(1.0)
	if not stub.aiming:
		failures.append("the watchdog must not cancel while the posture holds")

	# Posture breaks (hand opens): survives WITHIN the grace...
	runtime.features[1] = _posture_features(0.02)
	driver._process(0.2)
	if not stub.aiming:
		failures.append("a posture break shorter than the grace must not cancel -- a commit gesture in flight wobbles the posture")
	# ...and cancels once the grace is spent.
	driver._process(0.3)
	if stub.aiming:
		failures.append("the aim must cancel once the posture has been gone past the grace -- this is the reported stuck-arc bug")
	if not ("cancel:1" in stub.calls):
		failures.append("the cancel must go through the locomotion API for hand 1, got %s" % [stub.calls])
	driver.free()
	stub.free()
	runtime.free()
	recognizer.free()


## Stick-driven controller aim has no hand posture. The watchdog must key on
## aims THIS DRIVER began, never on is_aiming alone -- a vanished hand scores
## 0, and cancelling a controller aim because the OTHER modality's posture
## is absent would break thumbstick teleport wholesale.
func _test_posture_watchdog_never_touches_foreign_aim(failures: Array[String]) -> void:
	DriverScript.session_platform_override = -1
	var driver = DriverScript.new()
	var stub := _LocomotionStub.new()
	driver._locomotion = stub
	var runtime := _FeaturesStubRuntime.new()
	driver._gesture_runtime = runtime
	var recognizer: Node = (load("res://addons/godot_xr_hands/runtime/recognition/xr_thumb_microgesture_recognizer.gd") as GDScript).new()
	driver._recognizer = recognizer

	# Aim begun by something else (the stick): stub says aiming, but the
	# driver never began it. No features at all -- score would be 0.
	stub.aiming = true
	driver._process(5.0)
	if not stub.aiming:
		failures.append("the watchdog cancelled an aim it did not begin -- stick teleport would be broken for every controller user")
	driver.free()
	stub.free()
	runtime.free()
	recognizer.free()


## The first watchdog's regression, reported within one session: an aiming
## fist points away from the cameras, its curled fingers self-occlude, and
## features flicker invalid or low-quality while the pose is held perfectly.
## UNKNOWN posture must HOLD the aim -- unobservable is not gone -- and only
## positive evidence of an open hand may cancel. A truly abandoned aim is
## bounded by XRLocomotion's own intent timeout, not by this watchdog.
func _test_unknown_posture_holds_the_aim(failures: Array[String]) -> void:
	DriverScript.session_platform_override = -1
	var driver = DriverScript.new()
	var stub := _LocomotionStub.new()
	driver._locomotion = stub
	var runtime := _FeaturesStubRuntime.new()
	driver._gesture_runtime = runtime
	var recognizer: Node = (load("res://addons/godot_xr_hands/runtime/recognition/xr_thumb_microgesture_recognizer.gd") as GDScript).new()
	driver._recognizer = recognizer

	driver._on_gesture(4, 1, 1.0)  # begin the aim

	# No features at all.
	driver._process(5.0)
	if not stub.aiming:
		failures.append("missing features must hold the aim, not cancel it")
	# Features present but INVALID (tracking loss on the occluded fist).
	var invalid := _posture_features(0.8)
	invalid.valid = false
	runtime.features[1] = invalid
	driver._process(5.0)
	if not stub.aiming:
		failures.append("invalid features must hold the aim -- this is the occluded-fist case reported on device")
	# Valid but LOW QUALITY: still not evidence of an open hand.
	var poor := _posture_features(0.8)
	poor.tracking_quality = 0.1
	runtime.features[1] = poor
	driver._process(5.0)
	if not stub.aiming:
		failures.append("low-quality features must hold the aim -- quality loss is not posture exit")
	driver.free()
	stub.free()
	runtime.free()
	recognizer.free()


## The intent timeout bounds ABANDONED aims, but it reaped patient ones: a
## user holding the aiming fist past 3 seconds lost the arc mid-aim. While
## the posture is positively held the driver refreshes the clock, so expiry
## only reaps aims whose posture is gone or unknowable for the full window.
func _test_held_posture_outlives_the_intent_timeout(failures: Array[String]) -> void:
	# Locomotion level: refresh resets the clock; without it, the same aim dies.
	var refreshed = XRLocomotionScript.new()
	refreshed.begin_teleport_aim(0)
	for i in range(8):
		refreshed._intent_time += 0.5
		refreshed.refresh_teleport_aim(0)
	if refreshed._intent_time > 0.0 or not refreshed.is_aiming(0):
		failures.append("refresh_teleport_aim must reset the intent clock for the aiming hand")
	# The keep-alive must not extend a hand that is not aiming.
	refreshed._intent_time = 1.0
	refreshed.refresh_teleport_aim(1)
	if refreshed._intent_time != 1.0:
		failures.append("refresh for the WRONG hand must not touch the clock -- a keep-alive must not extend a handed-off aim")
	refreshed.free()

	# Driver level: a positively held posture emits the keep-alive each frame.
	DriverScript.session_platform_override = -1
	var driver = DriverScript.new()
	var stub := _LocomotionStub.new()
	driver._locomotion = stub
	var runtime := _FeaturesStubRuntime.new()
	driver._gesture_runtime = runtime
	var recognizer: Node = (load("res://addons/godot_xr_hands/runtime/recognition/xr_thumb_microgesture_recognizer.gd") as GDScript).new()
	driver._recognizer = recognizer
	driver._on_gesture(4, 1, 1.0)
	runtime.features[1] = _posture_features(0.8)
	driver._process(0.1)
	if not ("refresh:1" in stub.calls):
		failures.append("a positively held posture must refresh the locomotion intent clock, got %s" % [stub.calls])
	# Unknown posture must NOT refresh: the timeout is exactly what bounds it.
	stub.calls.clear()
	runtime.features.erase(1)
	driver._process(0.1)
	if "refresh:1" in stub.calls:
		failures.append("an UNKNOWN posture must not refresh the clock -- the timeout is what bounds an unobservable aim")
	driver.free()
	stub.free()
	runtime.free()
	recognizer.free()


## The tilted-fist fix: a fist tilted UP points its knuckles at the cameras
## and its curl readings collapse into the band between the exit bar and the
## release gate -- the same band a relaxing hand passes through. AMBIGUOUS
## must do NOTHING: no cancel (that was "we lose the arc when we tilt our
## hand up") and no keep-alive either (the intent timeout must stay able to
## bound it).
func _test_ambiguous_posture_neither_cancels_nor_extends(failures: Array[String]) -> void:
	DriverScript.session_platform_override = -1
	var driver = DriverScript.new()
	var stub := _LocomotionStub.new()
	driver._locomotion = stub
	var runtime := _FeaturesStubRuntime.new()
	driver._gesture_runtime = runtime
	var recognizer: Node = (load("res://addons/godot_xr_hands/runtime/recognition/xr_thumb_microgesture_recognizer.gd") as GDScript).new()
	driver._recognizer = recognizer

	driver._on_gesture(4, 1, 1.0)
	stub.calls.clear()
	# Curls 0.08: score ~0.29 -- between the exit bar (0.10) and the release
	# gate (0.42). A tilted fist reads here.
	runtime.features[1] = _posture_features(0.08)
	driver._process(5.0)
	if not stub.aiming:
		failures.append("an ambiguous posture must NOT cancel -- this is the tilted-fist bug")
	if "refresh:1" in stub.calls:
		failures.append("an ambiguous posture must NOT keep the aim alive either -- the intent timeout must be able to bound it")
	# A clearly open hand (curls near zero) must still cancel.
	runtime.features[1] = _posture_features(0.01)
	driver._process(1.0)
	if stub.aiming:
		pass  # cancelled as expected
	else:
		if not ("cancel:1" in stub.calls):
			failures.append("fixture: the open-hand cancel must go through the locomotion API")
	if stub.aiming:
		failures.append("a clearly open hand must still cancel after the grace")
	driver.free()
	stub.free()
	runtime.free()
	recognizer.free()


## The stale-target commit: the arc hides because the hand ray is gone, but
## the target used to survive -- and a tap in that window teleported to
## wherever the arc LAST pointed.
func _test_lost_ray_kills_the_target(failures: Array[String]) -> void:
	var loco = XRLocomotionScript.new()
	loco._intent_aim = true
	loco._teleport_hand = 0
	loco._target_valid = true
	loco._project_intent_arc(0)  # no controller, no hand tracker: ray unavailable

	if loco._target_valid:
		failures.append("an unprojectable arc must kill the target with the visuals, not keep it for a stale commit")
	loco.free()


func _test_hand_handoff_cancels_and_invalidates(failures: Array[String]) -> void:
	var loco = XRLocomotionScript.new()
	var cancelled: Array[int] = []
	loco.teleport_cancelled.connect(func(hand: int) -> void: cancelled.append(hand))

	loco.begin_teleport_aim(0)
	loco._target_valid = true
	loco.begin_teleport_aim(1)

	if cancelled != [0]:
		failures.append("re-aiming with the other hand must cancel the first hand observably, got %s" % [cancelled])
	if loco._target_valid:
		failures.append("a hand handoff must invalidate the first hand's target")
	if loco._teleport_hand != 1 or not loco.is_aiming(1):
		failures.append("after the handoff the new hand must be aiming")
	loco.free()


func _test_snap_turn_cancels_active_aim(failures: Array[String]) -> void:
	var origin := Node3D.new()
	root.add_child(origin)
	var camera := Node3D.new()
	origin.add_child(camera)
	var loco = XRLocomotionScript.new()
	loco._origin = origin
	loco._camera = camera

	loco.begin_teleport_aim(0)
	loco.do_snap_turn(1.0)

	if loco.is_aiming():
		failures.append("a snap turn during an intent aim must cancel the aim -- rotating under a live arc leaves it drawn")
	if origin.transform.basis.is_equal_approx(Basis()):
		failures.append("the snap turn itself must still rotate the origin")
	loco.free()
	origin.get_parent().remove_child(origin)
	origin.free()


func _test_disable_mid_aim_cancels(failures: Array[String]) -> void:
	var loco = XRLocomotionScript.new()
	loco.begin_teleport_aim(0)
	loco.enabled = false
	loco._physics_process(DT)

	if loco.is_aiming():
		failures.append("disabling locomotion mid-aim must end the aim, not suspend it")
	loco.free()


## PLATFORM mode: once the runtime detector has fired for a hand, the joint
## recognizer's events for THAT hand are dropped (both sources see the same
## physical gesture -- acting on both double-fires), while the other hand
## keeps the recognizer until the platform proves live there too.
func _test_platform_gestures_win_per_hand(failures: Array[String]) -> void:
	DriverScript.session_platform_override = -1
	var driver = DriverScript.new()
	var stub := _LocomotionStub.new()
	driver._locomotion = stub
	driver.use_platform_microgestures = true

	driver._on_native_gesture(0, 0, 1.0)      # platform LEFT swipe, left hand
	driver._on_recognizer_gesture(1, 0, 0.9)  # joint RIGHT swipe, same hand: dropped
	driver._on_recognizer_gesture(1, 1, 0.9)  # joint RIGHT swipe, other hand: kept

	if stub.calls != ["snap:+1", "snap:-1"]:
		failures.append("platform events must suppress recognizer events per hand only, got %s" % [stub.calls])
	driver.free()
	stub.free()


## PORTABLE mode -- the DEFAULT: the platform source is ignored outright, so
## a Quest session exercises exactly the recognizer path that WebXR, Galaxy
## XR and Link run. Letting both through would double-fire every gesture and
## give a false read of the portable path's quality.
func _test_portable_mode_ignores_platform_source(failures: Array[String]) -> void:
	DriverScript.session_platform_override = -1
	var driver = DriverScript.new()
	var stub := _LocomotionStub.new()
	driver._locomotion = stub

	driver._on_native_gesture(0, 0, 1.0)      # platform event: must be IGNORED
	driver._on_recognizer_gesture(1, 0, 0.9)  # joint recognizer: drives

	if stub.calls != ["snap:-1"]:
		failures.append("portable mode (the default) must ignore the platform source entirely, got %s" % [stub.calls])
	driver.free()
	stub.free()


## The feel_check session override wins over the per-driver export, so one
## in-headset poke flips every driver for the rest of the session.
func _test_session_override_forces_platform(failures: Array[String]) -> void:
	var driver = DriverScript.new()
	var stub := _LocomotionStub.new()
	driver._locomotion = stub
	driver.use_platform_microgestures = false
	DriverScript.session_platform_override = 1

	driver._on_native_gesture(0, 0, 1.0)
	driver._on_recognizer_gesture(1, 0, 0.9)

	if stub.calls != ["snap:+1"]:
		failures.append("the session override must force platform mode over the export, got %s" % [stub.calls])
	DriverScript.session_platform_override = -1
	driver.free()
	stub.free()


## The rejection relay mirrors the performed-path mux exactly: a
## platform-proven hand's recognizer chatter is as non-authoritative in
## rejection as in success -- relaying it would buzz the user about attempts
## the active detector may well have accepted.
func _test_rejection_relay_respects_the_mux(failures: Array[String]) -> void:
	DriverScript.session_platform_override = -1
	var driver = DriverScript.new()
	var relayed: Array = []
	driver.source_gesture_rejected.connect(func(hand: int, reason: int, attempted: int) -> void:
		relayed.append([hand, reason, attempted])
	)
	var performed: Array = []
	driver.source_gesture_performed.connect(func(gesture: int, hand: int) -> void:
		performed.append([gesture, hand])
	)

	# Portable mode (default): recognizer rejections relay, attempted
	# direction intact.
	driver._on_recognizer_rejected(0, 0, 1)
	if relayed != [[0, 0, 1]]:
		failures.append("portable mode must relay recognizer rejections with the attempted direction, got %s" % [relayed])

	# The success relay is post-mux and pre-consumption: it fires even with
	# the driver DISABLED -- telemetry counts what the sources produced, not
	# whether locomotion consumed it. (enabled=false also short-circuits
	# before _resolve_locomotion, which needs a tree this detached fixture
	# does not have.)
	driver.enabled = false
	driver._on_recognizer_gesture(1, 0, 0.9)
	driver.enabled = true
	if performed != [[1, 0]]:
		failures.append("the post-mux success relay must fire for an authoritative gesture, got %s" % [performed])

	# Platform mode, proven hand: that hand's rejections are dropped, the
	# other hand's still relay.
	driver.use_platform_microgestures = true
	driver._platform_hands[0] = true
	driver._on_recognizer_rejected(0, 1, 0)
	driver._on_recognizer_rejected(1, 2, -1)
	if relayed != [[0, 0, 1], [1, 2, -1]]:
		failures.append("a platform-proven hand's rejections must be dropped and the other hand's kept, got %s" % [relayed])
	driver.free()


## supports_gesture answers for whichever source is AUTHORITATIVE for that
## hand right now, so a consumer can say "forward swipe not available here"
## instead of leaving the user swiping into dead air.
func _test_supports_gesture_reflects_the_active_source(failures: Array[String]) -> void:
	DriverScript.session_platform_override = -1
	var driver = DriverScript.new()

	# No sources built (headless driver, hands addon may be absent):
	# optimistic, because absent evidence the pre-contract claim stands.
	if not driver.supports_gesture(2, 0):
		failures.append("with no source built, supports_gesture must stay optimistic")

	# Portable recognizer active: FORWARD (2) unsupported, LEFT (0) supported.
	var recognizer: Node = (load("res://addons/godot_xr_hands/runtime/recognition/xr_thumb_microgesture_recognizer.gd") as GDScript).new()
	var native: Node = (load("res://addons/godot_xr_hands/runtime/recognition/xr_native_microgesture_source.gd") as GDScript).new()
	driver._recognizer = recognizer
	driver._native = native
	if driver.supports_gesture(2, 0):
		failures.append("portable mode must report FORWARD unsupported -- the joint recognizer cannot derive it")
	if not driver.supports_gesture(0, 0):
		failures.append("portable mode must report LEFT supported")

	# Platform-proven hand answers from the native source's full vocabulary;
	# the unproven hand still answers from the recognizer.
	driver.use_platform_microgestures = true
	driver._platform_hands[0] = true
	if not driver.supports_gesture(2, 0):
		failures.append("a platform-proven hand must report FORWARD supported -- the runtime detector emits it")
	if driver.supports_gesture(2, 1):
		failures.append("the unproven hand must still answer from the portable recognizer")
	driver.free()
	recognizer.free()
	native.free()
