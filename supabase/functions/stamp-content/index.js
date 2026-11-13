// Deploy with legacy JWT verification off. Public reads and authenticated writes use the same URL.
const headers = {
  'Access-Control-Allow-Origin': 'https://sc1150401.github.io',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Content-Type': 'application/json',
  'Cache-Control': 'no-store'
};
const reply = (value,status=200) => new Response(JSON.stringify(value),{status,headers});
Deno.serve(async request => {
  if(request.method==='OPTIONS')return new Response(null,{status:204,headers});
  const base=Deno.env.get('SUPABASE_URL'), key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const dbHeaders={apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'};
  try {
    if(request.method==='GET'){
      const read=await fetch(base+'/rest/v1/stamp_site_copy?id=eq.1&select=version,texts',{headers:dbHeaders});
      if(!read.ok)return reply({error:'尚未完成文字資料庫設定。'},503);
      const [data]=await read.json();
      return data?reply(data):reply({error:'找不到文字設定。'},503);
    }
    if(request.method!=='POST')return reply({},405);
    const bearer=request.headers.get('authorization');
    if(!bearer?.startsWith('Bearer '))return reply({error:'請重新登入。'},401);
    const identity=await fetch(base+'/auth/v1/user',{headers:{apikey:Deno.env.get('SUPABASE_ANON_KEY'),Authorization:bearer}});
    if(!identity.ok)return reply({error:'請重新登入。'},401);
    const {id}=await identity.json();
    const {version,texts}=await request.json();
    const saved=await fetch(base+'/rest/v1/rpc/stamp_save_site_copy',{method:'POST',headers:dbHeaders,
      body:JSON.stringify({p_actor:id,p_version:version,p_texts:texts})});
    const data=await saved.json();
    if(saved.ok)return reply(data);
    if(data.message==='ADMIN_REQUIRED')return reply({error:'此帳號沒有管理權限。'},403);
    if(data.message==='RECORD_CHANGED')return reply({error:'文字已有更新，請先複製你的修改，再重新載入。'},409);
    return reply({error:'儲存失敗，請確認文字長度與動態欄位。'},400);
  } catch {return reply({error:'文字服務暫時無法連線。'},503);}
});
