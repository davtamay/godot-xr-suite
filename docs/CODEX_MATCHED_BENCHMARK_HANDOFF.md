# Matched benchmark/provenance implementation — complete

Suite changes are isolated on codex/benchmark-provenance. Schema 2 records and verifies the sole controlled export preset edit, preserving clean=false for the actual modified worktree. Arbitrary dirty source remains disqualifying. Nine positive/negative tests cover clean state, exact override, unrelated changes, untracked files, wrong hashes/revisions/base blobs, path escape and spaces. Both primary and requested fallback Tint binaries are hashed; a missing requested fallback prevents complete identity.

A separate commit records only two new Godot 4.8 default mipmap fields in 38 tracked import metadata files. Source was normalized explicitly rather than excluded from cleanliness checks. No runtime interaction or engine changes.

Demo codex/matched-benchmarks has a matched unlit mesh-submission workload and engine CPU/GPU timing adapters for Godot (both thread modes), Babylon.js 9.35.0 and PlayCanvas 2.24.0. All 60 measured runs passed; all geometry masks match exactly, requested draw counts match, and CPU/GPU data is present. Timed source: demo 9a2ca61, suite 93979ec, engine 2f3fd8aa21. Later compiler-hash/path-handling changes affect provenance only; final export equivalence is checked separately. CPU scopes differ and GPU timestamps are quantized; no overall fastest-engine claim follows. Headset tests, PBR benchmarks and long soaks are not included.

Original worktrees and Monday snapshots remain untouched. Follow-up work should start on these isolated branches, not blindly reset/pull the old dirty engine checkout. Read the demo benchmarks/matched/README.md and final output report for reproduction and evidence.
