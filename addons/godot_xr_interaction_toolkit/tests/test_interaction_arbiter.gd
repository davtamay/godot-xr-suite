extends SceneTree

## Headless tests for the interaction arbiter's transition rule.
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_interaction_toolkit/tests/test_interaction_arbiter.gd

const Arbiter := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_interaction_arbiter.gd")

func _init() -> void:
	var failures: Array[String] = []
	_test_teleport_is_exclusive(failures)
	_test_proximity_selects_near_or_far(failures)
	_test_dwell_is_hysteresis(failures)
	_test_flicker_does_not_strobe(failures)
	_test_tracking_loss(failures)
	if failures.is_empty():
		print("XR interaction arbiter: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	print("XR interaction arbiter: FAIL (%d)" % failures.size())
	quit(1)

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
