# MEIT iOS

현재 단계: **Phase 6A - Single-iPhone stabilization**.

Phase 6A: **implemented / device validation pending**.
Phase 6B: **Four-iPhone calibration and final integration — pending devices** (이번 단계에서 구현하지 않음).

| 단계 | 범위 | 검증 상태 |
|---|---|---|
| Phase 0 | GitHub Actions unsigned IPA build | 실제 빌드·Sideloadly 설치·앱 실행 확인 |
| Phase 1 | iPhone microphone capture + RMS | 권한, 48,000 Hz / mono, RMS, Start/Stop 실기기 확인 |
| Phase 2 | Native PCM → 16 kHz mono PCM16, 2.5초 rolling buffer | 실기기 40000 samples / 80000 bytes / 2.500 s / snapshot 확인 |
| Phase 3 | 한 iPhone의 수동 snapshot → Windows 기존 AI → 결과 표시 | 실제 Wi-Fi end-to-end inference 확인 |
| Phase 4 | FRONT / RIGHT / BACK / LEFT, RMS 방향, 해당 iPhone system vibration | 단일 실기기 진동·capture 중 진동 확인, 실제 4-phone 방향 검증 필요 |
| Phase 5 | 중앙 RMS event → 한 iPhone snapshot → 기존 AI → targeted vibration | 사용자 단일 iPhone 검증: 자동 siren 99.7%, FRONT / UNKNOWN / 진동 없음 |
| Phase 6A | Single-iPhone stabilization / diagnostics / latency / recovery | 구현됨, 새로운 IPA·실기기 반복/장시간 검증 필요 |
| Phase 6B | Four-iPhone calibration and final integration | pending devices, 미구현 |

Phase 0–3, Phase 4 system vibration, Phase 5 단일 iPhone 자동 실행 결과는 사용자 확인에 근거한다.

`meit-ios`는 `meit-ee`의 ESP32 하드웨어 경로에 대비하는 iOS fallback 프로젝트다.
장기적으로 여러 iPhone 15/16을 마이크 입력 및 haptic 출력 장치로 사용하고,
Windows 노트북의 기존 `meit-ai` 위험음 분류 모델과 연결할 예정이다.
현재 앱은 실제 입력의 RMS(dBFS)와 변환된 AI 입력 버퍼의 규격·준비 상태를 표시한다.
Phase 3에서는 수동 HTTP snapshot 전송과 기존 meit-ai 결과 표시를 추가한다.
Phase 4에서는 네 역할의 RMS 보고·방향 추정과 해당 iPhone 진동을 추가한다.
Phase 5에서는 bridge가 자동 이벤트와 단일 audio source를 선택한다. TDoA와 녹음 파일 저장은 구현하지 않는다.

## Operating Modes

하나의 앱에서 상단 segmented picker로 **Hardware / iPhone Fallback** 운용 경로를 선택한다.

| 모드 | 현재 범위 |
|---|---|
| Hardware Mode | UI shell implemented / meit-ee integration pending |
| iPhone Fallback | 기존 Phase 0–6A 구현과 진단 화면 유지 |

- `OperatingMode`의 `hardware` / `fallback` 값을 `@AppStorage("meit.operatingMode")`로
  UserDefaults에 저장한다. 첫 실행 기본값은 Hardware이며 이후 마지막 선택을 복원한다.
- `ContentView`가 AudioCaptureManager, NetworkManager, DeviceCoordinator, HapticManager를
  각각 하나의 `@StateObject`로 소유한다. Fallback은 같은 객체를 `@ObservedObject`로 받는다.
- Fallback → Hardware 전환 시 capture 및 대기 중 Start/Check Snapshot 작업, 수동 요청,
  자동 snapshot/upload, 등록·RMS 보고·command polling 및 후속 진동을 정리한다.
  기존 capture/session ID 검사가 늦은 권한·네트워크 응답을 무효화한다.
- 주소·role·UUID와 서버 설정을 삭제하지 않는다. 주소는 기존처럼 앱 세션 안에서 유지하고,
  role·UUID는 기존 UserDefaults 저장을 유지한다. 다른 폰에도 영향을 주는 서버의 전역 Auto 설정은
  변경하지 않는다. 이미 서버가 수락한 추론이나 OS에 전달된 한 번의 진동은 취소할 수 없다.
- Hardware → Fallback 복귀 시 이전 연결 성공 주소가 있으면 coordination을 다시 연결한다.
  마이크는 자동 시작하지 않으며 사용자가 **Start Capture**를 눌러야 한다.
- Hardware 화면은 Not Connected / —와 비활성 Connect Hardware / Test Motors 버튼만 표시한다.
  iPhone 마이크·PCM 전송·role·진동, ESP32/BLE 통신, 모의 데이터는 사용하지 않는다.

Hardware Mode TODO (이번 단계 미구현):

- ESP32-S3 / meit-ee connection 및 hardware direction input
- AI result synchronization
- motor status 및 motor test command
- system start/stop

### 모드 분리 검증

Windows에서 기존 bridge 테스트 **60개 통과**. 프로젝트 소스 참조·중복 등록, 객체 소유권,
전환 정리 경로 및 전체 diff를 정적 검토했다. Audio/Network/Haptics 내부, Python bridge,
기존 meit-ai, unsigned IPA workflow는 변경하지 않았다.
**이번 모드 분리의 Xcode 컴파일과 실제 iPhone 동작은 아직 검증하지 않았다.**

1. 기존 GitHub Actions를 수동 실행해 Modes의 세 Swift 파일 컴파일, 링크 및 unsigned IPA 생성을 확인한다.
2. 새 IPA 설치 후 저장된 선택이 없으면 Hardware인지, 미연결 표시와 두 비활성 버튼만 있는지 확인한다.
   이 상태에서 마이크 권한 요청·capture·RMS 보고·command polling이 시작되면 안 된다.
3. Fallback을 선택하고 아래 Phase 1–6A 및 bridge 문서의 기존 테스트를 수행한다.
   Start → Buffer Ready, 수동 inference, Auto, registration/RMS, 진동, Diagnostics를 확인한다.
4. capture/Check Snapshot/수동 업로드/자동 업로드/진동 중 각각 Hardware로 전환한다.
   마이크와 반복 요청이 멈추고 이후 진동 burst가 이어지지 않는지 확인한다.
   Start 직후 전환, 빠른 반복 전환, 권한 요청 후 복귀·전환도 검사한다.
5. Fallback 복귀 시 주소·role·UUID가 유지되고 capture는 정지 상태인지 확인한다.
   Start를 눌러 새 buffer가 채워지고 연결·Auto·수동 요청이 정상 복구되는지 확인한다.
6. 두 모드 각각에서 앱 종료·재실행 시 마지막 선택을 복원하는지 확인한다.
   background/foreground 및 10~20분 Fallback 안정성 테스트도 수행한다.

Phase 4 실제 네 iPhone 방향 검증은 여전히 pending이며, Phase 6A single-iPhone stabilization의
실기기 검증과 Phase 6B four-iPhone final calibration도 기존 대기 상태를 유지한다.

## 프로젝트

- SwiftUI, iPhone 전용, deployment target **iOS 17.0** 이상: iPhone 15/16 대상.
- Bundle identifier: `org.meit.ios`. 버전: `0.1.0` (build `1`).
- 앱의 third-party dependency 및 패키지 설치 단계 없음.
- Info.plist는 Xcode가 build settings와 로컬 네트워크용 `MEIT/MEIT/Info.plist`를 합쳐 생성한다. 아이콘은 이 단계에 포함하지 않는다.

```text
meit-ios/
├── MEIT/
│   ├── MEIT.xcodeproj/
│   │   ├── project.pbxproj
│   │   └── xcshareddata/xcschemes/MEIT.xcscheme
│   └── MEIT/
│       ├── MEITApp.swift
│       ├── ContentView.swift
│       ├── Info.plist
│       ├── Modes/
│       │   ├── OperatingMode.swift
│       │   ├── HardwareModeView.swift
│       │   └── FallbackModeView.swift
│       ├── Network/
│       │   ├── NetworkManager.swift
│       │   └── DeviceCoordinator.swift
│       ├── Haptics/HapticManager.swift
│       └── Audio/
│           ├── AudioCaptureManager.swift
│           ├── AIInputProcessor.swift
│           └── AIInputBuffer.swift
├── bridge/
│   ├── server.py
│   ├── meit_ai_adapter.py
│   ├── coordination.py
│   ├── automatic.py
│   ├── test_automatic.py
│   ├── test_reliability.py
│   ├── test_coordination.py
│   ├── test_bridge.py
│   └── README.md
├── .github/workflows/ios-build.yml
├── .gitignore
└── README.md
```

`MEITApp.swift`는 앱 진입점, `ContentView.swift`는 공통 객체 소유·모드 선택·전환 정리를 담당한다.
`Modes/OperatingMode.swift`는 저장 값과 표시 이름, `HardwareModeView.swift`는 하드웨어 UI shell,
`FallbackModeView.swift`는 기존 상태·버튼·오류·Diagnostics 화면을 담당한다.
`Audio/AudioCaptureManager.swift`는 기존 권한·세션·엔진·RMS를 유지하며 AI 처리 수명주기를 연결한다.
`Audio/AIInputProcessor.swift`는 제한된 PCM 복사 큐와 AVAudioConverter를 관리한다.
`Audio/AIInputBuffer.swift`는 규격, 40,000-sample ring buffer, immutable snapshot을 정의한다.
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
  tap의 native 형식을 바꾸지 않는다. 16 kHz 변환은 별도 worker에서만 수행한다.
  화면의 Native Input에는 실제 Hz와 채널 수를 표시한다.
- tap에서 모든 채널의 유효 `frameLength`를 `stride`에 맞춰 읽고 Double로 제곱합을 구한다.
  약 0.1초 분량의 sample power를 평균하여 `RMS = sqrt(mean(sample²))`,
  `dBFS = 20 * log10(RMS)`를 계산한다. 채널을 합쳐 위상이 상쇄되는 방식은 사용하지 않는다.
  비유한 sample은 0으로 취급하며 결과를 -100…0 dBFS로 제한한다.
  첫 측정은 바로 표시하고 이후 UI 값에는 계수 0.25의 지수 평활을 적용한다.
  이 값은 디지털 입력 레벨이며 보정된 음압(dB SPL)이 아니다.
- tap 콜백은 MainActor 밖의 factory에서 만들어 UI actor 격리를 상속하지 않는다.
  tap 전용 계산 객체는 tap 설치 시 한 번 생성하고 콜백만 접근한다.
  콜백은 기존 RMS 계산과 Phase 2의 사전 할당 슬롯으로의 PCM 복사만 수행한다.
  파일·네트워크 I/O, PCM 배열 생성, 변환, UI 수정, 동기 대기는 하지 않는다.
  RMS 숫자만 약 10 Hz로 main queue에 전달하며 공개 상태와 engine 제어는 MainActor에 둔다.
- Start 중이거나 캡처 중이면 중복 Start를 무시한다. Stop은 먼저 캡처 ID를 무효화하고,
  engine을 멈춘 뒤 설치된 tap만 제거하고 engine을 해제한다. RMS는 -100으로 초기화한다.
  이전 권한 요청의 완료나 늦게 도착한 측정값은 새 캡처를 시작하거나 덮어쓸 수 없다.
- 백그라운드 진입·화면 이탈 시 Stop한다. interruption 또는 engine 입력 구성 변경,
  media services reset도 캡처를 정리하고 재시작 안내를 표시한다. 자동 재시작이나
  background audio capability는 추가하지 않는다. 권한 팝업의 일시적인 inactive 상태는
  background로 취급하지 않는다.

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

## Phase 2 변환과 rolling buffer

```text
Native Float32 PCM (hardware sample rate / channels)
  → tap: preallocated slot copy
  → bounded serial worker: equal-weight mono mix (native sample rate)
  → AVAudioConverter: 16,000 Hz / mono / signed Int16
  → 40,000-sample circular buffer
  → makeAIInputSnapshot(): 80,000-byte raw PCM16LE
```

- native rate에서 16 kHz로 변환하는 지속적인 `AVAudioConverter`를 사용한다.
  48 kHz 전용 decimation이나 buffer별 sample 수의 정수 나눗셈은 사용하지 않는다.
  44.1/48 kHz 모두 같은 경로이며, 할당량 보호를 위한 입력 범위는 8…192 kHz / 1…32 ch다.
- mono는 worker에서 native Float32 채널들을 동일 가중치로 평균한다. 각 채널의 stride를
  반영하고 비유한 값은 0으로 처리하며 평균을 -1…1로 제한한다. 단일 채널은 그대로 전달한다.
  별도 channel layout이나 첫 채널 선택에 의존하지 않는다. 역상 채널은 mono 합성 시 상쇄될 수 있다.
- converter 입력은 native-rate mono Float32, 출력은 `.pcmFormatInt16`, 16,000 Hz,
  1 channel, interleaved다. sample-rate 품질은 `.high`, prime method는 `.normal`이다.
  converter가 resampling과 Float32 → signed Int16 변환을 수행한다.
- converter는 캡처 동안 재사용한다. input block의 요청 frame 수만 제공하고 offset을 진행시켜
  동일 sample을 중복 공급하지 않는다. 현재 입력을 모두 쓰면 `.noDataNow`를 반환한다.
  `.inputRanDry`의 부분 출력도 `frameLength`만큼 보관하고 필터·소수 비율 상태는 다음 입력으로
  이어간다. live buffer마다 `.endOfStream`을 보내거나 converter를 reset하지 않는다.
  초기 priming/처리 지연 때문에 Ready가 표시되는 벽시계 시각은 Start 후 정확히 2.5초가 아닐 수 있다.
- ring은 `[Int16]` 40,000개를 한 번 할당한다. write index를 순환하며 오래된 sample을 덮어쓴다.
  `removeFirst()`나 크기 증가가 없으며 append는 새 sample당 O(1)이다. full 이후에도 계속 갱신된다.
  최신 **변환 완료** sample 기준 최근 2.5초이며, UI는 큐 처리 및 polling만큼 늦게 표시될 수 있다.

### Threading과 메모리 제한

- native 슬롯 **4개**를 Start 시 할당한다. 슬롯당 capacity는
  `max(4096, ceil(nativeSampleRate × 0.5))` frames다. tap buffer를 보관하지 않고 유효 PCM만 복사한다.
  `DispatchSemaphore.wait(timeout: .now())`로 즉시 슬롯을 확보하며 오디오 thread를 기다리게 하지 않는다.
- FIFO 직렬 worker에 처리 중인 것을 포함해 native 변환 작업은 최대 4개만 존재한다.
  worker가 작업을 끝낸 뒤에만 슬롯을 재사용한다. mono/feed/output scratch buffer도 재사용한다.
  tap에서는 작은 dispatch closure 외에 입력 크기에 비례한 메모리를 새로 할당하지 않는다.
- 슬롯 부족, 예상보다 큰 입력, 형식 변경, 변환 오류는 캡처를 정지시키고 Error를 표시한다.
  누락된 소리를 이어 붙여 정상적인 연속 2.5초라고 표시하지 않는다. 다시 Start하면 새로 채운다.
- converter와 ring은 worker에서만 접근한다. `@unchecked Sendable`은 이 소유권 규칙과
  semaphore 인계를 명시하기 위한 것이며, 임의의 동시 호출을 허용하는 의미가 아니다.
- MainActor는 약 100 ms마다 **이전 조회가 끝난 뒤** 작은 status를 조회한다. snapshot 요청은
  한 번에 하나만 허용한다. 따라서 status/snapshot 요청도 무한히 적체되지 않는다.
  80,000-byte 할당은 실제 snapshot 요청 때만 worker에서 수행한다. 파일·네트워크·AI 처리는 없다.

### Snapshot API와 불변 조건

```swift
// MainActor에서 호출. buffer 미완성 / 정지 / 다른 snapshot 요청 중이면 nil.
if let snapshot = await audioCaptureManager.makeAIInputSnapshot() {
    let payload = snapshot.pcm16LittleEndian  // Data, 바로 전송 가능한 raw PCM bytes
    // snapshot.sampleRate == 16000
    // snapshot.channels == 1
    // snapshot.sampleFormat == "Int16 (PCM16LE)"
    // snapshot.sampleCount == 40000
    // snapshot.byteCount == 80000
    // snapshot.duration == 2.5
}
```

full 상태에서만 snapshot을 만들고, 가장 오래된 write index부터 **과거 → 현재** 순서로 복사한다.
각 Int16을 하위 byte → 상위 byte로 명시적으로 직렬화한다. WAV header는 없는 **signed PCM16,
little-endian**이며 Windows에서 little-endian signed 16-bit로 그대로 해석할 수 있다.
2's-complement 예: `-32768 → 00 80`, `-1 → FF FF`, `0 → 00 00`, `32767 → FF 7F`.

길이는 생성 시 runtime guard로 확인한다. Debug assertion은 16 kHz / 1 ch / Int16 2 bytes /
40,000 samples / 80,000 bytes / 2.5초를 확인하며 Release를 crash시키는 검증은 사용하지 않는다.
`duration = sampleCount / sampleRate`이고, snapshot은 ring과 별도의 immutable Data다.
Phase 3은 이 API와 payload를 재사용할 수 있다. 현재 전송 API나 서버는 추가하지 않았다.

### Start / Stop

Start마다 새 processor, converter, 슬롯, 빈 ring을 만든다. Stop은 capture ID를 먼저 무효화하고,
status task 취소 → engine 정지·tap 제거 → processor 정리 요청 → UI count 초기화를 수행한다.
worker의 제한된 pending 작업이 끝난 뒤 converter/ring을 reset하고 해제한다.
그 사이의 이전 status, 오류, snapshot 결과는 capture ID 검사로 무시한다.
새 캡처는 별도 processor를 사용하므로 이전 PCM·필터 상태가 섞이지 않는다.
interruption / configuration change / background 처리도 같은 Stop 경로를 사용한다.

[Apple AVAudioConverter sample-rate conversion 안내](https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions),
[부분 출력 상태 설명](https://developer.apple.com/documentation/avfaudio/avaudioconverteroutputstatus/inputrandry)

## Phase 2 실제 iPhone 테스트

1. 기존 수동 Actions workflow에서 새 `AIInputBuffer.swift`, `AIInputProcessor.swift`를 포함한
   컴파일·링크, unsigned 검사, IPA 패키징·업로드가 성공하는지 확인한다. 실패하면 해당 step과
   `MEIT-build-diagnostics/xcodebuild.log`를 확인한다. workflow 자체는 변경하지 않았다.
2. 새 IPA를 Sideloadly로 설치한다. Start 후 기존 권한·Native Input·RMS가 Phase 1처럼 동작해야 한다.
3. AI Input이 `16000 Hz / mono / PCM16 (little-endian)`인지 확인한다. count가 0부터 증가해
   `40000 / 40000 samples`, `80000 bytes`, `2.500 s`, `AI Buffer Ready`가 되어야 한다.
   미완성 상태에서는 Check Snapshot 버튼이 비활성화된다.
4. Check Snapshot을 누르면 **실제 API가 반환한** `40000 samples / 80000 bytes / 2.500 s`가 표시된다.
   데이터는 저장하거나 전송하지 않는다. 10초 이상 계속 캡처하여 count는 40,000에 머무르지만
   `Converted total`은 증가하는지, snapshot을 반복 조회해도 RMS가 계속 변하는지 확인한다.
5. Stop 직후 count/bytes/duration이 0, 상태가 Stopped가 되는지 확인한다. Start → Stop을
   빠른 조작 포함 10회 이상 반복하고, 매 Start마다 Buffering부터 시작하며 이전 Ready/snapshot이
   남지 않는지 확인한다. Snapshot 요청 직후 Stop/재시작하는 경우도 확인한다.
6. buffer가 차는 중과 가득 찬 상태 각각에서 홈 화면·잠금·전화/Siri 중단을 시험한다.
   정지/안내 후 다시 Start하면 새 빈 buffer로 시작해야 한다. Phase 1의 권한 거부/재허용도 재확인한다.
7. 가능하면 실제 native 44.1 kHz / 48 kHz와 다채널 입력 환경에서 같은 출력 규격을 확인한다.
   앱은 native rate나 route를 강제로 변경하지 않는다. 과부하 오류가 발생하면 count가 초기화되고
   캡처가 정지하는지 확인한다. 아직 과부하·다채널·44.1 kHz 실기기 검증은 수행하지 않았다.

현재 UI 검사는 길이·지속 갱신을 확인하는 절차다. 파형 보존, resampling 품질, ring wrap 시 정확한
sample 순서와 endian 해석의 자동화된 수치 검증은 아직 수행하지 않았다.

## Phase 3 수동 AI 연결

`Network/NetworkManager.swift`가 기존 snapshot API와 URLSession을 연결한다.
사용자가 Windows 사설 IPv4를 입력하고 Test Connection / Send Snapshot을 누른 경우만 요청한다.
Snapshot은 16 kHz mono PCM16LE, 40,000 samples / 80,000 bytes / 2.500 s이며 WAV header를 붙이지 않는다.
전송 중 중복 작업을 막고 취소·timeout·연결 실패·잘못된 응답을 화면에 표시한다.

`bridge/server.py`는 표준 라이브러리 직렬 HTTP 서버로 payload를 검사한다.
`bridge/meit_ai_adapter.py`는 별도 기존 meit-ai의 `classifier.adapter.predict_array()`를 호출한다.
모델은 시작 때 한 번 load하고 기존 preprocessing/calibration과 캐시를 재사용한다.
모델 소스·weights·dataset은 이 public repository로 복사하지 않는다.

Windows에서 단위 테스트와 합성 무음 snapshot의 실제 SavedModel HTTP 추론을 확인했다.
이후 사용자가 실제 iPhone → Wi-Fi → Windows → 결과 표시까지 확인했다.
이 기록은 Phase 3 검증이며, Phase 5 자동 동작의 빌드·기기 검증과 구분한다.
**실행 명령, HTTP 계약, 방화벽 및 기기 테스트는 [bridge/README.md](bridge/README.md)를 따른다.**
기존 Audio 소스와 unsigned IPA workflow는 변경하지 않았다.

## Phase 4 네 기기 coordination

동일 앱에서 FRONT / RIGHT / BACK / LEFT 중 역할을 선택한다. 역할과 최초 생성 UUID는
UserDefaults에 저장되며 실제 ID/IP를 소스에 넣지 않는다. Test Connection 성공 후 foreground에서
등록·command polling을 시작하고, capture 중에만 기존 RMS를 약 10 Hz로 보고한다.
수동 Send Snapshot 동작과 기존 80,000-byte PCM 계약은 유지한다.

- `DeviceCoordinator.swift`: 역할·ID, 약 100 ms RMS 보고, 약 200 ms command polling.
  각 루프는 한 요청을 await하므로 backlog를 만들지 않는다. 네트워크 실패는 capture를 멈추지 않는다.
- `HapticManager.swift`: Test Haptic과 서버 명령에 동일한 system vibration 3회를 사용한다.
  `AudioServicesPlayAlertSoundWithCompletion(kSystemSoundID_Vibrate)` 완료 후 200 ms 간격,
  burst 중 중복 차단·cooldown·recording 중 진동 허용·foreground 검사·오류 표시를 유지한다.
- `bridge/coordination.py`: 서버 수신 monotonic 시각, fresh RMS 500 ms, online timeout 5초,
  네 역할 모두 fresh일 때만 corrected RMS 최대값과 runner-up 차이로 방향을 결정한다.
  기본 margin은 3 dB이며 CLI로 조정 가능하다. calibration offset은 기기별 0 dB다.
- `bridge/server.py`: HTTP는 threaded, AI는 별도 lock으로 직렬화한다. 추론 시작 직전 방향을
  고정해 결과에 붙이며 `normal`은 진동을 만들지 않는다. `horn/siren/crash`이고 방향이 확정되면
  해당 기기에만 명령을 생성한다. 기기당 pending 1개, TTL 2초이며 polling에서 한 번 소비한다.

부족한 역할, stale RMS, 역할 충돌, margin 부족은 UNKNOWN으로 표시한다.
Phase 4 수동 기능은 그대로 유지한다. TDoA, class별 진동 패턴, background 보장, 자동 calibration은 포함하지 않는다.

Windows 단위 테스트는 기존 Phase 3 동작과 registration/conflict/stale/margin/command/병렬 요청을
검증한다. **실제 4-phone 검증 전이므로 Phase 4 완료로 표시하지 않는다.**
설정값, HTTP 예제, 전달 손실·중복 방지 정책과 정확한 네 대 테스트 순서는
[bridge/README.md](bridge/README.md)의 Phase 4 절을 따른다.

## Phase 5 자동 감지 / 추론

사용자 확인으로 단일 iPhone 자동 inference 검증 완료. 서버 기본값은 Auto OFF이다.
Test Connection → Start Capture → AI Buffer Ready → **Start Auto Detection** 순서로 사용한다.
Auto는 모든 폰이 공유하는 bridge 설정이며 OFF여도 기존 수동 기능은 유지된다.

- fresh + buffer-ready 기기 중 corrected RMS가 가장 큰 한 기기만 선택한다.
  1~3대여도 자동 AI는 실행하고 direction UNKNOWN이면 방향 진동을 하지 않는다.
- 중앙 상태: `IDLE → WAITING_FOR_AUDIO → INFERENCING → COOLDOWN → IDLE`.
  기본 trigger -30 dBFS, 오디오 대기 3초, 완료 후 cooldown 3초이다.
  다음 이벤트는 fresh RMS가 -33 dBFS 미만으로 750 ms 관측된 뒤에만 재무장한다.
  모두 Phase 6 보정 전 실험 설정이며 상세 CLI는 bridge 문서에 있다.
- 기존 `makeAIInputSnapshot()`과 16000 Hz / mono / PCM16LE / 40000 samples /
  80000 bytes / 2.500 s 계약을 그대로 재사용한다. Audio 소스는 수정하지 않았다.
- 자동 판정은 외부 `decision.judge()`의 기존 confidence 0.4 / 입력 dBFS -50 gate를 재사용한다.
  알림 허용 + trigger 당시 known direction이면 기존 system vibration 명령 하나를 보낸다.
  수동 `/infer`는 Phase 4의 기존 class 판정 동작을 유지한다.
- Auto Stop은 신규 이벤트와 미전달 자동 명령을 차단한다. 실행 중 TensorFlow 호출은
  강제 중단하지 않고 반환 결과/진동을 무효화한다. manual 요청은 독립적이다.
- 주소·role 변경, 비활성화/background, capture 중단 시 자동 업로드 task를 취소한다.
  서버 재시작은 Auto OFF, 현재 이벤트 초기화이며 폰은 기존 등록 재시도를 사용한다.

**Single-iPhone validation**: FRONT 한 대로 위 순서를 실행하고 소리를 재생한다.
Send Snapshot 없이 Source FRONT / label / confidence / Direction UNKNOWN이 표시되고
진동은 없어야 한다. 조용해진 뒤 다시 소리를 내어 다음 이벤트를 확인한다.

**Four-iPhone validation**: 네 role의 capture/RMS를 먼저 준비한 뒤 Auto를 켠다.
한쪽 가까이에서 소리를 내어 loudest source 하나만 업로드하는지 확인한다.
기존 AI가 알림을 허용하고 네 role이 fresh + 3 dB margin이면 해당 폰만 3회 진동해야 한다.

Windows 테스트와 가상 기기를 사용한 실제 SavedModel 결과는
[bridge/README.md](bridge/README.md)의 Phase 5 검증 절에 기록한다.
Phase 5 단일 iPhone 검증과 Phase 6A 변경의 새로운 Xcode 빌드·IPA·실기기 검증을 구분한다.

## Phase 6A: Single-iPhone stabilization

**implemented / device validation pending**. trigger -30 dBFS, rearm -33 dBFS / 750 ms,
cooldown 3000 ms, audio timeout 3000 ms 및 기존 judge 정책을 유지한다. 자동 tuning은 없다.

- Auto 아래 **Diagnostics**에서 현재 RMS/threshold, cooldown 남은 시간, armed/quiet 진행도,
  이벤트 단계별 서버 시각과 다섯 latency 구간을 확인한다. 시각은 서버 시작 이후 ms이며 폰 시각과 비교하지 않는다.
- Server polling / registration / RMS reporting / Auto sync / 마지막 성공 경과시간 / 마지막 오류를 구분한다.
  수동 요청 실패 뒤 foreground 복귀 시 이전 연결 성공 주소에 다시 등록하도록 조건을 보완했다.
- `GET /diagnostics`에 최근 event 20개와 고정 카운터를 제공한다. event ID는 앞 8자리만 표시하며
  device UUID/IP/PCM을 포함하지 않는다. 기존 command 전송에 필요한 전체 UUID 계약은 유지한다.
- 이벤트 전환 때만 짧은 console log를 남기며, RMS packet마다 출력하거나 파일에 오디오를 저장하지 않는다.
- Audio pipeline, system vibration, 방향 알고리즘, 외부 AI 및 unsigned workflow는 변경하지 않는다.

상세 timing 정의, Windows soak 결과, A–I 단일 기기 체크리스트와 소리별 실험표는
[bridge/README.md](bridge/README.md)의 Phase 6A 절을 따른다.
발표 전 실제 폰에서 baseline → 지속음 → quiet/rearm → Auto OFF → 수동 fallback →
Stop/Start → 서버 재시작 → background/foreground → **10~20분 실행**을 확인해야 한다.
실제 네 대 calibration / margin 최종 tuning / 통합 검증은 **Phase 6B — pending devices**다.

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

작성 환경은 **Windows이며 Xcode가 없다**. Phase 0–3의 실제 기기 검증은 사용자 확인으로
완료했다. Phase 4 system vibration과 capture 중 진동도 사용자 확인으로 검증되었다.
Phase 5는 실제 단일 iPhone에서 자동 siren 99.7% 결과를 확인했다.
**Phase 6A 변경의 Xcode 컴파일·IPA·실기기 안정성 및 실제 네 iPhone 동시 방향은 아직 검증하지 않았다.**
Windows bridge의 기존·신규 단위 테스트 및 정적 검토를 수행한다. 가상 device/합성 PCM으로
실행한 검증은 실제 microphone 감도·방향 정확도·물리적인 진동을 확인한 것이 아니다.
기존 unsigned workflow로 빌드한 뒤 bridge 문서의 Phase 6A 단일 iPhone 체크리스트를 수행해야 한다.

runner 이미지와 기본 Xcode는 갱신될 수 있다. 각 실행의 **Set up job**과
**Inspect Xcode and iOS SDK** 로그를 기준으로 빌드 환경을 확인한다.
[macos-15 runner의 설치 도구 목록](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)
