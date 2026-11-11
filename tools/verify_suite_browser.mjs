import fs from 'node:fs';import path from 'node:path';import http from 'node:http';import assert from 'node:assert/strict';import {createRequire} from 'node:module';
const root=path.resolve(process.argv[2]),out=path.resolve(process.argv[3]),revision=process.argv[4];fs.mkdirSync(out,{recursive:true});
const {chromium}=createRequire(path.join(process.env.GODOT_WEBGPU_TESTBED||'C:/Users/davta/work/engine-demo-merge/testbed','package.json'))('playwright');
const server=http.createServer((req,res)=>{const name=decodeURIComponent(new URL(req.url,'http://localhost').pathname);if(name==='/favicon.ico'){res.writeHead(204).end();return;}const file=path.resolve(root,'.'+name);if(!file.startsWith(root+path.sep)||!fs.existsSync(file)||!fs.statSync(file).isFile()){res.writeHead(404).end();return;}const headers={'Content-Type':{'.html':'text/html','.js':'application/javascript','.wasm':'application/wasm'}[path.extname(file)]||'application/octet-stream'};if(name.includes('/WebThreads/'))Object.assign(headers,{'Cross-Origin-Opener-Policy':'same-origin','Cross-Origin-Embedder-Policy':'require-corp'});res.writeHead(200,headers);fs.createReadStream(file).pipe(res);});await new Promise(r=>server.listen(0,'127.0.0.1',r));
const results=[];
try{for(const engine of ['Stock','Custom'])for(const mode of ['Web','WebThreads'])for(const renderer of ['webgl','webgpu']){
 const item={engine,mode,renderer,messages:[],errors:[]};let browser;
 try{browser=await chromium.launch({channel:'chrome',args:['--mute-audio']});const page=await browser.newPage({viewport:{width:1280,height:720}});page.on('pageerror',e=>item.errors.push(String(e)));page.on('console',m=>{item.messages.push(m.type()+': '+m.text());if(m.type()==='error')item.errors.push(m.text());});
 await page.goto(`http://127.0.0.1:${server.address().port}/${engine}/${mode}/index.html?renderer=${renderer}`);await page.locator('#start-button').click();
 if(engine==='Stock'&&renderer==='webgpu'){
  await page.waitForFunction(()=>document.querySelector('#error').textContent.includes('cannot run WebGPU'),null,{timeout:15000});
  assert.equal(await page.evaluate(()=>typeof window.__portableReport),'undefined');
  assert.ok(item.errors.length>0&&item.errors.every(x=>x.includes('cannot run WebGPU')));item.expectedRejection=true;
 }else{
  await page.waitForFunction(()=>!!window.__portableReport,null,{timeout:90000});await page.waitForTimeout(1000);item.report=await page.evaluate(()=>window.__portableReport);
  assert.equal(item.report.renderer,renderer);assert.equal(item.report.driver,renderer==='webgpu'?'webgpu':'opengl3');assert.ok(item.report.interactables>0&&item.report.webxr_adapter);assert.equal(item.report.hands_installed,false);assert.equal(item.errors.length,0);
  if(engine==='Stock')assert.equal(item.report.version.build,'official');else assert.ok(item.report.version.hash.startsWith(revision));
 }
 item.hosting=await page.evaluate(()=>({isolated:crossOriginIsolated,shared:typeof SharedArrayBuffer!=='undefined'}));assert.deepEqual(item.hosting,{isolated:mode==='WebThreads',shared:mode==='WebThreads'});
 await page.screenshot({path:path.join(out,`${engine}-${mode}-${renderer}.png`)});item.passed=true;
 }catch(e){item.passed=false;item.failure=String(e);process.exitCode=1;}finally{await browser?.close();results.push(item);fs.writeFileSync(path.join(out,'results.json'),JSON.stringify(results,null,2));console.log(engine,mode,renderer,item.passed,item.failure||'');}
}}finally{await new Promise(r=>server.close(r));}
