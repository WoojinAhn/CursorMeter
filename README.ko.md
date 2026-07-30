[English](README.md) | **한국어**

<p align="center">
  <img src="Resources/AppIcon.png" width="80" alt="CursorMeter icon">
</p>

<h1 align="center">CursorMeter</h1>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/github/license/WoojinAhn/CursorMeter" alt="License">
  <img src="https://img.shields.io/github/v/release/WoojinAhn/CursorMeter" alt="Release">
</p>

[Cursor](https://www.cursor.com/) IDE의 사용량을 macOS 메뉴바에서 한눈에 모니터링하는 경량 앱입니다. 브라우저 탭을 열 필요 없이 실시간으로 확인할 수 있습니다.

에디터 내 확장과 달리, CursorMeter는 네이티브 macOS 앱으로 독립 실행됩니다. IDE를 열지 않아도 메뉴바에서 항상 확인 가능하며, Keychain 기반으로 재시작 후에도 로그인이 유지됩니다.

## 주요 기능

- 메뉴바 게이지 링 아이콘으로 사용량 시각화 (초록 → 노랑 → 빨강 색상 단계)
- 메뉴바에서 빌링 사용량, 요청 횟수, 리셋 날짜 확인
- 사용량 임계치 도달 시 macOS 알림 (기본값: 80%/90%, 커스텀 가능)
- **사용량 점프 이펙트** — 사용량이 한 번에 크게 올라가면 메뉴바 아이콘에 ⚡(중간 점프) 또는 🚀(Max 모드급 점프)가 잠시 표시되어, 갑작스런 증가를 놓치지 않게 합니다. 강도 3단계(Quiet / Normal / Bold)와 글리프 스타일(⚡/🚀 또는 💲/💸) 선택 가능, Bold + 큰 점프 조합에선 macOS 알림도 함께 띄움.
- **주간 사용량 차트** (모든 플랜) — 팝오버에 최근 7일 막대 그래프 표시. 막대 높이는 Cursor의 가중 과금 단위(`requestsCosts`) 합으로 그려져, Max-mode Opus 한 콜이 가벼운 자동완성 수십 개를 상대적으로 압도합니다. 호버 tooltip은 plan 흡수된 날은 가중 단위 정수, on-demand 청구된 날은 실제 달러로 자동 분기. 오늘 강조 스타일 3가지(Outline / Dim / Both) 선택 가능.
- 메뉴바 표시 모드: 아이콘만, 분수(사용/한도), 퍼센트(%) 중 선택
- 설정 UI (새로고침 간격, 알림 임계치, 메뉴바 표시 형식, 점프 이펙트 강도, 주간 차트 스타일)
- 로그인 시 자동 실행 지원
- 앱 내 업데이트 확인
- **제로 설정 로그인** — 같은 Mac의 Cursor IDE에 로그인되어 있으면 별도 로그인 없이 자동 연결됩니다. IDE에 로그인되어 있지 않으면 팝오버가 안내합니다: 클릭 한 번으로 IDE가 열리고, 로그인을 마치는 순간 앱이 스스로 연결됩니다. 로그아웃하면 자동 IDE 연결도 재연결 전까지 일시 중지됩니다.
- **브라우저(WebView) 로그인은 deprecated** — 여전히 동작하지만(Google, GitHub, Enterprise SSO), 설정 → General → "Enable browser login" 옵트인 뒤로 숨겨졌습니다. Cursor IDE 앱이 설치되어 있지 않은 경우에만 자동으로 다시 노출되므로, 연결 경로가 없어지는 일은 없습니다.
- 자동 새로고침 (1/2/5/15분 간격 선택)
- **활동 기반 새로고침** — Cursor를 사용하면 다음 폴링을 기다리지 않고 약 1분 내에 앱이 새로고침되어, 작업 직후에도 사용량이 최신 상태로 유지됩니다. 간격 폴링은 fallback으로 계속 동작합니다. 설정 → Refresh → "Refresh on Cursor activity"에서 켜고 끌 수 있습니다.
- Keychain 기반 인증 정보 저장
- 순수 AppKit 기반 — 가벼운 메모리 풋프린트 (idle ~17 MB, 팝오버를 한 번 연 이후엔 ~33 MB; macOS가 AppKit/popover state를 유지해 다시 여는 속도 즉시). 주간 차트가 필요 없고 옛 ~15 MB 풋프린트가 더 낫다면 이전 안정 릴리즈 [v0.2.1](https://github.com/WoojinAhn/CursorMeter/releases/tag/v0.2.1) 을 받으시면 됩니다.

## 보안 특성

- 외부 의존성 0개 (macOS SDK만 사용)
- 2계층 WebView 호스트 화이트리스트 (exact + suffix), navigation action / response 양쪽에서 `https` 스킴까지 검증
- 로그인 세션 저장 전 필수 쿠키 검증
- GitHub Releases API에서 받은 URL은 호스트 검증 후 `NSWorkspace.open` 호출
- `URLSessionConfiguration.ephemeral` (디스크 캐시 없음)
- Keychain 기반 인증 정보 저장

전체 위협 모델과 신고 정책은 [`SECURITY.ko.md`](SECURITY.ko.md) 참조.

## 요구사항

- macOS 14 (Sonoma) 이상

## 설치

1. [Releases](https://github.com/WoojinAhn/CursorMeter/releases)에서 최신 `.zip` 다운로드
2. (선택) 릴리즈에 `.zip.sha256` 자산이 있으면 다운로드를 확인할 수 있습니다:
   `shasum -a 256 -c CursorMeter-<version>.zip.sha256`
   (손상되거나 잘못된 파일을 걸러냅니다. 배포자 서명이 아닙니다 — 앱은 ad-hoc 서명이므로 4단계 참고.)
3. 압축 해제 후 `CursorMeter.app`을 `/Applications`로 이동
4. 최초 실행 시 macOS가 차단할 수 있습니다 (미서명 앱). 우회 방법:
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

24개 스위트, 400+ 테스트: 뷰모델 로직(인증 체인, stale 감지, 임계치, 점프 이벤트), 커스텀 컨트롤(듀얼썸 range slider), 알림 규칙, 로그 마스킹, URLProtocol mock 기반 API 클라이언트 통합 테스트. 수동 테스트 항목은 [test-checklist.md](docs/test-checklist.md) 참고.

## 주의사항

이 앱은 Cursor의 **비공식 내부 엔드포인트** (usage, auth, dashboard API — 전체 목록은 [`docs/API_REFERENCE.md`](docs/API_REFERENCE.md) 참조)를 사용합니다. 해당 엔드포인트는 사전 고지 없이 변경되거나 차단될 수 있습니다.

## 로드맵

- [ ] 주간 차트 막대에 mode (plan/on-demand) 시각 표시 ([#69](https://github.com/WoojinAhn/CursorMeter/issues/69))
- [ ] 주간 차트에 빌링 사이클 rollover 마커 표시 ([#70](https://github.com/WoojinAhn/CursorMeter/issues/70))

## 기여하기

버그를 발견하셨거나 아이디어가 있으신가요? [이슈를 열어주세요](https://github.com/WoojinAhn/CursorMeter/issues) — 피드백과 제안은 언제나 환영합니다. 현재 Pull Request는 받지 않습니다.

## 스크린샷

<table>
  <tr>
    <th align="center">메뉴바</th>
    <th align="center">팝오버</th>
    <th align="center">주간 차트</th>
    <th align="center">설정</th>
  </tr>
  <tr>
    <td align="center" valign="top"><img src="docs/screenshots/menubar.png" alt="메뉴바" height="40"></td>
    <td align="center" valign="top"><img src="docs/screenshots/popover.png" alt="팝오버" width="240"></td>
    <td align="center" valign="top"><img src="docs/screenshots/popover-weekly.png" alt="주간 차트" width="240"></td>
    <td align="center" valign="top"><img src="docs/screenshots/settings.png" alt="설정" width="240"></td>
  </tr>
</table>

## 라이선스

MIT
