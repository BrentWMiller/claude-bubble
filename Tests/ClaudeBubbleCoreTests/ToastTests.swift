import XCTest
@testable import ClaudeBubbleCore

final class ToastTests: XCTestCase {
    func pip(_ id: String, _ state: BubbleState, _ slot: Int) -> PipFrame {
        PipFrame(id: id, state: state, slot: slot, rank: slot, atCenter: false, pulling: false, snapping: false,
                 flaring: false, hopping: false, shake: 0)
    }

    // Events → toasts
    func testEventsBecomeToasts() {
        let before = PipsFrame(pips: [pip("a", .needs, 0), pip("b", .idle, 1), pip("c", .working, 2)], slots: 3, overflow: 0,
                               merged: false, visible: true)
        let names = ["a": "AI Bubble", "b": "docs", "c": "infra", "d": "billing"]
        let toasts = ToastQueue.toasts(for: [.spawned("d"), .needs("c"), .error("c"), .finished("c"), .resumed("a"), .resumed("b")],
                                       previous: before, names: names)
        XCTAssertEqual(toasts.map(\.kind), [.started, .needs, .error, .finished, .resumed],
                       "resuming from needs counts; resuming a finished session doesn't")
        XCTAssertEqual(toasts.map(\.name), ["billing", "infra", "infra", "infra", "AI Bubble"])
    }

    func testKinds() {
        XCTAssertEqual(ToastKind.needs.text, "needs you")
        XCTAssertEqual(ToastKind.error.text, "hit an error")
        XCTAssertEqual(ToastKind.resumed.text, "back to work")
        XCTAssertEqual(ToastKind.allDone.text, "complete")
        XCTAssertEqual(ToastKind.review.text, "ready for review")
        XCTAssertEqual(ToastKind.allCases.map(\.lifetime), [4, 8, 8, 6, 8, 3.5, 6, 6, 8, 6, 8, 8])
        XCTAssertEqual(ToastKind.update.text, "is available")
    }

    // Lifetimes
    func testToastsExpireThenLeave() {
        let q = ToastQueue()
        q.push(.finished, name: "docs", now: 0)
        q.tick(now: 5.9, hovering: false)
        XCTAssertTrue(q.items.first!.showing)
        q.tick(now: 6.1, hovering: false)
        XCTAssertFalse(q.items.first!.showing, "leaving")
        q.tick(now: 6.9, hovering: false)
        XCTAssertTrue(q.items.isEmpty, "gone after the exit animation")
    }

    func testHoverPausesTheCountdown() {
        let q = ToastQueue()
        q.push(.started, name: "a", now: 0)
        q.tick(now: 2, hovering: false)
        q.tick(now: 10, hovering: true)   // 8s spent hovering
        q.tick(now: 11, hovering: false)
        XCTAssertTrue(q.items.first!.showing, "only 3s of its 4s have counted")
        q.tick(now: 12.1, hovering: false)
        XCTAssertFalse(q.items.first!.showing)
    }

    func testAtMostFiveShow() {
        let q = ToastQueue()
        for i in 0..<6 { q.push(.started, name: "s\(i)", now: Double(i) * 0.1) }
        let showing = q.items.filter(\.showing).map(\.name)
        XCTAssertEqual(showing.count, 5)
        XCTAssertFalse(showing.contains("s0"), "the oldest makes room")
    }

    // Layout
    func testCollapsedStackTucksOlderToastsBehind() {
        let q = ToastQueue()
        for i in 0..<4 { q.push(.started, name: "s\(i)", now: Double(i)) }
        let layout = q.layout(expanded: false)
        let newest = layout.first { $0.name == "s3" }!, second = layout.first { $0.name == "s2" }!
        let fourth = layout.first { $0.name == "s0" }!
        XCTAssertEqual(newest.top, 6); XCTAssertEqual(newest.scale, 1); XCTAssertEqual(newest.opacity, 1); XCTAssertEqual(newest.blur, 0)
        XCTAssertEqual(second.top, 13); XCTAssertEqual(second.scale, 0.945, accuracy: 0.001)
        XCTAssertEqual(second.opacity, 0.7, accuracy: 0.001); XCTAssertEqual(second.blur, 1.2, accuracy: 0.001)
        XCTAssertEqual(fourth.opacity, 0, "only three peek out")
        XCTAssertGreaterThan(newest.z, second.z)
        XCTAssertEqual(q.stackHeight(expanded: false), 40 + 14)
    }

    func testHoverFansTheStackOut() {
        let q = ToastQueue()
        for i in 0..<3 { q.push(.started, name: "s\(i)", now: Double(i)) }
        let layout = q.layout(expanded: true)
        XCTAssertEqual(layout.first { $0.name == "s2" }!.top, 6)
        XCTAssertEqual(layout.first { $0.name == "s0" }!.top, 86)
        XCTAssertTrue(layout.allSatisfy { $0.opacity == 1 && $0.blur == 0 && $0.scale == 1 })
        XCTAssertEqual(q.stackHeight(expanded: true), 126)
        XCTAssertEqual(ToastQueue().stackHeight(expanded: false), 0)
    }

    // Decode
    func testDecodeScramblesThenResolvesLeftToRight() {
        let s = "needs you"
        let start = ToastDecode.text(s, progress: 0, seed: 1, tick: 0)
        XCTAssertEqual(start.count, s.count)
        XCTAssertTrue(zip(start, s).allSatisfy { $0 == " " ? $1 == " " : ToastDecode.glyphs.contains($0) }, "all glyphs, spaces kept")
        XCTAssertEqual(ToastDecode.text(s, progress: 1, seed: 1, tick: 0), s)
        let mid = Array(ToastDecode.text(s, progress: 0.45, seed: 1, tick: 0))
        XCTAssertEqual(mid.first, "n", "the start resolves first")
        XCTAssertTrue(ToastDecode.glyphs.contains(mid.last!), "the end is still scrambled")
    }

    func testToastPullIsGentle() {
        let a = OrbAnimator(state: .working)
        a.pull(towards: [0, -1], amplitude: 0.32)
        let peak = (0..<19).map { _ in a.step(dt: 1.0 / 60).pull }.max() ?? 0
        XCTAssertEqual(peak, 0.32, accuracy: 0.02)
    }

    func testToastsAreOnByDefault() throws {
        XCTAssertTrue(BubblePreferences.defaults.toasts)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(BubblePreferences.defaults)) as? [String: Any])
        json.removeValue(forKey: "toasts")
        XCTAssertTrue(try JSONDecoder().decode(BubblePreferences.self, from: JSONSerialization.data(withJSONObject: json)).toasts)
    }

    func testSuccessGreenIsTheDesignsMint() {
        XCTAssertEqual(OrbAnimator.doneGreen.c1, [0.74, 1, 0.84])
        XCTAssertEqual(OrbAnimator.doneGreen.halo, [0.1, 0.3, 0.18])
    }

    func testFinishingWithAPullRequestAnnouncesReview() {
        let before = PipsFrame(pips: [pip("a", .working, 0)], slots: 1, overflow: 0, merged: false, visible: false)
        let toasts = ToastQueue.toasts(for: [.finished("a"), .reviewReady("b")], previous: before,
                                       names: ["a": "Billing: CSV Import", "b": "docs"], reviews: ["a", "b"])
        XCTAssertEqual(toasts.map(\.kind), [.review, .review])
    }

    func testTextOverrideShowsInPlacement() {
        let q = ToastQueue()
        q.push(.usageLow, name: "Usage", text: "25% left · resets 1h 12m", now: 0)
        q.push(.finished, name: "a", now: 0.1)
        let byKind = Dictionary(uniqueKeysWithValues: q.layout(expanded: false).map { ($0.kind, $0.text) })
        XCTAssertEqual(byKind[.usageLow], "25% left · resets 1h 12m")
        XCTAssertEqual(byKind[.finished], "finished")
    }

    // Placement: centred under the orb, moved to the opposite side of whatever would be cut off

    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let size = CGSize(width: 320, height: 230)
    func orb(_ cx: CGFloat, _ cy: CGFloat) -> CGRect { CGRect(x: cx - 60, y: cy - 60, width: 120, height: 120) }

    func testOpenSpaceSitsCentredBelow() {
        let p = ToastLayout.place(orb: orb(500, 500), size: size, visible: screen)
        XCTAssertEqual(p.frame.midX, 500)
        XCTAssertEqual(p.frame.maxY, 500 - 120 * 0.3 * 1.49, accuracy: 0.01)
        XCTAssertFalse(p.flipped)
        XCTAssertEqual(p.align, .center)
        XCTAssertEqual(p.pull, SIMD2(0, -1))
    }

    func testCutOffBelowGoesAbove() {
        let p = ToastLayout.place(orb: orb(500, 20), size: size, visible: screen)
        XCTAssertTrue(p.flipped)
        XCTAssertGreaterThan(p.frame.minY, 20)
        XCTAssertEqual(p.pull, SIMD2(0, 1))
    }

    func testCutOffRightGoesLeftLevelWithTheOrb() {
        let p = ToastLayout.place(orb: orb(1010, 400), size: size, visible: screen)   // hanging off the right
        XCTAssertEqual(p.align, .trailing, "hugs the orb's side")
        XCTAssertEqual(p.frame.maxX, 1010 - 120 * 0.3 * 1.28 - 12, accuracy: 0.01)
        XCTAssertEqual(p.frame.maxY - 6 - 15, 400, accuracy: 0.01, "first toast centred on the orb")
        XCTAssertFalse(p.flipped)
        XCTAssertEqual(p.pull, SIMD2(-1, 0))
    }

    func testCutOffLeftGoesRight() {
        let p = ToastLayout.place(orb: orb(-10, 400), size: size, visible: screen)
        XCTAssertEqual(p.align, .leading)
        XCTAssertEqual(p.frame.minX, -10 + 120 * 0.3 * 1.28 + 12, accuracy: 0.01)
        XCTAssertEqual(p.pull, SIMD2(1, 0))
    }

    func testAlwaysInsideTheScreen() {
        for (cx, cy) in [(-10.0, 400.0), (500, -10), (1010, -10), (990, 790), (150, 400), (1010, 790)] {
            let p = ToastLayout.place(orb: orb(cx, cy), size: size, visible: screen)
            XCTAssertTrue(screen.insetBy(dx: -0.01, dy: -0.01).contains(p.frame), "\(cx),\(cy)")
        }
    }
}
