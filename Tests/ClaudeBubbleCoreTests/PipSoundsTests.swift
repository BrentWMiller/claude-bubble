import XCTest
@testable import ClaudeBubbleCore

final class PipSoundsTests: XCTestCase {
    func frame(_ ids: [String], merged: Bool = false) -> PipsFrame {
        PipsFrame(pips: ids.enumerated().map { PipFrame(id: $0.element, state: .working, slot: $0.offset, rank: $0.offset,
                                                        atCenter: merged, pulling: false, snapping: false,
                                                        flaring: false, hopping: false, shake: 0) },
                  slots: ids.count, overflow: 0, merged: merged, visible: ids.count >= 2)
    }

    // Notes and placement
    func testEachSlotOwnsAPentatonicNote() {
        XCTAssertEqual((0..<7).map(PipSounds.note(slot:)), [64, 67, 69, 72, 74, 76, 79])
        XCTAssertEqual(PipSounds.note(slot: 12), 79, "overflow shares the last note")
    }

    func testPanFollowsTheArc() {
        XCTAssertLessThan(PipSounds.pan(slot: 0, slots: 7), -0.5, "first slot is on the left")
        XCTAssertEqual(PipSounds.pan(slot: 3, slots: 7), 0, accuracy: 0.001)
        XCTAssertGreaterThan(PipSounds.pan(slot: 6, slots: 7), 0.5)
    }

    // Events → sounds
    func testEventsBecomeCuesAtTheirPipsPitch() {
        let now = frame(["a", "b", "c"])
        let cues = PipSounds.requests(for: [.spawned("c"), .needs("a"), .finished("b"), .error("b")], frame: now, previous: now)
        XCTAssertEqual(cues.map(\.cue), [.spawn, .needs, .finish, .error])
        XCTAssertEqual(cues.map(\.note), [69, 64, 67, 67])
    }

    func testRetireSlidesTowardTheEndOfTheRow() {
        let now = frame(["a", "b", "c"])
        let slide = PipSounds.requests(for: [.retired("a")], frame: now, previous: now).first
        XCTAssertEqual(slide?.cue, .slide)
        XCTAssertGreaterThan(slide?.endPan ?? -1, slide?.pan ?? 1, "glides right, toward the end")
    }

    func testAllDonePlaysEveryPipsNote() {
        let merged = frame(["a", "b", "c"], merged: true)
        let chord = PipSounds.requests(for: [.allDone], frame: merged, previous: merged).first
        XCTAssertEqual(chord?.cue, .merge)
        XCTAssertEqual(chord?.chord, [64, 67, 69])
    }

    func testRemovedPipsUseWhereTheyWere() {
        let before = frame(["a", "b"]), after = frame(["a"])   // b has left
        XCTAssertEqual(PipSounds.requests(for: [.removed("b")], frame: after, previous: before).first?.note, 67)
    }

    func testRingPopIsSilentByItself() {
        let now = frame(["a", "b"])
        XCTAssertEqual(PipSounds.requests(for: [.ringPop], frame: now, previous: now), [], "the finish sound covers it")
    }

    // Rate limiting
    func testRepeatsAreRateLimited() {
        var limiter = SoundRateLimiter()
        XCTAssertTrue(limiter.allow(.spawn, now: 0))
        XCTAssertFalse(limiter.allow(.spawn, now: 0.05))
        XCTAssertTrue(limiter.allow(.needs, now: 0.05), "other sounds are separate")
        XCTAssertTrue(limiter.allow(.spawn, now: 0.08))
        XCTAssertTrue(limiter.allow(.hover, now: 1))
        XCTAssertFalse(limiter.allow(.hover, now: 1.1), "hover waits a little longer")
    }

    // Synthesis
    func testEveryCueRendersAudibleCleanAudio() {
        for cue in PipSounds.Cue.allCases {
            let r = SoundRequest(cue: cue, note: 72, pan: 0, endPan: 0.5, chord: [64, 67, 69])
            let out = PipSynth.render(r, sampleRate: 44_100)
            XCTAssertGreaterThan(out.left.count, 4410, "\(cue) lasts at least 0.1s")
            XCTAssertEqual(out.left.count, out.right.count)
            let peak = (out.left + out.right).map(abs).max() ?? 0
            XCTAssertGreaterThan(peak, 0.002, "\(cue) is audible")
            XCTAssertLessThan(peak, 1, "\(cue) never clips")
            XCTAssertTrue((out.left + out.right).allSatisfy(\.isFinite), "\(cue) has no NaNs")
        }
    }

    func testPanMovesTheSoundAcross() {
        let left = PipSynth.render(SoundRequest(cue: .finish, note: 72, pan: -0.9), sampleRate: 44_100)
        let energy = { (s: [Float]) in s.reduce(0) { $0 + $1 * $1 } }
        XCTAssertGreaterThan(energy(left.left), energy(left.right) * 2)
    }
}
