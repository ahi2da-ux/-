# 짠테크맵 Supabase 마이그레이션 가이드

이 폴더는 짠테크맵 iOS 앱의 목업 데이터를 Supabase DB로 옮기기 위한 SQL 파일을 모아둔 곳입니다.

## 프로젝트 정보

- Supabase Project URL: `https://wfznjcfurcsqdsanmmbr.supabase.co`
- REST API Base URL: `https://wfznjcfurcsqdsanmmbr.supabase.co/rest/v1`
- Project Ref: `wfznjcfurcsqdsanmmbr`

> 주의: iOS 앱 연동에는 `anon public key`가 추가로 필요합니다. `service_role` 키는 앱에 절대 넣으면 안 됩니다.

## 실행 순서

Supabase 대시보드의 SQL Editor에서 아래 파일을 순서대로 실행하세요.

1. `001_create_places_table.sql`
2. `002_create_menus_table.sql`
3. `003_seed_initial_places.sql`
4. `004_setup_rls_public_read.sql`
5. `005_create_price_reports_table.sql`
6. `006_create_report_photos_storage.sql`
7. `007_create_profiles_and_auth_reports.sql`
8. `008_setup_report_review_workflow.sql`
9. `009_admin_review_helper.sql`
10. `010_admin_report_photo_access.sql`
11. `011_harden_review_idempotency.sql`
12. `012_harden_profile_write_access.sql`
13. `013_create_point_transactions.sql`
14. `014_create_favorite_places.sql`
15. `015_create_price_alert_settings.sql`
16. `016_create_price_alert_events.sql`
17. `017_harden_price_alert_event_read_rpc.sql`
18. `018_apply_approved_report_to_menu_prices.sql`
19. `019_prevent_duplicate_price_reports.sql`
20. `020_challenge.sql`
21. `021_add_menu_reference_price.sql`
22. `022_harden_challenge_saving_logs.sql`
23. `023_add_savings_log_cancel_rpc.sql`
24. `024_sync_challenge_savings_summary.sql`
25. `025_link_approved_reports_to_challenge.sql`
26. `026_create_report_pipeline_audit_rpc.sql`
27. `027_create_report_pipeline_repair_rpc.sql`
28. `028_harden_release_security.sql`
29. `029_harden_challenge_and_report_pipeline.sql`
30. `030_harden_price_report_upload_status.sql`
31. `031_enforce_uploaded_report_approval.sql`
32. `032_harden_report_photo_integrity.sql`

순서를 지켜야 합니다. `menus` 테이블은 `places` 테이블을 참조하기 때문에 `001` 다음에 `002`가 실행되어야 합니다.
`price_reports` 테이블은 `places`를 참조하므로 `001`부터 `004`까지 끝난 뒤 `005`를 실행해야 합니다.
`report_photos` 테이블과 Storage bucket은 `price_reports`를 참조하므로 `006`은 `005` 다음에 실행해야 합니다.
`profiles`와 사용자별 제보 조회 정책은 Supabase Auth를 사용하므로 `007`은 `006` 다음에 실행해야 합니다.
운영자 검수 권한과 승인/반려 기록은 `price_reports`, `profiles`, Supabase Auth를 모두 전제로 하므로 `008`은 `007` 다음에 실행해야 합니다.
운영자 승인/반려 헬퍼 함수는 `app_admins`와 검수 컬럼을 전제로 하므로 `009`는 `008` 다음에 실행해야 합니다.
운영자 영수증/인증 사진 열람 정책은 `app_admins`, `report_photos`, Storage bucket을 전제로 하므로 `010`은 `009` 다음에 실행해야 합니다.
포인트 중복 지급 방지와 운영자 검수 이력 저장은 승인/반려 함수가 있어야 하므로 `011`은 `010` 다음에 실행해야 합니다.
프로필 쓰기 권한 축소는 `profiles`와 승인/반려 함수 구조를 전제로 하므로 `012`는 `011` 다음에 실행해야 합니다.
포인트 적립 이력 장부는 `profiles`, `price_reports`, 승인 함수 구조를 전제로 하므로 `013`은 `012` 다음에 실행해야 합니다.
즐겨찾기 테이블은 `places`와 Supabase Auth 사용자를 전제로 하므로 `014`는 `013` 다음에 실행해야 합니다.
가격 알림 설정은 `favorite_places`, `places`, Supabase Auth 사용자를 전제로 하므로 `015`는 `014` 다음에 실행해야 합니다.
가격 알림 이벤트는 `price_alert_settings`, `price_reports`, 승인 함수 구조를 전제로 하므로 `016`은 `015` 다음에 실행해야 합니다.
가격 알림 읽음 처리 보안 강화는 `price_alert_events`를 전제로 하므로 `017`은 `016` 다음에 실행해야 합니다.
승인된 가격 제보의 실제 가격표 반영은 `menus`, `places`, `price_reports`, 승인 함수 구조를 전제로 하므로 `018`은 `017` 다음에 실행해야 합니다.
가격 제보 중복/스팸 방지는 `price_reports`와 사용자 인증 연결을 전제로 하므로 `019`는 `018` 다음에 실행해야 합니다.
1억 챌린지 기본 스키마는 `020`에서 추가되고, 메뉴별 기준가는 `021`에서 추가합니다.
절약 로그 보안과 취소/요약 동기화는 `022`부터 `024`까지 순서대로 적용해야 합니다.
가격 제보 승인과 1억 챌린지 연결은 `025` 이후 동작하며, 운영 점검/복구 RPC는 `026`, `027`에서 추가됩니다.
베타 전 보안 강화는 `028`, `029`, `030`, `031`, `032` 순서로 적용합니다. 특히 `030`은 사진 업로드 상태 RPC, `031`은 업로드 완료 전 승인 차단, `032`는 실제 Storage object와 사진 metadata 정합성 검증을 담당합니다.
적용 후에는 `supabase/verification/001_verify_028_032_release_hardening.sql`을 SQL Editor에서 실행해 정책, 함수, 최근 제보 상태를 확인하세요.

## 운영자 등록과 가격 제보 검수 방법

`009_admin_review_helper.sql` 실행 후에는 아래 순서로 가격 제보를 검수할 수 있습니다.

### 1. 운영자 계정 만들기

앱의 `MY` 탭에서 실제 이메일로 회원가입하고, 이메일 인증까지 완료합니다.

### 2. 운영자 User UID 복사하기

Supabase Dashboard에서 아래 경로로 이동합니다.

1. Authentication
2. Users
3. 운영자로 사용할 계정 클릭
4. `User UID` 복사

### 3. 운영자 등록하기

Supabase SQL Editor에서 아래 SQL을 실행합니다.

```sql
insert into public.app_admins (user_id, role)
values ('여기에-복사한-User-UID', 'owner')
on conflict (user_id) do update set role = excluded.role;
```

### 4. 검수 대기 제보 확인하기

```sql
select
  id,
  user_id,
  menu_name,
  reported_price,
  photo_count,
  created_at
from public.price_reports
where report_status = 'pending'
order by created_at asc;
```

### 5. 가격 제보 승인하기

```sql
select public.approve_price_report(
  '여기에-price_reports-id',
  '영수증 가격과 메뉴명이 확인되어 승인합니다.'
);
```

### 6. 가격 제보 반려하기

```sql
select public.reject_price_report(
  '여기에-price_reports-id',
  '영수증 사진이 흐려 가격 확인이 어렵습니다.',
  '사용자에게 선명한 사진 재제보를 안내합니다.'
);
```

## 현재 들어가는 초기 데이터

현재 앱 코드에서 확인된 `Place.mock` 기준으로 장소 7건과 메뉴 21건을 넣습니다.

- 합정 칼국수
- 동네 백반집
- 샐러드공장
- 마포 순대국
- 망원 동네카페
- 홍대 컷트샵
- 합정 게스트하우스

초기 계획에는 8건이라고 적혀 있었지만, 현재 `ContentView.swift`에서 확인된 목업 장소는 7건입니다. 8번째 장소가 추가되면 다음 마이그레이션 파일인 `005_seed_more_places.sql`로 안전하게 추가하면 됩니다.

## Supabase CLI로 실행하는 방법

SQL Editor가 더 쉽지만, 나중에 개발이 익숙해지면 CLI 방식도 사용할 수 있습니다.

```bash
supabase login
supabase link --project-ref wfznjcfurcsqdsanmmbr
supabase db push
```

## 보안 원칙

- `anon public key`는 클라이언트 앱에 들어갈 수 있지만, 반드시 RLS 정책으로 보호해야 합니다.
- `service_role` 키는 서버 전용입니다. iOS, Android, 웹 프론트엔드에 넣으면 안 됩니다.
- 현재 RLS는 v0.1 개발용으로 `읽기: 모두 허용`, `쓰기: 로그인 사용자 허용`입니다.
- 운영 단계에서는 가격 제보, 장소 수정, 메뉴 수정은 일반 사용자가 직접 테이블을 쓰지 않고 Edge Function 또는 관리자 검수 흐름을 거치도록 좁히는 것이 안전합니다.
- 향후 영수증/인증사진 업로드 전에는 EXIF 위치 정보와 기기 정보를 제거해야 합니다.
- `price_reports`는 v0.1에서 insert만 공개 허용하고, 공개 조회는 막아둡니다. 사용자가 보낸 제보는 검수 전 운영 데이터이기 때문입니다.
- `price-report-photos` bucket은 private bucket입니다. 익명 사용자는 업로드만 가능하고 공개 조회는 막습니다.
- `007` 이후 로그인 사용자는 본인 프로필과 본인 가격 제보만 조회할 수 있습니다.
- `008` 이후 가격 제보 승인/반려는 `app_admins`에 등록된 관리자만 수행할 수 있습니다.
- 관리자는 앱 화면에서 임의로 만들어지지 않습니다. Supabase SQL Editor에서 직접 `app_admins`에 사용자 ID를 넣어야 합니다.
- `010` 이후 운영자는 private Storage에 저장된 가격 제보 사진을 검수 목적으로 열람할 수 있습니다.
- `011` 이후 이미 승인/반려된 제보는 다시 처리할 수 없습니다. 같은 제보로 포인트가 중복 지급되는 일을 막습니다.
- `012` 이후 일반 사용자는 `profiles` 테이블을 직접 update할 수 없습니다. 닉네임 변경은 `update_my_profile_display_name` RPC만 사용하고, 포인트와 제보 통계는 운영자 검수 함수만 변경합니다.
- `013` 이후 포인트 잔액뿐 아니라 적립 이력도 `point_transactions`에 남습니다. 사용자는 본인 이력만 조회하고, 운영자는 전체 이력을 조회할 수 있습니다.
- `014` 이후 로그인 사용자는 관심 가게를 즐겨찾기로 저장할 수 있습니다. 즐겨찾기는 본인만 조회/추가/삭제할 수 있습니다.
- `015` 이후 로그인 사용자는 즐겨찾기 장소별 가격 알림 설정을 저장할 수 있습니다. 실제 푸시 발송은 다음 단계에서 APNs/Edge Function과 연결합니다.
- `016` 이후 가격 제보가 승인될 때 목표 가격 조건을 만족하면 사용자별 인앱 알림 이벤트가 생성됩니다. APNs 푸시 토큰 저장 전 단계로, 개인정보 부담을 줄인 채 알림 로직을 검증할 수 있습니다.
- `017` 이후 사용자는 알림 테이블을 직접 수정하지 않고 `mark_price_alert_event_read` RPC로 본인 알림을 읽음 처리만 할 수 있습니다. 알림 제목, 메시지, 가격 같은 운영 데이터는 클라이언트가 변경할 수 없습니다.
- `018` 이후 운영자가 가격 제보를 승인하면 해당 메뉴 가격이 `menus`에 반영되고, 장소 대표 가격 `places.base_price`도 메뉴 최저가로 자동 갱신됩니다. 앱은 기존 장소 조회만 새로고침해도 지도 마커 가격이 바뀝니다.
- `019` 이후 로그인 사용자는 같은 장소의 같은 메뉴를 24시간 안에 반복 제보할 수 없고, 24시간 최대 10건까지만 제보할 수 있습니다. 익명 제보는 같은 장소/메뉴/가격의 10분 내 반복 입력을 막습니다.
