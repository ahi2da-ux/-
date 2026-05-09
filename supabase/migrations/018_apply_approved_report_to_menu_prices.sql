-- 018_apply_approved_report_to_menu_prices.sql
-- 승인된 가격 제보를 실제 메뉴/장소 가격 데이터에 반영합니다.
-- 핵심 목표:
-- 1. 운영자가 제보를 승인하면 public.menus에 해당 메뉴 가격을 upsert합니다.
-- 2. 같은 장소의 대표 가격 public.places.base_price를 메뉴 최저가로 다시 계산합니다.
-- 3. 앱은 기존 places + menus 조회만으로 최신 지도 가격을 표시할 수 있습니다.

create index if not exists menus_place_name_idx
on public.menus (place_id, name);

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
begin
  if approved_report.id is null then
    raise exception '가격에 반영할 제보 정보가 없습니다.';
  end if;

  if approved_report.report_status <> 'approved' then
    raise exception '승인된 제보만 가격표에 반영할 수 있습니다.';
  end if;

  select coalesce(max(sort_order), -1) + 1
  into next_sort_order
  from public.menus
  where place_id = approved_report.place_id;

  insert into public.menus (
    place_id,
    name,
    description,
    price,
    is_verified,
    sort_order
  ) values (
    approved_report.place_id,
    trim(approved_report.menu_name),
    '사용자 가격 제보 승인 반영',
    approved_report.reported_price,
    true,
    next_sort_order
  )
  on conflict (place_id, name)
  do update set
    price = excluded.price,
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

  update public.places
  set
    base_price = coalesce(recalculated_base_price, approved_report.reported_price),
    is_verified = true,
    verify_text = '가격 제보 승인 반영',
    receipt_count = receipt_count + greatest(approved_report.photo_count, 1),
    updated_text = '방금 확인',
    updated_at = now()
  where id = approved_report.place_id;
end;
$$;

grant execute on function public.apply_approved_report_to_price_catalog(public.price_reports) to authenticated;

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

  return updated_report;
end;
$$;

grant execute on function public.approve_price_report(uuid, text) to authenticated;

-- 기존에 이미 승인된 제보도 가격표에 반영합니다.
-- 같은 place_id + menu_name은 menus unique 제약으로 한 건으로 합쳐집니다.
do $$
declare
  approved_report public.price_reports;
begin
  for approved_report in
    select *
    from public.price_reports
    where report_status = 'approved'
    order by reviewed_at asc nulls last, created_at asc
  loop
    perform public.apply_approved_report_to_price_catalog(approved_report);
  end loop;
end;
$$;

-- 검증 예시:
-- select name, base_price, verify_text, updated_text
-- from public.places
-- order by updated_at desc
-- limit 10;
--
-- select places.name as place_name, menus.name as menu_name, menus.price, menus.is_verified
-- from public.menus
-- join public.places on places.id = menus.place_id
-- order by menus.updated_at desc
-- limit 20;
