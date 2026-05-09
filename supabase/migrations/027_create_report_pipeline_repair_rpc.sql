-- 027_create_report_pipeline_repair_rpc.sql
-- 가격 제보 승인 파이프라인 누락 건을 운영자가 수동 복구하는 RPC를 추가합니다.
-- 목표:
-- 1. 026 audit에서 발견한 missing_* 상태를 특정 report_id 기준으로 복구합니다.
-- 2. 이미 승인된 price_reports만 대상으로 하며, pending/rejected 제보는 건드리지 않습니다.
-- 3. 가격표, 포인트 장부, 알림 이벤트, 1억 챌린지를 멱등적으로 재반영합니다.

create or replace function public.repair_report_pipeline(
  target_report_id uuid
)
returns table (
  report_id uuid,
  user_id uuid,
  place_id uuid,
  place_name text,
  menu_name text,
  reported_price integer,
  report_status text,
  reviewed_at timestamptz,
  menu_id uuid,
  menu_price integer,
  menu_reference_price integer,
  expected_saved_amount bigint,
  point_transaction_id uuid,
  point_amount integer,
  savings_log_id uuid,
  saved_amount bigint,
  savings_source text,
  alert_event_count bigint,
  pipeline_status text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  target_report public.price_reports;
begin
  if not public.is_app_admin() then
    raise exception '관리자만 가격 제보 파이프라인을 복구할 수 있습니다.';
  end if;

  if target_report_id is null then
    raise exception '복구할 가격 제보 ID를 입력해주세요.';
  end if;

  select *
  into target_report
  from public.price_reports
  where id = target_report_id
  for update;

  if target_report.id is null then
    raise exception '복구할 가격 제보를 찾지 못했습니다.';
  end if;

  if target_report.report_status <> 'approved' then
    raise exception '승인된 가격 제보만 복구할 수 있습니다. 현재 상태: %', target_report.report_status;
  end if;

  -- 1. 가격표/장소 대표 가격 재반영
  perform public.apply_approved_report_to_price_catalog(target_report);

  -- 2. 로그인 사용자 제보라면 포인트 장부를 보강하고, 장부 기준으로 포인트 잔액을 재동기화
  if target_report.user_id is not null then
    insert into public.point_transactions (
      user_id,
      report_id,
      amount,
      transaction_type,
      title,
      description,
      created_by
    ) values (
      target_report.user_id,
      target_report.id,
      target_report.reward_points,
      'report_reward',
      '가격 제보 승인 적립',
      concat(target_report.menu_name, ' ', target_report.reported_price, '원 제보 승인'),
      auth.uid()
    )
    on conflict do nothing;

    update public.profiles
    set
      point_balance = coalesce((
        select sum(point_transactions.amount)
        from public.point_transactions
        where point_transactions.user_id = target_report.user_id
      ), 0),
      updated_at = now()
    where id = target_report.user_id;
  end if;

  -- 3. 1억 챌린지 절약 로그 재반영
  perform public.apply_approved_report_to_challenge(target_report);

  -- 4. 가격 알림 이벤트 재반영
  insert into public.price_alert_events (
    user_id,
    place_id,
    report_id,
    title,
    message,
    target_price,
    matched_price
  )
  select
    settings.user_id,
    target_report.place_id,
    target_report.id,
    '목표 가격 발견',
    concat(target_report.menu_name, ' ', target_report.reported_price, '원 제보가 승인됐어요.'),
    settings.target_price,
    target_report.reported_price
  from public.price_alert_settings as settings
  where settings.place_id = target_report.place_id
    and settings.is_enabled = true
    and (
      settings.target_price is null
      or target_report.reported_price <= settings.target_price
    )
  on conflict do nothing;

  -- 5. 챌린지 누적액 정합성 재동기화
  if target_report.user_id is not null then
    perform public.sync_challenge_savings(target_report.user_id);
  end if;

  return query
  select *
  from public.get_report_pipeline_audit(200) as audit
  where audit.report_id = target_report_id;
end;
$$;

grant execute on function public.repair_report_pipeline(uuid) to authenticated;

-- 실행 후 확인용 SQL:
-- 1. 문제가 있는 승인 제보 찾기
-- select *
-- from public.get_report_pipeline_audit(100)
-- where pipeline_status <> 'ok';
--
-- 2. 특정 제보 복구
-- select *
-- from public.repair_report_pipeline('여기에-price_reports-id');
--
-- 3. 복구 후 다시 확인
-- select *
-- from public.get_report_pipeline_audit(100)
-- where report_id = '여기에-price_reports-id';
