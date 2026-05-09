# PROJECT_ARCHITECTURE

## iOS SwiftUI 구조

- `ContentView.swift`
  - 앱 탭 구조: 탐색, 지도, 청년, 벼룩, MY
  - Auth, Supabase REST Repository, 지도/탐색/상세/MY/제보/관리자 UI 대부분 포함
  - `AppEnvironment.showsInternalTools = false`로 내부 QA UI 숨김
- `JjantechMapRunner/ChallengeView.swift`
  - 1억 챌린지 화면
  - `ChallengeViewModel`
  - `ChallengeRepository`
  - `VisitSavingSheet`, `ChallengeSummaryCard`, `GradeShareCardView`
- `JjantechMapRunner/AppMain.swift`
  - 앱 엔트리
- `JjantechMapRunner/Info.plist`
  - Supabase/Naver 설정 키 참조

## 주요 View/ViewModel/Service

| 영역 | 주요 타입 |
|---|---|
| Auth | `AuthManager`, `SupabaseAuthRepository`, `KeychainStore` |
| 장소 | `PlacesViewModel`, `SupabasePlacesRepository` |
| 지도 | `MapExploreView`, `NaverPriceMapView`, `RealNaverPriceMapView` |
| 상세 | `PlaceDetailView`, `PlaceDetailMenuPage`, `VisitSavingSheet` |
| 제보 | `PriceReportView`, `PriceReportRepository` |
| MY | `MyPageView`, `ProfileViewModel`, `MyReportsViewModel` |
| 관리자 | `AdminReviewViewModel`, `AdminReviewRepository`, `AdminReviewCard` |
| 포인트 | `PointTransactionsViewModel`, `PointTransactionsRepository` |
| 즐겨찾기 | `FavoritesViewModel`, `FavoritesRepository` |
| 알림 | `PriceAlertSettingsViewModel`, `PriceAlertEventsViewModel` |
| 챌린지 | `ChallengeViewModel`, `ChallengeRepository` |

## Supabase 구조

마지막 migration: `032_harden_report_photo_integrity.sql`

주요 테이블:

- `places`
- `menus`
- `profiles`
- `price_reports`
- `report_photos`
- `app_admins`
- `price_report_review_logs`
- `point_transactions`
- `favorite_places`
- `price_alert_settings`
- `price_alert_events`
- `savings_logs`

주요 RPC:

- `approve_price_report`
- `reject_price_report`
- `apply_approved_report_to_price_catalog`
- `apply_approved_report_to_challenge`
- `get_report_pipeline_audit`
- `repair_report_pipeline`
- `update_price_report_upload_status`
- `insert_report_photo_metadata`
- `mark_price_alert_event_read`
- `get_challenge_summary`
- `log_saving`
- `cancel_saving_log`
- `sync_challenge_savings`
- `update_my_profile_display_name`

## 데이터 흐름

### 장소 탐색

앱 실행 → `places?select=*,menus(*)` → 장소/메뉴 표시 → 지도 마커/리스트/상세 공유

### 가격 제보

사용자 입력 → `price_reports` insert(`upload_status = pending_upload`) → Storage 사진 업로드 → `insert_report_photo_metadata` RPC로 metadata 검증/저장 → `update_price_report_upload_status(..., uploaded)` → 관리자 pending 검수

사진 업로드 또는 metadata 저장 실패 시 `update_price_report_upload_status(..., upload_failed)`로 전환해 불완전한 제보가 운영자 검수 큐에 올라가지 않도록 한다. 운영자 pending 조회 대상은 `upload_status = uploaded` 조건을 포함한다. `031` 이후에는 `approve_price_report`도 업로드 완료 상태와 사진 metadata 개수를 다시 검사하고, `032` 이후에는 metadata와 실제 Storage object의 path/개수/display_order 정합성까지 검사한다.

### 관리자 승인

`approve_price_report` → 가격표 반영 → 포인트 장부 생성 → 가격 알림 이벤트 생성 → 챌린지 절약 로그 연결

### 1억 챌린지

장소 상세 방문 완료 → `log_saving` RPC → `savings_logs` insert → `sync_challenge_savings` → MY/ChallengeView 갱신

## 보안 구조

- anon/publishable key는 클라이언트 가능, RLS로 보호
- `service_role`은 클라이언트 금지
- 일반 사용자의 `places`, `menus`, `savings_logs` 직접 쓰기 제한은 `028`에서 강화
- 내부 보조 RPC 직접 실행 권한은 `028`, `029`에서 제한
- 가격 제보 업로드 상태 변경은 `030`의 `update_price_report_upload_status` RPC에서 검수 전 `pending` 제보와 본인 제보 중심으로 제한
- `031` 이후 신규 제보 insert는 기본적으로 `pending_upload`로 시작하고, 관리자 승인은 `uploaded` 상태와 사진 metadata 정합성이 맞는 제보만 통과한다
- `032` 이후 일반 사용자의 관리자 직접 update 우회와 로그인 사용자의 익명 제보 우회를 차단한다. 사진 metadata는 직접 insert하지 않고 `insert_report_photo_metadata` RPC가 실제 Storage object 존재 여부를 확인한 뒤 저장한다
