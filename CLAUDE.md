# LLM Token Bar

macOS 메뉴바 앱 - Claude OAuth usage 모니터링

## Git Workflow

- 새로운 작업은 반드시 **별도 브랜치**를 생성하여 진행
- 작업 완료 후 **main에 merge**
- 브랜치 이름: `feat/`, `fix/`, `refactor/` 등 conventional prefix 사용

## Tech Stack

- Swift 6.0 / SwiftUI / macOS 14+
- XcodeGen (`project.yml`)
- 빌드: `xcodegen generate && xcodebuild -project LLMTokenBar.xcodeproj -scheme LLMTokenBar -configuration Debug build`

## Architecture

- OAuth 토큰: Keychain에서 읽기 전용 (CLI 세션 보호를 위해 앱에서 토큰 refresh 하지 않음)
- Rate limit 시: Keychain에서 최신 토큰 재로드 후 재시도
- Polling: 성공 5분, 실패 30초, rate limit 5분 기반 지수 백오프
