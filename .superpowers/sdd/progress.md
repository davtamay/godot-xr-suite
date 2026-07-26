# Poke Fidelity — progress ledger

Plan: docs/poke-fidelity-plan.md
Design: docs/poke-fidelity-design.md
Branch: agent/poke-fidelity (godot-xr-suite), branched from master @ de46360
Godot: C:\tmp\Godot47\Godot_v4.7-stable_win64_console.exe (4.7.stable)
Demo:  C:\Users\davta\Repos\Godot_WebXR_gh\demo  (addons/* are SYMLINKS into
       this repo's working tree, so edits here are live with no copy step)
Tests: <godot> --headless --xr-mode off --path <demo> --script res://<path>
       --xr-mode off is MANDATORY or headless hangs forever.

Pre-flight amendments (controller, before Task 1) — commit dab7bbe:
- Added XRPokeEvaluator.is_source_pressed(source_id). The canvas needs
  per-source pressed state; is_pressed() answers "any source", so with two
  hands on a panel a pressed hand would have dragged the cursor for the idle
  one.
- apply_profile gained include_depth := true. The button was setting derived
  depths, applying a profile over them, then setting them back; a cap's throw
  is geometry (travel, press_fraction), not project feel.
- Dropped the set_active_targets_for_test seam from XRPokeInteractor.
  GDScript's underscore is convention, not privacy, so the marker fixture
  writes _active/_points directly instead of production code growing an API
  that exists only for a test.

Baseline before Task 1: test_grab_feel = PASS, exit 0 (verified by controller).

## Task status

Task 1: complete (commits 2125d35..bbd72d1, review clean both verdicts after
  two fix passes). 17 tests pass, output pristine.
  - Implementer commit 2125d35; fix pass 1 5ce9225; fix pass 2 bbd72d1.
  - Review: spec COMPLIANT, quality APPROVED. Reviewer hand-verified all
    fixture arithmetic and independently confirmed both load-bearing
    properties really are exercised (the slow-creep fixture's lateral
    component, and the fast-diagonal rescue depending on history surviving a
    bounds exit).
  - Two Important findings, both fixed in pass 1: forget() and apply_profile()
    had no test at all. forget() is the only caller of the history-CLEARING
    exit, so a regression flipping it to keep-history would have passed the
    whole suite silently.
  - Fix pass 2: the per-axis half_size fix from Minor finding 3 had shipped
    without a fixture, so the documented "zero on an axis = unbounded there"
    was unasserted. Mixed-axis test added; the mutation proved the old guard's
    real defect was OVER-rejecting x, not under-rejecting y.

### Carried into Task 2 (plan amendment, controller)
Fix pass 1 added three apply_profile tests against a local `_StubPokeProfile`
class in the test file. Task 2 must REPLACE that stub with the real
XRPokeProfile rather than adding the two near-duplicate tests the plan lists -
a stub cannot catch a property rename in the shipped resource. The profile
INSTANCE in those tests must keep values distinct from the evaluator defaults
(0.030 / 0.060 / false / 80.0 / 0.001), because XRPokeProfile's own defaults
deliberately match the evaluator's and a default-valued profile would make the
copy assertions pass trivially.

Task 2: complete (commit dd0114d, review clean both verdicts, no Critical or
  Important findings). XRPokeProfile shipped; the _StubPokeProfile from Task 1's
  fix pass replaced by the real resource, so a property rename in the shipped
  type would now break the suite.
  - Reviewer independently confirmed all five asserted profile values differ
    from the evaluator defaults, so none of the copy assertions are vacuous -
    the specific trap this task carried, since XRPokeProfile's defaults
    deliberately match XRPokeEvaluator's.

Task 3: complete (commits b96cea5..3a506b6, review clean both verdicts after
  two fix passes). 20 tests pass, output pristine.
  - PRE-EXISTING BUG FOUND, and it is a real one. xr_pokeable.gd's
    _local_normal() has its two Z arms inverted: Godot's Vector3.BACK is
    (0,0,+1), not (0,0,-1) as its trailing comments claim, so Z_PLUS returned
    (0,0,-1) and Z_MINUS returned (0,0,+1). Z_PLUS is the DEFAULT face, so the
    default configuration measured depth with the wrong sign. Verified
    empirically on this Godot build, not from memory.
  - This survived because XRPokeable has no consumers and had no tests. It is
    the strongest evidence so far for the design's claim that XRPokeable was
    the least-proven of the three poke surfaces.
  - The implementer's first fix negated at the call site
    (normal := -_local_normal()), which corrects the two Z arms and INVERTS the
    four X/Y arms that were already right. The suite stayed green because every
    fixture used the default Z_PLUS face. Sent back: repair the function, and
    add a non-Z-face test, which is the assertion that would have caught it.
  - Plan deviation authorised by controller: the brief said preserve
    _local_normal byte-for-byte. That rested on the function being correct.
  - Fixed properly in e6c326e (Z_PLUS -> BACK, Z_MINUS -> FORWARD, comments
    corrected, negation removed). Mutation evidence decouples the two bugs:
    re-applying the global negation fails BOTH the Z and the new X_PLUS tests,
    while reverting only the Z arm fails the Z tests and leaves X_PLUS green.
  - 7c29ad7 tracks the three .uid files Godot generated for the new scripts.
    All three implementers had left them untracked; this repo tracks .uid
    alongside every .gd, and without them the next machine to open the project
    mints fresh UIDs and breaks any uid:// reference to these scripts.
  - Review found two more Important items, both fixed in 3a506b6:
    * the pin round-trip test was VACUOUS for the u/v half - u_axis and v_axis
      are perpendicular to normal by construction, so on an identity transform
      pin.z depends only on normal.z * pinned.z and a u/v swap could not fail
      it. Now asserted on a translated AND rotated body.
    * get_poke_pin returned a pin for points OFF the face: poke_update wrote
      _pins before knowing the verdict, so a fingertip beside a button but
      deeper than its face would have snapped the Task 6 marker onto the
      button's plane. Both evaluator exit paths now return Vector3.INF.
      Controller authorised the evaluator edit, scoped to those exit paths -
      TWO logical paths, THREE lines, because the bounds rectangle is checked
      per-axis. Re-reviewer verified no other line in evaluate() moved.
    * a third test was written this pass because the band-exit path had no
      coverage at all - the mutation for it would otherwise have passed.

### Minor findings deferred to the final whole-branch review
- Task 1: is_pressed() / is_source_pressed() are only exercised indirectly
  through event assertions; no direct call in any test.
- Task 1: every fixture uses source_id 0. Multi-source independence (the
  _sources keyed dict) is implemented but has no dedicated test.
- Task 2: test helper _make_profile() returns Resource rather than
  XRPokeProfile - weaker typing than necessary now the concrete class exists.
- Task 2: XRPokeProfile reuses xr_poke_interactor.svg as its @icon (specified
  by the plan). Reads as a copy-paste leftover if a profile icon ever lands.
- Task 3: _plane_u's near-parallel-to-UP fallback branch fires only for
  Y_PLUS/Y_MINUS faces and no test exercises it.
- Task 3: X_MINUS, Y_PLUS and Y_MINUS have no pokeable-level fixture; X_PLUS
  is the single representative non-Z face. The four arms share no branching
  logic, so the risk is low, but the Y faces are the ones that reach the
  _plane_u branch above.

### Corrections to the PLAN found during execution (plan was wrong, code was not)
- Mutation 5 (`max_approach_angle` default 180) does not loosen the gate:
  the comparison is squared, and cos(180)^2 == cos(0)^2 == 1, so 180 is as
  restrictive as 0. It fails the fast-diagonal rescue, not the lateral sweep.
- Mutation 6 (`or` -> `and`) fails the slow-creep test too, not only the two
  rescue cases. The slow-creep fixture deliberately has in_front false, so
  AND rejects it. The plan's "and nothing else" was wrong.

### Carried into Task 4 (plan amendment, controller)
Task 3's fix changed the evaluator: `pinned_point` is now `Vector3.INF` on BOTH
exit paths, not a clamped point. The Task 4 brief predates that and stores the
pin unconditionally (`_poke_pins[source_id] = global_transform * pinned`). The
canvas must apply the same INF handling XRPokeable now uses - erase the entry
rather than store INF - or `get_poke_pin` will hand Task 6's marker an infinite
world position.

Task 4: IN PROGRESS (implementer commit 1826206; fix pass 1 in flight)
  - Canvas converted to the shared evaluator. Both suites green:
    test_poke_fidelity and test_ui_canvas_pointer (8 hover-ownership tests
    unchanged, which is the guard that the panel's cursor logic did not move).
  - Implementer applied the carried-over INF correction correctly.
  - Concern 1, being fixed: the new canvas test only proves the NEGATIVE (a
    slide-off does not fire the Control). A no-op adapter would pass it too.
    Adding the positive case plus a return-immediately mutation.
  - Concern 2, NO CODE CHANGE, feeds Task 8: entry-through-face and
    approach-angle gating are NEW to the canvas path. Strict narrowing - it can
    only newly reject, never newly accept - but it is still a behaviour delta on
    a surface tuned in-headset, which is a CLAUDE.md on-device-earn-in trigger.
    Implementer is writing a concrete gesture list for the Task 8 checklist.

### Carried into Task 8 (controller)
The on-device checklist must explicitly cover UI-panel gestures that the new
gate could newly reject - approaching a slider handle from the side, pressing a
button near the panel edge at a shallow angle. Revert lever if it regresses:
require_entry_through_face = false, max_approach_angle = 90.
  - Review Important (plan-mandated): the brief's own code stopped updating
    _last_pointer_position on pure hover frames. Inert today - every reader
    sets it before reading - but a divergence on an earned-in path, and the
    stated goal for this file was to move the DECISION without moving the
    BEHAVIOUR. Controller chose to fix rather than accept: restoring the
    pre-conversion continuous assignment fulfils the plan's intent, so this is
    not a plan contradiction needing the human.
  - Review Minor, also closed: the per-source drag branch
    (is_source_pressed vs is_pressed) had no guard, so a regression back to
    is_pressed would have passed both suites. Fixed in f2ab751 with a
    _MotionProbe Control capturing the actual pushed InputEventMouseMotion.
    The fixer correctly REJECTED _last_pointer_position as the observable - it
    is shared across sources and now unconditional, so it cannot distinguish
    hovered from dragged.
  - Pre-existing warnings (no XRInteractionManager, ObjectDB leaked) confirmed
    against a stashed baseline as predating this branch, not introduced here.
