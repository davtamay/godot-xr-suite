# Godot WebXR Kit

## Portable package and source

This addon comes from [davtamay/godot-xr-suite](https://github.com/davtamay/godot-xr-suite); the integration/demo repository is [davtamay/Godot_WebXR](https://github.com/davtamay/Godot_WebXR). Existing OSE author credits and third-party notices are preserved. Version and dependencies are in `module.json`; generated bundles additionally record the exact source commit and file hashes. See `LICENSE-NOTICE.md` for the repository's undeclared root license and retained third-party terms.

The minimal distribution installs two existing addon folders as one bundle: this runtime kit and `godot_xr_interaction_toolkit`. It includes the interaction toolkit and controller fallback models, but no custom engine, demo content, hand mesh addon, scene-understanding addon, or Android tooling. Standard Godot uses WebGL; installing this package does not add a WebGPU renderer. Fork-specific capabilities are optional and detected at runtime.

For the packaged installation instructions, hosting requirements, optional modules, and validation limits, see the bundle's root README. From the source repository, build it with `python tools/package_webxr.py --output webxr-minimal.zip`.


The WebXR platform layer for `godot_xr_interaction_toolkit`. Turns a browser
WebXR session into the poses and select/activate events the interaction toolkit
consumes, and provides the browser-side plumbing (custom HTML shell, capability
probe) that WebXR needs. Pure GDScript — no engine builds, no
export-template changes. Room mesh, occlusion, and depth sensing live in the
`godot_webxr_scene_understanding` addon.

**Requires** the `godot_xr_interaction_toolkit` addon (this kit builds on its
abstract `XRInputAdapter` and `XRHandTracker` helpers). Install both.

## Quick start: drop in the prefab (recommended)

Instance **one** scene under your scene's root and you have WebXR (browser) AND
OpenXR (Quest Link / SteamVR / Android XR) — controllers, hands, and grab with
**zero wiring**. On Web, the prefab automatically creates the browser Enter
VR/AR UI. Native OpenXR starts directly without that browser UI:

> **Instantiate Child Scene → `xr_prefab.tscn`** under your scene root. Done.

`webxr_prefab.tscn` remains as a compatibility alias for existing projects.
The root's `runtime_config` is the single user-facing policy surface. Assign an
`XRRuntimeConfig` resource to enable/disable either adapter, make browser hand
tracking required, opt into Meta simultaneous hands/controllers, or tune the
native headset timeout. The safe defaults are shared in
`runtime/default_xr_runtime_config.tres`.

- Works in new scenes and **drops into existing ones without fighting your
  camera** — your scene's `Camera3D` stays the flat view; the XR camera takes over
  only in-session.
- Make an object grabbable: add an `XRGrabInteractable` (with a `CollisionObject3D`
  child) anywhere in your scene.
- No browser session UI to build, no NodePaths to wire, no per-scene setup.

The prefab bundles the rig + both session bootstraps + procedural hands. Its
WebXR bootstrap auto-builds the browser UI; its OpenXR bootstrap starts the
native session directly. The one-time *project* setup for each runtime (OpenXR
toggle for in-editor testing, custom HTML shell for the WebXR export) is
documented below.

## Advanced: the rig only

You do **not** have to hand-wire the origin, controllers, manager, adapter, and
interactors. Instance the pre-wired rig scene once and add your grabbables:

```gdscript
const RIG := preload("res://addons/godot_webxr_kit/rig/webxr_rig.tscn")

func _ready() -> void:
    add_child(RIG.instantiate())   # XR origin + camera + 2 controllers + manager
                                   # + WebXRInputAdapter + per-hand ray/direct
                                   # interactors (line + reticle) + screen ray.
    # Then add any XRGrabInteractable(s) anywhere in the scene — they register
    # with the rig's manager automatically (found by group).
```

Or, in the editor: **Instantiate Child Scene → `webxr_rig.tscn`** under your
scene root, then add `XRGrabInteractable` nodes (each with a `CollisionObject3D`
child for the ray to hit). Session entry (requesting `immersive-vr`, setting
`viewport.use_xr`) stays in your project — see `runtime/webxr_bootstrap.gd` for
a working example. The rig has no scene-specific content, so it drops into any
project.

## Contents

```text
addons/godot_webxr_kit/
  xr_prefab.tscn                   # canonical drop-in: WebXR + OpenXR + hands
  webxr_prefab.tscn / .gd          # compatibility alias + shared prefab behavior
  plugin.cfg / plugin.gd
  rig/
    webxr_rig.tscn                # the pre-wired XR rig (used by the prefab)
  runtime/
    webxr_input_adapter.gd          # WebXRInputAdapter: WebXR session -> toolkit poses/events
    webxr_bootstrap.gd              # immersive-vr / immersive-ar session lifecycle
    openxr_bootstrap.gd             # OpenXRBootstrap: same scene -> headset in-editor (Link/SteamVR)
    browser_capabilities.gd         # WebGL2 / multiview / WebXR / WebGPU capability probe
    webxr_renderer.gd               # WebXRRenderer: read/switch the WebGL vs WebGPU backend
  web/
    company_webxr_shell.html        # custom HTML export shell + browser hand/depth JS bridges
```

## Required export wiring

The kit's WebXR hand tracking and depth preview ride on the custom HTML shell.
In your project's export preset (Web), set:

```
html/custom_html_shell="res://addons/godot_webxr_kit/web/company_webxr_shell.html"
```

The shell patches `navigator.xr.requestSession` / `requestAnimationFrame` and
publishes three `window` globals consumed by GDScript:

| JS global | Provided by | Consumed by |
|---|---|---|
| `CompanyWebXRHandBridge` | shell | `godot_xr_hands`' hand visualizer (optional) |
| `CompanyWebXRFailure` | `webxr_bootstrap.gd` writes it | surfaced to the page on session failure |

If you also install `godot_xr_hands`, its hand visualizer will use
`CompanyWebXRHandBridge` from this kit's shell for faster startup; without the
shell it falls back to `XRHandTracker`.

## Session lifecycle stays in your project

`webxr_bootstrap.gd` is a working example of requesting the session and setting
`viewport.use_xr`; wire its VR/AR buttons and status label in your scene. It
requests `hand-tracking` optional by default (`require_hand_tracking = false`),
so controller-only devices still start, and collects further session features
from nodes in the `webxr_feature_provider` group (see
`godot_webxr_scene_understanding`) — a scene only requests what it contains.

## Test on the headset in-editor (OpenXR)

`OpenXRBootstrap` (`runtime/openxr_bootstrap.gd`) is a drop-in sibling of the
WebXR bootstrap for **editor-time / native testing** via Meta Quest Link,
SteamVR, or Android XR's OpenXR runtime. Add it to your scene (the starter scene
already has it), enable **Project Settings → XR → OpenXR**, restart the editor,
start a runtime, and press **Play** — the *same scene* renders to the headset,
no export, no browser. It's **inert on web** (the WebXR bootstrap owns the
browser path), so leave both bootstraps in every scene and each activates on its
own platform. Because everything sits on the standard XR nodes, hands,
controllers, and interaction behave identically to the WebXR path — so you
iterate fast in-editor, then export to WebXR for the browser.

The reverse boundary is equally strict: `WebXRBootstrap` exits before creating
UI or touching browser APIs in native builds. `OpenXRBootstrap` exits on web.
Gameplay blocks therefore do not branch on platform; only the two session
adapters and optional capability providers do.

## WebGPU builds

`WebXRRenderer` (above) is the only WebGPU-aware piece here — it just reads or
switches the backend and works on any build. The WebGPU **build** tooling —
the one-checkbox WebGPU export toggle and the `BakeAnchor` node for baking
runtime-built materials — lives in the standalone **`godot_webgpu`** addon,
which this kit does not depend on. Install `godot_webgpu` if you want to ship
the WebGPU backend; see its README.

## Platform notes

- **Quest 3 / Quest Browser:** the proven path — controllers, hands, pinch
  select, VR and AR sessions all work.
- **Samsung Galaxy XR / tested Android XR browsers:** WebXR + WebGL2 present but
  no `OVR_multiview2` / `OCULUS_multiview`, so Godot WebXR stereo fails. Browser
  capability gap, not a kit/export issue.
- **AR depth / room mesh / occlusion:** moved to the
  `godot_webxr_scene_understanding` addon, which reports per-device status
  honestly (browser-flag-gated features, gpu-only depth grants, upcoming
  WebGPU paths).
- **Desktop / no XR session:** the adapter reports no poses and interactors idle;
  the scene stays usable as a flat preview.
