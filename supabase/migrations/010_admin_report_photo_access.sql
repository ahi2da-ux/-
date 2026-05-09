-- 010_admin_report_photo_access.sql
-- 운영자가 가격 제보에 첨부된 영수증/인증 사진을 검수 화면에서 열람할 수 있게 합니다.
-- Storage bucket은 계속 private으로 유지하고, app_admins에 등록된 관리자만 읽을 수 있게 합니다.

drop policy if exists "report_photos_admin_read" on public.report_photos;

create policy "report_photos_admin_read"
on public.report_photos
for select
to authenticated
using (public.is_app_admin());

drop policy if exists "price_report_photos_admin_read" on storage.objects;

create policy "price_report_photos_admin_read"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'price-report-photos'
  and public.is_app_admin()
);

-- 운영자 사진 확인용 쿼리 예시
-- select
--   id,
--   report_id,
--   storage_bucket,
--   storage_path,
--   content_type,
--   file_size_bytes,
--   display_order,
--   created_at
-- from public.report_photos
-- where report_id = '여기에-price_reports-id'
-- order by display_order asc;
