import AppKit
import Combine
import ClaudeBubbleCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = SettingsModel()
    private lazy var animator = OrbAnimator(palette: settings.prefs.palette)
    private var applied = BubblePreferences.defaults
    private var settingsSubscription: AnyCancellable?
    private var settingsWindow: SettingsWindowController?
    private var pendingSnapshots: DispatchWorkItem?
    private var lastTodayRefresh: CFTimeInterval = 0
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
    private var soundLimiter = SoundRateLimiter()
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
        model.snapshots = Self.renderSnapshots(applied.palette)
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
            self?.listPanel.orderOut(nil)
        }
        startHoverTracking()
        listPanel.bubble = panel
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
        simulatorSubscription = simulator.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.syncSessions() }
        watcher.start()
        updateVisibility()
        applyState()
        appearOrb()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
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
        guard let source = Bundle.main.url(forResource: "claude-bubble-hook", withExtension: "sh") else { return }
        let destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-bubble/hook.sh")
        do {
            if try HookInstaller.refreshInstalledHook(source: source, destination: destination) {
                NSLog("ClaudeBubble: refreshed installed hook")
            }
        } catch {
            NSLog("ClaudeBubble: hook refresh failed: \(error)")
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(settings: settings) }
        settingsWindow?.show()
    }

    /// Pushes changed preferences to the orb, pips, list and window.
    private func apply(_ prefs: BubblePreferences) {
        if prefs.palette != applied.palette {
            animator.palette = prefs.palette
            model.palette = prefs.palette
            scheduleSnapshots(prefs.palette)
        }
        if prefs.diameter != applied.diameter { panel.setDiameter(prefs.diameter) }
        if prefs.opacity != applied.opacity { panel.alphaValue = prefs.opacity }
        animator.interaction = prefs.interaction
        sounds.enabled = prefs.sounds
        let paletteChanged = prefs.palette != applied.palette
        applied = prefs
        if paletteChanged { applyState() }   // menu-bar icon color
    }

    /// Advances the pip choreography, reports finished sessions to the orb, and handles pip hover.
    private func updatePips(mouse: CGPoint) {
        let now = CACurrentMediaTime()
        let events = choreographer.update(model.sessions.map { PipInput(id: $0.id, state: $0.state) }, now: now)
        if events.contains(.ringPop) { animator.ringPop() }
        if events.contains(.allDone), forcedState == nil { animator.celebrate(from: .idle) }
        let previous = model.pips
        let frame = choreographer.frame(now: now)
        if frame != model.pips { model.pips = frame }
        if now - launchedAt > 1.5, !bubbleHidden {
            for request in PipSounds.requests(for: events, frame: frame, previous: previous)
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
            let p = PipArc.position(slot: slot, slots: frame.slots, centre: centre, radius: radius)
            animator.pull(towards: SIMD2(Float(p.x - centre.x), Float(centre.y - p.y)))   // view is y-down
        }
        // The session list can overlap the pip arc; when the pointer is in the list, the list wins.
        let overList = listPanel.isVisible && listPanel.frame.contains(mouse)
        let hit = bubbleHidden || !model.present || overList ? nil : PipArc.hit(local, frame: frame, centre: centre, radius: radius)
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
        let p = PipArc.position(slot: slot, slots: frame.slots, centre: centre, radius: radius)
        pipCard.show(session, under: CGPoint(x: panel.frame.minX + p.x, y: panel.frame.maxY - p.y))
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

    /// Color-well drags send a stream of palettes; re-render the mini orbs once the stream settles.
    private func scheduleSnapshots(_ palette: OrbPalette) {
        pendingSnapshots?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.snapshots = Self.renderSnapshots(palette) }
        pendingSnapshots = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
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

    private static func renderSnapshots(_ palette: OrbPalette) -> [BubbleState: NSImage] {
        var images: [BubbleState: NSImage] = [:]
        for state in BubbleState.allCases {
            if let image = OrbSnapshot.render(state: state, size: 96, palette: palette) {
                images[state] = NSImage(cgImage: image, size: NSSize(width: 48, height: 48))
            }
        }
        return images
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
        updatePips(mouse: mouse)
        let centre = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let radius = panel.frame.width * 0.3
        animator.setPointer(offset: PointerProximity.offset(mouse: mouse, centre: centre, radius: radius),
                            closeness: bubbleHidden ? 0 : PointerProximity.closeness(mouse: mouse, centre: centre, radius: radius))
        let open = hover.update(overOrb: !bubbleHidden && BubblePlacement.isOverOrb(mouse, panelFrame: panel.frame),
                                overList: listPanel.isVisible && listPanel.frame.contains(mouse),
                                hasContent: !bubbleHidden && !model.sessions.isEmpty,
                                now: CACurrentMediaTime())
        if open, CACurrentMediaTime() - lastTodayRefresh > (listPanel.isVisible ? 30 : 0) { refreshToday() }
        if open, !listPanel.isVisible {
            listPanel.show(near: panel.frame)
        } else if !open, listPanel.isVisible {
            listPanel.orderOut(nil)
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
        let soundItem = item("Sounds", #selector(toggleSounds))
        soundItem.state = prefs.sounds ? .on : .off
        let follow = item("Follow the Pointer", #selector(toggleFollow))
        follow.state = prefs.followPointer ? .on : .off
        return [submenu("Colors", colors), submenu("Size", sizes), submenu("Opacity", opacities),
                submenu("Interaction", interactions), soundItem, follow]
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = menu
        return it
    }

    private func showOrbMenu(with event: NSEvent, in view: NSView) {
        hover.dismiss()
        listPanel.orderOut(nil)
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
            guard let source = Bundle.main.url(forResource: "claude-bubble-hook", withExtension: "sh") else {
                throw HookInstaller.InstallError.missingHookScript
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            try HookInstaller.install(settingsURL: home.appendingPathComponent(".claude/settings.json"),
                                      hookSource: source,
                                      hookDestination: home.appendingPathComponent(".claude-bubble/hook.sh"))
            alert.messageText = "Hooks installed"
            alert.informativeText = "New Claude Code sessions will report to the bubble; restart running sessions to pick it up. Your previous settings were saved to settings.json.claude-bubble.bak."
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
