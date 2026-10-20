import Foundation

public enum Severity: String, Codable, Sendable, Comparable, CaseIterable {
    case info, warning, critical

    var rank: Int { Severity.allCases.firstIndex(of: self)! }
    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
}

/// What a finding or event is about.
public enum Subject: Codable, Sendable, Hashable, CustomStringConvertible {
    case fleet
    case host(String)
    case runner(String)
    case run(Int)

    public var description: String {
        switch self {
        case .fleet: "fleet"
        case .host(let id): "host \(id)"
        case .runner(let name): "runner \(name)"
        case .run(let id): "run \(id)"
        }
    }
}

/// One thing that is wrong now, the evidence for it, and what to do.
public struct Finding: Codable, Sendable, Equatable, Identifiable {
    /// Stable across observations while the condition lasts, so events record start and end once.
    public var id: String
    public var severity: Severity
    public var subject: Subject
    public var title: String
    public var evidence: [String]
    public var suggestedAction: String
    public var planIDs: [String]

    public init(id: String, severity: Severity, subject: Subject, title: String, evidence: [String],
                suggestedAction: String, planIDs: [String] = []) {
        self.id = id
        self.severity = severity
        self.subject = subject
        self.title = title
        self.evidence = evidence
        self.suggestedAction = suggestedAction
        self.planIDs = planIDs
    }
}

/// A token the executor obtains in memory and writes to one command's standard input.
public enum TokenKind: String, Codable, Sendable, CaseIterable { case registration, removal }

public enum PlanAction: Codable, Sendable, Equatable {
    /// A shell command on a host (locally or over SSH). With a token, its first stdin line is the token.
    case hostCommand(hostID: String, command: String, token: TokenKind?)
    /// A local command on this Mac in a working directory (little-ci's Mac wrappers).
    case localCommand(CommandInvocation)
    case cancelRun(id: Int)
    case deleteRunnerRegistration(id: Int, name: String)
}

public struct PlanStep: Codable, Sendable, Equatable {
    public var description: String
    public var action: PlanAction

    public init(_ description: String, _ action: PlanAction) {
        self.description = description
        self.action = action
    }
}

/// A condition that must hold, re-read from GitHub and the host, immediately before a plan runs.
public enum Precondition: Codable, Sendable, Hashable, CustomStringConvertible {
    case runnerIdle(name: String)
    case runnerOffline(name: String)
    case runnerRegistered(name: String)
    case serviceNotRunning(hostID: String, runner: String)
    case hostMayTakeJobs(hostID: String)
    case runActive(id: Int)
    case fleetIdle(prefix: String)

    public var description: String {
        switch self {
        case .runnerIdle(let name): "GitHub reports \(name) idle (not busy)"
        case .runnerOffline(let name): "GitHub reports \(name) offline"
        case .runnerRegistered(let name): "\(name) is registered on GitHub"
        case .serviceNotRunning(let host, let runner): "\(runner)'s service is not running on \(host)"
        case .hostMayTakeJobs(let host): "\(host) is lent to CI, or is not a lendable host"
        case .runActive(let id): "run \(id) is still queued or in progress"
        case .fleetIdle(let prefix): "no runner named \(prefix)-* is busy on GitHub"
        }
    }
}

/// Exact commands, their effect, and what must be true first. Runs only after the user confirms.
public struct Plan: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var subject: Subject
    public var effect: String
    public var steps: [PlanStep]
    public var preconditions: [Precondition]
    /// Platform runs and machine deletion ask twice.
    public var requiresSecondConfirmation: Bool

    public init(id: String, title: String, subject: Subject, effect: String, steps: [PlanStep],
                preconditions: [Precondition], requiresSecondConfirmation: Bool = false) {
        self.id = id
        self.title = title
        self.subject = subject
        self.effect = effect
        self.steps = steps
        self.preconditions = preconditions
        self.requiresSecondConfirmation = requiresSecondConfirmation
    }
}

public struct FleetEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case findingRaised, findingCleared, planExecuted, planFailed, hostReached, hostLost }

    public var id: UUID
    public var at: Date
    public var kind: Kind
    public var subject: Subject
    public var severity: Severity?
    public var title: String
    public var detail: String?

    public init(at: Date, kind: Kind, subject: Subject, severity: Severity? = nil, title: String, detail: String? = nil) {
        self.id = UUID()
        self.at = at
        self.kind = kind
        self.subject = subject
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

public struct ServiceLevel: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var target: String
    public var measured: String
    /// Nil when there is not enough data yet.
    public var met: Bool?
    public var basis: String
}

/// Which kind of work a run is, for the queue pane.
public enum QueueLane: String, Codable, Sendable, CaseIterable {
    case main, pullRequest, platform, performance, other

    public var title: String {
        switch self {
        case .main: "main"
        case .pullRequest: "PRs into main"
        case .platform: "platform and parity"
        case .performance: "perf lanes"
        case .other: "other"
        }
    }

    public static func of(_ run: WorkflowRun, policy: QueuePolicy) -> QueueLane {
        let branch = run.headBranch ?? ""
        if branch == "main" { return .main }
        if policy.platformBranchPrefixes.contains(where: branch.hasPrefix) { return .platform }
        if policy.performanceBranchPrefixes.contains(where: branch.hasPrefix) { return .performance }
        if run.event == "pull_request" { return .pullRequest }
        return .other
    }
}

public struct QueueEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Disposition: String, Codable, Sendable, CaseIterable { case superseded, pullRequestClosed, likelyRedOnMain }

    public var run: WorkflowRun
    public var lane: QueueLane
    public var dispositions: [Disposition]
    public var id: Int { run.id }
}

/// Everything the UI and the API show, derived without I/O from one set of observations.
public struct Assessment: Codable, Sendable, Equatable {
    public var assessedAt: Date
    public var findings: [Finding]
    public var plans: [Plan]
    public var queue: [QueueEntry]
    public var serviceLevels: [ServiceLevel]

    public var worstSeverity: Severity? { findings.map(\.severity).max() }
    public func plan(_ id: String) -> Plan? { plans.first { $0.id == id } }
}
