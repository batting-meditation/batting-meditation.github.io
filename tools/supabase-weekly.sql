-- 타격 명상 주간 순위 + 명예의 전당. Supabase SQL Editor에 이 파일 전체를 붙여넣고 Run 하세요. (여러 번 실행해도 됩니다)
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

create or replace function public.submit_zen_week(p_id uuid, p_secret text, p_name text, p_week text, p_total bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  h text;
  s text;
  cur text := zen_week_key();
  prev text := zen_week_key(now() - interval '7 days');
begin
  if p_secret is null or char_length(p_secret) < 16 then raise exception 'bad secret'; end if;
  p_name := left(btrim(coalesce(p_name, '')), 12);
  if p_name = '' then raise exception 'bad name'; end if;
  if p_week is distinct from cur and p_week is distinct from prev then raise exception 'bad week'; end if;
  p_total := greatest(0, least(coalesce(p_total, 0), 100000000));
  h := md5(p_secret);
  select secret_hash into s from zen_players where id = p_id;
  if s is null then
    insert into zen_players (id, secret_hash) values (p_id, h);
  elsif s <> h then
    raise exception 'not yours';
  end if;
  insert into zen_weekly (week, id, name, total) values (p_week, p_id, p_name, p_total)
  on conflict (week, id) do update
    set name = excluded.name, total = greatest(zen_weekly.total, excluded.total), updated_at = now();
end;
$$;

revoke all on function public.submit_zen_week(uuid, text, text, text, bigint) from public;
grant execute on function public.submit_zen_week(uuid, text, text, text, bigint) to anon, authenticated;
