"""Export a fresh minimal XR Suite project with official and custom web templates."""
import argparse,contextlib,io,json,os,shutil,subprocess,zipfile
from pathlib import Path
import package_webxr
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--stock-editor',type=Path,required=True);p.add_argument('--stock-templates',type=Path,required=True);p.add_argument('--custom-engine',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
out=a.output.resolve()
if out.exists() and any(out.iterdir()):raise ValueError('Use a new output directory')
out.mkdir(parents=True,exist_ok=True)
with contextlib.redirect_stdout(io.StringIO()):manifest=package_webxr.build(out/'minimal.zip')
assert not manifest['source']['dirty']
for engine in ['Stock','Custom']:
 project=out/('project-'+engine);project.mkdir()
 with zipfile.ZipFile(out/'minimal.zip') as z:z.extractall(project)
 for name in ['suite_browser.gd','suite_browser.tscn']:shutil.copyfile(Path(__file__).parent/'fixtures'/name,project/name)
 method='gl_compatibility' if engine=='Stock' else 'mobile'
 (project/'project.godot').write_text('config_version=5\n[application]\nconfig/name="XR Suite browser compatibility"\nrun/main_scene="res://suite_browser.tscn"\n[display]\nwindow/size/viewport_width=1280\nwindow/size/viewport_height=720\n[rendering]\nrenderer/rendering_method="'+method+'"\nrenderer/rendering_method.web="'+method+'"\nrendering_device/driver.web="webgpu"\n[editor_plugins]\nenabled=PackedStringArray("res://addons/godot_xr_interaction_toolkit/plugin.cfg", "res://addons/godot_webxr_kit/plugin.cfg")\n',encoding='utf-8')
 editor=a.stock_editor if engine=='Stock' else a.custom_engine/'bin/godot.windows.editor.x86_64.console.exe'
 env=os.environ.copy();env.update(GODOT_TINT_PATH=str(a.custom_engine/'bin/tint.exe'),GODOT_TINT_PATH_FALLBACK=str(a.custom_engine/'bin/tint-extended.exe'))
 def run(name,cmd):
  with (out/(name+'.log')).open('w',encoding='utf-8') as f:r=subprocess.run([str(x) for x in cmd],env=env,stdout=f,stderr=subprocess.STDOUT,timeout=300)
  text=(out/(name+'.log')).read_text(encoding='utf-8',errors='replace')
  if r.returncode or any(x in text for x in ['SCRIPT ERROR','Parse Error','could not start the Tint translator']):raise RuntimeError(name+' failed')
 run(engine+'-import',[editor,'--headless','--xr-mode','off','--path',project,'--import'])
 for mode in ['Web','WebThreads']:
  threaded=mode=='WebThreads'
  template=a.stock_templates/('web_release.zip' if threaded else 'web_nothreads_release.zip') if engine=='Stock' else a.custom_engine/'bin'/('godot.web.template_release.wasm32.zip' if threaded else 'godot.web.template_release.wasm32.nothreads.zip')
  (project/'export_presets.cfg').write_text('[preset.0]\nname="Web"\nplatform="Web"\nexport_filter="all_resources"\n[preset.0.options]\ncustom_template/release="'+template.as_posix()+'"\nvariant/thread_support='+str(threaded).lower()+'\nshader_baker/enabled='+str(engine=='Custom').lower()+'\nhtml/export_icon=false\nhtml/custom_html_shell="res://addons/godot_webxr_kit/web/company_webxr_shell.html"\n',encoding='utf-8')
  dest=out/engine/mode;dest.mkdir(parents=True)
  run(engine+'-'+mode+'-export',[editor,'--xr-mode','off','--path',project,'--export-release','Web',dest/'index.html'])
  print(engine,mode,'EXPORTED',flush=True)
