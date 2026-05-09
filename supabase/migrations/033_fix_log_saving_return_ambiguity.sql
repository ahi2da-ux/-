-- 033_fix_log_saving_return_ambiguity.sql
-- log_saving RPC 실행 시 반환 컬럼명(current_savings 등)이 PL/pgSQL 내부에서
-- 컬럼 참조와 충돌하는 문제를 보정합니다.
-- 기존 028번 migration은 수정하지 않고, 동일한 RPC 시그니처를 안전하게 교체합니다.

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
      from public.savings_logs as logs
      where logs.user_id = auth.uid()
        and logs.place_id is not distinct from p_place_id
        and logs.menu_id is not distinct from p_menu_id
        and logs.source in ('visit', 'guest_import')
        and logs.cancelled_at is null
        and logs.created_at >= now() - interval '2 hours'
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
  select
    summary.goal_amount,
    summary.current_savings,
    summary.remaining_amount,
    summary.progress_rate,
    summary.challenge_grade,
    summary.monthly_savings,
    summary.log_count
  from public.sync_challenge_savings(auth.uid()) as summary(
    goal_amount,
    current_savings,
    remaining_amount,
    progress_rate,
    challenge_grade,
    monthly_savings,
    log_count
  );
end;
$$;

revoke execute on function public.log_saving(uuid, uuid, text, text, bigint, bigint, bigint, text, text) from public;
revoke execute on function public.log_saving(uuid, uuid, text, text, bigint, bigint, bigint, text, text) from anon;
grant execute on function public.log_saving(uuid, uuid, text, text, bigint, bigint, bigint, text, text) to authenticated;

