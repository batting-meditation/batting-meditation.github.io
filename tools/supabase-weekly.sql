-- 타격 명상 주간 순위 + 명예의 전당 + 닉네임/비밀번호 + 의견 보내기.
-- Supabase SQL Editor에 이 파일 전체를 붙여넣고 Run 하세요. 여러 번 실행해도 되고, 예전 버전을 실행한 뒤에 다시 실행해도 됩니다.
-- 주는 한국 시간 월요일 0시에 바뀝니다. 기록은 각 기기가 처음 올릴 때 만든 비밀값으로만 고칠 수 있고, 한 주의 누적은 줄어들지 않습니다.

create table if not exists public.zen_players (
  id uuid primary key,
  secret_hash text not null,
  created_at timestamptz not null default now()
);
alter table public.zen_players enable row level security;   -- no policies: nobody reads or writes it directly

create table if not exists public.zen_weekly (
  week text not null,                                          -- e.g. 2026-W46 (ISO week, Korea time)
  id uuid not null references public.zen_players (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 12),
  total bigint not null default 0 check (total >= 0 and total <= 100000000),
  updated_at timestamptz not null default now(),
  primary key (week, id)
);
alter table public.zen_weekly enable row level security;
drop policy if exists "anyone can read the weekly board" on public.zen_weekly;
create policy "anyone can read the weekly board" on public.zen_weekly for select using (true);

create or replace function public.zen_week_key(ts timestamptz default now())
returns text language sql stable as $$ select to_char(ts at time zone 'Asia/Seoul', 'IYYY"-W"IW') $$;

-- hall of fame: the top player of every finished week
create or replace view public.zen_hall with (security_invoker = true) as
  select distinct on (week) week, name, total
  from public.zen_weekly
  where week < public.zen_week_key()
  order by week desc, total desc, updated_at asc;
grant select on public.zen_hall to anon, authenticated;

-- players own a nickname (unique, case-insensitive) and a 4~6 digit PIN; every browser that logged in with them
-- gets its own device secret, so the same record continues anywhere
create extension if not exists pgcrypto with schema extensions;
alter table public.zen_players add column if not exists name text;
alter table public.zen_players add column if not exists pin_hash text;
alter table public.zen_players add column if not exists fails int not null default 0;
alter table public.zen_players add column if not exists locked_until timestamptz;
create unique index if not exists zen_players_name_key on public.zen_players (lower(name));
create table if not exists public.zen_devices (
  player uuid not null references public.zen_players (id) on delete cascade,
  secret_hash text not null,
  created_at timestamptz not null default now(),
  primary key (player, secret_hash)
);
alter table public.zen_devices enable row level security;   -- no policies

create or replace function public.zen_device_ok(p_id uuid, p_secret text)
returns boolean language sql stable security definer set search_path = public as $$
  select p_secret is not null and char_length(p_secret) >= 16 and (
    exists (select 1 from zen_players where id = p_id and secret_hash = md5(p_secret)) or
    exists (select 1 from zen_devices where player = p_id and secret_hash = md5(p_secret)))
$$;
revoke all on function public.zen_device_ok(uuid, text) from public, anon, authenticated;

-- set or change this device's nickname (and PIN). New players need a PIN.
create or replace function public.zen_claim(p_id uuid, p_secret text, p_name text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  n text := left(btrim(coalesce(p_name, '')), 12);
  pl zen_players;
  has boolean;
begin
  if p_secret is null or char_length(p_secret) < 16 then return jsonb_build_object('error', 'bad secret'); end if;
  if n = '' then return jsonb_build_object('error', 'bad name'); end if;
  if p_pin is not null and p_pin !~ '^[0-9]{4,6}$' then return jsonb_build_object('error', 'bad pin'); end if;
  select * into pl from zen_players where id = p_id;
  has := found;
  if has and not zen_device_ok(p_id, p_secret) then return jsonb_build_object('error', 'not yours'); end if;
  if exists (select 1 from zen_players where lower(name) = lower(n) and id <> p_id) then return jsonb_build_object('error', 'name taken'); end if;
  if not has then
    if p_pin is null then return jsonb_build_object('error', 'need pin'); end if;
    insert into zen_players (id, secret_hash, name, pin_hash) values (p_id, md5(p_secret), n, crypt(p_pin, gen_salt('bf')));
  else
    if pl.pin_hash is null and p_pin is null then return jsonb_build_object('error', 'need pin'); end if;
    update zen_players set name = n, pin_hash = case when p_pin is null then pin_hash else crypt(p_pin, gen_salt('bf')) end where id = p_id;
    update zen_weekly set name = n where id = p_id and week = zen_week_key();
  end if;
  return jsonb_build_object('ok', true, 'name', n);
end;
$$;

-- continue a nickname on this browser: right PIN -> this browser's new secret is added to that player
create or replace function public.zen_login(p_name text, p_pin text, p_new_secret text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pl zen_players;
begin
  if p_new_secret is null or char_length(p_new_secret) < 16 then return jsonb_build_object('error', 'bad secret'); end if;
  select * into pl from zen_players where lower(name) = lower(btrim(coalesce(p_name, '')));
  if not found or pl.pin_hash is null then return jsonb_build_object('error', 'no such name'); end if;
  if pl.locked_until is not null and pl.locked_until > now() then return jsonb_build_object('error', 'locked'); end if;
  if crypt(coalesce(p_pin, ''), pl.pin_hash) <> pl.pin_hash then
    update zen_players set fails = case when fails + 1 >= 5 then 0 else fails + 1 end,
      locked_until = case when fails + 1 >= 5 then now() + interval '10 minutes' else locked_until end where id = pl.id;
    return jsonb_build_object('error', 'wrong pin');
  end if;
  update zen_players set fails = 0, locked_until = null where id = pl.id;
  insert into zen_devices (player, secret_hash) values (pl.id, md5(p_new_secret)) on conflict do nothing;
  return jsonb_build_object('ok', true, 'id', pl.id, 'name', pl.name);
end;
$$;

revoke all on function public.zen_claim(uuid, text, text, text) from public;
grant execute on function public.zen_claim(uuid, text, text, text) to anon, authenticated;
revoke all on function public.zen_login(text, text, text) from public;
grant execute on function public.zen_login(text, text, text) to anon, authenticated;

-- weekly total: only from a logged-in device of a player with a nickname; the nickname comes from the player
create or replace function public.submit_zen_week(p_id uuid, p_secret text, p_name text, p_week text, p_total bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  nm text;
  cur text := zen_week_key();
  prev text := zen_week_key(now() - interval '7 days');
begin
  if not zen_device_ok(p_id, p_secret) then raise exception 'not yours'; end if;
  select name into nm from zen_players where id = p_id;
  if nm is null then raise exception 'no name'; end if;
  if p_week is distinct from cur and p_week is distinct from prev then raise exception 'bad week'; end if;
  p_total := greatest(0, least(coalesce(p_total, 0), 100000000));
  insert into zen_weekly (week, id, name, total) values (p_week, p_id, nm, p_total)
  on conflict (week, id) do update
    set name = excluded.name, total = greatest(zen_weekly.total, excluded.total), updated_at = now();
end;
$$;

revoke all on function public.submit_zen_week(uuid, text, text, text, bigint) from public;
grant execute on function public.submit_zen_week(uuid, text, text, text, bigint) to anon, authenticated;

-- 의견 보내기: anyone can send, nobody can read through the app (read it in the Table Editor: feedback)
create table if not exists public.feedback (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  kind text not null check (kind in ('요구사항', '불만', '오류', '기타')),
  message text not null check (char_length(message) between 1 and 2000),
  page text check (char_length(page) <= 40),
  nickname text check (char_length(nickname) <= 12),
  ua text check (char_length(ua) <= 400)
);
alter table public.feedback enable row level security;
drop policy if exists "anyone can send feedback" on public.feedback;
create policy "anyone can send feedback" on public.feedback for insert to anon, authenticated with check (true);
grant insert on public.feedback to anon, authenticated;
