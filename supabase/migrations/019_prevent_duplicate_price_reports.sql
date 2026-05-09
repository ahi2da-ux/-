-- 019_prevent_duplicate_price_reports.sql
-- 가격 제보 중복/스팸을 DB 레벨에서 막습니다.
-- 핵심 목표:
-- 1. 로그인 사용자는 같은 장소 + 같은 메뉴를 24시간 안에 반복 제보할 수 없습니다.
-- 2. 로그인 사용자는 24시간 안에 최대 10건까지만 가격 제보할 수 있습니다.
-- 3. 익명 제보는 사용자 식별이 불가능하므로 같은 장소 + 같은 메뉴 + 같은 가격의 10분 내 반복만 막습니다.

create index if not exists price_reports_user_place_menu_created_idx
on public.price_reports (
  user_id,
  place_id,
  lower(trim(menu_name)),
  created_at desc
)
where user_id is not null;

create index if not exists price_reports_anon_place_menu_price_created_idx
on public.price_reports (
  place_id,
  lower(trim(menu_name)),
  reported_price,
  created_at desc
)
where user_id is null;

create or replace function public.prevent_duplicate_price_report()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  normalized_menu_name text;
  recent_user_report_count integer;
begin
  normalized_menu_name := lower(trim(new.menu_name));

  if normalized_menu_name = '' then
    raise exception '메뉴명을 입력해주세요.';
  end if;

  -- 로그인 사용자는 하루 제보량을 제한합니다.
  -- 운영자가 감당 가능한 검수량과 포인트 악용 방지를 위한 MVP 기준입니다.
  if new.user_id is not null then
    select count(*)
    into recent_user_report_count
    from public.price_reports
    where user_id = new.user_id
      and created_at >= now() - interval '24 hours';

    if recent_user_report_count >= 10 then
      raise exception '24시간 안에는 최대 10건까지만 가격 제보할 수 있습니다.';
    end if;

    if exists (
      select 1
      from public.price_reports
      where user_id = new.user_id
        and place_id = new.place_id
        and lower(trim(menu_name)) = normalized_menu_name
        and created_at >= now() - interval '24 hours'
        and report_status in ('pending', 'approved')
    ) then
      raise exception '같은 장소의 같은 메뉴는 24시간 안에 한 번만 제보할 수 있습니다.';
    end if;
  else
    -- 익명 사용자는 계정 기준 제한이 불가능합니다.
    -- 대신 같은 장소 + 같은 메뉴 + 같은 가격의 짧은 시간 반복 입력을 막습니다.
    if exists (
      select 1
      from public.price_reports
      where user_id is null
        and place_id = new.place_id
        and lower(trim(menu_name)) = normalized_menu_name
        and reported_price = new.reported_price
        and created_at >= now() - interval '10 minutes'
    ) then
      raise exception '같은 가격 제보가 방금 접수되었습니다. 잠시 후 다시 시도해주세요.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists prevent_duplicate_price_report on public.price_reports;

create trigger prevent_duplicate_price_report
before insert on public.price_reports
for each row
execute function public.prevent_duplicate_price_report();

-- 검증 예시:
-- 같은 로그인 사용자로 같은 place_id + menu_name을 연속 insert하면 아래 메시지로 차단됩니다.
-- "같은 장소의 같은 메뉴는 24시간 안에 한 번만 제보할 수 있습니다."
