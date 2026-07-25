# Interaction Arbitration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One explicit interaction mode per hand (NONE / NEAR / FAR / TELEPORT), replacing the scattered per-interactor suppression booleans — so "when can I do each action" is a single testable rule, and the teleport arc can no longer outlive its own state.

**Architecture:** An opt-in `XRInteractionArbiter` node in the rig, found by group. Its transition table is a static pure function so hysteresis and exclusivity are provable headless. Interactors consult it when present and fall back to today's logic when absent, so no existing scene changes behaviour.

**Tech Stack:** GDScript, Godot 4.8.

## Global Constraints

- Every Godot invocation MUST include `--headless --xr-mode off` or it hangs forever printing nothing. Test project: `C:/Users/davta/Repos/Godot_WebXR_gh/demo` (its `addons/` symlink into this tree). Binary: `C:/Users/davta/Documents/Godot_WebGPU/bin/godot.windows.editor.x86_64.console.exe`.
- A new `class_name` is not resolvable until the project rescans: run `<godot> --headless --xr-mode off --path . --import` once after adding one, or tests fail with "Could not find type".
- MUTATION-TEST every new assertion (mutate implementation → suite FAILS → revert → PASSES). **A surviving mutation is missing coverage, never acceptance.** This work has hit "fixture too benign to fail" eight times; a static-distance fixture CANNOT exercise hysteresis, which is the property most likely to be wrong.
- Licensing: implement from `docs/interaction-arbitration-design.md` only. No ISDK code read for implementation, copied, or adapted. Meta constants are sanity checks, never shipped values.
- BACK-COMPAT IS A HARD REQUIREMENT: with no arbiter node in a scene, every interactor must behave exactly as today. No existing suppression export may be removed or repurposed.
- Do not modify `xr_thumb_microgesture_recognizer.gd` or any recognizer thresholds (David's standing rule: working recognizers are protected; platform/behaviour work is additive only).
- `xr.interaction` stays `layer="foundation"` with `requires=[]` and standalone-installable.
- Suites that must stay green: `test_grab_feel.gd`, `test_hand_conditioning.gd`, `test_gesture_foundation.gd`; plus demo boot (`--quit-after 120`, zero SCRIPT ERROR).
- Branch: create `agent/interaction-arbitration` off the current `agent/grab-feel` tip. Ledger: `.superpowers/sdd/progress.md`.

---

### Task 1: The arbiter — transition table, node, and tests

**Files:**
- Create: `addons/godot_xr_interaction_toolkit/runtime/xr_interaction_arbiter.gd`
- Create: `addons/godot_xr_interaction_toolkit/tests/test_interaction_arbiter.gd`

**Interfaces:**
- Produces: `class_name XRInteractionArbiter extends Node`, group `xr_interaction_arbiter`.
- Produces: `enum Mode { NONE, NEAR, FAR, TELEPORT }`.
- Produces: `static func resolve_mode(previous: Mode, hand_tracked: bool, near_candidate: bool, teleport_active: bool, time_in_mode: float, minimum_dwell_sec: float) -> Mode` — the whole rule, pure.
- Produces: `func mode_for(hand: int) -> Mode` and `func is_mode_active(hand: int, mode: Mode) -> bool` (instance API interactors consult in Task 2).
- Produces exports: `near_release_dwell_sec := 0.12`, `enabled := true`.

**Design note the implementer must honour:** proximity is NOT a new physics query. `XRDirectInteractor` already runs a `hover_radius` sphere query at the grip pose every frame; the arbiter reads whether that interactor currently has a hover candidate. Hysteresis therefore lives in the DWELL (time), not in a second radius — the direct interactor's own enter/exit radius is already tuned and must not be duplicated or second-guessed.

- [ ] **Step 1: Write the failing tests.** Create `tests/test_interaction_arbiter.gd` following `test_grab_feel.gd`'s SceneTree pattern (`_init` collects failures, prints `XR interaction arbiter: PASS/FAIL`, exits 0/1):

```gdscript
extends SceneTree

const Arbiter := preload("res://addons/godot_xr_interaction_toolkit/runtime/xr_interaction_arbiter.gd")

func _init() -> void:
	var failures: Array[String] = []
	_test_teleport_is_exclusive(failures)
	_test_proximity_selects_near_or_far(failures)
	_test_dwell_is_hysteresis(failures)
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
	# present -- reaching toward a table must not veto an intentional teleport.
	for previous in [Arbiter.Mode.NONE, Arbiter.Mode.NEAR, Arbiter.Mode.FAR, Arbiter.Mode.TELEPORT]:
		var mode: int = Arbiter.resolve_mode(previous, true, true, true, 10.0, 0.12)
		if mode != Arbiter.Mode.TELEPORT:
			failures.append("teleport must win from mode %d, got %d" % [previous, mode])
	# And it must be LEFT the moment it ends -- the stuck-arc bug is exactly a
	# state that is entered and never exited.
	var after: int = Arbiter.resolve_mode(Arbiter.Mode.TELEPORT, true, false, false, 10.0, 0.12)
	if after == Arbiter.Mode.TELEPORT:
		failures.append("teleport must not persist once teleport_active goes false")

func _test_proximity_selects_near_or_far(failures: Array[String]) -> void:
	if Arbiter.resolve_mode(Arbiter.Mode.FAR, true, true, false, 10.0, 0.12) != Arbiter.Mode.NEAR:
		failures.append("a near candidate must select NEAR")
	if Arbiter.resolve_mode(Arbiter.Mode.NEAR, true, false, false, 10.0, 0.12) != Arbiter.Mode.FAR:
		failures.append("no near candidate (past dwell) must select FAR")

func _test_dwell_is_hysteresis(failures: Array[String]) -> void:
	# The hysteresis: NEAR is not abandoned the instant the candidate vanishes.
	# A hand resting at the edge of a table makes the candidate flicker frame to
	# frame; without the dwell the ray strobes. Time is the damping term.
	if Arbiter.resolve_mode(Arbiter.Mode.NEAR, true, false, false, 0.05, 0.12) != Arbiter.Mode.NEAR:
		failures.append("NEAR must be held through a brief candidate dropout (dwell not elapsed)")
	if Arbiter.resolve_mode(Arbiter.Mode.NEAR, true, false, false, 0.20, 0.12) != Arbiter.Mode.FAR:
		failures.append("NEAR must release once the dwell has elapsed")
	# Entering NEAR is immediate -- latency on the way IN reads as unresponsive.
	if Arbiter.resolve_mode(Arbiter.Mode.FAR, true, true, false, 0.0, 0.12) != Arbiter.Mode.NEAR:
		failures.append("entering NEAR must not wait for a dwell")

func _test_tracking_loss(failures: Array[String]) -> void:
	if Arbiter.resolve_mode(Arbiter.Mode.NEAR, false, true, false, 10.0, 0.12) != Arbiter.Mode.NONE:
		failures.append("an untracked hand must resolve to NONE regardless of candidates")
	if Arbiter.resolve_mode(Arbiter.Mode.NONE, true, false, false, 10.0, 0.12) != Arbiter.Mode.FAR:
		failures.append("recovery from NONE must resolve normally")
	# Tracking loss beats teleport too: no hand, no aiming.
	if Arbiter.resolve_mode(Arbiter.Mode.TELEPORT, false, false, true, 10.0, 0.12) != Arbiter.Mode.NONE:
		failures.append("an untracked hand must leave TELEPORT")
```

- [ ] **Step 2: Run — expect FAIL** (file does not exist):
`cd C:/Users/davta/Repos/Godot_WebXR_gh/demo && <godot> --headless --xr-mode off --path . --script res://addons/godot_xr_interaction_toolkit/tests/test_interaction_arbiter.gd`

- [ ] **Step 3: Implement the arbiter.** Write `xr_interaction_arbiter.gd` with the enum, the static `resolve_mode` satisfying the tests above, per-hand state (current mode + time in mode) advanced in `_process`, and `mode_for` / `is_mode_active`. Resolve the direct interactor and teleport state by group/path the way the codebase already does (see `_is_controller_modality` in `xr_poke_interactor.gd` for the group-lookup idiom, and `XRLocomotion.is_aiming()` for teleport state). Add `--import` before re-running tests, since this adds a `class_name`.

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Mutations, each FAIL-then-PASS with `git status` clean after:** (a) teleport checked after proximity instead of first → exclusivity tests fail; (b) dwell ignored (release NEAR immediately) → hysteresis test fails; (c) dwell applied on ENTRY as well → entering-NEAR test fails; (d) tracking check dropped → tracking-loss tests fail.

- [ ] **Step 6: Commit** `feat: interaction arbiter — one explicit mode per hand`.

---

### Task 2: Interactors consult the arbiter, with back-compat proven

**Files:**
- Modify: `addons/godot_xr_interaction_toolkit/runtime/xr_ray_interactor.gd` (its `_is_suppressed_by_linked_interactor` path)
- Modify: `addons/godot_xr_interaction_toolkit/runtime/xr_direct_interactor.gd` and `xr_poke_interactor.gd` if they need to stand down in TELEPORT
- Test: `addons/godot_xr_interaction_toolkit/tests/test_interaction_arbiter.gd`

**Interfaces:**
- Consumes: `XRInteractionArbiter.mode_for` / `is_mode_active` (Task 1).
- Produces: a shared lookup helper (place it on the arbiter as a static, e.g. `static func find_in_tree(node: Node) -> XRInteractionArbiter`) so three interactors do not each grow their own discovery code.

- [ ] **Step 1: Write the failing back-compat test FIRST — it is the most important assertion in this plan.** In a scene with NO arbiter, an interactor's suppression decision must be identical to today's. Build a small scene tree with a ray interactor and no arbiter, drive the suppression predicate directly, and assert it matches the pre-change behaviour for: nothing active, poke active, teleport active, linked-hover active. If any of these cannot be driven without a live XR rig, say so in the report and cover what can be — do NOT fabricate coverage for what cannot.

- [ ] **Step 2: Run — expect FAIL** (helper does not exist).

- [ ] **Step 3: Implement the consult.** Where an interactor currently computes suppression, first look for an arbiter; if found, defer entirely to `is_mode_active(hand, MY_MODE)`; if not, run the existing logic unchanged. The ray interactor is FAR; the direct and poke interactors are NEAR. Keep every existing export in place and functional for the no-arbiter path.

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Mutations:** (a) arbiter consulted but result ignored → an arbiter-present test fails; (b) fall back to arbiter-style behaviour when NO arbiter is present → the back-compat test fails. Mutation (b) is the one that matters: if it survives, the back-compat test is not actually testing back-compat.

- [ ] **Step 6:** All four suites green (three existing plus the arbiter suite) + demo boot clean. **Commit** `feat: interactors defer to the arbiter when one is present`.

---

### Task 3: Teleport owns its exit, plus the earn-in scene

**Files:**
- Modify: `addons/godot_xr_interaction_toolkit/runtime/xr_locomotion.gd`
- Modify: `C:/Users/davta/Repos/Godot_WebXR_gh/demo/scripts/feel_check.gd` (other repo — commit separately there)
- Test: `addons/godot_xr_interaction_toolkit/tests/test_interaction_arbiter.gd`

- [ ] **Step 1: Failing test for the reported bug.** `XRLocomotion` already times out an intent aim after `_INTENT_TIMEOUT = 3.0` and clears via `cancel_teleport`. Write a test proving the arbiter leaves TELEPORT when locomotion stops aiming — by any exit route: commit, cancel, timeout, and tracking loss. Drive `XRLocomotion`'s intent API directly rather than simulating a microgesture.

- [ ] **Step 2: Run — expect FAIL. Step 3: Implement** whatever wiring is missing so the arbiter observes locomotion's aim state. Do NOT alter locomotion's existing timeout or intent semantics — this task observes them, it does not retune them.

- [ ] **Step 4: Run — expect PASS. Step 5: Mutation:** make the arbiter latch TELEPORT once entered → the exit tests must fail.

- [ ] **Step 6: Add the earn-in dial.** In the demo repo, add one poke button to `feel_check.gd` toggling the arbiter's `enabled`, with a label showing the live per-hand mode (e.g. `L: NEAR  R: FAR`) so the state machine is legible in-headset rather than inferred. Keep the existing microgesture A/B button. Verify the scene boots headless with zero SCRIPT ERROR.

- [ ] **Step 7:** All four suites + demo boot green. Ledger entry. **Commit** in each repo separately.

---

### Task 4: On-device earn-in (DAVID IN HEADSET — gate)

No code. Launch `res://scenes/feel_check.tscn` over Quest Link (stock binary `C:/Users/davta/Documents/Godot R&D/_tools/Godot-4.8-dev2/Godot_v4.8-dev2_win64_console.exe`; `xr/shaders/enabled=true` is already set; retry-launcher in the session scratchpad).

Checklist: the far ray disappears as a hand approaches a grabbable and returns on withdrawal, WITHOUT flicker at the boundary (tune `near_release_dwell_sec` live if it strobes or feels sticky); teleport aiming hides ray and poke visuals and restores them exactly once on commit and on cancel; the arc never persists after the gesture ends — the reported bug, specifically hunted; grab, poke and throw all still feel as they did after the last session; the arbiter-off A/B feels no worse than arbiter-on. Also settle the still-open microgesture raw-vs-conditioned question while in there.

Record the verdict and every tuned value in the ledger and in `docs/interaction-arbitration-design.md`. NOT DONE until David signs off.
