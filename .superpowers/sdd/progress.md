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

Task 9: complete (commits cbcaee7.., reviewed; one Critical fix round).
  - Review round, CRITICAL (reviewer, proven by probe): the publisher's shadow
    trackers scored like real trackers in resolve_raw's scan (name contains
    left/right, hand matches). Steady state masked it -- strict > tie-break
    with raw seeded first -- but on any raw degradation the shadow, holding
    last frame's fully-valid joints, OUTRANKED raw. The pose source then fed
    the filter its own output and the gate's 0.25 s dropout hold never fired:
    hand frozen mid-air until full reacquisition. Also polluted the raw A/B
    leg. Fixed: scan excludes TRACKER_NAMES; reset_chain also invalidates
    shadows. Regression test proves FAIL(2) then PASS.
  - Attribution: plan defect, not implementer error -- Task 8's plan put the
    shadows in XRServer, Task 9's plan reused the scan as "the raw path", and
    nothing reconciled the two.
  - DEFECT CLASS, third occurrence: "fixture never degrades" (Task 6 static
    hand, Task 9 implementer's never-degrading raw tracker, now this). The
    implementer's own mutation testing structurally cannot see it because the
    tests share the fixture. Reviewer killed the surviving _cache_frame mutant
    and the test-state leak (777 timestamp) in the same round.
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

DECIDED (David, 2026-07-24) -- Task 9 review Important #2: Option A. On gate
rejection consumers see the UNTRACKED shadow (has_tracking_data false, joint
flags scrubbed), not the raw fallback; raw fallback is reserved for the
conditioned-off / publisher-disabled states. Implementing it surfaced a LATENT
TASK 8 BUG: a failed filter capture returns without writing the reused frame,
so publish republished the last tracked pose as live -- the shadow claimed
tracking data through every dropout, unobservable until something consumed the
shadow on the untracked path. Fixed in publish; write_frame_to_tracker's
untracked path now scrubs joint flags too (consumers gate on
joint_position_valid, not has_tracking_data). All four Option A mutations
killed, incl. get_shadow ignoring _enabled and the flag scrub removed.

Task 10 prep (automatable part) DONE: measure_traces.gd committed (7247915)
and verified against synthetic rest/motion/dropout traces -- rest wrist
jitter -79% at defaults, cond tip bone dev 0.00007 m vs the 0.0005 m ceiling,
dropout replay clean. Guided capture scene in the DEMO repo (abc95df,
Godot_WebXR_gh): res://scenes/trace_capture.tscn, zero-button, records both
hands per segment to user://hand_traces/{rest,motion,dropout}_{left,right}.res.
NOTE: rest-trace "lag" and motion-trace "jitter" are meaningless by
construction; read each metric only on its matching trace kind.

Task 10 progress (2026-07-24, on-device session with David over Quest Link):
  - Six real traces captured (rest/motion/dropout x both hands) after ~8
    failed launches whose root cause was xr/shaders/enabled missing from the
    demo's project.godot (fe55c99 there; recipe memorised). Baselines
    measured; sweep run (25+7 points); position_beta 0.7 -> 2.0 committed
    with docs/hand-conditioning-results.md. Bone-dev criterion PASSES on all
    six real traces (0.07-0.37mm vs 0.5mm ceiling). Jitter criterion passes
    only under a frame-to-frame reformulation -- the plan's from-the-mean
    metric is drift-dominated on real hands (SPEC CHALLENGE raised in the
    results doc, needs David's sign-off). Lag: 1 frame left / 2 frames right,
    metric quantized to whole frames.
  - FEEL CHECK PASSED (David, on-device, same day): extensive A/B via the
    feel_check workshop scene (~40 toggle flips). All three discriminating
    tests pass -- draw-station line quality, dropout freeze test (the
    reviewer's Critical confirmed dead on-device), throw release accuracy.
    Tuned params validated. Earn-in for hand conditioning: MET.
  - Two NEW on-device findings, classification pending an A/B bisect:
    (a) grabbed cubes snap to the WRIST rather than the hand -- either the
        grab code's palm->wrist fallback firing (palm joint invalid through
        some path) or pre-existing anchor behaviour;
    (b) microgesture teleport arc unreliable, sometimes "stuck on hand" --
        likely recognizer reliability (the historically rolled-back area)
        and/or the 3 s intent timeout reading as stuck. NOTE: any change here
        touches on-device-tuned behaviour and needs its own earn-in.
  - David's next feature interest: ISDK-style near/far interaction (shoulder
    -anchored ray, conical scoring, hysteresis, near/far arbitration).
    Technique-level only -- Oculus SDK License forbids code replication.
    Backlog inventory from 54c7562 is the starting input.
  - STILL OPEN for Task 10: WEB frame-cost measurement, right-hand 2-frame
    lag decision.

## NEXT ACTIONS, in order
1. Task 10: baseline traces, tuning, WEB frame-cost measurement, on-device
   earn-in. REQUIRES DAVID IN A HEADSET. A/B on the WebGL path, not WebGPU. Task 10 requires David in a headset; 7-9 automatable.

CARRY INTO TASK 10 (trace coverage): the defect class that keeps recurring is
"fixture never degrades". The trace harness and the recorded traces MUST
include a tracking-loss segment (the plan's "dropout" trace), and the metrics
should be checked on it -- a rest+motion-only tuning pass would have the same
blind spot the Task 9 tests had.

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

---

# Grab Feel — progress ledger

Plan: docs/grab-feel-plan.md (design: docs/grab-feel-design.md)
Branch: agent/grab-feel (godot-xr-suite)
Tests: <godot> --headless --xr-mode off --path C:/Users/davta/Repos/Godot_WebXR_gh/demo --script res://<path>

## Task 1: Diagnose and fix the wrist-yank (anchor + cube config)

**Step 1 cube audit** (`grab_lab_station.tscn`): only `SnapGripCube` has
`snap_to_attach=true` (attach_transform_path -> GripPoint); no `XRGrabPoint`
nodes exist anywhere in the scene. That cube is explicitly labeled on-scene
"SNAP-GRIP / jumps to a fixed grip" -- a deliberate demo of the snap-grip
policy, not a misconfiguration. All five other cubes (Instant, Smooth,
RotationCyl, LayerCube, Peg1, Peg2) are already free-grab. Verdict: suspect
(a) as literally stated in the brief (accidental cube misconfig) is NOT
live; Step 6's scene edit is a no-op and was skipped.

**Suspect (b), expanded scope (David's call after review):** the joint
*selection* extracted into `resolve_grip_anchor()` (palm-first, wrist only
when palm invalid) was already correct in the pre-existing code -- verified
by test and mutation. The real "pulled to the wrist" bug, matching
grab-feel-design.md's precise wording ("palm valid, yet wrist chosen or
wrist-offset pose produced"), was downstream in `_hand_grip_pose`: an origin
override to the wrist<->middle-metacarpal midpoint that fired whenever all
metacarpals were tracked (the normal case on real hardware), discarding the
palm-first choice on effectively every real grab.

That override was not an accident either -- commit `15d3783` ("Hands: anchor
the runtime grip at the same palm midpoint as the preview", v1.43.0,
2026-07-19) put it there deliberately, because the raw PALM joint didn't
match the editor Preview Hand / pose-math convention at the time. Two
on-device-informed decisions in direct conflict:
- 2026-07-19 (15d3783): raw PALM is wrong: use the wrist<->metacarpal
  midpoint.
- 2026-07-24 (David, this plan's motivating feel-check): that midpoint is
  what makes grabbed objects read as pulled to the wrist: anchor on PALM.

**David's decision (2026-07-24):** reverse the 1.43.0 midpoint override,
anchor on `resolve_grip_anchor()`'s PALM-first result instead, on the
explicit understanding that Task 6 (David in-headset) is the verification
gate for this reversal, and that authored grips (blaster/pen/spray) may
shift and will be re-checked there. Recorded in-code as a two-decision
history comment at the call site
(`xr_controller_hand_adapter.gd::_hand_grip_pose`), not a silent revert.

**What shipped:**
- `static func resolve_grip_anchor(tracker: XRHandTracker) -> Transform3D`
  on `XRControllerHandAdapter` (no `class_name`; preload in tests). Palm-first,
  wrist-fallback, tracker-local space (no XROrigin transform -- callers
  world-transform it). Routed both `_hand_grip_pose` and `_hand_anchor_global`
  through it, removing the duplicated inline selection.
- Removed the wrist<->middle-metacarpal midpoint origin override in
  `_hand_grip_pose`; origin now stays on `resolve_grip_anchor()`'s result
  through the metacarpal-valid branch. The basis/orientation math in that
  branch is unaffected -- it never read the midpoint, only wrist/index/pinky
  metacarpal positions.
- `tests/test_grab_feel.gd` (new suite, harness pattern matches
  `test_hand_conditioning.gd`): `_test_grip_anchor_prefers_palm` (brief's
  verbatim test) plus `_test_grip_pose_stays_on_palm_with_full_hand`
  (regression for the midpoint override, driven through the real call site
  `get_grip_pose()` via a fully-tracked registered `XRHandTracker`, not just
  the extracted selector -- the override lived downstream of the selector).

**Harness note for later tasks:** `_test_grip_pose_stays_on_palm_with_full_hand`
needs a live `Node3D.global_transform`, which asserts
`"!is_inside_tree()"` if read during `_init()` -- a node added to
`get_root()` there is not yet inside the tree (confirmed empirically: still
false immediately after `add_child`, true by the first `_process`). Deferred
that one test (and the suite's PASS/FAIL/quit) to `_process()`; the brief's
tree-independent test still runs from `_init()`. Task 4's plan snippet
(`get_root().add_child(grab)` then driving `_physics_process`/reading
`global_transform` immediately) will likely hit the same issue and need the
same fix.

**Mutation log:**
1. `resolve_grip_anchor`: swapped PALM/WRIST preference -> `_test_grip_anchor_prefers_palm`
   FAILed (`grip anchor must sit on the PALM...got (0.0, 1.0, 0.0)`) -> reverted -> PASS.
2. Origin-override reversal: restored the wrist<->metacarpal midpoint override ->
   `_test_grip_pose_stays_on_palm_with_full_hand` FAILed both its
   palm-match and midpoint-regression assertions (got `(0.0, 1.0075, -0.0175)`,
   the exact midpoint) -> reverted -> PASS.

**Suites:** `test_grab_feel.gd` PASS, `test_hand_conditioning.gd` PASS,
`test_gesture_foundation.gd` PASS, all after the anchor-origin change.

**Fix round (reviewer feedback):** verified the authoritative palm formula
first - OpenXR's `XR_HAND_JOINT_PALM_EXT` = midpoint(MIDDLE_METACARPAL,
MIDDLE_FINGER_PHALANX_PROXIMAL), i.e. the center of the middle metacarpal
bone, NOT wrist-involved at all (Meta OpenXR SDK implementation notes +
godot-proposals#13876). Three sites still used the retired
wrist<->metacarpal midpoint and were aligned to the real formula:
- `xr_grab_point.gd::_rebuild_hand_preview` (editor Preview Hand ghost) -
  fixed; untestable headless by design (`Engine.is_editor_hint()` guard
  makes it a no-op outside the editor), documented in task-1-report.md
  rather than shipping a fake test.
- `xr_grab_point.gd::_build_bind`'s `bind[PALM]` - traced downstream: dead
  data, nothing in `xr_hand_pose_math.gd` or `_pose_skeleton`'s write-back
  reads `HAND_JOINT_PALM`. Aligned anyway at zero behavioral risk. Test:
  `_test_grab_point_bind_palm_uses_metacarpal_center`.
- `xr_simulator.gd`'s fake-tracker PALM synthesis - materially misplaced
  (same systematic error as the original bug), fixed. Test:
  `_test_simulator_palm_uses_metacarpal_center`, against the REAL
  `_load_bind_skeletons()` asset-loading path (confirmed headless-safe: no
  tree/editor dependency).

Both new assertions mutation-proven (reverted each to the retired formula ->
FAIL -> reverted back -> PASS). All three suites re-confirmed green after
the fix round.

Status: complete (both submission and fix round). Commit: see task-1-report.md.
GF Task 1: complete (commits a76abdd..cd80922, review clean both verdicts,
  one fix round). Real bug was NOT joint selection but the 15d3783 midpoint
  override (tuned Jul 19, reversed Jul 24 with David's sign-off; Task 6
  verifies). Fix round aligned preview ghost + simulator palm synthesis to
  the OpenXR palm definition (midpoint of middle metacarpal bone, verified
  against the Khronos spec by implementer AND reviewer independently);
  bind[PALM] confirmed dead data, aligned anyway. CARRIED: preview-ghost
  change untestable headless -- David eyeballs a grab-point preview in the
  editor once; folded into the Task 6 checklist.
GF Task 2: complete (commits 9704a50..3101a13, review clean both verdicts,
  one fix round). Brief's mutation (a) SURVIVED as written -- every original
  vector let consensus alone reject the tail, so the dead-zone had zero
  observable coverage. Killed with a dead-zone-decisive vector (4 clean vs 5
  slowdown-tail: tail WINS consensus unless the newest 2 are dropped).
  Same defect class as GF Task 1's: a test that passes for the wrong reason.
  Reviewer independently hand-traced even-size median, deadzone>=size slice
  clamp, and tie-to-recent anchor ordering -- no bugs.
GF Task 3: complete (commits 407632b..f78df35, review clean, TWO fix rounds).
  - Round 1: transit_blend discarded scale entirely -- Basis(Quaternion) is
    pure rotation, so a scaled object snapped to unit scale permanently the
    moment transit engaged. Brief's code, not implementer error.
  - Round 2: the round-1 fix (get_scale/scaled round-trip) was ALSO unsound --
    get_scale() returns world-axis column lengths and scaled() pre-multiplies,
    so non-uniform scale on a ROTATED basis silently permutes which local axis
    gets which magnitude, plus a singular basis at mid-alpha when scale crosses
    zero. Uniform-scale tests structurally cannot see either.
  - Sound form: stop decomposing scale at all. local_scale =
    orthonormalized().inverse() * basis (exact for scale AND shear, verified by
    the reviewer on sheared bases), composed as blended * local_scale. Scale
    rides through untouched -- a transit MOVES an object, never resizes one.
  - Same defect class a third time this branch: only non-uniform, rotated,
    moving fixtures expose it. Three plausible-looking wrong answers in a row.
  - CARRY INTO TASK 4 (load-bearing, reviewer-verified): transit_blend's
    exactness depends on `from` and `to` carrying the SAME object scale. Within
    one continuous grab that holds exactly (to.basis = dR * from.basis, proven
    algebraically and empirically). It BREAKS across a two-hand -> one-hand
    handoff or any grab-point reselection, because _notify_select_exited
    recomputes _grab_offset (line ~137) -- alpha=1 then lands on a wrong but
    plausible-looking basis with no error. Task 4 must clear/re-arm transit on
    EVERY _compute_grab_offset recompute, not only when grabbers go empty.
GF Task 4: complete (commits 0ec42bd..339d152, review clean both verdicts,
  one fix round). Transit wired as a phase; free grabs never transit.
  - Implementer caught TWO of the brief's own mutations surviving against
    brief-derived fixtures and strengthened them unprompted -- the branch's
    recurring lesson finally landing at implementer level.
  - Transit is armed/cleared on every _grab_offset write path (entered,
    handoff, two-hand begin). Handoff RE-ARMS (recaptures _transit_from from
    the object's live world transform) rather than merely clearing, so the
    Task 3 scale invariant holds for the new offset.
  - Reviewer traced and DISPROVED a suspected cross-feature bug: transit
    motion cannot contaminate throw velocity, because _sample_throw_velocity
    samples the interactor's attach_pose, never the target's transform.
  - Fix round: the handoff test moved both hands by the same vector, so hand
    DISTANCE never changed and two_hand_scale never fired -- the test never
    exercised the scale change that motivated the re-arm. Now separates hands
    to 3.0x and tracks basis determinant per frame.
  - PRE-EXISTING, for final-review triage: snap_to_attach with NO attach node
    yields _grab_offset = IDENTITY, which encodes no scale, so a scaled object
    reverts to unit scale once plain tracking resumes. Point grabs, free grabs
    and snap-with-node all encode scale correctly. Task 5 audits whether any
    shipped prefab hits the degenerate config.
  - Minor, for follow-up (not blocking): the brief's arming condition
    (_grab_points.is_empty()) disables snap_to_attach transit object-wide once
    ANY grab point exists, including for a non-matching hand.
GF Task 5: complete (no code/scene changes -- audit found zero policy
  mismatches and zero live instances of the Task 4 degenerate config).
  **Step 1 audit table** (every shipped grabbable prefab + every station/demo
  scene that instances one; `bolt.tscn` and `samples/can.tscn` are plain
  RigidBody3D projectile/targets with no XRGrabInteractable and are correctly
  out of scope):

  | Prefab / instance | XRGrabPoint? | snap_to_attach | Policy | Intended? |
  |---|---|---|---|---|
  | grabbable.tscn | no | false | hold-where-grabbed | yes (generic template) |
  | throwable.tscn | no | false | hold-where-grabbed | yes (plain object) |
  | coffee_cup.tscn | yes (Body/GrabPoint, handle) | n/a | authored transit | yes (authored handle grip) |
  | pen.tscn | yes (Body/GrabPoint) | n/a | authored transit | yes (tool, per design table) |
  | spray_can.tscn | yes (Body/GrabPoint) | n/a | authored transit | yes (tool, per design table) |
  | blaster.tscn | yes (Body/GrabPoint) | n/a | authored transit | yes (tool, per design table) |
  | grab_lab_station.tscn: InstantCube/SmoothSphere/RotationCyl/LayerCube/Peg1/Peg2 | no | false | hold-where-grabbed | yes (movement-type/layer demos, Task 1 territory) |
  | grab_lab_station.tscn: SnapGripCube | no (uses attach_transform_path=GripPoint instead) | true | authored transit (snap-derived) | yes -- Task 1's confirmed intentional snap-grip demo; untouched |
  | throw_station.tscn: Block1-4 (throwable.tscn instances) | no | false (inherited) | hold-where-grabbed | yes |
  | draw_station.tscn: Pen, CoffeeCup (prefab instances) | inherited | n/a | authored transit | yes |
  | shoot_station.tscn: Blaster (prefab instance) | inherited | n/a | authored transit | yes |
  | spray_station.tscn: SprayCan (prefab instance) | inherited | n/a | authored transit | yes |
  | webxr_starter.tscn: GrabCube (grabbable.tscn instance) | no | false | hold-where-grabbed | yes |

  Every station/demo scene in the repo that instances a grabbable was
  checked (grab_lab_station, throw_station, draw_station, shoot_station,
  spray_station, webxr_starter, workshop_demo which only composes the five
  stations). control_panel_demo/locomotion_playground_demo/
  poke_playground_demo have no XRGrabInteractable-based objects (dial/lever/
  drawer/climb-hold use their own scripts, out of this policy's scope).

  **Degenerate-config check** (Task 4's carried note: `snap_to_attach=true`
  with no `attach_transform_path` and no grab points -> `_grab_offset =
  Transform3D.IDENTITY` -> scale silently reverts to 1 on grab): grepped
  every `.tscn` in the repo for `snap_to_attach` -- the ONLY hit is
  SnapGripCube above, and it has `attach_transform_path` set. Zero live
  occurrences of the degenerate config. Nothing to fix; the pre-existing
  behavior remains as documented for future authors.

  **Tuned-value note** (`throw_sample_frames` 5->10, GF Task 2, commit
  9704a50): confirmed by re-reading that commit's message -- a buffer-SIZE
  increase so the consensus estimator has enough samples to do outlier
  rejection (needs >=4 after the dead-zone), not a feel-tuning change. Left
  untouched per plan constraint. Separately, `throwable.tscn` and
  `throw_station.tscn`'s four Block instances still override
  `throw_sample_frames = 3` (pre-existing, predates GF Task 2) -- an
  on-device-tuned value per CLAUDE.md's on-device-earn-in rule; not touched,
  not investigated further (out of this task's scope, no evidence it's
  wrong).

  **Verification** (all green, zero SCRIPT ERROR):
  - `test_grab_feel.gd`: PASS
  - `test_hand_conditioning.gd`: PASS
  - `test_gesture_foundation.gd` (godot_xr_hands): PASS
  - Demo headless boot (`--headless --xr-mode off --path . --quit-after
    120`): exit 0, 0 SCRIPT ERROR occurrences.

  Status: GF Task 5 complete. Commit: chore: prefab grab-policy audit
  (ledger-only; no runtime/scene diffs -- the audit found nothing to fix).
  GF Task 6 (on-device earn-in) remains David-in-headset, not started.
