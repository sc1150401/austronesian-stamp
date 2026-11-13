-- 本次專用：安裝清除功能後，立即清空所有集章卡並保留贈品紀錄。
begin;
create table if not exists public.stamp_gift_archive (like public.stamp_gift_redemptions including defaults, primary key(id));
alter table public.stamp_gift_archive enable row level security;
revoke all on public.stamp_gift_archive from public,anon,authenticated;
grant select,insert,delete on public.stamp_gift_archive to service_role;
create index if not exists stamp_archive_participant on public.stamp_gift_archive(participant_id,request_id);
create or replace view public.stamp_gift_history with (security_invoker=true) as
 select r.*,false as archived from public.stamp_gift_redemptions r union all
 select r.*,true as archived from public.stamp_gift_archive r;
revoke all on public.stamp_gift_history from public,anon,authenticated;
grant select on public.stamp_gift_history to service_role;
create or replace function public.stamp_admin_snapshot(p_number bigint)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'number', p.participant_no::text, 'created_at', p.created_at,
    'spent_stamps',coalesce((select sum(stamp_cost) from public.stamp_gift_redemptions where participant_id=p.id),0),
    'stamps', coalesce((select jsonb_agg(jsonb_build_object(
      'station_id',s.station_id,'name',t.name,'collected_at',s.collected_at)
      order by s.station_id) from public.stamp_records s
      join public.stamp_stations t on t.id=s.station_id where s.participant_id=p.id),'[]'::jsonb),
    'redemptions', coalesce((select jsonb_agg(jsonb_build_object(
      'id',r.id,'gift_id',r.gift_id,'stamp_cost',r.stamp_cost,'name',v.name,
      'archived',r.archived,'redemption_no',r.redemption_no,'redeemed_at',r.redeemed_at)
      order by r.redeemed_at,r.redemption_no) from public.stamp_gift_history r
      join public.stamp_gifts v on v.id=r.gift_id where r.participant_id=p.id),'[]'::jsonb)
  ) from public.stamp_participants p where p.participant_no=p_number;
$$;

create or replace function public.stamp_admin_api(
  p_actor uuid, p_action text, p_payload jsonb default '{}'::jsonb
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_number bigint; v_id uuid; v_before jsonb; v_after jsonb;
  v_request uuid; v_existing public.stamp_admin_audit%rowtype;
  v_target text; v_kind text; v_name text; v_active boolean; v_reason text;
  v_result jsonb; v_limit integer; v_cursor bigint;
begin
  if not exists(select 1 from public.stamp_admins where user_id=p_actor and active) then
    raise exception 'ADMIN_REQUIRED';
  end if;
  if p_action='session' then return jsonb_build_object('ok',true); end if;

  if p_action='overview' then
    with counts as (
      select p.id,
        (select count(*) from public.stamp_records s where s.participant_id=p.id) as stamps,
        (select count(*) from public.stamp_gift_history r where r.participant_id=p.id) as redeemed
      from public.stamp_participants p
    ), daily as (
      select (created_at at time zone 'Asia/Taipei')::date as day, 1 as joined, 0 as stamps, 0 as redeemed from public.stamp_participants
      union all select (collected_at at time zone 'Asia/Taipei')::date,0,1,0 from public.stamp_records
      union all select (redeemed_at at time zone 'Asia/Taipei')::date,0,0,1 from public.stamp_gift_history
    )
    select jsonb_build_object(
      'rules_version','gifts-v1','generated_at',now(),
      'total',(select count(*) from counts),
      'started',(select count(*) from counts where stamps>0),
      'two_or_more',(select count(*) from counts where stamps>=2),
      'completed',(select count(*) from counts where stamps=6),
      'redeemed_total',(select count(*) from public.stamp_gift_history),
      'stamp_distribution',(select jsonb_agg(jsonb_build_object('stamps',n,'people',(select count(*) from counts c where c.stamps=n)) order by n) from generate_series(0,6) n),
      'redemption_distribution',(select jsonb_agg(jsonb_build_object('redeemed',n,'people',(select count(*) from counts c where c.redeemed=n)) order by n) from generate_series(0,greatest(3,(select max(redeemed)::integer from counts))) n),
      'stations',(select jsonb_agg(jsonb_build_object('id',t.id,'name',t.name,'active',t.active,'people',(select count(*) from public.stamp_records s where s.station_id=t.id)) order by t.id) from public.stamp_stations t),
      'vendors',(select jsonb_agg(jsonb_build_object('id',v.id,'name',v.name,'active',v.active,'stamp_cost',v.stamp_cost,
        'people',(select count(distinct participant_id) from public.stamp_gift_history r where r.gift_id=v.id),
        'portions',(select count(*) from public.stamp_gift_history r where r.gift_id=v.id),
        'first',(select count(*) from public.stamp_gift_history r where r.gift_id=v.id and redemption_no=1),
        'second',(select count(*) from public.stamp_gift_history r where r.gift_id=v.id and redemption_no=2)) order by v.id) from public.stamp_gifts v),
      'daily',coalesce((select jsonb_agg(to_jsonb(d) order by d.day) from (select day,sum(joined) joined,sum(stamps) stamps,sum(redeemed) redeemed from daily group by day) d),'[]'::jsonb)
    ) into v_result;
    return v_result;
  end if;

  if p_action='participant' then
    v_result=public.stamp_admin_snapshot((p_payload->>'number')::bigint);
    if v_result is null then raise exception 'NOT_FOUND'; end if;
    return v_result || jsonb_build_object('revision',md5(v_result::text));
  end if;

  if p_action='participants' then
    v_limit=least(500,greatest(1,coalesce((p_payload->>'limit')::integer,100)));
    v_cursor=coalesce((p_payload->>'after')::bigint,0);
    select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_no),'[]'::jsonb) into v_result from (
      select p.participant_no as sort_no,p.participant_no::text as number,p.created_at,
        (select count(*) from public.stamp_records s where s.participant_id=p.id) as stamps,
        (select count(*) from public.stamp_gift_history r where r.participant_id=p.id) as redeemed,
        coalesce((select sum(stamp_cost) from public.stamp_gift_redemptions r where r.participant_id=p.id),0) as spent_stamps
      from public.stamp_participants p where p.participant_no>v_cursor
      order by p.participant_no limit v_limit
    ) x;
    return jsonb_build_object('rows',v_result);
  end if;

  if p_action='audit' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_result from (
      select id,actor_id,action,target,reason,before_data,after_data,created_at
      from public.stamp_admin_audit order by created_at desc,id desc limit 100
    ) x;
    return jsonb_build_object('rows',v_result);
  end if;

  if p_action not in ('reset','catalog') then raise exception 'INVALID_ACTION'; end if;
  v_request=(p_payload->>'request_id')::uuid;
  if v_request is null then raise exception 'REQUEST_ID_REQUIRED'; end if;
  v_reason=btrim(coalesce(p_payload->>'reason',''));
  if char_length(v_reason)<2 or char_length(v_reason)>500 then raise exception 'REASON_REQUIRED'; end if;
  -- Serialize identical retry IDs so a delayed repeat cannot erase newly collected stamps.
  perform pg_advisory_xact_lock(hashtextextended(v_request::text,0));
  select * into v_existing from public.stamp_admin_audit where request_id=v_request;
  if found then
    if v_existing.actor_id<>p_actor or v_existing.action<>p_action then raise exception 'REQUEST_CONFLICT'; end if;
    return jsonb_build_object('ok',true,'already_applied',true,'target',v_existing.target,'removed',v_existing.before_data->'stamps');
  end if;

  if p_action='reset' and p_payload->>'mode'='all_stamps_only' then
    lock table public.stamp_participants,public.stamp_records,public.stamp_gift_redemptions in share row exclusive mode;
    -- Preserve receipts and release their old charges before opening the new stamp cards.
    with moved as (delete from public.stamp_gift_redemptions where participant_id is not null returning *)
      insert into public.stamp_gift_archive(id,participant_id,gift_id,stamp_cost,redemption_no,redeemed_at,redeemed_by,request_id)
      select id,participant_id,gift_id,stamp_cost,redemption_no,redeemed_at,redeemed_by,request_id from moved;
    delete from public.stamp_records where participant_id is not null;
    get diagnostics v_number=row_count;
    v_target='全部集章卡';
    v_before=jsonb_build_object('stamps',v_number);
    v_after=jsonb_build_object('stamps',0);
  elsif p_action='reset' and p_payload->>'mode' in ('all_rewards_only','all_stamps_rewards') then
    lock table public.stamp_participants,public.stamp_records,public.stamp_gift_redemptions,public.stamp_gift_archive in share row exclusive mode;
    select jsonb_build_object('redemptions',(select count(*) from public.stamp_gift_history),
      'stamps',(select count(*) from public.stamp_records)) into v_before;
    delete from public.stamp_gift_redemptions where participant_id is not null;
    delete from public.stamp_gift_archive where participant_id is not null;
    if p_payload->>'mode'='all_stamps_rewards' then
      delete from public.stamp_records where participant_id is not null;
      v_target='全部集章與兌換';
      v_after=jsonb_build_object('stamps',0,'redemptions',0);
    else
      v_target='全部兌換';
      v_after=jsonb_build_object('stamps',v_before->'stamps','redemptions',0);
    end if;
  elsif p_action='reset' then
    v_number=(p_payload->>'number')::bigint;
    v_kind=p_payload->>'mode';
    if v_kind is null or v_kind not in ('stamps_only','redemptions','all') then raise exception 'INVALID_MODE'; end if;
    select id into v_id from public.stamp_participants where participant_no=v_number for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    v_before=public.stamp_admin_snapshot(v_number);
    if (p_payload->>'revision') is distinct from md5(v_before::text) then raise exception 'RECORD_CHANGED'; end if;
    if v_kind='stamps_only' then
      with moved as (
        delete from public.stamp_gift_redemptions where participant_id=v_id returning *
      )
      insert into public.stamp_gift_archive(id,participant_id,gift_id,stamp_cost,redemption_no,redeemed_at,redeemed_by,request_id)
        select id,participant_id,gift_id,stamp_cost,redemption_no,redeemed_at,redeemed_by,request_id from moved;
    else
      delete from public.stamp_gift_redemptions where participant_id=v_id;
      delete from public.stamp_gift_archive where participant_id=v_id;
    end if;
    if v_kind in ('stamps_only','all') then delete from public.stamp_records where participant_id=v_id; end if;
    v_after=public.stamp_admin_snapshot(v_number);
    v_target='A'||lpad(v_number::text,greatest(6,length(v_number::text)),'0');
  else
    v_kind=p_payload->>'kind';
    if v_kind is null or v_kind not in ('station','vendor') then raise exception 'INVALID_KIND'; end if;
    v_number=(p_payload->>'id')::bigint;
    v_name=btrim(coalesce(p_payload->>'name',''));
    if char_length(v_name)<1 or char_length(v_name)>100 then raise exception 'INVALID_NAME'; end if;
    if jsonb_typeof(p_payload->'active') is distinct from 'boolean' then raise exception 'INVALID_ACTIVE'; end if;
    v_active=(p_payload->>'active')::boolean;
    if v_kind='station' then
      select to_jsonb(t) into v_before from public.stamp_stations t where id=v_number for update;
      if v_before is null then raise exception 'NOT_FOUND'; end if;
      if (p_payload->'expected') is distinct from v_before then raise exception 'RECORD_CHANGED'; end if;
      update public.stamp_stations set name=v_name,active=v_active where id=v_number;
      select to_jsonb(t) into v_after from public.stamp_stations t where id=v_number;
    else
      select to_jsonb(t) into v_before from public.stamp_gifts t where id=v_number for update;
      if v_before is null then raise exception 'NOT_FOUND'; end if;
      if (p_payload->'expected') is distinct from v_before then raise exception 'RECORD_CHANGED'; end if;
      update public.stamp_gifts set name=v_name,active=v_active where id=v_number;
      select to_jsonb(t) into v_after from public.stamp_gifts t where id=v_number;
    end if;
    v_target=v_kind||':'||v_number;
  end if;
  insert into public.stamp_admin_audit(request_id,actor_id,action,target,reason,before_data,after_data)
    values(v_request,p_actor,p_action,v_target,v_reason,v_before,v_after);
  return jsonb_build_object('ok',true,'already_applied',false,'target',v_target,'removed',v_before->'stamps');
end;
$$;
create or replace function public.redeem_stamp_gift_v2(p_participant_id uuid,p_gift_id integer,p_redeemed_by text,p_request_id uuid,p_expected_spent integer)
returns uuid language plpgsql security invoker set search_path='' as $$
declare v_id uuid; v_cost integer; v_active boolean; v_collected integer; v_spent integer; v_count integer;
begin
 -- Same lock as admin reset: serialize spends and resets for this participant.
 perform 1 from public.stamp_participants where id=p_participant_id for update;
 if not found then raise exception '找不到參加者'; end if;
 if p_request_id is null then raise exception 'INVALID_REQUEST'; end if;
 if exists(select 1 from public.stamp_gift_archive where participant_id=p_participant_id and request_id=p_request_id) then raise exception '兌換紀錄已更新，請重新載入集章卡。'; end if;
 select id into v_id from public.stamp_gift_redemptions where participant_id=p_participant_id and request_id=p_request_id and gift_id=p_gift_id;
 if found then return v_id; end if; -- Safe retry; never grants another copy.
 select stamp_cost,active into v_cost,v_active from public.stamp_gifts where id=p_gift_id for share;
 if not found then raise exception '贈品不存在'; end if;
 if not v_active then raise exception '這項贈品尚未開放兌換'; end if;
 select count(*) into v_collected from public.stamp_records where participant_id=p_participant_id;
 select coalesce(sum(stamp_cost),0),count(*) into v_spent,v_count from public.stamp_gift_redemptions where participant_id=p_participant_id;
 if v_spent is distinct from p_expected_spent then raise exception '兌換紀錄已更新，請重新載入集章卡。'; end if;
 if least(v_collected,6)-v_spent<v_cost then raise exception '剩餘可用章數不足'; end if;
 insert into public.stamp_gift_redemptions(participant_id,gift_id,stamp_cost,redemption_no,redeemed_by,request_id)
 values(p_participant_id,p_gift_id,v_cost,v_count+1,p_redeemed_by,p_request_id) returning id into v_id;
 return v_id;
end; $$;
revoke all on function public.redeem_stamp_gift_v2(uuid,integer,text,uuid,integer) from public,anon,authenticated;
grant execute on function public.redeem_stamp_gift_v2(uuid,integer,text,uuid,integer) to service_role;


-- Use a fixed request ID so rerunning this file preserves any stamps collected later.
do $once$
declare
  operation_id constant uuid := 'd99d5a65-ec90-497e-b2bb-2861444db931';
  cleared bigint;
begin
  perform pg_advisory_xact_lock(hashtextextended(operation_id::text,0));
  if exists(select 1 from public.stamp_admin_audit where request_id=operation_id) then return; end if;
  lock table public.stamp_participants,public.stamp_records,public.stamp_gift_redemptions in share row exclusive mode;
  with moved as (delete from public.stamp_gift_redemptions where participant_id is not null returning *)
  insert into public.stamp_gift_archive(id,participant_id,gift_id,stamp_cost,redemption_no,redeemed_at,redeemed_by,request_id)
    select id,participant_id,gift_id,stamp_cost,redemption_no,redeemed_at,redeemed_by,request_id from moved;
  delete from public.stamp_records where participant_id is not null;
  get diagnostics cleared=row_count;
  -- SQL Editor operates as a database role, outside the web administrator session.
  insert into public.stamp_admin_audit(request_id,actor_id,action,target,reason,before_data,after_data)
    values(operation_id,'00000000-0000-0000-0000-000000000000','reset','全部集章卡','SQL Editor / '||current_user,jsonb_build_object('stamps',cleared),jsonb_build_object('stamps',0));
end $once$;
commit;
select (select count(*) from public.stamp_records) as "剩餘章數",
       (select count(*) from public.stamp_gift_history) as "保留兌換份數",
       (select count(*) from public.stamp_participants) as "保留帳戶數";
