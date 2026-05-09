# 043 Auth 계정 상태 점검 버튼 추가 리포트

## 작업 목표

Supabase 로그인 문제가 있을 때, 사용자가 로그인 버튼만 반복해서 누르지 않고 앱 안에서 계정 상태를 점검할 수 있게 했습니다.

## 변경한 내용

### 1. MY 로그인 카드에 `계정 상태 점검` 버튼 추가

로그인 모드일 때만 표시됩니다.

버튼 동작:

1. 이메일/비밀번호 형식 확인
2. Supabase Auth 로그인 API 호출
3. 성공하면 세션을 Keychain에 저장하고 로그인 완료 처리
4. 실패하면 실패 원인을 초보자용 문장으로 안내

### 2. 실패 메시지 개선

`invalid_credentials`가 오면 아래처럼 보여줍니다.

> Supabase Auth에 이 이메일 유저가 없거나 비밀번호가 달라요. Users에서 유저 생성과 Confirm 상태를 확인해주세요.

`email_not_confirmed`가 오면 아래처럼 보여줍니다.

> 계정은 있지만 Confirm 처리가 안 됐어요. Supabase Users에서 Confirm 처리해주세요.

## 수정 파일

- `ContentView.swift`

## 현재 외부 API 확인 결과

아직 `jjantechmap.qa@gmail.com` 계정은 Supabase Auth에서 로그인되지 않습니다.

- 결과: `invalid_credentials`
- 해석: 유저가 없거나, 비밀번호가 다르거나, Confirm 상태가 아님

## QA 기준

- 앱 빌드 성공
- MY 탭 로그인 카드에 `계정 상태 점검` 버튼 표시
- 성공 시 로그인 완료
- 실패 시 원인 안내

