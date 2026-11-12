import XCTest
@testable import MirrorCore

final class MirrorLogicTests: XCTestCase {
    private func started(_ logic: MirrorLogic = MirrorLogic()) -> MirrorLogic {
        _ = logic.browserOpened(now: 0)
        _ = logic.pageHello(mse: true, now: 1)
        return logic
    }

    private func live() -> MirrorLogic {
        let logic = started()
        _ = logic.pageGoLive(videoEnd: 4, audioEnd: 4.02, now: 4)
        return logic
    }

    func testHelloStartsWithConfigBitrateInitAndFiller() {
        let logic = MirrorLogic()
        XCTAssertEqual(logic.browserOpened(now: 0), [])
        XCTAssertEqual(logic.pageHello(mse: true, now: 1),
                       [.sendConfig(lead: 1.0), .setBitrate(3_000_000), .sendInit, .sendFiller(at: 0, seconds: 4.0)])
        XCTAssertFalse(logic.isLive)
    }

    func testNoMSEFallsBack() {
        let logic = MirrorLogic()
        _ = logic.browserOpened(now: 0)
        XCTAssertEqual(logic.pageHello(mse: false, now: 1),
                       [.fallback(reason: "The TV browser cannot play this stream (no Media Source Extensions)")])
        XCTAssertEqual(logic.tick(now: 100), []) // only one fallback
    }

    func testPageThatNeverConnectsFallsBack() {
        let logic = MirrorLogic()
        _ = logic.browserOpened(now: 0)
        XCTAssertEqual(logic.tick(now: 14), [])
        XCTAssertEqual(logic.tick(now: 15), [.fallback(reason: "The TV browser did not open the page")])
    }

    func testPageThatNeverPlaysFallsBack() {
        let logic = started()
        XCTAssertEqual(logic.tick(now: 15.9), [])
        XCTAssertEqual(logic.tick(now: 16), [.fallback(reason: "The TV did not start playing")])
    }

    func testGoLive() {
        let logic = started()
        XCTAssertEqual(logic.pageGoLive(videoEnd: 4, audioEnd: 4.02, now: 4), [.goLive(videoAt: 4, audioAt: 4.02)])
        XCTAssertTrue(logic.isLive)
        XCTAssertEqual(logic.pageGoLive(videoEnd: 4, audioEnd: 4.02, now: 4.5), []) // already live
        XCTAssertEqual(logic.tick(now: 100).filter { if case .fallback = $0 { return true } else { return false } }, [])
    }

    func testErrorFallsBackOnlyBeforeTheFirstPlay() {
        XCTAssertEqual(started().pageError("code 4", now: 2), [.fallback(reason: "TV player error: code 4")])
        XCTAssertEqual(live().pageError("code 4", now: 5), [])
    }

    func testControlFailureFallsBack() {
        let logic = MirrorLogic()
        XCTAssertEqual(logic.controlFailed("TV not reachable"), [.fallback(reason: "TV not reachable")])
    }

    func testUnderrunRefillsAtBufferedEndWithMoreLeadAndLessBitrate() {
        let logic = live()
        XCTAssertEqual(logic.pageUnderrun(bufferedEnd: 20.5, now: 21),
                       [.sendConfig(lead: 1.5), .setBitrate(2_000_000), .sendFiller(at: 20.5, seconds: 4.0)])
        XCTAssertFalse(logic.isLive)
        XCTAssertEqual(logic.pageUnderrun(bufferedEnd: 21, now: 22), []) // not live: already refilling
        _ = logic.pageGoLive(videoEnd: 24.5, audioEnd: 24.5, now: 24)
        _ = logic.pageUnderrun(bufferedEnd: 30, now: 30)
        _ = logic.pageGoLive(videoEnd: 34, audioEnd: 34, now: 33)
        XCTAssertEqual(logic.pageUnderrun(bufferedEnd: 40, now: 40),
                       [.sendConfig(lead: 2.0), .sendFiller(at: 40, seconds: 4.0)]) // lead capped; bitrate at minimum
    }

    func testBitrateRampsUpWhileSmooth() {
        let logic = live()
        XCTAssertEqual(logic.tick(now: 13.9), [])
        XCTAssertEqual(logic.tick(now: 14), [.setBitrate(4_000_000)])
        XCTAssertEqual(logic.tick(now: 20), [])
        XCTAssertEqual(logic.tick(now: 24), [.setBitrate(5_000_000)])
        for t in stride(from: 34.0, through: 64.0, by: 10) { _ = logic.tick(now: t) }
        XCTAssertEqual(logic.bitrate, 8_000_000)
        XCTAssertEqual(logic.tick(now: 80), [])
    }

    func testNoRampWhileNotLive() {
        let logic = started()
        XCTAssertEqual(logic.tick(now: 12), [])
        XCTAssertEqual(logic.bitrate, 3_000_000)
    }

    func testSendBacklog() {
        let logic = live()
        XCTAssertEqual(logic.sendBacklog(seconds: 0.7, now: 10), [])      // not smooth: ramp window restarts
        XCTAssertEqual(logic.tick(now: 14), [])
        XCTAssertEqual(logic.tick(now: 20), [.setBitrate(4_000_000)])
        XCTAssertEqual(logic.sendBacklog(seconds: 1.2, now: 21), [.setBitrate(2_000_000)])
        XCTAssertEqual(logic.sendBacklog(seconds: 1.2, now: 22), [])        // already at the minimum
    }

    func testStuckRestartsTheTimelineAndReopensThePageOnTheThirdTime() {
        let logic = live()
        XCTAssertEqual(logic.pageStuck(now: 10), [.sendInit, .sendFiller(at: 0, seconds: 4.0)])
        XCTAssertEqual(logic.pageStuck(now: 20), [.sendInit, .sendFiller(at: 0, seconds: 4.0)])
        XCTAssertEqual(logic.pageStuck(now: 30), [.reopenPage])
        XCTAssertEqual(logic.pageStuck(now: 40), [.sendInit, .sendFiller(at: 0, seconds: 4.0)])
    }

    func testGoLiveResetsTheStuckCount() {
        let logic = live()
        _ = logic.pageStuck(now: 10)
        _ = logic.pageStuck(now: 20)
        _ = logic.pageGoLive(videoEnd: 4, audioEnd: 4, now: 24)
        XCTAssertEqual(logic.pageStuck(now: 30), [.sendInit, .sendFiller(at: 0, seconds: 4.0)])
    }

    func testClosedPageStopsAfterTheReconnectTime() {
        let logic = live()
        XCTAssertEqual(logic.pageClosed(now: 50), [])
        XCTAssertEqual(logic.tick(now: 59), [])
        XCTAssertEqual(logic.tick(now: 60), [.stop(reason: "The TV browser was closed")])
        XCTAssertEqual(logic.tick(now: 70), [])
    }

    func testReconnectWithinTheTimeKeepsMirroring() {
        let logic = live()
        _ = logic.pageClosed(now: 50)
        XCTAssertEqual(logic.pageHello(mse: true, now: 55),
                       [.sendConfig(lead: 1.0), .setBitrate(3_000_000), .sendInit, .sendFiller(at: 0, seconds: 4.0)])
        XCTAssertEqual(logic.tick(now: 70), [])
    }
}
