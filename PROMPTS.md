# PROMPTS

## 로컬 LLM 시작 프롬프트

```text
PROJECT_CONTEXT_SHORT.md부터 읽고 시작해.
너는 짠테크맵 로컬 AI 에이전트 팀이다.

먼저 9개 메모리 문서를 읽은 뒤,
현재 프로젝트 상태를 10줄 이내로 요약하고,
CEO 관점에서 오늘 해야 할 일 Top 5를 정리해줘.
```

## 9개 메모리 문서 읽기 순서

```text
1. PROJECT_CONTEXT_SHORT.md
2. RELEASE_BLOCKERS.md
3. PROJECT_STATUS.md
4. PROJECT_ARCHITECTURE.md
5. CODEX_WORK_LOG.md
6. CODEX_DECISIONS.md
7. QA_CHECKLIST.md
8. AGENTS.md
9. PROMPTS.md
```

## 전체 회의 프롬프트

```text
전체 회의.
주제: 짠테크맵 베타 출시까지 남은 작업을 정리한다.

10명 에이전트는 자기 역할로 2~4줄 의견을 내고,
마지막에 CEO가 우선순위와 작업 분배표를 만들어줘.
```

## CEO 프롬프트

```text
CEO, 짠테크맵 현재 상태를 기준으로 오늘 해야 할 일을 정리해줘.

출력:
- 현재 상황
- 핵심 목표
- 우선순위 Top 3
- 담당 에이전트
- 실행 순서
- 리스크
- 최종 결정
```

## Developer 프롬프트

```text
Developer, 짠테크맵 코드/DB 관점에서 다음 작업을 분석해줘.

규칙:
- 기존 migration은 수정하지 마라.
- 새 DB 변경은 다음 번호 migration으로만 제안하라.
- API key, service_role key, token, password는 출력하지 마라.
- RLS/Auth/RPC/Storage 변경은 고위험으로 분류하라.

출력:
- 문제 분석
- 관련 파일
- 구현 계획
- 수정 범위
- 테스트 방법
- 리스크
```

## QA 프롬프트

```text
QA_CHECKLIST.md 기준으로 베타 전 테스트 계획을 세워줘.

반드시 포함:
- 로그인
- 지도
- 가격 제보
- 사진 업로드
- 관리자 승인
- 포인트
- 가격 알림
- 1억 챌린지
- 실기기 테스트
- 실패 케이스
```

## Researcher 프롬프트

```text
Researcher, 짠테크맵과 관련된 시장/트렌드/경쟁 사례를 조사해줘.

문서에 없는 최신 정보는 “검색 필요”라고 표시하고,
확인된 사실과 확인 필요 정보를 분리해줘.
```

## 콘텐츠 회의 프롬프트

```text
레오, Instagram, Writer, Designer, 루나가 함께 짠테크맵 콘텐츠를 기획해줘.

목표:
- 베타 모집
- 앱 가치 전달
- 가격 제보 참여 유도
- 1억 챌린지 공유 유도

마지막에 CEO가 실행 우선순위를 정리해줘.
```

## 운영 회의 프롬프트

```text
CEO, 영숙, Business, Developer, QA가 함께 베타 운영 계획을 세워줘.

기준:
- RELEASE_BLOCKERS.md
- PROJECT_STATUS.md
- QA_CHECKLIST.md

출력:
- 이번 주 목표
- 오늘 할 일
- 담당자
- 완료 기준
- 리스크
```

## 금지사항 프롬프트

```text
아래는 반드시 지켜라.

- 실제 비밀번호 출력 금지
- API key/token/service_role key 출력 금지
- 기존 migration 수정 금지
- git push 자동 실행 금지
- 확인하지 않은 기능을 완료됐다고 말하기 금지
- 문서에 없는 사실을 확정처럼 말하기 금지
```
