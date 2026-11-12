import Foundation

enum Config {
    /// The AVTransport control URL printed by: python tools/tv_test.py discover
    static let tvControlURL = "http://192.168.1.122:1960/AVTransport/3bb094b5-517d-1511-0a0a-6613b2a3f7c2/control.xml"

    static let avTransportService = "urn:schemas-upnp-org:service:AVTransport:1"
    static let httpPort: UInt16 = 8090
    static let outputWidth = 1280          // every frame sent to the TV is this size (16:9);
    static let outputHeight = 720          // the screen is fitted in with black bars
    static let maxBacklogFrames = 20       // ~0.7s queued for a slow TV: drop and resync on next keyframe
    static let bitrate = 4_000_000
    static let fps = 30
    static let ptsDelay90k: UInt64 = 45_000 // 0.5s decoder buffer (90 kHz units)
    static let audioSampleRate: Double = 48_000 // app audio is sent as AAC-LC stereo at this rate
    static let audioBitrate = 128_000

    static let dlnaFeatures = "DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
    static let protocolInfo = "http-get:*:video/mpeg:" + dlnaFeatures
}
