extends SceneTree

## Headless tests for the interaction arbiter's transition rule.
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_interaction_toolkit/tests/test_interaction_arbiter.gd

const Arbiter := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_interaction_arbiter.gd")

var _failures: Array[String] = []

func _init() -> void:
	# Pure-function tests need no tree.
	_test_teleport_is_exclusive(_failures)
	_test_proximity_selects_near_or_far(_failures)
	_test_dwell_is_hysteresis(_failures)
	_test_flicker_does_not_strobe(_failures)
	_test_tracking_loss(_failures)

## The scene-based tests are deferred here because a node added to get_root()
## during _init() is not yet inside the tree, and get_tree() lookups assert.
## Same constraint test_grab_feel.gd documents.
func _process(_delta: float) -> bool:
	_test_backcompat_without_arbiter(_failures)
	_test_consult_with_arbiter(_failures)
	_test_teleport_exit_routes(_failures)
	if _failures.is_empty():
		print("XR interaction arbiter: PASS")
		quit(0)
		return true
	for failure in _failures:
		push_error(failure)
	print("XR interaction arbiter: FAIL (%d)" % _failures.size())
	quit(1)
	return true

func _test_teleport_is_exclusive(failures: Array[String]) -> void:
	# Teleport wins from EVERY other mode, including while a near candidate is
	# present -- reaching past a table must not veto a deliberate teleport.
	for previous in [Arbiter.Mode.NONE, Arbiter.Mode.NEAR, Arbiter.Mode.FAR, Arbiter.Mode.TELEPORT]:
		var mode: int = Arbiter.resolve_mode(previous, true, true, true, 10.0, 0.12)
		if mode != Arbiter.Mode.TELEPORT:
			failures.append("teleport must win from mode %d, got %d" % [previous, mode])
	# And it must be LEFT the moment aiming ends. The reported bug is exactly a
	# state entered and never exited, so this is the regression that matters.
	var after: int = Arbiter.resolve_mode(Arbiter.Mode.TELEPORT, true, false, false, 10.0, 0.12)
	if after == Arbiter.Mode.TELEPORT:
		failures.append("teleport must not persist once teleport_active goes false")
	# Leaving teleport must not be delayed by the NEAR dwell either -- the dwell
	# damps a flickering proximity candidate, not an explicit mode change.
	var fresh: int = Arbiter.resolve_mode(Arbiter.Mode.TELEPORT, true, false, false, 0.0, 0.12)
	if fresh == Arbiter.Mode.TELEPORT:
		failures.append("leaving teleport must not wait out the NEAR dwell")

func _test_proximity_selects_near_or_far(failures: Array[String]) -> void:
	if Arbiter.resolve_mode(Arbiter.Mode.FAR, true, true, false, 10.0, 0.12) != Arbiter.Mode.NEAR:
		failures.append("a near candidate must select NEAR")
	if Arbiter.resolve_mode(Arbiter.Mode.NEAR, true, false, false, 10.0, 0.12) != Arbiter.Mode.FAR:
		failures.append("no near candidate (past dwell) must select FAR")

func _test_dwell_is_hysteresis(failures: Array[String]) -> void:
	# NEAR is not abandoned the instant the candidate vanishes.
	if Arbiter.resolve_mode(Arbiter.Mode.NEAR, true, false, false, 0.05, 0.12) != Arbiter.Mode.NEAR:
		failures.append("NEAR must be held through a brief candidate dropout (dwell not elapsed)")
	if Arbiter.resolve_mode(Arbiter.Mode.NEAR, true, false, false, 0.20, 0.12) != Arbiter.Mode.FAR:
		failures.append("NEAR must release once the dwell has elapsed")
	# Entering NEAR is immediate: latency on the way IN reads as unresponsive.
	if Arbiter.resolve_mode(Arbiter.Mode.FAR, true, true, false, 0.0, 0.12) != Arbiter.Mode.NEAR:
		failures.append("entering NEAR must not wait for a dwell")
	# The dwell must not hold a mode it was never meant to: FAR has no dwell.
	if Arbiter.resolve_mode(Arbiter.Mode.FAR, true, true, false, 0.01, 0.12) != Arbiter.Mode.NEAR:
		failures.append("the dwell must apply to leaving NEAR only, not to leaving FAR")

func _test_flicker_does_not_strobe(failures: Array[String]) -> void:
	# The property the whole dwell exists for, driven ACROSS FRAMES rather than
	# asserted at a single instant: a hand at the edge of the hover sphere makes
	# the candidate flicker on and off frame to frame. A static fixture cannot
	# express this at all -- it is the shape of bug this project has shipped
	# eight times -- so the candidate is toggled every frame here.
	var mode: int = Arbiter.Mode.NEAR
	var since_candidate := 0.0
	var dwell := 0.12
	var frame_time := 1.0 / 72.0
	var flips := 0
	for frame in range(60):
		var candidate := frame % 2 == 0  # present, gone, present, gone...
		since_candidate = 0.0 if candidate else since_candidate + frame_time
		var next: int = Arbiter.resolve_mode(mode, true, candidate, false, since_candidate, dwell)
		if next != mode:
			flips += 1
			mode = next
	if flips != 0:
		failures.append("a candidate flickering every frame must not flip the mode at all, flipped %d times" % flips)
	if mode != Arbiter.Mode.NEAR:
		failures.append("a flickering candidate must settle in NEAR, ended in %d" % mode)

	# And the dwell must not make NEAR permanent: once the candidate is really
	# gone, the mode releases within roughly one dwell.
	var released_after := -1
	for frame in range(60):
		since_candidate += frame_time
		var next: int = Arbiter.resolve_mode(mode, true, false, false, since_candidate, dwell)
		if next != mode:
			mode = next
			released_after = frame
			break
	if released_after < 0:
		failures.append("NEAR never released after the candidate genuinely disappeared")
	elif float(released_after) * frame_time > dwell * 2.0:
		failures.append("NEAR took %.3f s to release, far beyond the %.3f s dwell" % [float(released_after) * frame_time, dwell])

func _test_tracking_loss(failures: Array[String]) -> void:
	if Arbiter.resolve_mode(Arbiter.Mode.NEAR, false, true, false, 10.0, 0.12) != Arbiter.Mode.NONE:
		failures.append("an untracked hand must resolve to NONE regardless of candidates")
	if Arbiter.resolve_mode(Arbiter.Mode.NONE, true, false, false, 10.0, 0.12) != Arbiter.Mode.FAR:
		failures.append("recovery from NONE must resolve normally")
	# Tracking loss beats teleport too: no hand, no aiming.
	if Arbiter.resolve_mode(Arbiter.Mode.TELEPORT, false, false, true, 10.0, 0.12) != Arbiter.Mode.NONE:
		failures.append("an untracked hand must leave TELEPORT")

const RayInteractor := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_ray_interactor.gd")

## THE most important assertion in this branch. Adding the arbiter must change
## nothing for the scenes that do not use it -- there are shipped scenes and
## user projects relying on the existing suppression exports.
func _test_backcompat_without_arbiter(failures: Array[String]) -> void:
	var host := Node3D.new()
	get_root().add_child(host)
	var ray := RayInteractor.new()
	host.add_child(ray)

	if Arbiter.find_in_tree(ray) != null:
		failures.append("find_in_tree must return null when no arbiter is in the scene")

	# With no arbiter, no linked interactor, and nothing poking or teleporting,
	# the ray is NOT suppressed -- the pre-change baseline.
	if ray._is_suppressed_by_linked_interactor():
		failures.append("with no arbiter and nothing active, the ray must not be suppressed (back-compat)")

	# The existing exports must still be the thing that decides. Point the ray
	# at a linked interactor that reports a selection: it must suppress, via the
	# old path, with no arbiter involved.
	var linked := RayInteractor.new()
	host.add_child(linked)
	ray.suppress_interactor_path = ray.get_path_to(linked)
	ray.suppress_on_linked_select = true
	linked._selected = Node.new()
	if not ray._is_suppressed_by_linked_interactor():
		failures.append("the existing suppress_on_linked_select path must still work with no arbiter")
	ray.suppress_on_linked_select = false
	if ray._is_suppressed_by_linked_interactor():
		failures.append("clearing suppress_on_linked_select must still unsuppress with no arbiter")

	linked._selected.free()
	host.queue_free()

## With an arbiter present it owns the decision entirely, and the old exports
## no longer get a vote -- one rule in one place is the whole point.
func _test_consult_with_arbiter(failures: Array[String]) -> void:
	var host := Node3D.new()
	get_root().add_child(host)
	var arbiter := Arbiter.new()
	host.add_child(arbiter)
	var ray := RayInteractor.new()
	host.add_child(ray)
	ray.hand = 0

	arbiter._mode[0] = Arbiter.Mode.FAR
	if ray._is_suppressed_by_linked_interactor():
		failures.append("FAR mode must leave the far ray unsuppressed")
	for blocked in [Arbiter.Mode.NEAR, Arbiter.Mode.TELEPORT, Arbiter.Mode.NONE]:
		arbiter._mode[0] = blocked
		if not ray._is_suppressed_by_linked_interactor():
			failures.append("mode %d must suppress the far ray" % blocked)

	# A disabled arbiter must not gate anything: that is the in-headset A/B
	# switch, and it has to hand control back rather than freeze everything off.
	arbiter._mode[0] = Arbiter.Mode.NEAR
	arbiter.enabled = false
	if ray._is_suppressed_by_linked_interactor():
		failures.append("a disabled arbiter must not suppress -- the A/B switch would strand the ray off")

	host.queue_free()

const Locomotion := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_locomotion.gd")

## The reported on-device bug in test form: the arc must not outlive the
## gesture. Drives XRLocomotion's real intent API rather than simulating a
## microgesture, and checks EVERY exit route -- a state that is entered by one
## path and left by only some of them is exactly how an arc gets stuck.
func _test_teleport_exit_routes(failures: Array[String]) -> void:
	var host := Node3D.new()
	get_root().add_child(host)
	var arbiter := Arbiter.new()
	host.add_child(arbiter)
	var locomotion := Locomotion.new()
	host.add_child(locomotion)
	locomotion.teleport_enabled = true

	# Entry.
	locomotion.begin_teleport_aim(0)
	if not locomotion.is_aiming(0):
		failures.append("begin_teleport_aim must start an aim; the rest of this test cannot run")
		host.queue_free()
		return
	if Arbiter.resolve_mode(Arbiter.Mode.FAR, true, false, locomotion.is_aiming(0), 10.0, 0.12) != Arbiter.Mode.TELEPORT:
		failures.append("an active aim must put the hand in TELEPORT")

	# Exit route 1: explicit cancel.
	locomotion.cancel_teleport(0)
	if locomotion.is_aiming(0):
		failures.append("cancel_teleport must end the aim")
	if Arbiter.resolve_mode(Arbiter.Mode.TELEPORT, true, false, locomotion.is_aiming(0), 10.0, 0.12) == Arbiter.Mode.TELEPORT:
		failures.append("cancelling must leave TELEPORT")

	# Exit route 2: commit (no valid target here, so it just ends the aim).
	locomotion.begin_teleport_aim(0)
	locomotion.commit_teleport(0)
	if locomotion.is_aiming(0):
		failures.append("commit_teleport must end the aim even with no valid target")
	if Arbiter.resolve_mode(Arbiter.Mode.TELEPORT, true, false, locomotion.is_aiming(0), 10.0, 0.12) == Arbiter.Mode.TELEPORT:
		failures.append("committing must leave TELEPORT")

	# Exit route 3: tracking loss while aiming -- the hand is gone, so nothing
	# is being aimed regardless of what locomotion still believes.
	locomotion.begin_teleport_aim(0)
	if Arbiter.resolve_mode(Arbiter.Mode.TELEPORT, false, false, locomotion.is_aiming(0), 10.0, 0.12) != Arbiter.Mode.NONE:
		failures.append("losing tracking mid-aim must leave TELEPORT")
	locomotion.cancel_teleport(0)

	host.queue_free()
