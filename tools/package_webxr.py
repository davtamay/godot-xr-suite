"""Build a reproducible XR Suite installation profile (Python 3.9+)."""
import argparse
import configparser
import hashlib
import json
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def git(*args):
    return subprocess.check_output(["git", "-c", "core.fsmonitor=false", *args], cwd=ROOT, text=True).strip()

def version(folder):
    config = configparser.ConfigParser()
    config.read(ROOT / "addons" / folder / "plugin.cfg", encoding="utf-8")
    return config["plugin"]["version"].strip('"')

def build(output, hands=False, scene=False, webgpu=False, profile="minimal"):
    suite = json.loads((ROOT / "xr-suite.json").read_text(encoding="utf-8"))
    if profile not in suite["profiles"]:
        raise ValueError("Unknown XR Suite profile: " + profile)
    if output.exists():
        raise FileExistsError(f"Refusing to overwrite {output}")
    selected = set(suite["profiles"][profile])
    selected.update(name for name, enabled in [("hands", hands), ("scene_understanding", scene), ("webgpu_tools", webgpu)] if enabled)
    features = sorted(selected)
    resolved_profile = next((name for name, values in suite["profiles"].items() if set(values) == selected), "custom")
    folders = list(suite["required_modules"])
    for feature in features:
        folders.extend(suite["optional_modules"][feature])
    folders = list(dict.fromkeys(folders))
    source = dict(suite["source"], revision=git("rev-parse", "HEAD"), dirty=bool(git("status", "--porcelain")))
    files = {}
    for folder in folders:
        base = ROOT / "addons" / folder
        for path in sorted(base.rglob("*")):
            relative = path.relative_to(base)
            if path.is_symlink():
                raise ValueError(f"Unresolved symlink in package: {path}")
            if not path.is_file() or any(part in {"tests", ".godot", ".git", "__pycache__"} for part in relative.parts) or path.suffix in {".import", ".pyc"}:
                continue
            files[path.relative_to(ROOT).as_posix()] = path.read_bytes()
    module_path = "addons/godot_webxr_kit/module.json"
    module = json.loads(files[module_path])
    module["source"].update(source)
    module["distribution"] = {"id": suite["id"], "name": suite["name"], "version": suite["version"], "profile": resolved_profile}
    files[module_path] = (json.dumps(module, indent=2) + "\n").encode()
    files["README.md"] = (ROOT / "docs/PORTABLE_WEBXR_PACKAGE.md").read_bytes()
    files["LICENSE-NOTICE.md"] = (ROOT / "addons/godot_webxr_kit/LICENSE-NOTICE.md").read_bytes()
    files["tests/portable_smoke.gd"] = (ROOT / "tools/test_portable_webxr.gd").read_bytes()
    manifest = {
        "schema_version": 2, "id": suite["id"], "name": suite["name"], "version": suite["version"],
        "profile": resolved_profile, "selected_optional_modules": features, "source": source,
        "components": {folder: version(folder) for folder in folders},
        "required_modules": suite["required_modules"], "available_optional_modules": suite["optional_modules"],
        "license": suite["license"], "license_notes": module["license_notes"],
        "authors_metadata": module["authors_metadata"], "compatibility": module["compatibility"],
        "entry_scene": module["entry_scene"], "html_shell": module["html_shell"],
        "files_sha256": {name: hashlib.sha256(data).hexdigest() for name, data in sorted(files.items())},
    }
    files["module.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    output.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation preserves existing user artifacts, including races.
    with output.open("xb") as stream, zipfile.ZipFile(stream, "w") as archive:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, data)
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
        for name, digest in manifest["files_sha256"].items():
            assert hashlib.sha256(archive.read(name)).hexdigest() == digest
    print(json.dumps({"output": str(output), "version": suite["version"], "profile": resolved_profile, "source": source, "components": manifest["components"], "files": len(files), "sha256": hashlib.sha256(output.read_bytes()).hexdigest()}, indent=2))

    return manifest

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--profile", choices=["minimal", "full"], default="minimal")
    parser.add_argument("--with-hands", action="store_true")
    parser.add_argument("--with-scene-understanding", action="store_true")
    parser.add_argument("--with-webgpu-tools", action="store_true")
    args = parser.parse_args()
    build(args.output, args.with_hands, args.with_scene_understanding, args.with_webgpu_tools, args.profile)
