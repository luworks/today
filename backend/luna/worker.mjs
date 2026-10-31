const encoder = new TextEncoder();
const MAX_BODY = 24000;
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
async function boundedJSON(request) {
 const reader=request.body?.getReader(); if(!reader)fail("missing_body");
 let length=0;const chunks=[];
 while(true){const {value,done}=await reader.read();if(done)break;length+=value.length;if(length>MAX_BODY){await reader.cancel();fail("request_too_large",413);}chunks.push(value);}
 const all=new Uint8Array(length);let offset=0;for(const c of chunks){all.set(c,offset);offset+=c.length;}
 try{return JSON.parse(new TextDecoder().decode(all));}catch{fail("invalid_json");}
}
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
export function prepare(body) {
 if(typeof body.instructions!=="string"||typeof body.input!=="string"||!body.input.trim())fail("invalid_request");
 if(bytes(body.instructions).length>8000||bytes(body.input).length>12000)fail("context_too_large",413);
 const format=body.text?.format;
 if(format?.type!=="json_schema"||format.strict!==true||!format.schema||typeof format.schema!=="object"||!/^[a-zA-Z0-9_-]{1,64}$/.test(format.name))fail("strict_schema_required");
 return {model:"gpt-6-luna",reasoning:{effort:"medium"},store:false,max_output_tokens:OUTPUT,instructions:body.instructions,input:body.input,text:{format}};
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
export default {async fetch(request,env) {
 const now=Math.floor(Date.now()/1000), path=new URL(request.url).pathname,db=env.DB;
 try {
  if(path==="/health"&&request.method==="GET")return json({ok:true,model:"gpt-6-luna",effort:"medium"});
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
   return json({username:user.username,model:"gpt-6-luna",effort:"medium",dailyLimit:40,used:usage?.count||0});
  }
  if(path==="/auth/logout"&&request.method==="POST") {await db.prepare("DELETE FROM sessions WHERE token_hash=?").bind(user.tokenHash).run();return json({ok:true});}
  if(path==="/auth/account"&&request.method==="DELETE") {await db.batch([db.prepare("DELETE FROM sessions WHERE user_id=?").bind(user.id),db.prepare("DELETE FROM calls WHERE user_id=?").bind(user.id),db.prepare("DELETE FROM users WHERE id=?").bind(user.id)]);return json({ok:true});}
  if(!["/v1/responses","/v1/decisions"].includes(path)||request.method!=="POST")fail("not_found",404);
  if(!env.OPENAI_API_KEY)fail("service_unavailable",503);
  const decision=path==='/v1/decisions';
  const payload=JSON.stringify((decision?prepareDecision:prepare)(await boundedJSON(request)));
  // Each counter is atomic; denied attempts may consume quota, never call OpenAI.
  // A decision consumes one unit of the existing per-user minute and daily quotas.
  await bucket(db,"minute:"+user.id+":"+Math.floor(now/60),6);
  await bucket(db,"daily:"+user.id+":"+Math.floor(now/86400),40);
  const reserve=10000, id=crypto.randomUUID();
  const allowance=await db.prepare("UPDATE budget SET used=used+? WHERE id=1 AND used+?<=ceiling RETURNING used").bind(reserve,reserve).first();
  if(!allowance)fail("service_budget_exhausted",429);
  await db.prepare("INSERT INTO calls VALUES (?,?,?,?,NULL,'pending')").bind(id,user.id,now,reserve).run();
  let upstream;
  try {
   upstream=await fetch("https://api.openai.com"+path,{method:"POST",headers:{"authorization":"Bearer "+env.OPENAI_API_KEY,"content-type":"application/json"},body:payload,redirect:"manual",signal:AbortSignal.timeout(20000)});
   if(!upstream.ok){
    if(decision&&[403,404].includes(upstream.status)){
     await db.prepare("UPDATE calls SET status='unknown' WHERE id=?").bind(id).run();
     return json({error:'upstream_unavailable',upstream_status:upstream.status,request_id:id},upstream.status);
    }
    throw new Error("upstream");
   }
   const result=await boundedJSON(upstream);const u=result.usage;
   if(Number.isSafeInteger(u?.input_tokens)&&u.input_tokens>=0&&Number.isSafeInteger(u?.output_tokens)&&u.output_tokens>=0){
    // Conservatively retain the Responses rate for output and cache writes.
    const charged=Math.ceil(u.input_tokens*.1+u.output_tokens*.5);
    await db.batch([db.prepare("UPDATE calls SET charged=?,status=? WHERE id=?").bind(charged,result.status||"unknown",id),db.prepare("UPDATE budget SET used=used-?+? WHERE id=1").bind(reserve,charged)]);
   }
   return json(result);
  } catch {
   await db.prepare("UPDATE calls SET status='unknown' WHERE id=?").bind(id).run();
   return json({error:"upstream_unavailable",request_id:id},502);
  }
 } catch(error) {return json({error:error.status?error.message:"service_unavailable"},error.status||503);}
}};
