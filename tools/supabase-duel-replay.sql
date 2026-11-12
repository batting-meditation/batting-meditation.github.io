-- 친구 대결: 상대 타자 미니 리플레이용. 공마다 스윙 정보(몇 번째 공, 스윙 타이밍, 타구 결과)를 최근 4개까지 저장합니다.
-- supabase-duel.sql 다음에 실행. 여러 번 실행해도 됩니다.
alter table public.zen_duels add column if not exists host_ev jsonb not null default '[]';
alter table public.zen_duels add column if not exists guest_ev jsonb not null default '[]';

create or replace function public.duel_view(d public.zen_duels, p_role text)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object('code', d.code, 'duration', d.duration_s, 'seed', d.seed, 'round', d.round, 'start_at', d.start_at, 'now', now(),
    'host', d.host_name, 'guest', d.guest_name, 'host_total', d.host_total, 'guest_total', d.guest_total, 'role', p_role,
    'opp_ev', case p_role when 'host' then d.guest_ev when 'guest' then d.host_ev end,
    'state', case when d.guest_name is null then 'waiting' when d.start_at is null then 'ready'
                  when now() < d.start_at + make_interval(secs => d.duration_s) then 'playing' else 'done' end)
$$;
revoke all on function public.duel_view(public.zen_duels, text) from public, anon, authenticated;

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
  update zen_duels set start_at = now() + interval '4 seconds', host_total = 0, guest_total = 0, host_ev = '[]', guest_ev = '[]',
    round = case when d.start_at is null then round else round + 1 end, seed = floor(random() * 2147483646)::int + 1
  where code = d.code returning * into d;
  return duel_view(d, r);
end;
$$;

-- total (only grows, capped at real-play speed) plus, optionally, the swing on one pitch for the other player's replay
drop function if exists public.duel_score(text, text, int, int);
create or replace function public.duel_score(p_code text, p_tok text, p_round int, p_total int, p_ev jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d zen_duels; r text; cap int; ev jsonb := null;
begin
  select * into d from zen_duels where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then return jsonb_build_object('error', 'no duel'); end if;
  r := duel_role(d, p_tok);
  if r is null then return jsonb_build_object('error', 'not yours'); end if;
  if d.start_at is not null and p_round = d.round and now() >= d.start_at and now() <= d.start_at + make_interval(secs => d.duration_s + 4) then
    cap := ceil(40 * extract(epoch from now() - d.start_at))::int + 300;
    if p_ev is not null and jsonb_typeof(p_ev) = 'object' and char_length(p_ev::text) <= 300 then ev := jsonb_build_array(p_ev); end if;
    if r = 'host' then
      update zen_duels set host_total = greatest(host_total, least(greatest(0, p_total), cap)),
        host_ev = case when ev is null then host_ev else (case when jsonb_array_length(host_ev) >= 4 then host_ev - 0 else host_ev end) || ev end
      where code = d.code returning * into d;
    else
      update zen_duels set guest_total = greatest(guest_total, least(greatest(0, p_total), cap)),
        guest_ev = case when ev is null then guest_ev else (case when jsonb_array_length(guest_ev) >= 4 then guest_ev - 0 else guest_ev end) || ev end
      where code = d.code returning * into d;
    end if;
  end if;
  return duel_view(d, r);
end;
$$;
revoke all on function public.duel_score(text, text, int, int, jsonb) from public;
grant execute on function public.duel_score(text, text, int, int, jsonb) to anon, authenticated;
