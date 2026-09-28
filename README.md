# MEIT iOS

현재 단계: **Phase 1 - Microphone capture and real-time RMS (dBFS)**.

Phase 0 - iOS build pipeline validation: GitHub Actions 빌드와 unsigned IPA 생성,
Sideloadly를 통한 실제 iPhone 설치·앱 실행을 사용자 확인으로 완료했다.

`meit-ios`는 `meit-ee`의 ESP32 하드웨어 경로에 대비하는 iOS fallback 프로젝트다.
장기적으로 여러 iPhone 15/16을 마이크 입력 및 haptic 출력 장치로 사용하고,
Windows 노트북의 기존 `meit-ai` 위험음 분류 모델과 연결할 예정이다.
현재 앱은 마이크 권한을 요청하고, 실제 입력의 RMS(dBFS)를 실시간 표시한다.
네트워크/Wi-Fi, meit-ai 연결, 여러 기기 연결, 방향 추정, 햅틱, 녹음 파일 저장은 구현하지 않는다.

## 프로젝트

- SwiftUI, iPhone 전용, deployment target **iOS 17.0** 이상: iPhone 15/16 대상.
- Bundle identifier: `org.meit.ios`. 버전: `0.1.0` (build `1`).
- 앱의 third-party dependency 및 패키지 설치 단계 없음.
- Info.plist는 Xcode가 build settings에서 생성한다. 아이콘은 이 단계에 포함하지 않는다.

```text
meit-ios/
├── MEIT/
│   ├── MEIT.xcodeproj/
│   │   ├── project.pbxproj
│   │   └── xcshareddata/xcschemes/MEIT.xcscheme
│   └── MEIT/
│       ├── MEITApp.swift
│       ├── ContentView.swift
│       └── Audio/AudioCaptureManager.swift
├── .github/workflows/ios-build.yml
├── .gitignore
└── README.md
```

`MEITApp.swift`는 앱 진입점, `ContentView.swift`는 상태·버튼·오류를 표시하는 화면이다.
`Audio/AudioCaptureManager.swift`는 권한·오디오 세션·엔진·RMS와 캡처 수명주기를 관리한다.
`project.pbxproj`는 타깃·소스·빌드 설정을 정의하고, 공유 `MEIT.xcscheme`은 CI에서
같은 scheme을 찾도록 한다. `.gitignore`는 빌드 산출물과 Xcode 개인 설정을 제외한다.

## Phase 1 마이크 입력

- `@MainActor ObservableObject`가 `isCapturing`, `isStarting`, `rmsDBFS`,
  `microphonePermission`, `errorMessage` 및 입력 형식 표시를 관리한다.
- Start를 누르면 iOS 17의 `AVAudioApplication.requestRecordPermission()`으로 권한을 요청한다.
  `notDetermined` / `granted` / `denied`를 구분하며, 거부 시 Settings에서 허용하도록 안내한다.
  Debug/Release 모두 자동 생성 Info.plist에 `NSMicrophoneUsageDescription`을 포함한다:
  **MEIT uses the microphone to detect environmental sounds.**
- `AVAudioSession`은 `.record`, `.measurement`, 옵션 없음으로 설정 후 활성화한다.
  세션 활성화·엔진 시작·세션 비활성화 실패는 화면의 Error에 표시한다.
- 매 Start마다 새 `AVAudioEngine`을 만들고 input node의 `outputFormat(forBus: 0)`을
  그대로 tap에 사용한다. sample rate와 채널 수가 유효한 Float32 입력인지 먼저 확인한다.
  44.1/48 kHz를 강제하거나 16 kHz로 바꾸지 않는다. 화면에 실제 Hz와 채널 수를 표시한다.
- tap에서 모든 채널의 유효 `frameLength`를 `stride`에 맞춰 읽고 Double로 제곱합을 구한다.
  약 0.1초 분량의 sample power를 평균하여 `RMS = sqrt(mean(sample²))`,
  `dBFS = 20 * log10(RMS)`를 계산한다. 채널을 합쳐 위상이 상쇄되는 방식은 사용하지 않는다.
  비유한 sample은 0으로 취급하며 결과를 -100…0 dBFS로 제한한다.
  첫 측정은 바로 표시하고 이후 UI 값에는 계수 0.25의 지수 평활을 적용한다.
  이 값은 디지털 입력 레벨이며 보정된 음압(dB SPL)이 아니다.
- tap 콜백은 MainActor 밖의 factory에서 만들어 UI actor 격리를 상속하지 않는다.
  tap 전용 계산 객체는 tap 설치 시 한 번 생성하고 콜백만 접근한다.
  콜백에서 파일·네트워크 I/O, PCM 배열 생성/복사, UI 수정, 동기 대기를 하지 않는다.
  약 10 Hz로 scalar 결과만 main queue에 비동기 전달하며 모든 공개 상태와 engine 제어는
  MainActor에서 직렬 처리한다. 전달용 작은 closure 외에 매 buffer 할당을 만들지 않는다.
- Start 중이거나 캡처 중이면 중복 Start를 무시한다. Stop은 먼저 캡처 ID를 무효화하고,
  engine을 멈춘 뒤 설치된 tap만 제거하고 engine을 해제한다. RMS는 -100으로 초기화한다.
  이전 권한 요청의 완료나 늦게 도착한 측정값은 새 캡처를 시작하거나 덮어쓸 수 없다.
- 백그라운드 진입·화면 이탈 시 Stop한다. interruption 또는 engine 입력 구성 변경,
  media services reset도 캡처를 정리하고 재시작 안내를 표시한다. 자동 재시작이나
  background audio capability는 추가하지 않는다. 권한 팝업의 일시적인 inactive 상태는
  background로 취급하지 않는다.

Phase 2의 native PCM 처리 지점은 tap 안의 `NativeRMSMeter.consume(_:)` 호출부다.
권한, session, hardware format, tap 수명주기는 재사용할 수 있다. 추후 resampling → mono →
signed PCM16 → 2.5초 버퍼를 별도 처리기로 추가한다. 현재 변환·전송·PCM 보관은 없다.
콜백 밖에서 PCM을 사용할 때는 버퍼가 재사용되므로 사전 할당 저장소 등 별도 소유권 설계가 필요하다.

[Apple 권한 API](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)),
[measurement 모드](https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/measurement),
[Float32 채널 데이터와 stride](https://developer.apple.com/documentation/avfaudio/avaudiopcmbuffer/floatchanneldata)

## Phase 1 실제 iPhone 테스트

1. 기존 workflow를 수동 실행한다. 빌드 로그에서 `AudioCaptureManager.swift`가 컴파일되고,
   `Package unsigned IPA`와 업로드가 성공하는지 확인한다. artifact 내부 앱의 Info.plist에
   위 `NSMicrophoneUsageDescription` 문구가 포함되는지도 확인한다.
2. IPA를 Sideloadly로 서명·설치한다. 첫 권한 요청을 검증할 때는 iOS 권한이 미결정인
   설치 상태를 사용한다. 기존 허용/거부가 유지되어 팝업이 안 뜨는 것은 정상이다.
3. 앱에서 Start Capture를 누르고 권한을 허용한다. `granted` / `Capturing`, 실제 Hz/채널 수,
   변화하는 유한 dBFS가 표시되는지 확인한다. 조용한 환경보다 말하기·박수에서 값이 증가해야 한다.
   실제 방의 배경 소음은 0이 아니므로 조용하다고 반드시 -100 dBFS가 되지는 않는다.
4. Stop을 누르면 `Ready`, -100 dBFS가 되고 측정 갱신이 멈추는지 확인한다.
   Start → Stop을 10회 이상 반복하고 빠르게 눌러도 중복 tap 오류나 crash가 없는지 확인한다.
5. 권한을 거부한 상태에서는 `denied` / `Permission Denied`와 안내가 표시되고 앱이 유지되어야 한다.
   Settings에서 허용하고 앱으로 돌아와 다시 Start하면 캡처가 시작되어야 한다.
6. 캡처 중 홈 화면 이동·화면 잠금 후 돌아오면 자동 재시작 없이 정지 상태여야 한다.
   권한 요청 중 백그라운드로 이동한 경우에도 늦은 허용 응답만으로 캡처가 시작되지 않아야 한다.
7. 전화/Siri 등의 오디오 interruption 또는 입력 변경 후 정지 상태·안내를 확인하고,
   방해 상황이 끝난 뒤 Start로 다시 캡처 가능한지 확인한다.
8. 가능하면 iPhone 15/16 각각에서 몇 분간 실행한다. 입력이 44.1 kHz 또는 48 kHz일 때 모두
   올바르게 갱신되는지 확인한다. 이번 앱에는 sample rate를 강제하는 기능이 없다.

## GitHub Actions 빌드

Workflow 이름은 **Build unsigned iOS IPA**이며 `workflow_dispatch`로만 실행한다.
push나 pull request로는 자동 실행하지 않는다. GitHub Secrets, Apple ID,
인증서, provisioning profile, signing key가 필요하지 않다.
GitHub 공식 checkout/upload-artifact action과 runner 기본 도구만 사용한다.

1. `macos-15` hosted runner에서 소스를 checkout한다. 저장소 권한은 `contents: read`다.
2. 설치된 Xcode 경로 목록, 현재 선택된 Xcode 버전, SDK 목록과 iOS SDK 버전을 출력한다.
   runner의 기본 Xcode를 사용하므로 실제 버전은 실행 로그에서 확인한다.
   `plutil`로 프로젝트 문법을 확인하고 `xcodebuild -list`로 프로젝트와 scheme을 확인한다.
3. 아래 명령으로 Release **device용** 앱을 만든다. 연결된 iPhone이나 simulator 부팅은 필요 없다.
   simulator용 바이너리는 IPA에 사용하지 않는다.

   ```bash
   xcodebuild \
     -project MEIT/MEIT.xcodeproj \
     -scheme MEIT \
     -configuration Release \
     -sdk iphoneos \
     -destination 'generic/platform=iOS' \
     -derivedDataPath "$PWD/build/DerivedData" \
     -resultBundlePath "$PWD/build/MEIT.xcresult" \
     CODE_SIGNING_ALLOWED=NO \
     CODE_SIGNING_REQUIRED=NO \
     CODE_SIGN_IDENTITY="" \
     build
   ```

4. 생성된 `build/DerivedData/Build/Products/Release-iphoneos/MEIT.app`에서
   Info.plist, 실행 파일, arm64 아키텍처와 서명/profile 부재를 확인한다.
5. 앱 번들을 통째로 `build/package/Payload/MEIT.app`에 복사하고,
   `Payload` 폴더를 ZIP 압축해 `build/MEIT-unsigned.ipa`를 만든다.
   `unzip -t`로 ZIP 무결성을 확인하고 내부 목록을 로그에 남긴다.
   `archive`나 서명이 필요한 `-exportArchive` 과정은 사용하지 않는다.
6. **MEIT-unsigned.ipa** artifact와 별도의 **MEIT-build-diagnostics** artifact를
   14일간 보관한다. 진단 자료 업로드는 앞 단계가 실패해도 시도한다.

IPA 내부 구조:

```text
MEIT-unsigned.ipa (ZIP)
└── Payload/
    └── MEIT.app/
        ├── MEIT
        ├── Info.plist
        └── ... Xcode가 생성한 번들 파일
```

이 IPA는 **unsigned** 상태이며 그대로 iPhone에 설치할 수 없다.
Windows의 Sideloadly를 통한 별도 서명 및 기기 설치는 후속 단계다.
App Store 배포는 현재 범위에 포함하지 않는다.

## GitHub 웹에서 수동 실행하기

1. 위 프로젝트와 workflow 파일을 GitHub `meit-ios` 저장소에 commit/push한다.
   최초에는 workflow 파일이 저장소의 **기본 브랜치**에 있어야 한다.
2. 저장소에 쓰기 권한이 있는 계정으로 GitHub에서 **Actions** 탭을 연다.
   Actions가 비활성화되어 있다면 저장소 설정에서 먼저 활성화한다.
3. 왼쪽 목록에서 **Build unsigned iOS IPA**를 선택한다.
4. **Run workflow**를 누르고 빌드할 브랜치를 선택한 뒤, 메뉴 안의
   **Run workflow** 버튼을 누른다.
5. 새 실행 항목을 열고 **Build and package MEIT** job이 성공할 때까지 기다린다.
6. 실행 요약 페이지의 **Artifacts**에서 **MEIT-unsigned.ipa**를 다운로드한다.
   GitHub가 제공하는 artifact ZIP을 한 번 풀면 내부의 `MEIT-unsigned.ipa` 파일을 얻는다.
   이 내부 IPA는 압축을 풀지 않은 채 후속 서명 도구에 전달한다.

**Run workflow**가 보이지 않으면 기본 브랜치의 workflow 파일, 쓰기 권한,
저장소의 Actions 활성화 여부를 확인한다.
[GitHub 공식 수동 실행 안내](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)

## 실패 로그 확인

**Actions → Build unsigned iOS IPA → 해당 실행 → Build and package MEIT**에서
빨간색으로 실패한 step을 펼친다.

- **Inspect Xcode and iOS SDK**: Xcode/SDK 선택, 프로젝트 파싱, scheme 인식 문제.
- **Build unsigned iOS app**: Swift 컴파일·링크·빌드 설정 오류.
  `tee`로 로그를 저장하며 `pipefail`로 실제 빌드 실패가 job에 전달되도록 한다.
- **Package unsigned IPA**: 앱 경로, 실행 파일, arm64, 서명 상태, ZIP 생성 문제.
- **Upload unsigned IPA / Upload build diagnostics**: artifact 업로드 문제.

실행 요약의 **MEIT-build-diagnostics**에는 생성된 경우 `xcodebuild.log`와
`MEIT.xcresult`가 포함된다. 텍스트 로그는 Windows에서도 읽을 수 있고,
`.xcresult`는 Mac의 Xcode에서 열 수 있다. 빌드 전에 실패하면 진단 파일이 없을 수
있으므로 해당 step의 웹 로그를 확인한다. job 화면 메뉴에서 전체 로그도 다운로드할 수 있다.

## 검증 상태와 범위

작성 환경은 **Windows이며 Xcode가 없다**. Phase 0 빌드와 실제 기기 실행은 사용자 확인으로
완료했으나, **Phase 1 변경은 아직 macOS/Xcode 컴파일 및 실제 마이크 동작을 검증하지 않았다**.
기존 unsigned workflow는 변경하지 않았다. 위 Actions 및 iPhone 테스트로 권한 설명 생성,
Swift 컴파일·링크, IPA 패키징, 권한·RMS·반복 Start/Stop을 검증해야 한다.

runner 이미지와 기본 Xcode는 갱신될 수 있다. 각 실행의 **Set up job**과
**Inspect Xcode and iOS SDK** 로그를 기준으로 빌드 환경을 확인한다.
[macos-15 runner의 설치 도구 목록](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)
