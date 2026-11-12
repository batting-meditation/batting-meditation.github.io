-- 공개 전 안전장치. supabase-weekly.sql을 실행한 뒤 이 파일 전체를 SQL Editor에 붙여넣고 Run 하세요. (여러 번 실행해도 됩니다)
--  1) 기록 조작 방지: 한 주 누적은 실제로 칠 수 있는 속도(초당 40m)보다 빨리 늘 수 없음
--  2) 욕설·사칭 닉네임 거부
--  3) 의견 보내기 도배 방지 (1분에 20개, 하루 500개)
--  4) 예전 순위표(zen_scores) 정리

-- 2) nickname filter: letters only, lower case, then look for blocked words
create or replace function public.zen_name_ok(p_name text)
returns boolean language sql immutable as $$
  select not exists (
    select 1 from unnest(array[
      '시발','씨발','씨바','씨빨','시빨','싀발','ㅅㅂ','ㅆㅂ','ㅅㅃ','병신','븅신','빙신','ㅂㅅ','좆','존나','졸라','지랄','ㅈㄹ','개새','새끼','섀끼','ㅅㄲ',
      '니미','느금','니애미','엠창','애미','애비','창녀','걸레','보지','자지','섹스','야동','강간','김치녀','메갈','일베','틀딱','급식충','장애인',
      '관리자','운영자','운영진','admin','administrator','moderator',
      'fuck','fuk','shit','bitch','sex','porn','nigger','nigga','dick','pussy','cunt','rape','nazi','hitler'
    ]) w
    where regexp_replace(lower(coalesce(p_name, '')), '[^a-z가-힣ㄱ-ㅎㅏ-ㅣ]', '', 'g') like '%' || w || '%'
  )
$$;

create or replace function public.zen_claim(p_id uuid, p_secret text, p_name text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  n text := left(btrim(coalesce(p_name, '')), 12);
  pl zen_players;
  has boolean;
begin
  if p_secret is null or char_length(p_secret) < 16 then return jsonb_build_object('error', 'bad secret'); end if;
  if n = '' then return jsonb_build_object('error', 'bad name'); end if;
  if not zen_name_ok(n) then return jsonb_build_object('error', 'bad word'); end if;
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

-- 1) weekly total can only grow as fast as real play allows (about one pitch every 5 s, under 150 m each)
create or replace function public.submit_zen_week(p_id uuid, p_secret text, p_name text, p_week text, p_total bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  nm text;
  born timestamptz;
  cur text := zen_week_key();
  prev text := zen_week_key(now() - interval '7 days');
  old_total bigint;
  old_at timestamptz;
  since timestamptz;
  allowed bigint;
begin
  if not zen_device_ok(p_id, p_secret) then raise exception 'not yours'; end if;
  select name, created_at into nm, born from zen_players where id = p_id;
  if nm is null then raise exception 'no name'; end if;
  if p_week is distinct from cur and p_week is distinct from prev then raise exception 'bad week'; end if;
  p_total := greatest(0, least(coalesce(p_total, 0), 100000000));
  select total, updated_at into old_total, old_at from zen_weekly where week = p_week and id = p_id;
  if found then
    allowed := old_total + ceil(40 * greatest(0, extract(epoch from now() - old_at))) + 300;
  else
    since := greatest((to_date(p_week, 'IYYY"-W"IW')::timestamp at time zone 'Asia/Seoul'), coalesce(born, now()));
    allowed := ceil(40 * greatest(0, extract(epoch from now() - since))) + 300;
  end if;
  p_total := least(p_total, allowed);
  insert into zen_weekly (week, id, name, total) values (p_week, p_id, nm, p_total)
  on conflict (week, id) do update
    set name = excluded.name, total = greatest(zen_weekly.total, excluded.total), updated_at = now();
end;
$$;

-- 3) feedback flood guard
create or replace function public.feedback_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from feedback where created_at > now() - interval '1 minute') >= 20
     or (select count(*) from feedback where created_at > now() - interval '1 day') >= 500 then
    raise exception 'too many';
  end if;
  return new;
end;
$$;
drop trigger if exists feedback_guard on public.feedback;
create trigger feedback_guard before insert on public.feedback for each row execute function public.feedback_guard();

-- 4) the old leaderboard is no longer used
drop function if exists public.submit_zen_score(uuid, text, text, bigint);
drop table if exists public.zen_secrets;
drop table if exists public.zen_scores;
