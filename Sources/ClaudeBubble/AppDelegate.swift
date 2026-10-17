import AppKit
import Combine
import ClaudeBubbleCore
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = SettingsModel()
    private lazy var animator = OrbAnimator(palette: settings.prefs.palette)
    private var applied = BubblePreferences.defaults
    private var settingsSubscription: AnyCancellable?
    private var lastTodayRefresh: CFTimeInterval = 0
    private var hoverToasts = false
    /// Re-anchors the list once a drag settles.
    private var settleList: DispatchWorkItem?
    /// True while the orb is popping out of one display and into another.
    private var swappingDisplays = false
    private var panel: BubblePanel!
    private var statusItem: NSStatusItem!
    private var watcher: SessionWatcher!
    private let model = SessionsModel()
    private var listPanel: SessionListPanel!
    private var hover = HoverTracker()
    private var hoverTimer: Timer?
    private var liveState: BubbleState = .idle
    /// What the session watcher last reported; the simulator can stand in for it.
    private var watchedState: BubbleState = .idle
    private var watchedSessions: [Session] = []
    private let simulator = SimulatorModel()
    private var simulatorWindow: SimulatorWindowController?
    private var setupWindow: SetupWindowController?
    private var simulatorSubscription: AnyCancellable?
    private let choreographer = PipChoreographer()
    private var pipCard: PipCardPanel!
    private let sounds = SoundPlayer()
    private let toasts = ToastQueue()
    private let toastModel = ToastModel()
    private var toastPanel: ToastPanel!
    private var soundLimiter = SoundRateLimiter()
    private let layerTracker = LayerTracker()
    private let edgeLight = EdgeLightController()
    private let linkScanner = LinkScanner()
    private let prStatus = PRStatusFetcher()
    private var island: IslandPanel!
    /// The all-done moment, for the island's "All sessions complete".
    private var islandDoneAt: Date?
    private var isIsland: Bool { applied.style == .island }
    /// While the island is being dragged: the edge and spot it's snapping to (saved on release).
    private var islandDrag: (dock: IslandDock, along: Double)?
    /// Quiet mode (a Focus, a screen share, or the toggle): the bubble shrinks to a dot and toasts wait.
    private var quiet = false
    private var heldToasts: [HeldToast] = []
    /// When the focus session's current motion began (bash settles with it).
    private var motionSince: Date?
    private let usageAlerts = UsageAlerts()
    /// What the status line wrapper last saved; re-read every 5s.
    private var realUsage: UsageReading?
    private var usageTimer: Timer?
    /// Which reading the alerts are following (real or simulated); switching re-baselines them.
    private var usageFromSimulator = false
    /// No sounds for the burst of pips that appear at launch.
    private let launchedAt = CACurrentMediaTime()
    private var forcedState: BubbleState?
    private let toggleItem = NSMenuItem(title: "", action: #selector(toggleBubble), keyEquivalent: "")
    private var debugItems: [NSMenuItem] = []
    /// The Colors/Size/Opacity/Follow items in the menu-bar menu; rebuilt each time it opens.
    private var quickItems: [NSMenuItem] = []
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    private var bubbleHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "bubbleHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "bubbleHidden") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Find gh now, off the main thread (it may ask the login shell), before anything needs it.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard PRStatusFetcher.resolveGH() != nil else { return }
            DispatchQueue.main.async { self?.syncSessions() }   // fetch PR status now that we can
        }
        applied = settings.prefs
        model.palette = applied.palette
        animator.interaction = applied.interaction
        sounds.enabled = applied.sounds && !quiet
        panel = BubblePanel(animator: animator, model: model, diameter: applied.diameter)
        panel.alphaValue = applied.opacity
        panel.onClick = { [weak self] in self?.focusTerminal() }
        panel.onUserMoved = { [weak self] _ in self?.rememberSpot() }
        panel.onRightClick = { [weak self] event, view in self?.showOrbMenu(with: event, in: view) }
        settings.currentSpot = { [weak self] in self?.currentSpot() }
        // @Published fires before storing; apply on the next run-loop turn so reads and writes see the new value.
        settingsSubscription = settings.$prefs.dropFirst().receive(on: RunLoop.main).sink { [weak self] prefs in self?.apply(prefs) }
        listPanel = SessionListPanel(model: model) { [weak self] in
            self?.focusTerminal()
            self?.hover.dismiss()
            self?.listPanel.popOut()
        }
        startHoverTracking()
        listPanel.bubble = panel
        toastPanel = ToastPanel(model: toastModel)
        toastPanel.bubble = panel
        island = IslandPanel(animator: animator, sessions: model)
        island.onClick = { [weak self] in
            self?.focusTerminal()
            self?.hover.dismiss()
        }
        island.onRightClick = { [weak self] event, view in self?.showOrbMenu(with: event, in: view) }
        island.onDragMoved = { [weak self] point in self?.dragIsland(to: point) }
        island.onDragEnded = { [weak self] in self?.endIslandDrag() }
        applyIslandOptions(applied)
        linkScanner.onChange = { [weak self] in self?.syncSessions() }
        prStatus.onChange = { [weak self] in self?.syncSessions() }
        toastModel.palette = applied.palette
        // The list is a child window of the orb, so a drag moves both together. Once the orb stops moving,
        // re-anchor it (it may need to flip above/below or come back on screen).
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.pipCard.isVisible { self.pipCard.hide() }
            self.settleList?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.listPanel.follow(self.panel.frame)
            }
            self.settleList = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        refreshInstalledHook()
        setUpStatusItem()
        showSetupOnFirstLaunch()
        pipCard = PipCardPanel(model: model)
        watcher = SessionWatcher(directory: SessionStore.defaultDirectory) { [weak self] state, sessions in
            self?.watchedState = state
            self?.watchedSessions = sessions
            self?.syncSessions()
        }
        // DispatchQueue (not RunLoop.main) so a dragged slider updates live, even in event-tracking mode.
        simulatorSubscription = simulator.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in self?.syncSessions() }
        setQuiet(applied.quiet)   // once the panels exist
        watcher.start()
        startUsagePolling()
        updateVisibility()
        applyState()
        appearOrb()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Remember where the user ⌘-drags it, so restarts don't put it back at the far left (where a crowded,
        // notched menu bar hides it first).
        statusItem.autosaveName = "ClaudeBubble"
        let menu = NSMenu()
        toggleItem.target = self
        menu.addItem(toggleItem)
        quickItems = makeQuickSettingsItems()
        quickItems.forEach(menu.addItem)
        menu.addItem(.separator())
        let settingsItem = item("Settings…", #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(item("Reset Position", #selector(resetPosition)))
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        menu.addItem(item("Restart", #selector(restart)))
        menu.delegate = self
        menu.addItem(.separator())
        menu.addItem(item("Setup…", #selector(openSetup)))
        menu.addItem(.separator())

        let debug = NSMenu()
        for (title, key) in [("Live", "live"), ("Idle", "idle"), ("Working", "working"), ("Needs You", "needs"), ("Error", "error")] {
            let it = item(title, #selector(setDebugState(_:)))
            it.representedObject = key
            debug.addItem(it)
            debugItems.append(it)
        }
        debug.addItem(.separator())
        debug.addItem(item("Session Simulator…", #selector(openSimulator)))
        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugItem.submenu = debug
        menu.addItem(debugItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Bubble", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusMenu = menu
        // The icon opens the same panel as right-clicking the bubble (or, while hidden, a click brings it back).
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }

    /// Real sessions, or the simulator's while its window is open.
    private func syncSessions() {
        if simulator.isOpen {
            let sims = simulator.asSessions
            model.sessions = sims
            liveState = SessionStore.aggregate(sims)
        } else {
            // Issue chips come from the branch name and the conversation (found in the background).
            // PR chips carry live status (checks, review, merged), which also clears "Ready for review" once merged.
            model.sessions = PRStatus.apply(prStatus.statuses, to: linkScanner.apply(to: watchedSessions))
            linkScanner.refresh(watchedSessions)
            prStatus.refresh(model.sessions)
            liveState = watchedState
        }
        applyState()
        updateMotion()
        refreshUsage()
    }

    /// Turns the pip arc around the orb so every pip stays on screen, easing the shortest way round.
    private func turnPips() {
        let frame = panel.frame
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        guard let visible = BubblePanel.screen(nearest: centre)?.visibleFrame else { return }
        let radius = frame.width * 0.3 * PipArc.radiusScale
        let target = PipArc.around(centre: centre, radius: radius, slots: max(model.pips.slots, 2), visible: visible)
        let current = model.pipAround
        let diff = (target - current + 540).truncatingRemainder(dividingBy: 360) - 180
        guard abs(diff) > 0.05 else { return }
        let next = abs(diff) < 0.5 ? target : current + diff * (1 - exp(-0.05 / 0.12))
        // The easing here is the animation: the pips' own springs would lag behind (and the hit test with them).
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { model.pipAround = (next + 360).truncatingRemainder(dividingBy: 360) }
    }

    /// The orb's motion follows the most recently changed working session; layers fire when its counters go up.
    private func updateMotion() {
        let focus = SessionStore.motionFocus(model.sessions)
        let activity = focus?.activity ?? SessionActivity()
        animator.motion = activity.motion
        animator.subagents = activity.subagents
        motionSince = focus == nil ? nil : activity.since
        let counts = model.sessions.map {
            LayerCounts(id: $0.id, ticks: $0.activity.ticks, fails: $0.activity.fails, skills: $0.activity.skills)
        }
        let events = layerTracker.update(counts, focus: focus?.id)
        for _ in 0..<min(events.ticks, 3) { animator.tick() }
        if isIsland, events.ticks > 0, let island { island.model.ticks.append(CACurrentMediaTime()) }
        if events.fails > 0 { animator.fail() }
        if events.skills > 0 { animator.skill() }
    }

    /// Hovering a pip previews that session's state on the orb (previews never celebrate).
    private var hoveredState: BubbleState? {
        guard let id = model.hoveredPip, !model.pips.merged else { return nil }
        return model.sessions.first { $0.id == id }?.state
    }

    /// What the orb shows. Never celebrates by itself: that's the pips' all-done merge (or Debug).
    private func applyState() {
        let state = forcedState ?? hoveredState ?? liveState
        animator.setState(state)
        // The menu-bar icon tracks the real (or forced) state, not a hover preview.
        statusItem.button?.image = bubbleHidden ? Self.hiddenImage : Self.statusImage(for: forcedState ?? liveState, palette: applied.palette)
        statusItem.button?.toolTip = bubbleHidden ? "Claude Bubble is hidden — click to show it" : nil
        let selected = forcedState?.rawValue ?? "live"
        for it in debugItems { it.state = (it.representedObject as? String) == selected ? .on : .off }
    }

    /// Shows the orb or the island (whichever the style is), or neither while hidden. Only one renders the orb.
    private func updateVisibility() {
        let showOrb = !bubbleHidden && !isIsland, showIsland = !bubbleHidden && isIsland
        if showOrb { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        panel.setRendering(showOrb)
        if let island {
            if showIsland {
                island.setFrame(islandWindowFrame(mouse: NSEvent.mouseLocation), display: false)   // in place before it shows
                island.orderFrontRegardless()
            } else {
                island.orderOut(nil)
            }
            island.setRendering(showIsland)
        }
        // Toasts hang from whichever is showing.
        let parent: NSWindow = isIsland ? island : panel
        if toastPanel.bubble !== parent {
            toastPanel.orderOut(nil)
            toastPanel.bubble = parent
        }
        if isIsland {
            if listPanel.isShown { listPanel.popOut() }
            if pipCard.isVisible { pipCard.hide() }
        }
        if !bubbleHidden { hiddenUntil = nil }
        toggleItem.title = bubbleHidden ? "Show Bubble" : "Hide Bubble"
        // While hidden, a click on the menu-bar icon brings the bubble straight back (right-click still opens the menu).
        if statusItem != nil { applyState() }   // the icon shows the hidden state
    }

    /// The display the island lives on: the pointer's with Follow the Pointer, else the main one.
    private func islandScreen(mouse: CGPoint) -> NSScreen? {
        (applied.followPointer ? BubblePanel.screen(nearest: mouse) : nil) ?? NSScreen.screens.first
    }

    /// The island's window: on its edge and spot (the dragged ones while dragging).
    private func islandWindowFrame(mouse: CGPoint) -> CGRect {
        let dock = islandDrag?.dock ?? applied.islandDock, along = islandDrag?.along ?? applied.islandAlong
        return IslandLayout.windowFrame(dock: dock, visible: islandScreen(mouse: mouse).map(islandArea) ?? island.frame, along: along)
    }

    private var menuBars: [CGRect] = []
    private var menuBarsCheckedAt: CFTimeInterval = 0

    /// The menu bars showing right now (re-checked twice a second). macOS reports the menu bar's space as taken even
    /// when it's hidden (a full-screen app, auto-hide), and not at all on some secondary displays, so look at the bars.
    private func visibleMenuBars() -> [CGRect] {
        let now = CACurrentMediaTime()
        guard now - menuBarsCheckedAt > 0.5 else { return menuBars }
        menuBarsCheckedAt = now
        let level = Int(CGWindowLevelForKey(.mainMenuWindow))
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        menuBars = windows.compactMap { w in
            guard w[kCGWindowLayer as String] as? Int == level,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
            return IslandLayout.cocoaRect(fromWindowBounds: bounds, mainHeight: mainHeight)
        }
        return menuBars
    }

    /// Where the island can sit on a screen: the visible frame (clear of the Dock), up to just under the menu bar
    /// while it's showing, or the very top when it isn't.
    private func islandArea(_ screen: NSScreen) -> CGRect {
        var v = screen.visibleFrame
        v.size.height = IslandLayout.top(of: screen.frame, menuBars: visibleMenuBars()) - v.minY
        return v
    }

    /// Dragging: snap to the edge nearest the pointer and slide along it, reshaping for that edge as it goes.
    private func dragIsland(to point: CGPoint) {
        guard let visible = islandScreen(mouse: point).map(islandArea) else { return }
        let target = IslandLayout.nearest(point, visible: visible)
        islandDrag = target
        hover.dismiss()
        if island.model.mode == .hover { island.model.mode = .rest }
        if island.model.dock != target.dock { island.model.dock = target.dock }
        let frame = islandWindowFrame(mouse: point)
        if island.frame != frame { island.setFrame(frame, display: true) }
    }

    private func endIslandDrag() {
        guard let target = islandDrag else { return }
        islandDrag = nil
        settings.prefs.islandDock = target.dock
        settings.prefs.islandAlong = target.along
    }

    private func applyIslandOptions(_ prefs: BubblePreferences) {
        island.alphaValue = prefs.opacity
        let m = island.model
        if m.dock != prefs.islandDock { m.dock = prefs.islandDock }
        if m.rest != prefs.islandRest { m.rest = prefs.islandRest }
        if m.glow != prefs.islandGlow { m.glow = prefs.islandGlow }
    }

    /// Places the island on its display and picks its mode: hover, needs, error, done or rest.
    private func updateIsland(mouse: CGPoint) {
        guard !bubbleHidden else { return }
        let window = islandWindowFrame(mouse: mouse)
        if island.frame != window, !island.isSwapping {
            // Onto another display: fade across. Same display (a dock or menu-bar change): just place it.
            let screenOf = { (r: CGRect) in NSScreen.screens.first { $0.frame.contains(CGPoint(x: r.midX, y: r.midY)) } }
            if island.isVisible, islandDrag == nil, let from = screenOf(island.frame), let to = screenOf(window), from != to {
                island.swap(to: window, dock: applied.islandDock, opacity: applied.opacity)
            } else {
                island.setFrame(window, display: true)
            }
        }
        let m = island.model
        func pill(_ mode: IslandMode) -> CGRect {
            IslandLayout.pillRect(size: IslandLayout.size(mode: mode, dock: m.dock, rest: m.rest, pips: model.sessions.count,
                                                          rows: model.sessions.count,
                                                          footer: model.today != nil || model.usage != nil,
                                                          linked: IslandLayout.linkedRows(model.sessions)),
                                  dock: m.dock, window: window)
        }
        let over = pill(m.mode).contains(mouse)
        let wasOpen = m.mode == .hover
        let open = islandDrag == nil
            && hover.update(overOrb: over, overList: over, hasContent: !model.sessions.isEmpty, now: CACurrentMediaTime(),
                            openDelay: HoverTracker.islandOpenDelay)
        if open, !wasOpen || CACurrentMediaTime() - lastTodayRefresh > 30 { refreshToday() }
        if open, !wasOpen { prStatus.refresh(model.sessions, looking: true) }
        let mode = IslandMode.choose(sessions: model.sessions, now: Date(), hovering: open, doneAt: islandDoneAt, quiet: quiet)
        if m.mode != mode { m.mode = mode }
        // Peeking at the session panel while quiet shows the orb at its normal size.
        animator.quiet = quiet && mode != .hover
        if m.state != animator.state { m.state = animator.state }
        // A colour change fans out across the island (from the old colour as it currently shows).
        let key = IslandColorKey(state: animator.state, done: mode == .done)
        if key != m.colorKey {
            let now = CACurrentMediaTime()
            let midFan = m.fanFrom != nil && now - m.fanStart < IslandModel.fanDuration
            m.fanFrom = midFan && now - m.fanStart < IslandModel.fanDuration / 2 ? m.fanFrom : m.colorKey
            m.fanStart = now
            m.colorKey = key
        }
        // Only publish when something actually expires (the whole island re-renders on every change).
        if m.ticks.contains(where: { CACurrentMediaTime() - $0 > 0.6 }) { m.ticks.removeAll { CACurrentMediaTime() - $0 > 0.6 } }
        island.pill = pill(mode)
    }

    @objc private func toggleBubble() {
        hideTimer?.cancel()
        bubbleHidden.toggle()
        updateVisibility()
        if !bubbleHidden { appearOrb() }
    }

    @objc private func resetPosition() {
        if isIsland {
            settings.prefs.islandDock = .top
            settings.prefs.islandAlong = 0.5
        } else {
            panel.resetPosition()
        }
    }

    private func focusTerminal() {
        let workspace = NSWorkspace.shared
        let override = UserDefaults.standard.string(forKey: TerminalApp.overrideKey)
        guard let id = TerminalApp.resolve(override: override, isInstalled: { workspace.urlForApplication(withBundleIdentifier: $0) != nil }),
              let url = workspace.urlForApplication(withBundleIdentifier: id) else {
            NSSound.beep()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        workspace.openApplication(at: url, configuration: config)
    }

    /// Keeps an already-installed hook in step with this build, so rebuilds don't need a reinstall.
    private func refreshInstalledHook() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bubbleDir = home.appendingPathComponent(".claude-bubble")
        // Only while Claude Code runs our hook (not after Disconnect), and the binary first: the refreshed hook.sh
        // hands every event to it. If the binary can't be put in place, the installed hook.sh (perhaps the older
        // self-contained one) stays, rather than becoming a shim with nothing to run.
        let settings = (try? Data(contentsOf: SetupModel.settingsURL)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        if HookInstaller.connection(settings: settings).hooks {
            do { try installHookBinary() } catch { NSLog("ClaudeBubble: hook binary refresh failed: \(error)") }
        }
        let binaryReady = FileManager.default.isExecutableFile(atPath: bubbleDir.appendingPathComponent("bin/claude-bubble-hook").path)
        if binaryReady { try? FileManager.default.removeItem(at: bubbleDir.appendingPathComponent("python-path")) }   // the old Python hook's
        for (resource, installed) in [("claude-bubble-hook", "hook.sh"), ("claude-bubble-statusline", "statusline.sh")] {
            if installed == "hook.sh", !binaryReady { continue }
            guard let source = Bundle.main.url(forResource: resource, withExtension: "sh") else { continue }
            do {
                if try HookInstaller.refreshInstalledHook(source: source, destination: home.appendingPathComponent(".claude-bubble/\(installed)")) {
                    NSLog("ClaudeBubble: refreshed installed \(installed)")
                }
            } catch {
                NSLog("ClaudeBubble: \(installed) refresh failed: \(error)")
            }
        }
        // Bring an existing install up to date: newer hook events, and the status line wrapper (usage).
        let settingsURL = home.appendingPathComponent(".claude/settings.json").resolvingSymlinksInPath()
        let wrapperURL = bubbleDir.appendingPathComponent("statusline.sh")
        let command = "\"\(bubbleDir.appendingPathComponent("hook.sh").path)\""
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let upgrade = HookInstaller.upgrade(settings: settings, hookCommand: command, wrapper: "\"\(wrapperURL.path)\"") else { return }
        do {
            let fm = FileManager.default
            if upgrade.inner != nil, !fm.fileExists(atPath: wrapperURL.path) {
                guard let source = Bundle.main.url(forResource: "claude-bubble-statusline", withExtension: "sh") else { return }
                try fm.copyItem(at: source, to: wrapperURL)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)
            }
            if let inner = upgrade.inner {
                try inner.write(to: bubbleDir.appendingPathComponent("statusline-inner"), atomically: true, encoding: .utf8)
            }
            let out = try JSONSerialization.data(withJSONObject: upgrade.settings, options: [.prettyPrinted, .withoutEscapingSlashes])
            try out.write(to: settingsURL, options: .atomic)
            NSLog("ClaudeBubble: brought the Claude Code hooks and status line up to date")
        } catch {
            NSLog("ClaudeBubble: hook upgrade failed: \(error)")
        }
    }

    /// Settings live on the panel's second page.
    @objc private func openSettings() {
        showQuickPanelFromStatusItem(page: .advanced)
    }

    /// Pushes changed preferences to the orb, pips, list and window.
    private func apply(_ prefs: BubblePreferences) {
        if !prefs.toasts { toasts.clear() }
        if prefs.palette != applied.palette {
            toastModel.palette = prefs.palette
            animator.palette = prefs.palette
            model.palette = prefs.palette
        }
        if prefs.diameter != applied.diameter { panel.setDiameter(prefs.diameter) }
        if prefs.opacity != applied.opacity { panel.alphaValue = prefs.opacity }
        animator.interaction = prefs.interaction
        sounds.enabled = prefs.sounds && !quiet
        if prefs.quiet != quiet { setQuiet(prefs.quiet) }
        let usageChanged = prefs.usage != applied.usage
        let styleChanged = prefs.style != applied.style
        let paletteChanged = prefs.palette != applied.palette
        applied = prefs
        if paletteChanged { applyState() }   // menu-bar icon color
        applyIslandOptions(prefs)
        if styleChanged {
            hover.dismiss()   // an open list or island panel mustn't carry over to the other style
            updateVisibility()
            if !bubbleHidden { appearOrb() }
        }
        if usageChanged {
            // Turning usage back on never announces thresholds crossed while it was off.
            usageAlerts.reset()
            refreshUsage()
        }
    }

    /// Advances the pip choreography, reports finished sessions to the orb, and handles pip hover.
    private func updatePips(mouse: CGPoint) {
        let now = CACurrentMediaTime()
        let events = choreographer.update(model.sessions.map { PipInput(id: $0.id, state: $0.state, review: $0.reviewReady) },
                                          now: now)
        if events.contains(.ringPop), !quiet { animator.ringPop() }
        if events.contains(.allDone), forcedState == nil, !quiet { animator.celebrate(from: .idle) }
        if events.contains(.allDone) { islandDoneAt = Date() }
        let previous = model.pips
        let frame = choreographer.frame(now: now)
        if frame != model.pips { model.pips = frame }
        if now - launchedAt > 1.5, !bubbleHidden, applied.toasts {
            announce(events, previous: previous, now: now)
        }
        if now - launchedAt > 1.5, !bubbleHidden {
            for request in PipSounds.requests(for: events, frame: frame, previous: previous, completion: applied.completionSound)
            where soundLimiter.allow(request.cue, now: now) {
                // The spawn tone lands as the rim is mid-stretch, like the design.
                sounds.play(request, after: request.cue == .spawn ? 0.13 : 0)
            }
        }

        // The pip arc, its hover, the pull toward a new pip and the pip card belong to the floating orb.
        guard !isIsland else {
            if pipCard.isVisible { pipCard.hide() }
            if model.hoveredPip != nil { model.hoveredPip = nil; applyState() }
            return
        }
        let side = panel.frame.width
        let local = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)   // y-down, like the view
        let centre = CGPoint(x: side / 2, y: side / 2)
        let radius = side * 0.3 * PipArc.radiusScale
        // The orb's rim stretches toward the newest pip's slot, then the pip snaps off.
        if frame.visible, model.present, !bubbleHidden, !quiet,
           let id = events.reversed().compactMap({ if case let .spawned(id) = $0 { id } else { nil } }).first,
           let slot = frame.pips.first(where: { $0.id == id })?.slot {
            let p = PipArc.position(slot: slot, slots: frame.slots, centre: centre, radius: radius, around: model.pipAround)
            animator.pull(towards: SIMD2(Float(p.x - centre.x), Float(centre.y - p.y)))   // view is y-down
        }
        // The session list can overlap the pip arc; when the pointer is in the list, the list wins.
        let overList = listPanel.isShown && listPanel.frame.contains(mouse)
        let hit = bubbleHidden || quiet || !model.present || overList ? nil : PipArc.hit(local, frame: frame, centre: centre, radius: radius, around: model.pipAround)
        if hit != model.hoveredPip {
            model.hoveredPip = hit
            applyState()
            if let id = hit, let pip = frame.pips.first(where: { $0.id == id }), let slot = pip.slot,
               soundLimiter.allow(.hover, now: now) {
                sounds.play(SoundRequest(cue: .hover, note: PipSounds.note(slot: slot), pan: PipSounds.pan(slot: slot, slots: frame.slots)))
            }
        }
        guard let id = hit, let pip = frame.pips.first(where: { $0.id == id }), let slot = pip.slot,
              let session = model.sessions.first(where: { $0.id == id }) else {
            if pipCard.isVisible { pipCard.hide() }
            return
        }
        let p = PipArc.position(slot: slot, slots: frame.slots, centre: centre, radius: radius, around: model.pipAround)
        pipCard.show(session, under: CGPoint(x: panel.frame.minX + p.x, y: panel.frame.maxY - p.y),
                     away: CGVector(dx: p.x - centre.x, dy: centre.y - p.y))   // view is y-down
    }

    // MARK: Usage

    private func startUsagePolling() {
        realUsage = UsageReading.load()
        refreshUsage()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.realUsage = UsageReading.load()
            self.refreshUsage()
            self.linkScanner.refresh(self.watchedSessions)   // new issue mentions turn up between session events too
            self.prStatus.refresh(self.model.sessions)
        }
        RunLoop.main.add(timer, forMode: .common)
        usageTimer = timer
    }

    /// Pushes the current usage (real, or the simulator's) to the orb, the hover card and the toasts.
    private func refreshUsage() {
        let fromSimulator = simulator.isOpen && simulator.usageActive
        if fromSimulator != usageFromSimulator {
            usageFromSimulator = fromSimulator
            usageAlerts.reset()
        }
        let reading = applied.usage ? (fromSimulator ? simulator.usageReading : realUsage) : nil
        let now = Date()
        if reading != model.usage { model.usage = reading }
        animator.usageLeft = reading?.left(at: now)
        for alert in usageAlerts.update(reading, now: now) where applied.toasts && !bubbleHidden {
            pushToast(alert.kind, name: "Usage", text: alert.text)
        }
    }

    // MARK: Toasts

    private func announce(_ events: [PipEvent], previous: PipsFrame, now: CFTimeInterval) {
        let names = Dictionary(model.sessions.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let reviews = Set(model.sessions.filter(\.reviewReady).map(\.id))
        for toast in ToastQueue.toasts(for: events, previous: previous, names: names, reviews: reviews) {
            pushToast(toast.kind, name: toast.name)
        }
        if events.contains(.allDone) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.applied.toasts else { return }
                self.pushToast(.allDone, name: "All sessions")
            }
        }
    }

    /// Shows a toast, or holds it for the catch-up while quiet.
    private func pushToast(_ kind: ToastKind, name: String, text: String? = nil) {
        if quiet {
            heldToasts.append(HeldToast(kind: kind, name: name, text: text))
            if heldToasts.count > 500 { heldToasts.removeFirst() }
            return
        }
        toasts.push(kind, name: name, text: text, now: CACurrentMediaTime())
        if kind != .started { tugTowardToasts() }   // a new pip already has its own pull
    }

    private func setQuiet(_ on: Bool) {
        guard on != quiet else { return }
        quiet = on
        animator.quiet = on
        model.quiet = on
        sounds.enabled = applied.sounds && !on
        if on {
            hover.dismiss()
            if listPanel.isShown { listPanel.popOut() }
            if pipCard.isVisible { pipCard.hide() }
            return
        }
        // Back: play what was held, quickly.
        let plan = CatchUp.plan(heldToasts)
        heldToasts = []
        for item in plan {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + item.delay) { [weak self] in
                // If quiet comes back mid catch-up, pushToast holds these again rather than dropping them.
                guard let self, self.applied.toasts, !self.bubbleHidden else { return }
                self.pushToast(item.kind, name: item.name, text: item.text)
            }
        }
    }

    /// Which way the toast stack lies from the orb (it follows the pips).
    private var toastPull: SIMD2<Float> = [0, -1]

    /// A toast appearing gives the orb a small taffy pull toward the stack.
    private func tugTowardToasts() {
        animator.pull(towards: toastPull, amplitude: 0.32)
    }

    /// Ages the toasts, lays out the stack and places its panel under (or above) the orb.
    private func updateToasts(mouse: CGPoint, now: CFTimeInterval) {
        guard applied.toasts, !toasts.isEmpty, !bubbleHidden else {
            if toastPanel.isVisible { toastPanel.orderOut(nil) }
            if !toasts.isEmpty { toasts.tick(now: now, hovering: false) }
            return
        }
        let placement: ToastLayout.Placement
        if isIsland {
            // Off the island's open side.
            let m = island.model
            let pill = IslandLayout.pillRect(size: IslandLayout.size(mode: m.mode, dock: m.dock, rest: m.rest,
                                                                     pips: model.sessions.count, rows: model.sessions.count,
                                                                     footer: model.today != nil || model.usage != nil,
                                                                     linked: IslandLayout.linkedRows(model.sessions)),
                                             dock: m.dock, window: island.frame)
            let visible = NSScreen.screens.first { $0.frame.intersects(island.frame) }.map(islandArea) ?? island.frame
            placement = ToastLayout.placeIsland(pill: pill, dock: m.dock, size: ToastPanel.size, visible: visible)
        } else {
            let orb = panel.frame
            let visible = BubblePanel.screen(nearest: CGPoint(x: orb.midX, y: orb.midY))?.visibleFrame ?? orb
            // Under the orb, or opposite whichever side would be cut off; always fully on screen.
            placement = ToastLayout.place(orb: orb, size: ToastPanel.size, visible: visible)
        }
        let frame = placement.frame, flipped = placement.flipped
        toastPull = placement.pull
        if toastModel.align != placement.align { toastModel.align = placement.align }
        // Expanded while the pointer is over the stack (lifetimes pause too).
        let collapsedHeight = toasts.stackHeight(expanded: false)
        let height = toastModel.placements.isEmpty ? collapsedHeight : max(collapsedHeight, toasts.stackHeight(expanded: hoverToasts))
        let stack = flipped ? CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: height)
                            : CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        hoverToasts = stack.contains(mouse)
        toasts.tick(now: now, hovering: hoverToasts)
        let placements = toasts.layout(expanded: hoverToasts)
        if placements != toastModel.placements { toastModel.placements = placements }
        if flipped != toastModel.flipped { toastModel.flipped = flipped }
        // The hover list already shows every session; toasts step aside while it's open.
        if listPanel.isShown || (isIsland && island.model.mode == .hover) || toasts.isEmpty {
            if toastPanel.isVisible { toastPanel.orderOut(nil) }
        } else {
            toastPanel.show(at: frame)
        }
    }

    @objc private func openSimulator() {
        if simulatorWindow == nil {
            simulatorWindow = SimulatorWindowController(simulator: simulator) { [weak self] in self?.applied.palette ?? .agentsView }
        }
        simulatorWindow?.show()
    }

    /// Totals today's activity from the job timelines, off the main thread.
    private func refreshToday() {
        lastTodayRefresh = CACurrentMediaTime()
        let since = Calendar.current.startOfDay(for: Date())
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let summary = DailyActivity.summary(jobsDir: JobStore.defaultDirectory, since: since)
            DispatchQueue.main.async { self?.model.today = summary }
        }
    }

    private func appearOrb() {
        animator.appear()
        model.present = true
    }

    private func vanishOrb() {
        animator.vanish()
        model.present = false
    }

    private func currentSpot() -> CGPoint? {
        let frame = panel.frame
        guard let visible = BubblePanel.screen(nearest: CGPoint(x: frame.midX, y: frame.midY))?.visibleFrame else { return nil }
        return RelativePlacement.spot(of: frame, in: visible)
    }

    /// Wherever the user puts the orb while following becomes the shared spot for every display.
    private func rememberSpot() {
        guard applied.followPointer, let spot = currentSpot() else { return }
        let stored = [Double(spot.x), Double(spot.y)]
        if settings.prefs.relativeSpot != stored { settings.prefs.relativeSpot = stored }
    }

    /// Moves the orb to the pointer's display, at the shared spot.
    private func followPointer(to mouse: CGPoint) {
        guard !bubbleHidden, !swappingDisplays else { return }
        let displays = NSScreen.screens.map { PointerFollow.Display(frame: $0.frame, visible: $0.visibleFrame) }
        if let origin = PointerFollow.destination(enabled: applied.followPointer,
                                                  buttonDown: NSEvent.pressedMouseButtons & 1 != 0,
                                                  mouse: mouse, panelFrame: panel.frame, displays: displays,
                                                  spot: applied.relativeSpot.map { CGPoint(x: $0[0], y: $0[1]) }) {
            // Pop out here, jump while invisible, pop in there.
            swappingDisplays = true
            vanishOrb()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                guard let self else { return }
                self.panel.move(to: origin)
                self.appearOrb()
                self.swappingDisplays = false
            }
        }
    }

    /// Polls the pointer at 20Hz; cheap, and catches hovers the click-through monitors don't see.
    private func startHoverTracking() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.updateHover() }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func updateHover() {
        let mouse = NSEvent.mouseLocation
        animator.motionElapsed = motionSince.map { Date().timeIntervalSince($0) } ?? 0
        if isIsland {
            // The island: no floating orb, pips, edge light, pointer attention or hover card.
            edgeLight.update(orb: nil, screen: nil, shared: [], color: .clear, state: .idle, opacity: 1, dt: 0.05)
            animator.setPointer(offset: .zero, closeness: 0)
            updatePips(mouse: mouse)
            updateIsland(mouse: mouse)
            updateToasts(mouse: mouse, now: CACurrentMediaTime())
            return
        }
        followPointer(to: mouse)
        turnPips()
        let orbScreen = BubblePanel.screen(nearest: CGPoint(x: panel.frame.midX, y: panel.frame.midY))
        let shown = animator.state
        let c = applied.palette[shown].swatch
        // Edges shared with another display aren't the edge of the desktop: no light there.
        let shared = orbScreen.map { s in EdgeLight.sharedEdges(of: s.frame, among: NSScreen.screens.filter { $0 != s }.map(\.frame)) } ?? []
        edgeLight.update(orb: applied.edgeLight && !bubbleHidden && model.present && !quiet ? panel : nil, screen: orbScreen?.visibleFrame,
                         shared: shared,
                         color: Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)), state: shown,
                         opacity: applied.opacity, dt: 0.05)
        updatePips(mouse: mouse)
        updateToasts(mouse: mouse, now: CACurrentMediaTime())
        let centre = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let radius = panel.frame.width * 0.3
        animator.setPointer(offset: PointerProximity.offset(mouse: mouse, centre: centre, radius: radius),
                            closeness: bubbleHidden ? 0 : PointerProximity.closeness(mouse: mouse, centre: centre, radius: radius))
        let open = hover.update(overOrb: !bubbleHidden && BubblePlacement.isOverOrb(mouse, panelFrame: panel.frame),
                                overList: listPanel.isShown && listPanel.frame.contains(mouse),
                                hasContent: !bubbleHidden && !model.sessions.isEmpty,
                                now: CACurrentMediaTime())
        if open, CACurrentMediaTime() - lastTodayRefresh > (listPanel.isShown ? 30 : 0) { refreshToday() }
        if open, !listPanel.isShown {
            prStatus.refresh(model.sessions, looking: true)   // what you see is current
            listPanel.show(near: panel.frame)
        } else if !open, listPanel.isShown {
            listPanel.popOut()
        }
    }

    /// Login-item state can change in System Settings, so re-read it each time the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if bubbleHidden, let until = hiddenUntil, until > Date() {
            toggleItem.title = "Show Bubble · back in \(DurationFormat.string(until.timeIntervalSinceNow + 59))"
        }
        // Refresh the quick settings so their checkmarks match the current preferences.
        guard menu === statusItem.menu, let first = quickItems.first else { return }
        let index = menu.index(of: first)
        quickItems.forEach(menu.removeItem)
        quickItems = makeQuickSettingsItems()
        for (offset, item) in quickItems.enumerated() { menu.insertItem(item, at: index + offset) }
    }

    // MARK: Quick settings (shared by the orb's context menu and the menu-bar menu)

    private func makeQuickSettingsItems() -> [NSMenuItem] {
        let prefs = settings.prefs
        let colors = NSMenu()
        for preset in OrbPalette.presets {
            let it = item(QuickPicks.title(forPreset: preset.name, in: prefs), #selector(pickPreset(_:)))
            it.representedObject = preset.name
            it.state = QuickPicks.isChecked(preset: preset.name, in: prefs) ? .on : .off
            colors.addItem(it)
        }
        let sizes = NSMenu()
        let checkedSize = QuickPicks.checkedSize(prefs.diameter)
        for size in QuickPicks.sizes {
            let it = item("\(size.label) (\(Int(size.diameter)) pt)", #selector(pickSize(_:)))
            it.representedObject = size.diameter
            it.state = checkedSize == size.diameter ? .on : .off
            sizes.addItem(it)
        }
        let opacities = NSMenu()
        let checkedOpacity = QuickPicks.checkedOpacity(prefs.opacity)
        for opacity in QuickPicks.opacities {
            let it = item("\(Int((opacity * 100).rounded()))%", #selector(pickOpacity(_:)))
            it.representedObject = opacity
            it.state = checkedOpacity == opacity ? .on : .off
            opacities.addItem(it)
        }
        let interactions = NSMenu()
        for mode in PointerInteraction.allCases {
            let it = item(mode.label, #selector(pickInteraction(_:)))
            it.representedObject = mode.rawValue
            it.state = prefs.interaction == mode ? .on : .off
            interactions.addItem(it)
        }
        let toastItem = item("Toasts", #selector(toggleToasts))
        toastItem.state = prefs.toasts ? .on : .off
        let quietItem = item("Quiet Mode", #selector(toggleQuiet))
        quietItem.state = quiet ? .on : .off
        let edgeItem = item("Edge Light", #selector(toggleEdgeLight))
        edgeItem.state = prefs.edgeLight ? .on : .off
        let usageItem = item("Usage", #selector(toggleUsage))
        usageItem.state = prefs.usage ? .on : .off
        let soundItem = item("Sounds", #selector(toggleSounds))
        soundItem.state = prefs.sounds ? .on : .off
        let completions = NSMenu()
        for option in CompletionSound.allCases {
            let it = item(option.label, #selector(pickCompletionSound(_:)))
            it.representedObject = option.rawValue
            it.state = prefs.completionSound == option ? .on : .off
            completions.addItem(it)
        }
        let styles = NSMenu()
        for style in BubbleStyle.allCases {
            let it = item(style == .orb ? "Orb" : "Island", #selector(pickStyle(_:)))
            it.representedObject = style.rawValue
            it.state = prefs.style == style ? .on : .off
            styles.addItem(it)
        }
        let docks = NSMenu()
        for dock in IslandDock.allCases {
            let it = item(dock.rawValue.capitalized, #selector(pickDock(_:)))
            it.representedObject = dock.rawValue
            it.state = prefs.islandDock == dock ? .on : .off
            docks.addItem(it)
        }
        let follow = item("Follow the Pointer", #selector(toggleFollow))
        follow.state = prefs.followPointer ? .on : .off
        let styleItems = [submenu("Style", styles)] + (prefs.style == .island ? [submenu("Island Dock", docks)] : [])
        return styleItems + [quietItem, submenu("Colors", colors), submenu("Size", sizes), submenu("Opacity", opacities),
                submenu("Interaction", interactions), toastItem, usageItem, edgeItem, soundItem, submenu("Completion Sound", completions), follow]
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = menu
        return it
    }

    /// Right-clicking the orb or island opens the quick panel (the menu-bar icon keeps the standard menu).
    private func showOrbMenu(with event: NSEvent, in view: NSView) {
        hover.dismiss()
        listPanel.popOut()
        quickPanel.show(at: NSEvent.mouseLocation)
    }

    private lazy var quickPanel = QuickPanel(settings: settings, actions: QuickPanelActions(
        hideForAnHour: { [weak self] in self?.hide(for: 3600) },
        restart: { [weak self] in self?.restart() },
        quit: { NSApp.terminate(nil) },
        previewSound: { [weak self] option in self?.sounds.previewCompletion(option) },
        openSetup: { [weak self] in self?.openSetup() },
        disconnect: { [weak self] in self?.disconnectClaudeCode() },
        uninstall: { [weak self] in self?.uninstallApp() },
        resetPosition: { [weak self] in self?.resetPosition() },
        launchAtLogin: { SMAppService.mainApp.status == .enabled },
        toggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() },
        debugState: { [weak self] in self?.forcedState?.rawValue ?? "live" },
        setDebugState: { [weak self] key in self?.forceState(key) },
        openSimulator: { [weak self] in self?.openSimulator() }
    ))

    /// Under the menu-bar icon (or at the pointer if the icon isn't showing).
    private func showQuickPanelFromStatusItem(page: QuickPanelState.Page = .main) {
        if let button = statusItem.button, let window = button.window {
            let r = window.convertToScreen(button.convert(button.bounds, to: nil))
            quickPanel.show(at: CGPoint(x: r.minX - 4, y: r.minY), page: page)
        } else {
            quickPanel.show(at: NSEvent.mouseLocation, page: page)
        }
    }

    private var hideTimer: DispatchWorkItem?
    /// When a timed hide ends (for the menu's countdown).
    private var hiddenUntil: Date?
    private var statusMenu: NSMenu!

    /// Hides the bubble and brings it back after `seconds` (unless it's been shown again by hand).
    private func hide(for seconds: TimeInterval) {
        guard !bubbleHidden else { return }
        bubbleHidden = true
        updateVisibility()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.bubbleHidden else { return }
            self.bubbleHidden = false
            self.updateVisibility()
            self.appearOrb()
        }
        hideTimer?.cancel()
        hideTimer = work
        hiddenUntil = Date().addingTimeInterval(seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Force a state to preview it (e.g. Working → Idle plays the completed moment); Live returns to real sessions.
    private func makeDebugMenu() -> NSMenu {
        let menu = NSMenu()
        let selected = forcedState?.rawValue ?? "live"
        for (title, key) in [("Live", "live"), ("Idle", "idle"), ("Working", "working"), ("Needs You", "needs"), ("Error", "error")] {
            let it = item(title, #selector(setDebugState(_:)))
            it.representedObject = key
            it.state = key == selected ? .on : .off
            menu.addItem(it)
        }
        menu.addItem(.separator())
        menu.addItem(item("Session Simulator…", #selector(openSimulator)))
        return menu
    }

    @objc private func pickPreset(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { settings.applyPreset(name) }
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        if let diameter = sender.representedObject as? Double { settings.prefs.diameter = diameter }
    }

    @objc private func pickOpacity(_ sender: NSMenuItem) {
        if let opacity = sender.representedObject as? Double { settings.prefs.opacity = opacity }
    }

    @objc private func pickInteraction(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = PointerInteraction(rawValue: raw) {
            settings.prefs.interaction = mode
        }
    }

    @objc private func pickCompletionSound(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = CompletionSound(rawValue: raw) else { return }
        settings.prefs.completionSound = option
        sounds.previewCompletion(option)
    }

    @objc private func toggleToasts() {
        settings.prefs.toasts.toggle()
    }

    @objc private func toggleQuiet() {
        settings.prefs.quiet.toggle()
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let style = BubbleStyle(rawValue: raw) { settings.prefs.style = style }
    }

    @objc private func pickDock(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let dock = IslandDock(rawValue: raw) { settings.prefs.islandDock = dock }
    }

    @objc private func toggleEdgeLight() {
        settings.prefs.edgeLight.toggle()
    }

    @objc private func toggleUsage() {
        settings.prefs.usage.toggle()
    }

    @objc private func toggleSounds() {
        settings.prefs.sounds.toggle()
    }

    @objc private func toggleFollow() {
        settings.setFollowPointer(!settings.prefs.followPointer)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// Relaunches this same bundle from a detached shell once we've exited.
    @objc private func restart() {
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    @objc private func setDebugState(_ sender: NSMenuItem) {
        forceState(sender.representedObject as? String ?? "live")
    }

    /// Debug: force a state ("live" returns to real sessions); Working then Idle previews the completed moment.
    private func forceState(_ key: String) {
        let before = forcedState ?? liveState
        forcedState = BubbleState(rawValue: key)
        applyState()
        if before == .working, forcedState == .idle { animator.celebrate(from: .working) }
    }

    /// Copies the bundled hook binary to ~/.claude-bubble/bin, where hook.sh runs it.
    private func installHookBinary() throws {
        guard let source = Bundle.main.url(forResource: "claude-bubble-hook", withExtension: nil) else {
            throw HookInstaller.InstallError.missingHookScript
        }
        let dest = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-bubble/bin/claude-bubble-hook")
        if try HookInstaller.installBinary(source: source, destination: dest) { NSLog("ClaudeBubble: installed hook binary") }
    }

    /// Connects Claude Code to the bubble: the hook binary, hooks for every event, and the status line wrapper.
    private func connectClaudeCode() throws {
        guard let source = Bundle.main.url(forResource: "claude-bubble-hook", withExtension: "sh"),
              let statusLine = Bundle.main.url(forResource: "claude-bubble-statusline", withExtension: "sh") else {
            throw HookInstaller.InstallError.missingHookScript
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        try installHookBinary()
        try HookInstaller.install(settingsURL: home.appendingPathComponent(".claude/settings.json"),
                                  hookSource: source,
                                  hookDestination: home.appendingPathComponent(".claude-bubble/hook.sh"),
                                  statusLineSource: statusLine,
                                  statusLineDestination: home.appendingPathComponent(".claude-bubble/statusline.sh"))
    }

    @objc private func openSetup() {
        if setupWindow == nil {
            setupWindow = SetupWindowController(model: SetupModel(
                settings: settings,
                simulator: simulator,
                connect: { [weak self] in try self?.connectClaudeCode() },
                toggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() },
                revealSettings: {
                    let url = SetupModel.settingsURL
                    if FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        NSWorkspace.shared.open(url.deletingLastPathComponent())
                    }
                },
                demo: { [weak self] on in self?.setupDemo(on) }))
        }
        setupWindow?.show()
    }

    private var demoLoop: Timer?

    /// While setup is open, the real bubble plays the Session Simulator's sample session, on a loop.
    private func setupDemo(_ on: Bool) {
        demoLoop?.invalidate()
        demoLoop = nil
        guard on else {
            simulator.reset()
            simulator.usageActive = false
            simulator.isOpen = false
            return
        }
        simulator.isOpen = true
        simulator.playDemo()
        let length = SimulatorStory.session.reduce(0) { $0 + $1.duration } + 3
        demoLoop = Timer.scheduledTimer(withTimeInterval: length, repeats: true) { [weak self] _ in self?.simulator.playDemo() }
    }

    /// The first time the app opens without its hooks in Claude Code, it explains itself and offers to connect.
    private func showSetupOnFirstLaunch() {
        let key = "setupShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let settings = (try? Data(contentsOf: SetupModel.settingsURL)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        UserDefaults.standard.set(true, forKey: key)
        if !HookInstaller.connection(settings: settings).hooks { openSetup() }
    }

    /// Takes the bubble out of Claude Code (after asking): hooks removed, the status line put back as it was.
    private func disconnectClaudeCode() {
        NSApp.activate(ignoringOtherApps: true)
        let ask = NSAlert()
        ask.messageText = "Disconnect from Claude Code?"
        ask.informativeText = "This removes Claude Bubble's hooks from ~/.claude/settings.json and puts your status line back the way it was. Nothing else in your settings changes. You can connect again from Setup."
        ask.addButton(withTitle: "Disconnect")
        ask.addButton(withTitle: "Cancel")
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let done = NSAlert()
        do {
            try HookInstaller.uninstall(settingsURL: home.appendingPathComponent(".claude/settings.json"),
                                        bubbleDir: home.appendingPathComponent(".claude-bubble"))
            done.messageText = "Disconnected"
            done.informativeText = "Restart running Claude Code sessions to stop them reporting. To remove the app too, quit it and move it to the Trash."
        } catch {
            done.alertStyle = .warning
            done.messageText = "Couldn't disconnect"
            done.informativeText = error.localizedDescription
        }
        done.runModal()
        setupWindow?.model.refresh()
    }

    /// Removes Claude Bubble completely (after asking): disconnected from Claude Code, its files, preferences and
    /// login item gone, and the app moved to the Trash. Stops at the first step that fails, before anything that
    /// can't be put back.
    private func uninstallApp() {
        NSApp.activate(ignoringOtherApps: true)
        let ask = NSAlert()
        ask.alertStyle = .critical
        ask.messageText = "Uninstall Claude Bubble?"
        ask.informativeText = "This disconnects it from Claude Code (your other hooks and your status line stay as they are), removes its files and preferences, and moves the app to the Trash."
        ask.addButton(withTitle: "Uninstall")
        ask.addButton(withTitle: "Cancel")
        guard ask.runModal() == .alertFirstButtonReturn else { return }

        let home = FileManager.default.homeDirectoryForCurrentUser
        do {
            try HookInstaller.uninstallEverything(settingsURL: home.appendingPathComponent(".claude/settings.json"),
                                                  bubbleDir: home.appendingPathComponent(".claude-bubble"))
        } catch {
            let failed = NSAlert()
            failed.alertStyle = .warning
            failed.messageText = "Couldn't uninstall"
            failed.informativeText = "\(error.localizedDescription)\n\nNothing was removed."
            failed.runModal()
            return
        }
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        for domain in [Bundle.main.bundleIdentifier, DefaultsMigration.legacyDomain].compactMap({ $0 }) {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        UserDefaults.standard.synchronize()

        let done = NSAlert()
        done.messageText = "Claude Bubble is uninstalled"
        done.informativeText = "Restart any Claude Code sessions that are still running; until then they may show a hook error. Your settings from before Claude Bubble are saved at ~/.claude/settings.json.claude-bubble.bak."
        done.runModal()
        // Last, so nothing above writes the preferences back: the app goes to the Trash (recoverable) and quits.
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            DispatchQueue.main.async { exit(0) }
        }
    }

    /// The menu-bar icon while the bubble is hidden: crossed out, so it's clear how to bring it back.
    private static let hiddenImage: NSImage? = {
        let image = NSImage(systemSymbolName: "eye.slash.circle", accessibilityDescription: "Claude Bubble: hidden")
        image?.isTemplate = true
        return image
    }()

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if bubbleHidden, NSApp.currentEvent?.type != .rightMouseUp {
            toggleBubble()
        } else if quickPanel.isVisible {
            quickPanel.dismiss()
        } else {
            showQuickPanelFromStatusItem()
        }
    }

    private static func statusImage(for state: BubbleState, palette: OrbPalette) -> NSImage? {
        let image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Claude Bubble: \(state.rawValue)")
        // Idle stays a plain template icon so the menu bar is quiet; busy states take the palette's color.
        let c = palette[state].swatch
        let color: NSColor? = state == .idle ? nil : NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        guard let color else {
            image?.isTemplate = true
            return image
        }
        let tinted = image?.withSymbolConfiguration(.init(paletteColors: [color]))
        tinted?.isTemplate = false
        return tinted
    }
}
