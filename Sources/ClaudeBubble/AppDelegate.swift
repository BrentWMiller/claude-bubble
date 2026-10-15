import AppKit
import ClaudeBubbleCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let animator = OrbAnimator()
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
        panel = BubblePanel(animator: animator, model: model)
        panel.onClick = { [weak self] in self?.focusTerminal() }
        listPanel = SessionListPanel(model: model, snapshots: Self.renderSnapshots()) { [weak self] in
            self?.focusTerminal()
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
        statusItem.button?.image = Self.statusImage(for: state)
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

    private static func renderSnapshots() -> [BubbleState: NSImage] {
        var images: [BubbleState: NSImage] = [:]
        for state in BubbleState.allCases {
            if let image = OrbSnapshot.render(state: state, size: 96) {
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

    private static func statusImage(for state: BubbleState) -> NSImage? {
        let image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Claude Bubble: \(state.rawValue)")
        let color: NSColor? = switch state {
        case .idle: nil
        case .working: .systemPurple
        case .needs: .systemOrange
        case .error: .systemRed
        }
        guard let color else {
            image?.isTemplate = true
            return image
        }
        let tinted = image?.withSymbolConfiguration(.init(paletteColors: [color]))
        tinted?.isTemplate = false
        return tinted
    }
}
