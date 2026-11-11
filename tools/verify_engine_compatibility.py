"""Check every XR Suite module profile against official and custom Godot editors."""
import argparse
import contextlib
import io
import itertools
import json
import re
import subprocess
import zipfile
from pathlib import Path
import package_webxr


def run_checked(args, log, marker=None):
    with log.open('w', encoding='utf-8') as stream:
        result = subprocess.run([str(x) for x in args], stdout=stream,
                                stderr=subprocess.STDOUT, timeout=180)
    text = log.read_text(encoding='utf-8', errors='replace')
    if result.returncode or re.search(r'SCRIPT ERROR:|Parse Error:|(?:^|\n)ERROR:|ObjectDB.*leaked', text):
        raise RuntimeError(f'Engine failure: {log}')
    if marker and marker not in text:
        raise RuntimeError(f'Missing success marker {marker}: {log}')
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stock-editor', type=Path, required=True)
    parser.add_argument('--custom-editor', type=Path, required=True)
    parser.add_argument('--custom-revision', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        raise ValueError('Choose a new empty output directory; previous evidence is preserved.')
    output.mkdir(parents=True, exist_ok=True)
    results = []
    for bits in itertools.product([False, True], repeat=3):
        label = ''.join(str(int(x)) for x in bits)
        archive = output / f'profile-{label}.zip'
        with contextlib.redirect_stdout(io.StringIO()):
            manifest = package_webxr.build(archive, *bits)
        if manifest['source']['dirty']:
            raise RuntimeError('Commit suite changes before generating attested validation packages.')
        for engine, executable in [('stock', args.stock_editor), ('custom', args.custom_editor)]:
            name = f'{engine}-{label}'
            project = output / name
            project.mkdir()
            with zipfile.ZipFile(archive) as bundle:
                bundle.extractall(project)
            (project / 'project.godot').write_text(
                'config_version=5\n[application]\nconfig/name="XR Suite compatibility"\n'
                '[rendering]\nrenderer/rendering_method="gl_compatibility"\n'
                '[editor_plugins]\nenabled=PackedStringArray("res://addons/godot_xr_interaction_toolkit/plugin.cfg", '
                '"res://addons/godot_webxr_kit/plugin.cfg")\n', encoding='utf-8')
            common = [executable, '--headless', '--xr-mode', 'off', '--path', project]
            run_checked([*common, '--editor', '--import'], output / f'{name}-import.log')
            text = run_checked([*common, '--script', 'res://tests/portable_smoke.gd'],
                               output / f'{name}-runtime.log', 'PORTABLE_WEBXR_SMOKE=')
            report = json.loads(next(line.split('=', 1)[1] for line in text.splitlines()
                                     if line.startswith('PORTABLE_WEBXR_SMOKE=')))
            assert report['passed'] and report['hands_installed'] == bits[0]
            if engine == 'custom':
                assert report['engine']['hash'].startswith(args.custom_revision)
            else:
                assert report['engine']['build'] == 'official'
            results.append({'profile_bits_hands_scene_webgpu': label, 'engine_type': engine,
                            'package_source': manifest['source'], **report})
            (output / 'results.json').write_text(json.dumps({'passed': False, 'runs': results}, indent=2), encoding='utf-8')
            print(name, 'PASS', flush=True)
    (output / 'results.json').write_text(json.dumps({'passed': True, 'runs': results}, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
