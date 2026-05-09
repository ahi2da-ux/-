-- 025_link_approved_reports_to_challenge.sql
-- 가격 제보 승인 흐름을 1억 챌린지 절약 기록과 연결합니다.
-- 목표:
-- 1. 운영자가 가격 제보를 승인하면 가격표/포인트/알림뿐 아니라 1억 챌린지에도 절약액을 반영합니다.
-- 2. 같은 price_report가 savings_logs에 중복 반영되지 않게 report_id 고유 인덱스를 둡니다.
-- 3. 익명 제보는 사용자 귀속이 불가능하므로 챌린지 기록에서 제외합니다.

alter table public.savings_logs
add column if not exists report_id uuid references public.price_reports(id) on delete set null;

alter table public.price_reports
add column if not exists savings_log_id uuid references public.savings_logs(id) on delete set null;

create unique index if not exists savings_logs_report_unique_idx
on public.savings_logs (report_id)
where report_id is not null;

create index if not exists price_reports_savings_log_id_idx
on public.price_reports (savings_log_id);

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
  inserted_log_id uuid;
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
    return approved_report.savings_log_id;
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
    source
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
    'approved_report'
  )
  on conflict (report_id) where report_id is not null
  do nothing
  returning id into inserted_log_id;

  if inserted_log_id is null then
    select id
    into inserted_log_id
    from public.savings_logs
    where report_id = approved_report.id
    limit 1;
  end if;

  if inserted_log_id is not null then
    update public.price_reports
    set savings_log_id = inserted_log_id
    where id = approved_report.id;

    perform public.sync_challenge_savings(approved_report.user_id);
  end if;

  return inserted_log_id;
end;
$$;

grant execute on function public.apply_approved_report_to_challenge(public.price_reports) to authenticated;

create or replace function public.approve_price_report(
  target_report_id uuid,
  admin_note text default null
)
returns public.price_reports
language plpgsql
security definer
set search_path = public
as $$
declare
  target_report public.price_reports;
  updated_report public.price_reports;
  trimmed_note text;
begin
  if not public.is_app_admin() then
    raise exception '관리자만 가격 제보를 승인할 수 있습니다.';
  end if;

  select *
  into target_report
  from public.price_reports
  where id = target_report_id
  for update;

  if target_report.id is null then
    raise exception '승인할 가격 제보를 찾지 못했습니다.';
  end if;

  if target_report.report_status <> 'pending' then
    raise exception '이미 검수 완료된 제보는 다시 승인할 수 없습니다. 현재 상태: %', target_report.report_status;
  end if;

  trimmed_note := nullif(trim(coalesce(admin_note, '')), '');

  update public.price_reports
  set
    report_status = 'approved',
    reviewed_by = auth.uid(),
    reviewed_at = now(),
    review_note = trimmed_note,
    rejection_reason = null,
    point_granted_at = now()
  where id = target_report_id
  returning * into updated_report;

  perform public.apply_approved_report_to_price_catalog(updated_report);
  perform public.apply_approved_report_to_challenge(updated_report);

  update public.profiles
  set
    point_balance = point_balance + updated_report.reward_points,
    accepted_report_count = accepted_report_count + 1,
    report_count = report_count + 1,
    updated_at = now()
  where id = updated_report.user_id
    and updated_report.user_id is not null;

  if updated_report.user_id is not null then
    insert into public.point_transactions (
      user_id,
      report_id,
      amount,
      transaction_type,
      title,
      description,
      created_by
    ) values (
      updated_report.user_id,
      updated_report.id,
      updated_report.reward_points,
      'report_reward',
      '가격 제보 승인 적립',
      concat(updated_report.menu_name, ' ', updated_report.reported_price, '원 제보 승인'),
      auth.uid()
    );
  end if;

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
    updated_report.place_id,
    updated_report.id,
    '목표 가격 발견',
    concat(updated_report.menu_name, ' ', updated_report.reported_price, '원 제보가 승인됐어요.'),
    settings.target_price,
    updated_report.reported_price
  from public.price_alert_settings as settings
  where settings.place_id = updated_report.place_id
    and settings.is_enabled = true
    and (
      settings.target_price is null
      or updated_report.reported_price <= settings.target_price
    )
  on conflict do nothing;

  insert into public.price_report_review_logs (
    report_id,
    admin_id,
    action,
    previous_status,
    next_status,
    note,
    rejection_reason
  ) values (
    updated_report.id,
    auth.uid(),
    'approved',
    target_report.report_status,
    updated_report.report_status,
    trimmed_note,
    null
  );

  select *
  into updated_report
  from public.price_reports
  where id = target_report_id;

  return updated_report;
end;
$$;

grant execute on function public.approve_price_report(uuid, text) to authenticated;

-- 기존 승인 제보 중 아직 챌린지에 반영되지 않은 건을 한 번 보강합니다.
do $$
declare
  approved_report public.price_reports;
begin
  for approved_report in
    select *
    from public.price_reports
    where report_status = 'approved'
      and user_id is not null
      and savings_log_id is null
    order by reviewed_at asc nulls last, created_at asc
  loop
    perform public.apply_approved_report_to_price_catalog(approved_report);
    perform public.apply_approved_report_to_challenge(approved_report);
  end loop;
end;
$$;

-- 실행 후 확인용 SQL:
-- select
--   price_reports.id as report_id,
--   price_reports.user_id,
--   price_reports.menu_name,
--   price_reports.reported_price,
--   price_reports.savings_log_id,
--   savings_logs.saved_amount,
--   savings_logs.source
-- from public.price_reports
-- left join public.savings_logs on savings_logs.id = price_reports.savings_log_id
-- where price_reports.report_status = 'approved'
-- order by price_reports.reviewed_at desc nulls last, price_reports.created_at desc
-- limit 20;
