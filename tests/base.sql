begin;

-- 參加者：LINE ID 必須由後端驗證後寫入
create table if not exists public.stamp_participants (
  id uuid primary key default gen_random_uuid(),
  line_user_id text not null unique,
  created_at timestamptz not null default now()
);

-- 六個集章點，正式掃碼設定完成前先關閉
create table if not exists public.stamp_stations (
  id smallint primary key check (id between 1 and 6),
  name text not null,
  active boolean not null default false
);

-- 六家試吃商家
create table if not exists public.stamp_vendors (
  id smallint primary key check (id between 1 and 6),
  name text not null,
  active boolean not null default false
);

-- 同一人同一站只能集一次
create table if not exists public.stamp_records (
  participant_id uuid not null
    references public.stamp_participants(id),
  station_id smallint not null
    references public.stamp_stations(id),
  collected_at timestamptz not null default now(),
  primary key (participant_id, station_id)
);

-- 同一人整場活動只能兌換一次
create table if not exists public.stamp_redemptions (
  id uuid primary key default gen_random_uuid(),
  participant_id uuid not null unique
    references public.stamp_participants(id),
  vendor_id smallint not null
    references public.stamp_vendors(id),
  redeemed_by text not null,
  redeemed_at timestamptz not null default now()
);

insert into public.stamp_stations (id, name)
select n, '集章點 0' || n
from generate_series(1, 6) as n
on conflict (id) do nothing;

insert into public.stamp_vendors (id, name)
select n, '試吃商家 0' || n || '（待公告）'
from generate_series(1, 6) as n
on conflict (id) do nothing;

alter table public.stamp_participants enable row level security;
alter table public.stamp_stations enable row level security;
alter table public.stamp_vendors enable row level security;
alter table public.stamp_records enable row level security;
alter table public.stamp_redemptions enable row level security;

-- 不開放瀏覽器直接讀寫，後續透過後端驗證身分
revoke all on table
  public.stamp_participants,
  public.stamp_stations,
  public.stamp_vendors,
  public.stamp_records,
  public.stamp_redemptions
from public, anon, authenticated;

grant select, insert, update, delete on table
  public.stamp_participants,
  public.stamp_stations,
  public.stamp_vendors,
  public.stamp_records,
  public.stamp_redemptions
to service_role;

commit;

select '資料表建立完成' as result;

