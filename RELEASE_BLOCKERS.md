# RELEASE_BLOCKERS

## 베타 출시 차단 이슈

| ID | 심각도 | 문제 | 담당 에이전트 | 해결 기준 |
|---|---|---|---|---|
| RB-001 | P0 | QA 계정 로그인 `invalid_credentials` | Auth/Supabase | QA 계정으로 앱 로그인 성공 |
| RB-002 | P0 | SQL `028`, `029`, `030`, `031`, `032` 실제 적용 미확인 | Data/RPC, Security/RLS | Supabase SQL Editor 실행 성공 |
| RB-003 | P0 | 가격 제보 승인 E2E 미검증 | QA, Data/RPC | 제보→승인→가격표→포인트→알림→챌린지 통과 |
| RB-004 | P0 | RLS/RPC 권한 실제 DB 검증 필요 | Security/RLS | 일반 사용자가 카탈로그/장부 직접 조작 불가 |
| RB-005 | P1 | 사진 업로드 실패/미완료 제보 승인 차단 검증 필요 | iOS Flow, Data/RPC | 030/031/032 적용 후 실패 제보가 검수 큐와 승인 RPC에서 제외되는지 확인 |
| RB-006 | P1 | 실기기 카메라/앨범/GPS 권한 QA 부족 | QA | 실제 iPhone에서 권한/촬영/위치 확인 |
| RB-007 | P1 | 개인정보/사진 처리 정책 최종화 필요 | Ops/Policy | 베타 안내 문서 준비 |
| RB-008 | P1 | TestFlight/App Store 준비 부족 | Ops/Policy | Bundle ID, Team, App Icon, Privacy 준비 |

## 현재 최우선

1. `028_harden_release_security.sql` 실행
2. `029_harden_challenge_and_report_pipeline.sql` 실행
3. `030_harden_price_report_upload_status.sql` 실행
4. `031_enforce_uploaded_report_approval.sql` 실행
5. `032_harden_report_photo_integrity.sql` 실행
6. QA 계정 로그인 성공 확인
7. 가격 제보 승인 E2E QA

## 출시 가능 기준

- P0 전부 해결
- P1 중 개인정보/실기기 권한 관련 항목 해결
- 내부 QA UI 미노출 확인
- 실패 시 앱이 죽지 않고 사용자 안내 표시
