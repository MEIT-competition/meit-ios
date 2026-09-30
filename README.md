# meit ios

meit ios는 iPhone의 마이크와 오디오 분석을 이용해 주변의 위험음을 감지하고, 소리가 발생한 방향과 AI 분류 결과를 제공하는 MEIT용 iOS 앱이다.
AI 추론은 같은 Wi-Fi의 Windows bridge에서 기존 `meit-ai` 모델로 수행한다.

## Overview

- iPhone 자체 마이크로 오디오를 캡처한다. ESP32 + INMP441 외부 마이크는 최종 구조에서 사용하지 않는다.
- 위험음을 `horn` / `siren` / `crash` / `normal`로 분류하고, label · confidence · direction을 화면에 표시한다.
- 두 가지 Operating Mode를 제공한다.

| Mode | 방향 추정 | 출력 |
|---|---|---|
| **Wearable Mode** | iPhone 한 대의 stereo 입력으로 LEFT / CENTER / RIGHT | 앱 UI (이후 laptop → ESP32 → 진동 모터로 연결) |
| **iPhone Mode** | 여러 iPhone의 RMS 비교 | 대상 iPhone의 system vibration |

## Modes

### Wearable Mode

```text
iPhone microphone
→ AVCapture stereo audio
→ LEFT / CENTER / RIGHT direction estimation
→ mono AI input conversion
→ Windows bridge
→ meit-ai
→ horn / siren / crash / normal
```

이후 경로는 다음과 같다.

```text
Windows laptop → ESP32 → DRV8833 → wearable vibration motors
```

- iPhone → ESP32 직접 BLE 통신은 하지 않는다. iOS 앱에는 CoreBluetooth 코드가 없다.
- laptop → ESP32 command transport와 모터 출력은 다른 파트/팀의 통합 범위이며 이 repository에서 구현하지 않는다.

iPhone 16 실기기에서 검증된 항목:

- AVCapture stereo 2-channel capture
- LEFT / CENTER / RIGHT direction estimation
- 2.5-second AI PCM buffer
- Windows bridge connection
- Wearable AI inference (horn / siren / crash 실기기 inference verified)
- label / confidence / direction UI

### iPhone Mode

iPhone Mode는 여러 대의 iPhone이 함께 동작하여 소리의 방향을 추정하고, 해당 방향의 기기에 진동 알림을 제공한다.

```text
iPhone microphone
→ Windows bridge / meit-ai
→ multiple iPhones RMS-based direction
→ target iPhone system vibration
```

FRONT / RIGHT / BACK / LEFT role, multi-iPhone direction, 대상 iPhone만 진동시키는 targeted system vibration 기능이 유지된다.

## Wearable Mode data flow

```text
                   ┌──────────────────────────────┐
                   │           iPhone             │
                   │                              │
                   │  Built-in microphones        │
                   │           ↓                  │
                   │  Stereo audio capture        │
                   │           ↓                  │
                   │  LEFT / CENTER / RIGHT       │
                   │           ↓                  │
                   │  16 kHz mono PCM snapshot    │
                   └──────────────┬───────────────┘
                                  │ Wi-Fi (HTTP)
                                  ▼
                   ┌──────────────────────────────┐
                   │       Windows bridge         │
                   │           ↓                  │
                   │          meit-ai             │
                   │ horn / siren / crash / normal│
                   └──────────────┬───────────────┘
                                  │ external integration
                                  ▼
                   ESP32 → DRV8833 → vibration motors
```

## Wearable Mode 방향 추론

Wearable Mode는 다음 순서로 방향을 추정한다.

- `AVCaptureDeviceInput` multichannel stereo
- 실제 2-channel PCM, standard Stereo (Left, Right) stream layout 확인
- CH1 / CH2 RMS 비교
- EMA smoothing
- hysteresis

현재 iPhone 16 실측 calibration:

```text
LEFT   → positive channel delta
CENTER → near zero
RIGHT  → negative channel delta
```

현재 설정:

| Parameter | Value |
|---|---|
| EMA alpha | 0.25 |
| Enter threshold | ±0.7 dB |
| Release threshold | ±0.5 dB |
| Silence gate | -65 dBFS |

위 값은 iPhone 16 실측을 기반으로 한 현재 실험값이다. 특정 물리 마이크 위치와 CH1 / CH2를 1:1로 대응시키지 않으며, CENTER도 실제 정면을 보장하지 않는다.

## AI audio format

| | |
|---|---|
| Sample rate | 16 kHz |
| Channels | Mono |
| Sample format | Signed PCM16LE |
| Duration | 2.5 s |
| Samples | 40,000 |
| Payload | 80,000 bytes |

Native stereo 입력은 mono downmix와 resampling을 거쳐 이 형식이 된다.

## AI inference

- 분류 class: `horn`, `siren`, `crash`, `normal`
- Wearable Mode는 `/wearable/observe`와 `/wearable/infer`를 사용한다. 기존 iPhone Mode `/infer`가 가지는 coordination / haptic side effect와 분리되어 있다.
- 모델은 기존 `meit-ai` repository의 것을 그대로 사용한다. 모델과 소스를 이 repository에 복사하지 않는다.

## AI server

두 모드가 같은 Windows bridge 주소를 공유한다.

1. iPhone과 Windows를 같은 Wi-Fi에 연결한다.
2. 앱의 ⚙️에서 Windows의 IPv4 주소를 입력한다.
3. 연결 테스트로 bridge 접근 여부를 확인한다.

### Windows bridge 실행

```powershell
cd C:\meit-ios
.\.venv\Scripts\python.exe -B bridge\server.py --ai-path C:\meit-ai
```

정상 실행 시 다음이 출력된다.

```text
MEIT bridge ready
AI repository: meit-ai (external)
Model loaded
Listening: 0.0.0.0:8765
```

Endpoint와 protocol 상세는 [bridge/README.md](bridge/README.md)를 참고한다.

## Current status

| Feature | Status |
|---|---|
| iPhone microphone capture | ✅ |
| iPhone 16 stereo 2ch capture | ✅ |
| LEFT / CENTER / RIGHT estimation | ✅ |
| 2.5 s AI input buffer | ✅ |
| Windows bridge | ✅ |
| Wearable automatic AI inference | ✅ |
| Horn / siren / crash real-device inference | ✅ |
| AI server connection test | ✅ |
| iPhone Mode multi-device flow | Implemented / final 4-device validation pending |
| Laptop → ESP32 command transport | External integration |
| Wearable motor output | External integration |

✅는 실기기에서 확인된 항목이다. Implemented는 구현되어 있으나 이 표에서 별도 실기기 검증을 주장하지 않는 항목이다.

## UI

- English / 한국어
- Wearable Mode / iPhone Mode
- live audio level
- last detection (label · confidence)
- direction
- AI server status
- settings (⚙️)
- diagnostics
- dark / light system appearance
- AppIcon 포함

## Project structure

```text
meit-ios/
├── MEIT/
│   └── MEIT/
│       ├── Audio/          # capture, stereo direction, AI input buffer
│       ├── Modes/          # Wearable / iPhone mode screens, diagnostics
│       ├── Network/        # bridge client, multi-device coordination
│       ├── Haptics/        # system vibration
│       ├── Localization/   # en / ko
│       └── Assets.xcassets/
├── bridge/                 # Windows bridge (Python) + tests
├── Tests/                  # Swift unit tests
├── .github/workflows/      # unsigned IPA build
└── README.md
```

## Build

GitHub Actions의 **Build unsigned iOS IPA** workflow(수동 실행)가 unsigned IPA를 만든다. 결과물은 `MEIT-unsigned.ipa` artifact로 내려받고, Windows에서 Sideloadly로 서명·설치한다.

- iPhone only
- deployment target: iOS 17+
- Wearable multichannel stereo path는 iOS 18+ 필요 (iPhone Mode는 iOS 17+에서 동작)

## Requirements

| | |
|---|---|
| iPhone | iOS 17+ (iPhone Mode), iOS 18+ (Wearable stereo path) |
| Windows laptop | 같은 Wi-Fi, `meit-ai` repository, Python environment |
