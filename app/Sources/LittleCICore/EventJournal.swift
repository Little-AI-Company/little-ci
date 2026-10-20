import Foundation

/// Observed transitions, kept on this Mac: at most 30 days and 5,000 events. History exists only for
/// the time the app ran; it cannot reconstruct what happened between observations.
public actor EventJournal {
    public static let retention: TimeInterval = 30 * 86_400
    public static let capacity = 5_000

    private let url: URL?
    public private(set) var events: [FleetEvent] = []

    /// `url == nil` keeps the journal in memory (demo data, tests).
    public init(url: URL?) {
        self.url = url
        if let url, let text = try? String(contentsOf: url, encoding: .utf8) {
            events = text.split(separator: "\n").compactMap { try? JobLedger.decoder.decode(FleetEvent.self, from: Data($0.utf8)) }
        }
    }

    public func append(_ newEvents: [FleetEvent], now: Date = Date()) throws {
        guard !newEvents.isEmpty else { return }
        events += newEvents
        let cutoff = now.addingTimeInterval(-Self.retention)
        let before = events.count
        events = Array(events.filter { $0.at >= cutoff }.suffix(Self.capacity))
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if events.count < before {
            try rewrite(url)
        } else {
            try appendLines(newEvents, to: url)
        }
    }

    public func recent(_ limit: Int, subject: Subject? = nil) -> [FleetEvent] {
        Array(events.filter { subject == nil || $0.subject == subject }.suffix(limit).reversed())
    }

    private func rewrite(_ url: URL) throws {
        let lines = try events.map { String(decoding: try JobLedger.encoder.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: url, options: .atomic)
    }

    private func appendLines(_ newEvents: [FleetEvent], to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for event in newEvents { try handle.write(contentsOf: try JobLedger.encoder.encode(event) + Data("\n".utf8)) }
    }

    /// Events for findings that appeared or cleared between two assessments.
    public static func transitions(from previous: Assessment?, to current: Assessment) -> [FleetEvent] {
        let before = Dictionary((previous?.findings ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(current.findings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let raised = current.findings.filter { before[$0.id] == nil || before[$0.id]?.severity != $0.severity }.map {
            FleetEvent(at: current.assessedAt, kind: .findingRaised, subject: $0.subject, severity: $0.severity,
                       title: $0.title, detail: $0.evidence.first)
        }
        let cleared = (previous?.findings ?? []).filter { after[$0.id] == nil }.map {
            FleetEvent(at: current.assessedAt, kind: .findingCleared, subject: $0.subject, severity: $0.severity,
                       title: "Cleared: \($0.title)")
        }
        return raised + cleared
    }
}
