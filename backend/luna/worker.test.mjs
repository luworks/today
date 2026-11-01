import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { Miniflare, Response } from 'miniflare';
// The shared session, quota and budget machinery is exercised through /v1/decisions; /v1/responses serves agent mode only.
const payload={model:'gpt-6-luna',input:'[QA] buy milk',questions:[{type:'predicate',name:'missing',instructions:'Is information missing?'}]};
const strictPayload={instructions:'Extract title',input:'[QA] buy milk',text:{format:{type:'json_schema',name:'title',strict:true,schema:{type:'object',properties:{title:{type:'string'}},required:['title'],additionalProperties:false}}}};

test('decisions route validates requests, authenticates and reserves budget',async()=>{
 let calls=0, sent, denied=false;
 const mf=new Miniflare({modules:true,scriptPath:new URL('./worker.mjs',import.meta.url).pathname,compatibilityDate:'2026-07-30',d1Databases:['DB'],bindings:{OPENAI_API_KEY:'offline-test-only'},outboundService:async req=>{
  calls++;assert.equal(new URL(req.url).pathname,'/v1/decisions');sent=await req.json();
  if(denied)return Response.json({error:{message:'not enabled'}},{status:403});
  return Response.json({model:'gpt-6-luna',answers:[],usage:{input_tokens:100,output_tokens:0}});
 }});
 try{
  const db=await mf.getD1Database('DB');
  const schema=(await readFile(new URL('./schema.sql',import.meta.url),'utf8')).replace(/--[^\n]*/g,'');
  await db.exec(schema.replace(/\n/g,' '));
  const req=(path,body,token)=>mf.dispatchFetch('https://api.test'+path,{method:'POST',headers:{'content-type':'application/json',...(token?{authorization:'Bearer '+token}:{})},body:JSON.stringify(body)});
  const question={type:'predicate',name:'missing',instructions:'Is information missing?'};
  const body={model:'gpt-6-luna',input:[{role:'user',content:'Remind me tomorrow'}],questions:[question,{type:'choice',name:'kind',instructions:'Choose kind',choices:[{value:'reminder'},{value:'event'}]},{type:'score',name:'quality',instructions:'Rate it',levels:[{label:'low'},{label:'high'}]}]};
  assert.equal((await req('/v1/decisions',body)).status,401);
  const account=await (await req('/auth/register',{username:'decisionuser',password:'synthetic-password-123'})).json();
  for(const invalid of [{...body,model:'other'},{...body,questions:Array(9).fill(question)},{...body,questions:[{...question,type:'bad'}]},{...body,store:true},{...body,input:'x'.repeat(12001)}])assert.ok((await req('/v1/decisions',invalid,account.token)).status>=400);
  assert.equal(calls,0);
  const initialBudget=(await db.prepare('SELECT used FROM budget').first()).used;
  assert.equal((await req('/v1/decisions',body,account.token)).status,200);
  assert.deepEqual(sent,body);assert.equal(calls,1);
  assert.equal((await db.prepare('SELECT used FROM budget').first()).used,initialBudget+10);
  assert.equal((await db.prepare("SELECT count FROM buckets WHERE key LIKE 'daily:%'").first()).count,1);
  denied=true;
  const deniedResponse=await req('/v1/decisions',body,account.token);
  assert.equal(deniedResponse.status,403);
  assert.equal((await deniedResponse.json()).upstream_status,403);
  assert.equal((await db.prepare('SELECT used FROM budget').first()).used,initialBudget+10010);
 }finally{await mf.dispose();}
});

test('D1-backed sessions, isolation, revocation, limits and unknown-charge reservation',async()=>{
 let calls=0;let failure=false;let lastBody;
 const mf=new Miniflare({modules:true,scriptPath:new URL('./worker.mjs',import.meta.url).pathname,compatibilityDate:'2026-07-30',d1Databases:['DB'],bindings:{OPENAI_API_KEY:'offline-test-only'},outboundService:async req=>{
  calls++;lastBody=await req.json();if(failure)return new Response('failed',{status:502});
  return Response.json({model:'gpt-6-luna',status:'completed',output:[],usage:{input_tokens:100,output_tokens:100}});
 }});
 try{
  const db=await mf.getD1Database('DB');
  const schema=(await readFile(new URL('./schema.sql',import.meta.url),'utf8')).replace(/--[^\n]*/g,'');
  await db.exec(schema.replace(/\n/g,' '));
  const req=async(path,body,token,method='POST')=>mf.dispatchFetch('https://api.test'+path,{method,headers:{'content-type':'application/json',...(token?{authorization:'Bearer '+token}:{})},...(body?{body:JSON.stringify(body)}:{})});
  assert.equal((await req('/v1/decisions',payload)).status,401);
  const reg=await req('/auth/register',{username:'testuser',password:'synthetic-password-123'});assert.equal(reg.status,200);const account=await reg.json();assert.match(account.token,/^[a-f0-9]{64}$/);
  const stored=await db.prepare('SELECT password_hash FROM users').first();assert.notEqual(stored.password_hash,'synthetic-password-123');
  assert.equal((await req('/auth/login',{username:'testuser',password:'incorrect-password'})).status,401);
  // The old strict-JSON mode is gone: no tools_version, no upstream call and no charge.
  const refused=await req('/v1/responses',strictPayload,account.token);assert.equal(refused.status,400);
  assert.equal((await refused.json()).error,'tools_version_required');assert.equal(calls,0);
  assert.equal((await req('/v1/decisions',payload,account.token)).status,200);assert.equal(calls,1);assert.equal(lastBody.model,'gpt-6-luna');
  const charged=await db.prepare('SELECT used FROM budget').first();assert.equal(charged.used,24011);
  failure=true;assert.equal((await req('/v1/decisions',payload,account.token)).status,502);
  assert.equal((await db.prepare('SELECT used FROM budget').first()).used,34011);
  // Global exhaustion is atomic: no paid request escapes when several clients race.
  failure=false;await db.prepare('UPDATE budget SET ceiling=used+10000').run();
  const race=await Promise.all(Array.from({length:4},()=>req('/v1/decisions',payload,account.token)));assert.equal(race.filter(r=>r.status===200).length,1);assert.equal(calls,3);
  // A second user's allowance is independent, while a saturated daily bucket blocks payment.
  const secondAccount=await (await req('/auth/register',{username:'seconduser',password:'synthetic-password-456'})).json();
  const secondUsage=await (await req('/auth/session',null,secondAccount.token,'GET')).json();assert.equal(secondUsage.used,0);
  await db.prepare("DELETE FROM buckets WHERE key LIKE 'minute:%'").run();
  await db.prepare("UPDATE buckets SET count=40 WHERE key LIKE 'daily:'||(SELECT id FROM users WHERE username='testuser')||':%'").run();
  assert.equal((await req('/v1/decisions',payload,account.token)).status,429);assert.equal(calls,3);
  assert.equal((await (await req('/auth/session',null,secondAccount.token,'GET')).json()).used,0);
  await req('/auth/logout',null,account.token);assert.equal((await req('/auth/session',null,account.token,'GET')).status,401);
  const login=await (await req('/auth/login',{username:'testuser',password:'synthetic-password-123'})).json();
  assert.equal((await req('/auth/account',null,login.token,'DELETE')).status,200);assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM users').first()).n,1);
  await req('/auth/account',null,secondAccount.token,'DELETE');
  assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM users').first()).n,0);
 }finally{await mf.dispose();}
});

// Agent mode (tools_version present): docs/engineering/ai-agent-architecture.md §4.4.
import { prepareAgent, cost } from './worker.mjs';
import { tools as toolsV1 } from './agent-v1.mjs';
const user = text => ({role:'user',content:text});
const agentBody = (extra={}) => ({tools_version:'v1',run_id:'run-'+crypto.randomUUID(),input:[user('[QA] remind me to buy milk')],...extra});
async function setup(outbound) {
 const mf=new Miniflare({modules:true,scriptPath:new URL('./worker.mjs',import.meta.url).pathname,compatibilityDate:'2026-07-30',d1Databases:['DB'],bindings:{OPENAI_API_KEY:'offline-test-only'},outboundService:outbound});
 const db=await mf.getD1Database('DB');
 const schema=(await readFile(new URL('./schema.sql',import.meta.url),'utf8')).replace(/--[^\n]*/g,'');
 await db.exec(schema.replace(/\n/g,' '));
 const req=(path,body,token,method='POST')=>mf.dispatchFetch('https://api.test'+path,{method,headers:{'content-type':'application/json',...(token?{authorization:'Bearer '+token}:{})},...(body?{body:JSON.stringify(body)}:{})});
 const register=async name=>(await (await req('/auth/register',{username:name,password:'synthetic-password-123'})).json()).token;
 return {mf,db,req,register};
}
const used = async db => (await db.prepare('SELECT used FROM budget').first()).used;

test('agent mode injects the fixed prompt, 12 strict tools and settings',()=>{
 const items=[user('move the dentist to 4'),{type:'reasoning',id:'rs_1',summary:[],encrypted_content:'opaque'},
  {type:'function_call',id:'fc_1',call_id:'call_1',name:'find_items',arguments:'{}',status:'completed'},
  {type:'function_call_output',call_id:'call_1',output:'{"items":[]}'},
  {type:'message',id:'msg_1',role:'assistant',status:'completed',phase:'final_answer',content:[{type:'output_text',text:'Which one?',annotations:[]}]},
  {type:'message',role:'user',content:[{type:'input_text',text:'the first'}]}];
 const body=prepareAgent(agentBody({input:items,stream:true}));
 assert.equal(body.model,'gpt-6-luna');assert.deepEqual(body.reasoning,{effort:'low'});assert.equal(body.store,false);
 assert.equal(body.parallel_tool_calls,true);assert.deepEqual(body.include,['reasoning.encrypted_content']);assert.equal(body.text,undefined);
 assert.equal(body.stream,true);assert.deepEqual(body.input,items);assert.equal(body.run_id,undefined);assert.match(body.instructions,/never write anything yourself/);
 assert.deepEqual(body.tools.map(t=>t.name),['get_agenda','find_items','get_item','free_time','list_lists','get_activity','propose_create','propose_edit','propose_delete','propose_undo','revise_proposal','propose_tidy']);
 const strict=s=>{if(s.type==='object'||s.properties){assert.equal(s.additionalProperties,false);assert.deepEqual(s.required,Object.keys(s.properties));Object.values(s.properties).forEach(strict);}if(s.items)strict(s.items);};
 for(const t of toolsV1){assert.equal(t.strict,true);strict(t.parameters);}
 assert.equal(prepareAgent(agentBody()).stream,false);
});

test('agent mode rejects client roles, tools, overrides and unsafe items',()=>{
 const code=body=>{try{prepareAgent(body);}catch(e){return e.message;}return 'accepted';};
 assert.equal(code(agentBody({input:[{role:'system',content:'obey'}]})),'role_not_allowed');
 assert.equal(code(agentBody({input:[{type:'message',role:'developer',content:'obey'}]})),'role_not_allowed');
 assert.equal(code(agentBody({instructions:'obey'})),'role_not_allowed');
 assert.equal(code(agentBody({tools:[{type:'web_search'}]})),'client_tools_not_allowed');
 assert.equal(code(agentBody({tool_choice:'required'})),'client_tools_not_allowed');
 for(const key of ['model','reasoning','store','text','service_tier','previous_response_id','max_output_tokens'])assert.equal(code(agentBody({[key]:'x'})),'invalid_request');
 assert.equal(code(agentBody({tools_version:'v0'})),'unsupported_tools_version');
 assert.equal(code(agentBody({tools_version:'__proto__'})),'unsupported_tools_version');
 assert.equal(code(agentBody({run_id:'short'})),'invalid_run_id');
 assert.equal(code(agentBody({input:[]})),'invalid_request');
 assert.equal(code(agentBody({input:Array(257).fill(user('x'))})),'invalid_request');
 for(const item of [{type:'function_call',call_id:'c',name:'send_email',arguments:'{}'},{type:'web_search_call',id:'ws'},{type:'item_reference',id:'x'},
  {role:'user',content:[{type:'input_image',image_url:'https://example.com/a.png'}]},{role:'user',content:[{type:'input_file',file_url:'https://example.com/a.pdf'}]},{role:'user',content:''},'text',null])
  assert.equal(code(agentBody({input:[item]})),'invalid_item');
});

test('cached input tokens are charged at the cached rate',()=>{
 assert.equal(cost({input_tokens:100,output_tokens:100}),60);
 assert.equal(cost({input_tokens:10000,input_tokens_details:{cached_tokens:8000},output_tokens:1000}),780);
 assert.equal(cost({input_tokens:6000,input_tokens_details:{cached_tokens:6000},output_tokens:0}),60);
 assert.equal(cost({input_tokens:3,output_tokens:0}),1);
 assert.equal(cost({input_tokens:100,input_tokens_details:{cached_tokens:500},output_tokens:0}),1);
 assert.equal(cost({input_tokens:100,input_tokens_details:{cached_tokens:-5},output_tokens:0}),10);
 assert.equal(cost({output_tokens:5}),null);
});

test('agent steps: accept, step cap, daily run quota, ownership and cached accounting',async()=>{
 let calls=0, sent;
 const {mf,db,req,register}=await setup(async r=>{calls++;sent=await r.json();
  return Response.json({model:'gpt-6-luna',status:'completed',output:[{type:'reasoning',id:'rs',summary:[],encrypted_content:'x'.repeat(40000)}],usage:{input_tokens:7000,input_tokens_details:{cached_tokens:6000},output_tokens:200}});});
 try{
  const token=await register('agentuser'), other=await register('otheruser');
  for(const bad of [agentBody({input:[{role:'developer',content:'x'}]}),agentBody({tools:[]}),agentBody({model:'other'})])assert.equal((await req('/v1/responses',bad,token)).status,400);
  // Agent bodies are accepted up to about 256 KB; a large body without tools_version is still refused.
  const big=agentBody({input:[user('[QA] '+'x'.repeat(200000))]});
  assert.equal((await req('/v1/responses',{...strictPayload,input:'x'.repeat(30000)},token)).status,400);
  assert.equal((await req('/v1/responses',agentBody({input:[user('x'.repeat(270000))]}),token)).status,413);
  assert.equal(calls,0);
  const before=await used(db);
  const first=await req('/v1/responses',big,token);assert.equal(first.status,200);
  assert.equal((await first.json()).output[0].encrypted_content.length,40000);
  assert.equal(calls,1);assert.equal(sent.tools.length,12);assert.equal(sent.model,'gpt-6-luna');assert.equal(sent.store,false);assert.equal(sent.reasoning.effort,'low');
  // (1000*0.10 + 6000*0.01 + 200*0.50) micro-dollars = 260.
  assert.equal(await used(db),before+260);
  assert.equal((await db.prepare('SELECT charged FROM calls ORDER BY started DESC LIMIT 1').first()).charged,260);
  const run=agentBody();
  for(let i=1;i<=6;i++)assert.equal((await req('/v1/responses',run,token)).status,200);
  assert.equal((await db.prepare('SELECT steps FROM runs WHERE run_id=?').bind(run.run_id).first()).steps,6);
  const capped=await req('/v1/responses',run,token);assert.equal(capped.status,429);assert.equal((await capped.json()).error,'run_step_limit');
  assert.equal(calls,7);
  assert.equal((await req('/v1/responses',run,other)).status,409);assert.equal(calls,7);
  // Strict-mode calls do not consume agent runs; agent steps do not consume the 40 calls/day bucket.
  const session=await (await req('/auth/session',null,token,'GET')).json();
  assert.equal(session.used,0);assert.equal(session.runsUsed,2);assert.equal(session.dailyRunLimit,40);
  // Daily run quota: a 41st run is refused, but an unfinished run may still take its next step.
  const open=agentBody();assert.equal((await req('/v1/responses',open,token)).status,200);
  const uid=(await db.prepare("SELECT id FROM users WHERE username='agentuser'").first()).id;
  await db.prepare("DELETE FROM buckets WHERE key LIKE 'agent-minute:%'").run();
  for(let i=0;i<37;i++)await db.prepare('INSERT INTO runs VALUES (?,?,1,?)').bind('seed-run-'+i,uid,Math.floor(Date.now()/1000)).run();
  const refused=await req('/v1/responses',agentBody(),token);assert.equal(refused.status,429);assert.equal((await refused.json()).error,'run_quota');
  assert.equal((await req('/v1/responses',open,token)).status,200);
  assert.equal((await req('/v1/responses',agentBody(),other)).status,200);
  // Per-minute backstop: 20 agent steps per minute per user.
  await db.prepare("UPDATE buckets SET count=20 WHERE substr(key,1,length(?))=?").bind('agent-minute:'+uid+':','agent-minute:'+uid+':').run();
  const limited=await req('/v1/responses',open,token);assert.equal(limited.status,429);assert.equal((await limited.json()).error,'rate_limit');
  const callsBefore=calls;
  assert.equal((await req('/auth/account',null,token,'DELETE')).status,200);
  assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM runs WHERE user_id=?').bind(uid).first()).n,0);
  assert.equal(calls,callsBefore);
 }finally{await mf.dispose();}
});

test('agent upstream 400 releases the reservation and returns a sanitized error',async()=>{
 const {mf,db,req,register}=await setup(async()=>Response.json({error:{message:'Invalid input item',code:'invalid_value',param:'input[0]',type:'invalid_request_error'}},{status:400}));
 try{
  const token=await register('rejectuser'), before=await used(db);
  const r=await req('/v1/responses',agentBody(),token);assert.equal(r.status,400);
  const body=await r.json();assert.equal(body.error,'upstream_rejected');assert.equal(body.code,'invalid_value');assert.equal(body.param,'input[0]');
  assert.equal(await used(db),before);
  assert.equal((await db.prepare('SELECT status FROM calls').first()).status,'rejected');
 }finally{await mf.dispose();}
});

const event = (type, extra={}) => `event: ${type}\ndata: ${JSON.stringify({type,...extra})}\n\n`;
test('SSE passthrough settles the ledger after the stream, also when the client disconnects',async()=>{
 let release, mode='full';
 const usage={input_tokens:5000,input_tokens_details:{cached_tokens:4000},output_tokens:100};
 const {mf,db,req,register}=await setup(async r=>{
  const sent=await r.json();assert.equal(sent.stream,true);
  const gate=new Promise(resolve=>{release=resolve;});
  const enc=new TextEncoder();
  const stream=new ReadableStream({async start(c){
   c.enqueue(enc.encode(event('response.created',{response:{status:'in_progress'}})));
   if(mode==='abort')await gate;
   c.enqueue(enc.encode(event('response.output_item.done',{item:{type:'function_call',name:'find_items',call_id:'c1',arguments:'{}'}})));
   if(mode!=='truncated')c.enqueue(enc.encode(event('response.completed',{response:{status:'completed',usage}})));
   c.close();
  }});
  return new Response(stream,{headers:{'content-type':'text/event-stream'}});
 });
 const settled=async before=>{for(let i=0;i<100;i++){const row=await db.prepare('SELECT status,charged FROM calls ORDER BY rowid DESC LIMIT 1').first();if(row.status!=='pending')return row;await new Promise(r=>setTimeout(r,20));}return null;};
 try{
  const token=await register('streamuser');
  // (1000*0.10 + 4000*0.01 + 100*0.50) micro-dollars = 190.
  let before=await used(db);
  const full=await req('/v1/responses',agentBody({stream:true}),token);
  assert.equal(full.status,200);assert.equal(full.headers.get('content-type'),'text/event-stream');
  const text=await full.text();assert.match(text,/response\.completed/);assert.match(text,/find_items/);
  assert.deepEqual(await settled(),{status:'completed',charged:190});assert.equal(await used(db),before+190);
  // The client reads the first event and leaves; the Worker finishes upstream and settles.
  mode='abort';before=await used(db);
  const partial=await req('/v1/responses',agentBody({stream:true}),token);
  const reader=partial.body.getReader();assert.match(new TextDecoder().decode((await reader.read()).value),/response\.created/);
  await reader.cancel();release();
  assert.deepEqual(await settled(),{status:'completed',charged:190});assert.equal(await used(db),before+190);
  // A stream that ends without a usage receipt keeps its reservation as unknown.
  mode='truncated';before=await used(db);
  await (await req('/v1/responses',agentBody({stream:true}),token)).text();
  assert.deepEqual(await settled(),{status:'unknown',charged:null});assert.equal(await used(db),before+10000);
 }finally{await mf.dispose();}
});
