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
        refreshInstalledHook()
        setUpStatusItem()
        watcher = SessionWatcher(directory: SessionStore.defaultDirectory) { [weak self] state, sessions in
            self?.liveState = state
            self?.model.sessions = sessions
            self?.applyState()
        }
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

    private func applyState() {
        let state = forcedState ?? liveState
        animator.setState(state)
        statusItem.button?.image = Self.statusImage(for: state, palette: applied.palette)
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
        let paletteChanged = prefs.palette != applied.palette
        applied = prefs
        if paletteChanged { applyState() }   // menu-bar icon color
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
        let follow = item("Follow the Pointer", #selector(toggleFollow))
        follow.state = prefs.followPointer ? .on : .off
        return [submenu("Colors", colors), submenu("Size", sizes), submenu("Opacity", opacities),
                submenu("Interaction", interactions), follow]
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
        menu.addItem(item("Restart", #selector(restart)))
        menu.addItem(NSMenuItem(title: "Quit Claude Bubble", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        NSMenu.popUpContextMenu(menu, with: event, for: view)
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
        forcedState = (sender.representedObject as? String).flatMap(BubbleState.init(rawValue:))
        applyState()
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
