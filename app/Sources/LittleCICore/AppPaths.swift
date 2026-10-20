import Foundation

/// Where the app keeps its inventory, event journal and job ledger on this Mac.
public enum AppPaths {
    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["LITTLE_CI_HOME"] { return URL(fileURLWithPath: override) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LittleCI", isDirectory: true)
    }

    public static var inventory: URL { directory.appendingPathComponent("inventory.json") }
    public static var events: URL { directory.appendingPathComponent("events.jsonl") }
    public static var jobLedger: URL { directory.appendingPathComponent("jobs.jsonl") }
    public static var settings: URL { directory.appendingPathComponent("settings.json") }
}
