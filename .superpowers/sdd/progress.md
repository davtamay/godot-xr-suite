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
Task 6: complete (commits cbf4529..5e668a4, review clean both verdicts; reviewer
  independently reproduced all three mutations).
  - Implementer flagged DONE_WITH_CONCERNS: the rigidity property test -- the
    formal statement of the design's central guarantee -- did not bite. Reversing
    the traversal order (worst possible decomposition bug) measured EXACTLY
    0.000000 deviation, because every joint carried identical symmetric +/-noise
    with identity bases, so the corruption cancelled.
  - Fixed with _articulated_hand_source: 26-joint hierarchical pose, distinct
    bone lengths, distinct per-joint rotations, deterministic asymmetric noise
    (seeded RNG), whole-hand motion. Measures 8 bones at several depths.
  - All three mutations now caught: reversed order (0.017-0.021 m), raw-vs-
    filtered parent (0.006-0.010 m), skipped dedup (new _test_hand_filter_dedup).
  - Correction: raw-vs-filtered parent was previously judged mathematically
    undetectable. It only looked that way because the old test data never MOVED --
    with a static hand, filtered ~= raw and there is nothing to lag behind.

Task 7: complete (commits 7133cdd..7b0be31, review clean both verdicts; reviewer
  independently re-ran all five mutations).
  - Mutation testing caught (a) latching discontinuity, (b) no hold on loss,
    (c) hold never expires. Mutation (d), dropping the FIRST-ACQUISITION
    discontinuity, was NOT caught: the test never consumed the flag right after
    the first capture, so a later recovery masked it. First acquisition must
    raise it because the filter has no history and must SEED, not blend.
  - Gap closed with an isolated fresh-gate block; proven by mutation (FAIL then
    PASS). A bonus mutation (fires every frame) is also now caught.

Task 9: implemented, mutation-tested, review pending.
  - Resolver gained _conditioned + set_conditioned/is_conditioned; get_tracker
    now prefers the publisher and falls back to raw. _resolve_tracker is public
    resolve_raw, which XRTrackerHandPoseSource calls so the chain cannot consume
    its own output. All 8 bypassing call sites unified. provides += hand_input.
  - CARRY-NOTE RESOLVED: the enabled-toggle hazard DOES reach set_conditioned,
    by a route the reviewer did not predict. Nothing drives the filter while
    conditioning is off, so _last_timestamp and the dedup wrist age by the whole
    off-leg. Added XRConditionedHandPublisher.reset_chain(), called from
    set_conditioned, guarded on an actual value change (an unguarded setter
    driven every frame from a UI toggle would wipe the filter every frame).
  - The plan prescribed NO new tests for Task 9. Added five assertions; 8 of 9
    mutations caught.
  - The first version of the feedback-loop test DID NOT BITE. Reverting the pose
    source to get_tracker still passed, because on the FIRST publish
    _last_tracked is false, so the re-entrant get_conditioned returns null and
    falls back to raw by accident. The loop only bites from the SECOND frame.
    Fixed with _test_pose_source_reads_raw_across_frames: two frames, raw pose
    moved 0.25 m between them. Mutant now measures exactly 0.00000 m of movement
    (the dedup shortcut replaying its own previous output). Same shape as the
    Task 6 lesson: a static fixture cannot expose a feed-forward bug.
  - Plan defect: Step 4's verification grep cannot produce its own stated
    expectation. "XRServer.get_tracker(.*hand_tracker" only matches the inline
    string form, but both files it says to expect (modality manager, simulator)
    use a _HAND_TRACKER_NAMES constant, so they never matched. Post-change it
    returns empty, which reads as a stronger pass than it is. Re-verified with
    an unfiltered sweep of every XRServer.get_tracker call instead.
  - Untested property: resolve_raw's _valid_hand guard. Mutating it away leaves
    resolve_raw(7) still returning null (the invalid TRACKER_PATHS key faults
    and resolves to null anyway), so no return-value assertion can separate the
    two. Guard kept -- it turns a fault plus a pointless full-tracker scan into
    a clean early return -- but deliberately NOT asserted rather than shipping a
    test that cannot fail.

## OUTSTANDING
Task 8: complete (commits df7c4d8..13d28a4, reviewed; two fix rounds).
  - Round 1 gap: the per-render-frame cache had ZERO coverage (both "always
    re-run" and "never re-run" passed). Closed by extracting _should_republish.
  - Round 2, CRITICAL, found by the reviewer: _ensure_tracker never set
    tracker.name, so BOTH hands registered as "Unknown", the documented
    TRACKER_NAMES lookup returned null, and publishing the right hand silently
    OVERWROTE the left in XRServer's registry. The publisher did not publish.
    Fixed + covered by _test_publisher_tracker_registration.
  - Round 2, Important: get_conditioned returned a tracker on a cache HIT even
    when the publish that filled it was untracked, while a MISS returned null --
    null-or-object depending on call order within one frame. Now consistent.
  - Lesson: the static write_frame_to_tracker was testable headless and got
    covered; the XRServer-touching path was assumed untestable and got none --
    which is exactly where the Critical bug lived. A headless --script run DOES
    have XRServer; use it.

## NEXT ACTIONS, in order
1. Task 9: REVIEW PENDING. Implemented and mutation-tested; no independent
   reviewer has looked at it yet. Every prior task's Critical/Important defects
   came from that review pass, so treat Task 9 as unreviewed, not as done.
2. Task 10: baseline traces, tuning, WEB frame-cost measurement, on-device
   earn-in. REQUIRES DAVID IN A HEADSET. A/B on the WebGL path, not WebGPU. Task 10 requires David in a headset; 7-9 automatable.

CARRY INTO TASK 10 (A/B measurement): the toggle is
XRHandTrackerResolver.set_conditioned(bool), and it resets the whole chain on
every real value change. That is correct for fidelity but it means an A/B
comparison must DISCARD the first frame or two after each flip -- the filter is
re-seeding, not converged. Do not read lag numbers across a flip boundary.

CARRY INTO FINAL REVIEW: filter.enabled still has the original unreset hazard.
Task 9 routed around it (set_conditioned resets the chain rather than touching
filter.enabled), so nothing in the suite flips filter.enabled at runtime today
-- but the field is @export and a user CAN flip it from the inspector, and that
path is still unreset and untested.

DISPATCH LESSON: every task where mutation testing was explicitly requested found
a real defect; the two where it was not requested shipped tests that could not
fail. Always request it.

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
- Task 7 (Minor, reviewer): min_valid_joints has zero test coverage. Reviewer
  verified the gating logic is correct via a standalone scratch script, so this is
  an untested property, not a defect.
