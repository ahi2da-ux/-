-- 031_enforce_uploaded_report_approval.sql
-- 가격 제보 승인 전 사진 업로드 완료 상태를 DB/RPC 레벨에서 강제합니다.
-- 목표:
-- 1. price_reports 직접 insert 시 upload_status = pending_upload만 허용합니다.
-- 2. approve_price_report가 upload_status = uploaded와 report_photos 개수를 검증합니다.
-- 3. 운영자가 ID를 직접 넣어 승인해도 불완전한 제보는 승인되지 않게 합니다.

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
    user_id is null
    or auth.uid() = user_id
  )
);

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
  uploaded_photo_count integer;
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

  select count(*)::integer
  into uploaded_photo_count
  from public.report_photos
  where report_id = target_report.id;

  if uploaded_photo_count < target_report.photo_count then
    raise exception '첨부 사진 metadata가 부족해 승인할 수 없습니다. expected %, actual %',
      target_report.photo_count,
      uploaded_photo_count;
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

-- 적용 후 확인:
-- select policyname, cmd, roles, with_check
-- from pg_policies
-- where schemaname = 'public'
--   and tablename = 'price_reports'
--   and policyname = 'price_reports_public_insert';
--
-- select id, report_status, upload_status, photo_count
-- from public.price_reports
-- order by created_at desc
-- limit 20;
