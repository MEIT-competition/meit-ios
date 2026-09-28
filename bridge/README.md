# Windows bridge — Phase 3 / Phase 4 / Phase 5

Phase 3: 사용자 확인으로 실제 iPhone Wi-Fi end-to-end inference 성공.
Phase 4: system vibration 및 capture 중 진동은 사용자 실기기 확인 완료. 네 실제 iPhone 동시 방향 검증은 필요.
Phase 5: **Automatic detection / inference — implemented / device validation pending**.
Python 표준 라이브러리 HTTP 서버이며 웹 프레임워크를 추가하지 않는다.
기존 `meit-ai`는 별도 저장소로 유지한다. 소스·모델·학습 데이터는 이 저장소에 넣지 않는다.

## 실제 AI 코드 감사 및 연결

기존 저장소의 실제 코드에서 확인한 API는 다음과 같다. 문서의 과거 clip 길이보다
현재 실행 코드의 `SR = 16000`, `CLIP_SEC = 2.5`를 기준으로 한다.

| 항목 | 기존 meit-ai API / 동작 |
|---|---|
| 연결 진입점 | `classifier.adapter.predict_array(wav)` |
| 입력 | 16 kHz mono, 40,000개의 정규화된 Float32 waveform sample |
| 출력 | `({class: probability}, dBFS)` |
| 클래스 | `horn`, `siren`, `crash`, `normal` |
| preprocessing | 기존 `measure_db()`와 `fit_length()`를 `predict_array()` 내부에서 실행 |
| 모델 | `model/saved_model/danger_sound_classifier`의 SavedModel / `serving_default` |
| loading | 기존 `load_model()` / `load_temperature()`의 모듈 캐시 사용 |
| confidence | 기존 calibration temperature 적용 softmax, 0~1 probability |
| 다른 진입점 | 파일 입력 `classifier.adapter.predict(path)`와 `model/inference.py` CLI 존재 |
| 수동 경로에서 제외 | `main.py`, decision gate, AI의 haptic/logging |
| 자동 알림 판정 | 외부 `decision.judge.judge(probs, direction=-1, db=dbfs)` 직접 재사용 |
| Python dependency | adapter가 직접 import하는 `numpy`, `tensorflow`, `librosa` |

Bridge는 wire의 signed little-endian Int16을 Float32로 해석하고 `32768.0`으로 나누어
기존 waveform API에 전달한다. resampling, padding, feature extraction, logits,
softmax, calibration을 새로 구현하지 않는다. 기존 모델 graph와 preprocessing을 그대로 실행한다.
수동 결과는 가장 큰 확률의 label/confidence를 반환한다. 자동 결과도 같은 값을 표시하며,
알림 허용 여부만 기존 `decision.judge()`에 맡긴다. 새 confidence threshold는 추가하지 않는다.
`inference_ms`는 기존 `predict_array()` 호출 시간을 bridge에서 측정한다. 네트워크 왕복 시간은 아니다.
무음에서도 하나의 label이 반환될 수 있으며, 분류 정확도를 별도로 검증해야 한다. Phase 4 진동은 아래의 class/방향 조건만 사용하는 개발용 동작이다.

시작 시 기존 `load_model()`과 `load_temperature()`를 호출한다. 이후 요청은 같은 캐시를 사용한다.
기존 API는 별도 device 선택을 하지 않으므로 TensorFlow의 기존 device placement를 그대로 사용한다.
GPU 설정이나 대체 모델은 추가하지 않는다. Phase 4에서는 `ThreadingHTTPServer`로 HTTP를
병렬 처리하고 기존 AI API 호출만 별도 lock으로 직렬화한다. registry에는 독립적인 짧은 lock을 쓴다.

## Windows 실행 (PowerShell)

먼저 터미널을 **meit-ios 저장소 루트**에서 연다. 기존 AI 가상환경이 있으면 그 환경을
활성화한다. 다음 명령으로 현재 interpreter의 inference dependency를 확인한다.

```powershell
python -c "import tensorflow, numpy, librosa; print(tensorflow.__version__, numpy.__version__, librosa.__version__)"
```

기존 환경이 없으면 격리된 환경을 만들 수 있다. Python 3.12 환경에서 아래 세 package로
현재 adapter와 실제 SavedModel 실행을 확인했다. 웹 서버용 추가 package는 없다.
AI팀이 관리하는 별도 환경이 있다면 그 환경을 우선 사용한다.

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install "tensorflow>=2.13" numpy librosa
```

이 작업에서 검증한 조합은 Python 3.12.8 / TensorFlow 2.21.0 / NumPy 2.5.3 /
librosa 1.0.0이다. 가상환경은 `.gitignore`로 제외된다.

sibling 구조(`meit-ios`, `meit-ai`)에서는 경로를 개인 설정 파일 없이 계산한다.
다른 위치라면 `MEIT_AI_PATH`를 해당 기존 AI 저장소 루트로 설정한다.

```powershell
$env:MEIT_AI_PATH = (Resolve-Path ..\meit-ai).Path
.\.venv\Scripts\python.exe -B bridge\server.py
```

기존 AI 환경을 활성화한 경우 마지막 명령의 interpreter를 `python`으로 바꾼다.
`-B`는 기존 AI 저장소에도 Python bytecode cache를 생성하지 않게 한다.
환경변수 대신 `--ai-path`로도 경로를 전달할 수 있다.

```powershell
python -B bridge\server.py --ai-path $env:MEIT_AI_PATH --host 0.0.0.0 --port 8765
```

모델 load가 완료되어야 서버가 listen하며 다음 메시지가 나온다.
TensorFlow 자체의 CPU/장치 진단 메시지도 나올 수 있다.

```text
MEIT bridge ready
AI repository: meit-ai (external)
Model loaded
Listening: 0.0.0.0:8765
```

`Ctrl+C`로 종료한다. 모델/경로/import 오류나 포트 충돌이면 시작에 실패한다.
브리지는 PCM, header, client IP, 모델 경로를 로그나 파일에 저장하지 않는다.

## HTTP 계약

`GET /health` → HTTP 200, `{"status":"ok"}`. 모델 초기화가 성공한 서버의 연결 확인용이다.

`POST /infer`:

```http
Content-Type: application/octet-stream
Content-Length: 80000
X-Audio-Sample-Rate: 16000
X-Audio-Channels: 1
X-Audio-Format: pcm16le
X-Audio-Samples: 40000
```

body는 **WAV header 없이 정확히 80,000 bytes = 40,000 samples = 2.500 s**이다.
raw signed PCM16 little-endian / 16,000 Hz / mono만 받는다. chunked/compressed input은 받지 않는다.
필수 header 누락·중복·규격 불일치, 잘못된 크기, 짧은 body를 AI 호출 전에 거부한다.
metadata와 길이 검증으로 실제 녹음의 sample rate를 추정할 수는 없으므로 송신 측도 계약을 지켜야 한다.

성공 HTTP 200의 구조 (숫자는 설명용 예시):

```json
{"label":"horn","confidence":0.72,"inference_ms":48.3}
```

실패 응답은 성공과 구분된다.

```json
{"error":{"code":"invalid_length","message":"Expected exactly 80000 bytes / 40000 samples."}}
```

- HTTP 400: metadata/길이/짧은 body/Transfer-Encoding 오류
- HTTP 404: 없는 endpoint
- HTTP 408: body 읽기 timeout
- HTTP 411: Content-Length 누락
- HTTP 415: 압축 body
- HTTP 500: 기존 AI 실행 실패 (상세 모델 정보는 응답에서 제외)

읽기 idle timeout은 10초다. 거부된 upload가 Windows TCP reset으로 오류 응답을 가리지 않도록
응답 후 최대 80,001 bytes/0.25초의 제한된 drain을 수행한다. 파일 저장은 하지 않는다.

## Windows / iPhone 연결 절차

1. 위 명령으로 bridge를 시작하고 `Model loaded`를 확인한다.
2. 별도 PowerShell에서 `Invoke-RestMethod http://127.0.0.1:8765/health`로 `ok`를 확인한다.
3. `ipconfig`로 **실제 Wi-Fi 어댑터의 IPv4**를 확인한다. loopback, VPN, 가상 어댑터 주소는 쓰지 않는다.
4. 신뢰하는 Wi-Fi에서 Windows 네트워크 프로필이 **Private**인지 확인한다.
   방화벽 허용 창이 나오면 실행한 Python의 **Private networks**만 허용한다.
   필요 시 Windows Defender Firewall 고급 설정에서 해당 Python 프로그램 또는 TCP 8765의
   inbound를 **Private / Local subnet**으로 제한해 허용한다. 방화벽 전체를 끄지 않는다.
   이 구현은 방화벽 설정을 자동 변경하지 않는다.
5. iPhone을 같은 Wi-Fi에 연결한다. 공유기의 guest/client isolation이나 VPN이 통신을 막지 않는지 확인한다.
6. 기존 수동 GitHub Actions workflow로 새 unsigned IPA를 빌드하고 Sideloadly로 설치한다.
7. 앱의 **AI Server**에 Windows의 사설 IPv4만 입력한다. `http://`, path, port는 입력하지 않는다.
   앱 포트는 8765이고 주소는 앱 실행 중 유지된다. 개인 IP는 소스나 파일에 저장하지 않는다.
8. **Test Connection**을 누르고 iOS local-network 권한 요청을 허용한다.
   `Connection: Connected`를 확인한다. 거절했다면 iOS 설정의 MEIT 로컬 네트워크 권한을 켜고 재시도한다.
9. **Start Capture** → **AI Buffer Ready**와 `40000 samples / 80000 bytes / 2.500 s`를 기다린다.
10. **Send Snapshot**을 한 번 누른다. `Sending...` 후 label/confidence/inference 시간을 확인한다.
    RMS와 변환 상태가 계속 갱신되는지도 확인한다.
11. 전송 중 버튼 비활성화, 반복 수동 전송, Stop → Start, Cancel Request, 앱 background를 확인한다.
    취소된 응답은 UI에 반영되지 않는다. 이미 시작된 서버 추론은 끝날 수 있지만 다음 요청과 겹치지 않는다.
12. 서버 종료, 잘못된 IPv4, Wi-Fi 단절, 권한 거부 상태에서 오류를 확인한 후 복구·재시도한다.
    앱 timeout은 연결 확인 10초/추론 60초 요청 대기, 전체 resource 최대 60초다.
    초기 local-network 권한 대기 상황도 실제 기기에서 확인한다.

이 단계는 **신뢰하는 사설 LAN의 수동 테스트용 HTTP**이며 인증/TLS를 구현하지 않는다.
외부 공개나 포트 포워딩 용도로 쓰지 않는다.

## iOS 설정 및 수명주기

`NetworkManager`가 URLSession, 응답 검증과 UI 상태를 MainActor에서 관리한다.
Snapshot 생성 대기부터 응답까지 한 작업만 허용한다. tap에서 네트워크 작업을 하지 않는다.
`makeAIInputSnapshot()`의 immutable `pcm16LittleEndian`을 검증 후 그대로 전송한다.
주소 변경/취소/Stop/background에서 작업을 취소하고 늦은 응답을 무시한다.
HTTP redirect는 거부하며 ephemeral session에 응답/audio를 disk cache하지 않는다.

`Info.plist`에 `NSLocalNetworkUsageDescription`을 추가한다. iOS 17+의 IP HTTP 정책에 맞춰
`NSExceptionDomains`의 **RFC1918 사설 IPv4 CIDR 3개**에만 insecure HTTP를 허용한다:
`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`. 이것은 개인 서버 IP 설정값이 아닌 표준 범위다.
앱도 이 범위의 IPv4만 입력받는다. 공인 IP/IPv6/hostname은 이번 UI에서 지원하지 않는다.
`NSAllowsArbitraryLoads`는 사용하지 않는다. Bonjour discovery가 없으므로 Bonjour 목록이나
multicast entitlement는 추가하지 않는다. Xcode는 이 plist와 기존 자동 생성 키를 합친다.

근거: [Apple ATS IP/CIDR 예외](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains),
[Apple local-network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

## 검증과 남은 확인

```powershell
.\.venv\Scripts\python.exe -B -m unittest discover -s bridge -p 'test_*.py' -v
```

- Windows 단위 테스트: HTTP 정상/실패, metadata·길이·압축·중복 길이·짧은 body 차단,
  AI 오류 응답, 요청 직렬화, PCM signed/endian 경계값, 기존 API startup load와 호출 재사용 확인.
  이 테스트의 모델은 명시적인 test double이다.
- 별도 실제 모델 검증: 기존 SavedModel에 합성 무음 80,000-byte body를 loopback HTTP로
  두 번 전송해 HTTP 200 및 실제 label/confidence를 받았고, 동일 모델 인스턴스 재사용을 확인했다.
  이 검증은 모델 실행 경로 확인이며 위험음 분류 정확도 평가가 아니다.
- Phase 3의 실제 Wi-Fi/iPhone end-to-end 성공은 사용자 확인으로 기록한다.
- **미검증**: 이번 Phase 4 변경의 Xcode 컴파일, 실제 네 iPhone의 등록/보고/polling,
  마이크 동작 중 Core Haptics, 방향 정확도, 기기별 감도 차이, interruption/복귀.
  기존 Actions의 `Build unsigned iOS app` 로그를 확인하고 아래 네 기기 테스트를 수행한다.


## Phase 4 registry / RMS / direction

모든 iPhone은 같은 IPA를 사용한다. Role picker로 역할을 선택하고 서버 IPv4를 입력한 뒤
Test Connection을 누른다. UUID와 role은 UserDefaults에 저장하며 앱 재실행 후 재사용한다.
앱 삭제로 UserDefaults가 지워지면 새 UUID를 만든다. 화면에는 UUID 앞부분만 표시한다.
role은 기본 FRONT이므로 네 기기에 서로 다른 역할을 지정해야 한다.

JSON endpoint는 `Content-Type: application/json` 및 1~4096-byte Content-Length body를 받는다.
아래 `<runtime UUID>`는 실제 기기에서 생성하는 UUID 자리이며 그대로 전송할 값이 아니다.

```http
POST /device/register
{"device_id":"<runtime UUID>","role":"front"}

POST /device/rms
{"device_id":"<runtime UUID>","role":"front","rms_dbfs":-34.2}
```

- 등록 성공: `{ "status": "registered", "device_id": "...", "role": "front" }`.
- 같은 ID/role 등록은 갱신이며, role 변경 성공 시 기존 역할·RMS·pending command를 교체한다.
- 다른 살아 있는 기기가 같은 role을 사용하면 HTTP **409 role_conflict**로 거부한다.
  기존 기기를 덮어쓰지 않고 conflict role을 방향 debug에도 표시한다.
  거부된 기기가 역할을 바꾸거나 마지막 경쟁 등록 시도 이후 5초가 지나면 conflict가 해제된다.
- RMS 성공: `{ "status": "ok" }`. 등록되지 않은 ID는 404, 등록 역할과 다르면 409.
  `rms_dbfs`는 finite number / -100...0만 허용한다. NaN, infinity, boolean, 문자열, 범위 밖 값은 400.
- RMS loop는 capture 중 약 **100 ms** 간격으로 현재 `rmsDBFS` 하나만 전송한다.
  이전 요청이 끝나야 다음 값을 읽는다. 느린 요청 동안의 중간 값은 쌓지 않는다.
  coordination 요청은 최대 1초로 제한하며 RMS 오류는 network UI만 갱신한다.
- `GET /devices`: device_id, role, last_seen, latest_rms_dbfs, latest_rms_timestamp,
  calibration_offset_db, online 및 현재 direction을 반환한다.
  timestamp는 **서버 monotonic seconds**이며 기기 clock과 비교하는 시간이 아니다.
- register/RMS/poll heartbeat가 **5초** 없으면 offline이다. 새 기기는 offline 역할을 인수할 수 있다.
  offline 기록은 마지막 heartbeat로부터 10초 후 제거한다. registry/경쟁 주장 각각 최대 16개다.
  polling heartbeat는 last_seen만 갱신하며 RMS freshness를 연장하지 않는다.

`GET /direction` 응답은 다음 필드를 가진다.

| 필드 | 의미 |
|---|---|
| `direction` | front / right / back / left / unknown |
| `reason` | ok / role_conflict / waiting_for_roles / stale_rms / insufficient_margin |
| `winner_dbfs`, `runner_up_dbfs`, `margin_db` | fresh corrected RMS의 1위·2위·차이; 부족하면 null |
| `missing_roles`, `stale_roles`, `conflict_roles` | 확정할 수 없는 이유의 역할 목록 |
| `devices` | role별 device_id, measured/corrected RMS, rms_age_ms, online, fresh |
| `required_margin_db`, `rms_max_age_ms` | 서버의 현재 기준 |

**네 role 모두 online이고 RMS age ≤ 500 ms일 때만** 방향을 확정한다.
`corrected_rms = latest_rms_dbfs + calibration_offset_db`를 정렬해 최고값을 고르며,
최고값과 두 번째 값의 차이가 **3 dB 이상**이어야 한다. 동률·불충분한 margin·stale·conflict는 unknown이다.
기기가 1~3대여도 정상 응답하며, 일부 RMS로 4방향을 확정하지 않는다.
calibration offset은 `Device.calibration_offset_db`에 분리했으며 기본은 모두 **0.0**이다.
향후 registry lock 안에서 측정된 offset을 설정할 수 있다. 현재 설정 endpoint/UI/자동 보정은 없다.

500 ms와 3 dB는 실측 정답이 아닌 초기 설정이다. CLI로 조정할 수 있다 (양수, finite).

```powershell
.\.venv\Scripts\python.exe -B bridge\server.py --rms-max-age-ms 500 --direction-margin-db 3
```

서버 수신 시간의 최신 RMS를 사용하며 TDoA나 device clock 동기화를 하지 않는다.
2.5초 snapshot 전체의 어느 시점에서 sound가 발생했는지를 RMS와 정밀 정렬하는 방식은 아니다.
방향 동작은 phone 배치·감도·반사음·지연에 영향을 받으므로 실제 테스트가 필요하다.

## Phase 4 command / haptic

```http
GET /device/command?device_id=<runtime UUID>&role=front
```

응답은 `{ "command": null, "direction": { ... } }` 또는 다음 command를 포함한다.

```json
{
  "command_id": "<server-generated UUID>",
  "kind": "direction_haptic",
  "role": "right",
  "source": "inference",
  "expires_in_ms": 1800.0
}
```

- foreground 연결 중 약 **200 ms**마다 자신의 command를 조회한다. 한 poll씩 await하며
  실패하면 약 1초 간격으로 재등록한다. 모든 폰의 live direction도 poll 응답으로 갱신한다.
- pending command는 **기기당 1개 / TTL 2초**. 이미 pending이면 새 command는 추가하지 않는다.
- poll은 lock 안에서 한 번만 command를 꺼낸다. 응답을 잃으면 해당 command도 유실될 수 있는
  **best-effort, at-most-once** 전달이다. ACK/재전송 보장은 이번 단계에 구현하지 않는다.
- 앱은 처리한 command ID 최근 32개를 UserDefaults에 저장하고 **play 전에** 기록한다.
  잘못된 role/kind, 만료되었거나 중복된 ID는 실행하지 않는다. 만료 검사에는 왕복 지연도 보수적으로 반영한다.
- target role이 바뀌거나 다른 device가 역할을 인수하면 기존 registration에 묶인 command는 보내지 않는다.
  역할 충돌이 생긴 pending command도 폐기한다.
- 주소/역할 변경, 비활성화/background에서는 기존 loop와 늦은 callback을 취소·무시한다.
  Stop Capture는 RMS 보고를 멈추지만 foreground polling은 유지한다. 마지막 RMS는 500 ms 뒤 stale이다.
  local-network 권한 요청 후 Test Connection 성공 시 등록된다. 다른 네트워크 오류는 mic을 멈추지 않는다.

`POST /direction/test-haptic` body `{}`는 AI 없이 direction을 구하고 해당 기기에 명령을 만든다.
응답: `{ "direction": { ... }, "haptic": { "queued": true, ... } }`.
unknown, pending 존재, target 변경이면 `queued: false`와 reason을 반환한다.
앱의 **Test Direction + Haptic** 버튼이 이 endpoint를 호출한다.

기존 `/infer`의 PCM/metadata와 label/confidence/inference_ms를 유지하고 다음을 추가한다.

- `direction`, `direction_margin_db`, `direction_details`, `haptic`
- AI lock 획득 후 **모델 호출 직전**의 RMS direction을 고정한다. 추론 중 새 RMS는 registry에 계속 들어온다.
  따라서 live Direction과 이전 AI Result의 Direction은 다를 수 있다.
- unknown이어도 분류 결과를 반환한다. `normal`은 `non_danger_class`로 haptic을 만들지 않는다.
- 기존 클래스 중 `horn / siren / crash` + known direction이면 그 역할에 command 하나를 시도한다.
  class별 패턴이나 추가 confidence/dB gate를 만들지 않는다. 기존 `decision.judge`는 호출하지 않는다.
- HTTP는 `ThreadingHTTPServer`에서 병렬 처리하고 기존 AI API만 `inference_lock`으로 직렬화한다.
  모델 호출 동안 registry lock은 잡지 않는다. 모델은 기존 startup cache를 그대로 재사용한다.
- Cancel Request는 iPhone의 응답 대기를 취소한다. 이미 시작된 서버 추론과 그 결과에 따른
  다른 기기의 haptic command 생성까지 취소하는 프로토콜은 이번 단계에 포함하지 않는다.

System vibration은 기존 `HapticManager`가 관리하며 Phase 5에서 변경하지 않았다.
`AudioServicesPlayAlertSoundWithCompletion(kSystemSoundID_Vibrate)`를 3회 요청하고
각 완료 후 다음 요청까지 200 ms를 둔다. burst 진행 중 새 요청은 버리고 완료 후 0.5초 cooldown,
completion 2초 timeout 및 foreground 검사를 유지한다. 이미 OS에 요청된 진동은 취소할 수 없다.
recording 중 `setAllowHapticsAndSystemSoundsDuringRecording(true)`와 같은 manager를 사용하는
**Test Haptic**도 유지한다. 사용자 확인으로 실제 iPhone 진동과 capture 중 진동은 검증되었다.

## 실제 iPhone 네 대 테스트 순서

1. 기존 수동 GitHub Actions로 Phase 4 IPA를 빌드한다. Xcode/Swift 실패는 Build unsigned iOS app 로그에서 확인한다.
   동일 IPA를 네 iPhone에 Sideloadly로 설치한다. 앱은 foreground에 둔다.
2. 각 폰에서 먼저 **Test Haptic**을 눌러 자체 진동을 확인한다. 지원/실패 표시를 확인한다.
3. 역할을 FRONT / RIGHT / BACK / LEFT로 나누고 앱을 재실행해 role과 Device ID가 유지되는지 확인한다.
4. 기존 Windows 환경에서 bridge를 실행한다. 같은 Wi-Fi/Private 방화벽 TCP 8765 조건은 Phase 3과 같다.
   네 폰에 같은 Windows IPv4를 입력하고 Test Connection → Registration Connected를 확인한다.
5. 네 폰에서 Start Capture. 기존 RMS/native format/AI buffer와 RMS Reporting 상태를 확인한다.
   Capture 중에도 Test Haptic이 동작하고 mic/변환이 계속되는지 확인한다.
6. 잠시 같은 role을 중복 선택해 409 conflict와 UNKNOWN을 확인하고 서로 다른 역할로 복구한다.
7. 오른쪽 가까이에서 소리를 유지한 상태로 live Direction RIGHT와 margin을 확인한다.
   **Test Direction + Haptic**을 누르고 RIGHT 폰만 한 번 진동하는지 확인한다.
   FRONT/BACK/LEFT도 반복하며 calibration 없이 방향이 불명확하면 margin/RMS를 기록한다.
8. 두 역할의 RMS 차이가 3 dB 미만이면 UNKNOWN이며 방향 테스트 진동이 없는지 확인한다.
   한 폰에서 capture를 Stop하고 500 ms 후 stale/UNKNOWN, 앱을 닫거나 연결을 끊고 5초 후 offline을 확인한다.
   1~3대만 켠 경우에도 앱/서버가 정상 응답하고 missing role을 표시해야 한다.
9. 네 폰을 복구한 뒤 어느 한 폰에서 AI Buffer Ready → **Send Snapshot**을 한 번 누른다.
   기존 label/confidence와 AI Direction을 확인한다. 위험 class + known direction이면 해당 폰만 진동한다.
   `normal` 결과 또는 unknown direction이면 진동이 없어야 한다. Auto OFF에서는 자동 AI 전송이 없어야 한다.
10. 느린 추론 중에도 다른 폰의 RMS/Direction/poll이 유지되는지 확인한다. 같은 command가 반복 진동하지 않는지,
    빠른 버튼 연타 시 pending/cooldown 제한이 적용되는지 확인한다.
11. 역할 변경, Windows 서버 재시작, Wi-Fi 단절·복구, Stop/Start, 앱 background/foreground를 반복한다.
    이전 역할의 command나 늦은 응답이 현재 폰을 잘못 울리지 않아야 한다.
    네트워크 실패 중에도 microphone/RMS/AI buffer가 계속 동작해야 한다.

Phase 4 당시 Windows 자동 테스트 **29개**가 통과했다. fake clock으로 stale/margin/TTL/role conflict, command atomic consume,
normal/danger 정책과 실제 HTTP 동시성을 확인한다. Phase 3 테스트도 함께 실행한다.
Python 자동 테스트는 물리적인 진동, UI lifecycle, 네 기기 방향 정확도를 확인하지 못한다.

이번 Windows 실제 모델 smoke test에서는 별도 기존 SavedModel과 가상 device 4개의 RMS를 연결했다.
합성 무음 PCM의 실제 추론 두 번에서 direction RIGHT 및 RIGHT 전용 command를 확인했고,
첫 추론 약 748 ms 동안에도 RMS 요청을 처리했다. 이 결과는 실제 phone의 RMS나 물리 haptic 검증이 아니다.

## Phase 5: 중앙 Automatic Detection / Inference

**implemented / device validation pending**. 서버 시작 시 Auto OFF, 재시작 시 이전 이벤트는 복구하지 않는다.
한 이벤트에 source 한 대, PCM 한 개, model 호출 최대 한 번이다. 1대부터 자동 AI를 실행하며
방향/진동 조건은 Phase 4의 네 role fresh + margin 조건과 분리한다.

### 기존 AI 감사와 재사용

- `decision/judge.py`: `THRESHOLD=0.4`, `DB_GATE=-50.0`(기존 코드에도 임시값 표기).
  `normal`, 낮은 confidence, 낮은 입력 dBFS를 거부한다. 이를 복제하지 않고 `judge()`를 import한다.
  `infer_auto()`는 `predict_array()`를 한 번만 호출하고 그 probabilities와 dBFS를 그대로 전달한다.
  반환이 None인지로 `danger`를 정하며 기존 pattern/intensity는 iPhone에 보내지 않는다.
- `decision/patterns.py`의 `GATING_MS=250`은 진동 패턴 길이 선택이다.
  `model/threshold_search.py`는 offline N-of-M simulation/threshold 평가이며 중앙 실시간 event gate가 아니다.
  따라서 multi-iPhone 이벤트 생성/cooldown은 새 `automatic.py`가 맡는다.
- `main.process_array()`는 logger side effect가 있으므로 사용하지 않는다. classifier/모델/preprocessing/
  calibration/load cache는 그대로 쓰고 `meit-ai`에는 파일을 쓰거나 소스/모델을 복사하지 않는다.
- 수동 `/infer`는 기존 Phase 4 정책을 유지한다. 자동은 기존 judge가 허용한 위험음만 진동 대상이다.
  UI의 label이 `siren`이어도 기존 confidence/dB gate에 걸리면 자동 진동은 없을 수 있다.

### 설정과 이벤트 흐름

```powershell
$env:MEIT_AI_PATH = (Resolve-Path ..\meit-ai).Path
.\.venv\Scripts\python.exe -B bridge\server.py --auto-trigger-dbfs -30 --auto-cooldown-ms 3000 --auto-audio-timeout-ms 3000 --auto-rearm-quiet-ms 750
```

| 설정 | 기본값 | 의미 |
|---|---|---|
| `--auto-trigger-dbfs` | -30 dBFS | source corrected RMS가 이 값 이상이면 trigger |
| `--auto-cooldown-ms` | 3000 | 완료/실패 뒤 새 이벤트 차단, 2.5초 rolling window보다 길게 설정 |
| `--auto-audio-timeout-ms` | 3000 | trigger부터 완전한 80000-byte upload를 수락할 때까지 |
| `--auto-rearm-quiet-ms` | 750 | 모든 fresh RMS가 trigger보다 3 dB 낮은 값 미만인 상태를 관측할 기간 |

위 RMS/time 값은 **Phase 5 experimental defaults**, Phase 6 실측 보정 대상이다.
서버 수신 monotonic clock을 사용하며 폰 clock synchronization은 필요 없다.

`IDLE → WAITING_FOR_AUDIO → INFERENCING → COOLDOWN → IDLE`.
RMS 보고 시 fresh(기본 500 ms), registered, `ai_buffer_ready=true`인 기기 중
corrected RMS 최대값을 source로 선택한다. 네 role/margin이 부족해도 trigger할 수 있다.
등록 상태와 direction은 동일 registry snapshot에서 읽고, trigger 당시 각 role RMS/freshness/
corrected RMS/winner/runner-up/margin/direction을 이벤트에 보관한다. 추론 이후 live 방향으로 교체하지 않는다.
대상 registration이 바뀌거나 offline/conflict이면 기존 command 보호에 따라 진동을 보내지 않는다.

지속 사이렌은 cooldown이 끝나도 quiet 재무장 전까지 재추론하지 않는다.
quiet 관측 사이에 RMS freshness보다 긴 공백이 생기면 관측을 다시 시작하며, stale/offline을 quiet로 간주하지 않는다.
따라서 noisy 환경에서는 IDLE + Waiting for quiet가 계속될 수 있다. Auto OFF/ON도 이 보호를 우회하지 않는다.
RMS trigger는 위험음 확정 판정이 아니며, snapshot은 **명령 수신 당시 최신 2.5초**이다.
소리 시작 직후에는 이전 배경음이 많이 포함될 수 있고, 중앙 gate가 물리적 사건을 완벽히 구별하는 것은 아니다.

### HTTP / command 계약

| Endpoint | 내용 |
|---|---|
| `GET /auto/status` | enabled/state/armed/config/active_event/last_event |
| `POST /auto/start` | JSON `{}`, global Auto ON; 다음 RMS 보고부터 감지 |
| `POST /auto/stop` | JSON `{}`, global Auto OFF; 자동 이벤트·미전달 자동 명령 무효화 |
| `POST /event/audio` | 기존 80000-byte raw PCM과 아래 이벤트 metadata |

기존 `POST /device/rms`에 optional boolean `ai_buffer_ready`를 추가했다.
생략은 false이므로 이전 클라이언트의 Phase 4 RMS 동작은 유지하면서 자동 source에서는 제외한다.
앱은 full buffer + capture 중 + 수동/자동 업로드 비점유일 때 true를 보고한다.

명령 예시(UUID 문자열은 매번 runtime 생성):

```json
{
  "command_id": "<command UUID>",
  "kind": "infer_snapshot",
  "event_id": "<event UUID>",
  "role": "right",
  "expires_in_ms": 2800
}
```

`GET /device/command`의 기존 command/direction에 `auto` 상태를 더해 모든 폰이 결과를 볼 수 있다.
기존 `kind=direction_haptic`은 유지하고 자동 진동에만 event_id/source=auto_inference를 붙인다.
기기당 pending slot **하나**를 그대로 공유한다. 이미 다른 명령이 있으면 덮어쓰지 않고 이벤트를
`command_unavailable`로 종료한 뒤 cooldown한다. 유실 시 재전송 대신 timeout으로 정리한다.

자동 PCM은 `/infer`와 동일 Content-Type/Content-Length 및 네 X-Audio-* header에 다음을 추가한다.

```text
X-Event-ID: <event UUID>
X-Device-ID: <selected device UUID>
X-Device-Role: right
```

서버는 포맷/길이, active event, 선택된 device/role/registration, 만료 및 미수락 상태를 확인한 후
`WAITING_FOR_AUDIO → INFERENCING`을 lock 안에서 원자적으로 변경한다. 그 뒤 기존 inference lock을
기다리므로 동시 중복 업로드도 두 번째 모델 호출을 만들지 않는다. 중복/종료/late 요청은 409,
잘못된 metadata는 400이며 AI를 실행하지 않는다. 이미 완료한 응답을 재전송하는 replay cache는 없다.
이 의미는 **event당 at-most-once model call**이며 HTTP 전달 성공을 보장하는 exactly-once는 아니다.

대기 3초 초과 시 `audio_timeout`을 기록하고 pending command를 비운 뒤 cooldown한다.
HTTP 요청이 없어도 서버 service_actions(기본 최대 약 0.5초 tick 지연)가 timeout을 진행한다.
모델 오류는 `inference_failed`로 정리하고 상세 private path/PCM을 응답·로그에 남기지 않는다.
HTTP는 계속 병렬이고 자동·수동 모델 호출은 같은 lock으로 직렬화된다.

Auto Stop은 미수락 이벤트를 종료하고, 이미 실행 중인 모델은 반환까지 한 슬롯을 유지하되
결과/자동 진동을 무효화한다. 다시 ON해도 그 호출이 끝나기 전 새 auto event는 없다.
TensorFlow가 반환하지 않는 상황은 강제 thread 종료하지 않는다. 이 경우 서버 재시작이 필요하다.
이미 전달되어 재생 중인 OS 진동을 원격 취소하는 프로토콜은 없다. 수동 `/infer`는 Auto Stop/cooldown과 독립적이다.

### iPhone lifecycle / bounded 상태

- 기존 `makeAIInputSnapshot()`과 immutable PCM Data를 사용하며 Audio processor/format/session을 변경하지 않았다.
  role·generation·foreground·capture·buffer·명령 유효 시간을 확인한다. 실패 시 mic을 멈추지 않는다.
- 자동 upload task와 Auto ON/OFF task는 각각 최대 한 개다. upload는 polling/RMS loop를 막지 않는다.
  각 기존 loop도 한 요청씩 await한다. command ID는 기존 최근 32개만 저장하고 실행 전에 기록한다.
- 주소/role 변경, disconnect, inactive/background, capture Stop에서 auto snapshot task를 취소한다.
  background 실행은 보장하지 않는다. 이미 서버가 수락한 추론은 로컬 upload 취소만으로 취소되지 않는다.
  서버 전체 자동 이벤트를 중단하려면 **Stop Auto Detection**을 사용한다.
- 서버는 active event 최대 1개 + 마지막 완료/실패 기록 1개만 보관한다. PCM은 이벤트 history에 저장하지 않는다.
  기기 registry 최대 16개, pending 기기당 1개, event ID 누적 set/list 없음, 이벤트별 timer/thread 없음.
  CLI HTTP 서버의 기존 thread-per-request 방식은 유지하며 공개 인터넷용 서버로 확장하지 않았다.

### Phase 5 검증

Windows 실행:

```powershell
.\.venv\Scripts\python.exe -B -m unittest discover -s bridge -p 'test_*.py' -v
```

기존 29개에 Phase 5 gate/HTTP/adapter 회귀 테스트를 추가했다. fake clock과 mock model로
OFF/1-phone/4-phone/source eligibility/threshold/재무장/cooldown/중복/timeout/Stop/
trigger-time direction/manual 보존/AI와 RMS·health·poll 동시성을 검증한다.
**최종 Windows Python 테스트 54개(기존 29 + 신규 25)가 모두 통과했다.**
전체 diff 및 `git diff --check`, Swift project reference 정적 검토, public 파일 민감정보 검사를 수행했다.

실제 외부 SavedModel 별도 Windows HTTP smoke test(모델 mock 아님):
메모리에서 만든 2.5초 교대 tone PCM → 가상 기기 RMS → 자동 event → infer_snapshot →
`/event/audio` → 실제 `predict_array` / `judge` → 결과를 확인했다. 모델은 한 번 초기화하고 캐시를 재사용했다.

| 가상 기기 | source | 실제 모델 결과 | direction | haptic command | 모델 시간 |
|---|---|---|---|---|---|
| 1대 | FRONT | siren, 97.99%, danger=true | UNKNOWN | 없음 | 약 333 ms |
| 4대 | RIGHT | siren, 97.99%, danger=true | RIGHT | RIGHT 하나 | 약 26.6 ms |

두 이벤트의 실제 모델 호출은 총 2회였고 각각 중복 upload는 409였다.
이 결과는 합성 입력의 연결 검증이며 실제 사이렌 분류 정확도/마이크/물리 진동 검증이 아니다.

**Single-iPhone validation**

1. 기존 workflow_dispatch Actions로 새 IPA 빌드 → Sideloadly 설치. 새 Swift의 Xcode 컴파일은 이 단계에서 확인한다.
2. bridge 실행 후 앱 foreground, FRONT, Test Connection → 등록 → Start Capture → AI Buffer Ready.
3. Auto OFF에서 소리를 내어 자동 이벤트가 없고 수동 Send Snapshot/Test Haptic이 유지되는지 확인한다.
4. Start Auto Detection 후 RMS가 trigger를 넘는 소리를 재생한다. Send Snapshot 없이 source FRONT,
   label/confidence, Direction UNKNOWN이 나타나고 방향 진동은 없어야 한다.
5. 지속음을 유지하면 반복 event가 생기지 않아야 한다. 조용해진 뒤 cooldown/재무장을 기다리고 다시 재생한다.
6. Auto Stop, Stop/Start Capture, Wi-Fi 단절·복구, 서버 재시작, background/foreground를 확인한다.
   mic/PCM은 기존처럼 동작하며 서버 재시작은 OFF, capture/background 중단은 늦은 snapshot을 취소해야 한다.
7. 명령 후 폰이 snapshot을 보내지 못하면 약 3초 뒤 audio_timeout, 이후 quiet + cooldown 뒤 복구하는지 확인한다.

**Four-iPhone validation**

1. 서로 다른 네 role의 등록·capture·buffer-ready·fresh RMS를 먼저 확인하고 Auto ON.
2. RIGHT 가까이서 소리를 내어 source가 가장 큰 corrected RMS 기기 한 대인지 확인한다.
   label은 기존 모델 결과이며 known direction + judge 허용일 때만 RIGHT의 기존 system vibration 3회가 재생되어야 한다.
3. 다른 세 방향도 반복한다. 두 최대 RMS의 차이가 margin 미만이거나 한 role이 stale/missing이면
   자동 AI 결과는 유지하되 direction UNKNOWN, 방향 진동 없음이어야 한다.
4. Auto/수동/Test Direction이 겹쳐도 command 중복 실행/무한 burst가 없어야 한다.
   추론 중 RMS가 바뀌어도 Last Auto Event direction은 trigger 당시 값을 유지해야 한다.

Phase 5 Xcode build / IPA / 실제 iPhone 자동 UI·snapshot·진동 연계는 **미검증**이다.
실제 네 대 동시 방향 테스트는 기기 부족으로 별도 검증이 필요하다. 기존 system vibration 구현은 수정하지 않았다.
