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
  - Re-review found finding 1's fix was a SUPERSET, not an exact restoration.
    Pre-conversion the bounds test lived in the adapter and gated the
    _last_pointer_position assignment; moving bounds into the evaluator left
    the adapter with a z-only gate, so out-of-bounds-but-in-z-range points now
    stored a clamped edge pixel. Fix pass 3 gates on `inside` explicitly.
    Rejected alternative: gating on pinned_point != INF. The evaluator's band
    starts at -release_depth (-0.04) but this adapter's reach gate allows down
    to -0.06, so a point 4-6cm behind the panel would have been skipped where
    the pre-conversion code assigned. Duplicating one cheap rectangle test is
    correct here - cursor position is presentation, not press decision.

Task 4: complete (commits 1826206..4f4e4be, review clean after three fix
  passes). Both suites green: test_poke_fidelity and test_ui_canvas_pointer.
  - Fix pass 3 mutation reproduced the predicted symptom exactly: dropping the
    `inside` guard stored pixel x=1024.0 (u clamped to 1.0) where 512.0 was
    correct. That is the spurious edge pixel the finding described.

Task 5: IN PROGRESS (implementer commit 5c9aa45; fix pass 1 in flight)
  - Implementer disabled require_entry_through_face on the button to make the
    fast-poke test pass. That switches the gate OFF entirely for buttons -
    _entry_passes returns true unconditionally, so the OR is always satisfied.
    Reversed. But the underlying problem it papered over was real:
  - ROOT CAUSE (xr_poke_button.gd:98): the cylinder test called poke_end ->
    forget(), which CLEARS the sample history. The evaluator's own bounds exit
    keeps it (_exit(state, true)). History survival is what lets the angle test
    rescue a fast approach whose previous sample fell outside the shape, so the
    button was destroying its own rescue and leaving the entry test to carry
    the gate alone.
  - Fix: new evaluator method leave_bounds(source_id) - a shape exit that keeps
    history, the counterpart of forget(). Cylinder test uses it; the reach test
    (>5cm above the cap) keeps forget(), which is correct there.
  - The brief's fast-poke FIXTURE was also wrong: it started at local.y=0.120,
    outside the reach guard at cap_rest_top+0.05 = 0.098, so the first sample
    forgot the source. That is a 14cm jump in one physics frame (~8.4 m/s), not
    a poke anyone performs. Corrected to 0.060 (~4.8 m/s, a hard slap).
  - Accepted deviation: emission moved from _physics_process into
    poke_update/poke_end. Better - it emits at the point of decision, and in
    production poke_update is called from _physics_process anyway.
  - Noted for on-device: two concurrent hands on ONE cap now arm per-source
    rather than sharing one aggregate-depth hysteresis. Low probability given
    the cap radius, but a real difference.
  - Fix pass 1 landed (7862a09). Review APPROVED; reviewer independently
    re-derived the threshold algebra, the cap-animation equivalence, both new
    tests' geometry, and confirmed leave_bounds is the ONLY change to the
    evaluator.
  - Review Important (plan-mandated, MINE): source_id is keyed by LOOP POSITION
    over the interactor group. Harmless pre-conversion because the button held
    no per-source state; it now indexes _penetrations, _pins, _pressed_sources
    AND the evaluator's in_front/history/pressed. If group membership or order
    changes between frames - a controller reconnecting - indices shift and one
    physical hand inherits another's armed state. Fix pass 2 keys by instance
    id instead. Nearly impossible to reproduce deliberately, which is exactly
    why it had to be caught by reading.
  - Fix pass 2 (25b468c): keyed by a dictionary-backed dense counter, NOT the
    get_instance_id()*2+hand the controller suggested - Godot instance IDs
    carry a high RefCounted bit, so arithmetic on them risks 64-bit overflow.
    Using the id only as a dictionary key sidesteps it. Good call by the agent.
  - The reordering test drives the real _physics_process group path, and
    reverting to position-keying reproduces a WRONG-HAND PRESS off a single
    deep sample. That is the guard the finding needed.

Task 5: complete (commits 5c9aa45..25b468c, review approved, two fix passes).

Task 6: implemented (commit 2292fbb), review pending.

### HARNESS DEFECT FOUND IN TASK 6 - affects every suite in this repo
A test function that hits a runtime error ABORTS SILENTLY: _init continues to
the next test, and the suite prints its PASS line and exits 0. A crashed test
is indistinguishable from a passing one. Verified empirically with a probe on
Godot 4.7.stable, not inferred.

A wrapper counter does NOT detect it - the abort unwinds only the erroring
function, so `_run(fn); _completed += 1` still increments. Also verified.
Detection must be external: scan process output for SCRIPT ERROR / ^ERROR:.

BASELINE TAKEN IMMEDIATELY (controller): all eight suites re-run with error
counting - test_poke_fidelity, test_ui_canvas_pointer, test_grab_feel,
test_hand_conditioning, test_interaction_arbiter, test_gesture_foundation,
test_adaptive_contact, test_eye_height_calibrator. Every one:
exit=0 scripterrors=0, genuine PASS. Nothing is currently hiding, so every
green result reported in this plan holds.

Plan amended: Task 8 gains a Step 0 creating tools/run_tests.ps1, which fails
on a script error as well as a non-zero exit, and Step 1 now runs all eight
suites through it. The scripterrors column - not the PASS text - is the proof.
This generalises well beyond this plan and is worth keeping.

Task 6: complete (commit 2292fbb, review approved, no Critical/Important).
  - Reviewer independently re-derived the pin math and confirmed the two
    mutations hit two DISTINCT tests rather than one catching both.

Task 7: IN PROGRESS (implementer commit cd63218; fix pass 1 in flight)
  - Plan corrected twice BEFORE dispatch, both by checking the plan against
    the tree: (a) XRPokeStation is instanced only in control_panel_demo.tscn,
    while poke_playground_demo.tscn duplicates the wiring in its own script and
    never touches the station - the original file list would have wired a block
    the edited scene does not run; (b) the demo targets are now built in CODE
    rather than hand-authored into a 400-line .tscn, following
    XRPokeButton._build_visuals, which also makes the block self-contained.
  - Review Important: the DragHandle handler ACCUMULATED a delta that is
    cumulative-since-press. XRPokeable.dragged re-emits the total offset every
    physics tick, so adding it each tick saturates the +-0.04 clamp in ~4
    frames and freezes - a snap-and-stick where a slide was intended. The
    plan's own wiring SET the position; the implementation deviated to +=.
  - Nothing the implementer ran could have caught it: the liveness verifier
    asserted static state (interpret_drag == true) and never exercised a drag.
    Fix pass adds an evaluator-level test pinning the cumulative contract.
  - Fix pass 1 (0722540). The implementer confirmed the evaluator-level test
    did NOT catch the handler bug (it asserts the signal, not the consumer),
    said so, and closed the gap with a SECOND station-level end-to-end test
    that did catch it - failing at the exact predicted accumulate-then-clamp
    value (0.040 vs 0.030). That is the response the finding needed.

Task 7: complete (commits cd63218..0722540, review clean after one fix pass).

Task 8: complete for Steps 0-5 (commits c77e742, bef5f47, 919b1b2, 9f960ef;
  review approved, no Critical/Important). Steps 6-7 are the ON-DEVICE EARN-IN
  and remain OPEN - they need a Quest and a human, and must not be simulated.

### THE RUNNER I SPECIFIED WAS ITSELF BROKEN (controller correction)
Step 0's script as I wrote it captured only stdout. Godot writes SCRIPT ERROR
and ERROR: to STDERR, so the scripterrors column could never have been anything
but zero - the tool built to catch lying tests was itself lying. My earlier
"all eight suites, zero script errors" claim rested on that broken measurement
and was unearned.
Fixed by the Task 8 implementer with `cmd /c "... 2>&1"` (OS-level merge,
avoiding PowerShell's ErrorRecord wrapping). Controller then verified
INDEPENDENTLY: a probe that crashes mid-test and still prints its own PASS with
exit=0 is now flagged (scripterrors=1, runner exits 1). All eight real suites
re-run genuinely clean. Also corrected the documented invocation - pwsh is not
installed here, it is `powershell -ExecutionPolicy Bypass -File`.

### Minor findings for the final whole-branch review to triage
- Task 1: is_pressed()/is_source_pressed() only exercised indirectly.
- Task 1: every fixture uses source_id 0; multi-source independence untested.
- Task 2: _make_profile() returns Resource, not XRPokeProfile.
- Task 2: XRPokeProfile reuses xr_poke_interactor.svg as its @icon.
- Task 3: _plane_u's near-parallel-to-UP branch (Y faces only) untested.
- Task 3: X_MINUS/Y_PLUS/Y_MINUS have no pokeable-level fixture.
- Task 6: the has_method("get_poke_pin")-false fallback branch is untested
  (only the INF branch is); multi-target tie-break unverified.
- Task 7: CancelTarget's poke rectangle (half_size 0.05) is ~2cm larger per
  side than its visible 0.06 box - deliberate, now commented.
- Task 8: tools/run_tests.ps1 interpolates $s unquoted into the cmd string; a
  suite path with a space or cmd metacharacter would break. Loud failure, not
  a silent false pass, but a real robustness gap in a checked-in tool.
- Task 8: XRPokeEvaluator._sources never prunes entries. Pre-existing, shared
  by all three adapters.

## FINAL WHOLE-BRANCH REVIEW (opus) - five Important findings, all fixed
Commits 841a9fc, 2db8230, 5b62718, 993c7e2.

I1. THE ABSTAIN RULE WAS A HOLE IN MY OWN DESIGN. In an AND gate an abstention
    is neutral; in the OR gate it is DECISIVE - it armed the press by itself and
    require_entry_through_face could not veto it. Verified: a lateral sweep that
    DWELLS presses after ~3 frames, once the fast samples age out of the 4-entry
    window. So "a sweep presses nothing" was false; it was "a sweep presses
    whichever key you stop on". Worse, _test_slow_creep_abstains_and_presses
    ASSERTED that behaviour - its subject was a lateral drift at depth, not a
    creep toward the surface.
    Final form: the guard now DECLINES (return false) rather than approving. A
    test that cannot judge direction must not vouch. Genuine slow creeps come
    from in front and are armed by the entry test. Deleting the guard outright
    was rejected: a stationary source has travel.z == 0 and travel_sq == 0, so
    the squared comparison reads 0 >= 0 = true, a blanket pass.
I2. A drag had no terminal event, so the station's DragHandle stayed in its
    held colour forever after the first drag. Added DRAG_ENDED.
I3. _plane_u mirrored BOTH drag axes on the default face (normal.cross(up)
    gives u = -X for Z_PLUS), so dragged reported the finger moving the wrong
    way and the handle slid away from it. Both drag fixtures hid this by feeding
    NEGATIVE world x and documenting the negation as a convention - a test
    written to the implementation. Fixed to up.cross(normal).
I4. All three station pokeables sat on their box MID-PLANE, so keys fired 5mm
    before contact and the pin clamped INSIDE the box - undercutting Task 6 on
    the very targets built to demo it. XRPokeable's doc now states the press
    plane is its own origin plane.
I5. A skim below press_depth then a jab was rejected by BOTH gates. The angle
    test now checks the most recent step as well as the whole window.

### tools/run_tests.ps1 was broken TWICE
First: captured stdout only, while Godot writes SCRIPT ERROR to stderr, so the
scripterrors column could never be non-zero.
Second: the DOCUMENTED invocation (powershell -File ... -Suite a,b,c) passed the
comma list as ONE string, so it ran one nonexistent path instead of eight
suites. The in-process form worked, which is why it went unnoticed.
Both fixed; both invocation forms now verified, and a crashing probe is still
correctly flagged.

## STATUS: all eight tasks complete. ON-DEVICE EARN-IN REMAINS OPEN.
