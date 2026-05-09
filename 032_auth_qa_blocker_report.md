# 032 Auth QA 블로커 리포트

## 결론

1억 챌린지의 실제 저장 QA를 진행하려면 로그인 가능한 Supabase 테스트 계정이 필요합니다.

현재 API 기준으로 확인한 결과, 샘플 계정 로그인은 아직 실패합니다.

## 확인 결과

### 1. 기존 샘플 이메일

- Email: `jjantech.qa@example.com`
- 결과: Supabase Auth가 `example.com` 도메인을 거부했습니다.
- 메시지: `email_address_invalid`

### 2. 수정된 샘플 이메일

- Email: `jjantechmap.qa@gmail.com`
- Password: 별도 보관된 QA 비밀번호 사용
- 회원가입 시도 결과: 이메일 발송 제한에 걸렸습니다.
- 메시지: `over_email_send_rate_limit`
- 로그인 시도 결과: 아직 로그인 불가입니다.
- 메시지: `invalid_credentials`

## 원인

Supabase Auth에서 테스트 계정이 아직 정상 생성/확정되지 않았습니다.
또한 현재 프로젝트는 이메일 발송 제한에 걸려 앱이나 API에서 새 인증 메일을 바로 보내기 어렵습니다.

## 왕초보 기준 해결 방법

1. Supabase 대시보드에 접속합니다.
2. 왼쪽 메뉴에서 Authentication을 누릅니다.
3. Users를 누릅니다.
4. Add user를 누릅니다.
5. 아래 값으로 유저를 직접 만듭니다.
   - Email: `jjantechmap.qa@gmail.com`
   - Password: 별도 보관된 QA 비밀번호 입력
   - Auto Confirm User 또는 Confirm 옵션이 있으면 켭니다.
6. 유저 목록에서 해당 계정이 Confirmed 상태인지 확인합니다.
7. 앱 MY 탭에서 이메일과 별도 보관한 QA 비밀번호를 입력합니다.
8. 로그인 버튼을 누릅니다.

## 이후 진행할 QA

1. 로그인 성공
2. 지도 또는 탐색에서 장소 선택
3. 장소 상세에서 방문 완료
4. 메뉴 선택 후 절약 기록 저장
5. MY 탭 1억 챌린지 카드 증가 확인
6. 1억 챌린지 상세에서 최근 기록 확인
7. 최근 기록 취소 후 누적 절약액 감소 확인

## 현재 상태

- 앱 코드: 빌드 가능
- Supabase URL/Key: 연결 가능
- Auth API: 응답 확인 완료
- 테스트 계정: 대시보드에서 수동 생성 필요
