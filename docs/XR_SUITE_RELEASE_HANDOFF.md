# XR Suite release ownership

XR Suite is maintained on the repository default branch, `master`.
`codex/xr-suite-release` is the delivery branch for the unified distribution.
The completed portable package, engine Closure candidate and Monday candidates
remain frozen. Runtime addon paths, IDs and versions remain stable.

`xr-suite.json` is the single suite catalog/version source (1.45.0).
`tools/package_webxr.py` builds Minimal, Full or selected optional capabilities;
`tools/release_xr_suite.py` is the one clean-checkout release entry point.
The GitHub workflow invokes its package tests and release command, uploads
artifacts and does not publish a GitHub release. Do not create a second runtime
fork, package repository, or product site for Minimal.

Company provenance: suite/profile version, component versions, exact source
repository/revision/dirty state, per-file hashes, archive hashes and retained
original credits. Existing licensing notice remains unchanged. See
PORTABLE_WEBXR_PACKAGE.md for upgrade/downgrade and manifest-ID migration.

Future release changes should increment the suite catalog version; bump component
versions only when those components change. Test all eight optional-module
combinations and both standard profiles. Keep company customizations outside the
managed addon directories. Coordinate before altering the installer contract.

## Default-branch integration scope

This delivery includes the validated portable package and its suite prerequisites:
export provenance/preset restoration, optional GPU-depth consumption, optional-hand
resource handling, explicit renderer selection, and the unified release pipeline.
It preserves Claude's existing input-timing/hand-pose commit `01d71c6` as an ancestor.
The integration is a normal fast-forward; no history rewriting or force push is used.
Only the suite repository is integrated. Engine, demo and Monday candidate refs
remain unchanged. Keep follow-up runtime work coordinated with the engine Closure
candidate `9c1d96cc56`; GPU-depth headset validation remains pending.

Use the default branch for subsequent suite fixes. Keep the Minimal and Full profiles
on the same source/version pipeline, preserve stable addon paths, and avoid reapplying
the portable-package or XR Suite commits once they appear in default-branch history.
