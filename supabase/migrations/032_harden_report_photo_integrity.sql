-- 032_harden_report_photo_integrity.sql
-- 가격 제보 사진 metadata와 실제 Storage object의 정합성을 강제합니다.
-- 목표:
-- 1. 로그인 사용자가 user_id null로 익명 제보를 넣어 제한을 우회하지 못하게 합니다.
-- 2. 사진 metadata insert 시 실제 Storage object와 price_reports 소유권/path를 검증합니다.
-- 3. 운영자 직접 UPDATE로 approve_price_report 검증을 우회하지 못하게 합니다.
-- 4. 업로드 완료/승인 RPC가 사진 개수, display_order, 실제 object 존재를 모두 확인합니다.

drop policy if exists "price_reports_public_insert" on public.price_reports;

create policy "price_reports_public_insert"
on public.price_reports
for insert
to anon, authenticated
with check (
  reported_price > 0
  and photo_count between 1 and 4
  and has_photo_attachment = true
  and report_status = 'pending'
  and upload_status = 'pending_upload'
  and (
    (auth.uid() is null and user_id is null)
    or auth.uid() = user_id
  )
);

drop policy if exists "price_reports_admin_update" on public.price_reports;

drop policy if exists "price_report_photos_public_upload" on storage.objects;

create policy "price_report_photos_public_upload"
on storage.objects
for insert
to anon, authenticated
with check (
  bucket_id = 'price-report-photos'
  and split_part(name, '/', 1) = 'price_reports'
  and split_part(name, '/', 2) <> ''
  and lower(right(name, 4)) = '.jpg'
);

drop policy if exists "report_photos_public_insert" on public.report_photos;

create unique index if not exists report_photos_report_id_display_order_idx
on public.report_photos (report_id, display_order);

create or replace function public.insert_report_photo_metadata(
  p_report_id uuid,
  p_storage_path text,
  p_content_type text,
  p_file_size_bytes integer,
  p_display_order integer
)
returns public.report_photos
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  target_report public.price_reports;
  inserted_photo public.report_photos;
  clean_path text;
begin
  if p_report_id is null then
    raise exception '사진을 연결할 제보를 선택해주세요.';
  end if;

  clean_path := nullif(trim(coalesce(p_storage_path, '')), '');

  select *
  into target_report
  from public.price_reports
  where id = p_report_id
  for update;

  if target_report.id is null then
    raise exception '가격 제보를 찾지 못했습니다.';
  end if;

  if target_report.report_status <> 'pending'
    or target_report.upload_status <> 'pending_upload' then
    raise exception '검수 전 업로드 중인 제보에만 사진을 연결할 수 있습니다.';
  end if;

  if auth.uid() is not null then
    if target_report.user_id is distinct from auth.uid() then
      raise exception '본인 제보에만 사진을 연결할 수 있습니다.';
    end if;
  else
    if target_report.user_id is not null then
      raise exception '로그인 제보는 로그인 상태에서만 사진을 연결할 수 있습니다.';
    end if;
  end if;

  if p_content_type <> 'image/jpeg' then
    raise exception 'JPEG 사진만 저장할 수 있습니다.';
  end if;

  if p_file_size_bytes is null or p_file_size_bytes <= 0 then
    raise exception '사진 파일 크기가 올바르지 않습니다.';
  end if;

  if p_display_order is null
    or p_display_order < 0
    or p_display_order >= target_report.photo_count then
    raise exception '사진 순서가 올바르지 않습니다.';
  end if;

  if clean_path is null
    or split_part(clean_path, '/', 1) <> 'price_reports'
    or split_part(clean_path, '/', 2) <> p_report_id::text
    or lower(right(clean_path, 4)) <> '.jpg' then
    raise exception '사진 저장 경로가 올바르지 않습니다.';
  end if;

  if not exists (
    select 1
    from storage.objects as objects
    where objects.bucket_id = 'price-report-photos'
      and objects.name = clean_path
  ) then
    raise exception '업로드된 사진 파일을 찾지 못했습니다.';
  end if;

  insert into public.report_photos (
    report_id,
    storage_bucket,
    storage_path,
    content_type,
    file_size_bytes,
    display_order
  ) values (
    p_report_id,
    'price-report-photos',
    clean_path,
    p_content_type,
    p_file_size_bytes,
    p_display_order
  )
  returning * into inserted_photo;

  return inserted_photo;
end;
$$;

revoke execute on function public.insert_report_photo_metadata(uuid, text, text, integer, integer) from public;
grant execute on function public.insert_report_photo_metadata(uuid, text, text, integer, integer) to anon;
grant execute on function public.insert_report_photo_metadata(uuid, text, text, integer, integer) to authenticated;

create or replace function public.price_report_photo_integrity_ok(p_report_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, storage
stable
as $$
declare
  target_report public.price_reports;
  metadata_count integer;
  distinct_order_count integer;
  object_count integer;
  invalid_path_count integer;
begin
  select *
  into target_report
  from public.price_reports
  where id = p_report_id;

  if target_report.id is null then
    return false;
  end if;

  select
    count(*)::integer,
    count(distinct display_order)::integer,
    count(*) filter (
      where storage_bucket <> 'price-report-photos'
        or content_type <> 'image/jpeg'
        or file_size_bytes <= 0
        or display_order < 0
        or display_order >= target_report.photo_count
        or split_part(storage_path, '/', 1) <> 'price_reports'
        or split_part(storage_path, '/', 2) <> p_report_id::text
        or lower(right(storage_path, 4)) <> '.jpg'
    )::integer
  into metadata_count, distinct_order_count, invalid_path_count
  from public.report_photos
  where report_id = p_report_id;

  if metadata_count <> target_report.photo_count then
    return false;
  end if;

  if distinct_order_count <> target_report.photo_count then
    return false;
  end if;

  if invalid_path_count <> 0 then
    return false;
  end if;

  select count(distinct photos.id)::integer
  into object_count
  from public.report_photos as photos
  join storage.objects as objects
    on objects.bucket_id = photos.storage_bucket
   and objects.name = photos.storage_path
  where photos.report_id = p_report_id;

  return object_count = target_report.photo_count;
end;
$$;

revoke execute on function public.price_report_photo_integrity_ok(uuid) from public;
revoke execute on function public.price_report_photo_integrity_ok(uuid) from anon;
revoke execute on function public.price_report_photo_integrity_ok(uuid) from authenticated;

create or replace function public.update_price_report_upload_status(
  p_report_id uuid,
  p_upload_status text
)
returns public.price_reports
language plpgsql
security definer
set search_path = public
as $$
declare
  target_report public.price_reports;
  next_status text;
  updated_report public.price_reports;
begin
  if p_report_id is null then
    raise exception '업로드 상태를 바꿀 제보를 선택해주세요.';
  end if;

  next_status := nullif(trim(coalesce(p_upload_status, '')), '');

  if next_status not in ('uploaded', 'upload_failed') then
    raise exception '허용되지 않은 업로드 상태입니다: %', coalesce(next_status, 'null');
  end if;

  select *
  into target_report
  from public.price_reports
  where id = p_report_id
  for update;

  if target_report.id is null then
    raise exception '가격 제보를 찾지 못했습니다.';
  end if;

  if target_report.report_status <> 'pending' then
    raise exception '검수 전 제보만 업로드 상태를 변경할 수 있습니다.';
  end if;

  if auth.uid() is not null then
    if target_report.user_id is distinct from auth.uid() then
      raise exception '본인 제보의 업로드 상태만 변경할 수 있습니다.';
    end if;
  else
    if target_report.user_id is not null then
      raise exception '로그인 제보는 로그인 상태에서만 업로드 상태를 변경할 수 있습니다.';
    end if;
  end if;

  if next_status = 'uploaded' and not public.price_report_photo_integrity_ok(target_report.id) then
    raise exception '첨부 사진 파일과 metadata가 일치하지 않아 업로드 완료 처리할 수 없습니다.';
  end if;

  if target_report.upload_status = 'uploaded' then
    return target_report;
  end if;

  update public.price_reports
  set upload_status = next_status
  where id = target_report.id
  returning * into updated_report;

  return updated_report;
end;
$$;

revoke execute on function public.update_price_report_upload_status(uuid, text) from public;
grant execute on function public.update_price_report_upload_status(uuid, text) to anon;
grant execute on function public.update_price_report_upload_status(uuid, text) to authenticated;

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

  if target_report.upload_status <> 'uploaded' then
    raise exception '사진 업로드가 완료된 제보만 승인할 수 있습니다. 현재 상태: %', target_report.upload_status;
  end if;

  if not public.price_report_photo_integrity_ok(target_report.id) then
    raise exception '첨부 사진 파일과 metadata가 일치하지 않아 승인할 수 없습니다.';
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

revoke execute on function public.approve_price_report(uuid, text) from public;
revoke execute on function public.approve_price_report(uuid, text) from anon;
grant execute on function public.approve_price_report(uuid, text) to authenticated;

-- 적용 후 핵심 확인:
-- 1. 로그인 사용자가 user_id null로 제보 insert 시 실패해야 합니다.
-- 2. 실제 storage.objects가 없는 report_photos metadata insert는 실패해야 합니다.
-- 3. 관리자 직접 update로 report_status = approved 변경은 실패해야 합니다.
-- 4. uploaded 전환과 approve_price_report는 사진 개수/path/object 정합성이 맞아야 성공해야 합니다.
