# TV Mirror — iPhone → LG TV (2017)

The iPhone streams its screen and app audio to the TV with about **1–1.5 s** delay. The microphone is
not sent, and no PC is needed once the app is installed.

**Browser mode (v2.0, default).** The phone opens the TV's own web browser over the TV's control
socket, as LG's remote app does. The browser plays H.264 + AAC in fragmented MP4 over a WebSocket. The
TV only starts playing with more than 3 s buffered, so the phone first sends a few seconds of "filler"
(the frozen screen) and joins the live picture just before it runs out. A remote "click" puts the page
in full screen.

**DLNA mode (v1.1, automatic fallback).** H.264 + AAC in MPEG-TS over HTTP, played by the TV's media
player, with ~10 s delay. It is used when browser mode cannot start: the TV is unreachable, the prompt
was refused, or the page does not play.

Design: `docs/superpowers/specs/2026-11-12-browser-mirroring-design.md`.

## 1. Test the TV (Windows, ~10 min)
Requirements: Python 3, FFmpeg in PATH (`winget install Gyan.FFmpeg`).

    python tools\tv_test.py discover
    python tools\tv_test.py play

If Windows Firewall asks, allow Python on private networks.
You should see a test pattern with a running clock on the TV.
- Nothing found → `--tv <TV_IP>`
- TV shows an error → try `play --silent-audio`
- Works → copy the "control URL" printed by `discover`.

Browser mode, without the phone (`tools/browser_test.py` stands in for the iPhone):

    python tools\browser_test.py --tv <TV_IP>
    python tools\browser_test.py --tv <TV_IP> --minutes 10 --hiccup-every 60 --hiccup-seconds 2

## 2. Configure
Paste the control URL into `Shared/Config.swift` → `tvControlURL`. Browser mode uses the same TV address.

## 3. Build in GitHub Actions
1. Create a **public** repo (free macOS minutes), push to a branch such as `dev` (not master).
2. Actions → "Build IPA": the `MirrorCore` unit tests run first (`swift test`).
3. Download the `TVMirror-ipa` artifact, unzip it to get `TVMirror.ipa`.
   If the build fails, download the `build-log` or `test-log` artifact.

## 4. Install with Sideloadly (Windows)
1. Install iTunes (Apple's website version, not the Store) + Sideloadly.
2. Connect the iPhone by cable, drag the IPA, enter your Apple ID, Start.
3. iPhone: Settings → Privacy & Security → Developer Mode → On (restart).
4. Settings → General → VPN & Device Management → trust your Apple ID.
The signature expires after 7 days: reinstall with Sideloadly.

## 5. Use
1. Open TV Mirror → "בדיקת חיבור לטלוויזיה" → allow Local Network.
2. Tap the round button → TV Mirror → Start Broadcast.
3. The first time, the TV asks "allow this device?": accept with the remote. The TV browser then
   opens, shows "connecting" for a few seconds, and switches to full screen.

## Logs
`idevicesyslog | findstr tvmirror` (libimobiledevice for Windows), or the error shown by iOS when the broadcast stops.

## Structure
- `Broadcast/` — the extension:
  - `SampleHandler` picks the mode;
  - browser mode: `MirrorSession`, `LGTVRemote`, `player.html`;
  - shared: `H264Encoder`, `AACEncoder`, `StreamServer` (HTTP + WebSocket);
  - DLNA: `TSMuxer`.
- `Core/` — platform-independent parts, unit-tested in CI (`swift test`): `FMP4`, `WebSocket`, `SSAP`,
  `MirrorLogic`, `MirrorTimeline`.
- `Shared/` — `Config`, `DLNAController` (SOAP).
- `App/` — UI with the broadcast picker.
- `tools/tv_test.py` — DLNA test from a PC. `tools/browser_test.py` — browser-mode test from a PC.
