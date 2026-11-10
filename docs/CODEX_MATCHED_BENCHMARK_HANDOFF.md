# Matched benchmark work — in progress

Isolated suite branch codex/benchmark-provenance verifies the matrix exporter's controlled preset edits without calling an actually dirty worktree clean. Source revision, base Git blob, effective bytes and exact dirty-path set must agree. Unrelated dirty files and untracked source remain disqualifying. Eight positive/negative provenance checks pass.

Demo implementation is on codex/matched-benchmarks at C:/Users/davta/work/engine-demo-merge/demo. Shared deterministic cube workloads, pinned Babylon.js 9.35.0 / PlayCanvas 2.24.0 and engine CPU/GPU profiler adapters are being validated. No engine modifications are planned: existing RenderingServer viewport timing APIs are reused. Do not overlap benchmark/provenance files until final handoff. Original dirty worktrees, published branches and Monday refs remain untouched. Headset testing is deferred.
