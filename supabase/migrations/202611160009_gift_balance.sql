begin;
create or replace function public.redeem_stamp_bundle(p_participant_id uuid,p_gift_ids integer[],p_request_id uuid,p_redeemed_by text)
returns uuid language plpgsql security invoker set search_path='' as $$
declare first_id uuid; previous_ids integer[]; collected integer; total integer; items integer; spent integer; last_no integer; start_no integer;
begin
 perform 1 from public.stamp_participants where id=p_participant_id for update;
 if not found then raise exception '找不到參加者'; end if;
 if p_request_id is null or coalesce(cardinality(p_gift_ids),0) not between 1 and 2
    or cardinality(p_gift_ids) <> (select count(distinct id) from unnest(p_gift_ids) id)
 then raise exception 'INVALID_SELECTION'; end if;
 select id,redemption_no into first_id,start_no from public.stamp_gift_redemptions where participant_id=p_participant_id and request_id=p_request_id;
 if found then
   select array_agg(gift_id order by gift_id) into previous_ids from public.stamp_gift_redemptions r where r.participant_id=p_participant_id and r.redemption_no>=start_no and not exists(select 1 from public.stamp_gift_redemptions n where n.participant_id=p_participant_id and n.request_id is not null and n.redemption_no>start_no and n.redemption_no<=r.redemption_no);
   if previous_ids = array(select id from unnest(p_gift_ids) id order by id) then return first_id; end if;
   raise exception 'INVALID_SELECTION';
 end if;
 if to_regclass('public.stamp_gift_archive') is not null then
   if exists(select 1 from public.stamp_gift_archive where participant_id=p_participant_id and request_id=p_request_id) then raise exception '兌換紀錄已更新，請重新載入集章卡。'; end if;
 end if;
 select coalesce(sum(stamp_cost),0),coalesce(max(redemption_no),0) into spent,last_no from public.stamp_gift_redemptions where participant_id=p_participant_id;
 perform 1 from public.stamp_gifts where id=any(p_gift_ids) order by id for share;
 select sum(stamp_cost),count(*) into total,items from public.stamp_gifts where id=any(p_gift_ids) and active;
 if items<>cardinality(p_gift_ids) then raise exception '這項贈品尚未開放兌換'; end if;
 select least(count(*),6) into collected from public.stamp_records where participant_id=p_participant_id;
 if total>collected-spent then raise exception '剩餘可用章數不足'; end if;
 insert into public.stamp_gift_redemptions(participant_id,gift_id,stamp_cost,redemption_no,redeemed_by,request_id)
 select p_participant_id,g.id,g.stamp_cost,last_no+i.n,p_redeemed_by,case when i.n=1 then p_request_id end
 from unnest(p_gift_ids) with ordinality i(id,n) join public.stamp_gifts g on g.id=i.id;
 select id into first_id from public.stamp_gift_redemptions where participant_id=p_participant_id and request_id=p_request_id;
 return first_id;
end; $$;
revoke all on function public.redeem_stamp_bundle(uuid,integer[],uuid,text) from public,anon,authenticated;
grant execute on function public.redeem_stamp_bundle(uuid,integer[],uuid,text) to service_role;
commit;
