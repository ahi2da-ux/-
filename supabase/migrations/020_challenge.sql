-- 020_challenge.sql
-- 1억 챌린지의 최소 데이터 기반을 추가합니다.
-- 목표:
-- 1. 사용자 프로필에 목표 금액, 누적 절약액, 챌린지 등급을 저장합니다.
-- 2. 사용자의 방문 절약 기록을 savings_logs에 남깁니다.
-- 3. 앱은 RPC로 절약 기록과 챌린지 요약을 안전하게 처리합니다.

alter table public.profiles
add column if not exists goal_amount bigint not null default 100000000 check (goal_amount > 0),
add column if not exists current_savings bigint not null default 0 check (current_savings >= 0),
add column if not exists challenge_grade text not null default '흙수저';

create table if not exists public.savings_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  place_id uuid references public.places(id) on delete set null,
  menu_id uuid references public.menus(id) on delete set null,
  place_name text,
  menu_name text,
  saved_amount bigint not null check (saved_amount > 0),
  original_price bigint,
  actual_price bigint,
  category text not null,
  source text not null default 'visit',
  created_at timestamptz not null default now()
);

create index if not exists savings_logs_user_created_at_idx
on public.savings_logs (user_id, created_at desc);

create index if not exists savings_logs_category_idx
on public.savings_logs (category);

create index if not exists savings_logs_place_id_idx
on public.savings_logs (place_id);

create index if not exists savings_logs_menu_id_idx
on public.savings_logs (menu_id);

alter table public.savings_logs enable row level security;

drop policy if exists "savings_logs_self_read" on public.savings_logs;
drop policy if exists "savings_logs_self_insert" on public.savings_logs;
drop policy if exists "savings_logs_admin_read" on public.savings_logs;

create policy "savings_logs_self_read"
on public.savings_logs
for select
to authenticated
using (auth.uid() = user_id);

create policy "savings_logs_self_insert"
on public.savings_logs
for insert
to authenticated
with check (
  auth.uid() = user_id
  and saved_amount > 0
);

create policy "savings_logs_admin_read"
on public.savings_logs
for select
to authenticated
using (public.is_app_admin());

create or replace function public.get_user_challenge_grade(
  p_savings bigint
)
returns text
language sql
stable
as $$
  select case
    when coalesce(p_savings, 0) >= 100000000 then '1억 달성자'
    when coalesce(p_savings, 0) >= 50000000 then '헬조선 생존자'
    when coalesce(p_savings, 0) >= 10000000 then '재테크 고수'
    when coalesce(p_savings, 0) >= 1000000 then '절약러'
    when coalesce(p_savings, 0) >= 100000 then '짠돌이'
    else '흙수저'
  end;
$$;

create or replace function public.log_saving(
  p_place_id uuid,
  p_menu_id uuid default null,
  p_place_name text default null,
  p_menu_name text default null,
  p_saved_amount bigint default 0,
  p_original_price bigint default null,
  p_actual_price bigint default null,
  p_category text default 'food',
  p_source text default 'visit'
)
returns table (
  goal_amount bigint,
  current_savings bigint,
  remaining_amount bigint,
  progress_rate numeric,
  challenge_grade text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  next_current_savings bigint;
  next_goal_amount bigint;
  next_grade text;
begin
  if auth.uid() is null then
    raise exception '로그인한 사용자만 절약액을 기록할 수 있습니다.';
  end if;

  if p_saved_amount is null or p_saved_amount <= 0 then
    raise exception '절약액은 1원 이상이어야 합니다.';
  end if;

  insert into public.profiles (id, display_name)
  values (auth.uid(), '짠테커')
  on conflict (id) do nothing;

  insert into public.savings_logs (
    user_id,
    place_id,
    menu_id,
    place_name,
    menu_name,
    saved_amount,
    original_price,
    actual_price,
    category,
    source
  ) values (
    auth.uid(),
    p_place_id,
    p_menu_id,
    nullif(trim(coalesce(p_place_name, '')), ''),
    nullif(trim(coalesce(p_menu_name, '')), ''),
    p_saved_amount,
    p_original_price,
    p_actual_price,
    nullif(trim(coalesce(p_category, '')), ''),
    coalesce(nullif(trim(p_source), ''), 'visit')
  );

  update public.profiles
  set
    current_savings = current_savings + p_saved_amount,
    challenge_grade = public.get_user_challenge_grade(current_savings + p_saved_amount),
    updated_at = now()
  where id = auth.uid()
  returning profiles.current_savings, profiles.goal_amount, profiles.challenge_grade
  into next_current_savings, next_goal_amount, next_grade;

  return query
  select
    next_goal_amount,
    next_current_savings,
    greatest(next_goal_amount - next_current_savings, 0),
    case
      when next_goal_amount <= 0 then 0::numeric
      else round((next_current_savings::numeric / next_goal_amount::numeric) * 100, 4)
    end,
    next_grade;
end;
$$;

grant execute on function public.log_saving(uuid, uuid, text, text, bigint, bigint, bigint, text, text) to authenticated;

create or replace function public.get_challenge_summary()
returns table (
  goal_amount bigint,
  current_savings bigint,
  remaining_amount bigint,
  progress_rate numeric,
  challenge_grade text,
  monthly_savings bigint,
  log_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  target_profile public.profiles;
begin
  if auth.uid() is null then
    raise exception '로그인한 사용자만 1억 챌린지를 조회할 수 있습니다.';
  end if;

  insert into public.profiles (id, display_name)
  values (auth.uid(), '짠테커')
  on conflict (id) do nothing;

  select *
  into target_profile
  from public.profiles
  where id = auth.uid();

  return query
  select
    target_profile.goal_amount,
    target_profile.current_savings,
    greatest(target_profile.goal_amount - target_profile.current_savings, 0),
    case
      when target_profile.goal_amount <= 0 then 0::numeric
      else round((target_profile.current_savings::numeric / target_profile.goal_amount::numeric) * 100, 4)
    end,
    target_profile.challenge_grade,
    coalesce((
      select sum(saved_amount)
      from public.savings_logs
      where user_id = auth.uid()
        and created_at >= date_trunc('month', now())
    ), 0)::bigint,
    coalesce((
      select count(*)
      from public.savings_logs
      where user_id = auth.uid()
    ), 0)::bigint;
end;
$$;

grant execute on function public.get_challenge_summary() to authenticated;

-- 검증 예시:
-- select public.get_user_challenge_grade(100000);
-- select * from public.get_challenge_summary();
-- select * from public.log_saving(
--   '여기에-places-id',
--   null,
--   '합정 칼국수',
--   '손칼국수',
--   5000,
--   12000,
--   7000,
--   'food',
--   'visit'
-- );
