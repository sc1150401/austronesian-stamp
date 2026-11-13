begin;
-- Keep historical charges as recorded, including the original 4-stamp socks.
alter table public.stamp_gift_redemptions drop constraint if exists stamp_gift_redemptions_gift_id_stamp_cost_fkey;
alter table public.stamp_gifts drop constraint if exists stamp_gifts_id_check, drop constraint if exists stamp_gifts_check;
alter table public.stamp_gifts drop constraint if exists stamp_gifts_current_prices;
update public.stamp_gifts set stamp_cost=3 where id=2 and stamp_cost=4;
update public.stamp_gifts set name='南島小巨人紋身貼紙' where id=1 and name='南島紋身貼紙';
update public.stamp_gifts set name='南島特色絲巾禮盒' where id=3 and name='南島絲巾禮盒';
insert into public.stamp_gifts(id,name,stamp_cost) values(4,'南島小巨人吊飾',4) on conflict do nothing;
alter table public.stamp_gifts add constraint stamp_gifts_current_prices check ((id,stamp_cost) in ((1,2),(2,3),(4,4),(3,6)));
alter table public.stamp_gift_redemptions drop constraint if exists stamp_gift_history_id,
 drop constraint if exists stamp_gift_history_price;
alter table public.stamp_gift_redemptions add constraint stamp_gift_history_id foreign key(gift_id) references public.stamp_gifts(id),
 add constraint stamp_gift_history_price check ((gift_id,stamp_cost) in ((1,2),(2,3),(2,4),(4,4),(3,6)));
revoke execute on function public.redeem_stamp_gift(uuid,integer,text) from public,anon,authenticated,service_role;
alter table public.stamp_gift_redemptions
 drop constraint if exists stamp_gift_redemptions_participant_id_gift_id_key,
 drop constraint if exists stamp_gift_redemptions_redemption_no_check,
 add column if not exists request_id uuid;
create unique index if not exists stamp_redemption_request on public.stamp_gift_redemptions(participant_id,request_id);
create or replace function public.redeem_stamp_gift_v2(p_participant_id uuid,p_gift_id integer,p_redeemed_by text,p_request_id uuid,p_expected_spent integer)
returns uuid language plpgsql security invoker set search_path='' as $$
declare v_id uuid; v_cost integer; v_active boolean; v_collected integer; v_spent integer; v_count integer;
begin
 -- Same lock as admin reset: serialize spends and resets for this participant.
 perform 1 from public.stamp_participants where id=p_participant_id for update;
 if not found then raise exception '找不到參加者'; end if;
 if p_request_id is null then raise exception 'INVALID_REQUEST'; end if;
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

create table if not exists public.stamp_site_copy(
 id integer primary key check(id=1), version integer not null default 0,
 texts jsonb not null default '{}',updated_by uuid,updated_at timestamptz
);
insert into public.stamp_site_copy(id) values(1) on conflict do nothing;
alter table public.stamp_site_copy enable row level security;
revoke all on public.stamp_site_copy from public,anon,authenticated;
grant select,update on public.stamp_site_copy to service_role;
create or replace function public.stamp_save_site_copy(p_actor uuid,p_version integer,p_texts jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_version integer; v_key text; v_value jsonb;
begin
 if not exists(select 1 from public.stamp_admins where user_id=p_actor and active) then raise exception 'ADMIN_REQUIRED'; end if;
 if jsonb_typeof(p_texts) is distinct from 'object' or octet_length(p_texts::text)>500000 then raise exception 'INVALID_TEXT'; end if;
 for v_key,v_value in select * from jsonb_each(p_texts) loop
   if not ('["南島文化節｜南島尋潮・集章任務", "連線測試版｜登入後讀取帳號的雲端集章紀錄。掃碼集章設定中，僅開放指定測試站；贈品兌換僅供測試，不作為正式領獎憑證。", "開始集章", "正在連接 LINE…", "使用 LINE 登入", "請先加入雙創營銷顧問有限公司官方 LINE；若已封鎖，請解除封鎖。", "加入雙創官方 LINE", "加入後回到本頁，點「我已加入，繼續集章」。", "登入後由後端驗證 LINE 身分，建立參加者資料並讀取紀錄；先前的模擬章不會轉入。", "2026 屏東南島文化節", "探索南島，收集文化足跡。", "探索全場域六個集章點，收集屬於你的文化足跡。", "2 章換南島小巨人紋身貼紙、3 章換南島特色襪子、4 章換南島小巨人吊飾、6 章換南島特色絲巾禮盒。兌換會扣除可用章數，同款贈品可重複兌換。", "12.05 — 12.06　屏東縣民公園", "我的集章卡", "掃描 QR 集章", "重新整理紀錄", "參加者編號：", "複製編號", "集章點名稱暫定。正式版將由現場 QR Code 開啟對應集章點。", "集章好禮兌換", "每次扣章・同款可重複換", "每次兌換將扣除對應的可用章數，已使用的章不可重複兌換。只要剩餘章數足夠，就能再換同款或其他贈品。想換絲巾禮盒，請保留全部 6 章。請在工作人員面前操作，確認後無法取消。", "集章小提醒", "① 全場域設有 6 個集章點，每個點限集一次，最多累積 6 章。", "② 貼紙扣 2 章、襪子扣 3 章、吊飾扣 4 章、絲巾禮盒扣 6 章；剩餘章數足夠即可再次兌換同款贈品。", "③ 例如集滿 6 章，可換 3 份貼紙、2 雙襪子、貼紙加吊飾各 1 份，或 1 盒絲巾。", "④ 一旦兌換貼紙、襪子或吊飾，就無法再換絲巾禮盒。兌換扣除可用章數，但保留各站集章紀錄。", "確認兌換", "請在工作人員面前操作，確認後無法取消。", "取消", "帳號連線測試版", "南島尋潮｜集章任務", "2026 屏東南島文化節；指導單位：原住民族委員會；主辦單位：屏東縣政府", "這一站尚未開放集章。", "請先加入雙創官方 LINE，或解除封鎖後再試。", "登入已失效，請關閉後重新開啟集章頁。", "暫時無法確認 LINE 好友狀態，請稍後再試。", "集章後端尚未部署，請完成設定後重試。", "印記尚未確認，請重新整理重試。", "集章回應不符，請重試。", "這一站已集過章，不會重複計算。", "✓ 已取得集章點 0{0} 的印記！", "族服時裝秀", "全國樂舞大賽", "南島音樂舞台", "sanguaq好食展", "收穫一條街", "部落生活百樣", "{0} / 6 個印記", "尚未載入", "集章點 0{0}", "等待載入", "✓ 已收集", "等待你的足跡", "南島小巨人紋身貼紙", "南島特色襪子", "南島特色絲巾禮盒", "登入已失效，請重新開啟頁面。", "贈品服務尚未就緒或連線失敗，請稍後重試。", "贈品紀錄格式異常，請重新整理。", "{0} 個章｜同款可重複換", "兌換{0}", "贈品兌換設定中，暫未開放", "暫未開放兌換", "剩餘可用章數不足", "請交由現場工作人員確認", "贈品服務尚未就緒，兌換暫時關閉；集章紀錄仍保留。", "累積 {0} 章・已使用 {1} 章・剩餘可用 {2} 章", "✓ {0}｜已扣 {1} 章｜{2}", "確定兌換【{0}】1 份？將扣除 {1} 章，剩餘 {2} 章。", "確認兌換（扣 {0} 章）", "正在確認兌換，請稍候…", "尚未確認兌換結果，請重試同一份兌換。", "贈品", "✓ {0}兌換已確認，已扣 {1} 章。兌換時間：{2}。請向工作人員領取本次贈品。", "完成", "連線失敗，請重試同一份兌換。", "重試確認這 1 份", "正在載入你的集章卡…", "請登入 LINE，讀取你的集章卡。", "正在前往雙創官方 LINE 加好友頁…", "我已加入，繼續集章", "集章點 0{0} 已保留，加入好友後即可繼續。", "加入好友後，即可繼續集章。", "正在確認並儲存印記…", "集章連線逾時，尚未確認結果，請重試。", "集章服務連線失敗，請確認網路後重試。", "集章連線失敗，請稍後重試。", "正在驗證身分並讀取雲端紀錄…", "LINE 登入憑證未通過驗證，請重新登入。", "重新登入 LINE", "✓ LINE 身分驗證成功，集章紀錄已從資料庫載入。", "重新整理集章紀錄", "{0} 原有紀錄已載入，本次站點保留供重試。", "重試取得印記", "已登入 LINE，但雲端紀錄載入失敗。請稍後重試；目前不顯示集章數量。", "暫時無法連接 LINE，請確認網路及測試員資格後重試。", "重新連線", "此環境無法開啟相機。請改用 LINE 掃描現場站點 QR，即可回到此頁集章。", "這不是本活動的集章 QR，請掃描集章點 01～06 的 QR。", "掃描未完成，請確認相機權限後重試。", " 已複製", " 請長按上方編號複製", "找不到參加者", "贈品不存在", "這項贈品尚未開放兌換", "南島小巨人吊飾", "兌換紀錄已更新，請重新載入集章卡。", "已兌換"]'::jsonb ? v_key) or jsonb_typeof(v_value)<>'string' or length(trim(v_value#>>'{}'))=0 or length(v_value#>>'{}')>3000 then raise exception 'INVALID_TEXT'; end if;
   if (select array_agg(m order by m) from regexp_matches(v_key,'\{[0-9]+\}','g') m)
      is distinct from (select array_agg(m order by m) from regexp_matches(v_value#>>'{}','\{[0-9]+\}','g') m) then raise exception 'INVALID_TEXT'; end if;
 end loop;
 update public.stamp_site_copy set texts=p_texts,version=version+1,updated_by=p_actor,updated_at=now() where id=1 and version=p_version returning version into v_version;
 if not found then raise exception 'RECORD_CHANGED'; end if;
 return jsonb_build_object('version',v_version);
end; $$;
revoke all on function public.stamp_save_site_copy(uuid,integer,jsonb) from public,anon,authenticated;
grant execute on function public.stamp_save_site_copy(uuid,integer,jsonb) to service_role;

-- Remove obsolete reward descriptions while preserving unrelated published edits.
update public.stamp_site_copy set texts=texts-array['2 章換南島紋身貼紙、4 章換南島特色襪子、6 章換南島絲巾禮盒。兌換會扣除可用章數，每種贈品每人限領一次。','② 貼紙扣 2 章、襪子扣 4 章、絲巾禮盒扣 6 章；每種贈品每人限兌換一次。','③ 集滿 6 章可換「貼紙＋襪子」（可分次兌換），或「絲巾禮盒」。也可只換貼紙或襪子。','④ 一旦兌換貼紙或襪子，就無法再換絲巾禮盒。兌換扣除可用章數，但保留各站集章紀錄。','兌換後無法再換南島絲巾禮盒。','南島紋身貼紙','南島絲巾禮盒','每次兌換將扣除對應的可用章數，已使用的章不可重複兌換。先換貼紙後，集滿其餘 4 章，最多可再換襪子，不能再換絲巾禮盒。想換絲巾禮盒，請保留全部 6 章。請在工作人員面前操作，確認後無法取消。'], version=version+1 where texts ?| array['2 章換南島紋身貼紙、4 章換南島特色襪子、6 章換南島絲巾禮盒。兌換會扣除可用章數，每種贈品每人限領一次。','② 貼紙扣 2 章、襪子扣 4 章、絲巾禮盒扣 6 章；每種贈品每人限兌換一次。','③ 集滿 6 章可換「貼紙＋襪子」（可分次兌換），或「絲巾禮盒」。也可只換貼紙或襪子。','④ 一旦兌換貼紙或襪子，就無法再換絲巾禮盒。兌換扣除可用章數，但保留各站集章紀錄。','兌換後無法再換南島絲巾禮盒。','南島紋身貼紙','南島絲巾禮盒','每次兌換將扣除對應的可用章數，已使用的章不可重複兌換。先換貼紙後，集滿其餘 4 章，最多可再換襪子，不能再換絲巾禮盒。想換絲巾禮盒，請保留全部 6 章。請在工作人員面前操作，確認後無法取消。'];
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
        (select count(*) from public.stamp_gift_redemptions r where r.participant_id=p.id) as redeemed
      from public.stamp_participants p
    ), daily as (
      select (created_at at time zone 'Asia/Taipei')::date as day, 1 as joined, 0 as stamps, 0 as redeemed from public.stamp_participants
      union all select (collected_at at time zone 'Asia/Taipei')::date,0,1,0 from public.stamp_records
      union all select (redeemed_at at time zone 'Asia/Taipei')::date,0,0,1 from public.stamp_gift_redemptions
    )
    select jsonb_build_object(
      'rules_version','gifts-v1','generated_at',now(),
      'total',(select count(*) from counts),
      'started',(select count(*) from counts where stamps>0),
      'two_or_more',(select count(*) from counts where stamps>=2),
      'completed',(select count(*) from counts where stamps=6),
      'redeemed_total',(select count(*) from public.stamp_gift_redemptions),
      'stamp_distribution',(select jsonb_agg(jsonb_build_object('stamps',n,'people',(select count(*) from counts c where c.stamps=n)) order by n) from generate_series(0,6) n),
      'redemption_distribution',(select jsonb_agg(jsonb_build_object('redeemed',n,'people',(select count(*) from counts c where c.redeemed=n)) order by n) from generate_series(0,3) n),
      'stations',(select jsonb_agg(jsonb_build_object('id',t.id,'name',t.name,'active',t.active,'people',(select count(*) from public.stamp_records s where s.station_id=t.id)) order by t.id) from public.stamp_stations t),
      'vendors',(select jsonb_agg(jsonb_build_object('id',v.id,'name',v.name,'active',v.active,'stamp_cost',v.stamp_cost,
        'people',(select count(distinct participant_id) from public.stamp_gift_redemptions r where r.gift_id=v.id),
        'portions',(select count(*) from public.stamp_gift_redemptions r where r.gift_id=v.id),
        'first',(select count(*) from public.stamp_gift_redemptions r where r.gift_id=v.id and redemption_no=1),
        'second',(select count(*) from public.stamp_gift_redemptions r where r.gift_id=v.id and redemption_no=2)) order by v.id) from public.stamp_gifts v),
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
        (select count(*) from public.stamp_gift_redemptions r where r.participant_id=p.id) as redeemed,
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
    delete from public.stamp_gift_redemptions where participant_id=v_id;
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
  return jsonb_build_object('ok',true,'already_applied',false,'target',v_target);
end;
$$;
revoke all on function public.stamp_admin_snapshot(bigint) from public,anon,authenticated;
revoke all on function public.stamp_admin_api(uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.stamp_admin_snapshot(bigint) to service_role;
grant execute on function public.stamp_admin_api(uuid,text,jsonb) to service_role;

update public.stamp_site_copy set texts=texts-array['兌換扣章・每種限領一次','{0} 個章｜每人限領一次','已兌換','已領取，不能重複兌換','兌換後無法再換其他贈品。','確定兌換【{0}】1 份？將扣除 {1} 章，剩餘 {2} 章。{3}','✓ {0}兌換已確認，已扣 {1} 章。兌換時間：{2}。請勿重複領取。'],version=version+1 where texts ?| array['兌換扣章・每種限領一次','{0} 個章｜每人限領一次','已兌換','已領取，不能重複兌換','兌換後無法再換其他贈品。','確定兌換【{0}】1 份？將扣除 {1} 章，剩餘 {2} 章。{3}','✓ {0}兌換已確認，已扣 {1} 章。兌換時間：{2}。請勿重複領取。'];
commit;
