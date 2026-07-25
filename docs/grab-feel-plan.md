# Grab Feel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Grabbed objects stop yanking to the wrist — plain objects hold where grabbed, authored-grip objects tween in with perceived-distance timing — and throws land straight via a consensus velocity estimator.

**Architecture:** Approach A from docs/grab-feel-design.md: attach transit as a *phase* wrapped around the existing `_apply_movement` in `xr_grab_interactable.gd`; policy authored by XRGrabPoint presence; palm-anchored attach pose; pure static functions for everything headless-testable.

**Tech Stack:** GDScript, Godot 4.8. Test harness: SceneTree scripts run headless.

## Global Constraints

- Every Godot invocation MUST include `--headless --xr-mode off` or it hangs forever silently. Test project is the demo in the OTHER repo: `C:/Users/davta/Repos/Godot_WebXR_gh/demo` (its addons/ symlink into this working tree). Binary: `C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe`.
- MUTATION-TEST every new assertion (mutate implementation → suite FAILS → revert → PASSES). Ledger history: every task that skipped this shipped tests that could not fail.
- Licensing: implement from the design doc's published-technique descriptions ONLY. Never read ISDK source for implementation. Meta constants are sanity checks, not shipped values.
- Do not change any existing exported tuning value (`throw_velocity_scale`, `max_throw_speed`, `smoothing_speed`, ...). New exports only: `transit_speed`, `throw_deadzone_frames`, `throw_consensus_tolerance`.
- Both suites must stay green after every task: `test_hand_conditioning.gd` and `test_gesture_foundation.gd`.
- Branch: `agent/hand-conditioning` in `C:/Users/davta/Repos/godot-xr-suite` (or a new branch off it if David prefers; ask at execution start). Ledger: `.superpowers/sdd/progress.md` — append per task.

---

### Task 1: Diagnose and fix the wrist-yank (anchor + cube config)

The design requires reproducing the bad behavior in a test BEFORE fixing.
Two suspects; this task determines which (possibly both) and fixes them.

**Files:**
- Inspect: `addons/godot_xr_interaction_toolkit/samples/stations/grab_lab_station.tscn` (cube grab config)
- Modify: `addons/godot_xr_interaction_toolkit/runtime/input/xr_controller_hand_adapter.gd` (grip/attach pose anchor, ~line 281 region)
- Create: `addons/godot_xr_interaction_toolkit/tests/test_grab_feel.gd` (new suite, same SceneTree pattern as test_hand_conditioning.gd)

**Interfaces:**
- Produces: `test_grab_feel.gd` harness with `_init()` collecting failures, printing `XR grab feel: PASS/FAIL`, exit 0/1 — later tasks append to it.
- Produces: whatever anchor helper is extracted must be a STATIC function so it is testable headless, e.g. `static func resolve_grip_anchor(tracker: XRHandTracker) -> Transform3D` choosing PALM, falling back to WRIST only when palm is invalid.

- [ ] **Step 1: Audit the cube config.** `grep -nE "snap_to_attach|XRGrabPoint|attach_transform" addons/godot_xr_interaction_toolkit/samples/stations/grab_lab_station.tscn` and read the cube nodes. Record in the ledger which of the two suspects is live: (a) cubes have `snap_to_attach=true` or a grab point (object centers onto attach pose — the yank), and/or (b) free grab but the attach pose anchors at the wrist.

- [ ] **Step 2: Write the failing/reproducing tests.** Create `tests/test_grab_feel.gd`:

```gdscript
extends SceneTree

## Headless tests for grab feel (docs/grab-feel-design.md).
## Run: godot --headless --xr-mode off --path <demo> --script res://addons/godot_xr_interaction_toolkit/tests/test_grab_feel.gd

func _init() -> void:
	var failures: Array[String] = []
	_test_grip_anchor_prefers_palm(failures)
	if failures.is_empty():
		print("XR grab feel: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	print("XR grab feel: FAIL (%d)" % failures.size())
	quit(1)

func _make_tracker(palm_valid: bool) -> XRHandTracker:
	var tracker := XRHandTracker.new()
	tracker.has_tracking_data = true
	var valid := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST, Transform3D(Basis.IDENTITY, Vector3(0, 1, 0)))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_WRIST, valid)
	tracker.set_hand_joint_transform(XRHandTracker.HAND_JOINT_PALM, Transform3D(Basis.IDENTITY, Vector3(0, 1, -0.07)))
	tracker.set_hand_joint_flags(XRHandTracker.HAND_JOINT_PALM, valid if palm_valid else 0)
	return tracker

func _test_grip_anchor_prefers_palm(failures: Array[String]) -> void:
	var palm_anchor := XRControllerHandAdapter.resolve_grip_anchor(_make_tracker(true))
	if not palm_anchor.origin.is_equal_approx(Vector3(0, 1, -0.07)):
		failures.append("grip anchor must sit on the PALM when the palm is valid, got %s" % palm_anchor.origin)
	var wrist_anchor := XRControllerHandAdapter.resolve_grip_anchor(_make_tracker(false))
	if not wrist_anchor.origin.is_equal_approx(Vector3(0, 1, 0)):
		failures.append("grip anchor must fall back to the WRIST when the palm is invalid, got %s" % wrist_anchor.origin)
```

NOTE: adapt the class/callable name to reality — the adapter may not be a
`class_name`. If it is preload-only, preload it in the test:
`const XRControllerHandAdapter := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_controller_hand_adapter.gd")`.
The extracted function MUST be static.

- [ ] **Step 3: Run — expect FAIL** (function does not exist yet):
`cd C:/Users/davta/Repos/Godot_WebXR_gh/demo && <godot> --headless --xr-mode off --path . --script res://addons/godot_xr_interaction_toolkit/tests/test_grab_feel.gd`

- [ ] **Step 4: Extract + fix.** In the adapter, extract the existing grip-pose joint selection into `static func resolve_grip_anchor(tracker) -> Transform3D` implementing palm-first/wrist-fallback, and route the existing call site through it. While in there, verify the existing call site actually honored palm-first — if it silently always used the wrist (the suspected yank), the extraction fixes it; record which in the ledger.

- [ ] **Step 5: Run — expect PASS.** Then mutate (swap palm/wrist preference) — expect FAIL — revert — PASS.

- [ ] **Step 6: If Step 1 found cube misconfig:** remove `snap_to_attach`/grab-point from the grab-lab cubes so they free-grab (hold-where-grabbed already works for free grabs). This is a sample-scene change, no test; note it in the commit body.

- [ ] **Step 7: Both suites + new suite green. Commit** `fix: grab anchors on the palm; grab-lab cubes free-grab`.

---

### Task 2: Throw consensus estimator (pure function + tests)

**Files:**
- Modify: `addons/godot_xr_interaction_toolkit/runtime/xr_grab_interactable.gd` (add statics + exports; replace `_average_throw_samples` call for the LINEAR estimate in `_apply_throw_on_release`; angular path gets dead-zone only)
- Test: `addons/godot_xr_interaction_toolkit/tests/test_grab_feel.gd`

**Interfaces:**
- Produces: `static func throw_consensus(samples: Array[Vector3], deadzone_frames: int, tolerance: float) -> Vector3` on XRGrabInteractable. Returns Vector3.ZERO for empty input. Falls back to plain mean when fewer than 4 samples remain after the dead-zone.
- Produces: exports `@export_range(0, 5, 1) var throw_deadzone_frames := 2` and `@export_range(0.05, 2.0, 0.05) var throw_consensus_tolerance := 0.35` (defaults conservative; earn-in tunes). `throw_sample_frames` default changes 5 → 10 — this is a buffer SIZE, not a tuned feel value; record in ledger.

- [ ] **Step 1: Write failing tests** (append to test_grab_feel.gd, register in `_init`):

```gdscript
func _test_throw_consensus(failures: Array[String]) -> void:
	# A clean constant-velocity throw: consensus == the velocity.
	var clean: Array[Vector3] = []
	for i in range(10):
		clean.append(Vector3(2, 1, 0))
	var v := XRGrabInteractable.throw_consensus(clean, 2, 0.35)
	if not v.is_equal_approx(Vector3(2, 1, 0)):
		failures.append("clean throw: expected (2,1,0), got %s" % v)

	# Release corruption: last 2 samples wildly wrong (fingers peeling off).
	# The old mean is dragged sideways; consensus must not be.
	var corrupted: Array[Vector3] = []
	for i in range(8):
		corrupted.append(Vector3(2, 1, 0) + Vector3(randf(), randf(), randf()) * 0.0)  # deterministic: exact
	corrupted.append(Vector3(-6, 0, 4))
	corrupted.append(Vector3(0, -9, 2))
	var cv := XRGrabInteractable.throw_consensus(corrupted, 2, 0.35)
	if cv.distance_to(Vector3(2, 1, 0)) > 0.05:
		failures.append("corrupted tail leaked into the estimate: %s" % cv)

	# Mid-buffer outlier (tracking glitch): consensus rejects it, mean cannot.
	var glitched: Array[Vector3] = []
	for i in range(9):
		glitched.append(Vector3(0, 0, -3))
	glitched.insert(4, Vector3(8, 8, 8))
	# dead-zone removes the newest 2 REAL samples; glitch is mid-buffer and must
	# be rejected by consensus, not the dead-zone.
	var gv := XRGrabInteractable.throw_consensus(glitched, 2, 0.35)
	if gv.distance_to(Vector3(0, 0, -3)) > 0.05:
		failures.append("mid-buffer glitch leaked into the estimate: %s" % gv)

	# Degenerate: fewer than 4 usable -> plain mean fallback (documented).
	var short: Array[Vector3] = [Vector3.ONE, Vector3.ONE, Vector3.ONE]
	var sv := XRGrabInteractable.throw_consensus(short, 2, 0.35)
	if not sv.is_equal_approx(Vector3.ONE):
		failures.append("short-buffer fallback broke: %s" % sv)
	if XRGrabInteractable.throw_consensus([], 2, 0.35) != Vector3.ZERO:
		failures.append("empty input must return ZERO")
```

- [ ] **Step 2: Run — expect FAIL** (no such static).

- [ ] **Step 3: Implement** on XRGrabInteractable:

```gdscript
## Consensus throw-velocity estimate (technique: Meta ISDK release filtering,
## as publicly described; implementation ours - see docs/grab-feel-design.md).
## Drops the newest deadzone_frames samples (release corruption), then returns
## the mean of the largest set of mutually agreeing samples. Two samples agree
## when their difference is under tolerance * median sample magnitude. Ties go
## to the more recent set. Fewer than 4 usable samples: plain mean of them.
static func throw_consensus(samples: Array[Vector3], deadzone_frames: int, tolerance: float) -> Vector3:
	if samples.is_empty():
		return Vector3.ZERO
	var usable := samples.slice(0, maxi(0, samples.size() - deadzone_frames))
	if usable.is_empty():
		usable = samples.duplicate()
	if usable.size() < 4:
		return _mean_of(usable)

	var magnitudes: Array[float] = []
	for sample in usable:
		magnitudes.append(sample.length())
	magnitudes.sort()
	var median: float = magnitudes[magnitudes.size() / 2]
	var limit := maxf(tolerance * median, 0.0001)

	var best_set: Array[Vector3] = []
	var best_anchor := -1
	for anchor_index in range(usable.size()):
		var agreeing: Array[Vector3] = []
		for sample in usable:
			if sample.distance_to(usable[anchor_index]) <= limit:
				agreeing.append(sample)
		if agreeing.size() > best_set.size() or (agreeing.size() == best_set.size() and anchor_index > best_anchor):
			best_set = agreeing
			best_anchor = anchor_index
	return _mean_of(best_set)

static func _mean_of(samples: Array[Vector3]) -> Vector3:
	if samples.is_empty():
		return Vector3.ZERO
	var total := Vector3.ZERO
	for sample in samples:
		total += sample
	return total / float(samples.size())
```

Wire it: in `_apply_throw_on_release`, the linear velocity becomes
`throw_consensus(_throw_linear_samples, throw_deadzone_frames, throw_consensus_tolerance)`;
the angular estimate stays `_average_throw_samples` but over
`_throw_angular_samples.slice(0, maxi(0, size - throw_deadzone_frames))`.
Change `throw_sample_frames` default 5 → 10. Add the two new exports to the
Throw group.

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Mutations, each FAIL-then-PASS:** (a) remove dead-zone (`deadzone_frames` ignored) → corrupted-tail test fails; (b) consensus returns `_mean_of(usable)` → mid-buffer glitch test fails; (c) drop the <4 fallback (return ZERO) → short-buffer test fails.

- [ ] **Step 6: Suites green. Commit** `feat: consensus throw velocity with release dead-zone`.

---

### Task 3: Transit timing + interpolation (pure functions + tests)

**Files:**
- Modify: `addons/godot_xr_interaction_toolkit/runtime/xr_grab_interactable.gd`
- Test: `addons/godot_xr_interaction_toolkit/tests/test_grab_feel.gd`

**Interfaces:**
- Produces: `static func transit_duration(from: Transform3D, to: Transform3D, speed: float) -> float` — perceived distance `maxf(translation_m, rotation_deg * 0.5 / 360.0)` divided by `speed`; 0.0 when speed <= 0 or distance ~0.
- Produces: `static func transit_blend(from: Transform3D, to: Transform3D, alpha: float) -> Transform3D` — origin lerp + basis slerp (orthonormalized quaternions), alpha clamped 0..1.
- Produces: export `@export_range(0.1, 10.0, 0.1) var transit_speed := 1.5` (metres of perceived distance per second; conservative default, earn-in tunes).

- [ ] **Step 1: Failing tests** (append + register):

```gdscript
func _test_transit_timing(failures: Array[String]) -> void:
	var origin := Transform3D.IDENTITY
	# 0.3 m translation, no rotation, speed 1.5 -> 0.2 s.
	var moved := Transform3D(Basis.IDENTITY, Vector3(0.3, 0, 0))
	if not is_equal_approx(XRGrabInteractable.transit_duration(origin, moved, 1.5), 0.2):
		failures.append("translation-dominant duration wrong")
	# 180 deg rotation, no translation: perceived 180*0.5/360 = 0.25 m -> 1/6 s.
	var flipped := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	if not is_equal_approx(XRGrabInteractable.transit_duration(origin, flipped, 1.5), 0.25 / 1.5):
		failures.append("rotation-dominant duration wrong")
	# Rotation must be able to DOMINATE a small translation (the ISDK point).
	var both := Transform3D(Basis(Vector3.UP, PI), Vector3(0.05, 0, 0))
	if not is_equal_approx(XRGrabInteractable.transit_duration(origin, both, 1.5), 0.25 / 1.5):
		failures.append("rotation must dominate when perceived-larger")
	if XRGrabInteractable.transit_duration(origin, moved, 0.0) != 0.0:
		failures.append("zero speed must yield zero duration (transit skipped)")

func _test_transit_blend(failures: Array[String]) -> void:
	var from := Transform3D(Basis.IDENTITY, Vector3.ZERO)
	var to := Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(1, 0, 0))
	var mid := XRGrabInteractable.transit_blend(from, to, 0.5)
	if not mid.origin.is_equal_approx(Vector3(0.5, 0, 0)):
		failures.append("blend origin at 0.5 wrong: %s" % mid.origin)
	var mid_angle := mid.basis.get_rotation_quaternion().angle_to(from.basis.get_rotation_quaternion())
	if absf(mid_angle - PI * 0.25) > 0.01:
		failures.append("blend rotation at 0.5 wrong: %f rad" % mid_angle)
	if not XRGrabInteractable.transit_blend(from, to, 1.5).origin.is_equal_approx(to.origin):
		failures.append("alpha must clamp at 1")
```

- [ ] **Step 2: Run — FAIL. Step 3: Implement:**

```gdscript
## Perceived-distance transit timing (technique: ISDK tweened grab movement,
## publicly described; implementation ours). A 180-degree flip counts as
## 0.25 m so rotation-dominant attaches do not pop.
static func transit_duration(from: Transform3D, to: Transform3D, speed: float) -> float:
	if speed <= 0.0:
		return 0.0
	var translation := (to.origin - from.origin).length()
	var rotation_deg := rad_to_deg(from.basis.get_rotation_quaternion().angle_to(to.basis.get_rotation_quaternion()))
	var perceived := maxf(translation, rotation_deg * 0.5 / 360.0)
	if perceived < 0.0005:
		return 0.0
	return perceived / speed

static func transit_blend(from: Transform3D, to: Transform3D, alpha: float) -> Transform3D:
	var t := clampf(alpha, 0.0, 1.0)
	var from_rotation := from.basis.orthonormalized().get_rotation_quaternion()
	var to_rotation := to.basis.orthonormalized().get_rotation_quaternion()
	return Transform3D(Basis(from_rotation.slerp(to_rotation, t)), from.origin.lerp(to.origin, t))
```

- [ ] **Step 4: PASS. Step 5: Mutations:** (a) drop the `maxf` (translation only) → rotation-dominant test fails; (b) unclamped alpha → clamp test fails. **Step 6: Suites green. Commit** `feat: transit timing and blend math`.

---

### Task 4: Wire the transit phase into the grab lifecycle

**Files:**
- Modify: `addons/godot_xr_interaction_toolkit/runtime/xr_grab_interactable.gd` (`_notify_select_entered`, `_physics_process`)
- Test: `addons/godot_xr_interaction_toolkit/tests/test_grab_feel.gd`

**Interfaces:**
- Consumes: `transit_duration`, `transit_blend` (Task 3).
- Produces: instance state `_transit_time_left: float`, `_transit_duration: float`, `_transit_from: Transform3D` (captured in WORLD space at grab). Method `func in_transit() -> bool` (observability + tests). Transit only arms for point grabs / snap_to_attach (`_point_grab or snap-derived offsets`); free grabs never transit (hold-where-grabbed).

- [ ] **Step 1: Failing test — transit converges onto a MOVING live target and free grabs skip transit entirely.** (This encodes the Task-9 lesson: static fixtures cannot expose feed-forward/handoff bugs.) Drive `_physics_process` directly with a stub interactor:

```gdscript
class StubInteractor:
	extends Node
	var pose := Transform3D.IDENTITY
	func get_attach_pose() -> Transform3D:
		return pose

func _test_transit_phase(failures: Array[String]) -> void:
	var grab := XRGrabInteractable.new()
	var body := Node3D.new()
	grab.add_child(body)
	get_root().add_child(grab)
	grab.target_path = grab.get_path_to(body)
	grab.snap_to_attach = true      # authored-grip style: transit arms
	grab.track_rotation = true
	grab.transit_speed = 1.5
	var interactor := StubInteractor.new()
	get_root().add_child(interactor)
	interactor.pose = Transform3D(Basis.IDENTITY, Vector3(0.3, 1.0, 0.0))
	body.global_position = Vector3.ZERO  # 0.3+ m from grip -> real transit

	grab._notify_select_entered(interactor)
	if not grab.in_transit():
		failures.append("snap grab 0.3 m away must enter transit")
	# Simulate 60 physics frames while the HAND MOVES; transit target is live.
	for frame in range(60):
		interactor.pose.origin += Vector3(0.0, 0.0, -0.004)
		grab._physics_process(1.0 / 60.0)
	if grab.in_transit():
		failures.append("transit must have ended (duration ~0.2 s < 1 s simulated)")
	if not body.global_position.is_equal_approx(interactor.pose.origin):
		failures.append("after transit the object must sit exactly on the LIVE attach pose, got %s vs %s" % [body.global_position, interactor.pose.origin])

	# Free grab (no snap, no grab point): NEVER transits, offset exact.
	var free := XRGrabInteractable.new()
	var free_body := Node3D.new()
	free.add_child(free_body)
	get_root().add_child(free)
	free.target_path = free.get_path_to(free_body)
	free_body.global_position = Vector3(0.05, 0.9, -0.1)
	var free_interactor := StubInteractor.new()
	get_root().add_child(free_interactor)
	free_interactor.pose = Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))
	var relative := free_body.global_position - free_interactor.pose.origin
	free._notify_select_entered(free_interactor)
	if free.in_transit():
		failures.append("free grab must not transit")
	free_interactor.pose.origin += Vector3(0.2, 0.1, 0.0)
	free._physics_process(1.0 / 60.0)
	var new_relative := free_body.global_position - free_interactor.pose.origin
	if not new_relative.is_equal_approx(relative):
		failures.append("hold-where-grabbed offset drifted: %s -> %s" % [relative, new_relative])
	grab.queue_free(); interactor.queue_free(); free.queue_free(); free_interactor.queue_free()
```

NOTE: `_notify_select_entered` calls `_set_body_frozen` / signals — if any of
that needs a scene tree the stubs don't provide, extend the stubs, do NOT
weaken the assertions.

- [ ] **Step 2: Run — FAIL** (`in_transit` undefined). **Step 3: Implement.** In `_notify_select_entered` (first-grabber branch), after `_grab_offset` is computed:

```gdscript
		_transit_duration = 0.0
		_transit_time_left = 0.0
		if _point_grab or (snap_to_attach and _grab_points.is_empty()):
			var target_node := get_target()
			if target_node != null:
				var desired := _attach_pose_for(interactor) * _grab_offset
				_transit_from = target_node.global_transform
				_transit_duration = transit_duration(_transit_from, desired, transit_speed)
				_transit_time_left = _transit_duration
```

In `_physics_process` single-hand path, replace the desired/apply pair with:

```gdscript
	var attach_pose := _attach_pose_for(_grabbing)
	var desired: Transform3D = attach_pose * _grab_offset
	var follow_rotation := track_rotation or _point_grab
	if _transit_time_left > 0.0:
		_transit_time_left = maxf(0.0, _transit_time_left - delta)
		var alpha := 1.0 - (_transit_time_left / _transit_duration)
		var blended := transit_blend(_transit_from, desired, alpha)
		target.global_transform = blended
	else:
		_apply_movement(target, desired, delta, follow_rotation, track_position or _point_grab)
	if not follow_rotation:
		attach_pose.basis = _last_throw_pose.basis
	_sample_throw_velocity(attach_pose, delta)
```

And `func in_transit() -> bool: return _transit_time_left > 0.0`. Clear
transit state in `_notify_select_exited` when grabbers empty and on
two-hand begin.

- [ ] **Step 4: PASS. Step 5: Mutations:** (a) blend toward the CAPTURED grip pose instead of the live `desired` → moving-target assertion fails; (b) transit arms for free grabs too → free-grab test fails; (c) transit never ends (`_transit_time_left` not decremented) → convergence test fails. **Step 6: Both suites + demo boot (`--quit-after 120`, no SCRIPT ERROR). Commit** `feat: attach transit phase — authored grips tween, free grabs hold`.

---

### Task 5: Prefab audit + full verification

**Files:**
- Inspect every shipped grabbable prefab: `grabbable.tscn`, `throwable.tscn`, `coffee_cup.tscn`, `pen.tscn`, `spray_can.tscn`, `blaster.tscn`, plus station scenes using them.
- Modify: only prefabs whose policy is wrong per the design table (tools tween — need XRGrabPoint or snap_to_attach; plain objects hold — need neither).

- [ ] **Step 1:** For each prefab record: has XRGrabPoint? snap_to_attach? → resulting policy. Fix mismatches (expected: cubes/throwable free; blaster/pen/spray authored).
- [ ] **Step 2:** Full run: grab-feel suite, both existing suites, demo headless boot — all green, zero SCRIPT ERROR.
- [ ] **Step 3:** Ledger: task statuses, the Step-1 audit table, tuned-value note (`throw_sample_frames` 5→10 rationale). Commit `chore: prefab grab-policy audit + ledger`.

---

### Task 6: On-device earn-in (DAVID IN HEADSET — gate)

No code. Launch `res://scenes/feel_check.tscn` over Quest Link (stock binary
`C:/Users/davta/Documents/Godot R&D/_tools/Godot-4.8-dev2/Godot_v4.8-dev2_win64_console.exe`;
`xr/shaders/enabled=true` already set; retry-launcher pattern in the session
scratchpad, or plain launch).

Checklist: cubes never relocate in the hand; blaster/pen settle smoothly, no
yank, transit speed feels right (tune `transit_speed` live if not); throws at
three speeds land straight (tune `throw_consensus_tolerance` /
`throw_deadzone_frames` if not); two-hand grab unaffected; nothing feels
worse. Record verdict + any tuned values in the ledger and
docs/hand-conditioning-results.md gets a sibling section or new results doc.
NOT DONE until David signs off.
