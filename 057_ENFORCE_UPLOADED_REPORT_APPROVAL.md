# 057_ENFORCE_UPLOADED_REPORT_APPROVAL

## 목적

가격 제보 사진 업로드가 끝나지 않은 상태의 제보가 운영자 승인 RPC를 우회 호출해 승인되는 위험을 막는다.

## 변경 내용

- `031_enforce_uploaded_report_approval.sql` 추가
- 신규 `price_reports` insert는 `upload_status = 'pending_upload'` 상태로만 시작하도록 RLS insert 정책 강화
- `approve_price_report`가 승인 전에 아래 조건을 다시 확인하도록 보강
  - 제보 상태가 `pending`
  - 업로드 상태가 `uploaded`
  - `report_photos` metadata 개수가 `photo_count` 이상
- 업로드가 끝나지 않은 제보는 운영자 pending UI뿐 아니라 RPC 직접 호출에서도 승인 차단

## 실행 순서

Supabase SQL Editor에서 아래 순서대로 실행한다.

1. `028_harden_release_security.sql`
2. `029_harden_challenge_and_report_pipeline.sql`
3. `030_harden_price_report_upload_status.sql`
4. `031_enforce_uploaded_report_approval.sql`

## 검증 방법

1. 사진이 정상 업로드된 가격 제보를 제출한다.
2. 운영자 계정으로 pending 목록에 표시되는지 확인한다.
3. 승인 시 가격표, 포인트, 알림, 챌린지 반영을 확인한다.
4. 사진 업로드 실패 또는 metadata 부족 제보를 만든다.
5. 해당 제보가 pending 목록에 보이지 않고, `approve_price_report` 직접 호출도 실패하는지 확인한다.

## 남은 리스크

- 실제 Supabase 프로젝트에 `031` 적용이 아직 확인되지 않았다.
- QA 계정 로그인 문제가 해결되어야 앱 안에서 운영자 승인 E2E를 완전히 검증할 수 있다.
