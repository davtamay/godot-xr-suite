# XR Suite release ownership

This follow-up changes distribution packaging only, on `codex/xr-suite-release`.
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
