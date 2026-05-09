-- 030_harden_price_report_upload_status.sql
-- 가격 제보 사진 업로드 중간 실패를 운영 검수 큐에서 분리합니다.
-- 목표:
-- 1. 앱은 price_reports를 pending_upload 상태로 먼저 생성합니다.
-- 2. 모든 사진 파일과 report_photos metadata 저장이 끝난 뒤 uploaded로 전환합니다.
-- 3. 업로드 실패 시 upload_failed로 전환해 운영자가 불완전한 제보를 승인하지 않게 합니다.

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
  uploaded_photo_count integer;
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

  if target_report.upload_status = 'uploaded' then
    return target_report;
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

  if next_status = 'uploaded' then
    select count(*)::integer
    into uploaded_photo_count
    from public.report_photos
    where report_id = target_report.id;

    if uploaded_photo_count < target_report.photo_count then
      raise exception '첨부 사진 metadata가 부족해 업로드 완료 처리할 수 없습니다.';
    end if;
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

-- 운영자 검수 큐는 report_status = pending 이면서 upload_status = uploaded 인 제보만 대상으로 삼아야 합니다.
-- 적용 후 확인:
-- select id, report_status, upload_status, photo_count
-- from public.price_reports
-- order by created_at desc
-- limit 20;
