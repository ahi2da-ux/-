-- 029_harden_challenge_and_report_pipeline.sql
-- 베타 운영 전 P0 데이터/RPC 안정화 마이그레이션입니다.
-- 목표:
-- 1. cancel_saving_log 반환값을 iOS ChallengeSummary 모델과 맞춥니다.
-- 2. 가격 제보 승인/복구를 반복 실행해도 places.receipt_count가 계속 부풀지 않게 합니다.
-- 3. 승인 제보와 savings_logs 연결이 끊기거나 취소된 경우에도 복구 가능하게 합니다.

-- 1. 1억 챌린지 기록 취소 RPC 반환형 보정
-- 기존 023번 함수는 5개 컬럼만 반환해서, iOS의 7개 컬럼 ChallengeSummary 디코딩과 맞지 않습니다.
drop function if exists public.cancel_saving_log(uuid, text);

create function public.cancel_saving_log(
  p_log_id uuid,
  p_reason text default 'user_cancelled'
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
  target_log public.savings_logs;
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

  return query
  select *
  from public.sync_challenge_savings(auth.uid());
end;
$$;

revoke execute on function public.cancel_saving_log(uuid, text) from public;
revoke execute on function public.cancel_saving_log(uuid, text) from anon;
grant execute on function public.cancel_saving_log(uuid, text) to authenticated;

-- 2. 승인 가격표 반영 RPC 멱등화
-- 기존 함수는 repair/backfill을 반복하면 receipt_count가 계속 증가할 수 있었습니다.
create or replace function public.apply_approved_report_to_price_catalog(
  approved_report public.price_reports
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  next_sort_order integer;
  recalculated_base_price integer;
  approved_receipt_count integer;
  target_category text;
  calculated_reference_price integer;
begin
  if approved_report.id is null then
    raise exception '가격에 반영할 제보 정보가 없습니다.';
  end if;

  if approved_report.report_status <> 'approved' then
    raise exception '승인된 제보만 가격표에 반영할 수 있습니다.';
  end if;

  select category
  into target_category
  from public.places
  where id = approved_report.place_id;

  calculated_reference_price := case target_category
    when 'food' then greatest(approved_report.reported_price + 3000, 12000)
    when 'cafe' then greatest(approved_report.reported_price + 1500, 5000)
    when 'hair' then greatest(approved_report.reported_price + 5000, 18000)
    when 'lodging' then greatest(approved_report.reported_price + 10000, 70000)
    else approved_report.reported_price
  end;

  select coalesce(max(sort_order), -1) + 1
  into next_sort_order
  from public.menus
  where place_id = approved_report.place_id;

  insert into public.menus (
    place_id,
    name,
    description,
    price,
    reference_price,
    is_verified,
    sort_order
  ) values (
    approved_report.place_id,
    trim(approved_report.menu_name),
    '사용자 가격 제보 승인 반영',
    approved_report.reported_price,
    calculated_reference_price,
    true,
    next_sort_order
  )
  on conflict (place_id, name)
  do update set
    price = excluded.price,
    reference_price = coalesce(public.menus.reference_price, excluded.reference_price),
    is_verified = true,
    description = case
      when public.menus.description is null or trim(public.menus.description) = '' then excluded.description
      else public.menus.description
    end,
    updated_at = now();

  select min(price)
  into recalculated_base_price
  from public.menus
  where place_id = approved_report.place_id;

  select coalesce(sum(greatest(photo_count, 1)), 0)::integer
  into approved_receipt_count
  from public.price_reports
  where place_id = approved_report.place_id
    and report_status = 'approved';

  update public.places
  set
    base_price = coalesce(recalculated_base_price, approved_report.reported_price),
    is_verified = true,
    verify_text = '가격 제보 승인 반영',
    receipt_count = greatest(coalesce(public.places.receipt_count, 0), approved_receipt_count),
    updated_text = '방금 확인',
    updated_at = now()
  where id = approved_report.place_id;
end;
$$;

-- 이 함수는 approve_price_report/repair_report_pipeline 내부에서만 쓰는 보조 함수입니다.
revoke execute on function public.apply_approved_report_to_price_catalog(public.price_reports) from public;
revoke execute on function public.apply_approved_report_to_price_catalog(public.price_reports) from anon;
revoke execute on function public.apply_approved_report_to_price_catalog(public.price_reports) from authenticated;

-- 3. 승인 제보 -> 1억 챌린지 연결 RPC 복구성 강화
create or replace function public.apply_approved_report_to_challenge(
  approved_report public.price_reports
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  target_place public.places;
  target_menu public.menus;
  calculated_saved_amount bigint;
  upserted_log_id uuid;
  active_log_id uuid;
begin
  if approved_report.id is null then
    raise exception '챌린지에 반영할 제보 정보가 없습니다.';
  end if;

  if approved_report.report_status <> 'approved' then
    raise exception '승인된 제보만 챌린지에 반영할 수 있습니다.';
  end if;

  if approved_report.user_id is null then
    return null;
  end if;

  if approved_report.savings_log_id is not null then
    select id
    into active_log_id
    from public.savings_logs
    where id = approved_report.savings_log_id
      and report_id = approved_report.id
      and user_id = approved_report.user_id
      and cancelled_at is null
    limit 1;

    if active_log_id is not null then
      perform public.sync_challenge_savings(approved_report.user_id);
      return active_log_id;
    end if;

    update public.price_reports
    set savings_log_id = null
    where id = approved_report.id;
  end if;

  select id
  into active_log_id
  from public.savings_logs
  where report_id = approved_report.id
    and user_id = approved_report.user_id
    and cancelled_at is null
  limit 1;

  if active_log_id is not null then
    update public.price_reports
    set savings_log_id = active_log_id
    where id = approved_report.id;

    perform public.sync_challenge_savings(approved_report.user_id);
    return active_log_id;
  end if;

  select *
  into target_place
  from public.places
  where id = approved_report.place_id;

  select *
  into target_menu
  from public.menus
  where place_id = approved_report.place_id
    and name = trim(approved_report.menu_name)
  order by updated_at desc nulls last, created_at desc nulls last
  limit 1;

  calculated_saved_amount := greatest(
    coalesce(target_menu.reference_price, target_menu.price, approved_report.reported_price)
    - approved_report.reported_price,
    0
  );

  if calculated_saved_amount <= 0 then
    return null;
  end if;

  insert into public.profiles (id, display_name)
  values (approved_report.user_id, '짠테커')
  on conflict (id) do nothing;

  insert into public.savings_logs (
    user_id,
    place_id,
    menu_id,
    report_id,
    place_name,
    menu_name,
    saved_amount,
    original_price,
    actual_price,
    category,
    source,
    cancelled_at,
    cancelled_reason
  ) values (
    approved_report.user_id,
    approved_report.place_id,
    target_menu.id,
    approved_report.id,
    target_place.name,
    trim(approved_report.menu_name),
    calculated_saved_amount,
    coalesce(target_menu.reference_price, target_menu.price, approved_report.reported_price),
    approved_report.reported_price,
    coalesce(target_place.category, 'food'),
    'approved_report',
    null,
    null
  )
  on conflict (report_id) where report_id is not null
  do update set
    user_id = excluded.user_id,
    place_id = excluded.place_id,
    menu_id = excluded.menu_id,
    place_name = excluded.place_name,
    menu_name = excluded.menu_name,
    saved_amount = excluded.saved_amount,
    original_price = excluded.original_price,
    actual_price = excluded.actual_price,
    category = excluded.category,
    source = excluded.source,
    cancelled_at = null,
    cancelled_reason = null
  returning id into upserted_log_id;

  update public.price_reports
  set savings_log_id = upserted_log_id
  where id = approved_report.id;

  perform public.sync_challenge_savings(approved_report.user_id);

  return upserted_log_id;
end;
$$;

-- 이 함수도 승인/복구 RPC 내부 보조 함수이므로 직접 실행 권한을 닫습니다.
revoke execute on function public.apply_approved_report_to_challenge(public.price_reports) from public;
revoke execute on function public.apply_approved_report_to_challenge(public.price_reports) from anon;
revoke execute on function public.apply_approved_report_to_challenge(public.price_reports) from authenticated;

-- 적용 후 확인 SQL:
-- select routine_name, privilege_type, grantee
-- from information_schema.routine_privileges
-- where routine_schema = 'public'
--   and routine_name in (
--     'cancel_saving_log',
--     'apply_approved_report_to_price_catalog',
--     'apply_approved_report_to_challenge'
--   )
-- order by routine_name, grantee;
--
-- select report_status, count(*)
-- from public.price_reports
-- group by report_status
-- order by report_status;
