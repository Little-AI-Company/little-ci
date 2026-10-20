import Foundation

/// The desired fleet: which GitHub target, which hosts, which runners, which targets.
/// Loaded from `inventory.json`; every value is validated before any observation runs.
public struct Inventory: Codable, Sendable, Equatable {
    public var github: GitHubTarget
    public var hosts: [HostSpec]
    public var serviceLevels: ServiceLevelTargets
    public var queue: QueuePolicy

    public init(github: GitHubTarget, hosts: [HostSpec], serviceLevels: ServiceLevelTargets = .init(),
                queue: QueuePolicy = .init()) {
        self.github = github
        self.hosts = hosts
        self.serviceLevels = serviceLevels
        self.queue = queue
    }

    public static func load(from url: URL) throws -> Inventory {
        let inventory = try JSONDecoder().decode(Inventory.self, from: Data(contentsOf: url))
        try inventory.validate()
        return inventory
    }

    public func host(_ id: HostSpec.ID) -> HostSpec? { hosts.first { $0.id == id } }

    /// The host that declares a runner of this exact name.
    public func host(ofRunner name: String) -> HostSpec? {
        hosts.first { host in host.runners.contains { $0.name == name } }
    }

    public func validate() throws {
        try github.validate()
        var hostIDs = Set<String>(), runnerNames = Set<String>()
        for host in hosts {
            guard host.id.wholeMatch(of: /[a-z][a-z0-9-]{0,31}/) != nil else {
                throw InventoryError.invalid("host id \"\(host.id)\" must be lowercase letters, digits and hyphens")
            }
            guard hostIDs.insert(host.id).inserted else { throw InventoryError.invalid("host id \(host.id) appears twice") }
            for runner in host.runners {
                guard runner.name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]{0,63}/) != nil else {
                    throw InventoryError.invalid("runner name \"\(runner.name)\" is not a valid runner name")
                }
                guard runnerNames.insert(runner.name).inserted else {
                    throw InventoryError.invalid("runner \(runner.name) appears twice")
                }
                for label in runner.labels where label.isEmpty || label.count > 256 {
                    throw InventoryError.invalid("runner \(runner.name) has a label that is empty or longer than 256 characters")
                }
            }
            try validateKind(of: host)
        }
    }

    /// Every value that reaches a shell command is checked here, so a typo cannot become shell code.
    func validateKind(of host: HostSpec) throws {
        func require(_ value: String, _ pattern: Regex<Substring>, _ field: String) throws {
            guard value.wholeMatch(of: pattern) != nil else {
                throw InventoryError.invalid("host \(host.id): \(field) \"\(value)\" has characters that are not allowed")
            }
        }
        let path = /\/[A-Za-z0-9._\/-]+/, name = /[A-Za-z0-9][A-Za-z0-9._-]{0,127}/, user = /[a-z_][a-z0-9_-]{0,31}/
        switch host.kind {
        case .macLaunchd(let mac):
            try require(mac.user, user, "user")
            try require(mac.runnerRoot, path, "runnerRoot")
            try require(mac.serviceLabelPrefix, /[A-Za-z0-9][A-Za-z0-9._-]{0,127}/, "serviceLabelPrefix")
        case .orbstackVM(let vm):
            guard let parent = hosts.first(where: { $0.id == vm.parentHost }) else {
                throw InventoryError.invalid("host \(host.id) names parent host \(vm.parentHost), which is not in the inventory")
            }
            // little-ci's OrbStack wrappers run on the Mac that owns the VM, which must be this Mac.
            guard parent.access == .local, case .macLaunchd = parent.kind else {
                throw InventoryError.invalid("host \(host.id): an OrbStack VM's parent host must be this Mac (access \"local\")")
            }
            try require(vm.machine, name, "machine")
            try require(vm.runnerUser, user, "runnerUser")
            try require(vm.fleetPrefix, name, "fleetPrefix")
            try require(vm.littleCICheckout, path, "littleCICheckout")
        case .linuxServer(let server):
            try require(server.runnerUser, user, "runnerUser")
            try require(server.fleetPrefix, name, "fleetPrefix")
            try require(server.littleCICheckout, path, "littleCICheckout")
        }
        if host.runnerUser == "root" { throw InventoryError.invalid("host \(host.id): the runner user must not be root") }
    }
}

extension HostSpec {
    /// The account the runners run as.
    var runnerUser: String {
        switch kind {
        case .macLaunchd(let mac): mac.user
        case .orbstackVM(let vm): vm.runnerUser
        case .linuxServer(let server): server.runnerUser
        }
    }
}

public enum InventoryError: Error, Equatable, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self { case .invalid(let reason): "Inventory is invalid: \(reason)" }
    }
}

/// The GitHub repository or organization whose runners this fleet serves.
public struct GitHubTarget: Codable, Sendable, Equatable {
    public enum Scope: String, Codable, Sendable, CaseIterable { case repository, organization }

    public var scope: Scope
    public var owner: String
    /// The repository: the runner target in repository scope, the watched repository in organization scope.
    public var repository: String
    /// Required in organization scope, rejected in repository scope.
    public var runnerGroup: String?

    public init(scope: Scope, owner: String, repository: String, runnerGroup: String? = nil) {
        self.scope = scope
        self.owner = owner
        self.repository = repository
        self.runnerGroup = runnerGroup
    }

    public var repositoryPath: String { "repos/\(owner)/\(repository)" }
    /// The URL a runner registered to this target records in its `.runner` file.
    public var registrationURL: String {
        switch scope {
        case .repository: "https://github.com/\(owner)/\(repository)"
        case .organization: "https://github.com/\(owner)"
        }
    }
    /// Where runners, registration and removal tokens live for this scope.
    public var runnersPath: String {
        switch scope {
        case .repository: "\(repositoryPath)/actions/runners"
        case .organization: "orgs/\(owner)/actions/runners"
        }
    }

    public func validate() throws {
        let slug = /[A-Za-z0-9][A-Za-z0-9._-]{0,99}/
        guard owner.wholeMatch(of: slug) != nil, repository.wholeMatch(of: slug) != nil else {
            throw InventoryError.invalid("GitHub owner and repository must be plain GitHub names")
        }
        switch scope {
        case .repository where runnerGroup != nil:
            throw InventoryError.invalid("runnerGroup is only valid in organization scope")
        case .organization where (runnerGroup ?? "").trimmingCharacters(in: .whitespaces).isEmpty:
            throw InventoryError.invalid("organization scope requires a nonblank runnerGroup")
        default: break
        }
    }
}

public struct HostSpec: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: HostKind
    public var access: HostAccess
    /// A lendable host takes CI only while lent; while not lent the app refuses to start its runners.
    public var lendable: Bool
    /// Most jobs this host should run at once, when it has a limit (M4: 2).
    public var maxConcurrentJobs: Int?
    public var runners: [RunnerSpec]

    public init(id: String, name: String, kind: HostKind, access: HostAccess, lendable: Bool = false,
                maxConcurrentJobs: Int? = nil, runners: [RunnerSpec]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.access = access
        self.lendable = lendable
        self.maxConcurrentJobs = maxConcurrentJobs
        self.runners = runners
    }
}

public struct RunnerSpec: Codable, Sendable, Equatable {
    public var name: String
    public var labels: [String]

    public init(name: String, labels: [String]) {
        self.name = name
        self.labels = labels
    }
}

/// How a host runs its runners. The VM layer is one case, so another VM provider is one more case.
public enum HostKind: Codable, Sendable, Equatable {
    /// A Mac with native launchd agents: `<serviceLabelPrefix><name>`, `<runnerRoot>/<name>/.env` and `.path`.
    case macLaunchd(MacLaunchdHost)
    /// A Linux VM on a Mac, provisioned by little-ci (identity file, scratch, reaper).
    case orbstackVM(OrbStackVMHost)
    /// A remote Linux server with systemd units, provisioned by little-ci.
    case linuxServer(LinuxServerHost)

    private enum CodingKeys: String, CodingKey { case type }
    private enum KindName: String, Codable { case macLaunchd, orbstackVM, linuxServer }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(KindName.self, forKey: .type) {
        case .macLaunchd: self = .macLaunchd(try MacLaunchdHost(from: decoder))
        case .orbstackVM: self = .orbstackVM(try OrbStackVMHost(from: decoder))
        case .linuxServer: self = .linuxServer(try LinuxServerHost(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .macLaunchd(let host): try container.encode(KindName.macLaunchd, forKey: .type); try host.encode(to: encoder)
        case .orbstackVM(let host): try container.encode(KindName.orbstackVM, forKey: .type); try host.encode(to: encoder)
        case .linuxServer(let host): try container.encode(KindName.linuxServer, forKey: .type); try host.encode(to: encoder)
        }
    }
}

public struct MacLaunchdHost: Codable, Sendable, Equatable {
    public var user: String
    public var runnerRoot: String
    public var serviceLabelPrefix: String

    public init(user: String, runnerRoot: String, serviceLabelPrefix: String) {
        self.user = user
        self.runnerRoot = runnerRoot
        self.serviceLabelPrefix = serviceLabelPrefix
    }

    public func serviceLabel(of runner: String) -> String { serviceLabelPrefix + runner }
}

public struct OrbStackVMHost: Codable, Sendable, Equatable {
    /// The Mac host that runs the VM.
    public var parentHost: String
    public var machine: String
    /// little-ci's `RUNNER_USER` inside the guest.
    public var runnerUser: String
    /// little-ci's derived runner prefix for this fleet.
    public var fleetPrefix: String
    /// A little-ci checkout on the parent Mac whose `config.env` describes this fleet.
    public var littleCICheckout: String

    public init(parentHost: String, machine: String, runnerUser: String, fleetPrefix: String, littleCICheckout: String) {
        self.parentHost = parentHost
        self.machine = machine
        self.runnerUser = runnerUser
        self.fleetPrefix = fleetPrefix
        self.littleCICheckout = littleCICheckout
    }
}

public struct LinuxServerHost: Codable, Sendable, Equatable {
    public var runnerUser: String
    public var fleetPrefix: String
    /// A little-ci checkout on the server whose `config.env` describes this fleet.
    public var littleCICheckout: String

    public init(runnerUser: String, fleetPrefix: String, littleCICheckout: String) {
        self.runnerUser = runnerUser
        self.fleetPrefix = fleetPrefix
        self.littleCICheckout = littleCICheckout
    }
}

/// How this Mac reaches a host: run locally, or over OpenSSH in batch mode.
public enum HostAccess: Codable, Sendable, Equatable, CustomStringConvertible {
    case local
    case ssh(destination: String)

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        if text == "local" {
            self = .local
        } else if text.hasPrefix("ssh:"), let destination = Optional(String(text.dropFirst(4))),
                  // A leading "-" would be read by ssh as an option.
                  destination.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9._-]*(@[A-Za-z0-9][A-Za-z0-9._-]*)?/) != nil {
            self = .ssh(destination: destination)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "access must be \"local\" or \"ssh:user@host\""))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String {
        switch self {
        case .local: "local"
        case .ssh(let destination): "ssh:\(destination)"
        }
    }
}

/// Targets from the Phase 1 report. Each is checked against measured values.
public struct ServiceLevelTargets: Codable, Sendable, Equatable {
    public var queueWaitMedianSeconds: Double = 120
    public var queueWaitP90Seconds: Double = 900
    public var minimumAvailableCheckRunners: Int = 4
    public var detectDeadRunnerSeconds: Double = 120
    public var maximumMachineFailureShare: Double = 0.05

    public init() {}
}

/// How the queue pane groups runs, and which runs need a second confirmation to cancel.
public struct QueuePolicy: Codable, Sendable, Equatable {
    /// Branch name prefixes of platform and parity work (cancelling these needs an extra confirmation).
    public var platformBranchPrefixes: [String] = ["platform", "parity"]
    /// Branch name prefixes of performance lanes.
    public var performanceBranchPrefixes: [String] = ["webapp-perf", "desktop-perf", "iphone-perf", "perf/"]
    /// The workflow whose runs and jobs make up the check pool.
    public var checkWorkflow: String = "CI"
    public var checkLabel: String = "little-ci"

    public init() {}
}
