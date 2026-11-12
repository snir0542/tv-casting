# TV Mirror v2.0 (browser mode) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mirror the iPhone to the LG TV through the TV's web browser with ~1–1.5 s delay. Fall back to the v1.1 DLNA path automatically.

**Architecture:** Platform-independent logic lives in a small Swift package `MirrorCore` (`Core/`), unit-tested in CI with `swift test`: fMP4 boxes, WebSocket framing, the LG SSAP protocol, and the session state machine. The broadcast extension compiles the same files and adds thin iOS glue: encoders, server, TV remote, session runner. The TV page (`Broadcast/player.html`) is tested from the PC with `tools/browser_test.py`, which stands in for the phone.

**Tech Stack:** Swift 5 (iOS 16 / macOS 13), VideoToolbox, AVAudioConverter, Network.framework, CryptoKit; ES5 JavaScript for Chrome 38 (webOS 3.5); Python 3 + ffmpeg for PC tests; GitHub Actions `macos-latest`, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-12-browser-mirroring-design.md`

## Global Constraints

- iOS deployment target 16.0. `MARKETING_VERSION` 2.0, `CURRENT_PROJECT_VERSION` 3.
- Work on branch `dev`, never master. Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- No Mac is available: Swift only compiles and runs on the CI runner. Every task that touches Swift ends with a push and a green CI run.
- The TV page must run on Chrome 38: ES5 only (no arrow functions, `let`/`const`, template strings or classes).
- Every fMP4 fragment starts with a keyframe. Video timescale 90000, audio 48000. One track per init segment (track ID 1), one SourceBuffer per track.
- The TV starts or resumes only with more than 3 s buffered: the filler length comes from pre-build check 2 (`Config.fillerSeconds`).
- Default numbers: lead 1.0 s (+0.5 s per underrun, max 2.0); bitrate 3 Mbps start, +1 Mbps every 10 s smooth, max 8, min 2; GOP 15 frames at 30 fps.
- Keep the v1.1 DLNA path working (`TSMuxer`, `DLNAController`, `/screen.ts`).

## File map

| File | Responsibility |
|---|---|
| `Package.swift` | SwiftPM manifest: target `MirrorCore` (path `Core`), test target `MirrorCoreTests` (path `Tests/MirrorCoreTests`) |
| `Core/ByteWriter.swift` | Big-endian byte writer with box/full-box helpers |
| `Core/FMP4.swift` | `FMP4.videoInit`, `FMP4.audioInit`, `FMP4.fragment`, `FMP4Sample`, track configs |
| `Core/WebSocket.swift` | Handshake accept key, server frame encoding, client frame parser |
| `Core/SSAP.swift` | LG register payload (from PyWebOSTV, MIT), request builders, reply parser |
| `Core/MirrorLogic.swift` | Session state machine: filler/splice/recovery/lead/bitrate/fallback decisions as `MirrorAction`s |
| `Tests/MirrorCoreTests/*.swift` | Unit tests for the four Core files + a VideoToolbox sample-stream writer |
| `Broadcast/player.html` | TV page |
| `tools/browser_test.py` | PC stand-in for the phone (local Chrome or TV via SSAP), hiccup simulation, sample replay |
| `Broadcast/H264Encoder.swift` | + browser mode: 30 fps host-locked grid, GOP 15, bitrate setter, AVCC output, filler burst |
| `Broadcast/AACEncoder.swift` | + raw AAC packets with host time, silent packet |
| `Broadcast/StreamServer.swift` | + `GET /` page, `GET /ws` WebSocket client |
| `Broadcast/LGTVRemote.swift` | SSAP over `NWConnection` + `NWProtocolWebSocket` (register, open URL, pointer click) |
| `Broadcast/MirrorSession.swift` | Runs `MirrorLogic`: muxing, timeline, sending, executing actions |
| `Broadcast/SampleHandler.swift` | Browser mode first, DLNA on fallback |
| `Shared/Config.swift`, `App/TVMirrorApp.swift`, `project.yml`, `.github/workflows/build.yml`, `README.md` | config, UI text, build, docs |

---

### Task 1: MirrorCore package + fMP4 muxer

**Files:**
- Create: `Package.swift`, `Core/ByteWriter.swift`, `Core/FMP4.swift`, `Tests/MirrorCoreTests/FMP4Tests.swift`
- Modify: `.github/workflows/build.yml` (add a `swift test` step before the IPA build; upload `sample-stream` if present)

**Interfaces (produces):**
```swift
struct FMP4VideoConfig { var width: Int; var height: Int; var sps: [UInt8]; var pps: [UInt8] }
struct FMP4AudioConfig { var sampleRate: Int; var channels: Int; var audioSpecificConfig: [UInt8] }
struct FMP4Sample { var data: [UInt8]; var duration: UInt32; var isSync: Bool }
enum FMP4 {
    static func videoInit(_ c: FMP4VideoConfig) -> [UInt8]
    static func audioInit(_ c: FMP4AudioConfig) -> [UInt8]
    static func fragment(sequence: UInt32, baseTime: UInt64, samples: [FMP4Sample]) -> [UInt8]
    static let aacLC48kStereoASC: [UInt8] = [0x11, 0x90]
}
```

- [ ] Write `FMP4Tests`: parse top-level boxes of `videoInit` (expect `ftyp`, `moov`; `moov` contains `mvhd`, `trak`, `mvex`; the `avcC` payload is `[1, sps[1], sps[2], sps[3], 0xFF, 0xE1, len16(sps), sps…, 1, len16(pps), pps…]`). Parse `audioInit` (`mp4a`, `esds` contains the ASC bytes, `mdhd` timescale 48000). For `fragment(sequence: 7, baseTime: 123_456_789_012, samples: [sync 10 B, non-sync 5 B])`:
  - boxes are `moof`, `mdat`;
  - `mfhd` sequence is 7;
  - `tfhd` flags are `0x020000`;
  - `tfdt` is version 1 with the base time;
  - `trun` flags are `0x000701`, with sample count 2;
  - the data offset equals `moof.size + 8`;
  - the sample flags are `0x02000000` / `0x01010000`;
  - the `mdat` payload is the concatenated sample bytes.
- [ ] Run `swift test` in CI (push): expect failure (types missing).
- [ ] Implement `ByteWriter` (`u8/u16/u24/u32/u64`, `bytes`, `box(_:_:)`, `fullBox(_:version:flags:_:)`) and `FMP4` per ISO/IEC 14496-12/-15. Use the same box layout as ffmpeg's `frag_keyframe+empty_moov+default_base_moof` output, which the TV played in the spike.
- [ ] Push; expect `swift test` green and the IPA build still green.
- [ ] Commit: "Add MirrorCore: fragmented MP4 muxer for the TV browser".

### Task 2: WebSocket framing

**Files:** Create `Core/WebSocket.swift`, `Tests/MirrorCoreTests/WebSocketTests.swift`

**Interfaces (produces):**
```swift
enum WebSocket {
    static func acceptKey(for clientKey: String) -> String
    static func handshakeResponse(clientKey: String) -> String
    static func frame(opcode: UInt8, payload: [UInt8]) -> [UInt8]     // server side: FIN, unmasked
    static func clientFrame(opcode: UInt8, payload: [UInt8], mask: [UInt8]) -> [UInt8] // masked (TV remote)
    struct Parser { mutating func append(_ bytes: [UInt8]); mutating func next() -> (opcode: UInt8, payload: [UInt8])? }
    static func headers(of request: String) -> [String: String]       // lower-cased names
}
```
- [ ] Tests:
  - RFC 6455 key `dGhlIHNhbXBsZSBub25jZQ==` → `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`;
  - frame header bytes for payload lengths 0, 125, 126, 65535, 65536;
  - the parser decodes the RFC masked "Hello" (`81 85 37 fa 21 3d 7f 9f 4d 51 58`), including when fed one byte at a time;
  - the parser round-trips `clientFrame` and returns nil on incomplete input;
  - `headers(of:)` finds `sec-websocket-key`.
- [ ] Implement with CryptoKit `Insecure.SHA1`. Push, CI green, commit "Add WebSocket framing to MirrorCore".

### Task 3: LG SSAP protocol

**Files:** Create `Core/SSAP.swift`, `Tests/MirrorCoreTests/SSAPTests.swift`

**Interfaces (produces):**
```swift
enum SSAPReply: Equatable { case prompt, registered(clientKey: String), response(id: String, payload: [String: String]), error(id: String, message: String) }
enum SSAP {
    static func register(clientKey: String?) -> String            // JSON text frame
    static func request(id: String, uri: String, payload: [String: String]) -> String
    static func parse(_ text: String) -> SSAPReply?
    static func pointerPath(fromSocketPath: String) -> String?   // "ws://h:3000/resources/x/netinput.pointer.sock" -> "/resources/x/netinput.pointer.sock"
    static let clickCommand = "type:click\n\n"
}
```
- [ ] Tests:
  - `register(nil)` decodes as JSON with `type == "register"`, `payload.pairingType == "PROMPT"`, the manifest signature present and no `client-key`;
  - `register("abc")` carries `client-key`;
  - `parse` maps the real TV replies captured in the spike: `{"type":"response","id":"register_0","payload":{"pairingType":"PROMPT"}}` → `.prompt`, `{"type":"registered","payload":{"client-key":"k"}}` → `.registered`, an `open_1` response with `returnValue` → `.response`, and `{"type":"error","id":"x","error":"401 insufficient permissions"}` → `.error`;
  - `pointerPath` on the spike's socket path.
- [ ] Implement (manifest copied from PyWebOSTV's `connection.py`, MIT, with a credit comment). Push, CI green, commit "Add LG SSAP protocol helpers to MirrorCore".

### Task 4: Session state machine

**Files:** Create `Core/MirrorLogic.swift`, `Core/MirrorTimeline.swift`, `Tests/MirrorCoreTests/MirrorLogicTests.swift`, `Tests/MirrorCoreTests/MirrorTimelineTests.swift`

**Interfaces (produces):**
```swift
struct MirrorTuning { var fillerSeconds = 4.0; var startLead = 1.0; var maxLead = 2.0; var leadStep = 0.5
    var startBitrate = 3_000_000; var minBitrate = 2_000_000; var maxBitrate = 8_000_000; var bitrateStep = 1_000_000
    var rampInterval = 10.0; var pageTimeout = 15.0; var maxBacklog = 1.0; var smoothBacklog = 0.5 }
enum MirrorAction: Equatable {
    case sendConfig(lead: Double)
    case sendInit                                  // both init segments
    case sendFiller(at: Double, seconds: Double)   // TV time where the filler starts
    case goLive(videoAt: Double, audioAt: Double)  // splice live at these TV times
    case setBitrate(Int)
    case reopenPage
    case fallback(reason: String)                  // start-up failure: switch to DLNA
    case stop(reason: String)                      // end the broadcast (TV browser closed for good)
}
struct MirrorTimeline {                            // in Core/MirrorTimeline.swift
    mutating func splice(videoAt: Double, slot: Int64, slotHostTime: Double)
    func videoTime(slot: Int64) -> Double          // videoAt + (slot - spliceSlot) / 30
    func tvTime(host: Double) -> Double            // host - offset
}
struct GOPSchedule {                               // keys at start, start+5, then every 15
    init(start: Int64, first: Int64 = 5, every: Int64 = 15)
    func isKey(_ slot: Int64) -> Bool
    func endsFragment(_ slot: Int64) -> Bool       // isKey(slot + 1)
}
struct AudioStamper {                              // continuous 48 kHz timestamps from a start time
    init(startAt: Double, frameSeconds: Double = 1024.0 / 48000)
    mutating func stamp(tvTime: Double) -> UInt64? // nil = drop (before the start); else start + n*1024
}
final class MirrorLogic {
    init(tuning: MirrorTuning)
    private(set) var lead: Double; private(set) var bitrate: Int; private(set) var isLive: Bool
    func browserOpened(now: Double) -> [MirrorAction]
    func pageHello(mse: Bool, now: Double) -> [MirrorAction]        // → [.sendConfig, .setBitrate, .sendInit, .sendFiller(at: 0, …)] or [.fallback]
    func pageGoLive(videoEnd: Double, audioEnd: Double, now: Double) -> [MirrorAction]
    func pageUnderrun(bufferedEnd: Double, now: Double) -> [MirrorAction]   // refill at bufferedEnd, lead += step, bitrate /= 2
    func pageStuck(now: Double) -> [MirrorAction]                  // new timeline: sendInit + sendFiller(at: 0); 3rd in a row → reopenPage
    func pageError(_ what: String, now: Double) -> [MirrorAction]  // before first live → fallback
    func sendBacklog(seconds: Double, now: Double) -> [MirrorAction]
    func pageClosed(now: Double) -> [MirrorAction]
    func controlFailed(_ reason: String) -> [MirrorAction]         // TV unreachable / pairing refused → fallback
    func tick(now: Double) -> [MirrorAction]                       // page timeouts, reconnect timeout, bitrate ramp
}
```
- [ ] Tests (fake clock):
  - hello → config, bitrate 3M, init, filler at 0 for 4 s;
  - hello with `mse:false` → fallback;
  - no hello 15 s after `browserOpened` → fallback "page did not connect";
  - hello but no go-live within 15 s → fallback "TV did not start playing";
  - go-live → `.goLive(videoAt:audioAt:)` and `isLive`;
  - an error before the first go-live → fallback, after it → no fallback;
  - underrun → filler at the buffered end, lead 1.5, bitrate halved, and the lead stops at 2.0;
  - 10 s smooth → +1 Mbps up to 8 Mbps, and no ramp while not live;
  - backlog > 1 s → halve, down to the 2 Mbps minimum;
  - stuck → init + filler at 0, and the third stuck in a row → reopenPage;
  - pageClosed → no actions until `tick` 10 s later → `.stop(reason: "The TV browser was closed")`, and a hello within 10 s cancels it;
  - `controlFailed` before the first play → fallback;
  - timeline: `videoTime` steps 1/30 s per slot from the splice, and `tvTime` maps the splice slot's host time to `videoAt`;
  - GOPSchedule: keys at 100, 105, 120, 135; `endsFragment(104)` and `endsFragment(119)` are true;
  - AudioStamper(startAt: 4.0): tv 3.98 → nil, 3.995 → 192000, the next → 193024.
- [ ] Implement. Push, CI green, commit "Add the mirroring session state machine to MirrorCore".

### Task 5: Sample stream from real VideoToolbox output

**Files:** Create `Tests/MirrorCoreTests/SampleStreamTests.swift`; modify `.github/workflows/build.yml` (env `SAMPLE_OUT=$RUNNER_TEMP/sample`, upload artifact `sample-stream`)

- [ ] Test (macOS, skipped via `XCTSkip` if VideoToolbox cannot create an H.264 session):
  - encode 4 s of filler (one gray picture, a keyframe then repeats) and then 10 s of moving frames (a moving bar), 1920×1080 at 30 fps, Main profile, no reordering, keyframe every 15 frames;
  - build the init segment from the format description's SPS/PPS;
  - write `video.init`, `video.frags` (filler = 1 fragment at t=0, live = 0.5 s fragments from t=4), and the same for audio (`FMP4.aacLC48kStereoASC`; 1024-sample silent packets made by AVAudioConverter);
  - assert every fragment's first sample is sync and the tfdt values are continuous.
- [ ] Push; download the artifact. Then:
  - on the PC, `ffprobe` the concatenated `video.init + video.frags`: expect h264 Main, 1920×1080, about 14 s;
  - replay it on the TV via `browser_test.py --sample`; it must play, and splice at 4 s.
- [ ] Commit "Write a VideoToolbox sample stream in CI for TV checks".

### Task 6: TV page + PC stand-in, soak test

**Files:** Create `Broadcast/player.html`, `tools/browser_test.py`

- [ ] `player.html` (ES5), per the spec protocol:
  - one WebSocket to `/ws`;
  - binary messages: byte 0 = track (0 video, 1 audio), the rest is appended to that track's SourceBuffer (queued while updating);
  - text messages: `config` (lead), `bye` (show "Mirroring stopped");
  - sends `hello` (mse, ua) on open; `golive` once playing with filler remaining ≤ lead; `underrun` on `waiting` with < 0.1 s buffered (once per stall); `stuck` (after rebuilding the MediaSource) when the position is frozen 5 s with > 1 s buffered; `stats` every 500 ms; `fullscreen`; `error`;
  - calls `requestFullscreen` on `keydown`/`click`;
  - removes media more than 10 s behind the position;
  - video element 100% of the screen, black background, small status text that hides once playing.
- [ ] `tools/browser_test.py` (reuses the spike code, now in the repo):
  - serves `Broadcast/player.html` and `/ws`, speaking the phone side of the protocol with ffmpeg (1080p CABAC video + AAC);
  - filler and refill made from a filler file re-timed by rewriting `tfdt`, splice on `golive`, new timeline on `stuck`;
  - options `--tv` (SSAP open + click), `--local`, `--hiccup-every S --hiccup-seconds D` (pause sending), `--minutes M`, `--sample DIR`;
  - prints delay stats every 10 s and a summary.
- [ ] Desktop Chrome (Playwright): `--local --minutes 1`: plays, golive happens, delay < 1.5 s.
- [ ] TV pre-build check 3: `--tv --minutes 10 --hiccup-every 60 --hiccup-seconds 2`. Expect every hiccup to recover to a delay < 2.5 s, no stuck player left unrecovered, and full screen 1920×1080.
- [ ] Commit "Add the TV player page and a PC stand-in for the phone".

### Task 7: Encoders for browser mode

**Files:** Modify `Broadcast/H264Encoder.swift`, `Broadcast/AACEncoder.swift`, `Shared/Config.swift`

**Interfaces (produces):**
```swift
struct EncodedVideo { let avcc: [UInt8]; let isKey: Bool; let slot: Int64; let sps: [UInt8]; let pps: [UInt8] }
final class H264Encoder {
    enum Mode { case dlna, browser }
    init(mode: Mode, width: Int, height: Int)
    var onFrame: (([UInt8], Double, Bool) -> Void)?   // dlna (unchanged)
    var onVideo: ((EncodedVideo) -> Void)?             // browser
    func setBitrate(_ bps: Int)
    func startLive(keyAtSlot: Int64)                    // browser: encode the grid from here, key every 15 slots
    func pauseLive()
    func encodeFiller(frames: Int, completion: @escaping ([EncodedVideo]) -> Void) // last picture, key first
    func currentSlot() -> Int64                         // host-locked 30 fps grid index
    static func slotHostTime(_ slot: Int64) -> Double
}
final class AACEncoder {
    var onPacket: (([UInt8], Double) -> Void)?   // raw AAC + host time (browser)
    var silentPacket: [UInt8]? { get }
}
```
- [ ] Implement:
  - DLNA behaviour unchanged when `mode == .dlna` (720p, annexB);
  - browser mode: a 30 Hz timer encodes the last picture for every grid slot since the last one (duplicates fill missed ticks), forces a key on `(slot - keySlot) % 15 == 0`, and passes the slot through the encode closure;
  - the filler burst encodes N copies of the last picture (black if none) with increasing private PTS while live is paused;
  - `Config` adds the spec's values.
- [ ] Push; the IPA build must compile. Commit "Add browser-mode output to the encoders".

### Task 8: Server, TV remote, session, fallback

**Files:** Modify `Broadcast/StreamServer.swift`, `Broadcast/SampleHandler.swift`, `App/TVMirrorApp.swift`, `project.yml`, `README.md`; create `Broadcast/LGTVRemote.swift`, `Broadcast/MirrorSession.swift`

- [ ] `StreamServer`:
  - `GET /` serves `player.html` from the extension bundle; `GET /ws` upgrades (`WebSocket.handshakeResponse`);
  - `onSocket: (PageSocket) -> Void`, where `PageSocket` has `send(binary:)`, `send(text:)`, `onText`, `onClose`, and `backlogBytes` (tracked with `.contentProcessed`);
  - `/screen.ts` is unchanged.
- [ ] `LGTVRemote`: `NWConnection` with `NWProtocolWebSocket.Options` (no Origin). Methods:
  - `register(timeout:)`: stores the client-key in `UserDefaults`, throws `.unreachable/.refused/.timeout`;
  - `open(url:)`;
  - `click()`, through the pointer socket.
- [ ] `MirrorSession`:
  - owns `MirrorLogic`, the page socket, the encoders and the `FMP4` state (sequence numbers, the GOP being built);
  - executes actions: init from the SPS/PPS of the first keyframe; filler = the encoder burst plus N silent AAC packets, stamped from `at`; `goLive` maps slot → TV time and host time → TV time with `offset`; video fragments are flushed on the 15th slot of a GOP; audio fragments every 5 packets;
  - if a keyframe's SPS/PPS differ from the last init segment (for example after a bitrate change), sends a new video init segment before that fragment;
  - calls `click()` 1 s after `hello` and again if `fullscreen` is false 3 s later (max 2 retries);
  - feeds `sendBacklog` every 500 ms and calls `tick` every 500 ms;
  - sends `bye` on stop.
- [ ] `SampleHandler`:
  - picks 1080p if `os_proc_available_memory() ≥ 25 MB`, else 720p;
  - starts `MirrorSession`; on `.fallback(reason)`, logs, tears it down and starts the v1.1 DLNA path (encoder `.dlna` 720p, TS, `DLNAController.play`);
  - a register or open failure (unreachable, timeout, refused) also falls back.
- [ ] `project.yml`:
  - the extension sources gain `Core`;
  - `player.html` is a resource;
  - versions 2.0/3.
- [ ] App text: explain the first-time "allow" prompt. README: v2.0 flow, `tools/browser_test.py`.
- [ ] Push; CI must be green (tests + IPA). Commit "Mirror through the TV browser with ~1 s delay (v2.0)".

### Task 9: Hand-off

- [ ] Download the IPA artifact to `C:\Users\snira\Downloads\tvmirror-v2.0\` and check its Info.plist values and that `player.html` is in the appex.
- [ ] Give the user the device checklist from the spec (pairing prompt, stopwatch delay, YouTube full screen sideways, sound sync, recovery, fallback, 10-minute stability).
