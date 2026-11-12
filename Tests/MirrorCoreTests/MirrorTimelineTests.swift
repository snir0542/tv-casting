import XCTest
@testable import MirrorCore

final class MirrorTimelineTests: XCTestCase {
    func testVideoTimeStepsOneFramePerSlot() {
        var t = MirrorTimeline()
        t.splice(videoAt: 4.0, slot: 1000, slotHostTime: 500.0)
        XCTAssertEqual(t.videoTime(slot: 1000), 4.0, accuracy: 1e-9)
        XCTAssertEqual(t.videoTime(slot: 1030), 5.0, accuracy: 1e-9)
        XCTAssertEqual(MirrorTimeline.ticks90k(t.videoTime(slot: 1001)), 363_000)
    }

    func testHostToTVTime() {
        var t = MirrorTimeline()
        t.splice(videoAt: 4.0, slot: 1000, slotHostTime: 500.0)
        XCTAssertEqual(t.tvTime(host: 500.0), 4.0, accuracy: 1e-9)
        XCTAssertEqual(t.tvTime(host: 501.25), 5.25, accuracy: 1e-9)
    }

    func testGOPScheduleHasShortFirstGOP() {
        let g = GOPSchedule(start: 100)
        let keys = (95...140).filter { g.isKey(Int64($0)) }
        XCTAssertEqual(keys, [100, 105, 120, 135])
        XCTAssertTrue(g.endsFragment(104))
        XCTAssertTrue(g.endsFragment(119))
        XCTAssertFalse(g.endsFragment(105))
        XCTAssertFalse(g.isKey(99))
    }

    func testAudioStamperStartsAtTheFillerEndAndStaysContinuous() {
        var a = AudioStamper(startAt: 4.0)
        XCTAssertEqual(a.stamp(tvTime: 3.98), .drop)                                // over half a frame early
        XCTAssertEqual(a.stamp(tvTime: 3.995), .place(time: 192_000, silenceBefore: 0)) // snapped to the start
        XCTAssertEqual(a.stamp(tvTime: 4.016), .place(time: 193_024, silenceBefore: 0)) // one AAC frame each
        XCTAssertEqual(a.stamp(tvTime: 4.040), .place(time: 194_048, silenceBefore: 0))
    }

    func testAudioStamperFillsALargeGapWithSilence() {
        var a = AudioStamper(startAt: 4.0)
        XCTAssertEqual(a.stamp(tvTime: 4.0), .place(time: 192_000, silenceBefore: 0))
        // 0.5 s later than expected: 23 silent frames keep the audio track free of holes
        XCTAssertEqual(a.stamp(tvTime: 4.5213), .place(time: 216_576, silenceBefore: 23))
        XCTAssertEqual(a.stamp(tvTime: 4.5427), .place(time: 217_600, silenceBefore: 0))
    }

    func testAudioStamperDropsPacketsFarBehindTheTimeline() {
        var a = AudioStamper(startAt: 4.0)
        _ = a.stamp(tvTime: 4.0)
        XCTAssertEqual(a.stamp(tvTime: 3.7), .drop)
        XCTAssertEqual(a.stamp(tvTime: 4.02), .place(time: 193_024, silenceBefore: 0))
    }
}
