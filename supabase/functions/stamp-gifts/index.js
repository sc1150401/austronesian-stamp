// Deploy as stamp-gifts with legacy JWT verification OFF.
// LINE ID tokens are verified before all database access.
// Each confirmation has its own retry-safe request ID.
const CHANNEL = "2012241831";
const headers = {
  "Access-Control-Allow-Origin": "https://sc1150401.github.io",
  "Access-Control-Allow-Headers": "content-type, authorization, apikey, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
  "Vary": "Origin"
};
const reply = (body, status = 200) =>
  new Response(JSON.stringify(body), {status, headers});
Deno.serve(async req => {
  if (req.method === "OPTIONS") return new Response(null, {status:204, headers});
  if (req.method !== "POST") return reply({error:"METHOD_NOT_ALLOWED"},405);
  try {
    const raw = await req.text();
    if (raw.length > 16000) return reply({error:"BODY_TOO_LARGE"},413);
    let body;
    try { body = JSON.parse(raw); }
    catch { return reply({error:"INVALID_REQUEST"},400); }
    if (!body || !["status","redeem"].includes(body.action))
      return reply({error:"INVALID_ACTION"},400);
    if (body.action === "redeem" &&
        (!Number.isInteger(body.gift_id) || body.gift_id < 1 || body.gift_id > 4))
      return reply({error:"INVALID_REDEMPTION"},400);
    if (typeof body.id_token !== "string" || !body.id_token)
      return reply({error:"LOGIN_REQUIRED"},401);
    const verify = await fetch("https://api.line.me/oauth2/v2.1/verify", {
      method:"POST",
      headers:{"Content-Type":"application/x-www-form-urlencoded"},
      body:new URLSearchParams({id_token:body.id_token,client_id:CHANNEL}),
      signal:AbortSignal.timeout(10000)
    });
    if (!verify.ok) return reply({error:"LOGIN_REQUIRED"},401);
    const identity = await verify.json();
    if (identity.aud !== CHANNEL || identity.iss !== "https://access.line.me" ||
        typeof identity.sub !== "string" || !identity.sub ||
        !(identity.exp > Date.now()/1000))
      return reply({error:"LOGIN_REQUIRED"},401);
    if(body.action==="redeem" && body.rules_version!=="gifts-v2")
      return reply({error:"REFRESH_REQUIRED"},409);
    if(body.action==="redeem" && (!/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(body.request_id) || !Number.isInteger(body.expected_spent)))
      return reply({error:"INVALID_REQUEST"},400);
    const url = Deno.env.get("SUPABASE_URL");
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !key) return reply({error:"SERVER_NOT_READY"},503);
    async function db(path, options = {}) {
      const res = await fetch(url + "/rest/v1/" + path, {
        ...options,
        headers:{apikey:key,Authorization:"Bearer "+key,"Content-Type":"application/json"},
        signal:AbortSignal.timeout(10000)
      });
      if (!res.ok) {
        // Return only known business-rule errors, never raw database details.
        let error;
        try { error = await res.json(); } catch {}
        const allowed = ['找不到參加者','贈品不存在','這項贈品尚未開放兌換','剩餘可用章數不足','兌換紀錄已更新，請重新載入集章卡。'];
        if (allowed.includes(error?.message))
          throw new Error(error.message);
        throw new Error("DATABASE_ERROR");
      }
      return await res.json();
    }
    const users = await db("stamp_participants?select=id,participant_no&line_user_id=eq."+
      encodeURIComponent(identity.sub));
    if (!users[0]) return reply({error:"PARTICIPANT_NOT_FOUND"},409);
    const participant = users[0].id;
    let redeemedId = null;
    if (body.action === "redeem") {
      redeemedId = await db("rpc/redeem_stamp_gift_v2", {
        method:"POST",
        body:JSON.stringify({
          p_participant_id:participant,
          p_gift_id:body.gift_id,
          p_request_id:body.request_id,p_expected_spent:body.expected_spent,
          p_redeemed_by:"self:"+identity.sub
        })
      });
    }
    const [stamps, redemptions, gifts, stations] = await Promise.all([
      db("stamp_records?select=station_id&participant_id=eq."+participant+"&order=collected_at.asc,station_id.asc"),
      db("stamp_gift_redemptions?select=id,gift_id,stamp_cost,redemption_no,redeemed_at&participant_id=eq."+
        participant+"&order=redemption_no"),
      db("stamp_gifts?select=id,name,stamp_cost,active&order=id"),
      db("stamp_stations?select=id,name&order=id")
    ]);
    return reply({
      ok:true,rules_version:"gifts-v2",gift_ready:true,stamps,redemptions,gifts,stations,
      participant_number:String(users[0].participant_no),redeemed_id:redeemedId,
      available_stamps:Math.max(0,stamps.length-redemptions.reduce((sum,r)=>sum+r.stamp_cost,0))
    });
  } catch (error) {
    const message = error?.message;
    if (message && /^(找不到參加者|贈品不存在|這項贈品|剩餘可用章數|兌換紀錄已更新)/.test(message))
      return reply({error:"REDEMPTION_REJECTED",message},409);
    return reply({error:"TEMPORARY_FAILURE"},500);
  }
});


