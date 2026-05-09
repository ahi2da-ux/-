# 056 가격 제보 업로드 상태 안정화 보고서

## 목표

가격 제보가 DB에는 생성됐지만 사진 업로드 또는 사진 metadata 저장이 중간에 실패하는 경우, 불완전한 제보가 운영자 검수 큐에 올라가지 않도록 막는다.

## 변경 파일

- `ContentView.swift`
- `supabase/migrations/030_harden_price_report_upload_status.sql`

## 변경 내용

### 1. 신규 migration 030 추가

파일:

`supabase/migrations/030_harden_price_report_upload_status.sql`

추가 RPC:

`update_price_report_upload_status(p_report_id uuid, p_upload_status text)`

역할:

- `pending_upload` 상태로 생성된 제보를 `uploaded` 또는 `upload_failed`로 전환한다.
- `uploaded` 전환 시 `report_photos` metadata 개수가 `price_reports.photo_count`보다 적으면 실패시킨다.
- 검수 전 `pending` 제보만 업로드 상태 변경을 허용한다.
- 로그인 사용자는 본인 제보만 변경할 수 있다.

### 2. 앱 제보 저장 흐름 변경

기존:

1. `price_reports` insert
2. 사진 Storage 업로드
3. `report_photos` metadata insert

문제:

- 2번 또는 3번에서 실패해도 `pending` 제보가 남을 수 있었다.

변경 후:

1. `price_reports`를 `upload_status = pending_upload`로 insert
2. 사진 Storage 업로드
3. `report_photos` metadata insert
4. 모두 성공하면 `update_price_report_upload_status(..., uploaded)` 호출
5. 중간 실패 시 `update_price_report_upload_status(..., upload_failed)` 호출

### 3. 운영자 검수 큐 보강

운영자 pending 조회에 아래 조건을 추가했다.

```text
upload_status = uploaded
```

이제 사진 업로드가 완료되지 않은 제보는 운영자가 승인할 수 있는 목록에 뜨지 않는다.

### 4. MY 제보 상태 문구 보정

앱에서 사용하는 업로드 상태값을 DB 값과 맞췄다.

- `uploaded`: 사진 업로드 완료
- `pending_upload`: 사진 업로드 중
- `upload_failed`: 사진 업로드 실패

## 검증 결과

### 빌드

명령:

```bash
xcodebuild -project JjantechMap.xcodeproj -scheme JjantechMap -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

결과:

- 성공
- 앱 코드 컴파일 오류 없음

### 실행

대상:

- iPhone 17 Pro Simulator

결과:

- 설치 성공
- 실행 성공
- 실행 프로세스 확인: `com.local.jjantechmap.runner`

## 적용 필요 사항

Supabase SQL Editor에서 다음 순서로 실행해야 DB까지 반영된다.

1. `028_harden_release_security.sql`
2. `029_harden_challenge_and_report_pipeline.sql`
3. `030_harden_price_report_upload_status.sql`

## 현재 MVP 완성도

- 로컬 코드 기준: 약 90%
- 028~030 Supabase 적용 + QA 로그인 성공 시 예상: 약 91%
- 가격 제보 승인 E2E 통과 시 예상: 약 92%

## 남은 리스크

- 030 SQL이 실제 Supabase에 아직 적용됐는지 확인 필요
- 익명 제보의 업로드 상태 변경은 사용자 식별이 약하므로 베타 이후 로그인 제보 중심으로 좁히는 것을 권장
- 사진 파일 Storage 업로드 후 metadata insert가 실패하면 Storage orphan 파일이 남을 수 있음
