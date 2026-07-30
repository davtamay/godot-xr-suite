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

	if failures.is_empty():
		print("XR microgesture locomotion: PASS")
		quit(0)
	else:
		for f in failures:
			push_error(f)
		print("XR microgesture locomotion: FAIL (%d)" % failures.size())
		quit(1)


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
	driver.source_gesture_rejected.connect(func(hand: int, reason: int) -> void:
		relayed.append([hand, reason])
	)

	# Portable mode (default): recognizer rejections relay.
	driver._on_recognizer_rejected(0, 0)
	if relayed != [[0, 0]]:
		failures.append("portable mode must relay recognizer rejections, got %s" % [relayed])

	# Platform mode, proven hand: that hand's rejections are dropped, the
	# other hand's still relay.
	driver.use_platform_microgestures = true
	driver._platform_hands[0] = true
	driver._on_recognizer_rejected(0, 1)
	driver._on_recognizer_rejected(1, 2)
	if relayed != [[0, 0], [1, 2]]:
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
