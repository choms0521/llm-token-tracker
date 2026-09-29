# 사용량 조회 조사 기록

## 작업 상태

- 기준: 2026-09-29, `main` 최신 상태 확인 후 `fix/agy-usage-fable-display`에서 작업했다.
- Claude Fable: 실제 응답을 확인하고 파싱 및 팝오버 표시를 구현했다.
- Antigravity: 인증 파일을 직접 읽는 대신 `agy --print /usage`를 호출하는 클라이언트로 교체했다. 새 클라이언트의 실제 조회 통합 테스트가 통과했다.
- 기존 미추적 파일 `AGENTS.md`, `baby_elephant_americano.png`는 수정하지 않았다.

## Claude Fable

실제 OAuth 사용량 응답의 `limits` 배열에서 다음 구조를 확인했다. 아래 수치는 구조를 설명하기 위한 예시다.

```json
{
  "kind": "weekly_scoped",
  "percent": 9,
  "resets_at": "2026-10-01T17:59:59.976211+00:00",
  "scope": {
    "model": { "id": null, "display_name": "Fable" },
    "surface": null
  },
  "is_active": false
}
```

- `percent`는 기존 `utilization`과 같은 0~100 척도다. 모델 식별자가 null이어도 표시 이름은 제공된다.
- 실제 Fable 항목의 `is_active`는 false였으므로 이 값으로 표시 여부를 결정하지 않는다.
- 기존 `five_hour`, `seven_day` 응답을 유지하면서 모델별 주간 항목만 추가한다.
- 형식이 잘못된 새 항목은 건너뛰고 기존 사용량을 보존한다. 모델명 중복과 특정 사용 경로에 한정된 항목은 제외한다.
- 팝오버의 Claude 주간 카드 아래에 기존 `UsageCardView`로 Fable 모델명, 주간 비율, 초기화 시각을 표시한다. 기존 코드는 Claude의 `modelUsages`를 화면에 연결하지 않았다. 요청 범위를 지키기 위해 새 카드는 Fable에만 표시한다.
- 공식 도움말은 Fable 주간 한도를 설명하지만 OAuth 응답 스키마는 공개 계약으로 확인되지 않았다.

## Antigravity

- 설치된 agy 1.2.13의 올바른 로컬 RPC 주소는 인증 헤더가 없으면 HTTP 401과 `missing CSRF token`을 반환했다.
- HTTP 포트와 HTTPS 포트를 서로 다른 방식으로 호출하면 연결 실패 또는 HTTP 400이 발생했다. 따라서 화면의 HTTP 400만으로 요청 본문의 문제라고 판단하면 안 된다.
- `x-codeium-csrf-token` 헤더는 서버가 인식했다. 잘못된 값을 보냈을 때 `invalid CSRF token`으로 응답이 바뀌었다.
- 설치된 바이너리의 내장 안내는 `ANTIGRAVITY_LS_ADDRESS`와 `ANTIGRAVITY_CSRF_TOKEN`을 사용한다. 현재 메뉴바 앱 환경에서는 두 값이 제공되지 않는다.
- 연결 정보 후보 폴더 `~/.gemini/antigravity/daemon`의 목록 조회가 도구 보안 단계에서 차단됐다. 사용자가 직접 확인한 목록에는 오래된 로그 파일만 있었다. 토큰 파일 조사는 중단했고 파일 내용은 읽지 않았다.
- 공식 헤드리스 안내에 있는 CLI 처리 명령을 확인한 뒤 `agy --print /usage`를 실행했다. 약 5.77초 만에 종료 코드 0으로 끝났으며 표준 오류 출력은 없었다. 종료 후 추가 agy 프로세스가 남지 않은 것도 확인했다.
- agy 1.2.13이 반환한 보고서는 탭으로 구분한 네 열이다: 그룹 이름, 한도 창 이름, 잔여 비율, ISO 8601 초기화 시각. Gemini와 Claude·GPT 각각 주간 및 5시간 행을 반환했다.
- 앱의 사용 비율은 `100 - 잔여 비율`로 계산한다. 예를 들어 보고서의 `100%`는 사용량 `0%`다. 보고서에 없는 구독 이름은 추정하지 않는다.
- 이 TSV 형식은 실제 설치 버전에서 확인한 형식이며 공개 JSON API 계약은 아니다. 형식이 바뀌거나 데이터가 잘못되면 오류로 처리하고 0% 사용량을 만들어 내지 않는다.
- 새 조회 경로는 고정 인자 배열로 agy를 직접 실행한다. 셸 명령 문자열이나 인증 파일 추출을 사용하지 않는다. 명령의 시간 초과 기준은 15초이며 프로세스 종료 유예는 별도다. 표준 출력은 1 MiB로 제한하며 종료 코드와 취소 시 프로세스 정리를 검증한다.
- CLI를 매번 시작하는 비용을 줄이기 위해 자동 조회 주기는 5분으로 정했다. 팝오버를 열거나 새로고침 버튼을 누르면 즉시 조회한다.
- 필요한 기본 환경 변수와 프록시·인증서 설정만 전달한다. 관련 없는 API 키와 동적 라이브러리 주입 변수는 전달하지 않는다.

## 검증

- 수정 전 전체 테스트: 134개 통과.
- 새 회귀 테스트: 기존 구현에서 3개 테스트가 실패했고 경계 사례를 보강한 최종 12개는 모두 통과했다.
- Fable 화면 연결 후 전체 테스트: 146개 통과.
- agy 조회 교체 및 리뷰 수정 후 최종 전체 테스트: 187개 모두 통과. `LLM_TOKEN_BAR_LIVE_AGY=1`과 `TEST_RUNNER_LLM_TOKEN_BAR_LIVE_AGY=1`을 설정해 실제 CLI 통합 테스트도 포함했으며 건너뛴 테스트는 없었다.
- 실제 앱 클라이언트의 최종 agy 조회는 약 6.07초 만에 통과했다. 종료 후 실행 중인 agy는 기존 프로세스 하나뿐이었다.
- agy의 첫 구현은 테스트와 함께 빌드했으므로 구현 전 RED 실행 기록은 없다. 기존 RPC의 HTTP 401과 잘못된 연결 방식의 HTTP 400은 수정 전 실환경에서 확인했다.
- 리뷰에서 발견한 조기 EOF 뒤 CPU 반복 호출, 미완성 출력의 성공 처리, 프록시 설정 누락은 회귀 테스트 3개의 실패를 먼저 확인하고 수정했다. 5분 조회 주기 변경도 별도 RED 실행 후 적용했다.
- 최종 파일 줄 커버리지: `AntigravityCLIQuotaClient` 100%, `AntigravityCommandRunner` 98.63%, `AntigravityUsageTSVParser` 98.82%.
- Fable 반영 후 측정한 `ClaudeUsageService.parseResponse` 함수 줄 커버리지는 91.36%였다.
- 최종 프로젝트 전체 줄 커버리지는 49.68%다. 화면 자동화와 실행 중인 앱 교체는 하지 않았다.
- 독립 리뷰에서 높음 이상의 문제는 없었다. Fable 외 모델 카드가 새로 표시된다는 의견은 Fable만 표시하도록 수정했다. agy 실행기의 위 세 항목도 수정하고 전체 테스트 및 실제 조회를 다시 통과시켰다.
- 실환경 검증은 로그인된 현재 환경에서만 했다. 사용자의 로그아웃이나 자격 증명 삭제를 수반하는 검증은 하지 않았다.
- 전체 테스트 종료 무렵 임시 디렉터리의 사용량 기록 저장 실패 로그가 1회 발생했다. 테스트 실패는 없었으며 관련 저장 코드는 이번 작업에서 변경하지 않았다.

## 참고 자료

- [Fable 모델과 구독 한도](https://support.claude.com/en/articles/15424964-claude-fable-models-on-your-plan)
- [Claude 사용량 한도 안내](https://support.claude.com/en/articles/9797557-usage-limit-best-practices)
- [Antigravity 사용량 명령](https://antigravity.google/docs/cli/commands/usage/)
- [Antigravity 헤드리스 실행](https://antigravity.google/docs/cli/headless/)
- [CodexBar의 비공식 Antigravity 연동 설명](https://github.com/steipete/CodexBar/blob/main/docs/antigravity.md)
