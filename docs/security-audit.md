# CodexBar Security Audit & CursorBar Mitigation Report

**Date:** 2026-02-26
**Auditor:** Internal
**Target:** CodexBar ([github.com/steipete/CodexBar](https://github.com/steipete/CodexBar)), commit `10808b1`
**Purpose:** Cursor 사용량 모니터링 도구의 사내 배포 적합성 평가

---

## Executive Summary

CodexBar는 다수의 AI 코딩 도구(Cursor, Claude, Copilot 등) 사용량을 메뉴바에서 모니터링하는 macOS 앱이다. 보안 감사 결과 **7개 이슈**를 발견했으며, 사내 배포에 부적합하다고 판단했다. 우리가 필요한 기능은 **Cursor 사용량 모니터링**뿐이므로, 발견된 이슈를 모두 해결한 경량 대체 앱(CursorBar)을 신규 구현했다.

**위험도 분포:** HIGH 1건 / MEDIUM-HIGH 1건 / MEDIUM 3건 / LOW 2건

---

## Findings

### F-01: TLS Certificate Validation Bypass [HIGH]

| 항목 | 내용 |
|---|---|
| **Location** | `Sources/CodexBarCore/Providers/Antigravity/AntigravityStatusProbe.swift:541-571` |
| **Category** | Network Security |
| **Impact** | MITM (Man-in-the-Middle) 공격 가능 |

**Description:**
`InsecureSessionDelegate` 클래스가 `URLSessionTaskDelegate`의 인증서 검증 콜백에서 **서버가 제시하는 모든 인증서를 무조건 신뢰**한다.

```swift
// AntigravityStatusProbe.swift:565-566
if let trust = challenge.protectionSpace.serverTrust {
    return (.useCredential, URLCredential(trust: trust))  // 검증 없이 수락
}
```

**Risk:**
Antigravity IDE의 localhost HTTPS 연결용으로 설계되었으나, 같은 머신의 악성 프로세스가 해당 포트를 가로채면 통신 내용을 탈취/변조할 수 있다. 사내 네트워크 환경에서 로컬 프로세스 간 공격 벡터가 된다.

**CursorBar Mitigation:**
커스텀 `URLSessionDelegate` 없음. macOS 기본 TLS 검증(ATS)만 사용.

---

### F-02: WebView Navigation Unrestricted [MEDIUM-HIGH]

| 항목 | 내용 |
|---|---|
| **Location** | `Sources/CodexBar/CursorLoginRunner.swift:59-86` |
| **Category** | WebView Security |
| **Impact** | 피싱 공격, 자격증명 탈취 |

**Description:**
`WKNavigationDelegate`의 `webView(_:decidePolicyFor:decisionHandler:)` 메서드가 **구현되어 있지 않다**. 로그인 WebView에서 어떤 URL이든 로드할 수 있으며, 사용자가 피싱 페이지로 유도될 수 있다.

**Attack Scenario:**
1. Cursor 로그인 redirect chain에서 공격자가 중간 URL을 조작
2. WebView가 악성 URL 로드를 차단하지 않음
3. 피싱 페이지에서 Cursor/Google/GitHub 자격증명 탈취

**CursorBar Mitigation:**
`decidePolicyFor` 콜백에서 도메인 whitelist 적용:
- `cursor.com`, `www.cursor.com`, `authenticator.cursor.sh`, `authenticate.cursor.sh`
- `api.workos.com`, `*.workos.com` (Cursor 인증 프로바이더)
- `accounts.google.com`, `github.com`, `*.github.com` (OAuth IdP)
- `login.microsoftonline.com`, `*.microsoftonline.com` (Enterprise SSO / Azure AD)
- `js.stripe.com`, `m.stripe.network` (Dashboard 결제 UI)
- 그 외 모든 도메인 → `.cancel`

---

### F-03: Environment Variable Binary Hijacking [MEDIUM]

| 항목 | 내용 |
|---|---|
| **Location** | `Sources/CodexBarCore/PathEnvironment.swift:132` |
| **Category** | Code Execution |
| **Impact** | 임의 코드 실행 |

**Description:**
`CLAUDE_CLI_PATH`, `CODEX_CLI_PATH`, `GEMINI_CLI_PATH`, `AUGGIE_CLI_PATH` 환경변수로 CLI 바이너리 경로를 덮어쓸 수 있다.

```swift
// PathEnvironment.swift:132
if let override = env[overrideKey], fileManager.isExecutableFile(atPath: override) {
    return override  // 실행 가능 여부만 확인, 서명 검증 없음
}
```

**Risk:**
부모 프로세스(예: 악성 셸 스크립트)가 환경변수를 설정하면, CodexBar가 악성 바이너리를 정상 CLI로 인식하여 실행한다. `isExecutableFile` 검사만으로는 바이너리의 진위를 보장할 수 없다.

**CursorBar Mitigation:**
외부 CLI 호출 없음. 환경변수 의존 없음. HTTP API만 사용.

---

### F-04: Direct Browser Cookie Database Access [MEDIUM]

| 항목 | 내용 |
|---|---|
| **Location** | `Sources/CodexBarCore/BrowserDetection.swift`, `SweetCookieKit` dependency |
| **Category** | Privacy / Permissions |
| **Impact** | 과도한 권한 요구, IT 정책 충돌 |

**Description:**
`SweetCookieKit` 의존성을 통해 Chrome, Firefox, Safari의 쿠키 데이터베이스를 **디스크에서 직접 읽는다**:
- Safari: `~/Library/Cookies/Cookies.binarycookies`
- Chrome: `~/Library/Application Support/Google/Chrome/*/Cookies`
- Firefox: `~/Library/Application Support/Firefox/Profiles/*/cookies.sqlite`

**Risk:**
`Full Disk Access` 권한이 필요하며, 이는 앱에게 사용자의 모든 파일에 대한 접근 권한을 부여한다. 사내 IT 보안 정책에서 Full Disk Access를 일반 앱에 허용하지 않을 수 있다. 또한 Cursor 외의 모든 사이트 쿠키에 접근 가능하다는 점에서 최소 권한 원칙에 위배된다.

**CursorBar Mitigation:**
브라우저 쿠키 DB 접근 없음. 앱 내 WebView로 직접 로그인하여 쿠키를 획득. `Full Disk Access` 불필요.

---

### F-05: Extensive JavaScript Injection in WebView [MEDIUM]

| 항목 | 내용 |
|---|---|
| **Location** | `Sources/CodexBar/OpenAICreditsPurchaseWindowController.swift:446` (~600줄) |
| **Category** | WebView Security |
| **Impact** | 공격 표면 확대 |

**Description:**
OpenAI 결제 페이지 자동화를 위해 **약 600줄의 JavaScript를 WebView에 주입**한다:
- DOM 탐색 및 Shadow DOM 접근
- React fiber tree (`__reactFiber$`) 내부 상태 읽기
- 자동 클릭 및 폼 데이터 조작
- `window.webkit.messageHandlers.codexbarLog.postMessage()`로 Swift에 데이터 전달

**Risk:**
JS 코드 자체는 악의적이지 않으나:
- 주입 대상 도메인에 대한 명시적 제한이 없어 XSS 공격 표면 확대
- JS-to-Swift 메시지 채널이 통제되지 않아 데이터 유출 경로 제공
- 대상 사이트 DOM 변경 시 예측 불가능한 동작 발생 가능

**CursorBar Mitigation:**
JS injection 0줄. `WKUserContentController` 미사용. WebView는 로그인 전용으로만 사용.

---

### F-06: URLSession Disk Cache Leakage [LOW]

| 항목 | 내용 |
|---|---|
| **Location** | 다수 파일 (전역 `URLSession.shared` 사용) |
| **Category** | Data Leakage |
| **Impact** | 민감 정보 디스크 잔류 |

**Description:**
대부분의 API 호출이 `URLSession.shared`를 사용한다. 이 세션은 기본적으로 응답을 `~/Library/Caches/`에 캐시하므로, 사용량 데이터, 인증 토큰 등 민감한 API 응답이 **평문으로 디스크에 잔류**할 수 있다.

**CursorBar Mitigation:**
`URLSessionConfiguration.ephemeral` 사용. 모든 캐시, 쿠키, 자격증명이 메모리에만 존재하고 디스크에 기록되지 않음.

---

### F-07: External Dependencies Without Verification [LOW]

| 항목 | 내용 |
|---|---|
| **Location** | `Package.swift` |
| **Category** | Supply Chain |
| **Impact** | 공급망 공격 |

**Description:**
6개의 외부 의존성을 사용하며, 모두 minimum version constraint (`from:`)로 선언되어 있다:

| Package | Source | Risk |
|---|---|---|
| SweetCookieKit >= 0.4.0 | github.com/steipete/SweetCookieKit | 브라우저 쿠키 DB 접근 |
| Sparkle >= 2.8.1 | github.com/sparkle-project/Sparkle | 자동 업데이트 (코드 실행) |
| Commander >= 0.2.1 | github.com/steipete/Commander | CLI 처리 |
| swift-log >= 1.9.1 | github.com/apple/swift-log | 로깅 |
| swift-syntax >= 600.0.1 | github.com/apple/swift-syntax | 코드 분석 |
| KeyboardShortcuts >= 2.4.0 | github.com/sindresorhus/KeyboardShortcuts | 단축키 |

**Risk:**
- `from:` constraint는 다음 major version 직전까지 허용하므로 의도치 않은 업데이트 가능
- 패키지 서명 검증이나 reproducible build 설정 없음
- 특히 `Sparkle`은 앱 바이너리를 다운로드하여 교체하는 기능이므로 공격 시 높은 영향

**CursorBar Mitigation:**
외부 의존성 0개. 모든 기능을 macOS SDK(`Foundation`, `Security`, `WebKit`, `SwiftUI`)만으로 구현.

---

## Correction Note

초기 분석에서 "cursor-session.json 평문 저장" 이슈를 보고했으나, 코드 감사 결과 **현재 CodexBar는 Keychain을 정상적으로 사용** 중이었다. 다만 `CookieHeaderCache.swift:105`에 `{provider}-cookie.json` 파일 경로 레거시 코드가 존재하여, `KeychainAccessGate` 비활성화 시 평문 fallback이 가능한 구조이다. 프로덕션 환경에서는 해당 경로가 실행되지 않으므로 별도 Finding으로 분류하지 않았다.

---

## Comparison Matrix

| Area | CodexBar | CursorBar |
|---|---|---|
| Credential Storage | Keychain (+ plaintext fallback path) | Keychain only |
| WebView URL Policy | No whitelist | Domain whitelist enforced |
| WebView JS Injection | ~600 lines | 0 lines |
| Browser Cookie Access | Direct DB read (Full Disk Access) | None |
| URLSession | `.shared` (disk cache) | `.ephemeral` (memory only) |
| TLS Validation | `InsecureSessionDelegate` (bypassed) | OS default (ATS enforced) |
| Environment Variables | `*_CLI_PATH` binary override | None |
| External Dependencies | 6 packages | 0 packages |
| Scope | Multi-provider (Cursor, Claude, Copilot, etc.) | Cursor only |
| Permissions Required | Full Disk Access | None (beyond network) |

---

## Conclusion

CodexBar는 다양한 AI 도구를 지원하기 위해 설계된 범용 앱으로, 해당 범용성이 보안 리스크의 근본 원인이다. 우리의 요구사항은 **Cursor 사용량 확인**뿐이므로, 불필요한 기능을 모두 제거하고 보안을 강화한 CursorBar를 사내 배포용으로 사용한다.

**CursorBar의 보안 특성:**
- 외부 의존성 0개 → 공급망 공격 차단
- WebView URL whitelist → 피싱 차단
- Ephemeral URLSession → 디스크 데이터 잔류 없음
- Keychain 전용 저장 → 자격증명 보호
- 추가 권한 불필요 → 최소 권한 원칙 준수
