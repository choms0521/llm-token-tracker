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

## Release Packaging Policy (고정)

- 릴리즈 DMG는 반드시 `scripts/create-dmg.sh`로 생성한다.
- DMG 레이아웃은 Finder 설치형 스타일(앱 아이콘 + Applications 링크)로 고정한다.
  - window: `660x400`
  - app icon: `(180, 200)`
  - Applications link: `(480, 200)`
- `create-dmg` 옵션으로 **DMG 서명 + 공증(notarization) + stapling**까지 한 번에 수행한다.
  - `--codesign "Developer ID Application: minseok cho (9ADWM2H336)"`
  - `--notarize "notarytool"`
- `notarytool` 키체인 프로필이 사전에 등록되어 있어야 한다.
