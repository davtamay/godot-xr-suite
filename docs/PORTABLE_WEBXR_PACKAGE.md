# XR Suite 1.45.0 — installation profiles

Source: https://github.com/davtamay/godot-xr-suite
Demo/integration: https://github.com/davtamay/Godot_WebXR

This is a reusable distribution of the existing runtime kit and interaction toolkit, not a new XR engine. Original OSE metadata, upstream credits, and third-party notices remain intact. `module.json` records version, source commit, dependencies, selected modules, and hashes of distributed files. `LICENSE-NOTICE.md` explains the absence of a root repository license declaration.

Choose one complete profile: Minimal, or Full (which also includes the minimal runtime/toolkit). Do not install them as duplicate addon copies.

## Install in a company project

1. Extract the bundle into a staging folder. Copy its selected `addons/` folders (two for Minimal) into your project's `addons/`. If versions are already installed, review and replace them as a complete matched bundle; do not mix revisions or install duplicate renamed copies.
2. Open the project and let Godot import its resources. Enable Godot XR Interaction Toolkit in Project Settings > Plugins for the XR Suite authoring tools. Runtime scenes do not require an autoload.
3. Instance `res://addons/godot_webxr_kit/xr_prefab.tscn` under your scene root. For a complete example, run `res://addons/godot_webxr_kit/samples/webxr_starter.tscn`. Add toolkit grabbables, rays, touch/UI, and locomotion components as needed.
4. Assign an XRRuntimeConfig to the prefab to choose WebXR/OpenXR policy. For a browser-only product, disable the OpenXR adapter. Keep hand tracking optional unless your product requires it.
5. In each Web export preset set `html/custom_html_shell="res://addons/godot_webxr_kit/web/company_webxr_shell.html"`. Standard Godot web projects use Compatibility/WebGL. Use matching official editor/templates for that path.
6. Serve over HTTPS (localhost is suitable for desktop testing). Start immersive VR/AR from a user action. A headset cannot treat a plain HTTP LAN address as localhost.

Threaded exports require cross-origin isolation: `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`, with compatible headers on all dependencies. Single-threaded exports need no SharedArrayBuffer, but still need HTTPS and WebXR permissions. Choose the preset deliberately and record its provenance. The shell starts after clicking Start Godot App. Use `?renderer=webgl` or `?renderer=webgpu` to select explicitly; unsupported WebGPU requests fail visibly. Without an explicit choice, immersive-capable browsers default to WebGL and other capable browsers can use WebGPU. Optional product metrics can be injected through the export head include; the package requires no external metrics script.

## Optional capabilities

The minimal bundle includes controller and hand input adapters plus the interaction toolkit. Hand visuals/gesture recognition require `--with-hands`. Scene sensing requires `--with-scene-understanding`, which includes the neutral and WebXR providers. `--with-webgpu-tools` includes the optional WebGPU export tooling; actual WebGPU rendering still requires the custom engine and matching templates. Browser/GPU capabilities and the negotiated XR session determine which features work. No headset or GPU-depth support is promised merely because an API exists.

Example source build:

```
python tools/package_webxr.py --profile minimal --output XR-Suite-Minimal-1.45.0.zip
python tools/package_webxr.py --with-hands --output XR-Suite-With-Hands-1.45.0.zip
python tools/package_webxr.py --profile full --output XR-Suite-Full-1.45.0.zip
python tools/release_xr_suite.py --output-dir /path/outside/repository/release
```

The packager refuses to overwrite an existing output. It omits imported caches and addon test folders, retains UID files and asset notices, and reports dirty source state honestly. Source consumers can continue using the existing full-suite setup.ps1; the minimal distribution does not change that workflow.

## Network, storage and agent control

Device-specific controller models may be fetched from the WebXR Input Profiles registry CDN and cached in `user://`. A generic fallback is bundled. Set `model_repository_url` on XRInputModalityManager to your own registry mirror when a company deployment requires self-hosting. The HTML shell stores renderer preference in browser local storage. Review these behaviors against your product's hosting and offline requirements.

The simulator and remote actuator code are included, but remote control is not enabled by default. Keep it disabled in production unless the product intentionally exposes a controlled integration. Do not confuse an actuator/emulator test with measured headset tracking or compositor correctness.

## Compatibility evidence and limits

Validate this exact bundle in a fresh project with official Godot 4.7.1 and the isolated custom 4.8 renderer candidate. The supplied smoke test checks prefab construction, controller adapters, toolkit registration, and safe behavior without the optional addons. Browser exports are tested separately; native import/startup does not prove stock browser or headset behavior. See the delivered validation report for exact versions, results, and hashes.

Quest 3 and Galaxy XR headset testing remains pending: session entry/exit, controller/hand input, poses, stereo alignment, tracking loss/recovery, depth alignment where supported, performance, and browser permission/hosting behavior. Full Closure-enabled WASM CI and other Godot releases are not certified by this package.

## One product, one release pipeline

`xr-suite.json` owns the XR Suite distribution version and module selection.
The suite version (1.45.0) is independent of component versions: WebXR Kit remains
1.44.1 and Interaction Toolkit remains 1.83.2 in this release. Runtime addon IDs,
folders, resource paths and entry scenes have not been renamed. The former portable
bundle is now the XR Suite Minimal profile; there is no separate runtime fork.
The bundle manifest ID is now `godot_xr_suite` (schema 2); consumers of the old
`godot_webxr_portable_bundle` ID should update their manifest reader. Component IDs
remain stable. Existing `--with-*` packaging flags continue to work.

The single release command requires a clean source checkout and an output directory
outside it. It builds Minimal and Full, verifies archive contents/hashes, and writes
`release.json` with archive SHA-256 hashes and source commit. Custom module combinations
use the same packager. The GitHub workflow runs package tests and this same command;
it uploads build artifacts without publishing a GitHub release. Tags use
`xr-suite-v<version>` and must match the catalog version. Manual workflow runs are
also available. No separate product site or source repository is required.

## Company product upgrades and attribution

Keep the bundle-root `module.json`, `release.json`, README and license notice with your
product's dependency records. Pin the suite version, selected profile/modules, source
commit and archive hash together. Root `module.json` records the suite identity;
`addons/godot_webxr_kit/module.json` retains the component identity plus distribution
metadata. Both identify your source repository and exact packaged revision. Original
OSE authorship and third-party credits remain intact; packaging does not replace them
with company authorship or grant a new license.

To upgrade, back up and remove only the addon folders managed by the previous manifest,
then copy the newly selected profile as a matched set. Keep company customizations in
your own scenes/scripts so the addons can be replaced. When downgrading Full to Minimal,
first remove project references to optional modules, then remove the previously managed
optional folders. Do not delete unrelated addons. Review manifest differences and run
project import/export tests before shipping. Dirty development bundles are labeled;
the release pipeline rejects dirty checkouts.
