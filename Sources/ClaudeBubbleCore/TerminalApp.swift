/// Which app a click on the orb brings forward.
public enum TerminalApp {
    /// Override with: defaults write dev.claudebubble.app terminalBundleID <bundle id>
    public static let overrideKey = "terminalBundleID"

    public static let candidates = [
        "co.zeit.hyper",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.apple.Terminal"
    ]

    public static func resolve(override: String?, isInstalled: (String) -> Bool) -> String? {
        ([override].compactMap { $0 } + candidates).first(where: isInstalled)
    }
}
