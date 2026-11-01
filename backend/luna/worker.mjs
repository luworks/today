import * as agentV1 from './agent-v1.mjs';
const encoder = new TextEncoder();
const MAX_BODY = 24000;
// Agent mode (tools_version present): bounded replayed history, server-owned prompt and tools.
const AGENT = {v1: agentV1};
const MAX_AGENT_BODY = 262144, MAX_AGENT_UPSTREAM = 4194304, MAX_ITEMS = 256;
const MAX_STEPS = 6, DAILY_RUNS = 40, AGENT_MINUTE = 20, RESERVE = 10000;
const OUTPUT = 4096;
const headers = {"content-type":"application/json", "cache-control":"no-store", "x-content-type-options":"nosniff"};
const json = (body, status=200) => new Response(JSON.stringify(body), {status, headers});
const fail = (code, status=400) => { throw Object.assign(new Error(code), {status}); };
const bytes = text => encoder.encode(text);
const hex = data => Array.from(new Uint8Array(data), b=>b.toString(16).padStart(2,"0")).join("");
const random = () => hex(crypto.getRandomValues(new Uint8Array(32)));
const hash = async text => hex(await crypto.subtle.digest("SHA-256", bytes(text)));
async function passwordHash(password, salt) {
 const key=await crypto.subtle.importKey("raw",bytes(password),"PBKDF2",false,["deriveBits"]);
 return hex(await crypto.subtle.deriveBits({name:"PBKDF2",salt:bytes(salt),iterations:100000,hash:"SHA-256"},key,256));
}
function equal(a,b) { let d=a.length^b.length; for(let i=0;i<Math.max(a.length,b.length);i++)d|=(a.charCodeAt(i)||0)^(b.charCodeAt(i)||0);return d===0; }
async function boundedText(source,max) {
 const reader=source.body?.getReader(); if(!reader)fail("missing_body");
 let length=0;const chunks=[];
 while(true){const {value,done}=await reader.read();if(done)break;length+=value.length;if(length>max){await reader.cancel();fail("request_too_large",413);}chunks.push(value);}
 const all=new Uint8Array(length);let offset=0;for(const c of chunks){all.set(c,offset);offset+=c.length;}
 return {text:new TextDecoder().decode(all),length};
}
const parse = text => { try{return JSON.parse(text);}catch{fail("invalid_json");} };
const boundedJSON = async (source,max=MAX_BODY) => parse((await boundedText(source,max)).text);
async function bucket(db,key,limit) {
 const r=await db.prepare("INSERT INTO buckets VALUES (?,1) ON CONFLICT(key) DO UPDATE SET count=count+1 WHERE count<? RETURNING count").bind(key,limit).first();
 if(!r)fail("rate_limit",429);
}
async function identity(request,db,now) {
 const bearer=request.headers.get("authorization")||"";if(!/^Bearer [a-f0-9]{64}$/.test(bearer))fail("sign_in_required",401);
 const tokenHash=await hash(bearer.slice(7));
 const user=await db.prepare("SELECT users.id,users.username FROM sessions JOIN users ON users.id=sessions.user_id WHERE token_hash=? AND expires>?").bind(tokenHash,now).first();
 if(!user)fail("session_expired",401);return {...user,tokenHash};
}
async function session(db,user,now) {
 const token=random();const expires=now+30*86400;
 await db.prepare("INSERT INTO sessions VALUES (?,?,?)").bind(await hash(token),user.id,expires).run();
 return json({token,expires,username:user.username,model:"gpt-6-luna",effort:"medium"});
}
const only = (value, keys) => value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).every(k => keys.includes(k));
const nonempty = value => typeof value === 'string' && value.trim().length > 0;
export function prepareDecision(body) {
 if(!only(body,['model','input','questions'])||body.model!=='gpt-6-luna')fail('invalid_request');
 const input=body.input;
 if(!(nonempty(input)||(Array.isArray(input)&&input.length>0&&input.length<=32&&input.every(m=>only(m,['role','content'])&&['user','assistant'].includes(m.role)&&nonempty(m.content)))))fail('invalid_request');
 if(bytes(JSON.stringify(input)).length>12000)fail('context_too_large',413);
 if(!Array.isArray(body.questions)||body.questions.length<1||body.questions.length>8)fail('invalid_request');
 const names=new Set();
 for(const q of body.questions){
  if(!only(q,['type','name','instructions',...(q?.type==='choice'?['choices']:q?.type==='score'?['levels']:[])])||!['predicate','choice','score'].includes(q.type)||!nonempty(q.name)||!/^[a-zA-Z0-9_-]{1,64}$/.test(q.name)||names.has(q.name)||!nonempty(q.instructions))fail('invalid_request');
  names.add(q.name);
  if(q.type!=='predicate'){
   const key=q.type==='choice'?'choices':'levels', field=q.type==='choice'?'value':'label', options=q[key];
   if(!Array.isArray(options)||options.length<2||options.length>(q.type==='score'?10:255))fail('invalid_request');
   const seen=new Set();
   for(const option of options){
    if(!only(option,[field,'description'])||!(nonempty(option[field])||(field==='value'&&typeof option[field]==='boolean'))||(option.description!==undefined&&typeof option.description!=='string')||seen.has(JSON.stringify(option[field])))fail('invalid_request');
    seen.add(JSON.stringify(option[field]));
   }
  }
 }
 return {model:'gpt-6-luna',input,questions:body.questions};
}
const ROLES = new Set(['user','assistant']), PARTS = new Set(['input_text','output_text','refusal']);
function checkItem(item,version) {
 if(!item||typeof item!=='object'||Array.isArray(item))fail('invalid_item');
 if('role' in item&&!ROLES.has(item.role))fail('role_not_allowed');
 const type=item.type??('role' in item?'message':undefined);
 if(type==='message'){
  const c=item.content;
  if(!ROLES.has(item.role)||!(nonempty(c)||(Array.isArray(c)&&c.length>0&&c.length<=64&&c.every(p=>p&&PARTS.has(p.type)&&typeof (p.text??p.refusal)==='string'))))fail('invalid_item');
 } else if(type==='function_call'){
  if(!version.toolNames.has(item.name)||!nonempty(item.call_id)||typeof item.arguments!=='string')fail('invalid_item');
 } else if(type==='function_call_output'){
  if(!nonempty(item.call_id)||typeof item.output!=='string')fail('invalid_item');
 } else if(type!=='reasoning')fail('invalid_item');
}
// Agent mode: the client sends only replayed items; prompt, tools, model and limits are fixed here.
export function prepareAgent(body) {
 if(!body||typeof body!=='object'||Array.isArray(body))fail('invalid_request');
 if('tools' in body||'tool_choice' in body)fail('client_tools_not_allowed');
 if('instructions' in body)fail('role_not_allowed');
 if(!only(body,['input','tools_version','run_id','stream']))fail('invalid_request');
 if(!Object.hasOwn(AGENT,body.tools_version))fail('unsupported_tools_version');
 if(typeof body.run_id!=='string'||!/^[A-Za-z0-9_-]{8,64}$/.test(body.run_id))fail('invalid_run_id');
 if(body.stream!==undefined&&typeof body.stream!=='boolean')fail('invalid_request');
 const version=AGENT[body.tools_version], input=body.input;
 if(!Array.isArray(input)||!input.length||input.length>MAX_ITEMS)fail('invalid_request');
 for(const item of input)checkItem(item,version);
 return {model:'gpt-6-luna',instructions:version.instructions,input,tools:version.tools,tool_choice:'auto',parallel_tool_calls:true,
  reasoning:{effort:'low'},store:false,include:['reasoning.encrypted_content'],max_output_tokens:OUTPUT,stream:body.stream===true};
}
// One run = one user message; the server counts its steps so a client cannot loop forever.
async function runStep(db,user,runId,now) {
 const next=()=>db.prepare("UPDATE runs SET steps=steps+1 WHERE run_id=? AND user_id=? AND steps<? RETURNING steps").bind(runId,user.id,MAX_STEPS).first();
 let r=await next();if(r)return r.steps;
 r=await db.prepare("INSERT INTO runs SELECT ?,?,1,? WHERE (SELECT COUNT(*) FROM runs WHERE user_id=? AND started>=?)<? ON CONFLICT(run_id) DO NOTHING RETURNING steps")
  .bind(runId,user.id,now,user.id,Math.floor(now/86400)*86400,DAILY_RUNS).first();
 if(r)return r.steps;
 const existing=await db.prepare("SELECT user_id FROM runs WHERE run_id=?").bind(runId).first();
 if(!existing)fail('run_quota',429);
 if(existing.user_id!==user.id)fail('invalid_run_id',409);
 r=await next();if(r)return r.steps; // a concurrent first step created the run
 fail('run_step_limit',429);
}
const safe = n => Number.isSafeInteger(n)&&n>=0;
// Micro-dollars: uncached input $0.10/M, cached input $0.01/M, output (incl. reasoning) $0.50/M.
export function cost(u) {
 if(!safe(u?.input_tokens)||!safe(u?.output_tokens))return null;
 const cached=Math.min(safe(u.input_tokens_details?.cached_tokens)?u.input_tokens_details.cached_tokens:0,u.input_tokens);
 return Math.ceil(((u.input_tokens-cached)*10+cached+u.output_tokens*50)/100);
}
async function settle(db,id,usage,status) {
 const charged=cost(usage);
 if(charged===null){await db.prepare("UPDATE calls SET status='unknown' WHERE id=?").bind(id).run();return;}
 await db.batch([db.prepare("UPDATE calls SET charged=?,status=? WHERE id=?").bind(charged,typeof status==='string'?status:'unknown',id),db.prepare("UPDATE budget SET used=used-?+? WHERE id=1").bind(RESERVE,charged)]);
}
const TERMINAL = new Set(['response.completed','response.incomplete','response.failed']);
// Reads the whole upstream SSE stream even after the client leaves, then settles the ledger.
// Client writes are not awaited, so a stalled client cannot hold the reservation open.
async function pump(body,writer,db,id) {
 const reader=body.getReader(), decoder=new TextDecoder();
 let buffer='', final=null, gone=false, size=0;
 writer.closed.catch(()=>{gone=true;});
 try {
  while(true){
   const {value,done}=await reader.read();if(done)break;
   size+=value.length;if(size>MAX_AGENT_UPSTREAM)throw new Error('upstream_too_large');
   if(!gone)writer.write(value).catch(()=>{gone=true;});
   buffer+=decoder.decode(value,{stream:true}).replace(/\r/g,'');
   let i;
   while((i=buffer.indexOf('\n\n'))>=0){
    const data=buffer.slice(0,i).split('\n').filter(l=>l.startsWith('data:')).map(l=>l.slice(5).trimStart()).join('\n');buffer=buffer.slice(i+2);
    if(!data||data==='[DONE]')continue;
    try{const event=JSON.parse(data);if(TERMINAL.has(event.type))final=event.response;}catch{}
   }
  }
  if(!gone)writer.close().catch(()=>{});
 } catch(error) {
  reader.cancel().catch(()=>{});writer.abort(error).catch(()=>{});
 }
 await settle(db,id,final?.usage,final?.status);
}
const sse = {"content-type":"text/event-stream","cache-control":"no-store","x-content-type-options":"nosniff"};
export default {async fetch(request,env,ctx) {
 const now=Math.floor(Date.now()/1000), path=new URL(request.url).pathname,db=env.DB;
 try {
  if(path==="/health"&&request.method==="GET")return json({ok:true,model:"gpt-6-luna",effort:"medium",agent:{tools_versions:Object.keys(AGENT),effort:"low",max_steps:MAX_STEPS,daily_runs:DAILY_RUNS}});
  if(!db)fail("service_unavailable",503);
  const ip=await hash((request.headers.get("CF-Connecting-IP")||"unknown")+":"+Math.floor(now/86400));
  if(["/auth/register","/auth/login"].includes(path)&&request.method==="POST") {
   await bucket(db,"login:"+ip+":"+Math.floor(now/60),10);
   const body=await boundedJSON(request);const username=typeof body.username==="string"?body.username.toLowerCase().trim():"", password=body.password;
   if(!/^[a-z0-9_.-]{3,48}$/.test(username)||typeof password!=="string"||password.length<12||password.length>128)fail("invalid_credentials");
   let user=await db.prepare("SELECT * FROM users WHERE username=?").bind(username).first();
   if(path==="/auth/register") {
    await bucket(db,"signup:"+ip,3);
    const count=await db.prepare("SELECT COUNT(*) AS n FROM users").first();if(count.n>=100)fail("registration_closed",429);
    if(user)fail("username_unavailable",409);
    user={id:crypto.randomUUID(),username,salt:random()};const digest=await passwordHash(password,user.salt);
    // The conditional INSERT enforces the account cap under concurrent registration.
    const r=await db.prepare("INSERT INTO users SELECT ?,?,?,?,? WHERE (SELECT COUNT(*) FROM users)<100 RETURNING id").bind(user.id,username,user.salt,digest,now).first();
    if(!r)fail("registration_closed",429);
   } else {
    await bucket(db,"account-login:"+await hash(username)+":"+Math.floor(now/60),5);
    const digest=await passwordHash(password,user?.salt||"unregistered-user-salt");
    if(!user||!equal(digest,user.password_hash))fail("invalid_credentials",401);
   }
   return await session(db,user,now);
  }
  const user=await identity(request,db,now);
  if(path==="/auth/session"&&request.method==="GET") {
   const usage=await db.prepare("SELECT count FROM buckets WHERE key=?").bind("daily:"+user.id+":"+Math.floor(now/86400)).first();
   const runs=await db.prepare("SELECT COUNT(*) AS n FROM runs WHERE user_id=? AND started>=?").bind(user.id,Math.floor(now/86400)*86400).first();
   return json({username:user.username,model:"gpt-6-luna",effort:"medium",dailyLimit:40,used:usage?.count||0,dailyRunLimit:DAILY_RUNS,runsUsed:runs?.n||0});
  }
  if(path==="/auth/logout"&&request.method==="POST") {await db.prepare("DELETE FROM sessions WHERE token_hash=?").bind(user.tokenHash).run();return json({ok:true});}
  if(path==="/auth/account"&&request.method==="DELETE") {await db.batch([db.prepare("DELETE FROM sessions WHERE user_id=?").bind(user.id),db.prepare("DELETE FROM calls WHERE user_id=?").bind(user.id),db.prepare("DELETE FROM runs WHERE user_id=?").bind(user.id),db.prepare("DELETE FROM users WHERE id=?").bind(user.id)]);return json({ok:true});}
  if(!["/v1/responses","/v1/decisions"].includes(path)||request.method!=="POST")fail("not_found",404);
  if(!env.OPENAI_API_KEY)fail("service_unavailable",503);
  const decision=path==='/v1/decisions';
  let body, agent=false, runId;
  if(decision)body=prepareDecision(await boundedJSON(request));
  else {
   // Agent mode only: the app's strict-JSON mode was removed with the old pipeline (P4).
   const raw=await boundedText(request,MAX_AGENT_BODY), parsed=parse(raw.text);
   if(!parsed||typeof parsed!=='object'||!('tools_version' in parsed))fail('tools_version_required');
   agent=true;
   body=prepareAgent(parsed);
   runId=parsed.run_id;
  }
  const payload=JSON.stringify(body);
  // Each counter is atomic; denied attempts may consume quota, never call OpenAI.
  // A decision consumes one unit of the existing per-user minute and daily quotas.
  // An agent step consumes one step of its run (6 max); new runs count against 40 runs/day.
  if(agent){
   await bucket(db,"agent-minute:"+user.id+":"+Math.floor(now/60),AGENT_MINUTE);
   await runStep(db,user,runId,now);
  } else {
   await bucket(db,"minute:"+user.id+":"+Math.floor(now/60),6);
   await bucket(db,"daily:"+user.id+":"+Math.floor(now/86400),40);
  }
  const id=crypto.randomUUID();
  const allowance=await db.prepare("UPDATE budget SET used=used+? WHERE id=1 AND used+?<=ceiling RETURNING used").bind(RESERVE,RESERVE).first();
  if(!allowance)fail("service_budget_exhausted",429);
  await db.prepare("INSERT INTO calls VALUES (?,?,?,?,NULL,'pending')").bind(id,user.id,now,RESERVE).run();
  let upstream;
  try {
   upstream=await fetch("https://api.openai.com"+path,{method:"POST",headers:{"authorization":"Bearer "+env.OPENAI_API_KEY,"content-type":"application/json"},body:payload,redirect:"manual",signal:AbortSignal.timeout(agent?30000:20000)});
   if(!upstream.ok){
    if(decision&&[403,404].includes(upstream.status)){
     await db.prepare("UPDATE calls SET status='unknown' WHERE id=?").bind(id).run();
     return json({error:'upstream_unavailable',upstream_status:upstream.status,request_id:id},upstream.status);
    }
    if(agent&&upstream.status===400){
     // OpenAI rejects invalid requests (e.g. a bad replayed item) before generating; nothing is billed.
     const detail=await boundedJSON(upstream,65536).catch(()=>({}));
     await db.batch([db.prepare("UPDATE calls SET charged=0,status='rejected' WHERE id=?").bind(id),db.prepare("UPDATE budget SET used=used-? WHERE id=1").bind(RESERVE)]);
     const e=detail?.error||{};
     return json({error:'upstream_rejected',upstream_status:400,code:typeof e.code==='string'?e.code:null,param:typeof e.param==='string'?e.param:null,message:typeof e.message==='string'?e.message.slice(0,500):null,request_id:id},400);
    }
    throw new Error("upstream");
   }
   if(body.stream){
    const {readable,writable}=new TransformStream();
    ctx.waitUntil(pump(upstream.body,writable.getWriter(),db,id));
    return new Response(readable,{headers:{...sse,"x-request-id":id}});
   }
   const result=await boundedJSON(upstream,agent?MAX_AGENT_UPSTREAM:MAX_BODY);
   await settle(db,id,result.usage,result.status);
   return json(result);
  } catch {
   await db.prepare("UPDATE calls SET status='unknown' WHERE id=?").bind(id).run();
   return json({error:"upstream_unavailable",request_id:id},502);
  }
 } catch(error) {return json({error:error.status?error.message:"service_unavailable"},error.status||503);}
}};
