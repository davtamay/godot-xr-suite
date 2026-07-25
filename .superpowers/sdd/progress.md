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

### Minor findings deferred to the final whole-branch review
- Task 1: is_pressed() / is_source_pressed() are only exercised indirectly
  through event assertions; no direct call in any test.
- Task 1: every fixture uses source_id 0. Multi-source independence (the
  _sources keyed dict) is implemented but has no dedicated test.

### Corrections to the PLAN found during execution (plan was wrong, code was not)
- Mutation 5 (`max_approach_angle` default 180) does not loosen the gate:
  the comparison is squared, and cos(180)^2 == cos(0)^2 == 1, so 180 is as
  restrictive as 0. It fails the fast-diagonal rescue, not the lateral sweep.
- Mutation 6 (`or` -> `and`) fails the slow-creep test too, not only the two
  rescue cases. The slow-creep fixture deliberately has in_front false, so
  AND rejects it. The plan's "and nothing else" was wrong.
