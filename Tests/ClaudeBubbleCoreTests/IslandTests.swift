import XCTest
@testable import ClaudeBubbleCore

final class IslandTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func s(_ id: String, _ state: BubbleState, since: Double = 60) -> Session {
        Session(id: id, state: state, updatedAt: now, stateSince: now.addingTimeInterval(-since))
    }

    // Preferences

    func testDefaultsAndOlderSettings() throws {
        let d = BubblePreferences.defaults
        XCTAssertEqual(d.style, .orb)
        XCTAssertEqual(d.islandDock, .top)
        XCTAssertEqual(d.islandRest, .live)
        XCTAssertEqual(d.islandGlow, .waves)
        let old = try JSONDecoder().decode(BubblePreferences.self, from: Data(#"{"toasts": false, "islandDock": "sideways"}"#.utf8))
        XCTAssertEqual(old.style, .orb)
        XCTAssertEqual(old.islandDock, .top, "an unknown value takes the default")
    }

    // Modes

    func testRestByDefault() {
        XCTAssertEqual(IslandMode.choose(sessions: [s("a", .working)], now: now, hovering: false, doneAt: nil), .rest)
        XCTAssertEqual(IslandMode.choose(sessions: [], now: now, hovering: false, doneAt: nil), .rest)
    }

    func testPriority() {
        let all = [s("w", .working), s("n", .needs), s("e", .error, since: 1)]
        XCTAssertEqual(IslandMode.choose(sessions: all, now: now, hovering: true, doneAt: now), .hover)
        XCTAssertEqual(IslandMode.choose(sessions: all, now: now, hovering: false, doneAt: now), .needs("n"))
        XCTAssertEqual(IslandMode.choose(sessions: [s("w", .working), s("e", .error, since: 1)], now: now, hovering: false, doneAt: now),
                       .error("e"))
        XCTAssertEqual(IslandMode.choose(sessions: [s("w", .idle)], now: now, hovering: false, doneAt: now.addingTimeInterval(-1)), .done)
    }

    func testErrorShowsForThreeAndAHalfSeconds() {
        XCTAssertEqual(IslandMode.choose(sessions: [s("e", .error, since: 3.4)], now: now, hovering: false, doneAt: nil), .error("e"))
        XCTAssertEqual(IslandMode.choose(sessions: [s("e", .error, since: 3.6)], now: now, hovering: false, doneAt: nil), .rest)
    }

    func testDoneShowsForFourAndAHalfSeconds() {
        XCTAssertEqual(IslandMode.choose(sessions: [], now: now, hovering: false, doneAt: now.addingTimeInterval(-4.4)), .done)
        XCTAssertEqual(IslandMode.choose(sessions: [], now: now, hovering: false, doneAt: now.addingTimeInterval(-4.6)), .rest)
    }

    func testNeedsPicksTheMostRecent() {
        let mode = IslandMode.choose(sessions: [s("old", .needs, since: 90), s("new", .needs, since: 5)], now: now,
                                     hovering: false, doneAt: nil)
        XCTAssertEqual(mode, .needs("new"))
    }

    // Sizes

    func testSizes() {
        func size(_ m: IslandMode, _ d: IslandDock = .top, _ r: IslandRest = .live, pips: Int = 3, rows: Int = 3) -> CGSize {
            IslandLayout.size(mode: m, dock: d, rest: r, pips: pips, rows: rows)
        }
        XCTAssertEqual(size(.rest), CGSize(width: 290, height: 40))
        XCTAssertEqual(size(.rest, .bottom, .compact), CGSize(width: 130, height: 40))
        XCTAssertEqual(size(.needs("a")), CGSize(width: 360, height: 94))
        XCTAssertEqual(size(.error("a"), .left), CGSize(width: 360, height: 94), "side docks go horizontal when not resting")
        XCTAssertEqual(size(.done), CGSize(width: 300, height: 40))
        XCTAssertEqual(size(.hover, rows: 3), CGSize(width: 350, height: 42 + 51 * 3 + 34 + 10))
        XCTAssertEqual(size(.hover, rows: 0).height, 42 + 51 + 34 + 10, "at least one row")
    }

    func testSideRestIsAVerticalCapsule() {
        XCTAssertEqual(IslandLayout.size(mode: .rest, dock: .right, rest: .live, pips: 0, rows: 0), CGSize(width: 44, height: 48))
        XCTAssertEqual(IslandLayout.size(mode: .rest, dock: .left, rest: .live, pips: 1, rows: 0), CGSize(width: 44, height: 63))
        XCTAssertEqual(IslandLayout.size(mode: .rest, dock: .left, rest: .compact, pips: 7, rows: 0),
                       CGSize(width: 44, height: 8 + 28 + 10 + 25 + 16 + 12), "capped at five pips")
    }

    // Placement

    let visible = CGRect(x: 0, y: 50, width: 1512, height: 900)   // menu bar above, Dock below

    func testWindowHugsTheDockedEdge() {
        let w = IslandLayout.windowSize
        XCTAssertEqual(IslandLayout.windowFrame(dock: .top, visible: visible),
                       CGRect(x: 756 - w.width / 2, y: 950 - w.height, width: w.width, height: w.height))
        XCTAssertEqual(IslandLayout.windowFrame(dock: .bottom, visible: visible).minY, 50)
        XCTAssertEqual(IslandLayout.windowFrame(dock: .left, visible: visible).minX, 0)
        XCTAssertEqual(IslandLayout.windowFrame(dock: .left, visible: visible).midY, 500)
        XCTAssertEqual(IslandLayout.windowFrame(dock: .right, visible: visible).maxX, 1512)
    }

    func testPillSitsOnTheDockedEdge() {
        let size = CGSize(width: 290, height: 44)
        for dock in IslandDock.allCases {
            let win = IslandLayout.windowFrame(dock: dock, visible: visible)
            let pill = IslandLayout.pillRect(size: size, dock: dock, window: win)
            XCTAssertEqual(pill.size, size)
            switch dock {
            case .top: XCTAssertEqual(pill.maxY, win.maxY); XCTAssertEqual(pill.midX, win.midX)
            case .bottom: XCTAssertEqual(pill.minY, win.minY); XCTAssertEqual(pill.midX, win.midX)
            case .left: XCTAssertEqual(pill.minX, win.minX); XCTAssertEqual(pill.midY, win.midY)
            case .right: XCTAssertEqual(pill.maxX, win.maxX); XCTAssertEqual(pill.midY, win.midY)
            }
        }
    }

    func testToastsHangOffTheOpenSide() {
        let size = CGSize(width: 320, height: 230)
        func place(_ dock: IslandDock) -> ToastLayout.Placement {
            let win = IslandLayout.windowFrame(dock: dock, visible: visible)
            let pill = IslandLayout.pillRect(size: CGSize(width: 290, height: 44), dock: dock, window: win)
            return ToastLayout.placeIsland(pill: pill, dock: dock, size: size, visible: visible)
        }
        let top = place(.top)
        XCTAssertEqual(top.frame.maxY, 950 - 44 - 12, "(placed against a 44pt test pill)")
        XCTAssertEqual(top.frame.midX, 756)
        XCTAssertFalse(top.flipped)
        let bottom = place(.bottom)
        XCTAssertEqual(bottom.frame.minY, 50 + 44 + 12)
        XCTAssertTrue(bottom.flipped)
        let left = place(.left)
        XCTAssertEqual(left.align, .leading)
        XCTAssertEqual(left.frame.minX, 0)
        XCTAssertEqual(place(.right).align, .trailing)
        for dock in IslandDock.allCases { XCTAssertTrue(visible.contains(place(dock).frame), "\(dock)") }
    }

    func testHoverListFitsTheWindow() {
        XCTAssertEqual(IslandLayout.shownRows(4), 4)
        XCTAssertEqual(IslandLayout.shownRows(IslandLayout.maxRows + 3), IslandLayout.maxRows)
        let big = IslandLayout.size(mode: .hover, dock: .top, rest: .live, pips: 12, rows: 12)
        XCTAssertEqual(big.height, 42 + 51 * CGFloat(IslandLayout.maxRows) + IslandLayout.moreHeight + 34 + 10)
        XCTAssertLessThanOrEqual(big.height, IslandLayout.windowSize.height)
        XCTAssertEqual(IslandLayout.size(mode: .hover, dock: .top, rest: .live, pips: 2, rows: 2, footer: false).height, 42 + 51 * 2 + 6 + 10)
    }
}
