---
name: release
description: "Create a new release for this mac-token-bar project by determining the next semantic version, checking main/clean tree status, generating release notes from commits, creating a git tag, building a Release app, generating a DMG, and publishing a GitHub release. Use when the user asks to cut a release, ship a new version, or bump patch/minor/major for this repository."
---

# Release

이 스킬은 현재 저장소 `mac-token-bar` 전용 릴리스 절차를 수행합니다.

## 사용법

```text
$release <version>
$release patch
$release minor
$release major
$release v1.2.1
```

## 버전 규칙

- `patch`: 버그 수정, 사소한 개선, 하위 호환 유지
- `minor`: 새 기능 추가, 하위 호환 가능
- `major`: breaking change

## 실행 프로토콜

다음 순서로 진행합니다.

### 1. 사전 검증

먼저 아래를 확인합니다.

- 현재 브랜치가 `main` 인지
- working tree 가 clean 한지
- `git pull --ff-only origin main` 으로 최신 상태인지

위 조건이 아니면 릴리스를 진행하지 않습니다.

### 2. 버전 결정

`{{ARGUMENTS}}` 를 해석해서 새 버전을 정합니다.

```bash
CURRENT_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
CURRENT="${CURRENT_TAG#v}"
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
```

- `patch` 또는 인자 없음: `PATCH += 1`
- `minor`: `MINOR += 1`, `PATCH = 0`
- `major`: `MAJOR += 1`, `MINOR = 0`, `PATCH = 0`
- `vX.Y.Z` 또는 `X.Y.Z`: 명시한 버전 사용

### 3. 변경 내역 수집

현재 태그 이후 커밋을 읽습니다.

```bash
git log ${CURRENT_TAG}..HEAD --oneline
```

커밋 메시지를 기준으로 초안 릴리스 노트를 분류합니다.

- `feat:` 새 기능
- `fix:` 버그 수정
- `refactor:` 개선
- 그 외: 기타 변경사항

### 4. 릴리스 요약 제시

아래를 사용자에게 짧게 보여줍니다.

- 현재 버전
- 새 버전
- 포함된 커밋 수
- 생성된 변경 내역 요약

태그 생성, GitHub Release 생성, 배포 같은 외부 부작용 단계 전에는 현재 계획을 한 번 명확히 알립니다.

### 5. 태그 생성 및 push

```bash
git tag v${NEW_VERSION}
git push origin v${NEW_VERSION}
```

브랜치 push 가 필요하면 함께 진행합니다.

```bash
git push origin main
```

### 6. Release 빌드

```bash
rm -rf .build-release
xcodegen generate
xcodebuild -project LLMTokenBar.xcodeproj \
    -scheme LLMTokenBar \
    -configuration Release \
    -derivedDataPath .build-release \
    -arch arm64 \
    DEVELOPMENT_TEAM="" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build
```

빌드 후 Release 앱이 생성되었는지 확인합니다.

- `.build-release` 아래 `LLM Token Bar.app` 존재 확인
- 필요하면 Info.plist 의 버전 값도 확인

### 7. DMG 생성

```bash
STAGING_DIR=$(mktemp -d)
APP_PATH=$(find .build-release -name "LLM Token Bar.app" -type d | head -1)
cp -R "$APP_PATH" "${STAGING_DIR}/LLM Token Bar.app"

create-dmg \
    --volname "LLM Token Bar" \
    --volicon "LLMTokenBar/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 128 \
    --icon "LLM Token Bar.app" 180 200 \
    --hide-extension "LLM Token Bar.app" \
    --app-drop-link 480 200 \
    --no-internet-enable \
    LLMTokenBar.dmg \
    "${STAGING_DIR}"

rm -rf "${STAGING_DIR}"
```

DMG 생성 실패가 언마운트 문제면 `hdiutil detach -force` 후 재시도합니다.

### 8. GitHub Release 배포

```bash
gh release create v${NEW_VERSION} ./LLMTokenBar.dmg \
    --title "v${NEW_VERSION}" \
    --notes "${RELEASE_NOTES}"
```

`gh` 인증이나 권한 문제로 막히면 정확한 에러를 보고하고 중단합니다.

### 9. 완료 보고

완료 시 아래를 정리해서 보고합니다.

- 릴리스 URL
- 태그 이름
- DMG 파일명과 크기
- 포함된 커밋 요약

## 규칙

- `main` 이 아니면 진행하지 않습니다.
- 커밋 안 된 변경사항이 있으면 진행하지 않습니다.
- `git pull` 로 최신 상태 확인 전 태그를 만들지 않습니다.
- Release 빌드와 DMG 생성 성공 전 GitHub Release 를 만들지 않습니다.
- 외부 publish 단계에서 실패하면 실패 지점과 복구 방법을 명확히 보고합니다.

Task: {{ARGUMENTS}}
