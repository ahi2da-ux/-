-- 001_verify_028_032_release_hardening.sql
-- 028~032 보안 마이그레이션 적용 후 Supabase SQL Editor에서 읽기 전용으로 확인하는 점검 쿼리입니다.

-- 1. 최신 핵심 함수 존재 확인
select
  routine_name,
  security_type
from information_schema.routines
where routine_schema = 'public'
  and routine_name in (
    'update_price_report_upload_status',
    'insert_report_photo_metadata',
    'price_report_photo_integrity_ok',
    'approve_price_report',
    'log_saving',
    'cancel_saving_log'
  )
order by routine_name;

-- 2. 일반 사용자의 직접 update/insert 우회 정책이 닫혔는지 확인
-- 기대: price_reports_admin_update, report_photos_public_insert는 결과에 나오면 안 됩니다.
select
  schemaname,
  tablename,
  policyname,
  cmd,
  roles
from pg_policies
where schemaname = 'public'
  and (
    (tablename = 'price_reports' and policyname = 'price_reports_admin_update')
    or (tablename = 'report_photos' and policyname = 'report_photos_public_insert')
  )
order by tablename, policyname;

-- 3. 가격 제보 insert 정책 확인
select
  policyname,
  cmd,
  roles,
  with_check
from pg_policies
where schemaname = 'public'
  and tablename = 'price_reports'
  and policyname = 'price_reports_public_insert';

-- 4. Storage 업로드 정책 확인
select
  policyname,
  cmd,
  roles,
  with_check
from pg_policies
where schemaname = 'storage'
  and tablename = 'objects'
  and policyname = 'price_report_photos_public_upload';

-- 5. 최근 제보 업로드 상태 분포 확인
select
  upload_status,
  report_status,
  count(*) as report_count
from public.price_reports
group by upload_status, report_status
order by upload_status, report_status;

-- 6. 사진 metadata와 실제 Storage object가 맞지 않는 제보 확인
-- 기대: 베타 출시 전에는 mismatch_count가 0이어야 합니다.
with photo_counts as (
  select
    reports.id,
    reports.photo_count,
    count(photos.id) as metadata_count,
    count(objects.id) as object_count
  from public.price_reports as reports
  left join public.report_photos as photos
    on photos.report_id = reports.id
  left join storage.objects as objects
    on objects.bucket_id = photos.storage_bucket
   and objects.name = photos.storage_path
  group by reports.id, reports.photo_count
)
select
  count(*) as mismatch_count
from photo_counts
where metadata_count <> photo_count
   or object_count <> photo_count;

-- 7. 가격 제보 승인 파이프라인 결과 확인용 최근 데이터
select
  id,
  user_id,
  menu_name,
  reported_price,
  photo_count,
  upload_status,
  report_status,
  reviewed_at,
  point_granted_at,
  created_at
from public.price_reports
order by created_at desc
limit 20;
