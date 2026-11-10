# Matched benchmarks and provenance — completed

Codex completed this batch on isolated local branches. No push/merge or engine source change was made. Published branches, Monday snapshots and original dirty source are preserved.

## Work locations

- Demo tooling: C:/Users/davta/work/engine-demo-merge/demo, codex/matched-benchmarks.
- Suite provenance: C:/Users/davta/work/matched-bench-suite, codex/benchmark-provenance.
- Full demo export: C:/Users/davta/work/matched-demo-export, codex/matched-demo-export.
- Existing validated engine: U:/, codex/publish-engine at 2f3fd8aa21. Do not reset/pull the old dirty C:/ws/xr/engine/Godot_WebGPU checkout to it.

## Completed and proven

60 measured runs: 100/1000/5000 independent unlit indexed cubes, Godot single/threaded, Babylon.js 9.35.0, PlayCanvas 2.24.0; five rotated-order repetitions, 3-second warm-up, 5-second sampling. All passed geometry-mask equality (IoU 1.0), requested draw counts, CPU/GPU timing presence and Godot hosting/provenance checks. Six final-build Godot screens passed and exactly matched their measured reference screenshots. Both full-demo thread modes start successfully with complete identity. New threaded/single resource packs have parity except their identity manifests.

Existing RenderingServer viewport CPU/GPU timing was reused; no engine profiler patch was necessary. CPU scopes differ between engines, GPU readbacks are asynchronous/quantized and the browser was paced near 31 ms. Do not turn these results into whole-engine speedup ratios or an overall best-renderer claim. This is mesh submission, not PBR or XR. Headset tests and long soaks remain unrun.

Schema-2 provenance verifies only the controlled temporary preset change against revision/base blob/current bytes/dirty paths, keeps the actual clean=false state, and rejects unrelated source dirt. Primary and requested fallback Tint binaries are hashed. Nine positive/negative tests pass, including quoted paths. The isolated suite explicitly records 38 import metadata updates: only the two new default mipmap fields from Godot 4.8. Do not silently exclude import files from cleanliness checks.

## Artifact identities and remaining limits

Timed artifact sources: demo 9a2ca611508d4e7dca8118573556874156a041e0; suite 93979ec; engine 2f3fd8aa21. Final compiler-identity builds use suite d77939e3ca5bddf9050bbb666b72cb3aeb73da46; benchmark demo remains 9a2ca61 and full-demo checkout is 46b11ca. Later handoff-only commits do not change runtime source.

Exact timed exports are preserved at C:/Users/davta/work/engine-demo-merge/matched-measured-build. Final exports are matched-final-build and provenance-demo-final alongside it. Fresh Godot bakes regenerate serialized scene identifiers, so cross-rebuild byte identity is NOT claimed. The decoded benchmark scene differed in generated IDs; final images are identical. Full-demo rebuild diffs are retained, not waived as an equivalence pass.

Keep FP16/FP32 baking enabled in this fixture. The initial FP32-only fixture produced missing shaders on a device selecting FP16; enabling the matching variants fixed it. Investigate that opt-out/runtime-feature edge separately before changing product export defaults.

Read outputs/Matched-3D-benchmark-results.md and the manifest under C:/Users/davta/Documents/Codex/2026-11-09/explore-and-compare-architectural-approaches-x20-2 for full evidence, artifacts and reproduction. Next work: a shared PBR scene, more closely aligned CPU boundaries and explicitly configured higher-resolution GPU timing. Do not re-do the completed provenance or timestamp integration as new work.
