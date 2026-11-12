-- 타격 명상 순위표: Supabase 프로젝트의 SQL Editor에 이 파일 전체를 붙여넣고 Run 하세요.
-- 점수는 아래 submit_zen_score 함수로만 쓸 수 있고, 각 기기가 처음 등록할 때 만든 비밀값을 알아야 자기 기록을
-- 고칠 수 있습니다(다른 사람이 내 기록을 덮어쓰지 못함). 누적 거리는 줄어들지 않습니다.

create table if not exists public.zen_scores (
  id uuid primary key,
  name text not null check (char_length(name) between 1 and 12),
  total bigint not null default 0 check (total >= 0 and total <= 100000000),
  updated_at timestamptz not null default now()
);
create table if not exists public.zen_secrets (
  id uuid primary key references public.zen_scores (id) on delete cascade,
  secret_hash text not null
);

alter table public.zen_scores enable row level security;
alter table public.zen_secrets enable row level security;   -- no policies: nobody reads or writes it directly

drop policy if exists "anyone can read the board" on public.zen_scores;
create policy "anyone can read the board" on public.zen_scores for select using (true);

create or replace function public.submit_zen_score(p_id uuid, p_secret text, p_name text, p_total bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  h text;
  s text;
begin
  if p_secret is null or char_length(p_secret) < 16 then raise exception 'bad secret'; end if;
  p_name := left(btrim(coalesce(p_name, '')), 12);
  if p_name = '' then raise exception 'bad name'; end if;
  p_total := greatest(0, least(coalesce(p_total, 0), 100000000));
  h := md5(p_secret);
  select secret_hash into s from zen_secrets where id = p_id;
  if s is null then
    insert into zen_scores (id, name, total) values (p_id, p_name, p_total);
    insert into zen_secrets (id, secret_hash) values (p_id, h);
  elsif s <> h then
    raise exception 'not yours';
  else
    update zen_scores set name = p_name, total = greatest(total, p_total), updated_at = now() where id = p_id;
  end if;
end;
$$;

revoke all on function public.submit_zen_score(uuid, text, text, bigint) from public;
grant execute on function public.submit_zen_score(uuid, text, text, bigint) to anon, authenticated;
