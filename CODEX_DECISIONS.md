# CODEX_DECISIONS

## 1. iOS 우선 개발

- 결정: iOS SwiftUI 앱을 먼저 완성한다.
- 이유: 현재 사용자 목표가 Xcode 실행 가능한 iOS 앱이고, 네이버 지도/Supabase 연결을 우선 검증해야 한다.
- 영향: Android/Web은 v2 이후 별도 로드맵.

## 2. 네이버 지도 SDK 사용

- 결정: Apple MapKit 대신 Naver Maps SDK를 사용한다.
- 이유: 한국 지도/장소 맥락에 적합하고, 네이버 지도 UI 벤치마킹이 제품 방향과 맞다.
- 영향: Naver Cloud Maps Dynamic Map 설정과 Bundle ID 등록 필요.

## 3. Supabase를 MVP 백엔드로 사용

- 결정: Supabase Auth/Postgres/Storage/RLS/RPC 사용.
- 이유: 빠른 MVP 구현, SQL 기반 검수 흐름, Storage 사진 업로드 구현이 가능하다.
- 영향: RLS/RPC 보안 관리가 중요해짐.

## 4. 가격 제보는 관리자 검수 후 반영

- 결정: 사용자가 직접 장소/메뉴 가격표를 수정하지 않는다.
- 이유: 허위 제보, 가격 오염, 포인트 부정 지급 방지.
- 영향: `approve_price_report`, `reject_price_report` 중심 운영 필요.

## 5. 1억 챌린지는 수동 절약 기록부터 시작

- 결정: 방문 완료/절약 기록 기반 핵심 루프부터 구현.
- 이유: MVP 68~89% 단계에서 자동 투자/금융 연동은 과함.
- 영향: “절약이 자산이 되는 순간” 리텐션 엔진으로 사용.

## 6. 내부 QA UI는 베타 사용자에게 숨김

- 결정: `AppEnvironment.showsInternalTools = false`.
- 이유: QA 보드, 시스템 상태, 샘플 계정 안내는 일반 사용자 경험과 보안에 부적합.
- 영향: 내부 점검 빌드가 필요하면 플래그를 명시적으로 바꿔야 함.

## 7. 기존 migration은 수정하지 않음

- 결정: DB 변경은 새 번호 migration만 사용.
- 이유: 실행 이력 보존과 롤백 추적.
- 영향: `028`, `029`처럼 보강 migration을 추가하는 방식 유지.

## 8. 비밀값은 문서/코드에 저장하지 않음

- 결정: password, token, service_role key 문서화 금지.
- 이유: 보안 사고 방지.
- 영향: QA 비밀번호도 코드에서 제거.
