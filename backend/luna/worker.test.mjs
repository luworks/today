import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { Miniflare, Response } from 'miniflare';
import { prepare } from './worker.mjs';
const payload={instructions:'Extract title',input:'[QA] buy milk',text:{format:{type:'json_schema',name:'title',strict:true,schema:{type:'object',properties:{title:{type:'string'}},required:['title'],additionalProperties:false}}}};

test('fixed model, reasoning, storage and tools cannot be overridden',()=>{
 const body=prepare({...payload,model:'other',reasoning:{effort:'max'},store:true,tools:[{type:'web_search'}]});
 assert.equal(body.model,'gpt-6-luna');assert.equal(body.reasoning.effort,'medium');assert.equal(body.store,false);assert.equal(body.max_output_tokens,4096);assert.equal(body.tools,undefined);
 assert.throws(()=>prepare({...payload,input:'x'.repeat(12001)}));
});

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
  assert.equal((await req('/v1/responses',payload)).status,401);
  const reg=await req('/auth/register',{username:'testuser',password:'synthetic-password-123'});assert.equal(reg.status,200);const account=await reg.json();assert.match(account.token,/^[a-f0-9]{64}$/);
  const stored=await db.prepare('SELECT password_hash FROM users').first();assert.notEqual(stored.password_hash,'synthetic-password-123');
  assert.equal((await req('/auth/login',{username:'testuser',password:'incorrect-password'})).status,401);
  assert.equal((await req('/v1/responses',payload,account.token)).status,200);assert.equal(calls,1);assert.equal(lastBody.model,'gpt-6-luna');
  const charged=await db.prepare('SELECT used FROM budget').first();assert.equal(charged.used,24011);
  failure=true;assert.equal((await req('/v1/responses',payload,account.token)).status,502);
  assert.equal((await db.prepare('SELECT used FROM budget').first()).used,34011);
  // Global exhaustion is atomic: no paid request escapes when several clients race.
  failure=false;await db.prepare('UPDATE budget SET ceiling=used+10000').run();
  const race=await Promise.all(Array.from({length:4},()=>req('/v1/responses',payload,account.token)));assert.equal(race.filter(r=>r.status===200).length,1);assert.equal(calls,3);
  // A second user's allowance is independent, while a saturated daily bucket blocks payment.
  const secondAccount=await (await req('/auth/register',{username:'seconduser',password:'synthetic-password-456'})).json();
  const secondUsage=await (await req('/auth/session',null,secondAccount.token,'GET')).json();assert.equal(secondUsage.used,0);
  await db.prepare("DELETE FROM buckets WHERE key LIKE 'minute:%'").run();
  await db.prepare("UPDATE buckets SET count=40 WHERE key LIKE 'daily:'||(SELECT id FROM users WHERE username='testuser')||':%'").run();
  assert.equal((await req('/v1/responses',payload,account.token)).status,429);assert.equal(calls,3);
  assert.equal((await (await req('/auth/session',null,secondAccount.token,'GET')).json()).used,0);
  await req('/auth/logout',null,account.token);assert.equal((await req('/auth/session',null,account.token,'GET')).status,401);
  const login=await (await req('/auth/login',{username:'testuser',password:'synthetic-password-123'})).json();
  assert.equal((await req('/auth/account',null,login.token,'DELETE')).status,200);assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM users').first()).n,1);
  await req('/auth/account',null,secondAccount.token,'DELETE');
  assert.equal((await db.prepare('SELECT COUNT(*) AS n FROM users').first()).n,0);
 }finally{await mf.dispose();}
});
