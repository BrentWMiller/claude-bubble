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
    private var settingsWindow: SettingsWindowController?
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
        applied = settings.prefs
        model.palette = applied.palette
        animator.interaction = applied.interaction
        sounds.enabled = applied.sounds
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
        pipCard = PipCardPanel(model: model)
        watcher = SessionWatcher(directory: SessionStore.defaultDirectory) { [weak self] state, sessions in
            self?.watchedState = state
            self?.watchedSessions = sessions
            self?.syncSessions()
        }
        // DispatchQueue (not RunLoop.main) so a dragged slider updates live, even in event-tracking mode.
        simulatorSubscription = simulator.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in self?.syncSessions() }
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
        menu.addItem(item("Install Claude Code Hooks…", #selector(installHooks)))
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
        statusItem.menu = menu
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
            model.sessions = watchedSessions
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
        statusItem.button?.image = Self.statusImage(for: forcedState ?? liveState, palette: applied.palette)
        let selected = forcedState?.rawValue ?? "live"
        for it in debugItems { it.state = (it.representedObject as? String) == selected ? .on : .off }
    }

    private func updateVisibility() {
        if bubbleHidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        panel.setRendering(!bubbleHidden)
        toggleItem.title = bubbleHidden ? "Show Bubble" : "Hide Bubble"
    }

    @objc private func toggleBubble() {
        bubbleHidden.toggle()
        updateVisibility()
        if !bubbleHidden { appearOrb() }
    }

    @objc private func resetPosition() { panel.resetPosition() }

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
        for (resource, installed) in [("claude-bubble-hook", "hook.sh"), ("claude-bubble-statusline", "statusline.sh")] {
            guard let source = Bundle.main.url(forResource: resource, withExtension: "sh") else { continue }
            do {
                if try HookInstaller.refreshInstalledHook(source: source, destination: home.appendingPathComponent(".claude-bubble/\(installed)")) {
                    NSLog("ClaudeBubble: refreshed installed \(installed)")
                }
            } catch {
                NSLog("ClaudeBubble: \(installed) refresh failed: \(error)")
            }
        }
        // A newer hook may listen to more events: add them to settings that already run the bubble's hook.
        let settingsURL = home.appendingPathComponent(".claude/settings.json").resolvingSymlinksInPath()
        let command = "\"\(home.appendingPathComponent(".claude-bubble/hook.sh").path)\""
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let refreshed = HookInstaller.refreshSubscriptions(settings: settings, command: command),
              let out = try? JSONSerialization.data(withJSONObject: refreshed, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return }
        do {
            try out.write(to: settingsURL, options: .atomic)
            NSLog("ClaudeBubble: subscribed the hook to new events")
        } catch {
            NSLog("ClaudeBubble: hook subscription refresh failed: \(error)")
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings) { [weak self] in self?.sounds.previewCompletion($0) }
        }
        settingsWindow?.show()
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
        sounds.enabled = prefs.sounds
        let usageChanged = prefs.usage != applied.usage
        let paletteChanged = prefs.palette != applied.palette
        applied = prefs
        if paletteChanged { applyState() }   // menu-bar icon color
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
        if events.contains(.ringPop) { animator.ringPop() }
        if events.contains(.allDone), forcedState == nil { animator.celebrate(from: .idle) }
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

        let side = panel.frame.width
        let local = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)   // y-down, like the view
        let centre = CGPoint(x: side / 2, y: side / 2)
        let radius = side * 0.3 * PipArc.radiusScale
        // The orb's rim stretches toward the newest pip's slot, then the pip snaps off.
        if frame.visible, model.present, !bubbleHidden,
           let id = events.reversed().compactMap({ if case let .spawned(id) = $0 { id } else { nil } }).first,
           let slot = frame.pips.first(where: { $0.id == id })?.slot {
            let p = PipArc.position(slot: slot, slots: frame.slots, centre: centre, radius: radius, around: model.pipAround)
            animator.pull(towards: SIMD2(Float(p.x - centre.x), Float(centre.y - p.y)))   // view is y-down
        }
        // The session list can overlap the pip arc; when the pointer is in the list, the list wins.
        let overList = listPanel.isShown && listPanel.frame.contains(mouse)
        let hit = bubbleHidden || !model.present || overList ? nil : PipArc.hit(local, frame: frame, centre: centre, radius: radius, around: model.pipAround)
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
            toasts.push(alert.kind, name: "Usage", text: alert.text, now: CACurrentMediaTime())
            tugTowardToasts()
        }
    }

    // MARK: Toasts

    private func announce(_ events: [PipEvent], previous: PipsFrame, now: CFTimeInterval) {
        let names = Dictionary(model.sessions.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let reviews = Set(model.sessions.filter(\.reviewReady).map(\.id))
        for toast in ToastQueue.toasts(for: events, previous: previous, names: names, reviews: reviews) {
            toasts.push(toast.kind, name: toast.name, now: now)
            if toast.kind != .started { tugTowardToasts() }   // a new pip already has its own pull
        }
        if events.contains(.allDone) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.applied.toasts else { return }
                self.toasts.push(.allDone, name: "All sessions", now: CACurrentMediaTime())
                self.tugTowardToasts()
            }
        }
    }

    /// A toast appearing gives the orb a small taffy pull toward the stack.
    private func tugTowardToasts() {
        animator.pull(towards: toastModel.flipped ? [0, 1] : [0, -1], amplitude: 0.32)
    }

    /// Ages the toasts, lays out the stack and places its panel under (or above) the orb.
    private func updateToasts(mouse: CGPoint, now: CFTimeInterval) {
        guard applied.toasts, !toasts.isEmpty, !bubbleHidden else {
            if toastPanel.isVisible { toastPanel.orderOut(nil) }
            if !toasts.isEmpty { toasts.tick(now: now, hovering: false) }
            return
        }
        let orb = panel.frame
        let reach = orb.width * 0.3 * 1.49
        let size = ToastPanel.size
        let visible = BubblePanel.screen(containing: CGPoint(x: orb.midX, y: orb.midY))?.visibleFrame ?? orb
        let belowTop = orb.midY - reach
        let flipped = belowTop - size.height < visible.minY
        let frame = CGRect(x: orb.midX - size.width / 2, y: flipped ? orb.midY + reach : belowTop - size.height,
                           width: size.width, height: size.height)
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
        if listPanel.isShown || toasts.isEmpty {
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
        guard let visible = BubblePanel.screen(containing: CGPoint(x: frame.midX, y: frame.midY))?.visibleFrame else { return nil }
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
        followPointer(to: mouse)
        animator.motionElapsed = motionSince.map { Date().timeIntervalSince($0) } ?? 0
        turnPips()
        let orbScreen = BubblePanel.screen(nearest: CGPoint(x: panel.frame.midX, y: panel.frame.midY))
        let shown = animator.state
        let c = applied.palette[shown].swatch
        // Edges shared with another display aren't the edge of the desktop: no light there.
        let shared = orbScreen.map { s in EdgeLight.sharedEdges(of: s.frame, among: NSScreen.screens.filter { $0 != s }.map(\.frame)) } ?? []
        edgeLight.update(orb: applied.edgeLight && !bubbleHidden && model.present ? panel : nil, screen: orbScreen?.visibleFrame,
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
            listPanel.show(near: panel.frame)
        } else if !open, listPanel.isShown {
            listPanel.popOut()
        }
    }

    /// Login-item state can change in System Settings, so re-read it each time the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
        let follow = item("Follow the Pointer", #selector(toggleFollow))
        follow.state = prefs.followPointer ? .on : .off
        return [submenu("Colors", colors), submenu("Size", sizes), submenu("Opacity", opacities),
                submenu("Interaction", interactions), toastItem, usageItem, edgeItem, soundItem, submenu("Completion Sound", completions), follow]
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = menu
        return it
    }

    private func showOrbMenu(with event: NSEvent, in view: NSView) {
        hover.dismiss()
        listPanel.popOut()
        let menu = NSMenu()
        makeQuickSettingsItems().forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings)))
        menu.addItem(item(bubbleHidden ? "Show Bubble" : "Hide Bubble", #selector(toggleBubble)))
        menu.addItem(item("Reset Position", #selector(resetPosition)))
        menu.addItem(.separator())
        menu.addItem(submenu("Debug", makeDebugMenu()))
        menu.addItem(item("Restart", #selector(restart)))
        menu.addItem(NSMenuItem(title: "Quit Claude Bubble", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        NSMenu.popUpContextMenu(menu, with: event, for: view)
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
        let before = forcedState ?? liveState
        forcedState = (sender.representedObject as? String).flatMap(BubbleState.init(rawValue:))
        applyState()
        // Debug ▸ Working then Idle previews the completed moment.
        if before == .working, forcedState == .idle { animator.celebrate(from: .working) }
    }

    @objc private func installHooks() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        do {
            guard let source = Bundle.main.url(forResource: "claude-bubble-hook", withExtension: "sh"),
                  let statusLine = Bundle.main.url(forResource: "claude-bubble-statusline", withExtension: "sh") else {
                throw HookInstaller.InstallError.missingHookScript
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            try HookInstaller.install(settingsURL: home.appendingPathComponent(".claude/settings.json"),
                                      hookSource: source,
                                      hookDestination: home.appendingPathComponent(".claude-bubble/hook.sh"),
                                      statusLineSource: statusLine,
                                      statusLineDestination: home.appendingPathComponent(".claude-bubble/statusline.sh"))
            alert.messageText = "Hooks installed"
            alert.informativeText = "New Claude Code sessions will report to the bubble; restart running sessions to pick it up. Your status line still runs as before, and now also passes usage to the bubble. Your previous settings were saved to settings.json.claude-bubble.bak."
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Couldn't install hooks"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
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
