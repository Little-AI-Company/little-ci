import Foundation

/// One finished job as the app saw it, with why it failed when it did.
public struct LedgerEntry: Codable, Sendable, Equatable {
    public var job: WorkflowJob
    public var workflow: String
    public var failure: FailureClass?

    public init(job: WorkflowJob, workflow: String, failure: FailureClass?) {
        self.job = job
        self.workflow = workflow
        self.failure = failure
    }
}

/// The measured inputs for service levels over one window.
public struct LedgerSummary: Codable, Sendable, Equatable {
    public var windowStart: Date?
    public var checkQueueWaits: [TimeInterval]
    public var machineFailures: Int
    public var codeFailures: Int
    public var unsureFailures: Int
    public var interruptedByStops: Int

    public static let empty = LedgerSummary(windowStart: nil, checkQueueWaits: [], machineFailures: 0, codeFailures: 0,
                                            unsureFailures: 0, interruptedByStops: 0)

    public var judgedFailures: Int { machineFailures + codeFailures + unsureFailures }
}

/// Finished jobs, appended as JSON lines to `jobs.jsonl`. Kept so a week of real use can be reported.
public actor JobLedger {
    private let url: URL
    private var entries: [Int: LedgerEntry] = [:]

    public init(url: URL = AppPaths.jobLedger) {
        self.url = url
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if let entry = try? Self.decoder.decode(LedgerEntry.self, from: Data(line.utf8)) { entries[entry.job.id] = entry }
            }
        }
    }

    public func contains(jobID: Int) -> Bool { entries[jobID] != nil }

    public func record(_ newEntries: [LedgerEntry]) throws {
        let fresh = newEntries.filter { entries[$0.job.id] == nil }
        guard !fresh.isEmpty else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for entry in fresh {
            try handle.write(contentsOf: try Self.encoder.encode(entry) + Data("\n".utf8))
            entries[entry.job.id] = entry
        }
    }

    public func summary(since start: Date, checkLabel: String) -> LedgerSummary {
        Self.summarize(Array(entries.values), since: start, checkLabel: checkLabel)
    }

    public static func summarize(_ entries: [LedgerEntry], since start: Date, checkLabel: String) -> LedgerSummary {
        let window = entries.filter { $0.job.createdAt >= start && $0.job.tookRunner }
        let failures = window.compactMap(\.failure)
        return LedgerSummary(
            windowStart: start,
            checkQueueWaits: window.filter { $0.job.labels.contains(checkLabel) }.compactMap(\.job.queueWait),
            machineFailures: failures.filter { $0.cause == .machine }.count,
            codeFailures: failures.filter { $0.cause == .code }.count,
            unsureFailures: failures.filter { $0.cause == .unsure }.count,
            interruptedByStops: failures.filter { $0.reason == "runner lost" }.count)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum ServiceLevelCalculator {
    static func levels(_ observations: FleetObservations, now: Date) -> [ServiceLevel] {
        let targets = observations.inventory.serviceLevels
        let ledger = observations.ledger
        let basis = ledger.windowStart.map { "jobs since \($0.formatted(.dateTime.month().day().hour().minute()))" } ?? "no jobs recorded yet"
        let waits = ledger.checkQueueWaits
        let median = percentile(waits, 0.5), p90 = percentile(waits, 0.9)

        let fresh = observations.github.flatMap { now.timeIntervalSince($0.observedAt) <= Assessor.staleAfter ? $0 : nil }
        let online = fresh.map { observations.inventory.checkRunners(in: $0).filter { $0.status == .online }.count }
        let machineShare = ledger.judgedFailures > 0 ? Double(ledger.machineFailures) / Double(ledger.judgedFailures) : nil

        return [
            ServiceLevel(id: "queue-wait", name: "Check-job queue wait",
                         target: "median ≤ \(Format.duration(targets.queueWaitMedianSeconds)), p90 ≤ \(Format.duration(targets.queueWaitP90Seconds))",
                         measured: median.map { "median \(Format.duration($0)), p90 \(Format.duration(p90 ?? $0)) (\(waits.count) jobs)" } ?? "no data",
                         met: median.map { $0 <= targets.queueWaitMedianSeconds && (p90 ?? $0) <= targets.queueWaitP90Seconds },
                         basis: basis),
            ServiceLevel(id: "capacity", name: "Check runners online",
                         target: "≥ \(targets.minimumAvailableCheckRunners)",
                         measured: online.map(String.init) ?? "unknown",
                         met: online.map { $0 >= targets.minimumAvailableCheckRunners },
                         basis: fresh == nil ? "GitHub data is not current" : "this fleet's runners on GitHub now"),
            ServiceLevel(id: "detect", name: "Time to detect a dead runner",
                         target: "≤ \(Format.duration(targets.detectDeadRunnerSeconds))",
                         measured: "≤ \(Format.duration(FleetMonitor.githubInterval + FleetMonitor.probeInterval)) by design",
                         met: FleetMonitor.githubInterval + FleetMonitor.probeInterval <= targets.detectDeadRunnerSeconds,
                         basis: "GitHub read every \(Int(FleetMonitor.githubInterval)) s, hosts every \(Int(FleetMonitor.probeInterval)) s"),
            ServiceLevel(id: "machine-share", name: "Machine-caused failures",
                         target: "≤ \(Int(targets.maximumMachineFailureShare * 100))% of failed jobs",
                         measured: machineShare.map { "\(Int(($0 * 100).rounded()))% (\(ledger.machineFailures) of \(ledger.judgedFailures))" } ?? "no failures",
                         met: machineShare.map { $0 <= targets.maximumMachineFailureShare },
                         basis: basis),
            ServiceLevel(id: "interrupted", name: "Jobs interrupted by stops",
                         target: "0", measured: "\(ledger.interruptedByStops)",
                         met: ledger.windowStart == nil ? nil : ledger.interruptedByStops == 0, basis: basis),
        ]
    }

    static func percentile(_ values: [TimeInterval], _ fraction: Double) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((fraction * Double(sorted.count - 1)).rounded()))]
    }
}
