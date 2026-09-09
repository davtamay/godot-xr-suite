# Godot WebGPU (web)

Standalone tooling for shipping a Godot **web** export on the **WebGPU** backend.
No dependencies — drop it into any web project, XR or not. Two pieces:

- **Fast WebGPU setup** — one click configures the project + restarts the editor.
- a **`BakeAnchor`** node for declaring runtime-built materials so their shaders
  bake ahead of time.

Requires a custom Godot engine build that has the WebGPU driver + shader baker.
On a stock Godot it's a harmless no-op.

## Select WebGPU / WebXR / both

Selection always lives in each individual Web export preset, whether or not
XR Suite is installed. This lets one project keep a conservative WebGL preset
and a separate WebGPU preset without synchronized duplicate controls.

Project Validator reads those choices for validation but never changes them.
WebGPU options are registered only for Web presets and never appear in Android
profiles.

- **`WebGPU`** (this addon) → the WebGPU rendering backend. Turning it on bakes
  shaders automatically (the raw `Shader Baker` toggle is hidden - it's plumbing),
  points the web build at WebGPU, and shows an in-panel **status line**:
  `✓ WebGPU preset enabled` once the project is ready, or a warning +
  one-click setup popup if it isn't.
- **`Uses WebXR`** (Godot's own) → build an immersive **WebXR** app (also makes
  the WebGPU adapter XR-compatible when both are on).

Turn on **either, or both** — WebGPU and WebXR are independent and compose:
WebGPU alone = a non-XR WebGPU game, WebXR alone = a WebGL WebXR app, both =
WebXR running on WebGPU (adapting to WebGPU-XR where the browser supports it,
else WebGL-XR).

## Fast WebGPU setup (one click + restart)

A WebGPU build needs the editor on the **Mobile** renderer (so the shader baker
runs — it only runs when the *editor* uses a RenderingDevice renderer, fixed at
startup). That's the one fiddly bit, so **ticking `WebGPU` on an unconfigured
project pops a one-click dialog**: it sets `rendering_method = mobile`,
`rendering_method.web = mobile`, `driver.web = webgpu`, disables multiview XR
shaders, and **restarts the editor**. After the restart, tick `WebGPU` again — it
sticks, and the status line reads **✓ WebGPU preset enabled**. The status is
shown only when the editor is actually running the required renderer, so it
never claims ready before a needed restart.

## Runtime-built materials on WebGPU: declare-and-bake

WebGPU has no in-browser shader translation. Shaders are baked ahead of time at
export (SPIR-V → WGSL) — the same model as Unity's shader variant collections —
so a material whose **shader** is first seen at runtime has nothing baked and
fails on the WebGPU backend (`missing from the baked shader cache`). Engines that
author shaders in WGSL directly (Bevy) sidestep it; engines with their own shader
language (Godot, Unity) precompile. This is the industry-standard tradeoff.

Most runtime material changes need **nothing**: changing *uniforms* (albedo
colour, roughness, energy, swapping a texture) reuses an already-baked shader.
You only act when the **shader itself is new** — a `StandardMaterial3D` whose
feature flags differ from anything an exported scene already renders
(`emission_enabled`, transparency, a different cull/blend mode…), or a
`ShaderMaterial` with code no exported scene already uses.

For those, **declare them** with a `BakeAnchor`:

```gdscript
# 1. Save the material as a .tres with its codegen flags frozen (the flags that
#    change the shader — transparency, emission_enabled, cull mode, etc.).
# 2. Drop a BakeAnchor node into any scene reachable from your main scene and add
#    the .tres to its `materials` array (in the inspector or from code).
# 3. At runtime, load()/duplicate() that .tres — its shader is already baked.
```

`BakeAnchor` references each declared material on tiny hidden meshes so the
exporter's shader baker includes it; the references are invisible and freed at
runtime, so there is zero in-game cost. Harmless no-op on WebGL / non-web.

> Verified: a custom `ShaderMaterial` referenced *only* by a `BakeAnchor`, then
> applied to a mesh at runtime, renders on the WebGPU backend with no
> `missing from the baked shader cache` error.

## Texture compression: leave it off (for now)

In the Web preset, set **VRAM Texture Compression → For Desktop = off, For Mobile
= off** for a WebGPU build. The GPU samples a compressed format *natively* only if
the hardware exposes it (a WebGL extension / a WebGPU `texture-compression-*`
feature); otherwise you get console errors and missing textures. No single
GPU-compressed set covers your targets:

- **BC / S3TC** (For Desktop) — desktop GPUs expose it; **headset GPUs (Adreno)
  generally don't**.
- **ETC2 / ASTC** (For Mobile) — headset GPUs expose it on WebGL, but this
  driver's WebGPU backend **doesn't decode ETC2/ASTC yet** (deferred; it does BC
  only).

With both off, textures stay as PNG/WebP (small download) and upload as plain
RGBA8 — which every GPU and both backends handle. Costs more runtime VRAM, fine
for anything that isn't texture-heavy.

**Future:** a KTX2 / Basis Universal workflow — an addon step that converts
textures to KTX2 (via Khronos KTX-Software / `toktx`) so one asset **transcodes at
load** to the device's native format (BC on desktop, ETC2/ASTC on mobile). That
gives small download *and* small VRAM *and* broad compatibility. It pairs with
adding ETC2/ASTC (+ Basis transcode) to the WebGPU driver's format table (BC-only
today) — the right long-term fix for headset VRAM.

## Stripped templates: the build-profile check

Godot's web template carries the whole engine — every class registered, both
renderers, every server — whether or not your project touches any of it. A
custom template built against an engine *build profile* leaves the unused half
out. Measured on a 48-light gallery: **40.5 MB of wasm down to 26.8, and 7.11 MB
of brotli down to 4.99.** Same frame, same console.

The catch is that such a template fits **one project at one moment**: the
classes it left out are gone from the binary, so the day you add a node it does
not have, the scene fails to load — and nothing at export time says so.

So when this preset's `custom_template/release` has a `.build` file beside it
(which `misc/webgpu_scripts/build-web-profiled.sh` writes when it builds one),
exporting re-runs the editor's own detection and names any class the project has
started using since. An ordinary template has no such file and pays nothing.

## Contents

```text
addons/godot_webgpu/
  plugin.cfg / plugin.gd     # WebGPU toggle + conditional "Set up WebGPU rendering"
  webgpu_export_plugin.gd    # the "WebGPU" Web-export toggle (auto-bakes, hides Shader Baker)
  bake_anchor.gd             # BakeAnchor: declare runtime-built materials to bake
```
