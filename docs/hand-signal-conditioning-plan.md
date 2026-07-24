# Hand Signal Conditioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Insert an adaptive filtering and tracking-loss-recovery layer between raw `XRHandTracker` joints and every consumer, delivered through one shared accessor.

**Architecture:** Conditioning decorates the existing `XRHandPoseSource` acquisition seam, producing a conditioned `XRHandFrame`. That frame is published into a shadow `XRHandTracker` per hand, so the thirteen files that read `XRHandTracker` receive conditioned data without being rewritten. The acquisition layer moves down into `godot_xr_interaction_toolkit` so the addon dependency DAG stays one-way.

**Tech Stack:** Godot 4.8, GDScript only. No GDExtension, no new addon.

**Spec:** `docs/hand-signal-conditioning-design.md`. Read it before starting.

## Global Constraints

- **Branch:** `agent/hand-conditioning` in `godot-xr-suite`. All commits land there.
- **Godot binary:** `C:\Users\davta\Documents\Godot_WebGPU\bin\godot.windows.editor.x86_64.console.exe` (fallback: `C:\Users\davta\Documents\Godot R&D\_tools\Godot-4.8-dev2\Godot_v4.8-dev2_win64_console.exe`).
- **Tests run from the DEMO project**, not the suite — `godot-xr-suite` has no `project.godot`. Project path is `C:\Users\davta\Repos\Godot_WebXR_gh\demo`, whose `addons/` are symlinks into the suite working tree. Editing the suite changes what the demo runs.
- **Test pattern:** `extends SceneTree`, a `_init()` that appends to `var failures: Array[String]`, prints `PASS`/`FAIL (n)`, and calls `quit(0)` or `quit(1)`. Follow `addons/godot_xr_hands/tests/test_gesture_foundation.gd` exactly.
- **Test command shape:**
  `<godot> --headless --xr-mode off --path C:/Users/davta/Repos/Godot_WebXR_gh/demo --script res://addons/<path>/tests/<file>.gd`
- **`--xr-mode off` is mandatory and verified.** Without it the process hangs indefinitely and prints nothing: the demo project enables OpenXR, and headless initialisation blocks with no runtime present. This is not a slow test — it never returns. A bare project without OpenXR runs the identical script instantly, which is how the cause was isolated. If a test appears to hang, check this flag first.
- **First run after adding files** performs an import pass and can take several minutes; subsequent runs are seconds. Never run two Godot instances against the demo project at once — they contend and both stall. If that happens: `taskkill //F //IM godot.windows.editor.x86_64.console.exe`.
- **Verified baseline:** `test_gesture_foundation.gd` prints `XR gesture foundation: PASS` and exits 0 under the command above. If it does not before you change anything, stop and report.
- **No ISDK code.** Meta's Interaction SDK is under the Oculus SDK License and is incompatible. Implement from published literature. The One Euro filter is Casiez, Roussel & Vogel, *1€ Filter*, CHI 2012.
- **DAG rule:** `godot_xr_interaction_toolkit` must keep `requires=PackedStringArray()` in its `xr_package.cfg` and must never `preload` from `godot_xr_hands` or `godot_webxr_kit`. Cross-addon access uses group lookup with a graceful fallback.
- **Break and fix forward.** Conditioning is on by default. No compatibility shims.
- **Indentation is mixed across this repo and GDScript will not tolerate mixing *within* a file.** The toolkit's own files use TABS (`xr_grab_interactable.gd`, `xr_poke_interactor.gd`); the acquisition files moved in from `godot_xr_hands` use 4 SPACES (`xr_hand_frame.gd`, `xr_hand_pose_source.gd`, `xr_tracker_hand_pose_source.gd`). There is no `.editorconfig`. **Rule: new files use tabs; when appending to an existing file, match that file's existing indentation.** The code blocks in this plan are tab-indented — convert them when appending to a space-indented file.
- **Do not "optimize" typed arrays into stride-N `PackedFloat32Array`.** In GDScript, the cost that matters is the number of GDScript-level operations, not the work each one does in C++. One `Array[Quaternion]` index read beats four `PackedFloat32Array` reads plus a constructor. `PackedVector3Array` is correct for vectors because it is a single read.

---

### Task 1: Move the acquisition layer into the toolkit

Prerequisite for everything else. Mechanical, and independently verifiable: the existing test suite must still pass afterwards.

Rationale is in the spec's *Preserving the dependency DAG* section — conditioning must live at or below the resolver, and the resolver cannot move up without inverting the DAG.

**Files:**
- Move: `addons/godot_xr_hands/runtime/data/xr_hand_frame.gd` (+ `.uid`) → `addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_frame.gd`
- Move: `addons/godot_xr_hands/runtime/input/xr_hand_pose_source.gd` (+ `.uid`) → `addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_pose_source.gd`
- Move: `addons/godot_xr_hands/runtime/input/xr_tracker_hand_pose_source.gd` (+ `.uid`) → `addons/godot_xr_interaction_toolkit/runtime/input/xr_tracker_hand_pose_source.gd`
- Modify: `addons/godot_xr_interaction_toolkit/runtime/input/xr_tracker_hand_pose_source.gd` (resolver preload becomes same-directory)

**Interfaces:**
- Consumes: nothing.
- Produces: `XRHandFrame`, `XRHandPoseSource`, `XRTrackerHandPoseSource` as globally-registered `class_name`s resolvable from the toolkit. Public API unchanged: `XRHandFrame.JOINT_COUNT`, `.begin_capture(hand, timestamp_usec, sequence)`, `.set_joint(joint, transform, radius, flags)`, `.has_joint(joint)`, `.joint_position(joint)`, `.joint_transforms`, `.joint_flags`, `.joint_radii`, `.tracking_valid`, `.valid_joint_count`, `.timestamp_usec`, `.hand`, `.sequence`, `.clear()`; `XRHandPoseSource.capture(hand, timestamp_usec, target) -> bool`.

- [ ] **Step 1: Record the baseline — the existing tests must pass BEFORE the move**

```bash
cd "C:/Users/davta/Repos/Godot_WebXR_gh/demo"
"C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe" \
  --headless --xr-mode off --path . \
  --script res://addons/godot_xr_hands/tests/test_gesture_foundation.gd
```

Expected: `XR gesture foundation: PASS`, exit 0. If this fails before you change anything, stop and report — do not proceed.

- [ ] **Step 2: Move the three files with git mv (preserves history)**

```bash
cd "C:/Users/davta/Repos/godot-xr-suite"
T=addons/godot_xr_interaction_toolkit/runtime/input
git mv addons/godot_xr_hands/runtime/data/xr_hand_frame.gd            $T/xr_hand_frame.gd
git mv addons/godot_xr_hands/runtime/data/xr_hand_frame.gd.uid        $T/xr_hand_frame.gd.uid
git mv addons/godot_xr_hands/runtime/input/xr_hand_pose_source.gd     $T/xr_hand_pose_source.gd
git mv addons/godot_xr_hands/runtime/input/xr_hand_pose_source.gd.uid $T/xr_hand_pose_source.gd.uid
git mv addons/godot_xr_hands/runtime/input/xr_tracker_hand_pose_source.gd     $T/xr_tracker_hand_pose_source.gd
git mv addons/godot_xr_hands/runtime/input/xr_tracker_hand_pose_source.gd.uid $T/xr_tracker_hand_pose_source.gd.uid
rmdir addons/godot_xr_hands/runtime/data 2>/dev/null || true
```

- [ ] **Step 3: Confirm the preload path still resolves, and add the discontinuity hook**

`xr_tracker_hand_pose_source.gd` preloads the resolver by absolute `res://` path, which Godot resolves regardless of where the preloading file lives — so the move does not break it. Confirm it reads exactly:

```gdscript
const XRHandTrackerResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")
```

Then add a no-op discontinuity hook to the base class, so decorators further down the chain can signal a tracking discontinuity without any decorator needing to know the concrete type of the one below it.

In `addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_pose_source.gd`, append:

```gdscript
## True exactly once after a tracking discontinuity (first acquisition, or
## recovery from a dropout). Decorators above reset their state on it rather
## than slewing from a stale pose. Sources with no notion of continuity return
## false forever, which is the correct default.
func consume_discontinuity(_hand: int) -> bool:
	return false
```

Then add the frame copy to `XRHandFrame` itself. Every decorator in the chain needs to copy a frame, and copying a frame is the frame's own business — defining it once here keeps the decorators free of a duplicated block.

In `addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_frame.gd`, append:

```gdscript
## Copies this frame's full contents into another frame.
func copy_into(target: XRHandFrame) -> void:
	target.begin_capture(hand, timestamp_usec, sequence)
	for joint in range(JOINT_COUNT):
		target.set_joint(joint, joint_transforms[joint], joint_radii[joint], joint_flags[joint])
	target.tracking_valid = tracking_valid
```

- [ ] **Step 4: Find any other path-based references to the moved files**

```bash
cd "C:/Users/davta/Repos/godot-xr-suite"
grep -rn "godot_xr_hands/runtime/data\|godot_xr_hands/runtime/input/xr_hand_pose_source\|godot_xr_hands/runtime/input/xr_tracker_hand_pose_source" --include=*.gd --include=*.tscn --include=*.cfg --include=*.md .
```

Expected: only `README.md` hits. Update the tree diagram in `addons/godot_xr_hands/README.md` (lines listing `data/xr_hand_frame.gd` and `input/`) to reflect that acquisition now lives in the toolkit. Any `.gd` or `.tscn` hit is a real break — fix the path.

- [ ] **Step 5: Re-run the existing tests**

```bash
cd "C:/Users/davta/Repos/Godot_WebXR_gh/demo"
"C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe" \
  --headless --xr-mode off --path . \
  --script res://addons/godot_xr_hands/tests/test_gesture_foundation.gd
```

Expected: `XR gesture foundation: PASS`, exit 0. Class names are globally registered, so the move should be transparent.

If you get `hides a global script class` or an unresolved-class error, the `.godot` class cache is stale. Rescan once and retry:

```bash
"C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe" --editor --headless --xr-mode off --path . --quit
```

- [ ] **Step 6: Verify the DAG is intact**

```bash
cd "C:/Users/davta/Repos/godot-xr-suite"
grep -rn "godot_xr_hands\|godot_webxr_kit" addons/godot_xr_interaction_toolkit/runtime/ --include=*.gd
```

Expected: **zero output**. Any runtime `preload` from the toolkit into a higher addon breaks standalone install.

- [ ] **Step 7: Commit**

```bash
cd "C:/Users/davta/Repos/godot-xr-suite"
git add -A
git commit -m "refactor: move the hand acquisition layer into the toolkit

XRHandFrame, XRHandPoseSource and XRTrackerHandPoseSource move from
godot_xr_hands into godot_xr_interaction_toolkit, joining the resolver.

Conditioning must sit at or below the resolver, and the resolver cannot move
up without making the foundation addon depend on a capability addon. Moving
the acquisition layer down keeps xr.interaction's requires=[] true and the
toolkit standalone-installable.

All three declare class_name, so references by class name are unaffected."
```

---

### Task 2: Joint hierarchy

**Files:**
- Create: `addons/godot_xr_interaction_toolkit/runtime/input/filter/xr_hand_joint_hierarchy.gd`
- Create: `addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd`

**Interfaces:**
- Consumes: nothing.
- Produces: `XRHandJointHierarchy.PARENT: PackedInt32Array` (26 entries, `WRIST` maps to `-1`); `XRHandJointHierarchy.IS_TIP: PackedByteArray` (26 entries, `1` for the 5 fingertips); `XRHandJointHierarchy.ORDER: PackedInt32Array` (26 joint ids, parents always before children).

- [ ] **Step 1: Write the failing test**

Create `addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd`:

```gdscript
extends SceneTree

## Headless tests for the hand conditioning layer.
## Run: godot --headless --path <demo> --script res://addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd

func _init() -> void:
	var failures: Array[String] = []
	_test_joint_hierarchy(failures)
	if failures.is_empty():
		print("XR hand conditioning: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	print("XR hand conditioning: FAIL (%d)" % failures.size())
	quit(1)

func _test_joint_hierarchy(failures: Array[String]) -> void:
	var parent := XRHandJointHierarchy.PARENT
	if parent.size() != XRHandTracker.HAND_JOINT_MAX:
		failures.append("hierarchy covers %d joints, expected %d" % [parent.size(), XRHandTracker.HAND_JOINT_MAX])
		return

	if parent[XRHandTracker.HAND_JOINT_WRIST] != -1:
		failures.append("wrist must be the root")

	# Every joint reaches the wrist without cycling.
	for joint in range(XRHandTracker.HAND_JOINT_MAX):
		var cursor := joint
		var hops := 0
		while cursor != -1 and hops <= XRHandTracker.HAND_JOINT_MAX:
			cursor = parent[cursor]
			hops += 1
		if cursor != -1:
			failures.append("joint %d never reaches the root (cycle or orphan)" % joint)

	# Spot-check chain structure.
	if parent[XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL] != XRHandTracker.HAND_JOINT_WRIST:
		failures.append("index metacarpal must parent to the wrist")
	if parent[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP] != XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL:
		failures.append("index tip must parent to the index distal phalanx")
	if parent[XRHandTracker.HAND_JOINT_PALM] != XRHandTracker.HAND_JOINT_WRIST:
		failures.append("palm must parent to the wrist")

	# Tips: exactly five, and none is any joint's parent.
	var tip_count := 0
	for joint in range(XRHandTracker.HAND_JOINT_MAX):
		if XRHandJointHierarchy.IS_TIP[joint] == 1:
			tip_count += 1
			if parent.has(joint):
				failures.append("joint %d is marked a tip but has children" % joint)
	if tip_count != 5:
		failures.append("expected 5 fingertips, found %d" % tip_count)

	# ORDER must list every parent before its children.
	var seen := {}
	for joint in XRHandJointHierarchy.ORDER:
		var p: int = parent[joint]
		if p != -1 and not seen.has(p):
			failures.append("ORDER lists joint %d before its parent %d" % [joint, p])
		seen[joint] = true
	if seen.size() != XRHandTracker.HAND_JOINT_MAX:
		failures.append("ORDER covers %d joints, expected %d" % [seen.size(), XRHandTracker.HAND_JOINT_MAX])
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd "C:/Users/davta/Repos/Godot_WebXR_gh/demo"
"C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe" \
  --headless --xr-mode off --path . \
  --script res://addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd
```

Expected: FAIL — parse error, `Identifier "XRHandJointHierarchy" not declared`.

- [ ] **Step 3: Implement the hierarchy**

Create `addons/godot_xr_interaction_toolkit/runtime/input/filter/xr_hand_joint_hierarchy.gd`:

```gdscript
class_name XRHandJointHierarchy
extends RefCounted

## Skeleton topology for Godot's 26 XRHandTracker joints.
##
## XRHandTracker reports every joint in one common space, not hierarchically.
## Conditioning needs parent-local rotations (so filtering can never change a
## bone length), which requires knowing who parents whom.

const _WRIST := XRHandTracker.HAND_JOINT_WRIST

## Finger chains, root-first. Matches the chains declared in xr_simulator.gd.
const CHAINS := [
	[XRHandTracker.HAND_JOINT_THUMB_METACARPAL, XRHandTracker.HAND_JOINT_THUMB_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_THUMB_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_THUMB_TIP],
	[XRHandTracker.HAND_JOINT_INDEX_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP],
	[XRHandTracker.HAND_JOINT_MIDDLE_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_MIDDLE_FINGER_TIP],
	[XRHandTracker.HAND_JOINT_RING_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_RING_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_RING_FINGER_TIP],
	[XRHandTracker.HAND_JOINT_PINKY_FINGER_METACARPAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_INTERMEDIATE, XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_DISTAL, XRHandTracker.HAND_JOINT_PINKY_FINGER_TIP],
]

## PARENT[joint] = parent joint id, or -1 for the wrist (the root).
static var PARENT: PackedInt32Array = _build_parents()
## IS_TIP[joint] = 1 for the five fingertips (leaf joints), else 0.
static var IS_TIP: PackedByteArray = _build_tips()
## Traversal order guaranteeing every parent precedes its children.
static var ORDER: PackedInt32Array = _build_order()

static func _build_parents() -> PackedInt32Array:
	var parents := PackedInt32Array()
	parents.resize(XRHandTracker.HAND_JOINT_MAX)
	parents.fill(_WRIST)
	parents[_WRIST] = -1
	parents[XRHandTracker.HAND_JOINT_PALM] = _WRIST
	for chain in CHAINS:
		# chain[0] is a metacarpal and keeps the default wrist parent.
		for index in range(1, chain.size()):
			parents[chain[index]] = chain[index - 1]
	return parents

static func _build_tips() -> PackedByteArray:
	var tips := PackedByteArray()
	tips.resize(XRHandTracker.HAND_JOINT_MAX)
	tips.fill(0)
	for chain in CHAINS:
		tips[chain[chain.size() - 1]] = 1
	return tips

static func _build_order() -> PackedInt32Array:
	var order := PackedInt32Array()
	order.append(_WRIST)
	order.append(XRHandTracker.HAND_JOINT_PALM)
	for chain in CHAINS:
		for joint in chain:
			order.append(joint)
	return order
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd "C:/Users/davta/Repos/Godot_WebXR_gh/demo"
"C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe" \
  --headless --xr-mode off --path . \
  --script res://addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd
```

Expected: `XR hand conditioning: PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
cd "C:/Users/davta/Repos/godot-xr-suite"
git add addons/godot_xr_interaction_toolkit/runtime/input/filter/ addons/godot_xr_interaction_toolkit/tests/
git commit -m "feat: add the hand joint hierarchy

Parent map, fingertip set, and a parent-before-child traversal order for
Godot's 26 XRHandTracker joints. XRHandTracker reports joints in one common
space rather than hierarchically, so parent-local conditioning needs this."
```

---

### Task 3: One Euro filter

The core algorithm. Vectorized and bank-allocated per the spec's Performance section.

**Files:**
- Create: `addons/godot_xr_interaction_toolkit/runtime/input/filter/xr_one_euro_filter.gd`
- Create: `addons/godot_xr_interaction_toolkit/runtime/input/filter/xr_one_euro_rotation_filter.gd`
- Modify: `addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `XROneEuroFilter.alpha(cutoff: float, dt: float) -> float` (static)
  - `XROneEuroFilter.new()`, properties `min_cutoff: float`, `beta: float`, `d_cutoff: float`
  - `XROneEuroFilter.resize(channel_count: int) -> void`
  - `XROneEuroFilter.reset_channel(channel: int) -> void`, `XROneEuroFilter.reset_all() -> void`
  - `XROneEuroFilter.filter(channel: int, value: Vector3, dt: float) -> Vector3`
  - `XROneEuroRotationFilter` with the same `resize` / `reset_channel` / `reset_all` and `filter(channel: int, value: Quaternion, dt: float) -> Quaternion`

- [ ] **Step 1: Write the failing tests**

Add to `addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd` — register the call in `_init` (after `_test_joint_hierarchy(failures)`):

```gdscript
	_test_one_euro_alpha(failures)
	_test_one_euro_behaviour(failures)
	_test_one_euro_robustness(failures)
	_test_rotation_filter(failures)
```

and append these functions:

```gdscript
func _test_one_euro_alpha(failures: Array[String]) -> void:
	# alpha = 1 / (1 + tau/dt), tau = 1/(2*pi*cutoff).
	# At cutoff = 1/(2*pi) Hz, tau = 1s; with dt = 1s, alpha = 0.5.
	var a := XROneEuroFilter.alpha(1.0 / TAU, 1.0)
	if not is_equal_approx(a, 0.5):
		failures.append("alpha(1/TAU, 1) = %.6f, expected 0.5" % a)
	# Higher cutoff => less smoothing => alpha closer to 1.
	if not (XROneEuroFilter.alpha(10.0, 0.01) > XROneEuroFilter.alpha(1.0, 0.01)):
		failures.append("alpha must increase with cutoff")

func _test_one_euro_behaviour(failures: Array[String]) -> void:
	var dt := 1.0 / 72.0

	# 1. First sample passes through untouched (seeding, not filtering).
	var seed_filter := XROneEuroFilter.new()
	seed_filter.resize(1)
	var first := seed_filter.filter(0, Vector3(1, 2, 3), dt)
	if not first.is_equal_approx(Vector3(1, 2, 3)):
		failures.append("first sample must seed, not filter: %s" % str(first))

	# 2. Noise on a stationary signal is attenuated.
	var still := XROneEuroFilter.new()
	still.resize(1)
	still.min_cutoff = 1.0
	still.beta = 0.0
	var noise := [0.01, -0.012, 0.008, -0.009, 0.011, -0.007, 0.010, -0.011]
	var raw_extent := 0.0
	var filtered_extent := 0.0
	for i in range(noise.size()):
		var sample := Vector3(noise[i], 0, 0)
		var out := still.filter(0, sample, dt)
		if i >= 2:  # skip the seeding transient
			raw_extent = maxf(raw_extent, absf(sample.x))
			filtered_extent = maxf(filtered_extent, absf(out.x))
	if filtered_extent >= raw_extent:
		failures.append("filter did not attenuate stationary noise (raw %.4f, filtered %.4f)" % [raw_extent, filtered_extent])

	# 3. Direction is preserved on diagonal motion. This is the property that
	#    per-component filtering breaks: independent alphas make the slow axis
	#    lag more, bending the path.
	var diagonal := XROneEuroFilter.new()
	diagonal.resize(1)
	diagonal.min_cutoff = 1.0
	diagonal.beta = 0.5
	var direction := Vector3(1.0, 0.25, 0.0).normalized()
	var out_vector := Vector3.ZERO
	for step in range(20):
		out_vector = diagonal.filter(0, direction * (0.02 * step), dt)
	if out_vector.length() > 0.0001:
		var angle_deg := rad_to_deg(out_vector.normalized().angle_to(direction))
		if angle_deg > 0.5:
			failures.append("filtered path bent %.3f deg off the input direction" % angle_deg)

	# 4. beta > 0 reduces lag on fast motion (the whole point of 1 euro).
	var lagged := _ramp_end(0.0, dt)
	var responsive := _ramp_end(1.0, dt)
	if not (responsive > lagged):
		failures.append("beta did not reduce lag: beta=0 ended at %.4f, beta=1 at %.4f" % [lagged, responsive])

	# 5. Channels are independent.
	var banked := XROneEuroFilter.new()
	banked.resize(2)
	banked.filter(0, Vector3(10, 0, 0), dt)
	var fresh := banked.filter(1, Vector3(0, 5, 0), dt)
	if not fresh.is_equal_approx(Vector3(0, 5, 0)):
		failures.append("channel 1 was polluted by channel 0: %s" % str(fresh))

func _ramp_end(beta: float, dt: float) -> float:
	var filter := XROneEuroFilter.new()
	filter.resize(1)
	filter.min_cutoff = 1.0
	filter.beta = beta
	var out := Vector3.ZERO
	for step in range(20):
		out = filter.filter(0, Vector3(0.05 * step, 0, 0), dt)
	return out.x

func _test_one_euro_robustness(failures: Array[String]) -> void:
	var dt := 1.0 / 72.0
	var filter := XROneEuroFilter.new()
	filter.resize(1)
	filter.filter(0, Vector3(1, 1, 1), dt)

	# Non-finite input must pass through and not poison the state.
	var nan_out := filter.filter(0, Vector3(NAN, 0, 0), dt)
	if nan_out.is_finite():
		failures.append("expected the non-finite input to pass through unchanged")
	var recovered := filter.filter(0, Vector3(2, 2, 2), dt)
	if not recovered.is_finite():
		failures.append("filter state was poisoned by a non-finite sample")

	# Zero and negative dt must not divide by zero.
	var zero_dt := filter.filter(0, Vector3(3, 3, 3), 0.0)
	if not zero_dt.is_finite():
		failures.append("dt = 0 produced a non-finite result")
	var negative_dt := filter.filter(0, Vector3(3, 3, 3), -0.5)
	if not negative_dt.is_finite():
		failures.append("negative dt produced a non-finite result")

	# reset_channel re-seeds: the next sample passes through.
	filter.reset_channel(0)
	var reseeded := filter.filter(0, Vector3(9, 9, 9), dt)
	if not reseeded.is_equal_approx(Vector3(9, 9, 9)):
		failures.append("reset_channel did not re-seed: %s" % str(reseeded))

func _test_rotation_filter(failures: Array[String]) -> void:
	var dt := 1.0 / 72.0
	var filter := XROneEuroRotationFilter.new()
	filter.resize(1)

	var start := Quaternion(Vector3.UP, 0.0)
	var seeded := filter.filter(0, start, dt)
	if not seeded.is_equal_approx(start):
		failures.append("rotation filter must seed on the first sample")

	# Double cover: q and -q are the SAME rotation, so filtering toward either
	# must converge to the same result. NOTE: do NOT add a manual `if dot < 0:
	# negate` correction -- Godot's slerp and angle_to are already double-cover
	# invariant, so it would be dead code. Verified against the engine; slerpni
	# is the explicit opt-out. This test fails (123 deg divergence) if slerp is
	# swapped for slerpni, so it genuinely constrains the behaviour.
	var target := Quaternion(Vector3.UP, 0.2).normalized()
	var toward := XROneEuroRotationFilter.new(); toward.resize(1)
	var away := XROneEuroRotationFilter.new(); away.resize(1)
	toward.filter(0, start, dt); away.filter(0, start, dt)
	var a := start
	var b := start
	for step in range(10):
		a = toward.filter(0, target, dt)
		b = away.filter(0, -target, dt)
	if rad_to_deg(a.angle_to(b)) > 0.01:
		failures.append("filtering toward target and -target diverged: angle_to = %f deg" % rad_to_deg(a.angle_to(b)))

	# Output stays normalized.
	var settle := Quaternion(Vector3.RIGHT, 1.0).normalized()
	for step in range(10):
		out = filter.filter(0, settle, dt)
	if not is_equal_approx(out.length(), 1.0):
		failures.append("rotation filter output drifted off unit length: %.6f" % out.length())
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd "C:/Users/davta/Repos/Godot_WebXR_gh/demo"
"C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe" \
  --headless --xr-mode off --path . \
  --script res://addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd
```

Expected: FAIL — `Identifier "XROneEuroFilter" not declared`.

- [ ] **Step 3: Implement the vector filter**

Create `addons/godot_xr_interaction_toolkit/runtime/input/filter/xr_one_euro_filter.gd`:

```gdscript
class_name XROneEuroFilter
extends RefCounted

## Adaptive low-pass filter bank over Vector3 channels.
##
## Casiez, G., Roussel, N., & Vogel, D. (2012). "1 euro filter: a simple
## speed-based low-pass filter for noisy input in interactive systems." CHI '12.
##
## The cutoff frequency rises with the estimated speed of the signal: heavy
## smoothing while the hand is still, low lag while it moves.
##
## Vectors are filtered as WHOLE UNITS -- one speed estimate from the vector's
## magnitude, one alpha, one lerp. Filtering components independently gives each
## axis its own alpha, so on a diagonal motion the slower axis lags further and
## the trajectory BENDS. One alpha preserves direction exactly, and costs 1
## GDScript operation instead of 3.
##
## State lives in flat packed arrays indexed by channel rather than one object
## per filtered value, avoiding both the allocation and the property lookups.

## Cutoff in Hz at zero speed. Lower = steadier at rest, more lag.
var min_cutoff := 1.0
## Speed coefficient. Higher = less lag when moving, more jitter passed through.
var beta := 0.0
## Cutoff in Hz for smoothing the speed estimate itself.
var d_cutoff := 1.0

var _value: PackedVector3Array = PackedVector3Array()
var _derivative: PackedVector3Array = PackedVector3Array()
var _seeded: PackedByteArray = PackedByteArray()

## Smallest dt we will divide by. A backgrounded tab or a paused frame can
## report a huge or zero delta; clamping keeps one bad frame from spiking.
const MIN_DELTA := 0.0001
const MAX_DELTA := 0.5

static func alpha(cutoff: float, dt: float) -> float:
	var time_constant := 1.0 / (TAU * maxf(cutoff, 0.0001))
	return 1.0 / (1.0 + time_constant / dt)

func resize(channel_count: int) -> void:
	_value.resize(channel_count)
	_derivative.resize(channel_count)
	_seeded.resize(channel_count)
	reset_all()

func reset_all() -> void:
	_seeded.fill(0)

func reset_channel(channel: int) -> void:
	if channel >= 0 and channel < _seeded.size():
		_seeded[channel] = 0

func filter(channel: int, value: Vector3, dt: float) -> Vector3:
	if channel < 0 or channel >= _seeded.size():
		return value
	# Never let a bad sample enter the state. Pass it through so the caller sees
	# the runtime's own value rather than a silently invented one.
	if not value.is_finite():
		return value

	var step := clampf(dt, MIN_DELTA, MAX_DELTA)

	if _seeded[channel] == 0:
		_value[channel] = value
		_derivative[channel] = Vector3.ZERO
		_seeded[channel] = 1
		return value

	var previous := _value[channel]
	var raw_derivative := (value - previous) / step
	var smooth_derivative := _derivative[channel].lerp(raw_derivative, alpha(d_cutoff, step))
	var cutoff := min_cutoff + beta * smooth_derivative.length()
	var filtered := previous.lerp(value, alpha(cutoff, step))

	_value[channel] = filtered
	_derivative[channel] = smooth_derivative
	return filtered
```

- [ ] **Step 4: Implement the rotation filter**

Create `addons/godot_xr_interaction_toolkit/runtime/input/filter/xr_one_euro_rotation_filter.gd`:

```gdscript
class_name XROneEuroRotationFilter
extends RefCounted

## One Euro adaptive low-pass over Quaternion channels.
##
## Shares XROneEuroFilter's alpha computation. Speed is angular distance per
## second and the blend is a single slerp, so the whole rotation is filtered as
## one unit -- the rotational counterpart of filtering a Vector3 as one unit.
##
## State is Array[Quaternion], NOT a stride-4 PackedFloat32Array: in GDScript
## the cost that matters is the number of GDScript-level operations, and one
## typed-array read beats four float reads plus a constructor.

var min_cutoff := 1.0
var beta := 0.0
var d_cutoff := 1.0

var _value: Array[Quaternion] = []
var _speed: PackedFloat32Array = PackedFloat32Array()
var _seeded: PackedByteArray = PackedByteArray()

func resize(channel_count: int) -> void:
	_value.resize(channel_count)
	_speed.resize(channel_count)
	_seeded.resize(channel_count)
	reset_all()

func reset_all() -> void:
	_seeded.fill(0)

func reset_channel(channel: int) -> void:
	if channel >= 0 and channel < _seeded.size():
		_seeded[channel] = 0

func filter(channel: int, value: Quaternion, dt: float) -> Quaternion:
	if channel < 0 or channel >= _seeded.size():
		return value
	if not value.is_finite() or is_zero_approx(value.length_squared()):
		return value

	var normalized := value.normalized()
	var step := clampf(dt, XROneEuroFilter.MIN_DELTA, XROneEuroFilter.MAX_DELTA)

	if _seeded[channel] == 0:
		_value[channel] = normalized
		_speed[channel] = 0.0
		_seeded[channel] = 1
		return normalized

	var previous: Quaternion = _value[channel]
	# q and -q are the same rotation. Without this, slerp can travel the long
	# way around and the hand snaps through a full turn.
	if previous.dot(normalized) < 0.0:
		normalized = -normalized

	var raw_speed := previous.angle_to(normalized) / step
	var smooth_speed := lerpf(_speed[channel], raw_speed, XROneEuroFilter.alpha(d_cutoff, step))
	var cutoff := min_cutoff + beta * smooth_speed
	var filtered := previous.slerp(normalized, XROneEuroFilter.alpha(cutoff, step)).normalized()

	_value[channel] = filtered
	_speed[channel] = smooth_speed
	return filtered
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd "C:/Users/davta/Repos/Godot_WebXR_gh/demo"
"C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe" \
  --headless --xr-mode off --path . \
  --script res://addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd
```

Expected: `XR hand conditioning: PASS`, exit 0.

- [ ] **Step 6: Commit**

```bash
cd "C:/Users/davta/Repos/godot-xr-suite"
git add addons/godot_xr_interaction_toolkit/
git commit -m "feat: add the One Euro filter banks

Adaptive low-pass over Vector3 and Quaternion channels (Casiez, Roussel &
Vogel, CHI 2012). Cutoff rises with estimated speed: steady at rest, low lag
when moving.

Vectors and rotations are filtered as whole units rather than per component.
Independent per-axis alphas make the slower axis lag further on diagonal
motion, bending the trajectory; one alpha from the magnitude preserves
direction and costs a third of the GDScript operations.

State is flat packed arrays indexed by channel, not an object per value."
```

---

### Task 4: Trace recorder and player

Must exist before any parameter tuning, so the first parameter choice is made against a real baseline.

**Files:**
- Create: `addons/godot_xr_interaction_toolkit/tools/trace/xr_hand_trace.gd`
- Create: `addons/godot_xr_interaction_toolkit/tools/trace/xr_hand_trace_recorder.gd`
- Create: `addons/godot_xr_interaction_toolkit/tools/trace/xr_hand_trace_player.gd`
- Modify: `addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd`

**Interfaces:**
- Consumes: `XRHandFrame`, `XRHandPoseSource` (Task 1).
- Produces:
  - `XRHandTrace` — `frames: Array` of dictionaries `{timestamp_usec: int, hand: int, transforms: Array[Transform3D], radii: PackedFloat32Array, flags: PackedInt32Array, tracking_valid: bool}`; `append_frame(frame: XRHandFrame) -> void`; `save(path: String) -> Error`; static `load_trace(path: String) -> XRHandTrace`; `size() -> int`
  - `XRHandTraceRecorder` — `Node`, `@export var hand: int`, `@export var auto_start: bool`, `start()`, `stop_and_save(path: String) -> Error`
  - `XRHandTracePlayer extends XRHandPoseSource` — `XRHandTracePlayer.new(trace: XRHandTrace)`, `capture(hand, timestamp_usec, target) -> bool` walking the trace one frame per call, `rewind()`, `remaining() -> int`

- [ ] **Step 1: Write the failing round-trip test**

Add to `_init` in `test_hand_conditioning.gd`:

```gdscript
	_test_trace_round_trip(failures)
```

and append:

```gdscript
func _test_trace_round_trip(failures: Array[String]) -> void:
	var trace := XRHandTrace.new()
	for step in range(5):
		var frame := XRHandFrame.new()
		frame.begin_capture(0, 1000 * step, step)
		frame.set_joint(
			XRHandTracker.HAND_JOINT_WRIST,
			Transform3D(Basis.IDENTITY, Vector3(0.01 * step, 0, 0)),
			0.01,
			XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
		frame.tracking_valid = true
		trace.append_frame(frame)

	if trace.size() != 5:
		failures.append("trace recorded %d frames, expected 5" % trace.size())

	var path := "user://test_hand_trace.res"
	if trace.save(path) != OK:
		failures.append("failed to save the trace")
		return

	var loaded := XRHandTrace.load_trace(path)
	if loaded == null or loaded.size() != 5:
		failures.append("failed to reload the trace")
		return

	# Replay it through the pose-source seam.
	var player := XRHandTracePlayer.new(loaded)
	var target := XRHandFrame.new()
	var positions: Array[float] = []
	while player.remaining() > 0:
		if player.capture(0, 0, target):
			positions.append(target.joint_transforms[XRHandTracker.HAND_JOINT_WRIST].origin.x)

	if positions.size() != 5:
		failures.append("replayed %d frames, expected 5" % positions.size())
		return
	for step in range(5):
		if not is_equal_approx(positions[step], 0.01 * step):
			failures.append("replayed frame %d had x=%.5f, expected %.5f" % [step, positions[step], 0.01 * step])

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd "C:/Users/davta/Repos/Godot_WebXR_gh/demo"
"C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe" \
  --headless --xr-mode off --path . \
  --script res://addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd
```

Expected: FAIL — `Identifier "XRHandTrace" not declared`.

- [ ] **Step 3: Implement the trace container**

Create `addons/godot_xr_interaction_toolkit/tools/trace/xr_hand_trace.gd`:

```gdscript
class_name XRHandTrace
extends Resource

## A recorded stream of raw hand frames, so conditioning can be measured and
## tuned offline against real tracking data instead of guesses.

@export var frames: Array = []

func append_frame(frame: XRHandFrame) -> void:
	var transforms: Array[Transform3D] = []
	transforms.resize(XRHandFrame.JOINT_COUNT)
	for joint in range(XRHandFrame.JOINT_COUNT):
		transforms[joint] = frame.joint_transforms[joint]
	frames.append({
		"timestamp_usec": frame.timestamp_usec,
		"hand": frame.hand,
		"transforms": transforms,
		"radii": frame.joint_radii.duplicate(),
		"flags": frame.joint_flags.duplicate(),
		"tracking_valid": frame.tracking_valid,
	})

func size() -> int:
	return frames.size()

func save(path: String) -> Error:
	return ResourceSaver.save(self, path)

static func load_trace(path: String) -> XRHandTrace:
	if not ResourceLoader.exists(path):
		return null
	return ResourceLoader.load(path, "XRHandTrace", ResourceLoader.CACHE_MODE_IGNORE) as XRHandTrace
```

- [ ] **Step 4: Implement the player**

Create `addons/godot_xr_interaction_toolkit/tools/trace/xr_hand_trace_player.gd`:

```gdscript
class_name XRHandTracePlayer
extends XRHandPoseSource

## Replays a recorded trace through the acquisition seam, so the whole
## conditioning chain runs headless with no headset attached.

var _trace: XRHandTrace
var _index := 0

func _init(trace: XRHandTrace = null) -> void:
	_trace = trace

func rewind() -> void:
	_index = 0

func remaining() -> int:
	if _trace == null:
		return 0
	return maxi(0, _trace.size() - _index)

## Ignores the passed timestamp and uses the recorded one, so replay reproduces
## the original frame pacing exactly -- which the filter depends on.
func capture(hand: int, _timestamp_usec: int, target: XRHandFrame) -> bool:
	if _trace == null or _index >= _trace.size():
		return false

	var entry: Dictionary = _trace.frames[_index]
	_index += 1

	target.begin_capture(hand, int(entry["timestamp_usec"]), _index)
	var transforms: Array = entry["transforms"]
	var radii: PackedFloat32Array = entry["radii"]
	var flags: PackedInt32Array = entry["flags"]
	for joint in range(XRHandFrame.JOINT_COUNT):
		target.set_joint(joint, transforms[joint], radii[joint], flags[joint])

	target.tracking_valid = bool(entry["tracking_valid"])
	return target.tracking_valid
```

- [ ] **Step 5: Implement the recorder**

Create `addons/godot_xr_interaction_toolkit/tools/trace/xr_hand_trace_recorder.gd`:

```gdscript
@tool
class_name XRHandTraceRecorder
extends Node

## Drop into a running scene to capture RAW hand frames to disk. Records
## upstream of all conditioning, so a trace stays a valid baseline no matter
## how the filter is later retuned.

## 0 = left, 1 = right.
@export var hand := 1
@export var auto_start := false
## Where stop_and_save writes by default.
@export var output_path := "user://hand_traces/trace.res"

var _trace: XRHandTrace
var _source: XRTrackerHandPoseSource
var _frame := XRHandFrame.new()
var _recording := false
var _last_timestamp := -1

func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return
	_source = XRTrackerHandPoseSource.new()
	if auto_start:
		start()

func start() -> void:
	_trace = XRHandTrace.new()
	_last_timestamp = -1
	_recording = true

func is_recording() -> bool:
	return _recording

func frame_count() -> int:
	return _trace.size() if _trace else 0

func stop_and_save(path := "") -> Error:
	_recording = false
	if _trace == null or _trace.size() == 0:
		push_warning("XRHandTraceRecorder: nothing recorded")
		return ERR_DOES_NOT_EXIST
	var target := path if not path.is_empty() else output_path
	DirAccess.make_dir_recursive_absolute(target.get_base_dir())
	var result := _trace.save(target)
	if result == OK:
		print("XRHandTraceRecorder: wrote %d frames to %s" % [_trace.size(), target])
	return result

func _process(_delta: float) -> void:
	if not _recording or _source == null:
		return
	var timestamp := Time.get_ticks_usec()
	if not _source.capture(hand, timestamp, _frame):
		return
	# The raw tracker can be polled faster than it updates; do not record a
	# frame twice or the replayed pacing stops matching reality.
	if _frame.timestamp_usec == _last_timestamp:
		return
	_last_timestamp = _frame.timestamp_usec
	_trace.append_frame(_frame)
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd "C:/Users/davta/Repos/Godot_WebXR_gh/demo"
"C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe" \
  --headless --xr-mode off --path . \
  --script res://addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd
```

Expected: `XR hand conditioning: PASS`, exit 0.

- [ ] **Step 7: Commit**

```bash
cd "C:/Users/davta/Repos/godot-xr-suite"
git add addons/godot_xr_interaction_toolkit/
git commit -m "feat: add the hand trace recorder, container, and player

Records raw hand frames to disk and replays them through the acquisition seam,
so the conditioning chain runs headless and parameters get tuned against real
tracking data rather than guesses. Recording sits upstream of all conditioning
so a trace stays a valid baseline across retunes."
```

---

### Task 5: Trace metrics

The three numbers that decide whether a parameter set is better or merely different.

**Files:**
- Create: `addons/godot_xr_interaction_toolkit/tools/trace/xr_hand_trace_metrics.gd`
- Modify: `addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd`

**Interfaces:**
- Consumes: `XRHandTrace`, `XRHandJointHierarchy`.
- Produces:
  - `XRHandTraceMetrics.rest_jitter(samples: PackedVector3Array) -> float` (static) — RMS deviation from the mean, metres
  - `XRHandTraceMetrics.motion_lag_seconds(raw: PackedVector3Array, conditioned: PackedVector3Array, dt: float, max_shift: int) -> float` (static)
  - `XRHandTraceMetrics.bone_length_deviation(frames: Array, joint: int) -> float` (static) — standard deviation of one bone's length, metres

- [ ] **Step 1: Write the failing tests**

Add to `_init`:

```gdscript
	_test_trace_metrics(failures)
```

and append:

```gdscript
func _test_trace_metrics(failures: Array[String]) -> void:
	# Jitter: a constant signal has zero spread; a noisy one does not.
	var still := PackedVector3Array()
	for i in range(20):
		still.append(Vector3(0.5, 0.5, 0.5))
	if not is_zero_approx(XRHandTraceMetrics.rest_jitter(still)):
		failures.append("a constant signal must have zero rest jitter")

	var noisy := PackedVector3Array()
	for i in range(20):
		noisy.append(Vector3(0.5 + (0.01 if i % 2 == 0 else -0.01), 0.5, 0.5))
	var noisy_jitter := XRHandTraceMetrics.rest_jitter(noisy)
	if not is_equal_approx(noisy_jitter, 0.01):
		failures.append("expected 0.01 m rest jitter, got %.5f" % noisy_jitter)

	# Lag: a signal delayed by a known number of frames must be measured back.
	var dt := 1.0 / 72.0
	var raw := PackedVector3Array()
	var delayed := PackedVector3Array()
	var shift := 3
	for i in range(60):
		raw.append(Vector3(sin(i * 0.2), 0, 0))
		delayed.append(Vector3(sin((i - shift) * 0.2), 0, 0))
	var measured := XRHandTraceMetrics.motion_lag_seconds(raw, delayed, dt, 10)
	if not is_equal_approx(measured, shift * dt):
		failures.append("expected %.5f s of lag, measured %.5f s" % [shift * dt, measured])

	# Bone length: a rigid chain has zero deviation, a stretching one does not.
	var rigid := _bone_frames([0.03, 0.03, 0.03, 0.03])
	if not is_zero_approx(XRHandTraceMetrics.bone_length_deviation(rigid, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP)):
		failures.append("a rigid bone must have zero length deviation")

	var stretching := _bone_frames([0.03, 0.04, 0.03, 0.04])
	if XRHandTraceMetrics.bone_length_deviation(stretching, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP) <= 0.0:
		failures.append("a stretching bone must report non-zero length deviation")

## Builds trace-shaped frames where the index tip sits `lengths[i]` from its parent.
func _bone_frames(lengths: Array) -> Array:
	var parent_joint: int = XRHandJointHierarchy.PARENT[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP]
	var built: Array = []
	for length in lengths:
		var transforms: Array[Transform3D] = []
		transforms.resize(XRHandFrame.JOINT_COUNT)
		for joint in range(XRHandFrame.JOINT_COUNT):
			transforms[joint] = Transform3D.IDENTITY
		transforms[parent_joint] = Transform3D(Basis.IDENTITY, Vector3.ZERO)
		transforms[XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP] = Transform3D(Basis.IDENTITY, Vector3(0, 0, length))
		var flags := PackedInt32Array()
		flags.resize(XRHandFrame.JOINT_COUNT)
		flags.fill(XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
		built.append({"transforms": transforms, "flags": flags})
	return built
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd "C:/Users/davta/Repos/Godot_WebXR_gh/demo"
"C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe" \
  --headless --xr-mode off --path . \
  --script res://addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd
```

Expected: FAIL — `Identifier "XRHandTraceMetrics" not declared`.

- [ ] **Step 3: Implement the metrics**

Create `addons/godot_xr_interaction_toolkit/tools/trace/xr_hand_trace_metrics.gd`:

```gdscript
class_name XRHandTraceMetrics
extends RefCounted

## The three quantities that decide whether a conditioning parameter set is
## better or merely different. Jitter and lag are in direct tension -- that
## tension is what an adaptive filter exists to manage -- so both are always
## reported together. Bone-length deviation checks the rigidity guarantee.

## RMS deviation from the mean over a segment where the hand was held still.
## Metres. Lower is steadier.
static func rest_jitter(samples: PackedVector3Array) -> float:
	if samples.size() < 2:
		return 0.0
	var mean := Vector3.ZERO
	for sample in samples:
		mean += sample
	mean /= float(samples.size())
	var total := 0.0
	for sample in samples:
		total += (sample - mean).length_squared()
	return sqrt(total / float(samples.size()))

## Delay between raw and conditioned, found by the frame shift that best aligns
## them. Seconds. Higher is laggier.
static func motion_lag_seconds(raw: PackedVector3Array, conditioned: PackedVector3Array, dt: float, max_shift: int) -> float:
	var count := mini(raw.size(), conditioned.size())
	if count < 2 or max_shift < 1:
		return 0.0
	var best_shift := 0
	var best_error := INF
	for shift in range(0, max_shift + 1):
		var error := 0.0
		var compared := 0
		for index in range(shift, count):
			error += (conditioned[index] - raw[index - shift]).length_squared()
			compared += 1
		if compared == 0:
			continue
		error /= float(compared)
		if error < best_error:
			best_error = error
			best_shift = shift
	return float(best_shift) * dt

## Standard deviation of one bone's length across a trace. Metres.
## The formal check on the parent-local design: filtering must not change it.
static func bone_length_deviation(frames: Array, joint: int) -> float:
	var parent_joint: int = XRHandJointHierarchy.PARENT[joint]
	if parent_joint < 0:
		return 0.0

	var lengths := PackedFloat32Array()
	for entry in frames:
		var transforms: Array = entry["transforms"]
		var flags: PackedInt32Array = entry["flags"]
		var valid := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID
		if (flags[joint] & valid) == 0 or (flags[parent_joint] & valid) == 0:
			continue
		var child: Transform3D = transforms[joint]
		var parent: Transform3D = transforms[parent_joint]
		lengths.append((child.origin - parent.origin).length())

	if lengths.size() < 2:
		return 0.0
	var mean := 0.0
	for length in lengths:
		mean += length
	mean /= float(lengths.size())
	var total := 0.0
	for length in lengths:
		total += pow(length - mean, 2.0)
	return sqrt(total / float(lengths.size()))
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd "C:/Users/davta/Repos/Godot_WebXR_gh/demo"
"C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe" \
  --headless --xr-mode off --path . \
  --script res://addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd
```

Expected: `XR hand conditioning: PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
cd "C:/Users/davta/Repos/godot-xr-suite"
git add addons/godot_xr_interaction_toolkit/
git commit -m "feat: add trace metrics for jitter, lag, and bone-length deviation

Rest jitter is RMS deviation from the local mean; motion lag is the frame
shift that best aligns conditioned output to raw input; bone-length deviation
is the standard deviation of a bone across a trace.

Jitter and lag are reported together because they trade against each other --
quoting only one would make any filter look good."
```

---

### Task 6: The hand filter

**Files:**
- Create: `addons/godot_xr_interaction_toolkit/runtime/input/filter/xr_hand_filter.gd`
- Modify: `addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd`

**Interfaces:**
- Consumes: `XROneEuroFilter`, `XROneEuroRotationFilter`, `XRHandJointHierarchy`, `XRHandFrame`, `XRHandPoseSource`.
- Produces: `XRHandFilter extends XRHandPoseSource` — `XRHandFilter.new(inner: XRHandPoseSource)`; properties `position_min_cutoff`, `position_beta`, `rotation_min_cutoff`, `rotation_beta`, `bone_min_cutoff`, `enabled: bool`; `reset(hand: int) -> void`; `set_controller_source(hand: int, is_controller: bool) -> void`; `capture(hand, timestamp_usec, target) -> bool`.

- [ ] **Step 1: Write the failing tests**

Add to `_init`:

```gdscript
	_test_hand_filter(failures)
```

and append:

```gdscript
## Builds a pose source emitting a wrist-plus-index-tip hand with optional noise.
func _noisy_source(sample_count: int, noise: float) -> XRHandTracePlayer:
	var trace := XRHandTrace.new()
	var tip_offset := Vector3(0, 0, 0.03)
	for step in range(sample_count):
		var frame := XRHandFrame.new()
		frame.begin_capture(1, step * 13888, step)  # ~72 Hz in microseconds
		var wobble := Vector3(noise if step % 2 == 0 else -noise, 0, 0)
		var wrist := Transform3D(Basis.IDENTITY, wobble)
		frame.set_joint(XRHandTracker.HAND_JOINT_WRIST, wrist, 0.01, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
		frame.set_joint(
			XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL,
			Transform3D(Basis.IDENTITY, wobble),
			0.008, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
		frame.set_joint(
			XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP,
			Transform3D(Basis.IDENTITY, wobble + tip_offset),
			0.008, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
		frame.tracking_valid = true
		trace.append_frame(frame)
	return XRHandTracePlayer.new(trace)

func _test_hand_filter(failures: Array[String]) -> void:
	# 1. Filtering attenuates wrist jitter.
	var raw_samples := PackedVector3Array()
	var raw_player := _noisy_source(40, 0.004)
	var raw_frame := XRHandFrame.new()
	while raw_player.remaining() > 0:
		if raw_player.capture(1, 0, raw_frame):
			raw_samples.append(raw_frame.joint_transforms[XRHandTracker.HAND_JOINT_WRIST].origin)

	var filtered_samples := PackedVector3Array()
	var filter := XRHandFilter.new(_noisy_source(40, 0.004))
	filter.position_min_cutoff = 1.0
	filter.position_beta = 0.0
	var out_frame := XRHandFrame.new()
	for step in range(40):
		if filter.capture(1, 0, out_frame):
			filtered_samples.append(out_frame.joint_transforms[XRHandTracker.HAND_JOINT_WRIST].origin)

	if filtered_samples.size() < 30:
		failures.append("hand filter produced only %d frames" % filtered_samples.size())
		return

	var raw_jitter := XRHandTraceMetrics.rest_jitter(raw_samples)
	var filtered_jitter := XRHandTraceMetrics.rest_jitter(filtered_samples)
	if filtered_jitter >= raw_jitter:
		failures.append("filter did not reduce jitter (raw %.5f, filtered %.5f)" % [raw_jitter, filtered_jitter])

	# 2. RIGIDITY. The central guarantee: no parameters, however extreme, may
	#    change a bone length. This must hold by construction, not by tuning.
	var extreme := XRHandFilter.new(_noisy_source(40, 0.02))
	extreme.position_min_cutoff = 0.01
	extreme.position_beta = 0.0
	extreme.rotation_min_cutoff = 0.01
	extreme.bone_min_cutoff = 0.01
	var captured: Array = []
	var rigid_frame := XRHandFrame.new()
	for step in range(40):
		if not extreme.capture(1, 0, rigid_frame):
			continue
		var transforms: Array[Transform3D] = []
		transforms.resize(XRHandFrame.JOINT_COUNT)
		for joint in range(XRHandFrame.JOINT_COUNT):
			transforms[joint] = rigid_frame.joint_transforms[joint]
		captured.append({"transforms": transforms, "flags": rigid_frame.joint_flags.duplicate()})

	var deviation := XRHandTraceMetrics.bone_length_deviation(captured, XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP)
	if deviation > 0.0005:
		failures.append("bone length varied by %.5f m under extreme filtering (limit 0.0005)" % deviation)

	# 3. enabled = false is a true pass-through.
	var bypass := XRHandFilter.new(_noisy_source(6, 0.01))
	bypass.enabled = false
	var bypass_frame := XRHandFrame.new()
	bypass.capture(1, 0, bypass_frame)
	bypass.capture(1, 0, bypass_frame)
	var expected := Vector3(-0.01, 0, 0)  # step 1 of the alternating wobble
	if not bypass_frame.joint_transforms[XRHandTracker.HAND_JOINT_WRIST].origin.is_equal_approx(expected):
		failures.append("disabled filter altered the frame: %s" % str(bypass_frame.joint_transforms[XRHandTracker.HAND_JOINT_WRIST].origin))
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd "C:/Users/davta/Repos/Godot_WebXR_gh/demo"
"C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe" \
  --headless --xr-mode off --path . \
  --script res://addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd
```

Expected: FAIL — `Identifier "XRHandFilter" not declared`.

- [ ] **Step 3: Implement the filter**

Create `addons/godot_xr_interaction_toolkit/runtime/input/filter/xr_hand_filter.gd`:

```gdscript
class_name XRHandFilter
extends XRHandPoseSource

## Adaptive conditioning decorator over any XRHandPoseSource.
##
## Decomposes each frame into a wrist world pose plus per-joint PARENT-LOCAL
## transforms, filters those, and recomposes. Because rotations are filtered in
## parent-local space, no filter strength can change a bone length -- distortion
## is structurally impossible rather than merely unlikely.
##
## Bone OFFSETS are filtered very hard: a given user's skeleton is essentially
## constant, and the runtime reports it with measurement noise on top, so heavy
## filtering converges to a stable per-user skeleton. That stops the mesh hand
## breathing, which is a separate artifact from joint jitter.

const _HANDS := 2

@export var enabled := true

## Optically-tracked parameters.
@export var position_min_cutoff := 1.0
@export var position_beta := 0.7
@export var rotation_min_cutoff := 1.5
@export var rotation_beta := 0.5
## Bone offsets converge to a stable skeleton; deliberately far lower.
@export var bone_min_cutoff := 0.05

## Controller-emulated hands have different noise characteristics.
@export var controller_position_min_cutoff := 2.0
@export var controller_position_beta := 0.4
@export var controller_rotation_min_cutoff := 3.0
@export var controller_rotation_beta := 0.3

var _inner: XRHandPoseSource
var _raw := XRHandFrame.new()

# Per hand.
var _wrist_position: Array[XROneEuroFilter] = []
var _wrist_rotation: Array[XROneEuroRotationFilter] = []
var _local_rotation: Array[XROneEuroRotationFilter] = []
var _local_offset: Array[XROneEuroFilter] = []
var _is_controller := [false, false]
var _last_timestamp := [-1, -1]
# Duplicate-sample suppression (see capture).
var _output: Array[XRHandFrame] = []
var _last_raw_wrist: Array[Transform3D] = [Transform3D.IDENTITY, Transform3D.IDENTITY]
var _has_output := [false, false]

func _init(inner: XRHandPoseSource = null) -> void:
	_inner = inner
	for hand in range(_HANDS):
		_output.append(XRHandFrame.new())
		var wrist_position := XROneEuroFilter.new()
		wrist_position.resize(1)
		_wrist_position.append(wrist_position)

		var wrist_rotation := XROneEuroRotationFilter.new()
		wrist_rotation.resize(1)
		_wrist_rotation.append(wrist_rotation)

		var rotations := XROneEuroRotationFilter.new()
		rotations.resize(XRHandFrame.JOINT_COUNT)
		_local_rotation.append(rotations)

		var offsets := XROneEuroFilter.new()
		offsets.resize(XRHandFrame.JOINT_COUNT)
		_local_offset.append(offsets)
	_apply_parameters()

## Called on tracking reacquisition so the filter snaps to the recovered pose
## instead of slewing from a stale one over its whole time constant.
func reset(hand: int) -> void:
	if hand < 0 or hand >= _HANDS:
		return
	_wrist_position[hand].reset_all()
	_wrist_rotation[hand].reset_all()
	_local_rotation[hand].reset_all()
	_local_offset[hand].reset_all()
	_last_timestamp[hand] = -1
	_has_output[hand] = false

## The input modality manager is the authority on whether a hand is
## controller-driven -- tracker.hand_tracking_source is NOT reliable across
## runtimes. Callers resolve the manager by group and push the answer here.
func set_controller_source(hand: int, is_controller: bool) -> void:
	if hand < 0 or hand >= _HANDS or _is_controller[hand] == is_controller:
		return
	_is_controller[hand] = is_controller
	_apply_parameters()
	reset(hand)

func _apply_parameters() -> void:
	for hand in range(_HANDS):
		var controller: bool = _is_controller[hand]
		var pos_cutoff := controller_position_min_cutoff if controller else position_min_cutoff
		var pos_beta := controller_position_beta if controller else position_beta
		var rot_cutoff := controller_rotation_min_cutoff if controller else rotation_min_cutoff
		var rot_beta := controller_rotation_beta if controller else rotation_beta

		_wrist_position[hand].min_cutoff = pos_cutoff
		_wrist_position[hand].beta = pos_beta
		_wrist_rotation[hand].min_cutoff = rot_cutoff
		_wrist_rotation[hand].beta = rot_beta
		_local_rotation[hand].min_cutoff = rot_cutoff
		_local_rotation[hand].beta = rot_beta
		_local_offset[hand].min_cutoff = bone_min_cutoff
		_local_offset[hand].beta = 0.0

func capture(hand: int, timestamp_usec: int, target: XRHandFrame) -> bool:
	if _inner == null:
		return false
	if not _inner.capture(hand, timestamp_usec, _raw):
		return false

	# Reset before conditioning this frame, never after: on reacquisition the
	# filter must snap to the recovered pose, not slew from the held stale one.
	if _inner.consume_discontinuity(hand):
		reset(hand)

	if not enabled or hand < 0 or hand >= _HANDS:
		_raw.copy_into(target)
		return _raw.tracking_valid

	# The render rate often exceeds the hand-tracking rate. If the runtime has
	# not moved the hand, re-running the chain would advance filter state on a
	# duplicate sample -- which biases the derivative estimate toward zero and
	# makes the filter over-smooth. Replay the previous output instead.
	var wrist_raw := _raw.joint_transforms[XRHandTracker.HAND_JOINT_WRIST]
	if _has_output[hand] and wrist_raw.is_equal_approx(_last_raw_wrist[hand]):
		_output[hand].copy_into(target)
		return _output[hand].tracking_valid
	_last_raw_wrist[hand] = wrist_raw

	var previous: int = _last_timestamp[hand]
	var dt := 1.0 / 72.0
	if previous >= 0 and _raw.timestamp_usec > previous:
		dt = float(_raw.timestamp_usec - previous) / 1_000_000.0
	_last_timestamp[hand] = _raw.timestamp_usec

	_raw.copy_into(target)

	var wrist_id := XRHandTracker.HAND_JOINT_WRIST
	var wrist := _raw.joint_transforms[wrist_id]
	var filtered_origin := _wrist_position[hand].filter(0, wrist.origin, dt)
	var filtered_basis := Basis(_wrist_rotation[hand].filter(0, wrist.basis.get_rotation_quaternion(), dt))
	var world: Array[Transform3D] = []
	world.resize(XRHandFrame.JOINT_COUNT)
	world[wrist_id] = Transform3D(filtered_basis, filtered_origin)
	target.joint_transforms[wrist_id] = world[wrist_id]

	var parents := XRHandJointHierarchy.PARENT
	for joint in XRHandJointHierarchy.ORDER:
		if joint == wrist_id:
			continue
		var parent_joint: int = parents[joint]
		if not _raw.has_joint(joint) or not _raw.has_joint(parent_joint):
			world[joint] = _raw.joint_transforms[joint]
			target.joint_transforms[joint] = world[joint]
			continue

		# Parent-local decomposition. Filtering here cannot change a bone
		# length, because length lives in the offset, not the rotation.
		var local := _raw.joint_transforms[parent_joint].affine_inverse() * _raw.joint_transforms[joint]
		var offset := _local_offset[hand].filter(joint, local.origin, dt)
		var rotation := local.basis.get_rotation_quaternion()
		if XRHandJointHierarchy.IS_TIP[joint] == 0:
			# Tips have no children and their rotation is unused by poke and
			# pinch, so filtering it would be pure cost.
			rotation = _local_rotation[hand].filter(joint, rotation, dt)

		world[joint] = world[parent_joint] * Transform3D(Basis(rotation), offset)
		target.joint_transforms[joint] = world[joint]

	target.copy_into(_output[hand])
	_has_output[hand] = true
	return target.tracking_valid
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd "C:/Users/davta/Repos/Godot_WebXR_gh/demo"
"C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe" \
  --headless --xr-mode off --path . \
  --script res://addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd
```

Expected: `XR hand conditioning: PASS`, exit 0.

If the rigidity assertion fails, the bug is in the decomposition, not the tuning — check that `world[parent_joint]` is the *filtered* parent, not the raw one, and that `ORDER` really is parent-before-child.

- [ ] **Step 5: Commit**

```bash
cd "C:/Users/davta/Repos/godot-xr-suite"
git add addons/godot_xr_interaction_toolkit/
git commit -m "feat: add the parent-local hand filter

Decomposes each frame into wrist world pose plus parent-local joint
transforms, filters those, recomposes. Filtering rotations in parent-local
space makes bone-length distortion structurally impossible rather than
tuning-dependent, verified by a property test at extreme parameters.

Bone offsets are filtered hard, converging to a stable per-user skeleton so
the mesh hand stops breathing. Tips skip rotation filtering: no children, and
poke and pinch use only their position.

Controller-emulated hands get their own parameter set, pushed in by the caller
-- tracker.hand_tracking_source is not reliable across runtimes."
```

---

### Task 7: Confidence gate

**Files:**
- Create: `addons/godot_xr_interaction_toolkit/runtime/input/filter/xr_hand_confidence_gate.gd`
- Modify: `addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd`

**Interfaces:**
- Consumes: `XRHandFrame`, `XRHandPoseSource`.
- Produces: `XRHandConfidenceGate extends XRHandPoseSource` — `XRHandConfidenceGate.new(inner: XRHandPoseSource)`; properties `hold_duration_sec := 0.25`, `min_valid_joints := 1`; `consume_discontinuity(hand: int) -> bool`; `capture(hand, timestamp_usec, target) -> bool`.

- [ ] **Step 1: Write the failing tests**

Add to `_init`:

```gdscript
	_test_confidence_gate(failures)
```

and append:

```gdscript
## Pose source emitting a scripted validity pattern: `pattern[i]` true = tracked.
class _ScriptedSource extends XRHandPoseSource:
	var pattern: Array = []
	var index := 0
	var step_usec := 13888

	func capture(hand: int, _timestamp_usec: int, target: XRHandFrame) -> bool:
		if index >= pattern.size():
			return false
		var valid: bool = pattern[index]
		target.begin_capture(hand, index * step_usec, index)
		index += 1
		if valid:
			target.set_joint(
				XRHandTracker.HAND_JOINT_WRIST,
				Transform3D(Basis.IDENTITY, Vector3(0.5, 0, 0)),
				0.01, XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID)
			target.tracking_valid = true
			return true
		target.tracking_valid = false
		return false

func _test_confidence_gate(failures: Array[String]) -> void:
	var source := _ScriptedSource.new()
	# tracked, tracked, LOST, LOST, tracked
	source.pattern = [true, true, false, false, true]

	var gate := XRHandConfidenceGate.new(source)
	gate.hold_duration_sec = 0.25   # ~18 frames at 72 Hz, so both gaps are held
	var frame := XRHandFrame.new()

	if not gate.capture(1, 0, frame):
		failures.append("gate rejected a tracked frame")
	gate.capture(1, 0, frame)

	# During the dropout the gate must hold the last good pose, not vanish.
	if not gate.capture(1, 0, frame):
		failures.append("gate did not hold the last good frame through a dropout")
	if not frame.joint_transforms[XRHandTracker.HAND_JOINT_WRIST].origin.is_equal_approx(Vector3(0.5, 0, 0)):
		failures.append("held frame did not carry the last good pose")
	gate.capture(1, 0, frame)

	# Reacquisition must raise a discontinuity exactly once.
	gate.capture(1, 0, frame)
	if not gate.consume_discontinuity(1):
		failures.append("gate did not raise a discontinuity on reacquisition")
	if gate.consume_discontinuity(1):
		failures.append("discontinuity was not cleared after being consumed")

	# Past the hold window the gate must report invalid rather than hold forever.
	var expiring_source := _ScriptedSource.new()
	expiring_source.pattern = [true, false, false, false, false, false]
	var expiring := XRHandConfidenceGate.new(expiring_source)
	expiring.hold_duration_sec = 0.02   # ~1.4 frames at 72 Hz
	var expiring_frame := XRHandFrame.new()
	expiring.capture(1, 0, expiring_frame)
	expiring.capture(1, 0, expiring_frame)
	var still_valid := true
	for step in range(4):
		still_valid = expiring.capture(1, 0, expiring_frame)
	if still_valid:
		failures.append("gate held past hold_duration_sec instead of reporting invalid")
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd "C:/Users/davta/Repos/Godot_WebXR_gh/demo"
"C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe" \
  --headless --xr-mode off --path . \
  --script res://addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd
```

Expected: FAIL — `Identifier "XRHandConfidenceGate" not declared`.

- [ ] **Step 3: Implement the gate**

Create `addons/godot_xr_interaction_toolkit/runtime/input/filter/xr_hand_confidence_gate.gd`:

```gdscript
class_name XRHandConfidenceGate
extends XRHandPoseSource

## Tracking-loss policy in one place instead of the dozen ad-hoc
## has_tracking_data checks scattered across the suite.
##
## Sits UPSTREAM of the filter deliberately. Filtering first would make a
## dropout interpolate smoothly INTO the garbage pose and smoothly back out --
## a visible lurch in both directions, worse than the pop it replaced.

const _HANDS := 2

## How long a lost hand keeps reporting its last good pose before going invalid.
@export var hold_duration_sec := 0.25
## Below this many valid joints the hand counts as lost.
@export var min_valid_joints := 1

var _inner: XRHandPoseSource
var _raw := XRHandFrame.new()
var _last_good: Array[XRHandFrame] = []
var _has_good := [false, false]
var _lost_since_usec := [-1, -1]
var _discontinuity := [false, false]

func _init(inner: XRHandPoseSource = null) -> void:
	_inner = inner
	for hand in range(_HANDS):
		_last_good.append(XRHandFrame.new())

## True once per reacquisition. The filter resets on it so it snaps to the
## recovered pose rather than slewing from the stale held one.
func consume_discontinuity(hand: int) -> bool:
	if hand < 0 or hand >= _HANDS or not _discontinuity[hand]:
		return false
	_discontinuity[hand] = false
	return true

func capture(hand: int, timestamp_usec: int, target: XRHandFrame) -> bool:
	if _inner == null or hand < 0 or hand >= _HANDS:
		return false

	var tracked := _inner.capture(hand, timestamp_usec, _raw)
	if tracked and _raw.valid_joint_count < min_valid_joints:
		tracked = false

	var now := _raw.timestamp_usec if _raw.timestamp_usec > 0 else timestamp_usec

	if tracked:
		if not _has_good[hand] or _lost_since_usec[hand] >= 0:
			# First acquisition also counts: the filter has no history either way.
			_discontinuity[hand] = true
		_lost_since_usec[hand] = -1
		_has_good[hand] = true
		_raw.copy_into(_last_good[hand])
		_raw.copy_into(target)
		return true

	if not _has_good[hand]:
		_raw.copy_into(target)
		target.tracking_valid = false
		return false

	if _lost_since_usec[hand] < 0:
		_lost_since_usec[hand] = now

	var held_for := float(now - _lost_since_usec[hand]) / 1_000_000.0
	if held_for > hold_duration_sec:
		_raw.copy_into(target)
		target.tracking_valid = false
		return false

	_last_good[hand].copy_into(target)
	target.timestamp_usec = now
	return true
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd "C:/Users/davta/Repos/Godot_WebXR_gh/demo"
"C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe" \
  --headless --xr-mode off --path . \
  --script res://addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd
```

Expected: `XR hand conditioning: PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
cd "C:/Users/davta/Repos/godot-xr-suite"
git add addons/godot_xr_interaction_toolkit/
git commit -m "feat: add the hand confidence gate

Holds the last good pose for a bounded window on tracking loss, then reports
invalid, and raises a discontinuity on reacquisition so the filter resets
instead of slewing from a stale pose.

Sits upstream of the filter deliberately: filtering first would interpolate
smoothly into the garbage pose and smoothly back out, which is worse than the
pop it replaces. Replaces a dozen ad-hoc has_tracking_data checks."
```

---

### Task 8: Conditioned tracker publisher

**Files:**
- Create: `addons/godot_xr_interaction_toolkit/runtime/input/xr_conditioned_hand_publisher.gd`
- Modify: `addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd`

**Interfaces:**
- Consumes: `XRHandFrame`, `XRTrackerHandPoseSource`, `XRHandConfidenceGate`, `XRHandFilter`.
- Produces: `XRConditionedHandPublisher` — statics `TRACKER_NAMES: Array` (`[&"/user/hand_tracker/left_conditioned", &"/user/hand_tracker/right_conditioned"]`), `get_conditioned(hand: int) -> XRHandTracker`, `set_enabled(value: bool) -> void`, `is_enabled() -> bool`, `publish(hand: int) -> XRHandTracker`, `filter() -> XRHandFilter`.

- [ ] **Step 1: Write the failing test**

Add to `_init`:

```gdscript
	_test_publisher(failures)
```

and append:

```gdscript
func _test_publisher(failures: Array[String]) -> void:
	var frame := XRHandFrame.new()
	frame.begin_capture(1, 12345, 1)
	frame.set_joint(
		XRHandTracker.HAND_JOINT_WRIST,
		Transform3D(Basis.IDENTITY, Vector3(0.25, 0.5, 0.75)),
		0.011,
		XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID | XRHandTracker.HAND_JOINT_FLAG_ORIENTATION_VALID)
	frame.tracking_valid = true

	var tracker := XRHandTracker.new()
	XRConditionedHandPublisher.write_frame_to_tracker(frame, tracker, XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED)

	if not tracker.has_tracking_data:
		failures.append("publisher did not mark the shadow tracker as tracking")
	var origin := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST).origin
	if not origin.is_equal_approx(Vector3(0.25, 0.5, 0.75)):
		failures.append("publisher wrote the wrong wrist origin: %s" % str(origin))
	if not is_equal_approx(tracker.get_hand_joint_radius(XRHandTracker.HAND_JOINT_WRIST), 0.011):
		failures.append("publisher did not carry the joint radius through")
	if (tracker.get_hand_joint_flags(XRHandTracker.HAND_JOINT_WRIST) & XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID) == 0:
		failures.append("publisher did not carry joint flags through")
	# hand_tracking_source must survive, or the modality manager stops working.
	if tracker.hand_tracking_source != XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED:
		failures.append("publisher did not carry hand_tracking_source through")

	# An invalid frame must clear the tracking flag rather than freeze.
	var lost := XRHandFrame.new()
	lost.begin_capture(1, 12400, 2)
	lost.tracking_valid = false
	XRConditionedHandPublisher.write_frame_to_tracker(lost, tracker, XRHandTracker.HAND_TRACKING_SOURCE_UNKNOWN)
	if tracker.has_tracking_data:
		failures.append("publisher left has_tracking_data set after an invalid frame")
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd "C:/Users/davta/Repos/Godot_WebXR_gh/demo"
"C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe" \
  --headless --xr-mode off --path . \
  --script res://addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd
```

Expected: FAIL — `Identifier "XRConditionedHandPublisher" not declared`.

- [ ] **Step 3: Implement the publisher**

Create `addons/godot_xr_interaction_toolkit/runtime/input/xr_conditioned_hand_publisher.gd`:

```gdscript
class_name XRConditionedHandPublisher
extends RefCounted

## Publishes conditioned hand data as a shadow XRHandTracker per hand.
##
## Consumers that speak XRHandTracker keep their exact type and API and simply
## receive better data. The pattern is already proven in this codebase by
## xr_simulator.gd, which constructs and populates XRHandTracker instances.
##
## The chain runs lazily on first access per rendered frame. That is correct
## rather than merely convenient: XRServer updates trackers pre-render, so hand
## data genuinely does not change between physics ticks inside one render
## frame. It also means staleness is structurally impossible -- access is what
## triggers the run -- and it needs no autoload, node, or scene setup.

const TRACKER_NAMES := [
	&"/user/hand_tracker/left_conditioned",
	&"/user/hand_tracker/right_conditioned",
]
const _RAW_NAMES := [
	&"/user/hand_tracker/left",
	&"/user/hand_tracker/right",
]
const _HANDS := 2

static var _enabled := true
static var _trackers := [null, null]
static var _frames := [null, null]
static var _gate: XRHandConfidenceGate = null
static var _filter: XRHandFilter = null
static var _published_frame := [-1, -1]

static func set_enabled(value: bool) -> void:
	_enabled = value

static func is_enabled() -> bool:
	return _enabled

static func filter() -> XRHandFilter:
	_ensure_chain()
	return _filter

## Runs the chain at most once per rendered frame per hand and returns the
## shadow tracker, or null when nothing is being tracked.
static func get_conditioned(hand: int) -> XRHandTracker:
	if not _enabled or hand < 0 or hand >= _HANDS:
		return null
	var frame_number := Engine.get_process_frames()
	if _published_frame[hand] == frame_number:
		return _trackers[hand]
	_published_frame[hand] = frame_number
	return publish(hand)

static func publish(hand: int) -> XRHandTracker:
	_ensure_chain()
	if _frames[hand] == null:
		_frames[hand] = XRHandFrame.new()
	var frame: XRHandFrame = _frames[hand]

	# The modality manager is the authority on controller-driven hands;
	# tracker.hand_tracking_source is not reliable across runtimes. Resolve it
	# softly by group so the toolkit gains no dependency on godot_webxr_kit.
	_filter.set_controller_source(hand, _is_controller_modality(hand))

	# One call drives the whole chain: the filter pulls from the gate, which
	# pulls from the raw tracker source. The filter consumes the gate's
	# discontinuity internally, so the reset lands before the frame is
	# conditioned rather than after.
	var tracked := _filter.capture(hand, Time.get_ticks_usec(), frame)

	var tracker := _ensure_tracker(hand)
	write_frame_to_tracker(frame, tracker, _raw_source(hand))
	return tracker if tracked else null

## Copies a conditioned frame into a tracker. Static and dependency-free so it
## can be unit-tested without touching XRServer.
static func write_frame_to_tracker(frame: XRHandFrame, tracker: XRHandTracker, source: int) -> void:
	tracker.hand_tracking_source = source
	if not frame.tracking_valid:
		tracker.has_tracking_data = false
		return
	for joint in range(XRHandFrame.JOINT_COUNT):
		tracker.set_hand_joint_transform(joint, frame.joint_transforms[joint])
		tracker.set_hand_joint_radius(joint, frame.joint_radii[joint])
		tracker.set_hand_joint_flags(joint, frame.joint_flags[joint])
	tracker.has_tracking_data = true

static func _ensure_chain() -> void:
	if _gate != null:
		return
	# raw tracker source -> confidence gate -> filter. Gate first: filtering a
	# dropout would interpolate smoothly into the garbage pose and back out.
	_gate = XRHandConfidenceGate.new(XRTrackerHandPoseSource.new())
	_filter = XRHandFilter.new(_gate)

static func _ensure_tracker(hand: int) -> XRHandTracker:
	if _trackers[hand] != null:
		return _trackers[hand]
	var tracker := XRHandTracker.new()
	tracker.hand = XRPositionalTracker.TRACKER_HAND_LEFT if hand == 0 else XRPositionalTracker.TRACKER_HAND_RIGHT
	XRServer.add_tracker(tracker)
	_trackers[hand] = tracker
	return tracker

static func _raw_source(hand: int) -> int:
	var raw := XRServer.get_tracker(_RAW_NAMES[hand]) as XRHandTracker
	return raw.hand_tracking_source if raw else XRHandTracker.HAND_TRACKING_SOURCE_UNKNOWN

static func _is_controller_modality(hand: int) -> bool:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null:
		return false
	var manager := loop.get_first_node_in_group("xr_input_modality_manager")
	if manager and manager.has_method("get_modality"):
		return int(manager.get_modality(hand)) == 1  # Modality.CONTROLLER
	return _raw_source(hand) == XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER
```

The chain composes as `XRTrackerHandPoseSource → XRHandConfidenceGate → XRHandFilter`, each a plain `XRHandPoseSource` decorator, driven by one `capture` call. The discontinuity travels through the generic `consume_discontinuity` hook added in Task 1, so no decorator needs to know the concrete type of the one beneath it.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd "C:/Users/davta/Repos/Godot_WebXR_gh/demo"
"C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe" \
  --headless --xr-mode off --path . \
  --script res://addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd
```

Expected: `XR hand conditioning: PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
cd "C:/Users/davta/Repos/godot-xr-suite"
git add addons/godot_xr_interaction_toolkit/
git commit -m "feat: publish conditioned hands as shadow XRHandTrackers

Consumers that speak XRHandTracker keep their type and API and receive
conditioned data. Runs the chain lazily once per rendered frame, which is
correct because XRServer updates trackers pre-render, and makes staleness
structurally impossible since access is what triggers the run.

Carries hand_tracking_source through so the modality manager keeps working,
and resolves controller modality by group lookup with a fallback so the
toolkit gains no dependency on godot_webxr_kit."
```

---

### Task 9: Resolver integration, call-site unification, A/B toggle, manifest

Makes conditioning actually reach consumers.

**Files:**
- Modify: `addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd`
- Modify: `addons/godot_xr_interaction_toolkit/runtime/xr_poke_interactor.gd:112,130`
- Modify: `addons/godot_xr_interaction_toolkit/runtime/xr_locomotion.gd:282`
- Modify: `addons/godot_xr_hands/runtime/xr_hand_mesh_visualizer.gd:131`
- Modify: `addons/godot_xr_hands/runtime/gesture_studio/xr_gesture_ghost_hand.gd:54`
- Modify: `addons/godot_xr_hands/runtime/gesture_studio/xr_gesture_recognizer.gd:66`
- Modify: `addons/godot_xr_hands/runtime/gesture_studio/xr_gesture_recorder.gd:79,142`
- Modify: `addons/godot_xr_interaction_toolkit/xr_package.cfg`

**Interfaces:**
- Consumes: `XRConditionedHandPublisher`.
- Produces: `XRHandTrackerResolver.set_conditioned(value: bool)`, `XRHandTrackerResolver.is_conditioned() -> bool`; `get_tracker(hand_id)` returns the conditioned tracker when available.

- [ ] **Step 1: Add conditioned mode to the resolver**

In `addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd`, add after the existing `static var _cache_frame := -1`:

```gdscript
## Conditioning is on by default. Flip at runtime for A/B comparison.
static var _conditioned := true

static func set_conditioned(value: bool) -> void:
	_conditioned = value
	_cache_frame = -1  # drop the frame cache so the switch takes effect now

static func is_conditioned() -> bool:
	return _conditioned
```

and replace the body of `get_tracker` with:

```gdscript
static func get_tracker(hand_id: int) -> XRHandTracker:
	if not _valid_hand(hand_id):
		return null

	var frame := Engine.get_process_frames()
	if _cache_frame != frame:
		_cache_frame = frame
		_cache.clear()
	if _cache.has(hand_id):
		return _cache[hand_id]

	var tracker: XRHandTracker = null
	if _conditioned:
		tracker = XRConditionedHandPublisher.get_conditioned(hand_id)
	if tracker == null:
		tracker = _resolve_tracker(hand_id)
	_cache[hand_id] = tracker
	return tracker
```

`_resolve_tracker` is unchanged and remains the raw path — the publisher consumes it through `XRTrackerHandPoseSource`, which calls it.

- [ ] **Step 2: Verify no infinite recursion**

The publisher's chain calls `XRTrackerHandPoseSource.capture`, which calls `XRHandTrackerResolver.get_tracker` — which would re-enter the publisher. Break the loop by having the pose source use the raw path directly.

In `addons/godot_xr_interaction_toolkit/runtime/input/xr_tracker_hand_pose_source.gd`, replace:

```gdscript
	var tracker := XRHandTrackerResolver.get_tracker(hand)
```

with:

```gdscript
	# Deliberately the RAW path: this source feeds the conditioning chain, and
	# get_tracker returns the conditioned result. Calling it here would make
	# the filter consume its own output.
	var tracker := XRHandTrackerResolver.resolve_raw(hand)
```

and in the resolver, rename `_resolve_tracker` to a public `resolve_raw` (updating its one internal call site):

```gdscript
## The unconditioned tracker, scored and resolved. Used by the conditioning
## chain itself; everything else should call get_tracker.
static func resolve_raw(hand_id: int) -> XRHandTracker:
```

- [ ] **Step 3: Unify the bypassing call sites**

Replace every raw hand-tracker lookup listed below with `XRHandTrackerResolver.get_tracker(hand)`. Each file already has, or needs, the preload:

```gdscript
const XRHandTrackerResolver := preload("res://addons/godot_xr_interaction_toolkit/runtime/input/xr_hand_tracker_resolver.gd")
```

| File | Line | Replace |
|---|---|---|
| `godot_xr_interaction_toolkit/runtime/xr_poke_interactor.gd` | 112 | `XRServer.get_tracker(_HAND_TRACKER_NAMES[hand]) as XRHandTracker` |
| `godot_xr_interaction_toolkit/runtime/xr_poke_interactor.gd` | 130 | same |
| `godot_xr_interaction_toolkit/runtime/xr_locomotion.gd` | 282 | `XRServer.get_tracker("/user/hand_tracker/%s" % ...) as XRHandTracker` |
| `godot_xr_hands/runtime/xr_hand_mesh_visualizer.gd` | 131 | `XRServer.get_tracker(_TRACKER_NAMES[hand]) as XRHandTracker` |
| `godot_xr_hands/runtime/gesture_studio/xr_gesture_ghost_hand.gd` | 54 | `XRServer.get_tracker("/user/hand_tracker/%s" % ...) as XRHandTracker` |
| `godot_xr_hands/runtime/gesture_studio/xr_gesture_recognizer.gd` | 66 | same |
| `godot_xr_hands/runtime/gesture_studio/xr_gesture_recorder.gd` | 79 | same |
| `godot_xr_hands/runtime/gesture_studio/xr_gesture_recorder.gd` | 142 | same |

Do **not** change `godot_webxr_kit/runtime/xr_input_modality_manager.gd` — it must observe true hardware state, and it is the authority the filter asks. Do **not** change `godot_webxr_kit/runtime/xr_simulator.gd` — it *produces* trackers.

Where a local `_HAND_TRACKER_NAMES` / `_TRACKER_NAMES` constant becomes unused after the edit, delete it.

- [ ] **Step 4: Verify the unification and the DAG**

```bash
cd "C:/Users/davta/Repos/godot-xr-suite"
echo "--- remaining raw hand-tracker lookups (expect only modality manager + simulator) ---"
grep -rn "XRServer.get_tracker(.*hand_tracker" addons --include=*.gd
echo "--- toolkit must not PRELOAD from higher addons (expect empty) ---"
grep -rnE "preload\(\"res://addons/(godot_xr_hands|godot_webxr_kit)" addons/godot_xr_interaction_toolkit/runtime/ --include=*.gd
```

Expected: the first prints only `xr_input_modality_manager.gd` and `xr_simulator.gd`; the second prints nothing.

The second grep deliberately targets `preload(` and not the bare addon name. The toolkit legitimately holds several *path strings* into `godot_xr_hands` (`xr_grab_point.gd`, `xr_hand_activator.gd`, `xr_microgesture_locomotion_driver.gd`) which it feeds to guarded `load()` / `ResourceLoader.exists()` and which no-op when that addon is absent. Those are soft dependencies and are fine. Only `preload` is resolved at parse time and would hard-break a standalone toolkit install.

- [ ] **Step 5: Declare the new capability in the manifest**

In `addons/godot_xr_interaction_toolkit/xr_package.cfg`, change:

```
provides=PackedStringArray("interactions", "locomotion", "xr_ui", "authoring")
```

to:

```
provides=PackedStringArray("interactions", "locomotion", "xr_ui", "authoring", "hand_input")
```

Leave `requires=PackedStringArray()` and `layer="foundation"` untouched — keeping them true is why the acquisition layer moved down.

- [ ] **Step 6: Run the full test suite — both test files**

```bash
cd "C:/Users/davta/Repos/Godot_WebXR_gh/demo"
G="C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe"
"$G" --headless --xr-mode off --path . --script res://addons/godot_xr_interaction_toolkit/tests/test_hand_conditioning.gd
"$G" --headless --xr-mode off --path . --script res://addons/godot_xr_hands/tests/test_gesture_foundation.gd
```

Expected: `XR hand conditioning: PASS` and `XR gesture foundation: PASS`, both exit 0.

- [ ] **Step 7: Boot the demo headless to catch scene-level breakage**

```bash
cd "C:/Users/davta/Repos/Godot_WebXR_gh/demo"
"C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe" \
  --headless --xr-mode off --path . --quit-after 120
```

Expected: exit 0, no `SCRIPT ERROR` lines mentioning the hand or conditioning classes.

- [ ] **Step 8: Commit**

```bash
cd "C:/Users/davta/Repos/godot-xr-suite"
git add -A
git commit -m "feat: route every hand-tracker consumer through conditioning

The resolver now returns the conditioned shadow tracker, falling back to raw
when none is live, with set_conditioned() as a runtime A/B switch.

Unifies the eight call sites that bypassed the resolver with raw
XRServer.get_tracker -- poke, locomotion, the mesh visualizer, and the three
gesture-studio files. Leaving them raw would have made fidelity inconsistent
across the suite, which reads worse than uniform noise.

XRTrackerHandPoseSource now calls resolve_raw explicitly so the chain cannot
consume its own output. Adds hand_input to the toolkit's provides list."
```

---

### Task 10: Baseline, tuning, and the on-device earn-in

No new code. This is where the spec's acceptance criteria are actually met, and it is a **gate** — the work is not done until it passes.

**Files:**
- Create: `addons/godot_xr_interaction_toolkit/tools/trace/measure_traces.gd`
- Create: `docs/hand-conditioning-results.md`

**Interfaces:**
- Consumes: everything above.
- Produces: recorded traces, measured numbers, tuned default parameters in `xr_hand_filter.gd`, and a results document.

- [ ] **Step 1: Write the measurement harness**

Create `addons/godot_xr_interaction_toolkit/tools/trace/measure_traces.gd`:

```gdscript
extends SceneTree

## Replays a trace raw and conditioned, and prints the three acceptance numbers.
## Run: godot --headless --path <demo> --script res://addons/godot_xr_interaction_toolkit/tools/trace/measure_traces.gd -- <trace.res>

const _WRIST := XRHandTracker.HAND_JOINT_WRIST
const _TIP := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("usage: ... -- <res://path/to/trace.res>")
		quit(1)
		return

	var trace := XRHandTrace.load_trace(args[0])
	if trace == null:
		push_error("could not load %s" % args[0])
		quit(1)
		return

	var raw_wrist := _replay(trace, false, _WRIST)
	var conditioned_wrist := _replay(trace, true, _WRIST)
	var raw_tip := _replay(trace, false, _TIP)
	var conditioned_tip := _replay(trace, true, _TIP)

	var dt := _mean_dt(trace)
	print("frames                : %d" % trace.size())
	print("mean dt               : %.4f s (%.1f Hz)" % [dt, 1.0 / maxf(dt, 0.0001)])
	print("wrist jitter raw      : %.6f m" % XRHandTraceMetrics.rest_jitter(raw_wrist))
	print("wrist jitter cond     : %.6f m" % XRHandTraceMetrics.rest_jitter(conditioned_wrist))
	print("tip   jitter raw      : %.6f m" % XRHandTraceMetrics.rest_jitter(raw_tip))
	print("tip   jitter cond     : %.6f m" % XRHandTraceMetrics.rest_jitter(conditioned_tip))
	print("wrist lag             : %.4f s" % XRHandTraceMetrics.motion_lag_seconds(raw_wrist, conditioned_wrist, dt, 12))
	print("tip   lag             : %.4f s" % XRHandTraceMetrics.motion_lag_seconds(raw_tip, conditioned_tip, dt, 12))
	print("tip bone dev raw      : %.6f m" % XRHandTraceMetrics.bone_length_deviation(trace.frames, _TIP))
	print("tip bone dev cond     : %.6f m" % XRHandTraceMetrics.bone_length_deviation(_conditioned_frames(trace), _TIP))
	quit(0)

func _replay(trace: XRHandTrace, conditioned: bool, joint: int) -> PackedVector3Array:
	var player := XRHandTracePlayer.new(trace)
	var source: XRHandPoseSource = XRHandFilter.new(player) if conditioned else player
	var frame := XRHandFrame.new()
	var samples := PackedVector3Array()
	for step in range(trace.size()):
		if source.capture(1, 0, frame):
			samples.append(frame.joint_transforms[joint].origin)
	return samples

func _conditioned_frames(trace: XRHandTrace) -> Array:
	var filter := XRHandFilter.new(XRHandTracePlayer.new(trace))
	var frame := XRHandFrame.new()
	var out: Array = []
	for step in range(trace.size()):
		if not filter.capture(1, 0, frame):
			continue
		var transforms: Array[Transform3D] = []
		transforms.resize(XRHandFrame.JOINT_COUNT)
		for j in range(XRHandFrame.JOINT_COUNT):
			transforms[j] = frame.joint_transforms[j]
		out.append({"transforms": transforms, "flags": frame.joint_flags.duplicate()})
	return out

func _mean_dt(trace: XRHandTrace) -> float:
	if trace.size() < 2:
		return 1.0 / 72.0
	var first := int(trace.frames[0]["timestamp_usec"])
	var last := int(trace.frames[trace.size() - 1]["timestamp_usec"])
	return float(last - first) / 1_000_000.0 / float(trace.size() - 1)
```

- [ ] **Step 2: Record the baseline traces on-device**

Add an `XRHandTraceRecorder` node to a demo scene with `auto_start = true`, deploy, and record three traces per hand:

1. **rest** — hold the hand still in view for ~10 seconds
2. **motion** — sweep the hand briskly back and forth for ~10 seconds
3. **dropout** — move the hand out of the tracking volume and back, twice

Save each, then pull them off the device from
`%APPDATA%/Godot/app_userdata/<project>/hand_traces/`.

These are the baseline. Record them **before** touching any parameters.

- [ ] **Step 3: Measure the baseline and tune**

```bash
cd "C:/Users/davta/Repos/Godot_WebXR_gh/demo"
"C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe" \
  --headless --xr-mode off --path . \
  --script res://addons/godot_xr_interaction_toolkit/tools/trace/measure_traces.gd \
  -- res://hand_traces/rest.res
```

Sweep `position_min_cutoff` and `position_beta` in `xr_hand_filter.gd` against the rest and motion traces until:

- rest jitter falls **>= 50%** versus raw
- motion lag stays **<= 13.9 ms** (one frame at 72 Hz)
- tip bone deviation stays **<= 0.0005 m**

Lower `min_cutoff` buys stillness and costs lag; higher `beta` buys back responsiveness during motion. Tune `min_cutoff` on the rest trace first, then `beta` on the motion trace.

Keep the filter gentle enough not to disturb the gesture recognizers, which retain their own fixed-alpha smoothing by design — see the spec's *Decisions and their consequences*. Record how much headroom you find; it determines whether the follow-up pass to remove the redundant layer is worth doing.

- [ ] **Step 4: Measure the frame cost on the web target**

Export the demo to web and measure the per-frame cost of `XRConditionedHandPublisher.publish` in the browser. This is the number that decides whether the design fits, and the spec deliberately claims none in advance.

Web is the constrained target and the one where GDScript is weakest, so measure there first — not on desktop.

**Contingent optimization, only if this measurement demands it.** The spec lists filtering only the joints currently consumed (roughly 8 of 26 while the mesh hand is hidden, re-seeding on show) as an available ~3x saving in gesture-only scenes. It is deliberately *not* built above, because it adds a consumer-tracking mechanism whose complexity is only justified by a real number. Build it here if the measurement says the budget does not fit; skip it if it does. Either way, record the decision and the number in Step 6.

Do **not** jump to GDExtension if it is slow: that means adopting the `dlink` export template and its build, size, and deployment costs, and needs its own justification. Reducing scope comes first.

- [ ] **Step 5: On-device earn-in — the gate**

A/B in-headset with `XRHandTrackerResolver.set_conditioned(...)` on the gesture, poke, and grab demos.

**A/B on the WebGL path, not WebGPU.** Chrome's `XRGPUBinding` performs a full-resolution copy per frame that defeats reprojection on some devices; measuring perceived lag on the WebGPU path would misattribute platform latency to the filter.

Per project precedent — a better-architected microgesture engine was rolled back for being less reliable on-device — **this gate overrides the offline metrics.** If it does not feel better in the headset, it does not ship, whatever Step 3 says.

Check specifically that the prior on-device-tuned behaviour listed in the spec's *Prior art* table has not regressed: hand ray stability, grip pose placement, poke marker behaviour, throw feel, and dial stability.

- [ ] **Step 6: Write up the results**

Create `docs/hand-conditioning-results.md` recording: the baseline numbers, the chosen parameters and why, the measured web frame cost, the recognizer headroom found, and the on-device verdict per demo. Report jitter and lag **together** — quoting only jitter would make any filter look good.

- [ ] **Step 7: Commit**

```bash
cd "C:/Users/davta/Repos/godot-xr-suite"
git add -A
git commit -m "perf: tune conditioning against recorded traces and record results

Parameters chosen from recorded rest/motion/dropout traces rather than guessed,
with jitter, lag, bone deviation, and measured web frame cost written up in
docs/hand-conditioning-results.md.

Verified on-device on the WebGL path per the earn-in rule."
```

---

## Deferred to later specs

Do not build these here. Listed so their absence is deliberate rather than forgotten: synthetic/display hand (Spec 2), grab pose scoring and surfaces (Spec 3), tweened grab movement (Spec 3), RANSAC throw (Spec 4), poke fidelity (Spec 5), ray and cursor (Spec 6), locomotion gate (Spec 7).
