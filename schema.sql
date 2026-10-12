-- =====================================================================
-- Inner Lab｜心緒研究所 — Supabase 資料庫結構與 RLS 權限
-- 使用方式：Supabase Dashboard → SQL Editor → 貼上整份檔案執行一次。
-- 前置設定：Authentication → Sign In / Providers → 開啟「Allow anonymous sign-ins」。
-- 注意：本檔只建立公開漂流瓶、共鳴與檢舉。私人日記與草稿只存在使用者瀏覽器，不上傳。
-- =====================================================================

-- ---------- 1. 漂流瓶 ----------
create table if not exists public.bottles (
  id                uuid primary key default gen_random_uuid(),
  owner_id          uuid not null default auth.uid() references auth.users (id) on delete cascade,
  title             text not null check (char_length(btrim(title)) between 1 and 40),
  message           text not null check (char_length(btrim(message)) between 1 and 300),
  note              text not null default '' check (char_length(note) <= 60),
  mood              text not null check (mood in ('calm','happy','miss','loss','anxious','tired','hope','grateful','other')),
  scene             text not null check (scene in ('moonlit-ocean','dawn-sea','galaxy-sea','rainy-window','misty-coast','deep-cosmos')),
  design_json       jsonb not null default '{}'::jsonb check (pg_column_size(design_json) <= 60000 and jsonb_typeof(design_json) = 'object'),
  nickname          text not null default '匿名旅人' check (char_length(nickname) between 1 and 40),
  visibility        text not null default 'public' check (visibility in ('public','private')),
  moderation_status text not null default 'visible' check (moderation_status in ('visible','hidden','removed')),
  resonance_count   integer not null default 0,   -- 我也有過這種感覺（felt）
  read_count        integer not null default 0,   -- 我讀到了（read）
  wish_count        integer not null default 0,   -- 願你慢慢好起來（wish）
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
-- 舊版已建立的資料表補上新欄位（重複執行安全）
alter table public.bottles add column if not exists read_count integer not null default 0;
alter table public.bottles add column if not exists wish_count integer not null default 0;
create index if not exists bottles_public_idx on public.bottles (created_at desc) where visibility = 'public' and moderation_status = 'visible';
create index if not exists bottles_owner_idx on public.bottles (owner_id, created_at desc);

-- ---------- 2. 溫和回應：read 我讀到了／felt 我也有過這種感覺／wish 願你慢慢好起來 ----------
-- 只有這三種固定回應，沒有留言、聊天或私訊
create table if not exists public.reactions (
  id            uuid primary key default gen_random_uuid(),
  bottle_id     uuid not null references public.bottles (id) on delete cascade,
  owner_id      uuid not null default auth.uid() references auth.users (id) on delete cascade,
  reaction_type text not null default 'felt' check (reaction_type in ('read','felt','wish')),
  created_at    timestamptz not null default now(),
  unique (bottle_id, owner_id, reaction_type)   -- 同一人對同一作品只能有一次相同反應
);
-- 舊版資料表的檢查條件換成三種回應（重複執行安全）
alter table public.reactions drop constraint if exists reactions_reaction_type_check;
alter table public.reactions add constraint reactions_reaction_type_check check (reaction_type in ('read','felt','wish'));

-- ---------- 3. 檢舉 ----------
create table if not exists public.reports (
  id          uuid primary key default gen_random_uuid(),
  bottle_id   uuid not null references public.bottles (id) on delete cascade,
  reporter_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  reason      text not null check (reason in ('spam','harass','privacy','danger','other')),
  details     text not null default '' check (char_length(details) <= 300),
  status      text not null default 'open' check (status in ('open','reviewed','dismissed')),
  created_at  timestamptz not null default now(),
  unique (bottle_id, reporter_id)
);

-- ---------- 4. 觸發器：伺服器端的頻率限制、計數與自動隱藏 ----------
-- 發布頻率限制：每個身分 10 分鐘內最多 3 個、24 小時內最多 20 個
create or replace function public.bottles_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.owner_id := auth.uid();
  if new.owner_id is null then raise exception 'not_authenticated'; end if;
  new.moderation_status := 'visible';
  new.resonance_count := 0;
  new.read_count := 0;
  new.wish_count := 0;
  new.created_at := now();
  new.updated_at := now();
  if (select count(*) from public.bottles where owner_id = new.owner_id and created_at > now() - interval '10 minutes') >= 3
     or (select count(*) from public.bottles where owner_id = new.owner_id and created_at > now() - interval '24 hours') >= 20 then
    raise exception 'rate_limited' using errcode = 'P0001', hint = 'rate_limit';
  end if;
  return new;
end $$;
drop trigger if exists bottles_before_insert on public.bottles;
create trigger bottles_before_insert before insert on public.bottles for each row execute function public.bottles_before_insert();

create or replace function public.bottles_before_update()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists bottles_before_update on public.bottles;
create trigger bottles_before_update before update on public.bottles for each row execute function public.bottles_before_update();

-- 三種回應的計數：由觸發器維護，使用者無法直接修改
create or replace function public.reactions_count()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  r public.reactions;
  d integer;
begin
  if tg_op = 'INSERT' then r := new; d := 1; else r := old; d := -1; end if;
  if r.reaction_type = 'felt' then
    update public.bottles set resonance_count = greatest(resonance_count + d, 0) where id = r.bottle_id;
  elsif r.reaction_type = 'read' then
    update public.bottles set read_count = greatest(read_count + d, 0) where id = r.bottle_id;
  elsif r.reaction_type = 'wish' then
    update public.bottles set wish_count = greatest(wish_count + d, 0) where id = r.bottle_id;
  end if;
  return null;
end $$;
drop trigger if exists reactions_count on public.reactions;
create trigger reactions_count after insert or delete on public.reactions for each row execute function public.reactions_count();

-- 被 3 個不同身分檢舉的作品先自動隱藏，等待管理者處理
create or replace function public.reports_auto_hide()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(distinct reporter_id) from public.reports where bottle_id = new.bottle_id and status = 'open') >= 3 then
    update public.bottles set moderation_status = 'hidden' where id = new.bottle_id and moderation_status = 'visible';
  end if;
  return null;
end $$;
drop trigger if exists reports_auto_hide on public.reports;
create trigger reports_auto_hide after insert on public.reports for each row execute function public.reports_auto_hide();

-- ---------- 5. Row Level Security ----------
alter table public.bottles   enable row level security;
alter table public.reactions enable row level security;
alter table public.reports   enable row level security;

-- 欄位層級權限：一般使用者只能寫入內容欄位，不能改 owner、審核狀態或計數
revoke all on public.bottles, public.reactions, public.reports from anon, authenticated;
grant select on public.bottles to anon, authenticated;
grant insert (title, message, note, mood, scene, design_json, nickname, visibility) on public.bottles to authenticated;
grant update (title, message, note, mood, visibility) on public.bottles to authenticated;
grant delete on public.bottles to authenticated;
grant select, insert, delete on public.reactions to authenticated;
grant insert (bottle_id, reason, details) on public.reports to authenticated;

-- bottles：公開且未被隱藏的作品所有人可讀；擁有者可讀自己的全部作品
drop policy if exists bottles_read_public on public.bottles;
create policy bottles_read_public on public.bottles for select to anon, authenticated
  using ((visibility = 'public' and moderation_status = 'visible') or owner_id = auth.uid());
drop policy if exists bottles_insert_own on public.bottles;
create policy bottles_insert_own on public.bottles for insert to authenticated
  with check (owner_id = auth.uid());
drop policy if exists bottles_update_own on public.bottles;
create policy bottles_update_own on public.bottles for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists bottles_delete_own on public.bottles;
create policy bottles_delete_own on public.bottles for delete to authenticated
  using (owner_id = auth.uid());

-- reactions：只能看到、新增、刪除自己的反應，且只能對公開作品反應
drop policy if exists reactions_read_own on public.reactions;
create policy reactions_read_own on public.reactions for select to authenticated using (owner_id = auth.uid());
drop policy if exists reactions_insert_own on public.reactions;
create policy reactions_insert_own on public.reactions for insert to authenticated
  with check (owner_id = auth.uid() and exists (select 1 from public.bottles b where b.id = bottle_id and b.visibility = 'public' and b.moderation_status = 'visible'));
drop policy if exists reactions_delete_own on public.reactions;
create policy reactions_delete_own on public.reactions for delete to authenticated using (owner_id = auth.uid());

-- reports：只能新增；一般訪客（包含檢舉人）都不能讀取檢舉紀錄，只有管理者在 Dashboard 或 service_role 後端處理
drop policy if exists reports_insert on public.reports;
create policy reports_insert on public.reports for insert to authenticated
  with check (reporter_id = auth.uid() and exists (select 1 from public.bottles b where b.id = bottle_id and b.visibility = 'public'));

-- ---------- 6. 前端讀取用的檢視表（不暴露 owner_id） ----------
drop view if exists public.public_bottles;
create view public.public_bottles with (security_invoker = true) as
  select b.id, b.title, b.message, b.note, b.mood, b.scene, b.design_json, b.nickname,
         b.resonance_count, b.read_count, b.wish_count, b.created_at,
         (b.owner_id = auth.uid()) as is_mine,
         coalesce((select array_agg(r.reaction_type order by r.reaction_type) from public.reactions r
                   where r.bottle_id = b.id and r.owner_id = auth.uid()), '{}'::text[]) as my_reactions
  from public.bottles b
  where b.visibility = 'public' and b.moderation_status = 'visible';
grant select on public.public_bottles to anon, authenticated;

-- ---------- 7. 管理者常用查詢（在 SQL Editor 以管理者身分執行，不要放進前端） ----------
-- 查看待處理檢舉：
--   select r.*, b.title, b.message from public.reports r join public.bottles b on b.id = r.bottle_id where r.status = 'open' order by r.created_at desc;
-- 隱藏作品：   update public.bottles set moderation_status = 'hidden' where id = '<bottle id>';
-- 恢復作品：   update public.bottles set moderation_status = 'visible' where id = '<bottle id>';
-- 結案檢舉：   update public.reports set status = 'reviewed' where bottle_id = '<bottle id>';
