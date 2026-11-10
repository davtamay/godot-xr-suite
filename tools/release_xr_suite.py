"""Build both XR Suite profiles from one clean source revision; never publish."""
import argparse
import hashlib
import json
import os
from pathlib import Path
from package_webxr import ROOT, build, git


def release(output):
    output = output.resolve()
    if output == ROOT.resolve() or ROOT.resolve() in output.parents:
        raise ValueError("Release output must be outside the source checkout")
    if git("status", "--porcelain"):
        raise ValueError("Release requires a clean checkout")
    suite = json.loads((ROOT / "xr-suite.json").read_text(encoding="utf-8"))
    tag = os.environ.get("GITHUB_REF", "")
    if tag.startswith("refs/tags/") and tag != "refs/tags/xr-suite-v" + suite["version"]:
        raise ValueError("Release tag does not match xr-suite.json version")
    revision = git("rev-parse", "HEAD")
    names = {profile: f"XR-Suite-{profile.title()}-{suite['version']}.zip" for profile in suite["profiles"]}
    for name in [*names.values(), "release.json"]:
        if (output / name).exists():
            raise FileExistsError("Refusing to overwrite " + str(output / name))
    artifacts = {}
    for profile, name in names.items():
        manifest = build(output / name, profile=profile)
        if manifest["source"]["revision"] != revision or manifest["source"]["dirty"]:
            raise RuntimeError("Source changed during release")
        artifacts[profile] = {"file": name, "sha256": hashlib.sha256((output / name).read_bytes()).hexdigest(), "components": manifest["components"]}
    if git("rev-parse", "HEAD") != revision or git("status", "--porcelain"):
        raise RuntimeError("Source changed during release; discard incomplete artifacts")
    report = {"schema_version": 1, "id": suite["id"], "name": suite["name"], "version": suite["version"], "source": dict(suite["source"], revision=revision, dirty=False), "artifacts": artifacts}
    with (output / "release.json").open("x", encoding="utf-8") as stream:
        json.dump(report, stream, indent=2)
        stream.write("\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    print(json.dumps(release(parser.parse_args().output_dir), indent=2))
