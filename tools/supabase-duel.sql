-- 친구 대결 (1대1, 제한시간 동안 누적 비거리). 여러 번 실행해도 됩니다.
-- 방은 6자리 코드로 만들고, 각 참가자는 자기 기기에서 만든 비밀값(token)으로만 자기 점수를 올립니다.
create table if not exists public.zen_duels (
  code text primary key,
  created_at timestamptz not null default now(),
  duration_s int not null check (duration_s between 30 and 1800),
  seed int not null,
  start_at timestamptz,
  round int not null default 1,
  host_name text not null,
  host_tok text not null,
  guest_name text,
  guest_tok text,
  host_total int not null default 0,
  guest_total int not null default 0
);
alter table public.zen_duels enable row level security;   -- no policies: only through the functions below

create or replace function public.duel_view(d public.zen_duels, p_role text)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object('code', d.code, 'duration', d.duration_s, 'seed', d.seed, 'round', d.round, 'start_at', d.start_at, 'now', now(),
    'host', d.host_name, 'guest', d.guest_name, 'host_total', d.host_total, 'guest_total', d.guest_total, 'role', p_role,
    'state', case when d.guest_name is null then 'waiting' when d.start_at is null then 'ready'
                  when now() < d.start_at + make_interval(secs => d.duration_s) then 'playing' else 'done' end)
$$;
revoke all on function public.duel_view(public.zen_duels, text) from public, anon, authenticated;

create or replace function public.duel_role(d public.zen_duels, p_tok text)
returns text language sql immutable as $$
  select case when p_tok is null then null when d.host_tok = md5(p_tok) then 'host' when d.guest_tok = md5(p_tok) then 'guest' end
$$;
revoke all on function public.duel_role(public.zen_duels, text) from public, anon, authenticated;

create or replace function public.duel_create(p_name text, p_secs int, p_tok text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n text := left(btrim(coalesce(p_name, '')), 12); c text; d zen_duels;
begin
  if n = '' or not zen_name_ok(n) then return jsonb_build_object('error', 'bad name'); end if;
  if p_tok is null or char_length(p_tok) < 16 then return jsonb_build_object('error', 'bad token'); end if;
  if p_secs is null or p_secs < 30 or p_secs > 1800 then return jsonb_build_object('error', 'bad time'); end if;
  delete from zen_duels where created_at < now() - interval '1 day';
  if (select count(*) from zen_duels where created_at > now() - interval '1 minute') >= 60 then return jsonb_build_object('error', 'busy'); end if;
  loop
    c := (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '') from generate_series(1, 6));
    exit when not exists (select 1 from zen_duels where code = c);
  end loop;
  insert into zen_duels (code, duration_s, seed, host_name, host_tok) values (c, p_secs, floor(random() * 2147483646)::int + 1, n, md5(p_tok)) returning * into d;
  return duel_view(d, 'host');
end;
$$;

create or replace function public.duel_join(p_code text, p_name text, p_tok text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n text := left(btrim(coalesce(p_name, '')), 12); d zen_duels; r text;
begin
  select * into d from zen_duels where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then return jsonb_build_object('error', 'no duel'); end if;
  r := duel_role(d, p_tok);
  if r is not null then return duel_view(d, r); end if;
  if d.guest_tok is not null then return jsonb_build_object('error', 'full'); end if;
  if p_tok is null or char_length(p_tok) < 16 then return jsonb_build_object('error', 'bad token'); end if;
  if n = '' or not zen_name_ok(n) then return jsonb_build_object('error', 'bad name'); end if;
  if lower(n) = lower(d.host_name) then return jsonb_build_object('error', 'same name'); end if;
  update zen_duels set guest_name = n, guest_tok = md5(p_tok) where code = d.code returning * into d;
  return duel_view(d, 'guest');
end;
$$;

create or replace function public.duel_state(p_code text, p_tok text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d zen_duels;
begin
  select * into d from zen_duels where code = upper(btrim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('error', 'no duel'); end if;
  return duel_view(d, duel_role(d, p_tok));
end;
$$;

-- start (or start again after a finished round): a 4 s countdown, fresh totals and pitch sequence
create or replace function public.duel_start(p_code text, p_tok text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d zen_duels; r text;
begin
  select * into d from zen_duels where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then return jsonb_build_object('error', 'no duel'); end if;
  r := duel_role(d, p_tok);
  if r is null then return jsonb_build_object('error', 'not yours'); end if;
  if d.guest_name is null then return jsonb_build_object('error', 'no guest'); end if;
  if d.start_at is not null and now() < d.start_at + make_interval(secs => d.duration_s) then return duel_view(d, r); end if;
  update zen_duels set start_at = now() + interval '4 seconds', host_total = 0, guest_total = 0,
    round = case when d.start_at is null then round else round + 1 end, seed = floor(random() * 2147483646)::int + 1
  where code = d.code returning * into d;
  return duel_view(d, r);
end;
$$;

-- your total during the round; only grows, only while the round runs, and only at real-play speed
create or replace function public.duel_score(p_code text, p_tok text, p_round int, p_total int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d zen_duels; r text; cap int;
begin
  select * into d from zen_duels where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then return jsonb_build_object('error', 'no duel'); end if;
  r := duel_role(d, p_tok);
  if r is null then return jsonb_build_object('error', 'not yours'); end if;
  if d.start_at is not null and p_round = d.round and now() >= d.start_at and now() <= d.start_at + make_interval(secs => d.duration_s + 4) then
    cap := ceil(40 * extract(epoch from now() - d.start_at))::int + 300;
    if r = 'host' then update zen_duels set host_total = greatest(host_total, least(greatest(0, p_total), cap)) where code = d.code returning * into d;
    else update zen_duels set guest_total = greatest(guest_total, least(greatest(0, p_total), cap)) where code = d.code returning * into d; end if;
  end if;
  return duel_view(d, r);
end;
$$;

do $$ declare f text; begin
  foreach f in array array['duel_create(text, int, text)', 'duel_join(text, text, text)', 'duel_state(text, text)', 'duel_start(text, text)', 'duel_score(text, text, int, int)'] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;
