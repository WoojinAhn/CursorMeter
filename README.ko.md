[English](README.md) | **한국어**

# CursorMeter

[Cursor](https://www.cursor.com/) IDE의 사용량을 macOS 메뉴바에서 한눈에 모니터링하는 경량 앱입니다. 브라우저 탭을 열 필요 없이 실시간으로 확인할 수 있습니다.


## 주요 기능

- 메뉴바 파이 차트 아이콘으로 사용량 시각화 (초록/노랑/빨강 색상 단계)
- 메뉴바에서 요청 사용량(사용/한도) 및 리셋 날짜 확인
- 사용량 임계치 도달 시 macOS 알림 (80%/90%, 커스텀 가능)
- 설정 UI (새로고침 간격, 알림 임계치, 메뉴바 표시 형식)
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
cp -r CursorMeter.app /Applications/
```

## 테스트

```bash
swift test    # 전체 테스트 실행 (Xcode 필요)
```

Unit test (LogRedactor, UsageDisplayData, DomainWhitelist, CircularProgressIcon, NotificationManager) + Integration test (CursorAPIClient with URLProtocol mock). 수동 테스트 항목은 [test-checklist.md](docs/test-checklist.md) 참고.

## 주의사항

이 앱은 Cursor의 **비공식 내부 API** (`/api/usage`, `/api/usage-summary`, `/api/auth/me`)를 사용합니다. 해당 엔드포인트는 사전 고지 없이 변경되거나 차단될 수 있습니다.

## 라이선스

MIT
