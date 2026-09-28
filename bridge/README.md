# Phase 3 Windows bridge

상태: **구현됨. 실제 iPhone → Wi-Fi → Windows → iPhone 검증 필요.**
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
| 제외한 경로 | `main.py`, `decision`의 threshold/dB gate, 250 ms gating, haptic/logging |
| Python dependency | adapter가 직접 import하는 `numpy`, `tensorflow`, `librosa` |

Bridge는 wire의 signed little-endian Int16을 Float32로 해석하고 `32768.0`으로 나누어
기존 waveform API에 전달한다. resampling, padding, feature extraction, logits,
softmax, calibration을 새로 구현하지 않는다. 기존 모델 graph와 preprocessing을 그대로 실행한다.
결과 dict에서 가장 큰 확률의 기존 label과 그 값을 선택할 뿐 threshold를 추가하지 않는다.
`inference_ms`는 기존 `predict_array()` 호출 시간을 bridge에서 측정한다. 네트워크 왕복 시간은 아니다.
무음에서도 하나의 label이 반환될 수 있으며, 이 결과를 위험 판정으로 해석하지 않는다.

시작 시 기존 `load_model()`과 `load_temperature()`를 호출한다. 이후 요청은 같은 캐시를 사용한다.
기존 API는 별도 device 선택을 하지 않으므로 TensorFlow의 기존 device placement를 그대로 사용한다.
GPU 설정이나 대체 모델은 추가하지 않는다. `HTTPServer`는 요청을 직렬 처리한다.

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
.\.venv\Scripts\python.exe -B -m unittest discover -s bridge -p test_bridge.py -v
```

- Windows 단위 테스트: HTTP 정상/실패, metadata·길이·압축·중복 길이·짧은 body 차단,
  AI 오류 응답, 요청 직렬화, PCM signed/endian 경계값, 기존 API startup load와 호출 재사용 확인.
  이 테스트의 모델은 명시적인 test double이다.
- 별도 실제 모델 검증: 기존 SavedModel에 합성 무음 80,000-byte body를 loopback HTTP로
  두 번 전송해 HTTP 200 및 실제 label/confidence를 받았고, 동일 모델 인스턴스 재사용을 확인했다.
  이 검증은 모델 실행 경로 확인이며 위험음 분류 정확도 평가가 아니다.
- **미검증**: 이번 Swift 변경의 macOS/Xcode 컴파일, 병합된 앱 Info.plist, iOS local-network/ATS 동작,
  실제 Wi-Fi/firewall, iPhone 녹음의 end-to-end 결과, 실제 기기 timeout/취소/재시작 동작.
  기존 Actions의 `Build unsigned iOS app` 로그와 IPA 내부 Info.plist부터 확인한다.
  이후 위 기기 순서대로 검증해야 Phase 3 완료로 기록할 수 있다.
