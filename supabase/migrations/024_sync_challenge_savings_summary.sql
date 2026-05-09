-- 024_sync_challenge_savings_summary.sql
-- 1억 챌린지 누적 절약액 정합성을 자동 복구합니다.
-- 목표:
-- 1. profiles.current_savings가 실제 활성 savings_logs 합계와 어긋나도 자동으로 보정합니다.
-- 2. 취소된 로그(cancelled_at is not null)는 누적액, 월 절약액, 기록 수에서 제외합니다.
-- 3. 앱은 기존 get_challenge_summary RPC를 그대로 호출하면 됩니다.

create or replace function public.sync_challenge_savings(
  p_user_id uuid default auth.uid()
)
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
  target_user_id uuid;
  target_goal_amount bigint;
  recalculated_savings bigint;
  recalculated_monthly_savings bigint;
  recalculated_log_count bigint;
  recalculated_grade text;
begin
  if auth.uid() is null then
    raise exception '로그인한 사용자만 1억 챌린지를 동기화할 수 있습니다.';
  end if;

  target_user_id := coalesce(p_user_id, auth.uid());

  if target_user_id <> auth.uid() and not public.is_app_admin() then
    raise exception '본인의 1억 챌린지만 동기화할 수 있습니다.';
  end if;

  insert into public.profiles (id, display_name)
  values (target_user_id, '짠테커')
  on conflict (id) do nothing;

  select coalesce(sum(saved_amount), 0)::bigint
  into recalculated_savings
  from public.savings_logs
  where user_id = target_user_id
    and cancelled_at is null;

  select coalesce(sum(saved_amount), 0)::bigint
  into recalculated_monthly_savings
  from public.savings_logs
  where user_id = target_user_id
    and cancelled_at is null
    and created_at >= date_trunc('month', now());

  select count(*)::bigint
  into recalculated_log_count
  from public.savings_logs
  where user_id = target_user_id
    and cancelled_at is null;

  recalculated_grade := public.get_user_challenge_grade(recalculated_savings);

  update public.profiles
  set
    current_savings = recalculated_savings,
    challenge_grade = recalculated_grade,
    updated_at = now()
  where id = target_user_id
  returning profiles.goal_amount
  into target_goal_amount;

  return query
  select
    target_goal_amount,
    recalculated_savings,
    greatest(target_goal_amount - recalculated_savings, 0),
    case
      when target_goal_amount <= 0 then 0::numeric
      else round((recalculated_savings::numeric / target_goal_amount::numeric) * 100, 4)
    end,
    recalculated_grade,
    recalculated_monthly_savings,
    recalculated_log_count;
end;
$$;

grant execute on function public.sync_challenge_savings(uuid) to authenticated;

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
begin
  if auth.uid() is null then
    raise exception '로그인한 사용자만 1억 챌린지를 조회할 수 있습니다.';
  end if;

  return query
  select *
  from public.sync_challenge_savings(auth.uid());
end;
$$;

grant execute on function public.get_challenge_summary() to authenticated;

-- 실행 후 확인용 SQL:
-- select proname, pronargs
-- from pg_proc
-- where proname in ('sync_challenge_savings', 'get_challenge_summary')
-- order by proname, pronargs;
--
-- 앱에서 1억 챌린지 화면을 새로고침하면
-- profiles.current_savings가 활성 savings_logs 합계와 자동으로 맞춰져야 합니다.
