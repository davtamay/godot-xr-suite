# Far Grab Modes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let each object declare what a far grab means — ATTRACT, FIXED or REEL — and fix the aim/reel coupling bug that makes today's reeling fight the wearer.

**Architecture:** `XRGrabInteractable` gains a `far_grab_mode` enum. `XRRayInteractor` reads it at select and dispatches. ATTRACT composes two mechanisms already earned in on device (the transit tween and the grip latch) rather than adding a third motion path. The ray's existing distance exports are re-scoped from policy to limits that REEL obeys.

**Tech Stack:** Godot 4.7, GDScript. No new dependencies.

Design: `docs/far-grab-modes-design.md`. Read it before Task 1.

## Global Constraints

- **Godot:** `C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe` (full path; not on PATH).
- **`--xr-mode off` on EVERY headless invocation**, or Godot hangs forever.
- **Demo project:** `C:\Users\davta\Repos\Godot_WebXR_gh\demo`. `addons/*` are symlinks into this repo, so edits are live.
- **INDENTATION IS PER FILE AND THIS PLAN SPANS BOTH — VERIFIED, not inferred.** `xr_ray_interactor.gd` is **4-SPACE** (260 lines). `xr_grab_interactable.gd` is **TABS** (432 lines). An earlier draft of this plan claimed both were 4-space; that was inferred from one file and was wrong. Check with a count before you type. Mixing inside one file is a parse error.
- **Suites, via the error-checking runner** (a crashed test still prints PASS, so the `scripterrors` column is the proof, not the PASS text):
  `powershell -ExecutionPolicy Bypass -File tools/run_tests.ps1 -Suite godot_xr_interaction_toolkit/tests/test_grab_feel,godot_xr_interaction_toolkit/tests/test_poke_fidelity,godot_xr_interaction_toolkit/tests/test_interaction_arbiter`
  Note `powershell`, not `pwsh` — PowerShell 7 is not installed.
- **Use the Edit tool, never scripted pattern replacement.**
- **PowerShell: never `2>&1` a native exe** — it reports failure on a clean run.
- **Commit any new `.uid` file** — this repo tracks them.
- **Do not retune anything earned in on device.** `transit_speed`, the grip latch, throw values and near-grab behaviour are all settled; this change composes them, it does not adjust them.
- **`xr.interaction` must stay `requires=[]`** and installable standalone.

---

### Task 1: The mode enum and ray dispatch

**Files:**
- Modify: `addons/godot_xr_interaction_toolkit/runtime/xr_grab_interactable.gd` (TABS)
- Modify: `addons/godot_xr_interaction_toolkit/runtime/xr_ray_interactor.gd` (4-space)
- Test: `addons/godot_xr_interaction_toolkit/tests/test_far_grab_modes.gd` (new)

**Interfaces:**
- Produces: `XRGrabInteractable.FarGrabMode` (`ATTRACT`, `FIXED`, `REEL`) and `@export var far_grab_mode := FarGrabMode.ATTRACT`; `XRRayInteractor.get_grab_distance() -> float` and `XRRayInteractor.adjust_grab_distance(delta: float) -> void` (the latter is phase 2's entry point and must exist now so the ray's distance state has one public mutator).

- [ ] **Step 1: Write the failing test**

New file `tests/test_far_grab_modes.gd`. Follow `test_grab_feel.gd`'s harness shape: `extends SceneTree`, non-tree tests in `_init`, tree-dependent ones in `_process`, failures collected in an array, `quit(0)` on pass.

The ray interactor's distance state is what this task changes, so drive it directly rather than standing up an XR session. Cover:

| Case | Expected |
|---|---|
| ATTRACT on select | `get_grab_distance()` is the grip floor, not the hit distance |
| FIXED on select | `get_grab_distance()` equals the hit distance |
| FIXED + hand motion along the ray | distance unchanged |
| FIXED | still clamped by `min_grab_distance` |
| REEL + hand motion along the ray | distance changes |
| Interactable with no mode set | behaves as ATTRACT |

**Every fixture must use a hit distance clearly different from `min_grab_distance` (0.25) and from the grip floor**, or ATTRACT and FIXED produce the same number and both tests pass against either implementation. Use a hit distance like 3.0.

- [ ] **Step 2: Run to verify it fails**

```bash
'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe' --headless --xr-mode off --path 'C:\Users\davta\Repos\Godot_WebXR_gh\demo' --script 'res://addons/godot_xr_interaction_toolkit/tests/test_far_grab_modes.gd'
```

Expected: FAIL — `FarGrabMode` and `get_grab_distance` do not exist.

- [ ] **Step 3: Add the enum to the interactable**

In `xr_grab_interactable.gd` (TABS), in the `Grab` export group:

```gdscript
## What a FAR (ray) grab does with this object. Near/direct grab is unaffected.
## ATTRACT: comes to your hand and stays - the common "I want that thing".
## FIXED: holds the distance it was grabbed at and follows your aim.
## REEL: hand motion along the ray winds it in and out.
enum FarGrabMode { ATTRACT, FIXED, REEL }
@export var far_grab_mode := FarGrabMode.ATTRACT
```

- [ ] **Step 4: Dispatch in the ray interactor**

`xr_ray_interactor.gd:236` currently reads:

```gdscript
func _notify_select_granted(interactable) -> void:
    # Grabbing closer than min_grab_distance keeps the true distance so the
    # object does not pop forward; min_grab_distance only floors pull-ins.
    _grab_distance = minf(_hover_distance, max_distance)
```

Replace the distance capture with a mode-aware one. Keep the existing comment — it explains why the FIXED/REEL capture is what it is. Read the mode defensively (`"far_grab_mode" in interactable`), so a third-party interactable without the property still works and behaves as ATTRACT.

ATTRACT sets the distance to the same floor the reel-to-grip path already uses, so the existing transit tween carries the object in and the existing latch holds it. Do NOT write a new motion path.

Then gate `_apply_motion_distance_manipulation` on the mode: it must run only for REEL.

Add the two public accessors named in Interfaces. `adjust_grab_distance` applies the same clamps the internal path uses — do not duplicate the clamp arithmetic; extract it if that is cleaner.

- [ ] **Step 5: Run to verify it passes**

Same command as Step 2. Expected: PASS, exit 0.

- [ ] **Step 6: Mutations — each must fail the suite**

| # | Mutation | Must fail |
|---|---|---|
| 1 | ATTRACT branch captures the hit distance instead of the floor | ATTRACT-on-select |
| 2 | `_apply_motion_distance_manipulation` runs for all modes | FIXED + hand motion |
| 3 | Missing-property fallback defaults to REEL instead of ATTRACT | unspecified-mode |

Report the assertion that fired for each. If any passes, the fixture is too weak — say so rather than adjusting the mutation.

- [ ] **Step 7: Commit**

```bash
git add addons/godot_xr_interaction_toolkit/runtime/xr_grab_interactable.gd addons/godot_xr_interaction_toolkit/runtime/xr_ray_interactor.gd addons/godot_xr_interaction_toolkit/tests/test_far_grab_modes.gd
git commit -m "feat: an object decides whether a far grab attracts, holds or reels"
```

---

### Task 2: Freeze the reel axis

**Files:**
- Modify: `addons/godot_xr_interaction_toolkit/runtime/xr_ray_interactor.gd` (4-space)
- Test: `addons/godot_xr_interaction_toolkit/tests/test_far_grab_modes.gd`

**Interfaces:**
- Consumes: Task 1's mode dispatch.
- Produces: no new public API. `_reel_axis` is internal.

This is a bug fix independent of the mode work: reeling projects hand motion onto the **live** ray direction, so aiming and reeling are the same input.

- [ ] **Step 1: Write the failing test**

The guard for this fix, and the one most likely to be written weakly. It must:
1. select in REEL mode,
2. move the hand a known amount along the ray and record the distance delta,
3. **rotate the ray** (change the direction the interactor reports) without moving the hand,
4. move the hand the *same* amount again,
5. assert the second delta equals the first.

A test that only asserts "some delta occurred" passes against the bug. The rotation between samples is the whole point.

- [ ] **Step 2: Run to verify it fails**

Expected: FAIL — with the live direction, the second delta differs because the projection axis moved.

- [ ] **Step 3: Capture the axis at select**

Add `var _reel_axis := Vector3.FORWARD` beside the other reel state. Set it in `_notify_select_granted` from the current ray direction. Use it in `_apply_motion_distance_manipulation` in place of `_last_ray_direction.normalized()`.

Leave `_last_ray_direction` alone — it is still needed for the hand-motion delta itself (`origin - _last_ray_origin` pairs with it elsewhere). Only the **projection axis** changes.

- [ ] **Step 4: Run to verify it passes** — same command, expect PASS.

- [ ] **Step 5: Mutation**

Revert to `_last_ray_direction.normalized()`. The aim-change test must fail. Report the assertion.

- [ ] **Step 6: Commit**

```bash
git add addons/godot_xr_interaction_toolkit/runtime/xr_ray_interactor.gd addons/godot_xr_interaction_toolkit/tests/test_far_grab_modes.gd
git commit -m "fix: aiming no longer changes what pulling means"
```

---

### Task 3: Verification, authoring surface, earn-in prep

**Files:**
- Modify: `addons/godot_xr_interaction_toolkit/editor/xr_blocks_dock.gd` (tabs)
- Modify: `addons/godot_xr_interaction_toolkit/README.md`
- Modify: `docs/far-grab-modes-design.md`

- [ ] **Step 1: Run every suite through the error-checking runner**

```bash
powershell -ExecutionPolicy Bypass -File tools/run_tests.ps1 -Suite godot_xr_interaction_toolkit/tests/test_far_grab_modes,godot_xr_interaction_toolkit/tests/test_grab_feel,godot_xr_interaction_toolkit/tests/test_poke_fidelity,godot_xr_interaction_toolkit/tests/test_ui_canvas_pointer,godot_xr_interaction_toolkit/tests/test_interaction_arbiter,godot_xr_hands/tests/test_gesture_foundation,godot_xr_hands/tests/test_adaptive_contact,godot_webxr_kit/tests/test_eye_height_calibrator
```

Every line must read `exit=0 scripterrors=0`. **`test_grab_feel` is the one to watch** — it guards the transit and grip-latch behaviour ATTRACT now composes.

- [ ] **Step 2: Boot-check the demo scenes**

```bash
'C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe' --headless --xr-mode off --path 'C:\Users\davta\Repos\Godot_WebXR_gh\demo' res://addons/godot_xr_interaction_toolkit/samples/workshop_demo.tscn --quit-after 150
```

Exit 0, zero lines matching `ERROR:`, `SCRIPT ERROR` or `Parse Error` — count all three.

- [ ] **Step 3: Update the dock description**

In `xr_blocks_dock.gd` (TABS), the `"Grabbable"` and `"Throwable"` entries. Add one clause naming `far_grab_mode` and its three values, in the existing voice — these descriptions are how an author discovers the feature.

- [ ] **Step 4: Document in the addon README**

Add a `### Far grab` section: what the three modes do, that the default is ATTRACT, and that the ray's distance exports are limits REEL obeys rather than global policy.

- [ ] **Step 5: Commit**

```bash
git add addons/godot_xr_interaction_toolkit/editor/xr_blocks_dock.gd addons/godot_xr_interaction_toolkit/README.md
git commit -m "docs: far grab modes in the dock and the README"
```

- [ ] **Step 6: On-device earn-in — DO NOT MERGE WITHOUT THIS**

ATTRACT changes the default for every existing far-grabbable, which is a `CLAUDE.md` stop-condition. The checklist is in `docs/far-grab-modes-design.md`. The human runs it; do not simulate or record a result you did not observe.

---

## Self-review notes

**Spec coverage.** Mode enum → Task 1. ATTRACT/FIXED/REEL behaviour → Task 1. Coupling fix → Task 2. Authoring surface → Task 3. Earn-in → Task 3 Step 6. Phase 2 (pinch-and-twist) is deliberately a separate plan.

**The two fixtures most likely to be written weakly**, called out in place: ATTRACT vs FIXED must use a hit distance distinct from both the floor and `min_grab_distance` or they cannot tell the implementations apart; and the aim-change test must rotate the ray *between* samples, since asserting "a delta occurred" passes against the bug.

**Not built:** pinch-and-twist, recoil assist, hand-to-shoulder distance.
