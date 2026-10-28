# 南島文化節管理後台設定

## 已完成與尚未完成
程式已準備；Supabase SQL、Edge Function 與管理員帳號仍需由專案管理者部署。GitHub Pages 上的登入畫面不代表後端已啟用。

## 1. 資料庫
在 Supabase SQL Editor 新增查詢，貼上 `supabase/migrations/202610280003_admin.sql` 全文並 Run。
此檔需要已完成兩份試吃的 redemption_no 欄位設定。它不刪除現有資料，新增固定參加者編號及管理稽核功能。結果應為「管理後台資料庫設定完成」。可重複執行。

## 2. 建立管理員登入帳號
在 Supabase Authentication → Users → Add user → Create new user，使用你要作為管理員的 Email 和密碼；完成 Email 確認（若建立畫面有 Auto Confirm，可啟用）。這是本活動後台帳號，不是要求你提供 Supabase 平台登入密碼。不要把密碼貼到聊天或 GitHub。

在 SQL Editor 執行下列內容，將 Email 替換為剛建立的帳號。只會授權該 Email 對應的 Auth 使用者；不是讓所有登入者成為管理員。

```sql
insert into public.stamp_admins(user_id, active)
select id, true from auth.users
where lower(email) = lower('請替換成管理員Email')
on conflict(user_id) do update set active = true
returning user_id, active;
```
必須回傳 1 列 active=true；0 列代表找不到這個 Email，先確認帳號已建立。若要撤銷權限，於資料庫將對應 user_id 的 active 改為 false。

## 3. 部署管理 API
Edge Functions → Deploy a new function → Via Editor。函式名稱 `stamp-admin`，以 `supabase/functions/stamp-admin/index.js` 全文取代預設程式並部署。
Settings 關閉 Verify JWT with legacy secret 並儲存。程式會用 Supabase Auth 驗證權杖，再查詢管理員名單；關閉此開關並不代表後台允許匿名存取。
使用 Supabase 提供的 SUPABASE_URL、SUPABASE_ANON_KEY、SUPABASE_SERVICE_ROLE_KEY 環境變數。不得把 service role key 放入 HTML、JavaScript 或對話。

## 4. 更新民眾 API
開啟現有 `stamp-redeem` 的 Code，將 `supabase/functions/stamp-redeem/index.js` 最新版本貼上重新部署。原本 legacy JWT 關閉設定保留。
完成後，民眾重新開啟集章頁，即可看到固定的 A000001 格式編號與複製按鈕。既有帳號會分配編號；不承諾舊帳號的編號按註冊先後排序。資料重設不會改變編號。
站點名稱現在也從資料庫讀取。

## 5. 管理後台入口
https://sc1150401.github.io/austronesian-stamp/admin.html

使用第 2 步建立的 Email 和密碼登入。頁面不保存密碼或登入權杖到 localStorage；關閉或重新整理後需再次登入。登入逾時亦需重新登入。

## 使用與統計定義
- 總參加人數＝目前參加者表中的帳號數；有集章＝至少 1 章；滿 3 章＝至少 3 章；完成＝6 章。
- 集滿率＝6 章人數 / 總參加人數，包含 0 章帳號作為分母。
- 0–6 章分布為互斥級別，每人計一次；兌換不會扣除章數。
- 同人同商家換 2 份，商家統計為 1 人 / 2 份。
- 日期以 Asia/Taipei 計算，新增參加者為首次建立帳號；無瀏覽/點擊/每日登入追蹤。
- 重設刪除指定集章/兌換資料，因此目前統計和歷史日期統計也會減少。操作稽核保留修改前後明細。
- 參加者匯出採游標分頁，不受單次 1000 列限制；匯出進行中如有變更，跨頁結果不保證同一時間快照。
- 操作紀錄頁及其匯出顯示最近 100 筆，較早紀錄保留於資料庫。
- 此版本沒有全活動一鍵刪除、未經授權的直接資料表存取，也不會顯示 LINE 身分識別碼、電話或暱稱。

## 重設
查詢編號 → 重設紀錄 → 選範圍 → 填原因 → 再次輸入同一編號 → 確認。
如果紀錄在確認前已變動，系統會要求重新查詢。相同請求重試不會再次刪除後來新增的印記。
清除兌換後將重新取得可兌換資格，僅在確認應重設時操作。

## 驗證
本機資料庫測試涵蓋遷移重跑、權限拒絕、0–6 章分布、同商家兩份、台灣日期、指定帳號隔離重設、稽核、過期畫面拒絕、重送保護及超過 1000 人的統計/匯出分頁。
API 模擬測試涵蓋未登入、無權限與偽造 actor 被拒；DOM 測試涵蓋編號、分布、文字注入及 CSV 公式防護。
尚需部署後實測：管理員登入、一般使用者被拒、手機版編號顯示、查詢、測試帳號重設、CSV 下載與活動設定修改。
