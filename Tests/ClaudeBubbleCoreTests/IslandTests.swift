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

    func testANeedsCardWithApprovalGrows() {
        let plain = IslandLayout.size(mode: .needs("a"), dock: .top, rest: .live, pips: 1, rows: 1)
        let asking = IslandLayout.size(mode: .needs("a"), dock: .top, rest: .live, pips: 1, rows: 1, approval: 100)
        XCTAssertEqual(plain.height, 94)
        XCTAssertEqual(asking.height, 40 + IslandLayout.approvalChrome + 100)
        XCTAssertEqual(IslandLayout.size(mode: .error("a"), dock: .top, rest: .live, pips: 1, rows: 1, approval: 100).height,
                       94, "only needs-you asks")
        let hover = IslandLayout.size(mode: .hover, dock: .top, rest: .live, pips: 1, rows: 1)
        XCTAssertEqual(IslandLayout.size(mode: .hover, dock: .top, rest: .live, pips: 1, rows: 1, approval: 100).height,
                       hover.height + 108, "a row's card")
    }

    func testWidthScalesEveryHorizontalShape() {
        func size(_ m: IslandMode, _ d: IslandDock = .top, _ r: IslandRest = .live, width: CGFloat) -> CGSize {
            IslandLayout.size(mode: m, dock: d, rest: r, pips: 3, rows: 3, width: width)
        }
        XCTAssertEqual(size(.rest, width: 1.5), CGSize(width: 435, height: 40))
        XCTAssertEqual(size(.rest, .top, .compact, width: 0.8), CGSize(width: 104, height: 40))
        XCTAssertEqual(size(.hover, width: 1.2).width, 420)
        XCTAssertEqual(size(.needs("a"), width: 1.2).width, 432)
        XCTAssertEqual(size(.done, width: 1.2).width, 360)
        XCTAssertEqual(size(.rest, .left, width: 1.5), size(.rest, .left, width: 1), "the side capsule is just the orb's column")
        XCTAssertEqual(size(.tucked, width: 1.5), size(.tucked, width: 1))
        XCTAssertEqual(size(.quiet, width: 1.5), size(.quiet, width: 1))
    }

    func testTheWindowFitsTheWidestIsland() {
        let widest = IslandLayout.size(mode: .needs("a"), dock: .top, rest: .live, pips: 0, rows: 0, width: IslandLayout.maxWidth)
        XCTAssertGreaterThanOrEqual(IslandLayout.windowSize.width, widest.width + 40, "room for the shadow")
    }

    func testSideRestIsAVerticalCapsule() {
        XCTAssertEqual(IslandLayout.size(mode: .rest, dock: .right, rest: .live, pips: 0, rows: 0), CGSize(width: 44, height: 48))
        XCTAssertEqual(IslandLayout.size(mode: .rest, dock: .left, rest: .live, pips: 1, rows: 0), CGSize(width: 44, height: 63))
        XCTAssertEqual(IslandLayout.size(mode: .rest, dock: .left, rest: .compact, pips: 7, rows: 0),
                       CGSize(width: 44, height: 8 + 28 + 10 + 25 + 16 + 12), "capped at five pips")
    }

    // Tucked: the circle the orb morphs into and out of

    func testTuckedIsACircleAroundTheOrb() {
        XCTAssertEqual(IslandLayout.size(mode: .tucked, dock: .top, rest: .live, pips: 3, rows: 3), CGSize(width: 48, height: 40))
        XCTAssertEqual(IslandLayout.size(mode: .tucked, dock: .bottom, rest: .compact, pips: 0, rows: 0), CGSize(width: 48, height: 40))
        XCTAssertEqual(IslandLayout.size(mode: .tucked, dock: .left, rest: .live, pips: 5, rows: 5), CGSize(width: 44, height: 44))
    }

    func testTuckedOrbCentre() {
        let w = CGRect(x: 100, y: 200, width: 440, height: 600)
        XCTAssertEqual(IslandLayout.tuckedOrbCentre(dock: .top, window: w), CGPoint(x: 320, y: 800 - 4 - 14))
        XCTAssertEqual(IslandLayout.tuckedOrbCentre(dock: .bottom, window: w), CGPoint(x: 320, y: 200 + 4 + 14))
        XCTAssertEqual(IslandLayout.tuckedOrbCentre(dock: .left, window: w), CGPoint(x: 100 + 22, y: 500))
        XCTAssertEqual(IslandLayout.tuckedOrbCentre(dock: .right, window: w), CGPoint(x: 540 - 22, y: 500))
    }

    func testChooseNeverTucks() {
        XCTAssertNotEqual(IslandMode.choose(sessions: [], now: now, hovering: false, doneAt: nil), .tucked)
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

    // Dragging around the edges

    func testNearestEdgeAndPositionAlongIt() {
        // visible = (0, 50, 1512 × 900)
        XCTAssertEqual(IslandLayout.nearest(CGPoint(x: 300, y: 930), visible: visible).dock, .top)
        XCTAssertEqual(IslandLayout.nearest(CGPoint(x: 300, y: 930), visible: visible).along, 300.0 / 1512, accuracy: 1e-6)
        XCTAssertEqual(IslandLayout.nearest(CGPoint(x: 1500, y: 500), visible: visible).dock, .right)
        XCTAssertEqual(IslandLayout.nearest(CGPoint(x: 1500, y: 500), visible: visible).along, 0.5, accuracy: 1e-6)
        XCTAssertEqual(IslandLayout.nearest(CGPoint(x: 10, y: 600), visible: visible).dock, .left)
        XCTAssertEqual(IslandLayout.nearest(CGPoint(x: 700, y: 60), visible: visible).dock, .bottom)
        // Off the screen still picks an edge, clamped along it.
        let off = IslandLayout.nearest(CGPoint(x: -400, y: 5000), visible: visible)
        XCTAssertTrue(off.along >= 0 && off.along <= 1)
    }

    func testWindowSlidesAlongItsEdgeButStaysOnScreen() {
        let w = IslandLayout.windowSize
        let mid = IslandLayout.windowFrame(dock: .top, visible: visible, along: 0.25)
        XCTAssertEqual(mid.midX, 1512 * 0.25, accuracy: 0.01)
        XCTAssertEqual(mid.maxY, 950)
        XCTAssertEqual(IslandLayout.windowFrame(dock: .top, visible: visible, along: 0).minX, 0, "clear of the corner")
        XCTAssertEqual(IslandLayout.windowFrame(dock: .bottom, visible: visible, along: 1).maxX, 1512)
        XCTAssertEqual(IslandLayout.windowFrame(dock: .left, visible: visible, along: 0.9).midY, 50 + 900 * 0.9 > 950 - w.height / 2
                       ? 950 - w.height / 2 : 50 + 900 * 0.9, accuracy: 0.01)
        XCTAssertEqual(IslandLayout.windowFrame(dock: .right, visible: visible, along: 0).minY, 50)
        XCTAssertEqual(IslandLayout.windowFrame(dock: .top, visible: visible), IslandLayout.windowFrame(dock: .top, visible: visible, along: 0.5))
    }

    func testAlongIsSavedAndDefaultsToTheMiddle() throws {
        XCTAssertEqual(BubblePreferences.defaults.islandAlong, 0.5)
        var p = BubblePreferences.defaults
        p.islandAlong = 0.2
        let back = try JSONDecoder().decode(BubblePreferences.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.islandAlong, 0.2)
        let old = try JSONDecoder().decode(BubblePreferences.self, from: Data(#"{"islandDock": "left"}"#.utf8))
        XCTAssertEqual(old.islandAlong, 0.5)
        XCTAssertEqual(try JSONDecoder().decode(BubblePreferences.self, from: Data(#"{"islandAlong": 7}"#.utf8)).clamped().islandAlong, 1, "clamped")
    }

    // The top edge: under a menu bar that's showing, else the screen's top

    func testTopIsUnderAShowingMenuBarElseTheScreenTop() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let bar = CGRect(x: 0, y: 1084, width: 1728, height: 33)
        XCTAssertEqual(IslandLayout.top(of: screen, menuBars: [bar]), 1084)
        XCTAssertEqual(IslandLayout.top(of: screen, menuBars: []), 1117, "full screen or auto-hidden: right to the top")
        let other = CGRect(x: 891, y: 2167, width: 1920, height: 30)   // another display's bar
        XCTAssertEqual(IslandLayout.top(of: screen, menuBars: [other]), 1117)
    }

    func testMenuBarFromWindowServerBounds() {
        // Window-server bounds are top-left based; the main display is 1117pt tall.
        XCTAssertEqual(IslandLayout.cocoaRect(fromWindowBounds: CGRect(x: 891, y: -1080, width: 1920, height: 30), mainHeight: 1117),
                       CGRect(x: 891, y: 2167, width: 1920, height: 30))
    }

    func testWindowLeavesRoomForTheShadow() {
        XCTAssertGreaterThanOrEqual(IslandLayout.windowSize.width - 360, 2 * 30, "the widest pill plus shadow room")
        // The tallest panel: every shown row with link chips, "+N more" and the footer.
        let tallest = IslandLayout.size(mode: .hover, dock: .top, rest: .live, pips: 9, rows: 9, linked: IslandLayout.maxRows)
        XCTAssertGreaterThanOrEqual(IslandLayout.windowSize.height, tallest.height + 30)
    }

    func testANeighbouringDisplaysMenuBarDoesntCount() {
        // Two displays side by side: the right one's menu bar starts exactly where the left one ends.
        let left = CGRect(x: -1029, y: 1117, width: 1920, height: 1080)
        let rightBar = CGRect(x: 891, y: 2167, width: 1920, height: 30)
        XCTAssertEqual(IslandLayout.top(of: left, menuBars: [rightBar]), left.maxY)
    }

    func testRowsWithLinksAreTaller() {
        let plain = IslandLayout.size(mode: .hover, dock: .top, rest: .live, pips: 3, rows: 3)
        XCTAssertEqual(IslandLayout.size(mode: .hover, dock: .top, rest: .live, pips: 3, rows: 3, linked: 2).height,
                       plain.height + 2 * IslandLayout.linkRowHeight)
        let pr = SessionLink(kind: .pr, label: "#1", url: URL(string: "https://github.com/o/r/pull/1")!)
        var a = s("a", .working), b = s("b", .idle)
        a.links = [pr]
        b.links = []
        XCTAssertEqual(IslandLayout.linkedRows([a, b]), 1)
    }
}
