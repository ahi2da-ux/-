# PROJECT_STATUS

## 기능별 완성도

| 기능 | 완성도 | 상태 |
|---|---:|---|
| 지도 기반 탐색 UI | 88% | 네이버 지도, 마커, 카테고리, 바텀시트 구현 |
| 탐색 리스트 | 84% | 검색/정렬/카드 UI 구현, 고급 검색은 부족 |
| 장소 상세 | 82% | 상세 탭, 메뉴, 리뷰, 가격 제보, 절약 기록 연결 |
| 로그인/인증 | 78% | Auth REST, Keychain 세션, 재설정 구현. QA 계정 상태 병목 |
| Supabase DB | 92% | 001~032 migration 및 028~032 검증 SQL 준비. 실제 실행 확인 필요 |
| 가격 제보 | 88% | DB 저장, 사진 업로드, EXIF 제거, 중복 방지, 업로드 상태 분리, 사진 파일/metadata 정합성 RPC 연동 |
| 관리자 검수 | 80% | 승인/반려/사진 검수/복구 RPC. 032 적용 후 E2E 검증 필요 |
| 포인트 장부 | 78% | 승인 보상 장부 연결. 실데이터 검증 필요 |
| 즐겨찾기 | 80% | 저장/삭제/조회 구현 |
| 가격 알림 | 62% | 인앱 이벤트 중심. APNs 미구현 |
| 1억 챌린지 | 84% | 요약/기록/취소/공유 카드, 체험 화면 구분 UX 보강. SQL 적용/E2E 필요 |
| MY 탭 | 76% | 요약 카드 다수. 베타 UX 정리 필요 |
| 청년/벼룩 v2 | 10% | 빈 화면 |
| QA/테스트 자동화 | 25% | 수동 QA 문서 중심 |

## 최근 검증 결과

- `xcodebuild -project JjantechMap.xcodeproj -scheme JjantechMap -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` 성공
- iPhone 17 Pro Simulator 설치 성공
- Bundle ID `com.local.jjantechmap.runner` 실행 성공
- `032_harden_report_photo_integrity.sql`와 `insert_report_photo_metadata` RPC 연동 후 재빌드/재설치/재실행 성공
- 최신 실행 프로세스: `com.local.jjantechmap.runner: 27240`
- 네이버 지도 SDK 내부 iOS 26 deprecation warning만 확인

## 미완성 영역

- QA 계정 로그인 성공 확인
- SQL `028`, `029`, `030`, `031`, `032` Supabase 실제 적용 확인
- `supabase/verification/001_verify_028_032_release_hardening.sql` 실행 결과 확인
- 가격 제보 승인 후 포인트/알림/챌린지 반영 E2E
- 030/031/032 적용 후 사진 업로드 실패 제보가 운영자 검수 큐와 승인 RPC에서 제외되는지 확인
- App Store 배포용 bundle id/team/privacy/app icon 정리
- 실기기 GPS/카메라/앨범 권한 테스트

## 베타 전 필수 조건

1. QA 계정 로그인 성공
2. 장소 조회가 Supabase DB 기준으로 정상 표시
3. 가격 제보 제출/사진 업로드 성공
4. 관리자 승인/반려 성공, 단 사진 업로드 완료 제보만 승인 가능
5. 승인 후 포인트/알림/챌린지 정합성 확인
6. 내부 QA UI 일반 사용자 노출 없음
7. 개인정보/사진 업로드 정책 문서 준비
