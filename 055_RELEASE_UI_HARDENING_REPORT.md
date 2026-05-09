# 055 베타 UI/인증 안정화 보고서

## 목표

베타 사용자에게 내부 QA/운영 도구가 노출되지 않도록 막고, 로그인 입력 안정성을 개선한다.

## 변경 파일

- `ContentView.swift`

## 변경 내용

### 1. 내부 도구 노출 제어

`AppEnvironment.showsInternalTools` 플래그를 추가했다.

현재 값:

```swift
static let showsInternalTools = false
```

이 값이 `false`이면 다음 내부 도구가 일반 MY 화면에 표시되지 않는다.

- 1억 챌린지 QA 체크리스트
- 운영 QA 보드
- 시스템 상태 카드
- QA 샘플값 채우기 버튼
- QA 계정 진단 박스
- 계정 상태 점검 버튼

### 2. QA 비밀번호 문자열 제거

앱 코드 안에 있던 QA 샘플 비밀번호 문자열을 제거했다.

이제 QA 비밀번호는 앱 코드가 아니라 Supabase Dashboard 또는 별도 안전한 메모에서 관리해야 한다.

### 3. 로그인 입력 안정화

로그인/회원가입 시 이메일 앞뒤 공백을 제거하도록 수정했다.

사용자가 실수로 이메일 끝에 공백을 넣어도 Auth 요청은 정리된 이메일로 전송된다.

### 4. 사용자용 인증 오류 문구 정리

일반 사용자에게 Supabase QA 계정 안내가 보이지 않도록 `invalidCredentials` 문구를 일반 로그인 오류 문구로 바꿨다.

## 검증 결과

### 빌드

명령:

```bash
xcodebuild -project JjantechMap.xcodeproj -scheme JjantechMap -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

결과:

- 성공
- 네이버 지도 SDK 내부의 iOS 26 `UIScreen.mainScreen` deprecation warning만 있음
- 앱 코드 컴파일 오류 없음

### 실행

대상:

- iPhone 17 Pro Simulator

결과:

- 설치 성공
- 실행 성공
- Bundle ID: `com.local.jjantechmap.runner`

## 현재 MVP 완성도

- SQL 028/029 실행 전 로컬 안정화 기준: 약 89%
- 028/029 Supabase 적용 + QA 로그인 성공 시 예상: 약 90~91%
- 가격 제보 승인 E2E 통과 시 예상: 약 92%

## 다음 작업

1. Supabase SQL Editor에서 028 실행
2. Supabase SQL Editor에서 029 실행
3. QA 계정 로그인 확인
4. 장소 상세 절약 기록/취소 QA
5. 가격 제보 승인 후 포인트/알림/챌린지 반영 QA
