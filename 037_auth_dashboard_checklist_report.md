# 037 Supabase Auth 대시보드 체크리스트 리포트

## 현재 상태

QA 계정 로그인 API를 다시 확인했지만 아직 실패합니다.

- Email: `jjantechmap.qa@gmail.com`
- Result: `invalid_credentials`

이 상태는 앱 코드 문제가 아니라 Supabase Auth에 해당 계정이 없거나, 비밀번호가 다르거나, Confirm 처리가 안 된 상태일 가능성이 큽니다.

## 이번 단계에서 개선한 것

MY 탭 로그인 카드의 QA 안내 박스에 Supabase 대시보드 작업 순서를 추가했습니다.

앱 안에서 아래 순서를 바로 볼 수 있습니다.

1. Authentication > Users > Add user
2. 복사한 이메일과 비밀번호 입력
3. Auto Confirm User 또는 Confirm 켜기
4. 앱에서 QA 샘플값 채우기 > 로그인으로 > 로그인

## 왜 필요한가

왕초보 입장에서는 Supabase 대시보드에서 계정을 만들 때 아래 실수가 자주 납니다.

- 이메일 오타
- 비밀번호 오타
- 회원가입 모드로 다시 눌러버림
- Confirm 처리를 안 함
- Add user가 아니라 invite 흐름을 탐

이번 개선은 이 실수를 줄이기 위한 앱 내 운영 가이드입니다.

## 다음 단계

QA 계정이 Confirm 완료되면 038 단계에서 실제 저장 루프를 검증합니다.

1. 로그인 성공 확인
2. 장소 상세 진입
3. 방문 완료
4. 절약 기록 저장
5. MY 1억 챌린지 카드 반영
6. 절약 기록 취소
