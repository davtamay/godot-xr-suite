"""Validate profile boundaries, company provenance and deterministic archives."""
import contextlib
import hashlib
import io
import itertools
import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch
import package_webxr as package
import release_xr_suite as release


class Profiles(unittest.TestCase):
    def test_all_optional_combinations(self):
        catalog = json.loads((package.ROOT / "xr-suite.json").read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as temp, contextlib.redirect_stdout(io.StringIO()):
            for bits in itertools.product([False, True], repeat=3):
                path = Path(temp) / (str(bits) + ".zip")
                manifest = package.build(path, *bits)
                expected = set(catalog["required_modules"])
                for enabled, feature in zip(bits, ["hands", "scene_understanding", "webgpu_tools"]):
                    if enabled:
                        expected.update(catalog["optional_modules"][feature])
                with zipfile.ZipFile(path) as z:
                    names = z.namelist()
                    self.assertEqual({n.split('/')[1] for n in names if n.startswith('addons/')}, expected)
                    self.assertFalse(any('/.godot/' in n or '/tests/' in n and n.startswith('addons/') for n in names))
                    self.assertEqual(json.loads(z.read('module.json')), manifest)
                    for name, digest in manifest['files_sha256'].items():
                        self.assertEqual(hashlib.sha256(z.read(name)).hexdigest(), digest)
                    component = json.loads(z.read('addons/godot_webxr_kit/module.json'))
                    self.assertEqual(component['distribution']['version'], catalog['version'])
                    self.assertEqual(component['version'], manifest['components']['godot_webxr_kit'])
                    self.assertEqual(component['source']['revision'], manifest['source']['revision'])
                    self.assertIn('OSE', manifest['authors_metadata'])
                    self.assertEqual(manifest['source']['repository'], 'https://github.com/davtamay/godot-xr-suite')
                    self.assertEqual(manifest['license'], 'NOASSERTION')
                again = Path(temp) / (str(bits) + '-again.zip')
                package.build(again, *bits)
                self.assertEqual(path.read_bytes(), again.read_bytes())
                with self.assertRaises(FileExistsError):
                    package.build(path, *bits)
            full = Path(temp) / 'full.zip'
            manifest = package.build(full, profile='full')
            self.assertEqual(manifest['profile'], 'full')
            self.assertEqual(len(manifest['components']), 6)

    def test_release_guards(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(release, 'git', return_value=' M README.md'):
                with self.assertRaisesRegex(ValueError, 'clean checkout'):
                    release.release(Path(temp))
            with self.assertRaisesRegex(ValueError, 'outside'):
                release.release(package.ROOT / 'release')
            with patch.object(release, 'git', return_value=''), patch.dict('os.environ', {'GITHUB_REF': 'refs/tags/xr-suite-v999.0.0'}):
                with self.assertRaisesRegex(ValueError, 'tag'):
                    release.release(Path(temp))


if __name__ == '__main__':
    unittest.main()
