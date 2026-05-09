-- 028_harden_release_security.sql
-- 출시 전 P0 보안 잠금 마이그레이션입니다.
-- 목표:
-- 1. 일반 로그인 사용자가 places/menus 가격표를 직접 수정하지 못하게 막습니다.
-- 2. savings_logs 직접 INSERT를 막고 log_saving RPC만 사용하게 합니다.
-- 3. 내부 보조 RPC를 일반 사용자가 직접 호출하지 못하게 합니다.
-- 4. log_saving에 금액/출처/장소/메뉴 검증을 추가합니다.

-- 1. 장소/메뉴 카탈로그 직접 쓰기 차단
drop policy if exists "places_authenticated_insert" on public.places;
drop policy if exists "places_authenticated_update" on public.places;
drop policy if exists "places_authenticated_delete" on public.places;

drop policy if exists "menus_authenticated_insert" on public.menus;
drop policy if exists "menus_authenticated_update" on public.menus;
drop policy if exists "menus_authenticated_delete" on public.menus;

drop policy if exists "places_admin_insert" on public.places;
drop policy if exists "places_admin_update" on public.places;
drop policy if exists "places_admin_delete" on public.places;

drop policy if exists "menus_admin_insert" on public.menus;
drop policy if exists "menus_admin_update" on public.menus;
drop policy if exists "menus_admin_delete" on public.menus;

create policy "places_admin_insert"
on public.places
for insert
to authenticated
with check (public.is_app_admin());

create policy "places_admin_update"
on public.places
for update
to authenticated
using (public.is_app_admin())
with check (public.is_app_admin());

create policy "places_admin_delete"
on public.places
for delete
to authenticated
using (public.is_app_admin());

create policy "menus_admin_insert"
on public.menus
for insert
to authenticated
with check (public.is_app_admin());

create policy "menus_admin_update"
on public.menus
for update
to authenticated
using (public.is_app_admin())
with check (public.is_app_admin());

create policy "menus_admin_delete"
on public.menus
for delete
to authenticated
using (public.is_app_admin());

-- 2. savings_logs 직접 INSERT 차단
drop policy if exists "savings_logs_self_insert" on public.savings_logs;
drop policy if exists "savings_logs_admin_insert" on public.savings_logs;

create policy "savings_logs_admin_insert"
on public.savings_logs
for insert
to authenticated
with check (public.is_app_admin());

-- 3. 내부 보조 함수 직접 호출 차단
revoke execute on function public.apply_approved_report_to_price_catalog(public.price_reports) from anon;
revoke execute on function public.apply_approved_report_to_price_catalog(public.price_reports) from authenticated;
revoke execute on function public.apply_approved_report_to_price_catalog(public.price_reports) from public;

revoke execute on function public.apply_approved_report_to_challenge(public.price_reports) from anon;
revoke execute on function public.apply_approved_report_to_challenge(public.price_reports) from authenticated;
revoke execute on function public.apply_approved_report_to_challenge(public.price_reports) from public;

-- 4. log_saving RPC 강화
-- 기존 020/022번에서 만든 log_saving과 반환 컬럼 수가 달라졌기 때문에,
-- create or replace만 사용하면 PostgreSQL이 "return type 변경 불가" 오류를 냅니다.
-- 클라이언트에서 호출하는 RPC 이름과 파라미터는 유지하되, 기존 함수를 먼저 제거한 뒤 다시 만듭니다.
drop function if exists public.log_saving(uuid, uuid, text, text, bigint, bigint, bigint, text, text);

create function public.log_saving(
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
  challenge_grade text,
  monthly_savings bigint,
  log_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  normalized_source text;
  normalized_category text;
  target_place public.places;
  target_menu public.menus;
  duplicate_exists boolean;
  max_allowed_saving bigint := 1000000;
begin
  if auth.uid() is null then
    raise exception '로그인한 사용자만 절약액을 기록할 수 있습니다.';
  end if;

  if p_place_id is null then
    raise exception '장소 정보가 필요합니다.';
  end if;

  if p_saved_amount is null or p_saved_amount <= 0 then
    raise exception '절약액은 1원 이상이어야 합니다.';
  end if;

  if p_saved_amount > max_allowed_saving then
    raise exception '한 번에 기록할 수 있는 절약액은 최대 %원입니다.', max_allowed_saving;
  end if;

  if p_actual_price is not null and p_actual_price < 0 then
    raise exception '실제 이용가는 0원 이상이어야 합니다.';
  end if;

  if p_original_price is not null and p_original_price < 0 then
    raise exception '일반 기준가는 0원 이상이어야 합니다.';
  end if;

  if p_original_price is not null
     and p_actual_price is not null
     and p_original_price < p_actual_price then
    raise exception '일반 기준가는 실제 이용가보다 작을 수 없습니다.';
  end if;

  normalized_source := coalesce(nullif(trim(p_source), ''), 'visit');
  normalized_category := coalesce(nullif(trim(p_category), ''), 'food');

  if normalized_source not in ('visit', 'guest_import') then
    raise exception '허용되지 않은 절약 기록 출처입니다: %', normalized_source;
  end if;

  select *
  into target_place
  from public.places
  where id = p_place_id;

  if target_place.id is null then
    raise exception '존재하지 않는 장소입니다.';
  end if;

  if p_menu_id is not null then
    select *
    into target_menu
    from public.menus
    where id = p_menu_id
      and place_id = p_place_id;

    if target_menu.id is null then
      raise exception '선택한 메뉴가 해당 장소에 속하지 않습니다.';
    end if;
  end if;

  -- 같은 사용자의 같은 장소/메뉴 요청은 트랜잭션 동안 직렬화합니다.
  perform pg_advisory_xact_lock(
    hashtextextended(
      auth.uid()::text || ':' ||
      coalesce(p_place_id::text, 'no_place') || ':' ||
      coalesce(p_menu_id::text, 'no_menu') || ':' ||
      normalized_source,
      0
    )
  );

  if normalized_source in ('visit', 'guest_import') then
    select exists (
      select 1
      from public.savings_logs
      where user_id = auth.uid()
        and place_id is not distinct from p_place_id
        and menu_id is not distinct from p_menu_id
        and source in ('visit', 'guest_import')
        and cancelled_at is null
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
    coalesce(nullif(trim(coalesce(p_place_name, '')), ''), target_place.name),
    coalesce(nullif(trim(coalesce(p_menu_name, '')), ''), target_menu.name),
    p_saved_amount,
    p_original_price,
    p_actual_price,
    normalized_category,
    normalized_source
  );

  return query
  select *
  from public.sync_challenge_savings(auth.uid());
end;
$$;

revoke execute on function public.log_saving(uuid, uuid, text, text, bigint, bigint, bigint, text, text) from public;
revoke execute on function public.log_saving(uuid, uuid, text, text, bigint, bigint, bigint, text, text) from anon;
grant execute on function public.log_saving(uuid, uuid, text, text, bigint, bigint, bigint, text, text) to authenticated;

-- 적용 후 확인 SQL:
-- select policyname, cmd, roles
-- from pg_policies
-- where schemaname = 'public'
--   and tablename in ('places', 'menus', 'savings_logs')
-- order by tablename, policyname;
--
-- select routine_name, privilege_type, grantee
-- from information_schema.routine_privileges
-- where routine_schema = 'public'
--   and routine_name in (
--     'apply_approved_report_to_price_catalog',
--     'apply_approved_report_to_challenge',
--     'log_saving'
--   )
-- order by routine_name, grantee;
