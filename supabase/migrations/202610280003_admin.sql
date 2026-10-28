begin;

-- Existing participants receive a permanent number. Resetting records never changes it.
alter table public.stamp_participants
  add column if not exists participant_no bigint generated always as identity;
create unique index if not exists stamp_participants_number_idx
  on public.stamp_participants(participant_no);
grant usage, select on sequence public.stamp_participants_participant_no_seq to service_role;

create table if not exists public.stamp_admins (
  user_id uuid primary key references auth.users(id),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.stamp_admin_audit (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique,
  actor_id uuid not null,
  action text not null,
  target text not null,
  reason text not null,
  before_data jsonb not null,
  after_data jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.stamp_admins enable row level security;
alter table public.stamp_admin_audit enable row level security;
revoke all on public.stamp_admins, public.stamp_admin_audit from public, anon, authenticated;
grant select on public.stamp_admins to service_role;
grant select, insert on public.stamp_admin_audit to service_role;

create or replace function public.stamp_admin_snapshot(p_number bigint)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'number', p.participant_no::text, 'created_at', p.created_at,
    'stamps', coalesce((select jsonb_agg(jsonb_build_object(
      'station_id',s.station_id,'name',t.name,'collected_at',s.collected_at)
      order by s.station_id) from public.stamp_records s
      join public.stamp_stations t on t.id=s.station_id where s.participant_id=p.id),'[]'::jsonb),
    'redemptions', coalesce((select jsonb_agg(jsonb_build_object(
      'id',r.id,'vendor_id',r.vendor_id,'name',v.name,
      'redemption_no',r.redemption_no,'redeemed_at',r.redeemed_at)
      order by r.redemption_no) from public.stamp_redemptions r
      join public.stamp_vendors v on v.id=r.vendor_id where r.participant_id=p.id),'[]'::jsonb)
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
        (select count(*) from public.stamp_redemptions r where r.participant_id=p.id) as redeemed
      from public.stamp_participants p
    ), daily as (
      select (created_at at time zone 'Asia/Taipei')::date as day, 1 as joined, 0 as stamps, 0 as redeemed from public.stamp_participants
      union all select (collected_at at time zone 'Asia/Taipei')::date,0,1,0 from public.stamp_records
      union all select (redeemed_at at time zone 'Asia/Taipei')::date,0,0,1 from public.stamp_redemptions
    )
    select jsonb_build_object(
      'generated_at',now(),
      'total',(select count(*) from counts),
      'started',(select count(*) from counts where stamps>0),
      'three_or_more',(select count(*) from counts where stamps>=3),
      'completed',(select count(*) from counts where stamps=6),
      'redeemed_total',(select count(*) from public.stamp_redemptions),
      'stamp_distribution',(select jsonb_agg(jsonb_build_object('stamps',n,'people',(select count(*) from counts c where c.stamps=n)) order by n) from generate_series(0,6) n),
      'redemption_distribution',(select jsonb_agg(jsonb_build_object('redeemed',n,'people',(select count(*) from counts c where c.redeemed=n)) order by n) from generate_series(0,2) n),
      'stations',(select jsonb_agg(jsonb_build_object('id',t.id,'name',t.name,'active',t.active,'people',(select count(*) from public.stamp_records s where s.station_id=t.id)) order by t.id) from public.stamp_stations t),
      'vendors',(select jsonb_agg(jsonb_build_object('id',v.id,'name',v.name,'active',v.active,
        'people',(select count(distinct participant_id) from public.stamp_redemptions r where r.vendor_id=v.id),
        'portions',(select count(*) from public.stamp_redemptions r where r.vendor_id=v.id),
        'first',(select count(*) from public.stamp_redemptions r where r.vendor_id=v.id and redemption_no=1),
        'second',(select count(*) from public.stamp_redemptions r where r.vendor_id=v.id and redemption_no=2)) order by v.id) from public.stamp_vendors v),
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
        (select count(*) from public.stamp_redemptions r where r.participant_id=p.id) as redeemed
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
    return jsonb_build_object('ok',true,'already_applied',true,'target',v_existing.target);
  end if;

  if p_action='reset' then
    v_number=(p_payload->>'number')::bigint;
    v_kind=p_payload->>'mode';
    if v_kind is null or v_kind not in ('redemptions','all') then raise exception 'INVALID_MODE'; end if;
    select id into v_id from public.stamp_participants where participant_no=v_number for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    v_before=public.stamp_admin_snapshot(v_number);
    if (p_payload->>'revision') is distinct from md5(v_before::text) then raise exception 'RECORD_CHANGED'; end if;
    delete from public.stamp_redemptions where participant_id=v_id;
    if v_kind='all' then delete from public.stamp_records where participant_id=v_id; end if;
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
      select to_jsonb(t) into v_before from public.stamp_vendors t where id=v_number for update;
      if v_before is null then raise exception 'NOT_FOUND'; end if;
      if (p_payload->'expected') is distinct from v_before then raise exception 'RECORD_CHANGED'; end if;
      update public.stamp_vendors set name=v_name,active=v_active where id=v_number;
      select to_jsonb(t) into v_after from public.stamp_vendors t where id=v_number;
    end if;
    v_target=v_kind||':'||v_number;
  end if;
  insert into public.stamp_admin_audit(request_id,actor_id,action,target,reason,before_data,after_data)
    values(v_request,p_actor,p_action,v_target,v_reason,v_before,v_after);
  return jsonb_build_object('ok',true,'already_applied',false,'target',v_target);
end;
$$;
revoke all on function public.stamp_admin_snapshot(bigint) from public,anon,authenticated;
revoke all on function public.stamp_admin_api(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.stamp_admin_snapshot(bigint) to service_role;
grant execute on function public.stamp_admin_api(uuid,text,jsonb) to service_role;
commit;
select '管理後台資料庫設定完成' as result;
