import XCTest
@testable import ClaudeBubbleCore

final class SimulatorStoryTests: XCTestCase {
    func testStepsMatchTheDesignTimeline() {
        XCTAssertEqual(SimulatorStory.steps.map(\.at), [0.3, 1.2, 2.1, 3.0, 4.0, 6.0, 8.0, 9.0, 10.4, 12.2, 14.0])
    }

    func testReplayEndsWithEverythingDone() {
        let end = SimulatorStory.replay(until: 20)
        XCTAssertEqual(end.map(\.name), ["Billing: CSV Import", "AI Bubble", "Docs: Getting Started"])
        XCTAssertEqual(end.map(\.state), [.idle, .idle, .idle])
    }

    func testStoryVisitsEveryInterestingState() {
        let states = stride(from: 0.0, through: 14.0, by: 0.1).flatMap { SimulatorStory.replay(until: $0).map(\.state) }
        XCTAssertTrue(states.contains(.needs))
        XCTAssertTrue(states.contains(.error))
        XCTAssertEqual(SimulatorStory.replay(until: 4.5).map(\.state), [.working, .needs, .working])
    }

    func testNamePoolAndStatusLines() {
        XCTAssertEqual(SimulatorStory.namePool.count, 10)
        XCTAssertEqual(SimulatorStory.detail(for: .needs), "Approve edit to auth.ts?")
        XCTAssertEqual(SimulatorStory.detail(for: .error), "Build failed · exit 1")
        XCTAssertEqual(SimulatorStory.detail(for: .working), "Running tests")
        XCTAssertEqual(SimulatorStory.detail(for: .idle), "Completed")
    }

    func testScriptedSessionShowsEverything() {
        let steps = SimulatorStory.session
        XCTAssertEqual(steps.first?.motion, .generating)
        XCTAssertEqual(steps.last?.state, .idle, "ends finished")
        XCTAssertEqual(Set(steps.map(\.motion)), Set(Motion.allCases), "every motion plays")
        XCTAssertTrue(steps.contains { $0.state == .needs })
        XCTAssertTrue(steps.contains { $0.state == .error })
        XCTAssertEqual(steps.filter(\.skill).count, 1)
        XCTAssertEqual(steps.compactMap(\.endsPrevious).filter { $0 == .failed }.count, 1, "the first test run fails")
        XCTAssertEqual(steps.first { $0.motion == .waiting }?.subagents, 3)
        // Usage runs down past both thresholds, then the window resets.
        let usage = steps.compactMap(\.usageLeft)
        XCTAssertEqual(usage, usage.sorted(by: >))
        XCTAssertTrue(usage.contains { $0 <= 25 && $0 > 10 })
        XCTAssertTrue(usage.contains { $0 <= 10 })
        let resetAt = steps.firstIndex(where: \.resetsUsage)
        XCTAssertNotNil(resetAt)
        XCTAssertGreaterThan(resetAt!, steps.lastIndex { $0.usageLeft != nil }!)
    }
}
