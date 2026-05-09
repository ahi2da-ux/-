# 033 Auth 오류 UX 개선 리포트

## 이번 단계 목표

1억 챌린지 실사용 QA를 하려면 로그인 성공이 먼저 필요합니다.
하지만 현재 테스트 계정은 Supabase Auth에서 `invalid_credentials` 상태입니다.

그래서 이번 단계에서는 앱 안에서 사용자가 왜 로그인이 안 되는지 바로 이해할 수 있도록 인증 오류 안내를 개선했습니다.

## 개선한 내용

### 1. 잘못된 이메일/비밀번호 안내 개선

기존에는 Supabase 원문 응답이 그대로 보일 수 있었습니다.
이제 `invalid_credentials` 응답은 아래처럼 표시됩니다.

> 이메일 또는 비밀번호가 맞지 않아요. QA 계정은 Supabase Authentication > Users에서 직접 만들고 Confirm 처리해주세요.

### 2. 이메일 발송 제한 안내 개선

Supabase에서 `over_email_send_rate_limit`가 내려오면 아래처럼 표시됩니다.

> Supabase 이메일 발송 제한에 걸렸어요. 대시보드에서 테스트 유저를 직접 만들고 Confirm 처리해주세요.

### 3. MY 로그인 카드에 QA 안내 박스 추가

MY 탭 로그인 카드 안에 아래 안내를 추가했습니다.

> Supabase > Authentication > Users에서 `jjantechmap.qa@gmail.com` 유저를 직접 만들고 Confirm 처리한 뒤 로그인해주세요.

## 현재 블로커

아직 Supabase Auth에 로그인 가능한 QA 계정이 확인되지 않았습니다.

사용자가 해야 할 일:

1. Supabase 대시보드 접속
2. Authentication > Users
3. Add user
4. Email: `jjantechmap.qa@gmail.com`
5. Password: 별도 보관한 QA 비밀번호
6. Confirm 처리

## 다음 단계

QA 계정 로그인이 성공하면 034 단계에서 아래 루프를 실제 검증합니다.

1. 로그인
2. 장소 상세 진입
3. 방문 완료
4. 절약 기록 저장
5. MY 1억 챌린지 카드 반영
6. 최근 기록 취소
