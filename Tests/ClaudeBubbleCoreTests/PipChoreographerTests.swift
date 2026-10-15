import XCTest
@testable import ClaudeBubbleCore

final class PipChoreographerTests: XCTestCase {
    func ins(_ pairs: [(String, BubbleState)]) -> [PipInput] { pairs.map { PipInput(id: $0.0, state: $0.1) } }
    func slots(_ f: PipsFrame) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: f.pips.compactMap { p in p.slot.map { (p.id, $0) } })
    }
    func pip(_ f: PipsFrame, _ id: String) -> PipFrame { f.pips.first { $0.id == id }! }

    // Order
    func testOrderedByUrgencyThenFirstSeen() {
        let c = PipChoreographer()
        _ = c.update(ins([("a", .working), ("b", .needs), ("c", .error), ("d", .idle), ("e", .working)]), now: 0)
        XCTAssertEqual(slots(c.frame(now: 1)), ["b": 0, "c": 1, "a": 2, "e": 3, "d": 4])
    }

    func testOverflowCollapsesIntoPlusN() {
        let c = PipChoreographer()
        _ = c.update((0..<9).map { PipInput(id: "s\($0)", state: .working) }, now: 0)
        let f = c.frame(now: 1)
        XCTAssertEqual(f.slots, 7)
        XCTAssertEqual(f.overflow, 3)
        XCTAssertEqual(f.pips.filter { $0.slot != nil }.count, 6)
        XCTAssertNil(pip(f, "s8").slot)
    }

    func testPipsShowOnlyWithTwoOrMoreSessions() {
        let c = PipChoreographer()
        _ = c.update(ins([("a", .working)]), now: 0)
        XCTAssertFalse(c.frame(now: 1).visible)
        _ = c.update(ins([("a", .working), ("b", .working)]), now: 1)
        XCTAssertTrue(c.frame(now: 2).visible)
    }

    // Spawn, hop, shake
    func testNewPipsArePulledOutThenSnapOff() {
        let c = PipChoreographer()
        _ = c.update(ins([("a", .working)]), now: 0)
        XCTAssertEqual(c.update(ins([("a", .working), ("b", .working)]), now: 1), [.spawned("b")])
        let pulling = pip(c.frame(now: 1.1), "b")
        XCTAssertTrue(pulling.pulling, "hidden while the orb's rim stretches toward its slot")
        XCTAssertFalse(pulling.snapping)
        let snap = pip(c.frame(now: 1.34), "b")
        XCTAssertTrue(snap.snapping, "pinches off as a stretched droplet")
        XCTAssertFalse(snap.pulling)
        let settled = pip(c.frame(now: 1.45), "b")
        XCTAssertFalse(settled.pulling || settled.snapping, "then springs round into its slot")
    }

    func testFinishingAndSpawningInOneUpdateReportBoth() {
        let c = PipChoreographer()
        _ = c.update(ins([("a", .working), ("b", .working)]), now: 0)
        XCTAssertEqual(c.update(ins([("a", .idle), ("b", .working), ("c", .working)]), now: 1), [.ringPop, .spawned("c")])
    }

    func testNeedsHopsTwice() {
        let c = PipChoreographer()
        _ = c.update(ins([("a", .working), ("b", .working)]), now: 0)
        _ = c.update(ins([("a", .working), ("b", .needs)]), now: 10)
        XCTAssertEqual([10.05, 10.25, 10.45, 10.65].map { pip(c.frame(now: $0), "b").hopping }, [true, false, true, false])
        XCTAssertEqual(slots(c.frame(now: 10.1))["b"], 0, "slides to the front")
    }

    func testErrorShakes() {
        let c = PipChoreographer()
        _ = c.update(ins([("a", .working), ("b", .working)]), now: 0)
        _ = c.update(ins([("a", .working), ("b", .error)]), now: 5)
        XCTAssertEqual([5.01, 5.06, 5.12, 5.5].map { pip(c.frame(now: $0), "b").shake }, [5, -5, 4, 0])
    }

    // Finishing
    func testFinishedPipFlaresThenRetiresToTheEnd() {
        let c = PipChoreographer()
        _ = c.update(ins([("a", .working), ("b", .working), ("c", .working)]), now: 0)
        _ = c.update(ins([("a", .idle), ("b", .working), ("c", .working)]), now: 10)
        let during = c.frame(now: 10.3)
        XCTAssertTrue(pip(during, "a").flaring)
        XCTAssertEqual(slots(during)["a"], 0, "holds its place while flaring")
        let after = c.frame(now: 10.7)
        XCTAssertFalse(pip(after, "a").flaring)
        XCTAssertEqual(slots(after)["a"], 2, "then moves to the end")
    }

    func testFinishingWhileOthersWorkPopsTheRing() {
        let c = PipChoreographer()
        _ = c.update(ins([("a", .working), ("b", .working)]), now: 0)
        XCTAssertEqual(c.update(ins([("a", .idle), ("b", .working)]), now: 1), [.ringPop])
    }

    func testTheLastToFinishMergesInsteadOfPopping() {
        let c = PipChoreographer()
        _ = c.update(ins([("a", .idle), ("b", .working)]), now: 0)
        XCTAssertEqual(c.update(ins([("a", .idle), ("b", .idle)]), now: 5), [], "no ring pop: the merge celebrates")
        XCTAssertFalse(c.frame(now: 5.5).merged)
        let merged = c.frame(now: 5.95)
        XCTAssertTrue(merged.merged)
        XCTAssertTrue(merged.pips.allSatisfy(\.atCenter))
    }

    func testNewActivityUnmerges() {
        let c = PipChoreographer()
        _ = c.update(ins([("a", .idle), ("b", .working)]), now: 0)
        _ = c.update(ins([("a", .idle), ("b", .idle)]), now: 1)
        XCTAssertTrue(c.frame(now: 2).merged)
        _ = c.update(ins([("a", .working), ("b", .idle)]), now: 3)
        XCTAssertFalse(c.frame(now: 3.1).merged)
    }

    func testReturningToWorkCancelsTheRetire() {
        let c = PipChoreographer()
        _ = c.update(ins([("a", .working), ("b", .working), ("c", .working)]), now: 0)
        _ = c.update(ins([("a", .idle), ("b", .working), ("c", .working)]), now: 10)
        _ = c.update(ins([("a", .working), ("b", .working), ("c", .working)]), now: 10.3)
        let f = c.frame(now: 11)
        XCTAssertFalse(pip(f, "a").flaring)
        XCTAssertEqual(slots(f)["a"], 0, "no leftover retire")
        XCTAssertFalse(f.merged)
    }

    func testEverythingFinishingCelebratesOnceAtTheMerge() {
        let c = PipChoreographer()
        _ = c.update(ins([("a", .idle), ("b", .working)]), now: 0)
        _ = c.update(ins([("a", .idle), ("b", .idle)]), now: 5)
        XCTAssertEqual(c.update(ins([("a", .idle), ("b", .idle)]), now: 5.5), [], "not yet")
        XCTAssertEqual(c.update(ins([("a", .idle), ("b", .idle)]), now: 5.95), [.allDone], "at the merge")
        XCTAssertEqual(c.update(ins([("a", .idle), ("b", .idle)]), now: 7), [], "once")
    }

    func testFinishingFromNeedsOrErrorCelebratesToo() {
        let c = PipChoreographer()
        _ = c.update(ins([("a", .idle), ("b", .needs)]), now: 0)
        _ = c.update(ins([("a", .idle), ("b", .idle)]), now: 1)
        XCTAssertEqual(c.update(ins([("a", .idle), ("b", .idle)]), now: 2), [.allDone])
    }

    func testSessionsThatArriveFinishedMergeQuietly() {
        // Launching, or switching to/from the simulator, with everything already done is not a finish.
        let c = PipChoreographer()
        _ = c.update(ins([("a", .idle), ("b", .idle)]), now: 0)
        XCTAssertEqual(c.update(ins([("a", .idle), ("b", .idle)]), now: 2), [])
        XCTAssertTrue(c.frame(now: 2).merged)
    }

    func testEverythingDisappearingIsNotAFinish() {
        let c = PipChoreographer()
        _ = c.update(ins([("a", .working), ("b", .working)]), now: 0)
        _ = c.update([], now: 1)   // e.g. the simulator opened with no sessions
        XCTAssertEqual(c.update([], now: 3), [])
    }

    func testRemovingTheLastActiveDuringFinishMergesCleanly() {
        let c = PipChoreographer()
        _ = c.update(ins([("a", .idle), ("b", .working), ("c", .working)]), now: 0)
        XCTAssertEqual(c.update(ins([("a", .idle), ("b", .idle)]), now: 1), [], "c left and b finished: nothing else is active")
        XCTAssertTrue(c.frame(now: 2).merged)
    }

    // Arc and hit testing
    func testArcCentresUnderTheOrb() {
        let centre = CGPoint(x: 60, y: 60)
        let mid = PipArc.position(slot: 1, slots: 3, centre: centre, radius: 46)
        XCTAssertEqual(mid.x, 60, accuracy: 0.001)
        XCTAssertEqual(mid.y, 106, accuracy: 0.001, "straight down in view space")
        XCTAssertLessThan(PipArc.position(slot: 0, slots: 3, centre: centre, radius: 46).x, 60, "first slot on the left")
    }

    func testHitTestFindsAVisiblePip() {
        let c = PipChoreographer()
        _ = c.update(ins([("a", .working), ("b", .working)]), now: 0)
        let f = c.frame(now: 1)
        let centre = CGPoint(x: 60, y: 60)
        let at = PipArc.position(slot: 1, slots: 2, centre: centre, radius: 46)
        XCTAssertEqual(PipArc.hit(CGPoint(x: at.x + 3, y: at.y), frame: f, centre: centre, radius: 46), "b")
        XCTAssertNil(PipArc.hit(CGPoint(x: 0, y: 0), frame: f, centre: centre, radius: 46))
    }

    func testHitPicksTheNearestPipAtSmallSizes() {
        // Small quick pick: side 80, arc radius ≈ 30.7, pips under 6pt apart.
        let c = PipChoreographer()
        _ = c.update((0..<5).map { PipInput(id: "s\($0)", state: .working) }, now: 0)
        let f = c.frame(now: 1)
        let centre = CGPoint(x: 40, y: 40)
        let radius: CGFloat = 80 * 0.3 * PipArc.radiusScale
        for slot in 0..<5 {
            let p = PipArc.position(slot: slot, slots: 5, centre: centre, radius: radius)
            XCTAssertEqual(PipArc.hit(p, frame: f, centre: centre, radius: radius), "s\(slot)")
        }
    }

    func testHiddenPipsAreNotHittable() {
        let c = PipChoreographer()
        _ = c.update((0..<9).map { PipInput(id: "s\($0)", state: .working) }, now: 0)
        let f = c.frame(now: 1)
        let centre = CGPoint(x: 60, y: 60)
        let plusN = PipArc.position(slot: 6, slots: 7, centre: centre, radius: 46)
        XCTAssertNil(PipArc.hit(plusN, frame: f, centre: centre, radius: 46), "the +N slot isn't a session")
    }

    func testMergedPipsAreNotHittable() {
        let c = PipChoreographer()
        _ = c.update(ins([("a", .idle), ("b", .idle)]), now: 0)
        let f = c.frame(now: 2)
        XCTAssertTrue(f.merged)
        let centre = CGPoint(x: 60, y: 60)
        XCTAssertNil(PipArc.hit(PipArc.position(slot: 0, slots: 2, centre: centre, radius: 46), frame: f, centre: centre, radius: 46))
    }
}
