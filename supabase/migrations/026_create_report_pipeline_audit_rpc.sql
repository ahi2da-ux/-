-- 026_create_report_pipeline_audit_rpc.sql
-- 가격 제보 승인 후 운영 파이프라인 상태를 한 번에 점검하는 관리자용 RPC를 추가합니다.
-- 목표:
-- 1. 승인된 가격 제보가 가격표, 포인트, 알림, 1억 챌린지에 정상 반영됐는지 확인합니다.
-- 2. 운영자가 Supabase SQL Editor에서 빠르게 누락 건을 찾을 수 있게 합니다.
-- 3. 일반 사용자는 조회할 수 없고 app_admin만 실행할 수 있게 제한합니다.

create or replace function public.get_report_pipeline_audit(
  p_limit integer default 50
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
  safe_limit integer;
begin
  if not public.is_app_admin() then
    raise exception '관리자만 가격 제보 파이프라인을 점검할 수 있습니다.';
  end if;

  safe_limit := least(greatest(coalesce(p_limit, 50), 1), 200);

  return query
  with menu_match as (
    select distinct on (menus.place_id, menus.name)
      menus.id,
      menus.place_id,
      menus.name,
      menus.price,
      menus.reference_price
    from public.menus
    order by menus.place_id, menus.name, menus.updated_at desc nulls last, menus.created_at desc nulls last
  ),
  alert_counts as (
    select
      price_alert_events.report_id,
      count(*)::bigint as count
    from public.price_alert_events
    where price_alert_events.report_id is not null
    group by price_alert_events.report_id
  )
  select
    reports.id as report_id,
    reports.user_id,
    reports.place_id,
    places.name as place_name,
    reports.menu_name,
    reports.reported_price,
    reports.report_status,
    reports.reviewed_at,
    menu_match.id as menu_id,
    menu_match.price as menu_price,
    menu_match.reference_price as menu_reference_price,
    greatest(
      coalesce(menu_match.reference_price, menu_match.price, reports.reported_price) - reports.reported_price,
      0
    )::bigint as expected_saved_amount,
    point_transactions.id as point_transaction_id,
    point_transactions.amount as point_amount,
    savings_logs.id as savings_log_id,
    savings_logs.saved_amount,
    savings_logs.source as savings_source,
    coalesce(alert_counts.count, 0)::bigint as alert_event_count,
    case
      when reports.report_status <> 'approved' then 'not_approved'
      when menu_match.id is null then 'missing_menu'
      when reports.user_id is not null and point_transactions.id is null then 'missing_point'
      when reports.user_id is not null
        and greatest(coalesce(menu_match.reference_price, menu_match.price, reports.reported_price) - reports.reported_price, 0) > 0
        and savings_logs.id is null then 'missing_challenge_log'
      when reports.user_id is not null
        and savings_logs.id is not null
        and savings_logs.saved_amount <> greatest(coalesce(menu_match.reference_price, menu_match.price, reports.reported_price) - reports.reported_price, 0) then 'challenge_amount_mismatch'
      else 'ok'
    end as pipeline_status
  from public.price_reports as reports
  left join public.places as places
    on places.id = reports.place_id
  left join menu_match
    on menu_match.place_id = reports.place_id
   and menu_match.name = trim(reports.menu_name)
  left join public.point_transactions as point_transactions
    on point_transactions.report_id = reports.id
   and point_transactions.transaction_type = 'report_reward'
  left join public.savings_logs as savings_logs
    on savings_logs.report_id = reports.id
   and savings_logs.cancelled_at is null
  left join alert_counts
    on alert_counts.report_id = reports.id
  order by reports.reviewed_at desc nulls last, reports.created_at desc
  limit safe_limit;
end;
$$;

grant execute on function public.get_report_pipeline_audit(integer) to authenticated;

-- 실행 후 확인용 SQL:
-- select *
-- from public.get_report_pipeline_audit(50)
-- order by reviewed_at desc nulls last;
--
-- 문제 건만 보고 싶을 때:
-- select *
-- from public.get_report_pipeline_audit(100)
-- where pipeline_status <> 'ok';
