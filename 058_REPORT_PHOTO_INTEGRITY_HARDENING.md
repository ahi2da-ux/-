# 058_REPORT_PHOTO_INTEGRITY_HARDENING

## 목적

가격 제보 승인 파이프라인에서 사진 metadata만으로 업로드 완료/승인을 판단하는 위험을 줄인다.

## 변경 파일

- `supabase/migrations/032_harden_report_photo_integrity.sql`

## 주요 보강

- 로그인 사용자가 `user_id = null`로 익명 제보를 넣어 계정 제한을 우회하지 못하게 함
- Storage 업로드 path를 `price_reports/{report_id}/{uuid}.jpg` 구조로 제한
- `report_photos` 직접 insert를 닫고 `insert_report_photo_metadata` RPC에서 실제 `storage.objects` 존재 여부 확인
- 운영자 직접 `UPDATE price_reports SET report_status = 'approved'` 우회 차단
- `update_price_report_upload_status`와 `approve_price_report`에서 사진 개수, `display_order`, path, 실제 object 존재를 모두 검증

## 실행 순서

Supabase SQL Editor에서 아래 순서대로 실행한다.

1. `028_harden_release_security.sql`
2. `029_harden_challenge_and_report_pipeline.sql`
3. `030_harden_price_report_upload_status.sql`
4. `031_enforce_uploaded_report_approval.sql`
5. `032_harden_report_photo_integrity.sql`

## 검증 기준

- 로그인 사용자가 `user_id = null`로 가격 제보 insert 시 실패
- 실제 Storage object 없이 `report_photos` metadata만 insert 시 실패
- 사진 개수와 metadata 개수가 다르면 `uploaded` 전환 실패
- 운영자 직접 update로 `approved` 변경 실패
- 정상 사진 업로드 후에는 기존 앱 제보 제출 흐름 성공

## 남은 리스크

- Supabase SQL Editor에서 실제 적용 확인 필요
- 정상 제보 1건과 실패 제보 1건으로 E2E 검증 필요
- `supabase/verification/001_verify_028_032_release_hardening.sql`로 적용 결과를 읽기 전용 확인해야 한다
