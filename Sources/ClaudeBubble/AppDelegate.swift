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
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    private var bubbleHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "bubbleHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "bubbleHidden") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applied = settings.prefs
        model.palette = applied.palette
        model.snapshots = Self.renderSnapshots(applied.palette)
        panel = BubblePanel(animator: animator, model: model, diameter: applied.diameter)
        panel.alphaValue = applied.opacity
        panel.onClick = { [weak self] in self?.focusTerminal() }
        panel.onDragEnded = { [weak self] in self?.rememberSpot() }
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
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        toggleItem.target = self
        menu.addItem(toggleItem)
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
        let paletteChanged = prefs.palette != applied.palette
        applied = prefs
        if paletteChanged { applyState() }   // menu-bar icon color
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

    /// After the user drags the orb while following, that spot becomes the shared one.
    private func rememberSpot() {
        guard applied.followPointer, let spot = currentSpot() else { return }
        let stored = [Double(spot.x), Double(spot.y)]
        if settings.prefs.relativeSpot != stored { settings.prefs.relativeSpot = stored }
    }

    /// Moves the orb to the pointer's display, at the shared spot.
    private func followPointer(to mouse: CGPoint) {
        guard !bubbleHidden else { return }
        let displays = NSScreen.screens.map { PointerFollow.Display(frame: $0.frame, visible: $0.visibleFrame) }
        if let origin = PointerFollow.destination(enabled: applied.followPointer,
                                                  buttonDown: NSEvent.pressedMouseButtons & 1 != 0,
                                                  mouse: mouse, panelFrame: panel.frame, displays: displays,
                                                  spot: applied.relativeSpot.map { CGPoint(x: $0[0], y: $0[1]) }) {
            panel.setFrameOrigin(origin)
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
        let open = hover.update(overOrb: !bubbleHidden && BubblePlacement.isOverOrb(mouse, panelFrame: panel.frame),
                                overList: listPanel.isVisible && listPanel.frame.contains(mouse),
                                hasContent: !bubbleHidden && !model.sessions.isEmpty,
                                now: CACurrentMediaTime())
        if open, !listPanel.isVisible {
            listPanel.show(near: panel.frame)
        } else if !open, listPanel.isVisible {
            listPanel.orderOut(nil)
        }
    }

    /// Login-item state can change in System Settings, so re-read it each time the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
