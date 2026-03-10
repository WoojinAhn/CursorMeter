[English](README.md) | **한국어**

# <img src="Resources/AppIcon.png" width="32" height="32" alt="CursorMeter icon" align="center"> CursorMeter

[Cursor](https://www.cursor.com/) IDE의 사용량을 macOS 메뉴바에서 한눈에 모니터링하는 경량 앱입니다. 브라우저 탭을 열 필요 없이 실시간으로 확인할 수 있습니다.

에디터 내 확장과 달리, CursorMeter는 네이티브 macOS 앱으로 독립 실행됩니다. IDE를 열지 않아도 메뉴바에서 항상 확인 가능하며, Keychain 기반으로 재시작 후에도 로그인이 유지됩니다.


## 주요 기능

- 메뉴바 파이 차트 아이콘으로 사용량 시각화 (초록/노랑/빨강 색상 단계)
- 메뉴바에서 요청 사용량(사용/한도) 및 리셋 날짜 확인
- 사용량 임계치 도달 시 macOS 알림 (80%/90%, 커스텀 가능)
- 메뉴바 표시 모드 전환: 분수(사용/한도) 또는 퍼센트(%)
- 설정 UI (새로고침 간격, 알림 임계치, 메뉴바 표시 형식)
- 로그인 시 자동 실행 지원
- 앱 내 업데이트 확인
- 앱 내 WebView 로그인 (Google, GitHub, Enterprise SSO 지원)
- 자동 새로고침 (1/2/5/15분 간격 선택)
- Keychain 기반 인증 정보 저장
- 순수 AppKit 기반 — 최소 메모리 사용량 (~13 MB RSS)

## 보안 특성

- 외부 의존성 0개 (macOS SDK만 사용)
- WebView 도메인 whitelist 적용
- `URLSessionConfiguration.ephemeral` (디스크 캐시 없음)
- JavaScript injection 없음
- Keychain 기반 인증 정보 저장

## 요구사항

- macOS 14 (Sonoma) 이상

## 설치

1. [Releases](https://github.com/WoojinAhn/CursorMeter/releases)에서 최신 `.zip` 다운로드
2. 압축 해제 후 `CursorMeter.app`을 `/Applications`로 이동
3. 최초 실행 시 macOS가 차단할 수 있습니다 (미서명 앱). 우회 방법:
   - 앱을 **우클릭** → **열기** → 대화상자에서 **열기** 클릭
   - 또는: 시스템 설정 → 개인정보 보호 및 보안 → **확인 없이 열기** 클릭

## 소스에서 빌드

```bash
# 빌드 + .app 번들 생성 (ad-hoc 서명)
bash Scripts/package_app.sh

# 설치
cp -r CursorMeter.app /Applications/
```

Swift 6.0+ 및 Xcode가 필요합니다.

## 테스트

```bash
swift test    # 전체 테스트 실행 (Xcode 필요)
```

Unit test (LogRedactor, UsageDisplayData, DomainWhitelist, CircularProgressIcon, NotificationManager) + Integration test (CursorAPIClient with URLProtocol mock). 수동 테스트 항목은 [test-checklist.md](docs/test-checklist.md) 참고.

## 주의사항

이 앱은 Cursor의 **비공식 내부 API** (`/api/usage`, `/api/usage-summary`, `/api/auth/me`)를 사용합니다. 해당 엔드포인트는 사전 고지 없이 변경되거나 차단될 수 있습니다.

## 로드맵

- [ ] 요청 한도 소진 시 On-demand 사용량으로 프로그레스 전환 ([#36](https://github.com/WoojinAhn/CursorMeter/issues/36))

## 라이선스

MIT
