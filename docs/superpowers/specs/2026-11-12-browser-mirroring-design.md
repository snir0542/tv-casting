# TV Mirror v2.0: low-latency mirroring through the TV's web browser

Date: 2026-11-12. Status: approved in chat, waiting for the user to review this document.

## Goal

Mirror the iPhone screen and app audio to the LG TV with about **1–1.5 s** delay instead of the
10–12 s of v1.1. A full-screen video on the phone fills the whole TV. If the new path cannot start,
mirroring still works through the v1.1 DLNA path.

Success criteria:

- Steady-state delay ≤ 1.5 s with sound, measured with a stopwatch on the phone next to the TV.
- The video fills the TV (1920×1080, no browser bars). Sideways phone video fills the frame, as in v1.1.
- Sound plays on the TV, in sync with the picture.
- The live picture appears within ~6 s of tapping Start Broadcast, showing filler until then.
- After a Wi-Fi hiccup the stream recovers by itself and returns to ~1 s delay.
- If the browser path fails at start, DLNA takes over without the user doing anything.

Out of scope: the microphone, DRM-protected apps (iOS blanks them in screen capture), finding the TV
automatically (the IP stays in `Config.swift`), and more than one TV.

## Background: what the TV does (measured 2026-11-12 from a PC)

TV: LG 2017, webOS 3.5, browser = Chrome 38 with Media Source Extensions (MSE).

| Path | Delay |
|---|---|
| DLNA (v1.1), with every tweak tried (SP flag, videoBroadcast class, CBR, short GOP, muxdelay 0) | 10–12 s |
| TV browser + MSE, plain live stream | 3.5–4.5 s |
| TV browser + MSE + filler splice, video only | 0.74–1.0 s |
| TV browser + MSE + filler splice, with AAC in its own SourceBuffer | 1.25–1.5 s |

Rules the TV's browser follows (all measured):

1. **Every fMP4 fragment must start with a keyframe.** Fragments cut mid-GOP fail with
   `MEDIA_ERR_SRC_NOT_SUPPORTED` (code 4).
2. **It starts or resumes playback only with more than 3 s buffered ahead.** Exactly 3.0 s never
   starts; 6 s starts at once. This applies after every start, seek and underrun.
3. **Once playing, a few hundred ms of buffer is enough.**
4. **`playbackRate` is ignored** (reported as set, plays at 1×). Seeking re-triggers rule 2.
   So the delay cannot be reduced after the start, only set at the start.
5. **Full screen needs a user gesture.** Without it the page gets 1920×909 of 1920×1080. A "click"
   through the TV's pointer socket arrives as `keydown` 13, and `requestFullscreen()` then works.
6. After an underrun with audio, the TV's player once hung for good (position frozen, data buffered).

The trick that gives ~1 s delay: send more than 3 s of filler at once so the TV starts immediately,
then splice the live stream in so it starts just before the filler runs out, with timestamps
continuing exactly where the filler ends. The delay then equals the lead left at the splice.

## Decisions

- **Approach A:** everything runs in the broadcast extension. The main app is often suspended while
  YouTube plays, and a custom TV app needs LG developer mode, which expires every ~50 h.
- **Automatic fallback to DLNA** when the browser path cannot start.
- **Quality:** always encode 1920×1080, start at ~3 Mbps and raise the bitrate while playback is
  smooth. The picture size never changes mid-stream, so the TV never re-initialises its decoder.
  Use 1280×720 for the session if the extension is short on memory at start.

## Components

| Unit | Responsibility | Status |
|---|---|---|
| `Broadcast/H264Encoder.swift` | Rotate/fit as in v1.1. Output size from the session (1080p or 720p). In browser mode, encode on a fixed 30 fps grid locked to the host clock (repeat the last picture for empty slots) with a keyframe every 15 frames. Bitrate settable while running. Emits AVCC samples + format description. Can encode a filler burst of the last picture. | changed |
| `Broadcast/AACEncoder.swift` | As v1.1, plus raw AAC output (no ADTS) and the AudioSpecificConfig for MP4. Can be re-anchored to a new start time. Makes silent filler frames. | changed |
| `Broadcast/FMP4Muxer.swift` | Per-track init segment (`ftyp` + `moov` with `avc1`/`avcC` or `mp4a`/`esds`, `mvex`) and media fragments (`moof` with `mfhd`/`tfhd`/`tfdt`/`trun` + `mdat`). Video timescale 90000, audio 48000. | **new** |
| `Broadcast/TSMuxer.swift` | Unchanged; used only by the DLNA fallback. | unchanged |
| `Broadcast/StreamServer.swift` | Serves `GET /` (player page), `GET /ws` (WebSocket: hand-rolled handshake with CryptoKit SHA-1, binary/text frames, ping/close), and keeps `GET /screen.ts` for DLNA. | changed |
| `Broadcast/player.html` | The TV page (ES5, Chrome 38). Two SourceBuffers, one WebSocket. Asks for go-live and refills, rebuilds a stuck player, goes full screen on `keydown`, reports stats. Bundled as an extension resource. | **new** |
| `Shared/LGTVRemote.swift` | SSAP client over `URLSessionWebSocketTask` to `ws://<TV>:3000` (no Origin header): register (PROMPT pairing, client-key in the extension's `UserDefaults`), `system.launcher/open`, `getPointerInputSocket` + `type:click`. Registration manifest taken from PyWebOSTV (MIT), credited in the source. | **new** |
| `Broadcast/MirrorSession.swift` | Browser-mode logic: TV timeline, filler/splice state machine, recovery, adaptive lead and bitrate, start-up watchdog for the fallback. | **new** |
| `Broadcast/SampleHandler.swift` | Starts browser mode; switches to the v1.1 DLNA path when `MirrorSession` reports a start-up failure. | changed |
| `Shared/Config.swift` | New constants (below); keeps the TV address. | changed |
| `App/TVMirrorApp.swift` | Text: the first start shows an "allow this device?" prompt on the TV. The test button checks the TV's DLNA and control ports. | changed |
| `tools/browser_test.py` | PC stand-in for the phone: serves `Broadcast/player.html`, speaks the same WebSocket protocol, streams ffmpeg fMP4, can simulate hiccups, launches the TV browser over SSAP. Grows out of the spike's `browser_probe.py`. | **new** |

No App Group is needed: the extension pairs with the TV itself and keeps its own client-key.

## Start-up sequence

1. `broadcastStarted`: create encoder, audio encoder, server and `MirrorSession`. Pick 1080p unless
   `os_proc_available_memory()` is below `Config.minMemoryFor1080p`.
2. `LGTVRemote` connects to the TV and registers (first time: the TV shows the prompt).
   It then opens `http://<phone-ip>:8090/` in the TV browser.
3. The page connects to `/ws`, builds a `MediaSource` with a video and an audio SourceBuffer, and sends
   `hello`.
4. The phone sends both init segments, then the **filler** at TV time 0. The filler is the current
   picture (black if none yet) for `Config.fillerSeconds` at 30 fps (one keyframe, then repeats) plus
   silent AAC covering at least the same span.
5. Shortly after `hello`, the phone sends a pointer click, and the page goes full screen on the
   resulting `keydown`. The page reports `fullscreen`, and the phone retries the click up to twice if
   it is off.
6. When playing with `remaining filler ≤ lead`, the page sends `golive` with each SourceBuffer's
   buffered end.
7. The phone forces a keyframe on the next 30 fps slot and maps that slot to the video filler end.
   It re-anchors the audio so its timeline continues exactly at the audio filler end (within one AAC
   frame, ≤ 21 ms). Live fragments follow:
   - Video: one fragment per 15 frames (0.5 s), sent as soon as the 15th frame is encoded.
   - Audio: one fragment per 5 AAC frames (~107 ms).

### TV timeline

- One timeline in seconds, starting at 0 with the first filler. The phone keeps
  `offset = hostTime − tvTime`, set at every splice.
- Video: frame k after a splice is stamped `spliceTime + k/30`, with a constant sample duration of
  3000 at 90 kHz. The timeline is gap-free by construction.
- Audio: PCM captured at host time h goes to TV time `h − offset`. PCM that falls before the audio
  filler end is dropped. Gaps are filled with silence, as in v1.1.

## WebSocket protocol (one connection)

Binary, phone → page: first byte = track (`0` video, `1` audio), the rest is appended unchanged to that
track's SourceBuffer (init segment or `moof`+`mdat`).

Text JSON, phone → page: `{"type":"config","lead":1.0}`, `{"type":"bye"}`.

Text JSON, page → phone:

| Message | When |
|---|---|
| `{"type":"hello","mse":true,"ua":"..."}` | WebSocket open; `mse:false` → fallback |
| `{"type":"golive","v":<end s>,"a":<end s>}` | filler remaining ≤ lead |
| `{"type":"underrun","pos":<s>}` | `waiting` with < 0.1 s buffered |
| `{"type":"stuck","pos":<s>}` | position frozen 5 s while > 1 s buffered (page has rebuilt its player) |
| `{"type":"stats","pos":<s>,"lag":<s>,"rs":<n>}` | every 500 ms |
| `{"type":"fullscreen","on":<bool>}` | on change |
| `{"type":"error","what":"..."}` | media error / append exception |

## Recovery

- **Underrun** (rule 2 makes a freeze unavoidable): the phone sends a refill of the frozen last
  picture plus silence, starting at the current buffered end. It splices live again on the next
  `golive`. The user sees a 3–5 s freeze, then ~1 s delay again.
  - Each underrun raises the lead by 0.5 s (1.0 → 1.5 → 2.0 s max) and halves the bitrate.
- **Stuck player:** the page tears down its `MediaSource`, builds a new one, and sends `stuck`. The phone
  resends the init segments and a filler from TV time 0 (a new timeline).
  - If that fails twice in a row, the phone reopens the page through `system.launcher/open`.
- **Page gone** (browser closed on the TV): wait `Config.reconnectSeconds` (10 s) for a new `/ws`
  connection (a new connection gets the full start-up from step 4).
  - Otherwise end the broadcast with "The TV browser was closed".

## Adaptive bitrate

- Start at `Config.startBitrate` (3 Mbps).
- After every 10 s without underrun and with the WebSocket send backlog under 0.5 s of data, add
  1 Mbps, up to `Config.maxBitrate` (8 Mbps).
- On an underrun, or a send backlog over 1 s, halve it, down to `Config.minBitrate` (2 Mbps).
- If VideoToolbox emits new SPS/PPS after a bitrate change, send a new video init segment before the
  next fragment. The resolution is unchanged, so MSE accepts it.

## Fallback to DLNA (start-up only)

Switch to the v1.1 path (TS muxer + `DLNAController.play`, 720p as in v1.1) when:

- the TV's control port does not answer within 5 s;
- the pairing is refused, or not accepted within 60 s;
- the page does not connect within 15 s of opening the browser;
- `hello` says `mse:false`, an `error` arrives before the first `golive`, or the TV is not playing
  15 s after `hello`.

Log the reason. Once browser mode has played, failures are handled by recovery, not by the fallback.

## Stop

`broadcastFinished`: send `bye`, after which the page shows "Mirroring stopped". Then stop the encoders and
server and close the TV connections. If DLNA was in use, stop DLNA as in v1.1.

## New `Config` values

`controlPort = 3000`, `fillerSeconds` (default 4.0, set by check 2 below), `startLead = 1.0`,
`maxLead = 2.0`, `gopFrames = 15`, `startBitrate = 3_000_000`, `minBitrate = 2_000_000`,
`maxBitrate = 8_000_000`, `minMemoryFor1080p = 25 MB` (available memory at start),
`reconnectSeconds = 10`, `controlTimeout = 5`, `pairingTimeout = 60`, `pageTimeout = 15`.

## Testing

1. **Pre-implementation TV checks from the PC** (automatic, TV on), extending the spike:
   - iPhone-like video: H.264 Main with CABAC, no B-frames, 1080p, and a bitrate change mid-stream;
   - the shortest filler that starts playback: 3.5, 4 and 5 s;
   - a 10-minute run with simulated 2 s send pauses, covering refill and stuck recovery.
   The results set `fillerSeconds` and confirm the bitrate ramp before any Swift is written.
2. **Page tests without the phone:** `tools/browser_test.py` serves the real `player.html`, in desktop
   Chrome and on the TV.
3. **Swift unit tests in CI** (new test target, run on the macOS runner): `FMP4Muxer` box layout and
   sizes, timeline/splice arithmetic, WebSocket framing, and the `MirrorSession` state machine with a fake
   clock. One test writes a sample stream to a file, uploaded as a build artifact. On the PC it is
   checked with ffprobe and played on the TV through `browser_test.py` before the phone build is
   installed.
4. **On the iPhone (v2.0 IPA via Sideloadly):**
   - first-time pairing prompt;
   - delay with a stopwatch;
   - YouTube full screen, sideways;
   - sound sync;
   - recovery (walk away from the router);
   - fallback (refuse the prompt);
   - memory at 1080p (the extension is not killed during 10 minutes).

## Risks

- **Extension memory (~50 MB) at 1080p:** mitigated by the 720p choice at start. Check 4 measures it.
- **VideoToolbox output differs from x264** (CABAC, VUI, SPS changes on a bitrate change): check 1 covers
  the CABAC side; in-band parameter-set changes are handled with a new init segment.
- **A 0.5 s GOP at a low bitrate looks softer:** acceptable at start; the bitrate ramp compensates.
- **The TV browser may misbehave over long sessions** (memory, screensaver). The 10-minute check runs
  before the build and the device test runs after it. The page removes played-out media every 10 s.
- **The SSAP registration manifest comes from PyWebOSTV:** credited in the source.

## Version

`MARKETING_VERSION` 2.0. Work continues on the `dev` branch (never master).
