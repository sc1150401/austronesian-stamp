// Deploy as stamp-claim; disable "Verify JWT with legacy secret".
// Tokens are verified with LINE before any database write.
const CHANNEL = "2012241831";
const headers = {
  "Access-Control-Allow-Origin": "https://sc1150401.github.io",
  "Access-Control-Allow-Headers": "content-type, authorization, apikey, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
  "Cache-Control": "no-store",
  "Vary": "Origin",
};
const reply = (data, status = 200) =>
  new Response(JSON.stringify(data), {status, headers});
Deno.serve(async req => {
  if (req.method === "OPTIONS") return new Response(null, {status:204, headers});
  if (req.method !== "POST") return reply({error:"METHOD_NOT_ALLOWED"},405);
  try {
    const raw = await req.text();
    if (raw.length > 16000) return reply({error:"BODY_TOO_LARGE"},413);
    let body;
    try { body = JSON.parse(raw); }
    catch { return reply({error:"INVALID_REQUEST"},400); }
    const station = body?.station_id;
    const token = body?.access_token;
    if (!Number.isInteger(station) || station < 1 || station > 6)
      return reply({error:"INVALID_STATION"},400);
    if (typeof token !== "string" || !token)
      return reply({error:"LOGIN_REQUIRED"},401);

    const verify = await fetch("https://api.line.me/oauth2/v2.1/verify?" +
      new URLSearchParams({access_token:token}), {signal:AbortSignal.timeout(10000)});
    if (!verify.ok) return reply({error:"LOGIN_REQUIRED"},401);
    const verified = await verify.json();
    if (verified.client_id !== CHANNEL || !(verified.expires_in > 0))
      return reply({error:"LOGIN_REQUIRED"},401);
    const lineHeaders = {Authorization:"Bearer " + token};
    const [profileResponse, friendResponse] = await Promise.all([
      fetch("https://api.line.me/v2/profile", {headers:lineHeaders,signal:AbortSignal.timeout(10000)}),
      fetch("https://api.line.me/friendship/v1/status", {headers:lineHeaders,signal:AbortSignal.timeout(10000)}),
    ]);
    if (!profileResponse.ok || !friendResponse.ok)
      return reply({error:"LINE_CHECK_FAILED"},502);
    const profile = await profileResponse.json();
    const friend = await friendResponse.json();
    if (friend.friendFlag !== true) return reply({error:"FRIEND_REQUIRED"},403);
    if (typeof profile.userId !== "string" || !profile.userId)
      return reply({error:"LOGIN_REQUIRED"},401);

    const url = Deno.env.get("SUPABASE_URL");
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !key) return reply({error:"SERVER_NOT_READY"},503);
    async function db(path, options = {}) {
      const res = await fetch(url + "/rest/v1/" + path, {
        ...options,
        headers: {apikey:key, Authorization:"Bearer " + key,
          "Content-Type":"application/json", ...options.headers},
        signal:AbortSignal.timeout(10000),
      });
      if (!res.ok) throw new Error("DATABASE_ERROR");
      const text = await res.text();
      return text ? JSON.parse(text) : null;
    }
    const stations = await db("stamp_stations?select=id&active=eq.true&id=eq." + station);
    if (!stations.length) return reply({error:"STATION_CLOSED"},409);
    await db("stamp_participants?on_conflict=line_user_id", {
      method:"POST", headers:{Prefer:"resolution=ignore-duplicates"},
      body:JSON.stringify({line_user_id:profile.userId}),
    });
    const users = await db("stamp_participants?select=id&line_user_id=eq." +
      encodeURIComponent(profile.userId));
    if (!users[0]) throw new Error("PARTICIPANT_NOT_FOUND");
    const inserted = await db("stamp_records?on_conflict=participant_id,station_id", {
      method:"POST",
      headers:{Prefer:"resolution=ignore-duplicates,return=representation"},
      body:JSON.stringify({participant_id:users[0].id, station_id:station}),
    });
    return reply({ok:true, station_id:station, already_collected:inserted.length === 0});
  } catch {
    return reply({error:"TEMPORARY_FAILURE"},500);
  }
});
