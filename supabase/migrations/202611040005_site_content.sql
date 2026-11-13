begin;
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
   if not ('["南島文化節｜南島尋潮・集章任務", "連線測試版｜登入後讀取帳號的雲端集章紀錄。掃碼集章設定中，僅開放指定測試站；贈品兌換僅供測試，不作為正式領獎憑證。", "開始集章", "正在連接 LINE…", "使用 LINE 登入", "請先加入雙創營銷顧問有限公司官方 LINE；若已封鎖，請解除封鎖。", "加入雙創官方 LINE", "加入後回到本頁，點「我已加入，繼續集章」。", "登入後由後端驗證 LINE 身分，建立參加者資料並讀取紀錄；先前的模擬章不會轉入。", "2026 屏東南島文化節", "探索南島，收集文化足跡。", "探索全場域六個集章點，收集屬於你的文化足跡。", "2 章換南島紋身貼紙、4 章換南島特色襪子、6 章換南島絲巾禮盒。兌換會扣除可用章數，每種贈品每人限領一次。", "12.05 — 12.06　屏東縣民公園", "我的集章卡", "掃描 QR 集章", "重新整理紀錄", "參加者編號：", "複製編號", "集章點名稱暫定。正式版將由現場 QR Code 開啟對應集章點。", "集章好禮兌換", "兌換扣章・每種限領一次", "每次兌換將扣除對應的可用章數，已使用的章不可重複兌換。先換貼紙後，集滿其餘 4 章，最多可再換襪子，不能再換絲巾禮盒。想換絲巾禮盒，請保留全部 6 章。請在工作人員面前操作，確認後無法取消。", "集章小提醒", "① 全場域設有 6 個集章點，每個點限集一次，最多累積 6 章。", "② 貼紙扣 2 章、襪子扣 4 章、絲巾禮盒扣 6 章；每種贈品每人限兌換一次。", "③ 集滿 6 章可換「貼紙＋襪子」（可分次兌換），或「絲巾禮盒」。也可只換貼紙或襪子。", "④ 一旦兌換貼紙或襪子，就無法再換絲巾禮盒。兌換扣除可用章數，但保留各站集章紀錄。", "確認兌換", "請在工作人員面前操作，確認後無法取消。", "取消", "帳號連線測試版", "南島尋潮｜集章任務", "2026 屏東南島文化節；指導單位：原住民族委員會；主辦單位：屏東縣政府", "這一站尚未開放集章。", "請先加入雙創官方 LINE，或解除封鎖後再試。", "登入已失效，請關閉後重新開啟集章頁。", "暫時無法確認 LINE 好友狀態，請稍後再試。", "集章後端尚未部署，請完成設定後重試。", "印記尚未確認，請重新整理重試。", "集章回應不符，請重試。", "這一站已集過章，不會重複計算。", "✓ 已取得集章點 0{0} 的印記！", "族服時裝秀", "全國樂舞大賽", "南島音樂舞台", "sanguaq好食展", "收穫一條街", "部落生活百樣", "{0} / 6 個印記", "尚未載入", "集章點 0{0}", "等待載入", "✓ 已收集", "等待你的足跡", "南島紋身貼紙", "南島特色襪子", "南島絲巾禮盒", "登入已失效，請重新開啟頁面。", "贈品服務尚未就緒或連線失敗，請稍後重試。", "贈品紀錄格式異常，請重新整理。", "{0} 個章｜每人限領一次", "已兌換", "兌換{0}", "贈品兌換設定中，暫未開放", "已領取，不能重複兌換", "暫未開放兌換", "剩餘可用章數不足", "請交由現場工作人員確認", "贈品服務尚未就緒，兌換暫時關閉；集章紀錄仍保留。", "累積 {0} 章・已使用 {1} 章・剩餘可用 {2} 章", "✓ {0}｜已扣 {1} 章｜{2}", "兌換後無法再換其他贈品。", "兌換後無法再換南島絲巾禮盒。", "確定兌換【{0}】1 份？將扣除 {1} 章，剩餘 {2} 章。{3}", "確認兌換（扣 {0} 章）", "正在確認兌換，請稍候…", "尚未確認兌換結果，請重試同一份兌換。", "贈品", "✓ {0}兌換已確認，已扣 {1} 章。兌換時間：{2}。請勿重複領取。", "完成", "連線失敗，請重試同一份兌換。", "重試確認這 1 份", "正在載入你的集章卡…", "請登入 LINE，讀取你的集章卡。", "正在前往雙創官方 LINE 加好友頁…", "我已加入，繼續集章", "集章點 0{0} 已保留，加入好友後即可繼續。", "加入好友後，即可繼續集章。", "正在確認並儲存印記…", "集章連線逾時，尚未確認結果，請重試。", "集章服務連線失敗，請確認網路後重試。", "集章連線失敗，請稍後重試。", "正在驗證身分並讀取雲端紀錄…", "LINE 登入憑證未通過驗證，請重新登入。", "重新登入 LINE", "✓ LINE 身分驗證成功，集章紀錄已從資料庫載入。", "重新整理集章紀錄", "{0} 原有紀錄已載入，本次站點保留供重試。", "重試取得印記", "已登入 LINE，但雲端紀錄載入失敗。請稍後重試；目前不顯示集章數量。", "暫時無法連接 LINE，請確認網路及測試員資格後重試。", "重新連線", "此環境無法開啟相機。請改用 LINE 掃描現場站點 QR，即可回到此頁集章。", "這不是本活動的集章 QR，請掃描集章點 01～06 的 QR。", "掃描未完成，請確認相機權限後重試。", " 已複製", " 請長按上方編號複製", "找不到參加者", "贈品不存在", "這項贈品尚未開放兌換"]'::jsonb ? v_key) or jsonb_typeof(v_value)<>'string' or length(trim(v_value#>>'{}'))=0 or length(v_value#>>'{}')>3000 then raise exception 'INVALID_TEXT'; end if;
   if (select array_agg(m order by m) from regexp_matches(v_key,'\{[0-9]+\}','g') m)
      is distinct from (select array_agg(m order by m) from regexp_matches(v_value#>>'{}','\{[0-9]+\}','g') m) then raise exception 'INVALID_TEXT'; end if;
 end loop;
 update public.stamp_site_copy set texts=p_texts,version=version+1,updated_by=p_actor,updated_at=now() where id=1 and version=p_version returning version into v_version;
 if not found then raise exception 'RECORD_CHANGED'; end if;
 return jsonb_build_object('version',v_version);
end; $$;
revoke all on function public.stamp_save_site_copy(uuid,integer,jsonb) from public,anon,authenticated;
grant execute on function public.stamp_save_site_copy(uuid,integer,jsonb) to service_role;
commit;
