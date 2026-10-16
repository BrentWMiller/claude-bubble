import simd
import XCTest
@testable import ClaudeBubbleCore

final class UsageTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func reading(left: Double, resetsIn: TimeInterval = 3600, from now: Date? = nil) -> UsageReading {
        let now = now ?? t0
        return UsageReading(usedPercent: 100 - left, resetsAt: now.addingTimeInterval(resetsIn), capturedAt: now)
    }

    // Reading

    func testDecodesWrapperJSON() throws {
        let json = #"{"used_percentage": 77.4, "resets_at": 1800003600, "captured_at": 1800000000}"#
        let r = try XCTUnwrap(UsageReading.decode(Data(json.utf8)))
        XCTAssertEqual(r.usedPercent, 77.4, accuracy: 0.001)
        XCTAssertEqual(r.resetsAt, t0.addingTimeInterval(3600))
        XCTAssertEqual(r.capturedAt, t0)
        XCTAssertNil(UsageReading.decode(Data("nope".utf8)))
        XCTAssertNil(UsageReading.decode(Data(#"{"resets_at": 1}"#.utf8)))
    }

    func testLeftClampsAndRefillsAfterReset() {
        let r = UsageReading(usedPercent: 120, resetsAt: t0.addingTimeInterval(60), capturedAt: t0)
        XCTAssertEqual(r.left(at: t0), 0)
        XCTAssertEqual(r.left(at: t0.addingTimeInterval(60)), 100)
        XCTAssertEqual(reading(left: 40).left(at: t0), 40, accuracy: 0.001)
    }

    func testLevels() {
        XCTAssertEqual(reading(left: 26).level(at: t0), .ok)
        XCTAssertEqual(reading(left: 25).level(at: t0), .low)
        XCTAssertEqual(reading(left: 10.5).level(at: t0), .low)
        XCTAssertEqual(reading(left: 10).level(at: t0), .critical)
        XCTAssertEqual(reading(left: 0).level(at: t0), .critical)
        XCTAssertEqual(reading(left: 5, resetsIn: 10).level(at: t0.addingTimeInterval(11)), .ok)
    }

    func testTimeLeft() {
        XCTAssertEqual(reading(left: 50, resetsIn: 3840).timeLeft(at: t0), 3840)
        XCTAssertEqual(reading(left: 50, resetsIn: 10).timeLeft(at: t0.addingTimeInterval(30)), 0)
    }

    // Tint

    func testTintAmounts() {
        XCTAssertEqual(UsageTint.amounts(left: 80).warm, 0)
        XCTAssertEqual(UsageTint.amounts(left: 50).warm, 0)
        XCTAssertEqual(UsageTint.amounts(left: 37.5).warm, 0.5, accuracy: 0.001)
        XCTAssertEqual(UsageTint.amounts(left: 25).warm, 1)
        XCTAssertEqual(UsageTint.amounts(left: 25).critical, 0)
        XCTAssertEqual(UsageTint.amounts(left: 12.5).critical, 0.5, accuracy: 0.001)
        XCTAssertEqual(UsageTint.amounts(left: 0).critical, 1)
    }

    func testTintMovesRimAndHaloOnly() {
        let palette = OrbPalette.agentsView
        let base = OrbParams.target(for: .working, palette: palette)
        let warm = UsageTint.apply(base, state: .working, palette: palette, warm: 1, critical: 0)
        XCTAssertLessThan(simd_distance(warm.c1, palette.needs.c1), 1e-5)
        XCTAssertLessThan(simd_distance(warm.c3, palette.needs.c3), 1e-5)
        XCTAssertLessThan(simd_distance(warm.halo, palette.needs.halo), 1e-5)
        XCTAssertEqual(warm.c2, base.c2)
        let hot = UsageTint.apply(base, state: .working, palette: palette, warm: 1, critical: 1)
        XCTAssertLessThan(simd_distance(hot.c1, palette.error.c1), 1e-5)
        XCTAssertLessThan(simd_distance(hot.halo, palette.error.halo), 1e-5)
        XCTAssertEqual(UsageTint.apply(base, state: .working, palette: palette, warm: 0, critical: 0), base)
    }

    func testTintLeavesNeedsAndErrorAlone() {
        let palette = OrbPalette.agentsView
        for state in [BubbleState.needs, .error] {
            let base = OrbParams.target(for: state, palette: palette)
            XCTAssertEqual(UsageTint.apply(base, state: state, palette: palette, warm: 1, critical: 1), base)
        }
    }

    // Alerts

    func testFirstReadingIsBaseline() {
        let alerts = UsageAlerts()
        XCTAssertEqual(alerts.update(reading(left: 8), now: t0), [])
        XCTAssertEqual(alerts.update(reading(left: 6), now: t0), [])
    }

    func testLowThenCritical() {
        let alerts = UsageAlerts()
        _ = alerts.update(reading(left: 40, resetsIn: 4320), now: t0)
        XCTAssertEqual(alerts.update(reading(left: 25, resetsIn: 4320), now: t0),
                       [UsageAlert(kind: .usageLow, text: "25% left · resets 1h 12m")])
        XCTAssertEqual(alerts.update(reading(left: 20, resetsIn: 4320), now: t0), [])
        XCTAssertEqual(alerts.update(reading(left: 9.6, resetsIn: 4320), now: t0),
                       [UsageAlert(kind: .usageCritical, text: "10% left · resets 1h 12m")])
        XCTAssertEqual(alerts.update(reading(left: 3, resetsIn: 4320), now: t0), [])
    }

    func testJumpPastBothFiresOnlyCritical() {
        let alerts = UsageAlerts()
        _ = alerts.update(reading(left: 40, resetsIn: 2280), now: t0)
        XCTAssertEqual(alerts.update(reading(left: 8, resetsIn: 2280), now: t0).map(\.kind), [.usageCritical])
    }

    func testRefreshOnlyAfterAThreshold() {
        let alerts = UsageAlerts()
        _ = alerts.update(reading(left: 60, resetsIn: 100), now: t0)
        // Next window, nothing fired in the last one: quiet.
        let later = t0.addingTimeInterval(200)
        XCTAssertEqual(alerts.update(reading(left: 90, resetsIn: 3600, from: later), now: later), [])
    }

    func testNewWindowRefreshesAndRearms() {
        let alerts = UsageAlerts()
        _ = alerts.update(reading(left: 30, resetsIn: 100), now: t0)
        XCTAssertEqual(alerts.update(reading(left: 20, resetsIn: 100), now: t0).map(\.kind), [.usageLow])
        let later = t0.addingTimeInterval(200)
        XCTAssertEqual(alerts.update(reading(left: 98, resetsIn: 18000, from: later), now: later),
                       [UsageAlert(kind: .usageRefreshed, text: "refreshed · 100% left")])
        // The new window's thresholds fire again.
        XCTAssertEqual(alerts.update(reading(left: 24, resetsIn: 18000, from: later), now: later).map(\.kind), [.usageLow])
    }

    func testRefreshFiresWhenResetPassesWithoutNewReading() {
        let alerts = UsageAlerts()
        let r1 = reading(left: 30, resetsIn: 100)
        _ = alerts.update(r1, now: t0)
        let r2 = reading(left: 5, resetsIn: 100)
        XCTAssertEqual(alerts.update(r2, now: t0).map(\.kind), [.usageCritical])
        XCTAssertEqual(alerts.update(r2, now: t0.addingTimeInterval(101)).map(\.kind), [.usageRefreshed])
        XCTAssertEqual(alerts.update(r2, now: t0.addingTimeInterval(130)), [])
        // The next real reading for the new window doesn't refresh twice.
        let later = t0.addingTimeInterval(140)
        XCTAssertEqual(alerts.update(reading(left: 99, resetsIn: 18000, from: later), now: later), [])
    }

    func testNoReadingDoesNothing() {
        let alerts = UsageAlerts()
        XCTAssertEqual(alerts.update(nil, now: t0), [])
        _ = alerts.update(reading(left: 40), now: t0)
        XCTAssertEqual(alerts.update(nil, now: t0), [])
        XCTAssertEqual(alerts.update(reading(left: 20), now: t0).map(\.kind), [.usageLow])
    }

    func testResetBaselineSuppressesCrossings() {
        let alerts = UsageAlerts()
        _ = alerts.update(reading(left: 40), now: t0)
        alerts.reset()
        XCTAssertEqual(alerts.update(reading(left: 8), now: t0), [])
    }

    // Review fixes

    func testDecodesRawStatusLineJSON() throws {
        let json = #"{"model":{"id":"x"},"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":1800003600}}}"#
        let r = try XCTUnwrap(UsageReading.decode(Data(json.utf8), capturedAt: t0))
        XCTAssertEqual(r.usedPercent, 40)
        XCTAssertEqual(r.resetsAt, t0.addingTimeInterval(3600))
        XCTAssertEqual(r.capturedAt, t0)
        XCTAssertNil(UsageReading.decode(Data(#"{"model":{"id":"x"}}"#.utf8), capturedAt: t0))
    }

    func testNoRefreshForAWindowThatNeverWarned() {
        let alerts = UsageAlerts()
        _ = alerts.update(reading(left: 8, resetsIn: 100), now: t0)   // baseline while low: silent
        XCTAssertEqual(alerts.update(reading(left: 8, resetsIn: 100), now: t0.addingTimeInterval(101)), [])
    }

    func testResetTimeJitterIsTheSameWindow() {
        let alerts = UsageAlerts()
        _ = alerts.update(reading(left: 30, resetsIn: 3600), now: t0)
        XCTAssertEqual(alerts.update(reading(left: 20, resetsIn: 3600), now: t0).map(\.kind), [.usageLow])
        XCTAssertEqual(alerts.update(reading(left: 19, resetsIn: 3601), now: t0), [], "a second of drift isn't a new window")
    }

    func testPercentAgreesWithLevel() {
        XCTAssertEqual(UsageFormat.percent(25.4), "26%")
        XCTAssertEqual(UsageFormat.percent(25), "25%")
        XCTAssertEqual(UsageFormat.percent(10.4), "11%")
        XCTAssertEqual(UsageFormat.percent(9.6), "10%")
    }
}
