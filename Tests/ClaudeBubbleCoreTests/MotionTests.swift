import XCTest
@testable import ClaudeBubbleCore

final class MotionTests: XCTestCase {
    // Tool → motion

    func testToolsMapToMotions() {
        XCTAssertEqual(Motion.forTool("Read"), .read)
        XCTAssertEqual(Motion.forTool("Grep"), .search)
        XCTAssertEqual(Motion.forTool("Glob"), .search)
        XCTAssertEqual(Motion.forTool("Edit"), .edit)
        XCTAssertEqual(Motion.forTool("Write"), .edit)
        XCTAssertEqual(Motion.forTool("MultiEdit"), .edit)
        XCTAssertEqual(Motion.forTool("Bash"), .bash)
        XCTAssertEqual(Motion.forTool("WebFetch"), .web)
        XCTAssertEqual(Motion.forTool("WebSearch"), .web)
        XCTAssertEqual(Motion.forTool("mcp__notion__search"), .mcp)
        XCTAssertEqual(Motion.forTool("Agent"), .waiting)
        XCTAssertEqual(Motion.forTool("Task"), .waiting)
        XCTAssertEqual(Motion.forTool("TodoWrite"), .generating)
        XCTAssertEqual(Motion.forTool(""), .generating)
    }

    func testShaderModesMatchTheDesign() {
        XCTAssertEqual(Motion.allCases.map(\.shaderMode), [0, 17, 12, 2, 26, 9, 23, 24, 25])
    }

    // Director

    func testStartsSettledOnGenerating() {
        let d = MotionDirector()
        let f = d.frame(now: 0)
        XCTAssertEqual(f.to, .generating)
        XCTAssertEqual(f.mix, 1)
    }

    func testBlendsOverOnePointSixSeconds() {
        let d = MotionDirector()
        d.update(want: .read, now: 1)
        XCTAssertEqual(d.frame(now: 1).from, .generating)
        XCTAssertEqual(d.frame(now: 1).to, .read)
        XCTAssertEqual(d.frame(now: 1.8).mix, 0.5, accuracy: 0.01, "smoothstep midpoint")
        XCTAssertEqual(d.frame(now: 2.6).mix, 1)
    }

    func testHoldsAtLeastHalfASecond() {
        let d = MotionDirector()
        d.update(want: .read, now: 0)
        d.update(want: .edit, now: 0.3)   // too soon, and mid-blend
        XCTAssertEqual(d.frame(now: 0.3).to, .read)
    }

    func testSwitchMidBlendWaitsForTheBlend() {
        let d = MotionDirector()
        d.update(want: .read, now: 0)
        d.update(want: .edit, now: 1.0)   // held long enough, but still blending
        XCTAssertEqual(d.frame(now: 1.0).to, .read)
        d.update(want: .edit, now: 1.6)
        let f = d.frame(now: 1.6)
        XCTAssertEqual(f.from, .read)
        XCTAssertEqual(f.to, .edit)
        XCTAssertEqual(f.mix, 0)
    }

    func testOnlyLatestTargetIsKept() {
        let d = MotionDirector()
        var t = 0.0
        for want in [Motion.read, .search, .read, .edit, .read, .search, .bash] {
            d.update(want: want, now: t)
            t += 0.1
        }
        // Keep asking for bash until things settle.
        while t < 10 { d.update(want: .bash, now: t); t += 0.1 }
        let f = d.frame(now: t)
        XCTAssertEqual(f.to, .bash)
        XCTAssertEqual(f.mix, 1)
    }

    func testSameTargetDoesNothing() {
        let d = MotionDirector()
        d.update(want: .generating, now: 5)
        XCTAssertEqual(d.frame(now: 5).mix, 1)
    }

    // Layer tracker

    func counts(_ id: String, _ t: Int, _ f: Int = 0, _ s: Int = 0) -> LayerCounts {
        LayerCounts(id: id, ticks: t, fails: f, skills: s)
    }

    func testFirstSightBaselines() {
        let tracker = LayerTracker()
        XCTAssertEqual(tracker.update([counts("a", 120, 4, 2)], focus: "a"), LayerEvents())
        XCTAssertEqual(tracker.update([counts("a", 122, 5, 2)], focus: "a"), LayerEvents(ticks: 2, fails: 1, skills: 0))
    }

    func testOnlyTheFocusFires() {
        let tracker = LayerTracker()
        _ = tracker.update([counts("a", 1), counts("b", 1)], focus: "a")
        XCTAssertEqual(tracker.update([counts("a", 1), counts("b", 5)], focus: "a"), LayerEvents())
    }

    func testFocusSwitchDoesNotReplay() {
        let tracker = LayerTracker()
        _ = tracker.update([counts("a", 1), counts("b", 1)], focus: "a")
        _ = tracker.update([counts("a", 1), counts("b", 9)], focus: "a")
        XCTAssertEqual(tracker.update([counts("a", 1), counts("b", 9)], focus: "b"), LayerEvents())
        XCTAssertEqual(tracker.update([counts("a", 1), counts("b", 10)], focus: "b"), LayerEvents(ticks: 1))
    }

    func testCounterGoingDownRebaselines() {
        let tracker = LayerTracker()
        _ = tracker.update([counts("a", 50)], focus: "a")
        XCTAssertEqual(tracker.update([counts("a", 0)], focus: "a"), LayerEvents(), "a restarted session")
        XCTAssertEqual(tracker.update([counts("a", 1)], focus: "a"), LayerEvents(ticks: 1))
    }
}
