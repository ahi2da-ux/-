-- 021_add_menu_reference_price.sql
-- 1억 챌린지의 절약액 계산 신뢰도를 높이기 위해 메뉴별 일반 기준가를 저장합니다.
-- 목표:
-- 1. menus.reference_price를 추가합니다.
-- 2. 기존 메뉴 데이터에 카테고리별 MVP 기준가를 안전하게 채웁니다.
-- 3. 앱은 reference_price가 있으면 그 값을 우선 사용하고, 없으면 기존 임시 계산으로 fallback합니다.

alter table public.menus
add column if not exists reference_price integer check (reference_price is null or reference_price >= 0);

create index if not exists menus_reference_price_idx
on public.menus (reference_price);

update public.menus
set reference_price = case places.category
  when 'food' then greatest(public.menus.price + 3000, 12000)
  when 'cafe' then greatest(public.menus.price + 1500, 5000)
  when 'hair' then greatest(public.menus.price + 5000, 18000)
  when 'lodging' then greatest(public.menus.price + 10000, 70000)
  else public.menus.price
end
from public.places
where public.menus.place_id = public.places.id
  and public.menus.reference_price is null;

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

-- 검증 예시:
-- select
--   places.name as place_name,
--   menus.name as menu_name,
--   menus.price,
--   menus.reference_price,
--   greatest(coalesce(menus.reference_price, menus.price) - menus.price, 0) as expected_saving
-- from public.menus
-- join public.places on places.id = menus.place_id
-- order by menus.updated_at desc
-- limit 20;
