-- 023_add_savings_log_cancel_rpc.sql
-- 1억 챌린지 절약 기록 취소 기능을 추가합니다.
-- 목표:
-- 1. 사용자가 잘못 기록한 방문 절약액을 직접 취소할 수 있게 합니다.
-- 2. 로그를 물리 삭제하지 않고 취소 시각/사유를 남겨 운영 감사 추적을 보존합니다.
-- 3. 취소된 로그는 챌린지 요약, 월 절약액, 기록 횟수에서 제외합니다.

alter table public.savings_logs
add column if not exists cancelled_at timestamptz,
add column if not exists cancelled_reason text;

create index if not exists savings_logs_user_active_created_at_idx
on public.savings_logs (user_id, created_at desc)
where cancelled_at is null;

create or replace function public.cancel_saving_log(
  p_log_id uuid,
  p_reason text default 'user_cancelled'
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
  target_log public.savings_logs;
  next_current_savings bigint;
  next_goal_amount bigint;
  next_grade text;
begin
  if auth.uid() is null then
    raise exception '로그인한 사용자만 절약 기록을 취소할 수 있습니다.';
  end if;

  if p_log_id is null then
    raise exception '취소할 절약 기록을 선택해주세요.';
  end if;

  select *
  into target_log
  from public.savings_logs
  where id = p_log_id
  for update;

  if target_log.id is null then
    raise exception '취소할 절약 기록을 찾지 못했습니다.';
  end if;

  if target_log.user_id <> auth.uid() then
    raise exception '본인의 절약 기록만 취소할 수 있습니다.';
  end if;

  if target_log.cancelled_at is not null then
    raise exception '이미 취소된 절약 기록입니다.';
  end if;

  update public.savings_logs
  set
    cancelled_at = now(),
    cancelled_reason = coalesce(nullif(trim(p_reason), ''), 'user_cancelled')
  where id = target_log.id;

  insert into public.profiles (id, display_name)
  values (auth.uid(), '짠테커')
  on conflict (id) do nothing;

  update public.profiles
  set
    current_savings = greatest(current_savings - target_log.saved_amount, 0),
    challenge_grade = public.get_user_challenge_grade(greatest(current_savings - target_log.saved_amount, 0)),
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

grant execute on function public.cancel_saving_log(uuid, text) to authenticated;

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
        and cancelled_at is null
        and created_at >= date_trunc('month', now())
    ), 0)::bigint,
    coalesce((
      select count(*)
      from public.savings_logs
      where user_id = auth.uid()
        and cancelled_at is null
    ), 0)::bigint;
end;
$$;

grant execute on function public.get_challenge_summary() to authenticated;

-- 실행 후 확인용 SQL:
-- select proname, pronargs
-- from pg_proc
-- where proname in ('cancel_saving_log', 'get_challenge_summary')
-- order by proname;
--
-- select id, place_name, menu_name, saved_amount, cancelled_at, cancelled_reason
-- from public.savings_logs
-- order by created_at desc
-- limit 10;
