# 로컬 개발 빌드 서명

CursorMeter는 기본적으로 앱을 임시(ad-hoc) 서명합니다. 재사용할 Apple Development
인증서를 선택하면 로컬 빌드를 교체해도 서명 식별 조건을 유지할 수 있습니다.
직접 빌드한 앱을 교체하는 개발자를 위한 옵션입니다. 다운로드하는 릴리즈나 해당
릴리즈의 업데이트 후 키체인 승인 문제는 바뀌지 않습니다. 공개 배포용 Developer ID
서명·공증은 [#31](https://github.com/WoojinAhn/CursorMeter/issues/31)에서 별도로 다룹니다.

## 최초 설정

1. Xcode의 **Settings → Accounts**에서 Apple 계정으로 로그인하고 팀을 선택합니다.
   무료 계정은 **Personal Team**으로 표시됩니다.
2. **Manage Certificates → + → Apple Development**를 선택합니다. 인증서와 개인키를
   이 Mac에 보관합니다. 개인키가 없는 인증서만으로는 서명할 수 없습니다.
3. 사용할 수 있는 서명 인증서를 확인합니다.

   ```bash
   security find-identity -v -p codesigning
   ```

   Apple Development 항목의 40자리 16진수 값을 복사합니다.
   서명 옵션에는 표시 이름이 아닌 이 인증서 지문을 입력합니다.

Apple Development 인증서는 유료 개발자 프로그램에 가입하지 않아도 발급할 수 있습니다.
([Apple WWDR 인증서 정책 §4.2](https://images.apple.com/certificateauthority/pdf/Apple_WWDR_CPS_v3.0.pdf))
공개 배포용 Developer ID 서명과 공증은 포함되지 않습니다.

Xcode에 인증서가 보여도 위 명령에 유효한 항목이 없다면 인증서 연결 관계를 확인합니다.
WWDR 중간 인증서가 누락된 경우 이런 문제가 생길 수 있습니다.
[Apple의 발급자 진단 안내](https://developer.apple.com/forums/thread/712043)에 따라
[Apple PKI](https://www.apple.com/certificateauthority/)에서 맞는 공개 중간 인증서를 설치합니다.
Apple 인증서는 시스템의 기본 신뢰 설정을 사용합니다. Always Trust로 덮어쓰지 마세요.
개인키를 저장소에 내보내지 마세요.

## 빌드와 확인

저장소 최상위 디렉터리에서 실행합니다.

```bash
CM_DEV_SIGNING_IDENTITY='YOUR_40_HEX_SHA1' bash Scripts/package_app.sh
codesign --verify --deep --strict CursorMeter.app
codesign -d -r- CursorMeter.app
```

자리표시자를 인증서 지문으로 바꿉니다. 지정 요구사항(designated requirement)에
`com.woojin.CursorMeter`와 해당 인증서의 정확한 지문이 들어 있어야 합니다.
기존 `APP_OUTPUT_DIR` 옵션으로 공백이 포함된 출력 경로도 사용할 수 있습니다.
앱은 계속 개발 빌드이며, 인증서를 선택해도 릴리즈 업데이트 확인이 켜지지 않습니다.

이 값은 해당 명령에만 적용됩니다. 여러 로컬 빌드에서 사용하려면 현재 셸에서 변수를
export하고 같은 인증서를 재사용합니다. 컴퓨터별 서명 설정을 커밋하지 마세요.
스크린샷 스크립트도 이 변수를 상속하며, 패키징이 성공한 뒤에 실행 중인 앱을 종료하고
설치된 앱을 교체합니다.

명시적인 빈 값, 인증서 이름, `-`, 잘못된 지문, `BUILD_CHANNEL=release`에서의 명시적
서명 옵션은 오류로 종료됩니다. 서명이나 검증에 실패해도 임시 서명으로 재시도하지 않습니다.

## 키체인 동작과 제약

인증서와 번들 식별자를 재사용하면 빌드가 바뀌어도 서명 식별 조건을 유지할 수 있습니다.
키체인의 접근 권한 검사는 별도로 적용됩니다. 임시 서명이나 다른 서명에서 처음 전환할 때는
승인이 필요할 수 있습니다. 다운로드한 릴리즈로 돌아갈 때도 다시 승인이 필요할 수 있습니다.

이번 검증은 일회용 키체인의 가상 항목을 사용합니다. 서로 다른 A/B 빌드가 인증 UI 없이
항목을 읽고 갱신해야 하며, 임시 서명과 다른 앱 식별자를 사용한 대조군은 읽기가 거부되어야
합니다. 기존 로그인 키체인 항목의 권한을 이전하거나 모든 macOS 버전의 동작을 증명하는
검증은 아닙니다. 모든 앱에 접근을 허용하거나 항목의 partition 보호를 변경하지 않습니다.

같은 서명 인증서를 유지합니다. 인증서를 교체하면 인증서 지문을 포함한 식별 조건도 바뀌므로
새 승인이 필요할 수 있습니다. 만료일은 Xcode에서 확인하세요.
승인 창을 피하려고 기존 로그인 정보를 삭제하거나 접근 보호를 완화하지 마세요.

macOS 26.6.2(Apple Silicon)에서 격리된 읽기·갱신 및 거부 대조군 검증이 통과했고,
정리와 검색 목록·기본 키체인 유지도 확인했습니다. 패키징한 CursorMeter 앱 두 개도
서명 식별 조건은 같고 CDHash는 다르며 엄격한 서명 검증에 통과했습니다. 두 앱을
설치하거나 기존 로그인 정보를 읽지는 않았습니다.

## 기본 방식으로 복귀

```bash
unset CM_DEV_SIGNING_IDENTITY
bash Scripts/package_app.sh
```

변수를 해제하면 임시 서명으로 돌아갑니다. 빈 문자열로 설정하는 것은 명시적인 잘못된
설정이므로 실패합니다. 옵션을 바꿔도 인증서는 폐기하거나 삭제하지 않습니다.
공개 릴리즈 워크플로는 바뀌지 않습니다.
