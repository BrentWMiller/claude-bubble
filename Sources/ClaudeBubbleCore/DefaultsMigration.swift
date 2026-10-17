import Foundation

/// The app's settings moved with its bundle ID (com.brentmiller.ClaudeBubble → dev.claudebubble.app): copies them
/// over once, before anything reads them, unless the new ID already has settings of its own.
public enum DefaultsMigration {
    public static let legacyDomain = "com.brentmiller.ClaudeBubble"
    static let doneKey = "migratedFromLegacyDomain"

    /// `domain`: the defaults' own domain (the bundle ID for `.standard`). Returns whether it copied anything.
    @discardableResult
    public static func migrate(from legacy: String = legacyDomain, to domain: String, in defaults: UserDefaults) -> Bool {
        let own = defaults.persistentDomain(forName: domain) ?? [:]
        guard own[doneKey] == nil else { return false }
        defaults.set(true, forKey: doneKey)
        guard own.isEmpty, let old = defaults.persistentDomain(forName: legacy), !old.isEmpty else { return false }
        for (key, value) in old { defaults.set(value, forKey: key) }
        return true
    }
}
