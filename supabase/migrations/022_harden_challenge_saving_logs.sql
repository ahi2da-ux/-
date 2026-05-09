-- 022_harden_challenge_saving_logs.sql
-- 1억 챌린지 절약 기록의 운영 안정성을 강화합니다.
-- 목표:
-- 1. 같은 사용자가 같은 장소/메뉴를 짧은 시간에 반복 기록해 절약액을 부풀리는 문제를 막습니다.
-- 2. 버튼 연타처럼 거의 동시에 들어오는 요청도 트랜잭션 잠금으로 한 번씩만 처리합니다.
-- 3. 기존 앱 호출 방식은 유지하고 log_saving RPC 내부 로직만 안전하게 교체합니다.

create index if not exists savings_logs_user_place_menu_source_created_at_idx
on public.savings_logs (user_id, place_id, menu_id, source, created_at desc);

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
  normalized_source text;
  duplicate_exists boolean;
begin
  if auth.uid() is null then
    raise exception '로그인한 사용자만 절약액을 기록할 수 있습니다.';
  end if;

  if p_saved_amount is null or p_saved_amount <= 0 then
    raise exception '절약액은 1원 이상이어야 합니다.';
  end if;

  normalized_source := coalesce(nullif(trim(p_source), ''), 'visit');

  -- 같은 사용자의 같은 장소/메뉴 요청은 트랜잭션 동안 직렬화합니다.
  -- 사용자가 버튼을 빠르게 여러 번 눌러도 중복 검사와 저장이 엇갈리지 않게 하기 위한 장치입니다.
  perform pg_advisory_xact_lock(
    hashtextextended(
      auth.uid()::text || ':' ||
      coalesce(p_place_id::text, 'no_place') || ':' ||
      coalesce(p_menu_id::text, 'no_menu') || ':' ||
      normalized_source,
      0
    )
  );

  if normalized_source = 'visit' then
    select exists (
      select 1
      from public.savings_logs
      where user_id = auth.uid()
        and place_id is not distinct from p_place_id
        and menu_id is not distinct from p_menu_id
        and source = 'visit'
        and created_at >= now() - interval '2 hours'
    )
    into duplicate_exists;

    if duplicate_exists then
      raise exception '같은 장소/메뉴 절약 기록은 2시간에 한 번만 가능해요.';
    end if;
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
    coalesce(nullif(trim(p_category), ''), 'food'),
    normalized_source
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

-- 실행 후 확인용 SQL:
-- 1. 함수가 교체됐는지 확인
-- select proname, pronargs
-- from pg_proc
-- where proname = 'log_saving';
--
-- 2. 최근 절약 로그 확인
-- select user_id, place_name, menu_name, saved_amount, source, created_at
-- from public.savings_logs
-- order by created_at desc
-- limit 10;
--
-- 3. 앱에서 같은 장소/메뉴를 2시간 안에 두 번 기록하면
-- "같은 장소/메뉴 절약 기록은 2시간에 한 번만 가능해요." 오류가 나와야 정상입니다.
