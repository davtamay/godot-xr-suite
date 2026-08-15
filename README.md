# godot-xr-suite

**Cross-platform XR building blocks for Godot 4.x** — WebXR in browsers,
native OpenXR APKs on headsets, and editor testing through Quest Link /
SteamVR, drag-and-drop by design. Think Meta's
Building Blocks or Unity's XRI + XR Hands, but easier: most blocks wire
themselves the moment you drop them in.

## Quick start: define exports, then build

1. Enable the `godot_xr_interaction_toolkit` plugin → the **XR Suite** dock
   appears with the full catalog.
2. Add the Web and/or Android presets you want under **Project > Export**.
   WebGPU lives in each Web preset; Universal XR APK lives in each Android
   preset. There is no second target selector.
3. Run **Project Validator** in the XR Suite Validator dock. It reads those presets, shows
   the exact required addons and repairs missing XR configuration. Package
   cleanup runs automatically before every export. Hands and Scene
   Understanding are inferred from project references, with advanced
   include/strip overrides.
4. Click **New XR Scene** — you get a ready playground: rig + sessions +
   hands + teleportable floor + sun + sky + a grabbable in reach. (Or build
   it yourself: drop **XR Prefab** and **Floor (teleportable)** from the
   catalog and add a light.)

That's a working scene: look around, teleport, grab, poke, pinch — in the
browser via WebXR, or press Play straight to a headset over Quest Link (the
same scene carries both). When something doesn't behave on the headset, open
the **Scene Validator** (also in the dock): it checks scene structure for
everything that fails silently at runtime, with one-click fixes. Project
Doctor handles export presets, addons, and project settings.

## Test without a headset

The playground includes the **XR Simulator**: press Play flat and drive the
whole scene from your desk — WASD + drag to move, the mouse aims the ray,
right-click grabs, T teleports, Z/C snap-turn. Press **X** for simulated
HANDS: the realistic hand mesh renders live, right-click pinches through the
*real* pinch-select path, and number keys apply authored gesture poses (the
shipped presets plus your own Gesture Studio recordings) so real recognizers
fire against your scene logic. **H** shows the bindings on screen. The
simulator goes inert the moment a real XR session starts — safe to ship.
The **Debug Panel** block stays visible *inside* sessions and narrates every
interaction (grabs, teleports, sockets, gestures) for on-device debugging.

## Addons

| Addon | Layer | Purpose |
|---|---|---|
| `godot_webxr_kit` | Platform & embodiment | Session bootstraps (WebXR browser + OpenXR editor/native), the pre-wired rig, input adapters, per-hand input modality, profile-matched controller models, export shell. |
| `godot_xr_hands` | Hands provider | Hand visualization, the **Gesture Studio** (data-driven poses, record-first authoring, ghost-hand preview), thumb microgesture recognition. |
| `godot_xr_interaction_toolkit` | Interaction (consumer) | Interactors (ray, direct, poke, socket), interactables + affordances, locomotion, in-world UI panels + keyboard, the XR Suite authoring dock. |
| `godot_xr_scene_understanding` | Perception | Shared depth/scene-mesh managers with capability-selected WebXR, Meta OpenXR, and Android XR providers. |
| `godot_webxr_scene_understanding` | Optional WebXR perception provider | Browser acquisition for the neutral depth/mesh blocks, plus WebXR light estimation, hit-test/anchors, and compatibility paths. |
| `godot_webgpu` | Export | WebGPU web-export toggle + shader bake anchors (see Renderers below). |
| `godot_universal_xr_apk` | Export | One arm64 OpenXR development APK for Quest 3 + Android XR, with an idempotent setup command and manifest validator. |

**Layering rule:** providers produce input data (hands, platform events);
consumers turn input into interaction. Consumers may depend softly downward
(soft-loaded, inert when absent); providers never know consumers exist.

## Self-describing package graph

Every suite addon carries an `xr_package.cfg` declaring its stable package ID,
targets, capabilities, dependencies, layer, and runtime/export footprint.
The XR Suite dock combines those manifests with the Web/Android presets already
defined under Project > Export, then resolves transitive dependencies.

The interaction toolkit also carries a fallback catalog. This is intentional:
an addon that is not installed cannot provide its own manifest, but it still
needs to appear as a clearly named missing package. Installed manifests
override the fallback metadata. Incremental adoption is therefore:

1. Select the feature now.
2. Copy the listed addon folder later.
3. Reopen **Project Validator**; opening it always performs a fresh recheck.

Project Validator resumes configuration when all requirements are available.

Both are authoring metadata and are excluded from Web and APK runtime
packages. Note that nothing yet checks the fallback catalog against the
installed manifests, so a package added without updating both can drift.

Keeping all suite addons in the Godot project is supported and is the easiest
team workflow. “Installed” does not mean “shipped”: the neutral XR Suite
export plugin removes editor metadata and opposite-platform providers/tooling
from each artifact automatically.

The Project Validator report separates required or missing addons from addons
installed locally for another target. Target changes never delete project
files; keeping all addons available makes switching immediate while automatic
export-time cleanup controls what ships.

Before every export, XR Suite applies platform exclusions selected from the
active Godot export preset: Web
exports strip OpenXR vendor binaries, Universal APK tooling, and native
perception providers; Android exports strip browser shells, WebGPU tooling, and
WebXR-only perception providers/bridges. Editor-only files are stripped from
both. No validator button is required before building.

### Optional feature footprint

Enhanced Hands and Scene Understanding use **Auto (Recommended)** by default.
Auto scans project-owned `.gd`, `.tscn`, and `.tres` files for explicit suite
references; simply installing an addon does not count as using it. Adding or
removing a block is reflected automatically on the next export.

Project Validator says that automatic cleanup needs no action. Its collapsed
**Show Optional Feature Overrides** disclosure offers:

- **Force Include** for dynamic loading that static reference scanning cannot
  see.
- **Force Strip** for deliberately minimal exports. The dialog names the exact
  addon folders excluded and warns with the referring project files when a
  forced strip conflicts with detected usage.

In the checked-in suite, the installed source footprints are currently small:
roughly 0.41 MiB for Enhanced Hands and 0.29 MiB for shared + Web perception.
Final PCK/APK savings are usually smaller after compression and Godot import
processing. Stripping is therefore mostly dependency/build hygiene today, but
becomes more valuable when projects add larger hand models, recordings,
textures, or perception assets.

## Vocabulary used in the editor

| Term | Meaning |
|---|---|
| **Export Preset** | The source of truth for whether the project ships to Web, Android, or both. |
| **Project Validator** | Preset-driven validation and idempotent repair of addons and XR settings; package cleanup is automatic at export. |
| **Automatic Feature** | Hands or perception inferred from project scene/script references. |
| **Build Choice** | A preset-local decision such as WebGPU on one Web export. |
| **Required Addon** | An installable package selected automatically from the target and features. |
| **Scene Block** | A reusable node or scene the author adds to the current scene. |

“Capability” and “package” remain internal architecture terms. The editor uses
the more direct “Feature” and “Addon” wording.

## The Scene Blocks catalog

Everything below is in **XR Suite → Scene Blocks**. "Self-wiring" means drop it
anywhere — under the rig, under a hands mount, at the scene root — and it
finds the rig by itself (NodePath exports are overrides, not setup).

### Sessions & rig (`godot_webxr_kit`)
| Block | What you get |
|---|---|
| **XR Prefab** | Everything XR in one drop: runtime-neutral rig + conditional WebXR/OpenXR bootstraps + hands. On Web, the prefab automatically creates the browser Enter VR/AR UI. Native OpenXR starts directly without that browser UI. |
| **XR Rig** | The shared rig alone (origin, camera, controllers, interactors, modality, locomotion, poke) — for scenes with their own HUD. |
| **WebXR Session UI** | Browser-only Enter VR/AR buttons, capability readout, and status HUD; the WebXR bootstrap adopts it automatically. |
| **WebXR / OpenXR Bootstrap** | Session lifecycle per platform; each is inert on the other's platform, so ship both. |
| **Hands Mount** | Procedural or realistic tracked hands (`hand_style`); virtual meshes hide per hand while it drives a controller. |
| **Realistic Hands** | Rigged hand meshes (WebXR Input Profiles, MIT, bundled) skinned live to the tracked joints. |
| **Input Modality** (self-wiring, rig-default) | Per-hand controller↔hands switching + profile-matched controller models (bundled generic, device models fetched + cached at runtime). |
| **XR Simulator (desktop)** | Flat-test everything: simulated controllers *and* hands, gesture pose bench, on-screen hotkey help. Auto-inert in real sessions. |
| **Debug Panel (XR)** | The HUD that survives into the session: FPS, modality, and a live event log auto-wired to the suite's signals. |

### Interaction (`godot_xr_interaction_toolkit`)
| Block | What you get |
|---|---|
| **Locomotion** (self-wiring, rig-default) | Teleport arc + snap turn on the thumbsticks; the far selection ray hides while aiming (mutually exclusive). Optional **directional teleport**: rotate the thumbstick to choose your landing facing. External drivers (microgestures, your own gestures) steer the **same** arc via its intent API. |
| **Microgesture Locomotion** (opt-in) | Thumb swipes drive that same teleport/turn. Needs `godot_xr_hands`; inert without. |
| **Teleport Anchor** | A FIXED teleport destination (Unity's TeleportationAnchor): aim the arc at it to snap to that exact spot, optionally turned to face its forward. Drop-in, self-wires to the rig's locomotion. |
| **Continuous Move** | Smooth stick-walk + optional continuous turn (Unity's Continuous Move/Turn). Opt-in; auto-claims its stick so teleport stays on the other hand — the two coexist. |
| **Tunneling Vignette** | Comfort: darkens the view edges while you move to cut motion sickness. Watches camera motion, so it pairs with any locomotion; ignores teleport jumps. |
| **Climb Provider + Climb Interactable** | Climbing (Unity's Climb Provider): grab a handhold and moving your hand moves the rig the opposite way — pull down to rise, hand over hand. Handholds self-wire to the provider. |
| **Poke Interactor** (self-wiring, rig-default) | Fingertip touch: press panels, **drag sliders by touch**, push 3D buttons. Controller tips poke too. |
| **Poke Button (3D)** | A physical push-button that visibly depresses and fires with hysteresis. |
| **Pokeable** | Makes any object touch-sensitive: drop it in, set the face and press depth, get `pressed`/`released` per hand. The general form the poke button is one styling of. |
| **Floor (teleportable)** | Ground in one drop: visible floor + teleport collision; in AR passthrough the solid floor hides and a translucent grid marks the teleportable area. |
| **Grabbable** | Ready grabbable: swap the mesh, collision auto-fits, highlight included. |
| **Throwable** | A physics block you grab and **throw** — a RigidBody3D frozen while held (gravity won't fight the grab), thrown on release, so it flies, falls, and bounces with real gravity. |
| **Blaster** | Grab it, then fire. Bare hands **grip it with the lower fingers** (`hand_grab_style = GRIP`, index free) and **curl the index** to shoot — the trigger visibly depresses, so the gesture teaches itself; controllers grip-to-hold, trigger-to-fire. The *grab-it-then-use-it* pattern (guns, spray cans, drills). Drop **XRBlaster** inside any grabbable and point a Muzzle node. |
| **Hand Activator** | Fires a held object's **activate** from a **bare-hand gesture** — hands do what a controller trigger does. Drop inside a grabbable and pick a trigger finger (index for a gun, thumb for a spray can) or point it at any Gesture Studio pose. `MOMENTARY` (one shot) or `CONTINUOUS` (held-active). Emits `trigger_progress` for live feedback; reusable across every powered hand tool. |
| **Spray Can** | The **continuous** twin of the blaster, proving the parts compose: the *same* grip-grab + Hand Activator (set to `CONTINUOUS`) plus an **XRSprayer** that raycasts from the nozzle and paints any **Drawing Surface** it hits. A whole different tool from the same blocks. |
| **Grab Point** | Authored grip: parent INSIDE a grabbable where the hand should hold it — grabbing anywhere snaps the object into the palm, position *and* orientation (Unity attach transforms / Meta grab poses). Enable **Preview Hand** for an editor-only reference hand that grips the object exactly as it will in-headset — move the grab point until it looks right, no guessing. Per-hand filter + priority; multiple points, nearest wins. |
| **Pen + Drawing Surface** | A grabbable pen whose grab point is pitched into a natural writing pose, and a notepad its tip draws on — swap the mesh, drop a Drawing Surface, and any pen tip paints where it touches (runtime texture on a baked material, WebGPU-safe). |
| **Interaction Feedback** (rig-default) | Scene-wide feel: every interactable automatically gets hover glow + click sound + hand-correct controller haptics, styled by ONE swappable `XRFeedbackTheme` resource. Unity deprecated its affordance system and only announced a unified replacement — this ships it. |
| **Highlight / Socket Affordance** | Self-wiring child components: parent INSIDE the object, they find their interactable and mesh. Doubles as the per-object OVERRIDE for Interaction Feedback (objects with their own affordance are skipped). |
| **Socket Interactor** | Snap-zone that grabs and holds interactables. |
| **Dial / Lever / Drawer** | Grab-driven mechanisms (Unity's Dial/Lever/Drawer): a rotary knob, a hinged handle, a linear drawer — each constrains your grab to one degree of freedom and outputs a normalized 0–1 `value_changed`. Track the hand, so far-ray operation never bounces. |
| **Pinch-Twist Distance** | Far-grab distance by pinch-and-twist: hold the pinch and roll your wrist to push or pull the held object along the ray, leaving aim untouched. |
| **Surface Draggable** | Position constraint (Unity XRI / XR Hands transform constraints): grab a piece and slide it along only the local axes you allow — a magnet on a board (two axes), a bead on a wire (one). Parent-local, so it works on a tilted board; optional per-axis bounds. |
| **UI Panel (3D)** | In-world panel: ordinary Godot Controls, usable by ray *and* by touch. |
| **Keyboard (XR)** | In-world keyboard: `open(initial, prompt)` → `text_submitted` / `cancelled`. |

### Hands & gestures (`godot_xr_hands`)
| Block | What you get |
|---|---|
| **Gesture Recognizer** | Hand poses as data (`.tres`): per-hand start/end signals, hysteresis + hold built in, live tuning HUD (`show_debug`). Presets included. |
| **Gesture Recorder** | Hold a pose, get a gesture — targets from your recorded means, tolerances from your own jitter. See persistence below. |
| Sequences (`XRHandSequence`) | Motion gestures as staged data (conditions + feature deltas + time windows). Authoring format only for now — no shipped scene assigns sequences to a recognizer. |

### Perception (`godot_xr_scene_understanding`, `godot_webxr_scene_understanding`)
| Block | What you get |
|---|---|
| **Occlusion / Depth** | Real-world occlusion (hard/soft) with a drag-in occludees list. |
| **Scene Mesh** | The device's room geometry: visualize, occlude, label, collide. |
| **Light Estimation** | Objects lit by (and reflecting) the real room (Android XR). Ships in `godot_webxr_scene_understanding`. |
| **Synthetic Room** | A fake scanned room (surfaces, semantic labels, collision) fed through the real perception path, so the AR blocks work at your desk with no headset. Inert on web by default. |
| **Hit Test + Anchors** | Surface reticle + pinch-to-place spatial anchors. |

### WebGPU export (`godot_webgpu`)
| Block | What you get |
|---|---|
| **WebGPU toggle** | One checkbox on the web export preset produces the adaptive build. |
| **Bake / Font Bake Anchor** | Declare runtime-built materials / Label3D text so their shaders bake. |

## Authoring pipelines worth knowing

- **Record gestures like Unity's XR Hands strategy, one step shorter**: run
  the Gesture Studio over Quest Link from the editor — recordings land as
  plain `.tres` files on disk (`user://gestures`) — copy them into your
  project as shipped presets. In the **browser**, recordings persist in that
  browser's site data only (cleared with browsing data): great for per-user
  personalization, not for authoring. The Studio says this to users.
- **Controller models** follow the WebXR Input Profiles registry: the generic
  model ships bundled; device-specific models download once per device and
  cache. Runtime-parsed glTF materials are remapped onto pre-baked templates
  so they render on WebGPU exports.

## Bake-safety rules (web/WebGPU exports)

Shaders compile at export, not at runtime, on the WebGPU path:
1. No `StandardMaterial3D.new()` for rendered materials — duplicate a baked
   `.tres` and change uniforms (colors, texture-swaps, roughness).
2. Texture *presence* is codegen: swapping a texture on an already-textured
   template is safe; adding one to a textureless material is not.
3. Never VRAM-compress textures destined for WebGPU exports (import lossless).
4. Runtime-internal engine materials (Label3D…) need a bake anchor.

## Renderers

WebGL is the **recommended default** (full features, smooth XR everywhere).
The WebGPU build is the experimental opt-in chip on the launcher: Godot's
modern Mobile renderer running in XR — currently held back by the browsers'
WebXR-WebGPU bridge (an extra full-res copy per frame), not by the engine.
It lights up as browsers optimize; nothing you build against the suite cares
which renderer is active.

## Consuming the suite

**Locally (Windows, several projects on one machine)** — directory junctions
so every project sees edits instantly:

```powershell
foreach ($a in @("godot_webxr_kit","godot_xr_hands","godot_xr_interaction_toolkit","godot_xr_scene_understanding","godot_webxr_scene_understanding","godot_webgpu","godot_universal_xr_apk")) {
  New-Item -ItemType Junction -Path "<project>\addons\$a" -Target "<this repo>\addons\$a"
}
```

**Portably (team/CI)** — add this repo as a git submodule, or vendor a tagged
snapshot of `addons/*`.

Design docs and standing decisions live in [`docs/`](docs/) — start with
[`cross-platform-xr.md`](docs/cross-platform-xr.md),
`architecture-decision-2026-07-17.md`, and `gesture-authoring-design.md`.
