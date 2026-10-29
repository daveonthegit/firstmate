import {McpSession,readCredential,gate} from '../bin/fm-t3-mcp.mjs';
import fs from 'node:fs';
import cp from 'node:child_process';
const token=process.argv[2], root=process.argv[3];
const c=readCredential(token), s=new McpSession(c.origin,c.access_token);
function cli(args,expected=0,extra=[]){console.log('$ node bin/fm-t3-mcp.mjs '+args.join(' '));const r=cp.spawnSync(process.execPath,['bin/fm-t3-mcp.mjs',...args,'--token-file',token,...extra],{encoding:'utf8'});console.log(r.stdout.trim());if(r.stderr)console.log(r.stderr.trim());console.log('exit='+r.status);if(r.status!==expected)throw Error('unexpected exit');return JSON.parse(r.stdout);}
try {
const verified=await gate(s,c); console.log('GATE '+JSON.stringify(verified));
cli(['status']);
const p=cli(['project-ensure','--root',root]).projectId;
const caps=await s.call('orchestrator_capabilities',{});
console.log('LIVE CATALOG '+JSON.stringify(caps.providers.filter(p=>['codex','claudeAgent'].includes(p.providerInstanceId))));
const model=caps.providers.find(p=>p.providerInstanceId==='codex').models[0].id;
const selection=cli(['resolve-selection','--harness','codex','--instance','codex','--model',model,'--effort','high']).selection;
cli(['resolve-selection','--harness','codex','--instance','codex','--model',model,'--effort','not-a-real-effort'],4);
const cm=caps.providers.find(p=>p.providerInstanceId==='claudeAgent').models.find(m=>m.options?.some(o=>o.id==='fastMode'));
console.log('UPDATE DEFAULT '+JSON.stringify(await s.call('t3_project_update',{projectId:p,defaultModelSelection:{instanceId:'claudeAgent',model:cm.id,options:[{id:'fastMode',value:false}]}})));
cli(['resolve-selection','--harness','claude','--instance','claudeAgent','--model','default','--effort','high','--project',p]);
const launched=cli(['launch','--project',p,'--title','firstmate-live-compat-idle','--model-selection',JSON.stringify(selection)]);
console.log('BINDING '+JSON.stringify(await s.call(verified.toolFamilies.configuration==='earlier'?'t3_thread_configuration':'t3_thread_configure',{threadId:launched.threadId})));
cli(['requests','--thread',launched.threadId]);
fs.writeFileSync(root+'/answers.json',JSON.stringify({q1:'yes'}));
cli(['respond','--thread',launched.threadId,'--request','nonexistent-request','--answers-file',root+'/answers.json'],3);
cli(['archive','--thread',launched.threadId]);
fs.writeFileSync(root+'/wrong-token',JSON.stringify({...c,environment_id:'different-disposable-environment'}),{mode:0o600});
console.log('$ status with deliberately wrong pinned environment');
let r=cp.spawnSync(process.execPath,['bin/fm-t3-mcp.mjs','status','--token-file',root+'/wrong-token'],{encoding:'utf8'}); console.log(r.stdout.trim());console.log('exit='+r.status);if(r.status!==4)throw Error('identity guard not enforced');
} finally {await s.close();}
