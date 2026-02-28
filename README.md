# CursorBar

[Cursor](https://www.cursor.com/) IDE의 사용량을 macOS 메뉴바에서 모니터링하는 경량 앱입니다. CodexBar의 보안 이슈를 해결하기 위해 새로 구현했습니다. 자세한 내용은 [보안 감사 보고서](docs/security-audit.md)를 참고하세요.

## 주요 기능

- 메뉴바에서 요청 사용량(사용/한도) 및 리셋 날짜 확인
- 앱 내 WebView 로그인 (Google, GitHub, Enterprise SSO 지원)
- 자동 새로고침 (1/2/5/15분 간격 선택)
- Keychain 기반 인증 정보 저장

## 보안 특성

- 외부 의존성 0개 (macOS SDK만 사용)
- WebView 도메인 whitelist 적용
- `URLSessionConfiguration.ephemeral` (디스크 캐시 없음)
- JavaScript injection 없음
- Data Protection Keychain 사용 (프롬프트 없음)

## 요구사항

- macOS 14 (Sonoma) 이상
- Swift 6.0+ (빌드 시)

## 빌드 및 설치

```bash
# 빌드 + .app 번들 생성 (ad-hoc 서명)
bash Scripts/package_app.sh

# 설치
cp -r CursorBar.app /Applications/
```

## 테스트

```bash
swift test    # 전체 테스트 실행 (Xcode 필요)
```

Unit test (LogRedactor, UsageDisplayData, DomainWhitelist) + Integration test (CursorAPIClient with URLProtocol mock). 수동 테스트 항목은 [test-checklist.md](docs/test-checklist.md) 참고.

## 라이선스

MIT

---

# CursorBar (English)

A lightweight macOS menu bar app for monitoring [Cursor](https://www.cursor.com/) IDE usage. Built from scratch to address security issues found in CodexBar. See the [security audit report](docs/security-audit.md) for details.

## Features

- View request usage (used/limit) and reset date from the menu bar
- In-app WebView login (Google, GitHub, Enterprise SSO)
- Auto-refresh at configurable intervals (1/2/5/15 min)
- Keychain-based credential storage

## Security

- Zero external dependencies (macOS SDK only)
- WebView domain whitelist enforced
- `URLSessionConfiguration.ephemeral` (no disk cache)
- No JavaScript injection
- Data Protection Keychain (no access prompts)

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6.0+ (for building)

## Build & Install

```bash
# Build + create .app bundle (ad-hoc signed)
bash Scripts/package_app.sh

# Install
cp -r CursorBar.app /Applications/
```

## Testing

```bash
swift test    # Run all tests (requires Xcode)
```

Unit tests (LogRedactor, UsageDisplayData, DomainWhitelist) + Integration tests (CursorAPIClient with URLProtocol mock). See [test-checklist.md](docs/test-checklist.md) for manual test scenarios.

## License

MIT
