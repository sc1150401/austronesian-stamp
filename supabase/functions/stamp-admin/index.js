// Deploy as stamp-admin. Disable legacy JWT verification; Supabase Auth verifies users here.
// No service key, password, token, or LINE identifier is returned in admin data.
const ORIGIN = 'https://sc1150401.github.io';
const headers = {'Access-Control-Allow-Origin':ORIGIN,
  'Access-Control-Allow-Headers':'content-type, authorization, apikey, x-client-info',
  'Access-Control-Allow-Methods':'POST, OPTIONS','Content-Type':'application/json',
  'Cache-Control':'no-store','Vary':'Origin'};
const reply=(data,status=200)=>new Response(JSON.stringify(data),{status,headers});
Deno.serve(async req=>{
  if(req.method==='OPTIONS') return new Response(null,{status:204,headers});
  if(req.method!=='POST') return reply({error:'METHOD_NOT_ALLOWED'},405);
  const origin=req.headers.get('origin');
  if(origin && origin!==ORIGIN) return reply({error:'ORIGIN_DENIED'},403);
  try {
    const raw=await req.text();
    if(raw.length>16000) return reply({error:'BODY_TOO_LARGE'},413);
    let body; try{body=JSON.parse(raw);}catch{return reply({error:'INVALID_REQUEST'},400);}
    const action=body?.action;
    if(!['login','logout','session','overview','participant','participants','reset','catalog','audit'].includes(action))
      return reply({error:'INVALID_ACTION'},400);
    const base=Deno.env.get('SUPABASE_URL');
    const key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const anon=Deno.env.get('SUPABASE_ANON_KEY');
    if(!base||!key||!anon) return reply({error:'SERVER_NOT_READY'},503);
    async function rpc(actor,action,payload={}) {
      const r=await fetch(base+'/rest/v1/rpc/stamp_admin_api',{
        method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},
        body:JSON.stringify({p_actor:actor,p_action:action,p_payload:payload}),
        signal:AbortSignal.timeout(20000)
      });
      const data=await r.json();
      if(!r.ok) {
        const allowed=['ADMIN_REQUIRED','NOT_FOUND','RECORD_CHANGED','REQUEST_CONFLICT','REASON_REQUIRED','INVALID_MODE','INVALID_NAME','INVALID_KIND','INVALID_ACTIVE','REQUEST_ID_REQUIRED'];
        throw new Error(allowed.includes(data.message)?data.message:'DATABASE_ERROR');
      }
      return data;
    }
    if(action==='login') {
      if(typeof body.email!=='string'||body.email.length>254||typeof body.password!=='string'||body.password.length>1024)
        return reply({error:'LOGIN_FAILED'},401);
      const r=await fetch(base+'/auth/v1/token?grant_type=password',{
        method:'POST',headers:{apikey:anon,'Content-Type':'application/json'},
        body:JSON.stringify({email:body.email.trim(),password:body.password}),signal:AbortSignal.timeout(15000)
      });
      const auth=await r.json();
      if(!r.ok||!auth.user?.id||!auth.access_token) return reply({error:'LOGIN_FAILED'},401);
      await rpc(auth.user.id,'session');
      // Browser keeps only this short-lived token in memory. Refreshing requires login again.
      return reply({ok:true,access_token:auth.access_token,expires_in:auth.expires_in});
    }
    const bearer=req.headers.get('authorization')||'';
    if(!/^Bearer \S+$/.test(bearer)) return reply({error:'LOGIN_REQUIRED'},401);
    const authResponse=await fetch(base+'/auth/v1/user',{
      headers:{apikey:anon,Authorization:bearer},signal:AbortSignal.timeout(10000)
    });
    if(!authResponse.ok) return reply({error:'LOGIN_REQUIRED'},401);
    const user=await authResponse.json();
    if(!user.id) return reply({error:'LOGIN_REQUIRED'},401);
    if(action==='logout') {
      await fetch(base+'/auth/v1/logout?scope=local',{method:'POST',headers:{apikey:anon,Authorization:bearer},signal:AbortSignal.timeout(10000)});
      return reply({ok:true});
    }
    // p_actor always comes from verified Supabase Auth, never from the browser body.
    const data=await rpc(user.id,action,body.payload || {});
    return reply({ok:true,data});
  } catch(error) {
    const name=error?.message;
    if(name==='ADMIN_REQUIRED') return reply({error:name},403);
    const expected=['NOT_FOUND','RECORD_CHANGED','REQUEST_CONFLICT','REASON_REQUIRED','INVALID_MODE','INVALID_NAME','INVALID_KIND','INVALID_ACTIVE','REQUEST_ID_REQUIRED'];
    if(expected.includes(name)) return reply({error:name},409);
    return reply({error:'TEMPORARY_FAILURE'},500);
  }
});
