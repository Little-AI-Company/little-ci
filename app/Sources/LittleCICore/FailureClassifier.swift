import Foundation

/// Why a job failed: the machine, the code, or not enough evidence. Signatures come from the
/// 2026-10-20 measurement (reports/phase1-measurement.md).
public struct FailureClass: Codable, Sendable, Equatable {
    public enum Cause: String, Codable, Sendable, CaseIterable { case machine, code, unsure, derived }

    public var cause: Cause
    public var reason: String
    /// The log line that matched, when one did.
    public var evidence: String?

    public init(cause: Cause, reason: String, evidence: String? = nil) {
        self.cause = cause
        self.reason = reason
        self.evidence = evidence
    }
}

public enum FailureClassifier {
    struct Signature {
        var reason: String
        var pattern: Regex<AnyRegexOutput>
    }

    nonisolated(unsafe) static let machineSignatures: [Signature] = [
        .init(reason: "runner lost", pattern: try! Regex(#"lost communication with the server|received a shutdown signal"#)),
        .init(reason: "Docker down", pattern: try! Regex(#"failed to connect to the docker API.*no such file|error during connect: .*docker\.sock.*: EOF"#)),
        .init(reason: "toolchain drift", pattern: try! Regex(#"has Bun \S+; package\.json asks for|needs Node \d+ or newer"#)),
        .init(reason: "Docker Compose missing", pattern: try! Regex(#"unknown shorthand flag: 'f' in -f"#)),
        .init(reason: "network", pattern: try! Regex(#"Failed to download action .*SSL connection could not be established"#)),
        .init(reason: "disk full", pattern: try! Regex(#"No space left on device|ENOSPC"#)),
        .init(reason: "OrbStack data not mounted", pattern: try! Regex(#"OrbStack data could not be mounted"#)),
    ]

    nonisolated(unsafe) static let testTimeout = try! Regex(#"timed out after 5000ms"#)

    /// Facts about the same commit's other attempts, which turn an ambiguous failure into a machine one.
    public struct Context: Sendable {
        public var passedOnAnotherHost: Bool
        public var passedOnRerun: Bool

        public init(passedOnAnotherHost: Bool = false, passedOnRerun: Bool = false) {
            self.passedOnAnotherHost = passedOnAnotherHost
            self.passedOnRerun = passedOnRerun
        }
    }

    /// `aggregateJobNames` are jobs that only report other jobs' results (CI's "Check").
    public static func classify(_ job: WorkflowJob, log: String?, annotations: [String] = [], context: Context = .init(),
                                aggregateJobNames: Set<String> = ["Check", "Run failed main jobs again"]) -> FailureClass {
        if aggregateJobNames.contains(job.name) { return .init(cause: .derived, reason: "reports other jobs") }
        let printed = printedOutput(log ?? "") + annotations
        let text = printed.joined(separator: "\n")
        for signature in machineSignatures {
            if let match = printed.first(where: { $0.contains(signature.pattern) }) {
                return .init(cause: .machine, reason: signature.reason, evidence: String(match.prefix(300)))
            }
        }
        if let duration = job.duration, duration < 30, context.passedOnAnotherHost {
            return .init(cause: .machine, reason: "host-specific: under 30 s, same commit passed on another host")
        }
        let timedOut = text.contains(testTimeout)
        if timedOut, context.passedOnRerun { return .init(cause: .machine, reason: "load: 5 s test timeout that passed on rerun") }
        if text.contains("The operation was canceled") { return .init(cause: .unsure, reason: "reached the job time limit") }
        if log == nil { return .init(cause: .unsure, reason: "no log") }
        if timedOut { return .init(cause: .unsure, reason: "5 s test timeout, no passing rerun yet") }
        return .init(cause: .code, reason: "test, lint or typecheck output")
    }

    /// Lines the job printed. GitHub's log also echoes each step's script (in cyan) and its header;
    /// error text inside a script is not an error, so those lines are dropped.
    public static func printedOutput(_ log: String) -> [String] {
        log.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            var text = Substring(line)
            if let space = text.firstIndex(of: " "), text[..<space].hasSuffix("Z") { text = text[text.index(after: space)...] }
            if text.hasPrefix("\u{1B}[36;1m") || text.hasPrefix("##[group]Run ") { return nil }
            return String(text)
        }
    }
}
