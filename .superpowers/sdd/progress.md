# Hand Signal Conditioning — progress ledger

Plan: docs/hand-signal-conditioning-plan.md
Branch: agent/hand-conditioning (godot-xr-suite)
Tests: <godot> --headless --xr-mode off --path C:/Users/davta/Repos/Godot_WebXR_gh/demo --script res://<path>

Pre-flight decisions (David):
- Frame copying lives on XRHandFrame.copy_into(target); decorators must not
  define their own _copy_frame. Plan amended before Task 1.
- XROneEuroFilter / XROneEuroRotationFilter keep independent resize/reset
  bookkeeping. Duplication accepted deliberately; final review may triage.
- Harness verified before dispatch: --xr-mode off is REQUIRED or headless
  hangs forever on OpenXR init. Baseline test_gesture_foundation.gd = PASS.

## Task status
Task 1: complete (commits f096ac4..8314241, review clean both verdicts)
Task 2: complete (commit 5eb8e10, review clean both verdicts)
Task 3: complete (commits 9f42c8a..63238f9, review clean after one Important fix)
  - Reviewer found the plan-mandated quaternion hemisphere correction was DEAD
    CODE: Godot's slerp/angle_to are already double-cover invariant (slerpni is
    the opt-out). Verified independently against the engine. David chose remove
    + comment-why. Replacement test proven non-vacuous (slerp->slerpni = FAIL,
    123 deg divergence), reproduced by the re-reviewer. Plan and spec corrected.
Task 4: complete (commits bc26b14..5377e76, review clean after one Critical fix)
  - Reviewer found the recorder's dedup guard was DEAD: it compared
    timestamp_usec, which XRTrackerHandPoseSource echoes from the caller and the
    recorder regenerated per tick, so it was unique by construction. Every render
    frame was recorded, fabricating the replay pacing filter tuning depends on.
    Now compares the raw wrist Transform3D against the last KEPT frame.
    Fail-then-pass proof reproduced by the re-reviewer.
  - Also found: ResourceLoader.load's type_hint does not resolve GDScript
    class_name globals; dropped. Plan corrected.
Task 5: complete (commit 20fdd7d, review clean both verdicts)
  - Implementer mutation-tested all three metrics (stub each to return 0.0,
    confirm real failure). Reviewer independently re-derived the math: rest_jitter
    population RMS correct, motion_lag indexing has no off-by-one and normalises
    the window so shift search is unbiased, bone_length_deviation is population
    stdev and skips invalid joints.

## Minor findings for final-review triage
- workshop_station.gd:11 hard-preloads godot_webxr_kit (pre-existing DAG break in
  samples/, not runtime/). Spawned as separate task task_b6249a4f. Out of scope here.
- Task 2 (Minor, reviewer): xr_hand_joint_hierarchy.gd PARENT/IS_TIP/ORDER are
  mutable `static var` and CHAINS is an untyped Array literal; a caller could mutate
  the topology in place. Hardening opportunity, not a defect.
- Task 4 (Minor, re-reviewer): _test_recorder_dedup_guard uses [same, same,
  changed], which cannot distinguish "compare to last KEPT" from "compare to last
  POLLED" -- both behave identically on a single duplicate pair. Needs 3+ samples
  with non-transitive near-equality (A~B~C, A!~C). Implementation is correct by
  inspection (state updates only on return true); coverage gap, not a live bug.
- Task 5 (Minor, reviewer): bone_length_deviation's stretching-case test only
  asserts > 0.0, not an exact value, so it would not catch a population-vs-sample
  denominator bug. Inherited from the plan's prescribed test, not an implementer
  choice.
