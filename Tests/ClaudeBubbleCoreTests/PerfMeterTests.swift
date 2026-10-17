import XCTest
@testable import ClaudeBubbleCore

final class PerfMeterTests: XCTestCase {
    func testStats() {
        let s = PerfStats(samples: (1...100).map(Double.init))
        XCTAssertEqual(s.count, 100)
        XCTAssertEqual(s.average, 50.5, accuracy: 0.001)
        XCTAssertEqual(s.p95, 95)
        XCTAssertEqual(s.max, 100)
        XCTAssertEqual(PerfStats(samples: []).count, 0)
        XCTAssertEqual(PerfStats(samples: []).max, 0)
    }

    func testRecordsOnlyWhileOn() {
        let meter = PerfMeter()
        _ = meter.measure(.sync) { 1 }
        meter.count(.orbFrame)
        XCTAssertEqual(meter.report().sections[.sync]?.count ?? 0, 0)
        meter.recording = true
        XCTAssertEqual(meter.measure(.sync) { 42 }, 42)
        meter.count(.orbFrame, 3)
        let r = meter.report()
        XCTAssertEqual(r.sections[.sync]?.count, 1)
        XCTAssertGreaterThan(r.rates[.orbFrame] ?? 0, 0)
    }

    func testKeepsOnlyTheWindow() {
        let meter = PerfMeter(window: 5)
        meter.recording = true
        let t0 = Date(timeIntervalSince1970: 1000)
        meter.record(.sync, seconds: 0.010, at: t0)
        meter.record(.sync, seconds: 0.002, at: t0.addingTimeInterval(4))
        meter.count(.event, 10, at: t0)
        meter.count(.event, 5, at: t0.addingTimeInterval(4))
        let r = meter.report(now: t0.addingTimeInterval(7))
        XCTAssertEqual(r.sections[.sync]?.count, 1)
        XCTAssertEqual(r.sections[.sync]?.max ?? 0, 0.002, accuracy: 1e-9)
        XCTAssertEqual(r.rates[.event] ?? 0, 1, accuracy: 0.001, "5 events in the 5s window")
    }

    func testReportText() {
        let meter = PerfMeter()
        meter.recording = true
        meter.record(.sync, seconds: 0.004)
        let text = meter.report().text
        XCTAssertTrue(text.contains("sync"))
        XCTAssertTrue(text.contains("4.0ms"))
    }
}
