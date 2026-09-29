# meit ios

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

## 두 Operating Mode의 최종 구조

두 모드 모두 **iPhone 자체 마이크가 기본 입력**이다. 차이는 최종 알림 출력 경로다.
ESP32의 I2S/INMP441 마이크 입력은 사용하지 않는다. 위 Phase 0–6B 표는 기존 iPhone mode 구현/검증 이력이다.

| 모드 | 목표 경로 | 이번 patch의 실제 구현 범위 |
|---|---|---|
| wearable mode / 웨어러블 모드 | iPhone mic → Wi-Fi → laptop / meit-ai → laptop → ESP32 → DRV8833 → wearable motors | 기존 stereo 방향 + 자동 Wearable AI 추론/결과 표시, 모터 출력 미구현 |
| iPhone mode / iPhone 모드 | iPhone mic → laptop / meit-ai → multi-iPhone direction → target iPhone vibration | 기존 inference / 자동 감지 / coordination / 진동 경로 유지 |

**Wearable mode의 laptop AI 전송은 구현됨 / 이번 변경의 Xcode·실기기 검증 대기. 모터 출력은 미구현.**
ESP32 통신 주체는 Windows laptop bridge다. iOS에 CoreBluetooth, BLE central, ESP32 UUID,
모터 packet 또는 iPhone→ESP32 직접 전송을 구현하지 않는다.

TODO — 이후 별도 단계에서는 아래 경로의 ESP32 command transport와 모터 출력을 구현한다:

```text
wearable mode iPhone audio
→ side-effect-free laptop inference
→ laptop → ESP32 command transport
→ DRV8833 / wearable motor output
```

기존 `POST /infer`는 `coordination.after_inference()`를 통해 다른 iPhone에 `direction_haptic`을
예약할 수 있다. 따라서 wearable mode는 `/infer`와 `/event/audio`를 호출하지 않는다.
Wearable은 전용 `/wearable/observe`와 `/wearable/infer`를 사용한다. 기존 `meit-ai` 소스와 모델은 변경하지 않는다.

## Wearable mode iPhone microphone

사용자 iPhone 16에서 stereo·AI buffer·LEFT/CENTER/RIGHT 검증 완료. **새 AI 전송 경로의 Xcode 빌드 및 실기기 검증은 대기**.

- 입력은 항상 `iPhone microphone / iPhone 마이크`다. 입력 선택 toggle은 없다.
  `start listening / 감지 시작`과 `stop listening / 감지 중지`로 캡처를 시작/종료한다.
  앱 진입이나 foreground 복귀만으로 마이크를 자동 시작하지 않는다.
- 메인은 listening/waiting, 실제 live audio RMS meter, AI server 연결 상태 / wearable 미연결 상태,
  실험적 stream-semantic direction 또는 unavailable, 시작/중지 action과 diagnostics를 표시한다.
  AI server는 Wearable 관측 요청의 실제 성공/실패를 표시하며, 모터 연결은 not connected다.
  주소 입력과 최근 AI 결과만 추가하고, 상세 요청 정보는 고급 진단에 둔다.
  iPhone mode에서 과거 성공한 health check를 Wearable 연결 성공으로 표시하지 않는다.
- `ContentView`가 기존 `AudioCaptureManager` 한 개를 소유한다.
  Capture ownership은 `none / iphoneMode / wearableMode`다. iPhone은 기존 AVAudioEngine/tap,
  Wearable은 AVCaptureSession을 사용하며 두 backend를 동시에 시작하지 않는다.
  `captureID`, wearable request ID, mode generation, 늦은 callback 무효화와 소유자별 정리를 유지한다.
- 내부 `OperatingMode.hardware / fallback`, `meit.operatingMode`, role/UUID 저장 key와 network protocol은 유지한다.
  `WearableMicState`, `audio.wearableMic`, `WearableDirection`은 최근 추가한 wearable 입력 상태의 새 이름이다.
- Wearable native CMSampleBuffer → bounded Float32 adapter → 기존 4-slot AI worker의 mono downmix
  → 16 kHz mono PCM16LE → 2.5초 ring/snapshot을 재사용한다.
  **40,000 samples / 80,000 bytes / 2.5 sec**, PCM buffer ready까지 로컬에서 준비한다.
  Wearable은 전용 관측/AI upload만 시작한다. iPhone registration, `/device/rms`, command polling, 진동은 시작하지 않는다.
- AVCapture input의 `.stereo` 지원을 재확인하고 mode를 설정한다. 실행 mode가 stereo이며 실제
  CMSampleBuffer PCM이 2채널 이상이어야 stereoUsable이다. AVAudioSession polar pattern / inputNode
  채널은 이 backend의 성공 조건이 아니다. 실제 출력이 mono면 성공으로 표시하지 않으며 AI PCM은 준비 가능하다.
- 실제 stereo일 때 기존 RMS meter의 약 100 ms window에서 channel 1/2 RMS와 absolute peak를 계산한다.
  planar/interleaved stride와 기존 aggregate RMS/live meter를 유지하며 별도 DSP pipeline을 추가하지 않는다.
- `StereoDirectionEstimator`의 linear RMS EMA(alpha=0.25), silence=-65 dBFS는 유지한다.
  기존 3 dB margin을 Wearable 실측 실험용 진입 ±0.7 dB / 해제 ±0.5 dB hysteresis로 교체했다.
  CH1=PCM channel 0, CH2=PCM channel 1이다. EMA된 선형 RMS를 dB로 바꾼 차이로 분류한다.
  무음·invalid·mono·semantic mapping 상실은 unavailable 및 smoothing/state reset이다.
- `stereoSemanticMappingAvailable`은 원본 standard Stereo tag와 2채널 ASBD 확인을 뜻한다.
  `physicalMappingVerified`는 별도의 물리 calibration이며 계속 false다. 기존에는 물리 방향 노출을 막는
  gate로 사용했지만, 이제 UI의 실험적 semantic direction과 구분한다. 특정 마이크 위치를 추측하지 않는다.
  기본 진단과 Wearable 메인의 방향은 Left / Center / Right / Unavailable이다. Center는 실제 정면 보장이 아니다.
- Diagnostics는 iPhone 입력 label, route, session/node/buffer channels, stereo usable,
  channel 1/2 RMS·peak, channel dominance, polar patterns/orientation, physical mapping,
  PCM buffer ready 및 오류를 표시한다.
- `audio.wearableMic`의 `direction`, `channelDominance`, `audioReady`, `stereoUsable`,
  `physicalMappingVerified`는 향후 **iOS→laptop metadata/state**로 활용할 수 있다.
  안정화된 direction은 전용 AI 요청 metadata로 사용한다. iPhone→ESP32 직접 전송은 없다.
- Wearable 캡처가 변경한 session preference는 종료 시 복원한다. 원래 preferred channel 수가 0이면
  API가 0을 거부하므로 시작 전 실제 채널 수를 복원한다. 실패하면 표시하고 다음 시작 전에 재시도한다.
  기존 converter/ring, NetworkManager, DeviceCoordinator, HapticManager, iPhone mode 화면/기능은 유지한다.

### Wearable automatic AI inference — device validation pending

- 기존 NetworkManager/HTTP 세션과 immutable AI snapshot을 재사용한다. Wearable capture와 서버 주소가
  준비되면 약 200 ms 간격으로 `/wearable/observe`에 RMS·buffer readiness를 보낸다. 실패 시 1초 간격으로 재확인한다.
- RMS gate는 `bridge/event_gate.py`의 공통 함수다. 실제 bridge 설정을 그대로 사용한다:
  기본 trigger >= -30 dBFS, quiet < -33 dBFS가 750 ms 관측되면 rearm, 추론 종료 뒤 3000 ms cooldown.
  지속음은 다시 trigger하지 않는다. 조용한 관측이 끊기면 quiet 시간을 새로 센다.
- bridge가 새 event를 반환할 때만 현재 AI ring에서 직전 2.5초 snapshot을 얻는다. 별도 녹음/저장/변환은 없다.
  정확히 16 kHz / mono / signed PCM16LE / 40,000 samples / 80,000 bytes일 때 `/wearable/infer`로 보낸다.
- snapshot 요청 시점의 stable direction을 `X-Wearable-Direction`에 전달한다. unavailable/미제공은 응답의 null이다.
  방향은 classifier 입력이 아니며, 응답 시점의 최신 방향으로 덮어쓰지 않는다.
- 기존 adapter `infer_auto` → `_predict` → `classifier.adapter.predict_array`와 `decision.judge`를 재사용한다.
  label은 horn/siren/crash/normal이며, 기존 confidence >= 0.4 및 dB >= -50 조건을 통과한 위험음만 danger=true다.
  일반음/낮은 신뢰도도 원래 label/confidence와 danger=false로 표시한다. 새 alert나 command는 만들지 않는다.
- iOS는 한 serial task, bridge는 한 bounded pending/busy slot과 기존 model lock을 사용한다.
  Stop/백그라운드/모드/주소 변경 시 iOS 작업·generation을 무효화한다. 이미 시작된 모델 호출은 중단하지 않지만
  응답은 버려지고 slot은 완료까지 유지된다. 모델 실행 중 새 세션 요청은 409 후 재시도된다.
- 기본 진단의 4개 행은 유지한다. AI label/confidence, 최근 전송 방향/바이트, 왕복 지연, 결과 시간,
  기존 danger 판정, 마지막 오류는 고급 진단에 표시한다. 네트워크/추론 실패는 audio capture를 stop하지 않는다.
- Windows Python 테스트: 기존 60 + Wearable 19 = 79개 모두 통과. 영어/한국어 215 keys 일치,
  project/source references와 diff whitespace 검사를 통과했다.
- Windows의 mock classifier 테스트는 실제 모델 정확도·Swift 컴파일·실기기 네트워크 검증을 대신하지 않는다.
  GitHub Actions는 unsigned 앱 build만 수행하며 Swift unit tests를 실행하지 않는다.

실기기 재검증:

1. 기존 환경의 Windows bridge를 새 코드로 재시작한다: `.\.venv\Scripts\python.exe -B bridge/server.py --ai-path C:\meit-ai`.
2. 새 IPA를 설치하고 Wearable에서 Windows 사설 IPv4 입력 → 감지 시작 → AI server 연결 및 40,000 samples 확인.
3. LEFT/CENTER/RIGHT, stereo 2ch와 RMS가 계속 동작하는지 확인한다.
4. 경적/사이렌/충돌 테스트 음원을 재생하여 label·confidence·요청 시점 방향을 확인한다.
   bridge의 `[WEARABLE] POST /wearable/infer completed` 로그와 고급 진단의 80,000 bytes도 확인한다.
5. 같은 소리를 계속 재생해 중복 추론이 없는지 확인하고, 조용한 구간과 cooldown 후 새 소리로 다시 추론한다.
6. unavailable 방향에서도 AI가 동작하며 임의 방향을 채우지 않는지 확인한다.
7. 서버 중지/복구, 추론 중 Stop/Start·모드 전환·주소 변경으로 capture 지속과 늦은 응답 폐기를 확인한다.
8. Wearable 추론은 iPhone 진동/coordination command를 만들지 않아야 한다. iPhone mode로 돌아가 기존
   수동·자동 추론과 기존 조건을 충족한 targeted haptic을 회귀 검증한다.

### Wearable AVCapture stereo backend

사용자 iPhone 16 기본 모델 capability 결과: input=true, stereo=true, FOA=true, 조회용 mode=none.
후속 사용자 실기기 확인: active mode=stereo, actual PCM=2채널, stereo usable=true, AI buffer=40,000/40,000.
이번 portrait orientation patch의 적용 결과와 반복 실행 안정성은 별도 실기기 검증이 필요하다.
이전 AVAudioSession data-source 경로의 bottom/Omnidirectional/1채널 결과와 모순되지 않는다.

- `wearableMode`만 `WearableStereoCapture` helper를 사용한다. iPhone mode의 `.record + .measurement`,
  AVAudioEngine, input tap 및 기존 AI/network/coordination/haptic 경로는 유지한다.
- 공유 session의 category/mode/options와 input/source/pattern/orientation/channel preference를 저장한다.
  Built-in input을 지정하고 AVCapture의 자동 audio-session 구성을 허용한다. Apple은 자동 설정 후
  원래 session을 복원하지 않으므로, backend 정지/정리 후 저장한 설정을 명시적으로 복원한다.
- session queue에서 stereo 지원 재확인 → `input.multichannelAudioMode = .stereo` → input/output 추가
  → delegate 연결 → commit → startRunning 순서로 시작한다. iOS 18+가 필요하며 FOA는 사용하지 않는다.
  `audioSettings`는 iOS에서 설정하지 않는다(macOS API). 실제 native 출력 형식을 sample에서 읽는다.
- Delegate는 최대 4개 CMSampleBuffer만 retain해 별도 serial worker로 전달한다. PCM allocation, format
  adapter, AI processor 초기화와 계산은 worker에서 수행한다. 밀리면 무한 적재/조용한 누락 대신 오류로 중지한다.
- 첫 sample의 ASBD에서 rate/channels/format ID/flags/bits/interleaving을 읽는다. Linear PCM만 허용하며
  sample rate는 8–192 kHz, channels는 1–32, 버퍼는 최대 0.5초(최소 4096 frames)로 제한한다.
  Format 변경, 데이터 미준비, 복사/변환 실패 및 용량 초과는 오류로 처리한다. 5초간 PCM이 없으면 중지한다.
- `CMSampleBufferCopyPCMDataIntoAudioBufferList`로 재사용 native buffer에 복사한다. `AVAudioConverter`
  의 `convert(to:from:)`는 **같은 sample rate/channel count**에서 Float32 planar 표현으로만 바꾼다.
  새 resampler/ring은 없다. 기존 AIInputProcessor가 mono downmix / 16 kHz PCM16LE 변환을 수행한다.
- 기존 NativeRMSMeter와 StereoDirectionEstimator를 공유한다. Overall RMS는 모든 채널의 평균 power의
  제곱근이며 반대 위상도 상쇄하지 않는다. AI mono mix는 기존 signed sample 평균이다. 두 정의를 구분한다.
  CH1/CH2 RMS·peak 및 semantic direction을 실험한다. Physical mapping은 계속 false이며 motor 방향을 검증하지 않는다.
- 기본 진단 네 항목은 유지한다. 고급 진단의 probe mode는 조회용으로 남고, 별도로 active capture mode와
  실제 PCM rate/format/flags/bits/interleaving을 표시한다. Input node는 이 backend에서 사용하지 않는다고 표시한다.
- Stop은 captureID를 즉시 무효화하고 UI를 초기화한다. Session queue에서 delegate 해제 → delivery drain
  → stopRunning → PCM worker drain/processor stop → input/output/session 해제 후 MainActor에서 session을 복원한다.
  다음 Start는 이 cleanup Task를 기다린 뒤 진행한다. 취소된 Start의 늦은 성공/실패도 captureID로 무시한다.
  Interruption/runtime error/route 변경에서도 자동 재시작하지 않는다. 복원 실패는 다음 Start 전에 재시도한다.
- Wearable의 `/infer`, `/event/audio`, registration/RMS reporting/command polling은 추가하지 않았다.

실기기 검증: 외부 마이크를 분리하고 세로로 고정 → Wearable Start → active mode=stereo와 실제 PCM
2채널 확인 → CH1/CH2 박수/말소리 비교 → 40,000 / 40,000 samples 확인 → Stop/Start 반복 →
background/foreground 및 두 모드 빠른 왕복 → iPhone mode의 기존 추론/진동 기능 회귀 확인.
권한 대기 중 전환, 시작 직후 Stop, interruption 및 오디오 route 변경도 확인한다. Windows의 Python
테스트/정적 검사는 이 Swift backend의 빌드나 실제 stereo 수음을 증명하지 않는다.

근거: [multichannel mode](https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput/multichannelaudiomode),
[automatic session configuration](https://developer.apple.com/documentation/avfoundation/avcapturesession/automaticallyconfiguresapplicationaudiosession),
[PCM copy](https://developer.apple.com/documentation/coremedia/cmsamplebuffercopypcmdataintoaudiobufferlist(_:at:framecount:into:)),
[format-only conversion](https://developer.apple.com/documentation/avfaudio/avaudioconverter/convert(to:from:)).

### Wearable portrait orientation experiment — device validation pending

사용자는 고정된 폰에서 재시작에 따라 CH1/CH2 공간 대응이 뒤집히는 현상을 관찰했다. 기존 코드는
preferred orientation을 저장/복원했지만 시작 전에 특정 orientation을 요청하지 않았다.
이것이 뒤집힘의 확정 원인이라는 뜻은 아니며, 아래 patch로 실제 적용 상태를 먼저 검증한다.

- 물리 기준: portrait, 화면은 사용자 쪽, 상단/수화부는 위, USB-C 모서리는 아래다. 케이블은 연결하지 않는다.
- Session queue에서 input/output `commitConfiguration()` 후 `startRunning()` 직전에
  `setPreferredInputOrientation(.portrait)`를 호출한다. Recording 도중에는 호출하지 않는다.
- `usesApplicationAudioSession=true`, `automaticallyConfiguresApplicationAudioSession=true`를 유지한다.
  현재 성공한 stereo 자동 구성을 보존한다. Apple 문서는 자동 설정이 정확히 언제 끝나는지 보장하지 않으므로
  commit만으로 orientation 적용 완료라고 간주하지 않는다. Start 후 shared session 값을 다시 읽는다.
  자동 구성으로 덮어써져도 capture 중 재설정하지 않고, 고급 진단에서 미확인 상태로 표시한다.
- Requested는 이번 시작에 전달한 값, preferred/actual은 시작 후 조회값이다. PCM reading 시에도
  preferred/actual을 읽기만 한다. Portrait confirmed는 requested/preferred/actual 모두 portrait,
  active mode=stereo, 실제 PCM 2채널 이상일 때만 true다. Stereo usable과 물리 mapping은 별개다.
- 원본 CMSampleBuffer의 `CMAudioFormatDescriptionGetChannelLayout`에서 layout tag와 label을 조회한다.
  `kAudioChannelLayoutTag_Stereo`(사용자 관측값 0x00650002)와 ASBD 2채널이 일치하면 Apple 정의에 따라
  `Stereo (Left, Right)`, channel 0 semantic label=Left, channel 1 semantic label=Right로 표시한다.
  이 tag는 explicit descriptions 없이도 순서를 정의한다. 다른 tag/bitmap은 기존 Core Audio 확장 결과의
  검증된 descriptions만 사용하며, 임의의 순서나 layout 이름을 추측하지 않는다.
  크기/채널 수 검증 실패, metadata 부재, 해석 불가 시 unknown이다. 채널 수만으로 Left/Right를 만들지 않는다.
  Label Left/Right가 있어도 stream role일 뿐 특정 물리 마이크 위치나 물리 방향으로 사용하지 않는다.
  PCM 변환/채널 순서를 바꾸지 않는다. 이 metadata patch는 actual orientation=none 문제를 수정하거나
  audio-session 자동 구성이나 physical mapping을 변경하지 않는다. 이후 semantic estimator patch는 아래 별도 절에 설명한다.
  근거: [Apple standard Stereo ordering](https://developer.apple.com/documentation/coreaudiotypes/kaudiochannellayouttag_stereo).
- 고급 진단에 requested/preferred/actual, 실제 AVCapture audio-session flags, portrait confirmed,
  channel 0/1 label, layout tag, channel delta를 표시한다. 기본 진단과 iPhone Mode UI는 유지한다.
- Channel delta는 표시된 CH1 RMS dBFS − CH2 RMS dBFS다. 기존 -100...0 dBFS clamp를 사용하므로
  silence는 유한 값(양쪽 silence면 0 dB)이다. 방향은 raw delta가 아닌 아래 EMA/hysteresis 상태를 따른다.
- 종료 시 기존 stop/drain barrier 후 저장한 orientation을 포함한 session preferences를 복원한다.
  다음 backend는 정리 완료를 기다린다. 이 patch는 AI converter/ring, iPhone mode, network/AI 서버 연결을 변경하지 않는다.

실기기 절차: 폰을 움직이지 않고 같은 음원 위치/음량으로 Start → 소리 → 기록 → Stop을 **최소 5회** 반복한다.
각 회차에 requested/preferred/actual, active mode, 실제 채널 수, 두 session flags, channel 0/1 label,
layout tag, CH1/CH2 RMS·peak, delta, dominance를 기록한다. Portrait orientation confirmed는 세 값이 모두
portrait일 때만 true이며 아래 semantic 방향의 활성 조건과는 별개다. 같은 위치 음원에서 채널 대응이
뒤집히지 않는지 확인한다. Physical mapping은 여전히 미검증이다.
40,000/40,000 samples 유지, background/foreground와 iPhone Mode 왕복 후 기존 기능도 확인한다.
후속 사용자 실험에서 LEFT/CENTER/RIGHT delta 경향이 확인되어 아래 semantic direction 실험을 추가했다. 물리 마이크 위치는 mapping하지 않는다.
Windows 검사로 orientation 안정성이나 Swift/Xcode build 성공을 주장하지 않는다.

근거: [input orientation](https://developer.apple.com/documentation/avfaudio/avaudiosession/inputorientation),
[preferred orientation](https://developer.apple.com/documentation/avfaudio/avaudiosession/setpreferredinputorientation(_:)),
[automatic configuration](https://developer.apple.com/documentation/avfoundation/avcapturesession/automaticallyconfiguresapplicationaudiosession),
[channel layout](https://developer.apple.com/documentation/coremedia/cmaudioformatdescriptiongetchannellayout(_:sizeout:)).

### Wearable RMS semantic direction — device validation pending

사용자 관측: LEFT delta 약 0...+3 dB, CENTER 약 0...+0.5 dB, RIGHT 약 0...−2 dB.
범위가 겹치므로 ±0.7/±0.5 dB는 실험 초기값이며 방향 정확도를 보장하는 calibration은 아니다.
Orientation 요청/actual=none 문제와 AVCapture 자동 구성은 이번 patch에서 변경하지 않는다.

- 기존 estimator 하나만 사용한다. 선형 CH1/CH2 RMS EMA(alpha=0.25) 후
  `20 log10(smoothed CH1) − 20 log10(smoothed CH2)`를 사용한다. 0 근처는 기존 meter의 -100 dBFS floor다.
- CENTER(또는 초기 unavailable)에서 delta >= +0.7이면 LEFT, <= -0.7이면 RIGHT, 그 사이는 CENTER.
  LEFT는 >= +0.5에서 유지, 그 미만이면 CENTER. RIGHT는 <= -0.5에서 유지, 그 초과면 CENTER.
  반대쪽으로 바로 전환하지 않고 최소 한 update에서 CENTER를 거친다. 일정 시간 유지하는 timer는 추가하지 않았다.
- 기존 -65 dBFS silence gate를 raw 입력에 먼저 적용한다. 둘 다 threshold 이하, 음수/NaN/Inf,
  mono/불명확한 mapping이면 즉시 unavailable로 바꾸고 EMA/상태/delta를 초기화한다.
- UI 활성 조건: Wearable active mode=stereo, 실제 buffer >=2채널, stereoUsable,
  원본 `kAudioChannelLayoutTag_Stereo`와 ASBD 2채널이 확인되고 실제 buffer count와 일치,
  silence gate 통과. Generic descriptions에 Left/Right가 있더라도 standard tag가 아니면 활성화하지 않는다.
- Semantic mapping은 metadata의 stream Left/Right 역할이며 물리 마이크 상단/하단 또는 motor 방향을 뜻하지 않는다.
  `physicalMappingVerified=false`를 유지한다. Orientation이 none이라는 이유만으로 semantic 방향을 차단하지 않는다.
- 기본 진단 네 항목은 유지하고 방향 감지 값만 locale에 맞는 Left/Center/Right/Unavailable로 표시한다.
  고급 진단에는 raw/smoothed delta, estimator state, direction, semantic mapping 확인, enter/release threshold를 표시한다.
  Raw delta는 표시용 dBFS 차이로 clamp되고, estimator delta는 EMA RMS에서 계산되어 값이 다를 수 있다.
- 이 방향 단계에서는 로컬 UI/state까지만 구현했다. 위 새 AI 경로는 이 값을 metadata로만 보내며 BLE/motor/haptic은 여전히 없다.
  AIInputProcessor/AIInputBuffer 및 기존 iPhone Mode는 변경하지 않았다.

실기기: 고정된 portrait 상태와 일정한 소리로 LEFT/CENTER/RIGHT 위치를 반복 비교한다.
Raw와 smoothed delta를 함께 기록하고 +0.7 진입/+0.5 해제, -0.7 진입/-0.5 해제를 관찰한다.
0.5...0.7 또는 -0.7...-0.5 구간에서는 직전 상태에 따라 결과가 달라지는 것이 정상이다.
반대쪽 이동은 CENTER 경유, 무음은 즉시 Unavailable, Start/Stop은 이전 상태가 남지 않아야 한다.
Actual orientation=none 진단은 그대로 기록한다. 40,000/40,000 samples, live RMS와 iPhone Mode 복귀도 회귀 확인한다.
Swift tests에는 요청한 8개 전환, ±0.5 유지 경계, 반대편 직접 점프 방지, 실제 기본 EMA의 지연/유지,
silence/gate loss/invalid 입력/reset을 추가했다. 로컬 Swift compiler 및 Xcode test target이 없어 **추가만 했고 실행하지 않았다**.

### AVCapture multichannel capability probe — iPhone 16

실제 대상은 iPhone 16 기본 모델이다. Apple 사양의 Spatial Audio / stereo recording 지원과
현재 AVAudioSession source의 stereo polar pattern 제공 여부는 별개다. `.stereo` 패턴이 없다는
관측만으로 기기 전체의 multichannel capture가 불가능하다고 결론 내리지 않는다.

- Wearable **고급 진단**을 열 때 임시 `AVCaptureDeviceInput`을 만들고 다음 값을 조회한다:
  `AVCapture audio input available`, `isMultichannelAudioModeSupported(.stereo)`,
  `isMultichannelAudioModeSupported(.firstOrderAmbisonics)`, `multichannelAudioMode`.
- 조회는 UI/audio callback 밖에서 수행하며 결과 값만 UI로 전달한다. 화면을 나간 뒤의 결과는 반영하지 않는다.
  iOS의 `.microphone`은 논리적 장치이므로 실제 기기 검증은 외부 마이크를 분리한 상태에서 수행한다.
- Probe 자체는 `AVCaptureSession` / `AVCaptureAudioDataOutput`을 생성하거나 실행하지 않는다.
  Input을 session에 연결하지 않고 mode도 설정하지 않는다. 실제 Wearable capture backend와 별개다.
- 표시 mode는 **조회용 input의 현재 값**(기본값 `none`)이다. 실행 중인 AVAudioEngine의 mode나
  native PCM 채널 수를 나타내지 않는다. 지원 true도 실제 stereo/FOA PCM 수음 성공을 증명하지 않는다.
- 마이크 권한을 요청하지 않는다. 기존 Start listening에서 권한 허용 후 진단을 다시 열면 된다.
  권한 부족, input 생성 오류, OS 미지원은 지원 false와 구분해 `미확인 / Not checked`로 표시한다.
- Multichannel enum/input capability API는 **iOS 18+**다. Deployment target 17.0은 유지하고
  `#available(iOS 18.0, *)`로 보호한다. 빌드는 iOS 18 SDK를 포함한 Xcode 16 이상이 필요하다.
  기존 Actions의 Xcode/SDK 로그를 확인한다. Workflow는 변경하지 않았다.
- `AVCaptureAudioDataOutput.spatialAudioChannelLayoutTag`는 **iOS 26+**다. FOA input에서
  FOA 4채널 또는 stereo 2채널 output을 구성하는 API이며, 이번에는 조사만 하고 사용하지 않는다.
- 사용자 실기기 stereo=true 결과에 따라 위 Wearable 전용 stereo backend를 추가했다.
  FOA 지원은 계속 표시하지만 FOA 캡처/방향 계산은 구현하지 않는다. Capability는 PCM 성공과 구분한다.

실기기 확인: 새 IPA 설치 → Wearable Start로 권한 허용 → 진단 정보 → 고급 진단 정보에서
네 조회 값을 기록한다. Native mono 여부와 별도로 비교하고, 조회 후에도 RMS와 40,000-sample
AI buffer, Start/Stop 및 iPhone mode가 정상인지 확인한다. Probe true/true는 사용자 확인 결과이며
기존 backend의 실제 stereo PCM과 40,000-sample 준비는 사용자 확인 결과다. 이번 portrait patch의 안정성은 재검증해야 한다.

근거: [iPhone 16 사양](https://support.apple.com/ko-kr/121029),
[capability query](https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput/ismultichannelaudiomodesupported(_:)),
[multichannel mode](https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput/multichannelaudiomode),
[spatial audio output](https://developer.apple.com/documentation/avfoundation/avcaptureaudiodataoutput/spatialaudiochannellayouttag).

### Mode lifecycle

- iPhone → Wearable: 기존 capture/Start 작업, 수동 요청, 자동 snapshot/upload, registration/RMS/polling,
  후속 진동을 기존 방식으로 정리한다. 서버 전역 Auto 설정이나 주소·role·UUID를 변경하지 않는다.
- Wearable → iPhone: wearableMode 소유 캡처와 요청을 정리하고 session preference를 복원한다.
  이전 iPhone mode 연결 성공 주소가 있으면 기존 coordination 복구를 유지하되, 마이크는 Start가 필요하다.
- Stop/background/입력 변경/권한 대기 중 전환에서도 capture ID와 mode generation을 통해
  이전 작업이 새 모드의 캡처를 정지시키지 않도록 한다. Diagnostics 열기/닫기는 캡처를 소유하지 않는다.
- 이미 서버가 수락한 추론이나 OS에 전달된 한 번의 진동은 기존과 동일하게 취소할 수 없다.

### 실제 iPhone 검증

1. GitHub Actions를 수동 실행해 unsigned IPA를 빌드하고 별도 서명/설치한다.
2. 한/영에서 두 모드 이름과 iPhone microphone 기본 입력, 시작/중지 버튼을 확인한다.
   첫 진입은 waiting이며 권한 요청/수음이 자동 시작되지 않아야 한다. 기존 About/footer는 그대로여야 한다.
3. Wearable Start → 권한 → live audio 변화 → 40,000 samples / PCM ready를 확인한다.
   Windows 서버 없이도 수음 가능하고, 이 동작으로 HTTP 요청이나 iPhone 진동이 발생하면 안 된다.
4. 고급 진단에서 active mode와 실제 PCM 채널 수/형식을 확인한다. Node는 사용하지 않으며,
   PCM이 mono이면 채널별 수치는 비어 있고 stereo/direction unavailable이어도 PCM ready는 가능하다.
5. Stereo이면 현재 장착 orientation에서 좌우 박수·말소리·정면·조용한 상태의 채널 우세도를 비교한다.
   어느 채널이 상승하는지 data source/orientation과 함께 확인하고, 아래 semantic direction/hysteresis도 검증한다.
6. Stop → RMS/채널/PCM 상태 초기화 → Start 반복, 권한 대기 중 Stop/전환, 빠른 모드 왕복,
   background/foreground, route 변경/interruption, diagnostics 열기/닫기를 확인한다.
7. iPhone mode로 돌아가 기존 Start/Stop, 수동/자동 inference, multi-iPhone RMS 방향,
   target iPhone vibration, diagnostics/developer tools와 언어 변경이 정상인지 회귀 검사한다.
   실제 네 iPhone 방향 및 최종 calibration은 기존 Phase 6B 검증 범위다.

### 검증 범위와 Swift tests

Windows에서 기존 Python 60개 테스트, localization parity, project references, 단일 manager/engine/tap,
mode ownership/lifecycle, stale naming, 전체 diff와 민감정보 패턴을 검사한다.
Windows 검증은 Xcode 컴파일 또는 실제 iPhone stereo/방향 정확도를 증명하지 않는다.

`Tests/StereoDirectionEstimatorTests.swift`는 production pure Swift source 대상 standalone 테스트다.
**로컬 Swift compiler가 없고 Xcode test target도 없으므로 이 환경과 현재 Actions에서는 실행되지 않는다.**
기존 Actions workflow는 앱 build/unsigned IPA 패키징만 수행하며 변경하지 않는다.

Swift compiler가 있는 환경에서는 iOS SDK나 third-party dependency 없이 실행할 수 있다:

```powershell
$estimatorTest = Join-Path $env:TEMP 'meit-stereo-estimator-tests.exe'
swiftc MEIT/MEIT/Audio/StereoDirectionEstimator.swift Tests/StereoDirectionEstimatorTests.swift -o $estimatorTest
if ($LASTEXITCODE -eq 0) { & $estimatorTest }
```

macOS에서도 같은 두 source를 `swiftc ... -o /tmp/meit-stereo-tests`로 컴파일해 실행한다.

## UI & branding

- 앱 표시 이름과 상단 title은 `meit ios`, 모드는 `wearable mode / iPhone mode`이다.
- 메인은 listening → live audio → auto detection → last detection / direction → device position / server →
  하나의 start/stop listening action 순서다. 시작/정지는 하단에 고정해 스크롤 중에도 접근할 수 있다.
  마이크 활성 상태와 자동 분석 가능 상태를 구분한다.
  마지막 결과는 이 화면에서 가장 최근 관측한 수동/자동 결과 하나이며 과거 결과임을 표시한다.
- 오른쪽 settings에서 주소·연결 테스트·position·about을 제공한다. diagnostics는 메인에서도
  바로 열 수 있고 RMS/PCM/buffer, 네트워크, Auto threshold/state/event/timing을 보존한다.
  developer tools에는 기존 다섯 테스트 액션과 취소·수동 결과·진동 상태를 유지한다.
- 상세 화면은 sheet 안의 NavigationStack으로 탐색한다. 상세 화면 이동은 capture/polling을
  정리하지 않고 snapshot 조회만 취소한다. 기존 모드 전환·background 정리는 유지한다.
- system typography/colors, Dynamic Type, 텍스트 상태, VoiceOver label, 최소 44pt 주요 버튼을
  사용한다. custom font, animation, glass 효과는 없으며 About 설명에만 연한 배경 박스를 사용한다.
- 새 IPA에서 Light/Dark, 큰 글자, VoiceOver, sheet 열기/뒤로/닫기 중 capture 유지,
  Auto·수동 결과 표시, 모든 테스트 액션과 모드 전환·foreground 복구를 확인한다.
  이전 Phase 테스트의 Start/Stop Capture는 현재 start/stop listening에 해당하고,
  기술 수치와 테스트 버튼은 diagnostics/developer tools에서 찾는다.

### English / 한국어 & live audio

settings → language에서 English / 한국어를 선택한다. 기본값은 English이며
`@AppStorage("meit.language")`로 저장한다. `Localization/en.lproj/Localizable.strings`와
`ko.lproj/Localizable.strings`의 의미 기반 key를 선택 언어의 Bundle로 조회하고,
환경값으로 열린 메인·sheet·상세 화면에 전달한다. 언어 변경 시 `.id`로 화면을 재생성하거나
manager를 교체하지 않는다. 브랜드 `meit ios`와 아이콘 규격은 유지한다.
메인·AI label·방향·기기 위치·설정·개발자 액션·Hardware 안내를 번역한다.
진단 section 제목도 번역하되 기술 key/수치 및 manager·서버의 원본 오류는 그대로 표시한다.
앱 안 언어 선택은 iOS 자체 권한 팝업이나 시스템 언어 설정을 변경하지 않는다.

listening 상태 바로 아래 live audio는 기존 `audio.rmsDBFS`와 `isCapturing`만 받는다.
수평 ProgressView는 `clamp((dBFS + 60) / 60, 0...1)`로 표시한다:
-60 dBFS 이하 0%, -30 dBFS 50%, -10 dBFS 약 83%, 0 dBFS 100%.
이것은 시각화 스케일이며 AI trigger/rearm과 관계없다. 기존 약 10 Hz RMS 발행을 그대로
사용하며 별도 timer, animation, waveform history, PCM 복사 또는 DSP가 없다.
정지 시 0% / — dBFS / microphone inactive를 표시한다. 비유한 입력은 표시에서만 방어한다.
VoiceOver는 현 언어로 레벨과 수음 상태를 함께 읽고 매 갱신마다 강제로 알리지 않는다.

이번 변경은 Windows 정적 검토와 기존 60개 bridge 테스트로 확인하며 실제 iOS 검증은 별도다.
Actions에서 두 언어 리소스와 새 Swift 파일이 빌드·앱 번들에 포함되는지 확인한다.
실기기에서는 양방향 언어 전환(열린 sheet 포함)·재실행 저장·수음 유지, 말/박수/조용한 환경의
실제 미터 변화·정지 초기화, Auto/수동 분석/진동/모드 전환/foreground 복구를 확인한다.
한국어 segmented picker·긴 안내·버튼·큰 글자의 clipping, Light/Dark, VoiceOver도 확인한다.

### AppIcon & About

실제 아이콘은 `MEIT/MEIT/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`에 포함한다.
검정 배경·흰 소문자 `m`·넉넉한 여백·두꺼운 획의 독자적인 lettering이다. minitmute 참고 범위는
흑백·소문자·절제된 인상이며 favicon/로고 파일을 복사하거나 생성 입력으로 사용하지 않았다.
built-in image_gen으로 생성한 artwork를 1024×1024 불투명 RGB PNG로 규격화했다.
40/60/120px 축소본의 식별성을 확인했다. 사전 모서리 마스크·gradient·glow·그림자는 없다.
Xcode의 단일 iOS 1024px AppIcon 설정을 사용하고 asset catalog를 Resources에 한 번 등록한다.
Debug/Release 모두 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`이며 앱 표시 이름은 그대로다.

About은 굵은 `meit ios`, 자연스럽게 줄바꿈되는 설명과 하드웨어 대기 안내를 담은 하나의
secondary text / tertiary system grouped background 박스, 하단 copyright footer로 구성한다.
설명은 한 문자열이며 강제 개행·줄 수 제한·고정 높이가 없다. Dynamic Type과 VoiceOver를 유지한다.
`settings.aboutDescription`을 두 언어에서 수정하고 `settings.copyright`를 추가했다.
기존 언어 선택·메인·manager·오디오·AI·진동·모드 전환·bridge·workflow 로직은 변경하지 않는다.

Windows 기존 60개 테스트 및 소스/리소스 정적 검사를 수행했다. **Xcode asset compile과 새 IPA의
실기기 검증은 아직 필요하다.** Actions에서 CompileAssetCatalog, AppIcon/Assets.car 및 두 언어
리소스 포함, unsigned IPA 생성을 확인한다. iPhone에서는 홈 화면 아이콘, About의 bold/설명 박스/
footer, 영어↔한국어, Light/Dark, 큰 글자와 VoiceOver를 확인한다.

<details>
<summary>AppIcon generation prompt (built-in image_gen)</summary>

Use case: logo-brand. Asset type: final iOS AppIcon artwork, exact 1024x1024 square PNG, opaque RGB. Full bleed completely flat pure black background (#000000), square corners (iOS applies its own mask). One single white lowercase Latin letter "m" centered optically. Create original restrained editorial lettering: sturdy even strokes, two gently rounded shoulders, clean flat terminals, balanced slightly wide proportions, exceptionally crisp edges, no thin hairlines. Mark occupies approximately 58% of canvas width and 44% of height with ample black negative space. Legible at 40px. Only the exact letter "m", no other text. Calm, sharp, minimal black and white. No existing brand logo or favicon reference/copy. No microphone, soundwave, arrows, warning symbol, radar, gradient, texture, noise, shadows, glow, bevel, glass, 3D, borders, rounded icon frame, mockup or surrounding scene. Output the actual flat production icon alone, not a presentation.

</details>

## 프로젝트

- SwiftUI, iPhone 전용, deployment target **iOS 17.0** 이상: iPhone 15/16 대상.
- Bundle identifier: `org.meit.ios`. 버전: `0.1.0` (build `1`).
- 앱의 third-party dependency 및 패키지 설치 단계 없음.
- Info.plist는 Xcode가 build settings와 로컬 네트워크용 `MEIT/MEIT/Info.plist`를 합쳐 생성한다. `Assets.xcassets`의 AppIcon을 포함한다.

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
│       ├── Assets.xcassets/
│       │   ├── Contents.json
│       │   └── AppIcon.appiconset/
│       │       ├── Contents.json
│       │       └── AppIcon-1024.png
│       ├── Modes/
│       │   ├── OperatingMode.swift
│       │   ├── HardwareModeView.swift
│       │   ├── FallbackModeView.swift
│       │   ├── FallbackDetailsView.swift
│       │   └── LiveAudioView.swift
│       ├── Localization/
│       │   ├── AppLanguage.swift
│       │   ├── en.lproj/Localizable.strings
│       │   └── ko.lproj/Localizable.strings
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
`FallbackModeView.swift`는 listening과 감지 결과를, `FallbackDetailsView.swift`는 settings·diagnostics·developer tools를 표시한다.
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
  **meit ios uses the microphone to detect environmental sounds.**
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
