# CODEX_WORK_LOG

## 요약

Codex는 짠테크맵을 HTML UI 참고 SwiftUI 목업에서 시작해, 네이버 지도 + Supabase + 가격 제보 + 포인트 + 1억 챌린지 기반의 iOS MVP로 확장했다.

## 주요 작업 내역

### 1. 초기 iOS 앱 구성

- `ContentView.swift` 단일 파일 기반 SwiftUI 앱 작성
- 하단 탭: 탐색, 지도, 청년, 벼룩, MY
- 탐색 리스트, 지도 탐색, 장소 상세, 가격 제보, MY 구현
- 청년/벼룩은 v2 빈 화면 유지

### 2. 네이버 지도 전환

- MapKit 목업에서 네이버 지도 SDK 기반 구조로 전환
- Naver Maps SPM 패키지 사용
- `NMFNcpKeyId` 기반 지도 렌더링
- 지도 마커, 가격 라벨, 카테고리 필터, 바텀시트 구현

### 3. Supabase 연동

- `supabase/migrations/001` ~ `032` 작성
- 장소/메뉴/프로필/제보/사진/관리자/포인트/즐겨찾기/알림/챌린지 스키마 구축
- RLS와 RPC 점진 보강

### 4. 가격 제보/관리자 검수

- 가격 제보 DB 저장
- 사진 첨부 및 Storage 업로드
- 관리자 pending 조회
- 승인/반려 RPC
- 승인 시 가격표, 포인트, 알림, 챌린지 연결 설계
- 가격 제보 사진 업로드 상태를 `pending_upload` → `uploaded`/`upload_failed`로 분리
- 운영자 pending 검수 큐가 `upload_status = uploaded` 제보만 대상으로 삼도록 보강

### 5. 1억 챌린지

- `ChallengeView.swift` 추가
- `get_challenge_summary`, `log_saving`, `cancel_saving_log` 연동
- MY 요약 카드
- 방문 완료/절약 기록
- 공유 카드 초안
- 게스트 체험 장부와 로그인 후 import 흐름

### 6. 안정화

- `028_harden_release_security.sql` 준비
- `029_harden_challenge_and_report_pipeline.sql` 준비
- `030_harden_price_report_upload_status.sql` 준비
- `031_enforce_uploaded_report_approval.sql` 준비
- `032_harden_report_photo_integrity.sql` 준비
- `supabase/verification/001_verify_028_032_release_hardening.sql` 준비
- 내부 QA UI 일반 화면 숨김
- QA 비밀번호 문자열 제거
- 로그인 이메일 trim 처리
- 인증 실패/가격 제보 실패 메시지를 사용자용 문구로 정리
- 익명 제보 성공 시 포인트 지급 문구가 나오지 않도록 분기
- 가격 제보 사진 metadata 저장을 직접 insert에서 `insert_report_photo_metadata` RPC 호출로 변경
- 1억 챌린지 체험 화면의 샘플 로그에 예시 배지를 추가하고, 체험 로그 취소 버튼을 숨겨 실제 기록과 혼동을 줄임
- 예전 QA 비밀번호 문자열 문서 제거
- iPhone 17 Pro Simulator 빌드/설치/실행 성공
- 현재 MVP 완성도는 로컬 코드/빌드/실행 기준 약 90%로 정리

## 검증 결과

- Xcode 빌드 성공
- Simulator 설치 성공
- Simulator 실행 성공
- SQL `028`, `029`, `030`, `031`, `032`는 파일 준비 완료, Supabase 적용 확인 필요

## 남은 이슈

- QA 계정 로그인 `invalid_credentials`
- Supabase `028` → `029` → `030` → `031` → `032` 순서 실제 실행 확인
- 가격 제보 승인 E2E 확인
- 사진 업로드 원자성 부족
- App Store/TestFlight 준비 부족
