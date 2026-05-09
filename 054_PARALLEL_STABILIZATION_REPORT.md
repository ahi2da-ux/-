# 054 병렬 안정화 작업 보고서

## 목표

짠테크맵 MVP를 신규 기능 추가가 아니라 베타 운영 가능한 수준으로 안정화한다.

현재 기준 핵심 병목은 QA 계정 로그인 `invalid_credentials`, Supabase RPC/RLS 안전성, 가격 제보 승인 파이프라인의 반복 실행 안정성이다.

## 병렬 분석 결과 요약

### 1. Auth/Supabase

- 앱의 로그인 구현은 Supabase Auth REST API의 password grant 흐름을 사용한다.
- `invalid_credentials`의 1순위 원인은 앱 코드보다 Supabase Authentication 유저 상태다.
- 사용자가 Supabase Dashboard에서 확인해야 할 항목:
  - `Authentication > Users`에 QA 이메일 사용자가 존재하는지
  - Confirmed 상태인지
  - 비밀번호가 앱에서 입력한 값과 같은지
  - 같은 Supabase 프로젝트를 바라보고 있는지
  - Auth Logs에서 실제 에러가 `invalid_credentials`인지 확인
- 코드 개선 필요:
  - 로그인 이메일 trim
  - QA 샘플값/비밀번호/진단 UI를 베타 사용자 화면에서 숨기기

### 2. Data/RPC

- 가격 제보 승인 흐름은 가격표, 포인트, 알림, 1억 챌린지까지 연결되어 있다.
- P0에 가까운 문제:
  - `cancel_saving_log` DB 반환형이 iOS `ChallengeSummary`와 맞지 않는다.
  - `apply_approved_report_to_price_catalog`가 반복 실행되면 `receipt_count`가 계속 부풀 수 있다.
  - `apply_approved_report_to_challenge`는 `savings_log_id`만 보고 조기 종료해서, 실제 로그가 삭제/취소/불일치 상태일 때 복구가 약하다.

### 3. Security/RLS

- 일반 사용자가 `places`, `menus`, `savings_logs`를 직접 조작할 수 있는 여지를 줄여야 한다.
- 내부 보조 RPC는 사용자가 직접 호출하지 못하게 닫고, 관리자 승인/복구 RPC 내부에서만 쓰도록 제한해야 한다.

## 이번에 준비한 파일

### 028_harden_release_security.sql

위치:

`supabase/migrations/028_harden_release_security.sql`

역할:

- 일반 로그인 사용자의 `places`, `menus` 직접 쓰기 차단
- `savings_logs` 직접 insert 차단
- 내부 보조 RPC 직접 호출 권한 회수
- `log_saving` RPC 금액/장소/메뉴/중복 검증 강화

중요 보정:

- 기존 `log_saving`과 반환형이 달라 `create or replace`만 쓰면 실패할 수 있어, 기존 함수를 drop 후 재생성하도록 수정했다.

### 029_harden_challenge_and_report_pipeline.sql

위치:

`supabase/migrations/029_harden_challenge_and_report_pipeline.sql`

역할:

- `cancel_saving_log` 반환형을 iOS `ChallengeSummary`와 맞춤
- 승인 가격표 반영 RPC를 반복 실행해도 `receipt_count`가 부풀지 않게 보정
- 승인 제보와 챌린지 로그 연결이 끊기거나 취소된 경우에도 복구 가능하게 보강

## 사용자가 지금 실행해야 할 순서

1. Supabase Dashboard 접속
2. SQL Editor 열기
3. `028_harden_release_security.sql` 전체 실행
4. 성공하면 `029_harden_challenge_and_report_pipeline.sql` 전체 실행
5. 둘 다 성공하면 앱에서 QA 계정 로그인 재시도

## 실행 후 검증할 것

### Supabase

- `places`, `menus`에 일반 authenticated write 정책이 제거되었는지 확인
- `savings_logs_self_insert` 정책이 제거되었는지 확인
- `log_saving`, `cancel_saving_log`가 authenticated만 실행 가능한지 확인
- 승인/복구 RPC가 정상 실행되는지 확인

### iOS 앱

- QA 계정 로그인 성공 여부
- 장소 상세에서 절약 기록 저장
- 1억 챌린지 누적 금액 증가
- 절약 기록 취소 후 앱이 디코딩 에러 없이 요약을 갱신하는지
- 가격 제보 승인 후 포인트/알림/챌린지 반영 여부

## 현재 MVP 완성도 판단

- 작업 전: 약 87%
- 028/029 SQL 실행 전 준비 상태: 약 88%
- 028/029 실행 성공 + QA 로그인 성공 시: 약 90%
- 실제 가격 제보 승인 E2E QA 통과 시: 약 92%

## 다음 우선순위

1. 사용자가 028, 029 SQL 실행
2. QA 계정 로그인 성공 확인
3. 앱 내부 QA/운영자 UI를 일반 사용자 화면에서 숨기기
4. 가격 제보 제출/승인/포인트/알림/챌린지 E2E 검증
5. 베타 운영 문서와 개인정보/사진 업로드 정책 최종 정리
