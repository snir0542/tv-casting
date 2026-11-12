# TV Mirror — iPhone → LG TV (2017) via DLNA

The iPhone streams its screen and app audio (ReplayKit → H.264 + AAC → MPEG-TS over HTTP) and tells
the TV (UPnP AVTransport) to play that URL. No PC is needed once it is installed. The microphone is not sent.

## 1. Test the TV (Windows, ~10 min)
Requirements: Python 3, FFmpeg in PATH (`winget install Gyan.FFmpeg`).

    python tools\tv_test.py discover
    python tools\tv_test.py play

If Windows Firewall asks, allow Python on private networks.
You should see a test pattern with a running clock on the TV.
- Nothing found → `--tv <TV_IP>`
- TV shows an error → try `play --silent-audio`
- Works → copy the "control URL" printed by `discover`.

## 2. Configure
Paste the control URL into `Shared/Config.swift` → `tvControlURL`.

## 3. Build in GitHub Actions
1. Create a **public** repo (free macOS minutes), push to a branch such as `dev` (not master).
2. Actions → "Build IPA" → download the `TVMirror-ipa` artifact → unzip → `TVMirror.ipa`.
   If it fails, download the `build-log` artifact.

## 4. Install with Sideloadly (Windows)
1. Install iTunes (Apple's website version, not the Store) + Sideloadly.
2. Connect the iPhone by cable, drag the IPA, enter your Apple ID, Start.
3. iPhone: Settings → Privacy & Security → Developer Mode → On (restart).
4. Settings → General → VPN & Device Management → trust your Apple ID.
The signature expires after 7 days: reinstall with Sideloadly.

## 5. Use
1. Open TV Mirror → "בדיקת חיבור לטלוויזיה" → allow Local Network.
2. Tap the round button → TV Mirror → Start Broadcast.

## Logs
`idevicesyslog | findstr tvmirror` (libimobiledevice for Windows), or the error shown by iOS when the broadcast stops.

## Structure
- `Broadcast/` — the extension: `H264Encoder`, `AACEncoder`, `TSMuxer`, `StreamServer` (HTTP), `SampleHandler`
- `Shared/` — `Config`, `DLNAController` (SOAP)
- `App/` — UI with the broadcast picker
- `tools/tv_test.py` — TV test from a PC
