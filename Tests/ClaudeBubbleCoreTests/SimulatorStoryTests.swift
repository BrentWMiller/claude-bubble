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
}
