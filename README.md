# MEIT iOS

현재 단계: **Phase 0 - iOS build pipeline validation**.

`meit-ios`는 `meit-ee`의 ESP32 하드웨어 경로에 대비하는 iOS fallback 프로젝트다.
장기적으로 여러 iPhone 15/16을 마이크 입력 및 haptic 출력 장치로 사용하고,
Windows 노트북의 기존 `meit-ai` 위험음 분류 모델과 연결할 예정이다.
현재 앱은 **MEIT iOS** 텍스트만 표시하며, 오디오·햅틱·통신·모델 기능은 구현하지 않는다.

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
│       └── ContentView.swift
├── .github/workflows/ios-build.yml
├── .gitignore
└── README.md
```

`MEITApp.swift`는 앱 진입점, `ContentView.swift`는 화면이다.
`project.pbxproj`는 타깃·소스·빌드 설정을 정의하고, 공유 `MEIT.xcscheme`은 CI에서
같은 scheme을 찾도록 한다. `.gitignore`는 빌드 산출물과 Xcode 개인 설정을 제외한다.

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

작성 환경은 **Windows이며 Xcode가 없다**. 로컬 Xcode 빌드 성공을 의미하지 않는다.
첫 GitHub Actions 실행에서 프로젝트 로딩, Swift 컴파일·링크, 자동 Info.plist 생성,
서명 없는 앱 생성, IPA 패키징 및 artifact 업로드를 실제 검증해야 한다.
실제 iPhone 15/16에서의 실행과 Sideloadly 서명·설치도 아직 검증하지 않았다.

runner 이미지와 기본 Xcode는 갱신될 수 있다. 각 실행의 **Set up job**과
**Inspect Xcode and iOS SDK** 로그를 기준으로 빌드 환경을 확인한다.
[macos-15 runner의 설치 도구 목록](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)
