import XCTest
@testable import StrandAnalytics

/// The Connection & Sync line formatters + readout parsers (Test Centre). Pure - no clock, no BLE - so
/// fixtures pin the exact line shapes the Swift and Kotlin emitters share. Twin of the Android
/// ConnectionReadoutTest.
final class ConnectionTraceTests: XCTestCase {

    // A strap whose newest record sits before wall-now reads clockOk, with the [oldest, newest] span.
    func testClockDriftLineHealthy() {
        // 2026-06-26 12:00:00 UTC newest, oldest two days earlier, wall just after newest.
        let newest = 1_782_475_200            // 2026-06-26 12:00:00 UTC
        let oldest = newest - 2 * 86_400
        let wall = newest + 600               // wall 10 min ahead of the newest record
        let line = ConnectionTrace.clockDriftLine(oldestUnix: oldest, newestUnix: newest, wallNowUnix: wall)
        XCTAssertTrue(line.hasPrefix("clockDrift newest=2026-06-26 12:00:00 "), line)
        XCTAssertTrue(line.contains("newestVsWall=-600s"), line)
        XCTAssertTrue(line.contains("spanDays=2"), line)
        XCTAssertTrue(line.hasSuffix("clockOk"), line)
        XCTAssertFalse(line.contains("FUTURE"), line)
    }

    // A strap whose newest record is dated AHEAD of wall-now beyond the tolerance is FUTURE-DATED.
    func testClockDriftLineFutureDated() {
        let wall = 1_782_475_200
        let newest = wall + 3 * 86_400        // strap thinks it banked 3 days into the future
        let line = ConnectionTrace.clockDriftLine(oldestUnix: nil, newestUnix: newest, wallNowUnix: wall)
        XCTAssertTrue(line.contains("newestVsWall=+\(3 * 86_400)s"), line)
        XCTAssertTrue(line.contains("FUTURE-DATED"), line)
        XCTAssertFalse(line.contains("oldest="), line)   // half range reply: no lower bound
    }

    // A small skew inside the tolerance window must NOT trip the future flag.
    func testClockDriftLineWithinToleranceIsOk() {
        let wall = 1_782_475_200
        let newest = wall + 60                // 1 min ahead, inside the 120s default tolerance
        let line = ConnectionTrace.clockDriftLine(oldestUnix: nil, newestUnix: newest, wallNowUnix: wall)
        XCTAssertTrue(line.hasSuffix("clockOk"), line)
    }

    func testFirmwareLine() {
        XCTAssertEqual(ConnectionTrace.firmwareLine(version: 25, decodable: true), "firmware layout=v25 decodable")
        XCTAssertEqual(ConnectionTrace.firmwareLine(version: 30, decodable: false),
                       "firmware layout=v30 UNMAPPED (no motion/HR decoded)")
    }

    func testNoCursorLine() {
        XCTAssertEqual(ConnectionTrace.noCursorLine(),
                       "offload trim=0xFFFFFFFF noCursor (strap has no banked history to offload)")
    }

    // #990: the -363 d drift that used to print "clockOk". Beyond the 48 h behind-tolerance the line
    // must carry a clock warning naming the day count, mirroring the universal line's shared verdict.
    func testClockDriftLineFarBehindIsWarning() {
        let wall = 1_782_475_200
        let line = ConnectionTrace.clockDriftLine(oldestUnix: nil, newestUnix: wall - 363 * 86_400,
                                                  wallNowUnix: wall)
        XCTAssertTrue(line.contains("CLOCK-WARNING"), line)
        XCTAssertTrue(line.contains("363d behind wall"), line)
        XCTAssertFalse(line.contains("clockOk"), line)
    }

    func testClockDriftLineBehindWithinToleranceStaysOk() {
        let wall = 1_782_475_200
        let line = ConnectionTrace.clockDriftLine(oldestUnix: nil, newestUnix: wall - 47 * 3_600,
                                                  wallNowUnix: wall)
        XCTAssertTrue(line.hasSuffix("clockOk"), line)
    }

    // #987: an epoch-era newest (never-set RTC, ~1970/71) is the named RTC-EPOCH fault, not a generic
    // behind warning and never clockOk.
    func testClockDriftLineEpochEraReadsRtcEpoch() {
        let line = ConnectionTrace.clockDriftLine(oldestUnix: nil, newestUnix: 40_000_000,  // 1971-04
                                                  wallNowUnix: 1_782_475_200)
        XCTAssertTrue(line.contains("RTC-EPOCH"), line)
        XCTAssertFalse(line.contains("clockOk"), line)
    }
}

final class ConnectionReadoutTests: XCTestCase {

    func testUptimeLabelFromConnectMarker() {
        let tail = ["[connection] connect up gen=1 latencyMs=420 uptimeStart=1000"]
        // 3 min 12 s after the connect.
        XCTAssertEqual(ConnectionReadout.uptimeLabel(taggedTail: tail, nowUnix: 1000 + 192), "3m 12s")
    }

    func testUptimeLabelDownAfterDisconnect() {
        let tail = [
            "[connection] connect up gen=1 latencyMs=420 uptimeStart=1000",
            "[connection] connect down (uptime ends)",
        ]
        XCTAssertEqual(ConnectionReadout.uptimeLabel(taggedTail: tail, nowUnix: 5000), "not connected")
    }

    func testUptimeLabelEmptyTail() {
        XCTAssertEqual(ConnectionReadout.uptimeLabel(taggedTail: [], nowUnix: 5000), "not connected")
    }

    func testReconnectCountTakesHighest() {
        let tail = [
            "[connection] reconnect n=1 reason=connectionTimeout",
            "[connection] reconnect n=2 reason=connectionTimeout",
            "[connection] reconnect n=3 failedConnect reason=peerRemovedPairing",
        ]
        XCTAssertEqual(ConnectionReadout.reconnectCount(taggedTail: tail), 3)
    }

    func testReconnectCountZeroWhenNone() {
        XCTAssertEqual(ConnectionReadout.reconnectCount(taggedTail: ["[connection] connect up gen=1 uptimeStart=1"]), 0)
    }

    func testLastOffloadResult() {
        let tail = [
            "[connection] offload progress trim=100 chunkRows=5 sessionRows=5 sessionMotion=2 nights=1",
            "[connection] offload result=complete rows=42 nights=2",
        ]
        XCTAssertEqual(ConnectionReadout.lastOffloadResult(taggedTail: tail), "complete rows=42 nights=2")
    }

    func testLastOffloadResultStalled() {
        let tail = ["[connection] offload result=stalled (idle timeout, rows=12 so far)"]
        XCTAssertEqual(ConnectionReadout.lastOffloadResult(taggedTail: tail), "stalled (idle timeout, rows=12 so far)")
    }

    func testLastOffloadResultNilWhenNone() {
        XCTAssertNil(ConnectionReadout.lastOffloadResult(taggedTail: ["[connection] connect up gen=1 uptimeStart=1"]))
    }

    // MARK: - #990 per-session / all-time drained rows

    func testSessionRowsFromProgressLine() {
        let tail = ["[connection] offload progress trim=100 chunkRows=5 sessionRows=57 sessionMotion=2 nights=1"]
        XCTAssertEqual(ConnectionReadout.sessionRows(taggedTail: tail), 57)
    }

    func testSessionRowsResultLineWins() {
        let tail = [
            "[connection] offload progress trim=100 chunkRows=5 sessionRows=5 sessionMotion=2 nights=1",
            "[connection] offload result=complete rows=42 nights=2",
        ]
        XCTAssertEqual(ConnectionReadout.sessionRows(taggedTail: tail), 42)
    }

    func testSessionRowsEmptyResultIsZeroNotStale() {
        // An "empty" result carries no rows= field: it honestly means 0, never an older running total.
        let tail = [
            "[connection] offload progress trim=100 chunkRows=9 sessionRows=9 sessionMotion=2 nights=1",
            "[connection] offload result=empty (console only, no sensor records)",
        ]
        XCTAssertEqual(ConnectionReadout.sessionRows(taggedTail: tail), 0)
    }

    func testSessionRowsNilWhenNoOffload() {
        XCTAssertNil(ConnectionReadout.sessionRows(taggedTail: ["[connection] connect up gen=1 uptimeStart=1"]))
    }

    func testDrainedRowsFromSummary() {
        XCTAssertEqual(ConnectionReadout.drainedRowsFromSummary(
            "Backfill: session persisted 5397 rows (5211 with motion, 5211 skin-temp) across 2 night(s)."), 5_397)
        XCTAssertNil(ConnectionReadout.drainedRowsFromSummary("Backfill: session ended - reason=timeout"))
        XCTAssertNil(ConnectionReadout.drainedRowsFromSummary("session persisted garbage rows"))
    }

    // MARK: - #987 clock latch + last frame

    func testClockCorrelatedDeviceParsesNewest() {
        let lines = [
            "12:00:01  Clock correlated: device=100 wall=1782475200",
            "12:05:09  Clock correlated: device=1782475600 wall=1782475601",
        ]
        XCTAssertEqual(ConnectionReadout.clockCorrelatedDevice(logLines: lines), 1_782_475_600)
        XCTAssertNil(ConnectionReadout.clockCorrelatedDevice(logLines: ["connect up"]))
    }

    func testClockCorrelationDoesNotLeakAcrossConnectionReset() {
        let lines = [
            "Clock correlated: device=1782475600 wall=1782475601",
            "Clock correlation reset for new whoop5 connection",
        ]
        XCTAssertNil(ConnectionReadout.clockCorrelatedDevice(logLines: lines))
    }

    func testWhoop5ClockStateMarkersAreConnectionScoped() {
        let lines = [
            "Clock correlation reset for new whoop5 connection",
            "WHOOP 5/MG: clockState family=whoop5 state=setSent verification=awaiting",
            "WHOOP 5/MG: clockState family=whoop5 state=responseObserved command=147 decode=unverified",
        ]
        XCTAssertTrue(ConnectionReadout.whoop5ClockSetSent(logLines: lines))
        XCTAssertTrue(ConnectionReadout.whoop5ClockResponseObserved(logLines: lines))
        XCTAssertNil(ConnectionReadout.whoop5VerifiedClock(logLines: lines))
        XCTAssertNil(ConnectionReadout.whoop5VerifiedClockSkew(logLines: lines))

        let verified = lines + [
            "WHOOP 5/MG: clockState family=whoop5 state=verified rtc=1783668869 wall=1783668870 skewSeconds=-1 result=success",
        ]
        XCTAssertEqual(ConnectionReadout.whoop5VerifiedClock(logLines: verified), 1_783_668_869)
        XCTAssertEqual(ConnectionReadout.whoop5VerifiedClockSkew(logLines: verified), -1)
        XCTAssertFalse(ConnectionReadout.whoop5ClockResponseObserved(logLines: verified))
        XCTAssertFalse(ConnectionReadout.whoop5ClockSetSent(
            logLines: lines + ["Clock correlation reset for new whoop5 connection"]))
    }

    func testWhoop5VerifiedClockSkewParsesSignedValues() {
        let reset = "Clock correlation reset for new whoop5 connection"
        XCTAssertEqual(ConnectionReadout.whoop5VerifiedClockSkew(logLines: [
            reset,
            "clockState family=whoop5 state=verified rtc=1783668869 skewSeconds=-14 result=success",
        ]), -14)
        XCTAssertEqual(ConnectionReadout.whoop5VerifiedClockSkew(logLines: [
            reset,
            "clockState family=whoop5 state=verified rtc=1783668869 skewSeconds=0 result=success",
        ]), 0)
        XCTAssertEqual(ConnectionReadout.whoop5VerifiedClockSkew(logLines: [
            reset,
            "clockState family=whoop5 state=verified rtc=1783668869 skewSeconds=3 result=success",
        ]), 3)
    }

    func testWhoop5VerifiedClockSkewDoesNotLeakAcrossConnectionsOrMalformedNewestVerification() {
        let olderVerified =
            "clockState family=whoop5 state=verified rtc=1783668869 skewSeconds=-14 result=success"
        XCTAssertNil(ConnectionReadout.whoop5VerifiedClockSkew(logLines: [
            olderVerified,
            "Clock correlation reset for new whoop5 connection",
        ]))
        XCTAssertNil(ConnectionReadout.whoop5VerifiedClockSkew(logLines: [
            "Clock correlation reset for new whoop5 connection",
            olderVerified,
            "clockState family=whoop5 state=verified rtc=1783668872 result=success",
        ]), "the newest verified entry wins even when its skew field is unavailable")
    }

    func testWhoop5ClockStatusIsModelAwareAndHonest() {
        let wall = 1_783_664_352
        XCTAssertEqual(
            ConnectionReadout.clockStatusLabel(
                isWhoop5: true, deviceClockUnix: nil, strapNewestUnix: nil, wallNowUnix: wall,
                measuredClockSkew: nil, setSent: true, responseObserved: false),
            "SET_CLOCK sent; awaiting verification")
        XCTAssertEqual(
            ConnectionReadout.clockStatusLabel(
                isWhoop5: true, deviceClockUnix: nil, strapNewestUnix: wall - 5, wallNowUnix: wall,
                measuredClockSkew: nil, setSent: true, responseObserved: false),
            "Unix-time mapping active; records aligned with wall time")
        XCTAssertEqual(
            ConnectionReadout.clockStatusLabel(
                isWhoop5: true, deviceClockUnix: nil, strapNewestUnix: nil, wallNowUnix: wall,
                measuredClockSkew: nil, setSent: true, responseObserved: true),
            "GET_CLOCK response observed; payload format unverified")
        XCTAssertEqual(
            ConnectionReadout.clockStatusLabel(
                isWhoop5: true, deviceClockUnix: 40_000_000, strapNewestUnix: nil, wallNowUnix: wall,
                measuredClockSkew: -1, setSent: true, responseObserved: false),
            "stale RTC detected (reads 1970/71)")
        XCTAssertEqual(
            ConnectionReadout.clockStatusLabel(
                isWhoop5: true, deviceClockUnix: nil, strapNewestUnix: 40_000_000, wallNowUnix: wall,
                measuredClockSkew: nil, setSent: true, responseObserved: false),
            "stale RTC detected (reads 1970/71)")
        XCTAssertEqual(
            ConnectionReadout.clockStatusLabel(
                isWhoop5: true, deviceClockUnix: nil, strapNewestUnix: wall + 600, wallNowUnix: wall,
                measuredClockSkew: nil, setSent: true, responseObserved: false),
            "future RTC detected")
    }

    func testWhoop5VerifiedClockStatusUsesStableMeasuredSkew() {
        let first = ConnectionReadout.clockStatusLabel(
            isWhoop5: true,
            deviceClockUnix: 1_783_668_869,
            strapNewestUnix: nil,
            wallNowUnix: 1_783_668_870,
            measuredClockSkew: -1,
            setSent: true,
            responseObserved: false)
        let later = ConnectionReadout.clockStatusLabel(
            isWhoop5: true,
            deviceClockUnix: 1_783_668_869,
            strapNewestUnix: nil,
            wallNowUnix: 1_783_668_970,
            measuredClockSkew: -1,
            setSent: true,
            responseObserved: false)
        XCTAssertEqual(first, "Verified: strap RTC matched wall time (measured skew -1s)")
        XCTAssertEqual(later, first)
    }

    func testWhoop5MeasuredClockSkewThresholds() {
        let rtc = 1_783_668_869
        let wall = 1_783_668_870
        XCTAssertEqual(ConnectionReadout.clockStatusLabel(
            isWhoop5: true, deviceClockUnix: rtc, strapNewestUnix: nil, wallNowUnix: wall,
            measuredClockSkew: 121, setSent: true, responseObserved: false),
        "future RTC detected (121s ahead)")
        XCTAssertEqual(ConnectionReadout.clockStatusLabel(
            isWhoop5: true, deviceClockUnix: rtc, strapNewestUnix: nil, wallNowUnix: wall,
            measuredClockSkew: -121, setSent: true, responseObserved: false),
        "stale RTC detected (121s behind)")
        XCTAssertEqual(ConnectionReadout.clockStatusLabel(
            isWhoop5: true, deviceClockUnix: rtc, strapNewestUnix: nil, wallNowUnix: wall,
            measuredClockSkew: 3, setSent: true, responseObserved: false),
        "Verified: strap RTC matched wall time (measured skew 3s)")
    }

    func testWhoop5VerifiedClockWithoutMeasuredSkewDoesNotDrift() {
        let first = ConnectionReadout.clockStatusLabel(
            isWhoop5: true, deviceClockUnix: 1_783_668_869, strapNewestUnix: nil,
            wallNowUnix: 1_783_668_870, measuredClockSkew: nil,
            setSent: true, responseObserved: false)
        let later = ConnectionReadout.clockStatusLabel(
            isWhoop5: true, deviceClockUnix: 1_783_668_869, strapNewestUnix: nil,
            wallNowUnix: 1_783_678_870, measuredClockSkew: nil,
            setSent: true, responseObserved: false)
        XCTAssertEqual(first, "Verified: valid strap RTC response received")
        XCTAssertEqual(later, first)
    }

    func testWhoop4ClockStatusRemainsUnchanged() {
        XCTAssertEqual(ConnectionReadout.clockStatusLabel(
            isWhoop5: false, deviceClockUnix: 1_782_475_600, strapNewestUnix: 40_000_000,
            wallNowUnix: 1_900_000_000, measuredClockSkew: -999,
            setSent: true, responseObserved: true), "yes")
        XCTAssertEqual(ConnectionReadout.clockStatusLabel(
            isWhoop5: false, deviceClockUnix: nil, strapNewestUnix: nil,
            wallNowUnix: 1_900_000_000, measuredClockSkew: nil,
            setSent: false, responseObserved: false), "no (waiting for the strap clock)")
    }

    func testClockLatchedLabel() {
        XCTAssertEqual(ConnectionReadout.clockLatchedLabel(deviceClockUnix: 1_782_475_600), "yes")
        XCTAssertEqual(ConnectionReadout.clockLatchedLabel(deviceClockUnix: 40_000_000), "no (RTC reads 1970/71)")
        XCTAssertEqual(ConnectionReadout.clockLatchedLabel(deviceClockUnix: nil), "no (waiting for the strap clock)")
    }

    func testRtcWarningFiresOnEpochEraClockOrNewest() {
        XCTAssertNotNil(ConnectionReadout.rtcWarning(deviceClockUnix: 40_000_000, strapNewestUnix: nil))
        XCTAssertNotNil(ConnectionReadout.rtcWarning(deviceClockUnix: nil, strapNewestUnix: 30_000_000))
        XCTAssertNil(ConnectionReadout.rtcWarning(deviceClockUnix: 1_782_475_600, strapNewestUnix: 1_782_475_000))
        XCTAssertNil(ConnectionReadout.rtcWarning(deviceClockUnix: nil, strapNewestUnix: nil),
                     "no signal seen yet must not fabricate a fault")
    }

    func testLastFrameLabel() {
        XCTAssertEqual(ConnectionReadout.lastFrameLabel(lastFrameUnix: 990, nowUnix: 1_002), "12s ago")
        XCTAssertEqual(ConnectionReadout.lastFrameLabel(lastFrameUnix: nil, nowUnix: 1_002), "no frames yet")
    }
}
