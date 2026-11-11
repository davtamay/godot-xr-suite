# Engine compatibility matrix

Run `python tools/verify_engine_compatibility.py --stock-editor <official-Godot-console> --custom-editor <fork-console> --custom-revision <commit> --output <new-directory>` from a clean suite checkout.

The runner packages all eight combinations of optional hands, scene understanding and WebGPU tooling. Each archive is imported and started in both editors: 16 real engine checks. It rejects parser/runtime errors, missing completion markers, leaked ObjectDB objects, wrong custom revisions and non-official stock builds. Every package retains its source repository, suite/component versions, exact revision and file hashes. Results report the actual engine versions rather than infer compatibility from executable names.

This verifies native import, toolkit instantiation, optional gesture resources and browser capability reporting in native preview. It does not establish immersive browser support or headset behavior. Run the shell capability tests and the demo repository's browser regression runner for those separate desktop layers. Stock Godot must report no WebGPU support; adding XR Suite does not add a renderer to the engine.

Existing release profiles and module folder names are unchanged. Run this gate before publishing a suite release or adopting a new standard/custom engine revision.

Browser compatibility is checked separately with `tools/export_suite_browser.py` and `tools/verify_suite_browser.mjs`. Supply checksum-verified official web templates, the official editor, and the custom engine directory. The exported fixture uses an actual minimal archive with its original module.json. The verifier covers WebGL on official Godot, WebGL/WebGPU on the fork, both thread modes, and explicit rejection of unsupported WebGPU on stock builds. It checks the real RenderingServer driver, toolkit registration, source engine revision, and hosting isolation. Browser startup is not an immersive headset session.
