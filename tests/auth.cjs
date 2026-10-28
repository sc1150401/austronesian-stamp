const fs=require('fs'),assert=require('assert');
const src=fs.readFileSync('supabase/functions/stamp-admin/index.js','utf8');
let handler,calls=[],role='admin';
const Deno={serve:fn=>handler=fn,env:{get:k=>({SUPABASE_URL:'https://db.test',SUPABASE_SERVICE_ROLE_KEY:'server-secret',SUPABASE_ANON_KEY:'public-key'})[k]}};
const fetch=async(url,options)=>{calls.push({url,options});if(url.endsWith('/auth/v1/user'))return role==='invalid'?Response.json({}, {status:401}):Response.json({id:'verified-user'});if(url.includes('/token?'))return Response.json({user:{id:'verified-user'},access_token:'session-token',expires_in:3600,refresh_token:'never-return'});if(url.includes('/rpc/')){const b=JSON.parse(options.body);assert.equal(b.p_actor,'verified-user');return role==='denied'?Response.json({message:'ADMIN_REQUIRED'},{status:400}):Response.json({total:7});}throw Error('Unexpected URL');};
new Function('Deno','fetch',src)(Deno,fetch);
const request=(body,token)=>handler(new Request('https://edge.test',{method:'POST',headers:{origin:'https://sc1150401.github.io',...(token?{Authorization:'Bearer '+token}:{})},body:JSON.stringify(body)}));
(async()=>{
assert.equal((await request({action:'overview'})).status,401);assert.equal(calls.length,0);
role='invalid';assert.equal((await request({action:'reset',payload:{p_actor:'forged'}},'bad')).status,401);assert(!calls.some(c=>c.url.includes('/rpc/')));
role='denied';assert.equal((await request({action:'overview'},'valid')).status,403);
role='admin';assert.equal((await request({action:'reset',payload:{p_actor:'forged',number:'1'}},'valid')).status,200);
const login=await (await request({action:'login',email:'admin@example.com',password:'test'})).json();assert.equal(login.access_token,'session-token');assert(!('refresh_token' in login));assert(!JSON.stringify(login).includes('server-secret'));
console.log('PASS: missing/invalid tokens blocked, nonadmins denied, verified actor overrides forged actor, login excludes secrets/refresh token');
})();
