[English](SECURITY.md) | **한국어**

# 보안 정책

## 취약점 신고

CursorMeter에서 보안 취약점을 발견하셨다면, **공개 이슈로 등록하지 마시고** GitHub Private Vulnerability Reporting을 이용해주세요.

**신고**: [github.com/WoojinAhn/CursorMeter/security/advisories/new](https://github.com/WoojinAhn/CursorMeter/security/advisories/new)

### 포함해주실 내용

- 취약점 설명
- 재현 방법
- 예상되는 영향
- 영향받는 버전 (CursorMeter 릴리즈 태그 및 macOS 버전)

### 처리 절차

1. 위 GitHub advisory 양식으로 비공개 신고
2. 48시간 이내 수신 확인
3. 수정 개발 및 테스트
4. 새 릴리즈 배포
5. GitHub advisory를 통한 공개 고지

---

## 위협 모델

CursorMeter는 비공개 Cursor API를 쿠키 기반 세션 자격증명으로 호출하는 메뉴바 앱입니다. 보호 대상 자산은 다음과 같습니다.

- **Cursor 세션 쿠키** (Keychain 저장), 세션 토큰 유효기간 동안 재사용 가능
- **계정 이메일 / 이름** (`/api/auth/me`에서 추출)

로그인 WebView는 CursorMeter가 서드파티 origin을 로드하는 유일한 지점입니다. 나머지(`/api/usage-summary`, `/api/usage`, `/api/auth/me`)는 `URLSessionConfiguration.ephemeral`로 `cursor.com`에 직접 HTTPS 통신합니다.

## Cursor IDE 자격증명 재사용 (#54)

같은 Mac에 설치된 Cursor IDE가 로그인되어 있으면, CursorMeter는 사용자에게 다시 로그인을 요구하지 않고 IDE의 세션에서 자격증명을 파생합니다.

- **읽는 대상:** `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`의 단일 키 — `cursorAuth/accessToken`.
- **읽는 방식:** 읽기 전용 SQLite 연결(`SQLITE_OPEN_READONLY`, busy timeout 250 ms)을 매 읽기마다 열고 닫습니다. IDE의 저장소에 쓰거나 락을 걸지 않습니다.
- **읽지 않는 것:** `cursorAuth/refreshToken` 및 그 외 모든 키. CursorMeter는 토큰 갱신을 직접 수행하지 않고, IDE가 이미 유지하는 액세스 토큰만 재사용합니다.
- **로깅:** 합성된 세션 헤더는 다른 모든 자격증명과 동일하게 취급되어 절대 로그에 남지 않습니다 (LogRedactor 정책 참고).
- **위협 모델:** 사용자 자신의 머신에 있는 사용자 자신의 자격증명이며, CursorMeter가 이미 보유한 Keychain 저장 쿠키와 동일한 신뢰 경계 안에 있습니다. 새로운 비밀 자산 유형이 추가되지 않으며, 브라우저 로그인(WebView) 경로는 fallback으로 계속 사용 가능합니다.

## WebView 화이트리스트 정책

로그인 WebView(`LoginWindow.swift`)는 모든 navigation을 2계층 호스트 화이트리스트로 검증합니다. 동일한 검증이 `decidePolicyFor navigationAction`과 `decidePolicyFor navigationResponse` 양쪽에서 수행되며, 두 콜백 모두 `scheme == "https"`까지 확인합니다 — 호스트가 화이트리스트에 있더라도 평문 HTTP나 `file:` / `javascript:` / `data:` 스킴은 거부합니다.

### Tier 1 — 정확한 호스트 매칭

서브도메인 takeover나 open redirect가 이 WebView를 경유할 수 있는, 공격면이 큰 부모 도메인에 적용합니다.

| 호스트 | 이유 |
|---|---|
| `cursor.com`, `www.cursor.com`, `authenticator.cursor.sh`, `authenticate.cursor.sh` | Cursor 본체 |
| `accounts.google.com`, `oauth2.googleapis.com` | Google OAuth (well-known 엔드포인트만) |
| `github.com`, `api.github.com` | GitHub OAuth (`pages.github.com` / `gist.github.com` 제외) |
| `js.stripe.com`, `m.stripe.network` | Cursor 대시보드 결제 위젯 |
| `api.workos.com` | WorkOS non-tenant API |
| `login.microsoftonline.com` | Azure AD 진입점 |

### Tier 1 — Google OAuth ccTLD 리다이렉트

Google은 일부 사용자를 `accounts.google.com`으로 보내기 전에 `accounts.google.<ccTLD>`(예: `accounts.google.co.kr`)를 경유하도록 라우팅합니다. 이 항목이 없으면 WebView가 해당 locale hop을 차단하여 Google의 fallback 경로가 동작하게 되고, 사용자에게 보이는 로그인 마찰이 발생합니다.

상위 ~50개 마켓에 한해 `accounts.google.<ccTLD>`를 명시합니다. 의도적으로 좁게 잡았습니다 — `accounts` 서브도메인만 허용하므로 `sites`, `mail`, `pages` 등의 locale 변형은 그대로 차단됩니다. 누락 국가는 reactive 정책: 차단 보고가 들어오면 추가합니다.

배경: Google은 2025년 4월 ccTLD를 단계적으로 폐지하고 `.com` 통합 라우팅으로 전환한다고 발표했습니다. 본 리스트의 relevance는 시간이 지남에 따라 줄어들 것으로 예상합니다.

### Tier 2 — Suffix 매칭

정확한 열거가 비현실적인 영역(Cursor 내부 서비스 세분화, 테넌트별 SSO)에 한해 유지합니다.

| Suffix | 이유 |
|---|---|
| `.cursor.com`, `.cursor.sh` | 내부 서비스 세분화 |
| `.workos.com` | 테넌트별 SSO 커넥션 |
| `.microsoftonline.com` | Azure AD 테넌트 가변성 |

### 적용된 완화책

- `WKWebsiteDataStore.nonPersistent()` — 로그인 WebView는 디스크에 쿠키/캐시를 남기지 않음
- `javaScriptCanOpenWindowsAutomatically = false`
- WebView는 로그인 시에만 열리고 완료 즉시 폐기
- 호스트 검증은 case-insensitive
- `navigationAction`과 `navigationResponse` 양쪽에서 동일한 화이트리스트 적용

### 쿠키 캡처 검증

Keychain 저장 전, `captureAndComplete`는 `requiredCookieNames`에 명시된 모든 쿠키명이 존재하는지 검증합니다. 이는 비인증 쿠키(CSRF, analytics)가 세션 토큰보다 먼저 도착하는 partial-cookie-write 경합을 차단합니다 — 검증이 없으면 빈 세션 헤더로 "성공" 처리되어 이후 모든 API 호출이 무성공 실패합니다.

### 수용된 잔여 위험

Tier 2 suffix 제공자 산하 엔티티(예: 관리되지 않는 `*.workos.com` 테넌트)의 서브도메인 takeover는 원리적으로 로그인 WebView에 도달할 수 있습니다. 영향 범위는 단일 Cursor 로그인 세션으로 한정되며, 테넌트별 SSO를 무한 열거 부담 없이 지원하는 대가로 이 위험을 수용합니다.

### WebView에서 미지원되는 인증 기능

로그인 WebView는 ad-hoc 서명 앱의 `WKWebView`이지 시스템 브라우저가 아닙니다. 다음 Google 계정 기능들은 Apple Developer Program 유료 가입자에게만 부여되는 entitlement(`com.apple.developer.web-browser`, associated domains, iCloud Keychain passkey 접근)에 의존하므로 여기서는 동작하지 않습니다.

- **Passkey / WebAuthn** (Bluetooth 또는 platform authenticator)
- iCloud Keychain passkey 동기화에 의존하는 **기기 간 sign-in**

해당 사용자는 비밀번호 + 2FA, 이메일 인증 코드, 또는 다른 제공자(GitHub, 이메일 링크)로 fallback 해주시기 바랍니다. 이는 CursorMeter의 설계 선택이 아니라 빌드 서명의 제약 조건이며, Google OAuth를 WebView로 임베드하는 다른 ad-hoc 서명 macOS 앱에도 동일하게 적용됩니다. 관련된 Keychain Data Protection 제약은 별도 이슈로 추적되고 있습니다.

## 범위 외

- 상위 의존성(Cursor, Apple SDK, OAuth 제공자)의 취약점 — 해당 벤더에 직접 신고해주세요
- 잠금 해제된 Mac에 물리적 접근이 필요한 이슈
- 로컬 Keychain에 대한 사변적 timing attack
