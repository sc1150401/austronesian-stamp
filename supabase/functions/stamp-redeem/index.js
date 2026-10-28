// Deploy as stamp-redeem with legacy JWT verification OFF.
// LINE ID tokens are verified before all database access.
// redemption_no must remain unchanged when retrying a confirmation.
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
        (!Number.isInteger(body.vendor_id) || body.vendor_id < 1 || body.vendor_id > 6 ||
         ![1,2].includes(body.redemption_no)))
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
        const allowed = [
          "兌換份數只能是第 1 份或第 2 份","找不到參加者",
          "這一份試吃已兌換，不能更換商家","這家商家尚未開放兌換",
          "印記不足：第一份需 3 章，第二份需 6 章","請先核銷第一份試吃"
        ];
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
      redeemedId = await db("rpc/redeem_stamp_reward", {
        method:"POST",
        body:JSON.stringify({
          p_participant_id:participant,
          p_vendor_id:body.vendor_id,
          p_redemption_no:body.redemption_no,
          p_redeemed_by:"self:"+identity.sub
        })
      });
    }
    const [stamps, redemptions, vendors, stations] = await Promise.all([
      db("stamp_records?select=station_id&participant_id=eq."+participant),
      db("stamp_redemptions?select=id,vendor_id,redemption_no,redeemed_at&participant_id=eq."+
        participant+"&order=redemption_no"),
      db("stamp_vendors?select=id,name,active&order=id"),
      db("stamp_stations?select=id,name&order=id")
    ]);
    return reply({
      ok:true,stamps,redemptions,vendors,stations,
      participant_number:String(users[0].participant_no),redeemed_id:redeemedId,
      available:Math.max(0,Math.min(2,Math.floor(stamps.length/3))-redemptions.length)
    });
  } catch (error) {
    const message = error?.message;
    if (message && /^(兌換份數|找不到參加者|這一份試吃|這家商家|印記不足|請先核銷)/.test(message))
      return reply({error:"REDEMPTION_REJECTED",message},409);
    return reply({error:"TEMPORARY_FAILURE"},500);
  }
});

