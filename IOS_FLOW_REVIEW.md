# IOS_FLOW_REVIEW

> 분석 대상: `ContentView.swift` (9,678줄) + `ChallengeView.swift` (1,474줄)
> 분석 일시: 2026-05-09

---

## 1. 현재 iOS 흐름 요약

- **아키텍처**: 단일 `ContentView.swift`에 모든 View/ViewModel/Repository/Model이 집중 (모놀리식)
- **탭 구조**: 탐색 → 지도 → 청년(v2) → 벼룩(v2) → MY (5탭)
- **인증**: `AuthManager` (ObservableObject) → Keychain 저장 → `SupabaseAuthRepository` 호출
- **상태 관리**: `@EnvironmentObject`로 `authManager`, `placesViewModel`, `favoritesViewModel`, `challengeViewModel` 4개 공유
- **세션 복원**: 앱 시작 시 `restoreSession()` → 만료 시 `refreshSessionIfNeeded()` → 실패 시 세션 nil + 메시지
- **데이터 흐름**: 로그인 성공 → `onChange(of: authManager.session?.userID)` → favorites/challenge 자동 로드
- **비로그인 대응**: 대부분의 카드가 `isSignedIn` 분기로 Guest 안내 또는 체험 모드 제공

---

## 2. 베타 전에 반드시 확인할 화면

| 화면 | 확인할 것 | 위험도 |
|---|---|---|
| **MY 탭 로그인 폼** | QA 계정 생성 + Confirm 후 실제 로그인 성공 여부 | 🔴 높음 |
| **로그인 직후 MY 탭** | profile/points/challenge/favorites/reports 동시 로드 성공 여부 | 🔴 높음 |
| **PlaceDetailView 방문완료** | 로그인 시 `VisitSavingSheet`, 비로그인 시 `VisitSavingPreviewSheet` 분기 정상 작동 | 🟡 중간 |
| **VisitSavingSheet 기록** | `log_saving` RPC 호출 → 성공 시 dismiss + toast, 실패 시 message 표시 | 🟡 중간 |
| **ChallengeView 진입** | session 필수 → 로그인 상태에서만 NavigationLink 활성화 확인 | 🟡 중간 |
| **가격 제보 (PriceReportView)** | 사진 1장 이상 필수 → 카메라/앨범 → 제출 → alert 표시 | 🟡 중간 |
| **세션 만료 후 복귀** | `scenePhase .active` → `refreshSessionIfNeeded` → 실패 시 로그아웃 + 메시지 | 🟡 중간 |
| **ExploreView 빈 결과** | 필터 조합에 따른 빈 상태 UI 표시 | 🟢 낮음 |
| **Supabase 미설정 시** | `SupabaseConfig.current == nil` → mock 데이터 폴백 | 🟢 낮음 |

---

## 3. 로그인 상태별 UX 점검

### 비로그인 (Guest)

| 항목 | 현재 상태 | 판정 |
|---|---|---|
| 탐색/지도 탭 접근 | ✅ 정상 — 장소 목록·지도 모두 접근 가능 | OK |
| PlaceDetailView 진입 | ✅ 정상 — NavigationLink 제한 없음 | OK |
| 즐겨찾기 버튼 | ✅ toast "로그인하면 즐겨찾기를 저장할 수 있어요" | OK |
| 방문완료 버튼 | ✅ `VisitSavingPreviewSheet` 체험 모드 표시 | OK |
| 체험 기록 저장 | ✅ `GuestChallengeStore` → UserDefaults 저장 | OK |
| 가격 제보 | ✅ 비로그인 경고 배너 + `userID: nil`로 익명 제보 가능 | OK |
| MY 탭 | ✅ `AuthFormCard` 로그인 폼 표시 | OK |
| 1억 챌린지 카드 | ✅ 체험 안내 + `ChallengePreviewView` 링크 | OK |
| 포인트/제보/알림 | ✅ "-" 또는 "로그인 후 확인 가능" 표시 | OK |

### 로그인 (Member)

| 항목 | 현재 상태 | 판정 |
|---|---|---|
| 세션 저장 | ✅ Keychain에 `AuthSession` JSON 저장 | OK |
| 로그인 직후 데이터 로드 | ✅ `onChange(of: session?.userID)` → favorites + challenge 로드 | OK |
| MY 탭 데이터 로드 | ✅ `.task(id: session?.userID)` → profile/points/challenge/alerts/reports/admin 7개 순차 로드 | ⚠️ 점검필요 |
| 로그아웃 | ✅ Keychain 삭제 + 7개 ViewModel reset | OK |
| 로그아웃 후 UI | ✅ `AuthFormCard` 재표시 | OK |

**⚠️ MY 탭 로드 관련 잠재 이슈:**
- `.task(id:)` 안에서 7개 `await` 호출이 순차(sequential) 실행됨
- 하나의 API가 느리면 나머지 전부 지연됨
- 네트워크 에러 시 중간에 멈출 수 있음 (단, 각 ViewModel이 개별 try-catch 처리하므로 크래시 위험은 낮음)

### 세션 만료

| 항목 | 현재 상태 | 판정 |
|---|---|---|
| 만료 감지 | ✅ `expiresAt`까지 300초 미만이면 `needsRefresh = true` | OK |
| 자동 갱신 | ✅ `scenePhase .active` → `refreshSessionIfNeeded()` | OK |
| 갱신 실패 처리 | ✅ Keychain 삭제 + `session = nil` + "다시 로그인해주세요" 메시지 | OK |
| 갱신 실패 후 UI | ✅ `onChange(of: session?.userID)` → favorites/challenge reset | OK |
| 만료된 토큰으로 API 호출 시 | ⚠️ 각 Repository에서 HTTP 401 에러 → ViewModel message로 표시되지만, 자동 로그아웃이나 재인증 유도는 없음 | 점검필요 |

---

## 4. 1억 챌린지 화면 흐름

```
[비로그인]
MY 탭 → ChallengeSummaryCard (체험 안내) → ChallengePreviewView (샘플 + Guest 기록)
탐색 탭 → ChallengeExploreEntryCard → "MY에서 로그인" 텍스트 (NavigationLink 비활성)
PlaceDetailView → 방문완료 → VisitSavingPreviewSheet → GuestChallengeStore 저장

[로그인]
MY 탭 → ChallengeSummaryCard (실제 데이터) → ChallengeView(session:)
탐색 탭 → ChallengeExploreEntryCard → NavigationLink → ChallengeView(session:)
PlaceDetailView → 방문완료 → VisitSavingSheet → log_saving RPC → 성공 시 summary 갱신

[데이터 갱신 경로]
VisitSavingSheet.submit() → challengeViewModel.logSaving() → summary/logs 갱신
ChallengeView.task → challengeViewModel.load(session:) → summary/logs 로드
ChallengeView.refreshable → 같은 load 호출
MY 탭 onAppear → challengeViewModel.load(session:)
```

**현재 상태 판정: ✅ 흐름 자체는 완성됨**

**잠재 이슈:**
1. `VisitSavingSheet`에서 절약 기록 후 `PlaceDetailView`로 돌아왔을 때 toast는 표시되나, MY 탭의 `ChallengeSummaryCard`는 다음 진입 시에만 갱신됨 (실시간 반영은 `@EnvironmentObject` 통해 자동 — ✅ OK)
2. Guest → 로그인 전환 시 `GuestChallengeLedgerCard`의 "실제 장부로 옮기기" 기능 존재 (✅ 구현됨)

---

## 5. 방문 완료/절약 기록 흐름

### 로그인 상태

```
PlaceDetailView
  └─ "방문 완료" 버튼 탭
      └─ authManager.session != nil → isShowingVisitSavingSheet = true
          └─ VisitSavingSheet(place:, session:, onLogged:)
              ├─ 메뉴 선택 (place.menus 기반 라디오)
              ├─ 절약액 자동 계산 (referencePrice vs actualPrice)
              ├─ 절약액 수동 입력 가능 (TextField)
              └─ "기록" 버튼
                  └─ submit() → SavingLogRequest 생성
                      └─ challengeViewModel.logSaving(draft, session:)
                          └─ ChallengeRepository.logSaving() → RPC "log_saving"
                              ├─ 성공: summary 갱신 + logs 재조회 + onLogged 콜백 + dismiss
                              ├─ 중복 에러: "2시간에 한 번만 가능" 메시지
                              └─ 기타 에러: "실패했어요" 메시지
```

### 비로그인 상태

```
PlaceDetailView
  └─ "방문 완료" 버튼 탭
      └─ authManager.session == nil
          ├─ toast "체험 모드로 절약액을 계산해볼게요"
          └─ VisitSavingPreviewSheet(place:)
              ├─ 메뉴 선택 + 절약액 계산 (동일 로직)
              ├─ "체험 기록 저장" → GuestChallengeStore.append()
              ├─ "MY 탭에서 로그인하고 실제 기록하기" → dismiss
              └─ 성공 메시지 표시
```

**판정: ✅ 흐름 완성, 로그인/비로그인 분기 정상**

---

## 6. 가격 제보 흐름

```
PlaceDetailView 하단 "가격 제보" 버튼
  └─ NavigationLink → PriceReportView(place:)
      ├─ 헤더: 장소명 + 예상 포인트 (+30P)
      ├─ 비로그인 경고 배너 (isSignedIn == false 시 표시)
      ├─ 메뉴명 입력 (기본값 "백반 (4찬)")
      ├─ 가격 입력 (숫자만 파싱)
      ├─ 사진 첨부 (필수 1장, 최대 4장)
      │   ├─ confirmationDialog → 카메라 / 앨범 선택
      │   ├─ CameraImagePicker (카메라 사용 불가 시 alert)
      │   └─ PhotosPicker (앨범 선택)
      ├─ 방문 날짜 (DatePicker, 오늘 이전만)
      ├─ 메모 입력
      ├─ validationMessage (조건 미충족 시 빨간 경고)
      └─ "제보 제출하고 30P 받기" 버튼
          └─ submit()
              ├─ 유효성 검사 (메뉴명, 가격, 사진 필수)
              ├─ PriceReportDraft 생성 (userID: session?.userID)
              ├─ reportRepository.submit(draft, images, session)
              │   ├─ insertReport → price_reports 테이블
              │   ├─ ImagePrivacyProcessor.makeSafeJPEGData (EXIF 제거)
              │   ├─ uploadPhotoData → Storage "price-report-photos"
              │   └─ insertPhotoMetadata → report_photos 테이블
              ├─ 성공: haptic + alert "제보가 접수됐어요" → dismiss
              └─ 실패: haptic + validationMessage (에러별 분기 메시지)
```

**판정: ✅ 흐름 완성**

**잠재 이슈:**
1. 사진 업로드 중 네트워크 끊김 시 → report는 DB에 있지만 photo가 일부만 업로드될 수 있음 (부분 실패 → 현재 전체 에러로 처리)
2. 비로그인 제보 시 `session?.accessToken ?? config.publishableKey` 사용 → RLS 정책에 따라 거부될 수 있음
3. 제보 성공 후 `MyReportsCard` 새로고침은 자동이 아님 (MY 탭 재진입 시 `.task(id:)` 통해 갱신)

---

## 7. MY 탭 IA 정리 제안

현재 MY 탭 카드 배치 순서 (위→아래):

| 순서 | 카드 | 비로그인 시 | 용도 |
|---|---|---|---|
| 1 | 프로필 헤더 (고정) | Guest 표시 | 필수 |
| 2 | AuthFormCard / 로그아웃 버튼 | 로그인 폼 | 필수 |
| 3 | StatBox (제보/승인/포인트) | "-" 표시 | 필수 |
| 4 | PointTransactionsCard | 로그인 안내 | 필수 |
| 5 | ChallengeSummaryCard | 체험 안내 | 필수 |
| 6 | GuestChallengeLedgerCard | 체험 기록 표시 | QA용 |
| 7 | ChallengeQAChecklistCard | 체크리스트 | **QA 전용** |
| 8 | OperationsQABoardCard | QA 보드 | **QA 전용** |
| 9 | SystemStatusCard | 시스템 상태 | **QA 전용** |
| 10 | FavoritePlacesCard | 로그인 안내 | 필수 |
| 11 | PriceAlertSettingsCard | 로그인 안내 | 필수 |
| 12 | PriceAlertEventsCard | 로그인 안내 | 필수 |
| 13 | ProfileViewModel 메시지 | - | 디버그 |
| 14 | AdminReviewCard | 숨김 | Admin 전용 |
| 15 | MyReportsCard | 로그인 안내 | 필수 |
| 16 | MonthlySavingsReportCard | 로그인 안내 | 필수 |
| 17 | MyMenuRow 리스트 (4개) | 안내 텍스트 | 필수 |

**제안 (베타 출시 전):**
- 6, 7, 8, 9번 카드는 QA/운영 전용이므로 베타 사용자에게 노출 불필요 → `#if DEBUG` 또는 Admin 분기 권장
- 현재 상태에서는 기능 테스트를 위해 유지해도 무방

---

## 8. 수정 필요 파일 후보

| 파일 | 위치 | 수정 사유 |
|---|---|---|
| `ContentView.swift` | L5110-5128 | MY 탭 `.task(id:)` 순차 로드 → 병렬 로드 전환 권장 |
| `ContentView.swift` | L3818-3823 | 방문완료 비로그인 분기 — toast 텍스트와 동시에 sheet 열림 (toast가 sheet에 가려질 수 있음) |
| `ContentView.swift` | L4525-4546 | 비로그인 제보 경고 — RLS 거부 가능성 확인 필요 |
| `ContentView.swift` | L7769-7788 | QA 샘플값 채우기 버튼 — 베타 배포 시 제거/숨김 필요 |
| `ContentView.swift` | L7791 | `AuthQAGuideBox` — 베타 배포 시 제거/숨김 필요 |
| `ChallengeView.swift` | L448-502 | `ChallengeView`는 `session` 필수 — 세션 만료 시 화면에 에러 표시만 됨 |

---

## 9. 최소 수정안

### 1. MY 탭 데이터 로드 병렬화 (위험도: 🟡 중간)

**현재 문제**: `.task(id:)` 내 7개 `await` 순차 실행 → 총 로드 시간 = 7개 API 응답 시간의 합  
**수정 방향**: `async let` 또는 `TaskGroup`으로 병렬 호출  
**영향 범위**: `ContentView.swift` L5110-5128

### 2. 방문완료 비로그인 시 toast 가림 수정 (위험도: 🟢 낮음)

**현재 문제**: toast "체험 모드로 절약액을 계산해볼게요"가 뜨자마자 sheet가 올라와서 가려짐  
**수정 방향**: toast 제거 또는 sheet 내부 상단에 안내 배너로 이동 (이미 `VisitSavingPreviewSheet` 내에 안내 텍스트 있으므로 toast 제거가 깔끔)  
**영향 범위**: `ContentView.swift` L3820

### 3. QA 전용 UI 요소 베타 배포 시 숨김 (위험도: 🟢 낮음)

**현재 문제**: `AuthFormCard`의 "QA 샘플값 채우기" 버튼, `AuthQAGuideBox`, `ChallengeQAChecklistCard`, `OperationsQABoardCard`, `SystemStatusCard`가 일반 사용자에게 노출됨  
**수정 방향**: `#if DEBUG` 래핑 또는 Admin 여부 분기  
**영향 범위**: `ContentView.swift` 여러 곳

### 4. 세션 만료 후 API 401 발생 시 자동 재인증 유도 (위험도: 🟡 중간, 베타 후 가능)

**현재 문제**: 만료된 토큰으로 API 호출 시 각 ViewModel에서 에러 메시지만 표시 → 사용자가 수동으로 로그아웃 후 재로그인 필요  
**수정 방향**: Repository의 validate에서 401 감지 → AuthManager에 통보 → 세션 클리어 + 재로그인 안내  
**영향 범위**: 전체 Repository → 베타 이후 추천

### 5. 가격 제보 비로그인 RLS 테스트 (위험도: 🟡 중간)

**현재 문제**: 비로그인 시 `session?.accessToken ?? config.publishableKey`로 API 호출 → Supabase RLS 정책에 따라 INSERT 거부 가능  
**수정 방향**: Supabase Dashboard에서 `price_reports` 테이블의 INSERT 정책이 anon key 허용하는지 확인 → 불허 시 비로그인 제보 차단하고 로그인 유도  
**영향 범위**: Supabase 설정 + `PriceReportView` L4525

---

## 10. 수정 전 CEO 승인 필요 항목

| 항목 | 이유 | 승인 질문 |
|---|---|---|
| QA 전용 UI 숨김 | 베타 사용자 UX에 직접 영향 | QA 카드들을 `#if DEBUG`로 숨길까요, 아니면 베타 기간에도 노출해둘까요? |
| 비로그인 가격 제보 허용 여부 | 익명 제보 허용 시 스팸/어뷰징 위험 | 비로그인 사용자의 가격 제보를 허용할까요, 로그인 필수로 바꿀까요? |
| MY 탭 병렬 로드 전환 | 기존 순차 로드 동작 변경 | 로드 속도 개선을 위해 병렬 API 호출로 변경해도 될까요? |
| 방문완료 toast 제거 | 비로그인 UX 미세 변경 | 체험 모드 진입 시 toast를 제거하고 sheet 내 안내에 통합해도 될까요? |

---

## 부록: 에러/로딩/빈 상태 점검 요약

| 화면 | 로딩 상태 | 빈 상태 | 에러 상태 |
|---|---|---|---|
| ExploreView | `DataStatusBanner` ProgressView | "조건에 맞는 장소가 없어요" | mock 데이터 폴백 |
| PlaceDetailView | 없음 (동기 데이터) | 해당없음 | 해당없음 |
| VisitSavingSheet | "저장 중" 버튼 텍스트 | 해당없음 | viewModel.message 표시 |
| ChallengeView | ProgressView + isLoading | "아직 기록된 절약 로그가 없어요" | "불러오지 못했어요" |
| PriceReportView | ProgressView + "제보 저장 중" | 해당없음 | validationMessage (에러별 분기) |
| MY 탭 각 카드 | 개별 isLoading | 개별 message | 개별 message |
| AuthFormCard | ProgressView + "처리 중" | 해당없음 | authMessage (색상 분기) |

**종합 판정: 로딩/빈/에러 상태는 대부분 구현되어 있으며, 크래시 위험은 낮음**
