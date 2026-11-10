"""Verify controlled export overrides never bless unrelated dirty source."""
import argparse, hashlib, json, os, subprocess, tempfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--editor',required=True);args=p.parse_args()
source=Path(__file__).resolve().parents[1]/'addons/godot_webgpu/editor/build_provenance.gd'
with tempfile.TemporaryDirectory(prefix='xr-provenance-') as temporary:
 root=Path(temporary); repo=root/'repo';repo.mkdir();(repo/'export_presets.cfg').write_text('base\n');(repo/'source.gd').write_text('source\n')
 def git(*a):return subprocess.check_output(['git','-C',str(repo),*a],text=True).strip()
 git('init');git('add','.');git('-c','user.name=Provenance Test','-c','user.email=test@example.invalid','commit','-m','fixture')
 script=root/'probe.gd';script.write_text('extends SceneTree\nfunc _initialize():\n var code = load(OS.get_environment("PROVENANCE_SOURCE"))\n var result = code._source_state(OS.get_environment("PROVENANCE_REPO"))\n var file = FileAccess.open(OS.get_environment("PROVENANCE_RESULT"),FileAccess.WRITE)\n file.store_string(JSON.stringify(result))\n file.close()\n quit()\n')
 env=os.environ.copy();env.update(PROVENANCE_SOURCE=source.as_posix(),PROVENANCE_REPO=repo.as_posix(),PROVENANCE_RESULT=(root/'result.json').as_posix())
 env.pop('GODOT_EXPORT_PRESET_OVERRIDE',None)
 def check(name,clean,verified):
  (root/'result.json').unlink(missing_ok=True)
  run=subprocess.run([args.editor,'--headless','--quit-after','10','--path',str(root),'--script',str(script)],env=env,capture_output=True,text=True,timeout=30)
  assert run.returncode==0 and (root/'result.json').exists(),(name,run.stdout,run.stderr)
  result=json.loads((root/'result.json').read_text());assert result['clean']==clean and result.get('export_override_verified',False)==verified,(name,result)
  print('PASS',name,flush=True)
 check('clean source',True,False)
 (repo/'export_presets.cfg').write_text('override\n')
 override={'root':repo.as_posix(),'path':'export_presets.cfg','revision':git('rev-parse','HEAD'),'base_blob':git('rev-parse','HEAD:export_presets.cfg'),'effective_sha256':hashlib.sha256((repo/'export_presets.cfg').read_bytes()).hexdigest()}
 env['GODOT_EXPORT_PRESET_OVERRIDE']=json.dumps(override);check('verified override retains clean=false',False,True)
 (repo/'source.gd').write_text('changed\n');check('other dirty source rejected',False,False);(repo/'source.gd').write_text('source\n')
 (repo/'extra.txt').write_text('untracked');check('untracked source rejected',False,False);(repo/'extra.txt').unlink()
 env['GODOT_EXPORT_PRESET_OVERRIDE']=json.dumps(dict(override,effective_sha256='bad'));check('wrong bytes rejected',False,False)
 env['GODOT_EXPORT_PRESET_OVERRIDE']=json.dumps(dict(override,revision='bad'));check('wrong revision rejected',False,False)
 env['GODOT_EXPORT_PRESET_OVERRIDE']=json.dumps(dict(override,base_blob='bad'));check('wrong base rejected',False,False)
 env['GODOT_EXPORT_PRESET_OVERRIDE']=json.dumps(dict(override,path='../export_presets.cfg'));check('escaped path rejected',False,False)

 (repo/'export_presets.cfg').write_text('base\n')
 (repo/'space dir').mkdir();git('mv','export_presets.cfg','space dir/export_presets.cfg');git('-c','user.name=Provenance Test','-c','user.email=test@example.invalid','commit','-m','spaced fixture')
 target=repo/'space dir/export_presets.cfg';target.write_text('override\n')
 override={'root':repo.as_posix(),'path':'space dir/export_presets.cfg','revision':git('rev-parse','HEAD'),'base_blob':git('rev-parse','HEAD:space dir/export_presets.cfg'),'effective_sha256':hashlib.sha256(target.read_bytes()).hexdigest()}
 env['GODOT_EXPORT_PRESET_OVERRIDE']=json.dumps(override);check('quoted preset path verified',False,True)
