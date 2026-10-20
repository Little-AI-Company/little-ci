import Foundation

// MARK: GitHub

/// A runner as GitHub's runner API reports it.
public struct GitHubRunner: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable, CaseIterable { case online, offline }
    public struct Label: Codable, Sendable, Equatable { public var name: String }

    public var id: Int
    public var name: String
    public var status: Status
    public var busy: Bool
    public var labels: [Label]

    public var labelNames: [String] { labels.map(\.name) }
}

public struct WorkflowRun: Codable, Sendable, Equatable, Identifiable {
    public struct PullRequestReference: Codable, Sendable, Equatable { public var number: Int }
    public struct Repository: Codable, Sendable, Equatable { public var fullName: String }

    public var id: Int
    public var name: String
    /// Stable per workflow file; two workflows can share a display name.
    public var workflowId: Int?
    public var event: String
    public var status: String
    public var conclusion: String?
    public var headBranch: String?
    /// The repository the head branch lives in: a fork's name differs from the base repository's.
    public var headRepository: Repository?
    public var headSha: String
    public var displayTitle: String
    public var createdAt: Date
    public var runStartedAt: Date?
    public var runAttempt: Int
    public var updatedAt: Date?
    public var pullRequests: [PullRequestReference]
    public var htmlUrl: String

    public var isActive: Bool { ["queued", "in_progress", "waiting", "pending", "requested"].contains(status) }
}

public struct WorkflowJob: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var runId: Int
    public var name: String
    public var status: String
    public var conclusion: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var runnerName: String?
    public var labels: [String]
    public var headSha: String
    public var headBranch: String?
    public var runAttempt: Int

    /// A rerun attempt copies the jobs it did not rerun, keeping the old start time. Those copies are not new work.
    public var isCarriedOverCopy: Bool {
        guard let startedAt else { return false }
        return startedAt < createdAt.addingTimeInterval(-2)
    }

    /// The job took a runner (a named self-hosted runner, not a skipped or never-started job).
    public var tookRunner: Bool {
        guard let runnerName, !runnerName.isEmpty, startedAt != nil else { return false }
        return !isCarriedOverCopy
    }

    public var queueWait: TimeInterval? {
        guard tookRunner, let startedAt else { return nil }
        return startedAt.timeIntervalSince(createdAt)
    }

    public var duration: TimeInterval? {
        guard tookRunner, let startedAt, let completedAt else { return nil }
        return completedAt.timeIntervalSince(startedAt)
    }
}

public struct PullRequestState: Codable, Sendable, Equatable {
    public var number: Int
    public var state: String
    public var merged: Bool
    public var headBranch: String

    public init(number: Int, state: String, merged: Bool, headBranch: String) {
        self.number = number
        self.state = state
        self.merged = merged
        self.headBranch = headBranch
    }

    public var isOpen: Bool { state == "open" }
}

/// What the workflow and package.json ask of each runner's toolchain.
public struct ToolchainRequirement: Codable, Sendable, Equatable {
    public var bunVersion: String?
    public var minimumNodeMajor: Int?

    public init(bunVersion: String?, minimumNodeMajor: Int?) {
        self.bunVersion = bunVersion
        self.minimumNodeMajor = minimumNodeMajor
    }
}

/// One read of GitHub at one moment.
public struct GitHubSnapshot: Codable, Sendable, Equatable {
    public var observedAt: Date
    public var runners: [GitHubRunner]
    /// Runs that are queued, waiting or in progress.
    public var activeRuns: [WorkflowRun]
    /// Jobs of the active runs.
    public var activeJobs: [WorkflowJob]
    /// The newest runs of the check workflow on main that passed or failed (cancelled runs say nothing), newest first.
    public var recentMainRuns: [WorkflowRun]
    /// Failed jobs of the newest completed main run.
    public var redMainJobs: [String]
    /// Pull requests by head branch. A branch with any open PR maps to an open one.
    public var pullRequests: [String: PullRequestState]
    public var toolchain: ToolchainRequirement?

    public init(observedAt: Date, runners: [GitHubRunner], activeRuns: [WorkflowRun] = [], activeJobs: [WorkflowJob] = [],
                recentMainRuns: [WorkflowRun] = [], redMainJobs: [String] = [], pullRequests: [String: PullRequestState] = [:],
                toolchain: ToolchainRequirement? = nil) {
        self.observedAt = observedAt
        self.runners = runners
        self.activeRuns = activeRuns
        self.activeJobs = activeJobs
        self.recentMainRuns = recentMainRuns
        self.redMainJobs = redMainJobs
        self.pullRequests = pullRequests
        self.toolchain = toolchain
    }

    public func runner(named name: String) -> GitHubRunner? { runners.first { $0.name == name } }
}

// MARK: Hosts

/// All health facts one probe round trip returned.
public struct HostFacts: Codable, Sendable, Equatable {
    public var probeVersion: Int
    public var observedAt: Date
    public var hostname: String
    public var userID: Int?
    public var cpuCount: Int?
    public var memoryBytes: Int64?
    /// 1, 5 and 15 minute load averages.
    public var loadAverage: [Double]
    public var memoryFreePercent: Int?
    public var swapUsedBytes: Int64?
    public var swapTotalBytes: Int64?
    public var onACPower: Bool?
    public var volumes: [VolumeFacts]
    public var docker: DockerFacts?
    public var orbstack: OrbStackFacts?
    /// For a VM host: the VM's OrbStack settings and little-ci identity, read on the parent Mac.
    public var virtualMachine: OrbStackVMFacts?
    public var runners: [RunnerServiceFacts]
    public var recentPowerEvents: [PowerEvent]

    public var loadPerCore: Double? {
        guard let cpuCount, cpuCount > 0, let first = loadAverage.first else { return nil }
        return first / Double(cpuCount)
    }

    public func runner(named name: String) -> RunnerServiceFacts? { runners.first { $0.name == name } }
}

public struct VolumeFacts: Codable, Sendable, Equatable {
    public var device: String
    public var mountPoint: String
    public var totalBytes: Int64
    public var availableBytes: Int64
    public var isReadOnly: Bool

    /// Simulator runtimes and other read-only images are always full by design.
    public var countsForHealth: Bool {
        guard !isReadOnly, totalBytes > 0 else { return false }
        if mountPoint == "/System/Volumes/Data" { return true }
        let ignoredDevices = ["tmpfs", "devtmpfs", "efivarfs", "overlay", "shm", "udev", "none"]
        let ignoredPrefixes = ["/Library/Developer/CoreSimulator/", "/private/var/run/com.apple.security.cryptexd/",
                               "/System/Volumes/", "/Volumes/Recovery", "/dev", "/run", "/sys", "/proc", "/snap/", "/boot/efi"]
        return !ignoredDevices.contains(device) && !device.hasPrefix("devices --")
            && !ignoredPrefixes.contains { mountPoint.hasPrefix($0) }
    }

    public var usedFraction: Double {
        // df's capacity: used / (used + available), which ignores space reserved for root.
        let used = Double(max(0, totalBytes - availableBytes))
        return used / Double(totalBytes)
    }
}

public struct DockerFacts: Codable, Sendable, Equatable {
    public var socketPath: String
    public var socketExists: Bool
    public var serverVersion: String?
    public var error: String?
    public var composeVersion: String?

    public var isServing: Bool { serverVersion != nil }
}

public struct OrbStackFacts: Codable, Sendable, Equatable {
    public var version: String?
    public var status: String?
    /// The last start in vmgr.log failed to mount OrbStack's data disk.
    public var dataMountFailed: Bool
    public var lastStartAt: String?
    public var evidence: [String]
}

public struct RunnerServiceFacts: Codable, Sendable, Equatable {
    public enum ServiceState: Codable, Sendable, Equatable {
        case running(pid: Int)
        case loadedNotRunning(lastExitCode: Int?)
        case notLoaded
        case unknown(String)

        public var isRunning: Bool { if case .running = self { true } else { false } }
    }

    public var name: String
    public var directoryExists: Bool
    /// From the runner's `.runner` file; only the URL and name are read, never credentials.
    public var registeredURL: String?
    /// The runner name in `.runner` (`agentName`).
    public var registeredName: String?
    public var serviceDefinitionExists: Bool
    public var service: ServiceState
    public var bunVersion: String?
    public var nodeVersion: String?
}

public struct PowerEvent: Codable, Sendable, Equatable {
    public var at: Date
    public var kind: String
    public var reason: String
}

/// The result of one attempt to probe a host. A failed attempt keeps the reason; the last facts stay visible.
public struct HostObservation: Codable, Sendable, Equatable {
    public enum Outcome: Codable, Sendable, Equatable {
        case reached(HostFacts)
        case unreachable(String)
    }

    public var hostID: String
    public var attemptedAt: Date
    public var outcome: Outcome
    public var lastFacts: HostFacts?

    public init(hostID: String, attemptedAt: Date, outcome: Outcome, lastFacts: HostFacts? = nil) {
        self.hostID = hostID
        self.attemptedAt = attemptedAt
        self.outcome = outcome
        self.lastFacts = lastFacts
    }

    public var facts: HostFacts? {
        if case .reached(let facts) = outcome { facts } else { nil }
    }
}
