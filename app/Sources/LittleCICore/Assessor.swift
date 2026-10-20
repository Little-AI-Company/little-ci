import Foundation

/// Everything one assessment reads. Assembled by `FleetMonitor`, recorded as fixtures in tests.
public struct FleetObservations: Codable, Sendable, Equatable {
    public var inventory: Inventory
    public var github: GitHubSnapshot?
    public var githubError: String?
    public var hosts: [String: HostObservation]
    /// Lendable hosts currently lent to CI.
    public var lentHosts: Set<String>
    public var ledger: LedgerSummary
    /// Finding IDs active in the previous assessment, for thresholds that clear higher than they raise.
    public var previouslyActive: Set<String>

    public init(inventory: Inventory, github: GitHubSnapshot?, githubError: String? = nil, hosts: [String: HostObservation],
                lentHosts: Set<String> = [], ledger: LedgerSummary = .empty, previouslyActive: Set<String> = []) {
        self.inventory = inventory
        self.github = github
        self.githubError = githubError
        self.hosts = hosts
        self.lentHosts = lentHosts
        self.ledger = ledger
        self.previouslyActive = previouslyActive
    }
}

/// observe -> compare with the inventory -> findings and plans. No I/O, so recorded incidents replay exactly.
public enum Assessor {
    /// Observations older than this are stale: shown with their age, never read as "offline" or "healthy".
    public static let staleAfter: TimeInterval = 150
    static let diskCriticalFree = 0.05, diskWarningFree = 0.10, diskClearFree = 0.12
    static let loadWarningPerCore = 3.0, loadCriticalPerCore = 8.0
    static let stallAfter: TimeInterval = 300

    public static func assess(_ observations: FleetObservations, now: Date) -> Assessment {
        var builder = Builder(observations: observations, now: now)
        builder.assessGitHub()
        for host in observations.inventory.hosts { builder.assess(host) }
        builder.assessFleet()
        builder.assessQueue()
        let findings = builder.findings.sorted { ($0.severity, $1.id) > ($1.severity, $0.id) }
        return Assessment(assessedAt: now, findings: findings, plans: builder.plans, queue: builder.queue,
                          serviceLevels: ServiceLevelCalculator.levels(observations, now: now))
    }

    struct Builder {
        let observations: FleetObservations
        let now: Date
        var findings: [Finding] = []
        var plans: [Plan] = []
        var queue: [QueueEntry] = []

        var inventory: Inventory { observations.inventory }
        var github: GitHubSnapshot? {
            guard let snapshot = observations.github, now.timeIntervalSince(snapshot.observedAt) <= Assessor.staleAfter else { return nil }
            return snapshot
        }

        mutating func add(_ finding: Finding, plans newPlans: [Plan] = []) {
            guard !findings.contains(where: { $0.id == finding.id }) else { return }
            var finding = finding
            for plan in newPlans where !plans.contains(where: { $0.id == plan.id }) { plans.append(plan) }
            finding.planIDs = newPlans.map(\.id)
            findings.append(finding)
        }

        // MARK: GitHub

        mutating func assessGitHub() {
            if github == nil {
                let reason = observations.githubError ?? observations.github.map {
                    "last read \(Int(now.timeIntervalSince($0.observedAt))) s ago" } ?? "not read yet"
                add(Finding(id: "github.unavailable", severity: .warning, subject: .fleet,
                            title: "GitHub runner and queue data is not current",
                            evidence: [reason], suggestedAction: "Check `gh auth status` and the network. Runner states are unknown until GitHub is read."))
            }
        }

        // MARK: Hosts

        mutating func assess(_ host: HostSpec) {
            let mayTakeJobs = !host.lendable || observations.lentHosts.contains(host.id)
            guard let observation = observations.hosts[host.id] else { return }
            let onlineOnGitHub = host.runners.compactMap { github?.runner(named: $0.name) }.filter { $0.status == .online }

            guard let facts = observation.facts, now.timeIntervalSince(facts.observedAt) <= Assessor.staleAfter else {
                let reason: String = switch observation.outcome {
                case .unreachable(let message): message
                case .reached(let facts): "last probe \(Int(now.timeIntervalSince(facts.observedAt))) s ago"
                }
                if github == nil {
                    add(Finding(id: "host.\(host.id).unreachable", severity: .warning, subject: .host(host.id),
                                title: "\(host.name) cannot be probed and GitHub's view of its runners is unknown",
                                evidence: [reason], suggestedAction: "Check SSH to \(host.access) and the GitHub read."))
                } else if onlineOnGitHub.isEmpty {
                    add(Finding(id: "host.\(host.id).away", severity: .info, subject: .host(host.id), title: "\(host.name) is away",
                                evidence: [reason, "GitHub shows none of its runners online"],
                                suggestedAction: "Nothing to do. It takes jobs again when it is back."))
                } else {
                    add(Finding(id: "host.\(host.id).unreachable", severity: .warning, subject: .host(host.id),
                                title: "\(host.name) cannot be probed while \(onlineOnGitHub.count) of its runners are online",
                                evidence: [reason], suggestedAction: "Check SSH to \(host.access). Health facts are unknown until it answers."))
                }
                assessRunnersWithoutFacts(host, mayTakeJobs: mayTakeJobs)
                return
            }

            assessDisks(host, facts)
            assessLoad(host, facts)
            assessDocker(host, facts, runnersOnline: onlineOnGitHub)
            assessPower(host, facts, runnersOnline: onlineOnGitHub)
            for runner in host.runners { assess(runner, on: host, facts: facts, mayTakeJobs: mayTakeJobs) }
            switch host.kind {
            case .macLaunchd:
                // Retire only a runner whose own registration names this target and this exact runner.
                plans += host.runners.compactMap { runner in
                    owns(facts.runner(named: runner.name), runner.name) ? PlanFactory.retireLaunchdRunner(host, runner.name, inventory: inventory) : nil }
            case .orbstackVM(let vm):
                switch assessVirtualMachine(host, vm, facts) {
                case .absent: plans += PlanFactory.lifecyclePlans(host, inventory: inventory, machineExists: false)
                case .matches: plans += PlanFactory.lifecyclePlans(host, inventory: inventory)
                case .mismatched: break
                }
            case .linuxServer:
                plans += PlanFactory.lifecyclePlans(host, inventory: inventory)
            }
        }

        mutating func assessDisks(_ host: HostSpec, _ facts: HostFacts) {
            // Volumes in one APFS container (or one filesystem) report the same numbers: one finding for them.
            let groups = Dictionary(grouping: facts.volumes.filter(\.countsForHealth)) { "\($0.totalBytes)/\($0.availableBytes)" }
            for volumes in groups.values {
                // Name the container by its main volume: macOS's Data volume, then the shortest mount point.
                let volume = volumes.first { $0.mountPoint == "/System/Volumes/Data" }
                    ?? volumes.sorted { $0.mountPoint.count < $1.mountPoint.count }[0]
                let free = 1 - volume.usedFraction
                let id = "disk.\(host.id).\(volume.mountPoint)"
                let wasActive = observations.previouslyActive.contains(id)
                let severity: Severity? = if free < Assessor.diskCriticalFree { .critical }
                    else if free < Assessor.diskWarningFree || (wasActive && free < Assessor.diskClearFree) { .warning }
                    else { nil }
                guard let severity else { continue }
                let mounts = volumes.map(\.mountPoint).sorted().joined(separator: ", ")
                add(Finding(id: id, severity: severity, subject: .host(host.id),
                            title: "\(host.name) \(volume.mountPoint) is \(Int((volume.usedFraction * 100).rounded()))% full",
                            evidence: ["\(Format.bytes(volume.availableBytes)) free of \(Format.bytes(volume.totalBytes)) (\(mounts))"],
                            suggestedAction: "Free space before jobs fail with \"No space left on device\": runner _work folders, Docker images (`docker system df`), simulators, DerivedData."))
            }
        }

        mutating func assessLoad(_ host: HostSpec, _ facts: HostFacts) {
            if let perCore = facts.loadPerCore, perCore >= Assessor.loadWarningPerCore, let cores = facts.cpuCount {
                add(Finding(id: "load.\(host.id)", severity: perCore >= Assessor.loadCriticalPerCore ? .critical : .warning,
                            subject: .host(host.id), title: "\(host.name) load is \(Format.decimal(perCore)) per core",
                            evidence: ["load average \(facts.loadAverage.map(Format.decimal).joined(separator: " ")) on \(cores) cores",
                                       "tests with short timeouts fail under load"],
                            suggestedAction: "Lower this host's concurrent jobs, or pause heavy local work while it takes CI."))
            }
            if let used = facts.swapUsedBytes, let total = facts.swapTotalBytes, total > 0, Double(used) / Double(total) > 0.8 {
                add(Finding(id: "swap.\(host.id)", severity: .warning, subject: .host(host.id),
                            title: "\(host.name) swap is \(Int(Double(used) / Double(total) * 100))% used",
                            evidence: ["\(Format.bytes(used)) of \(Format.bytes(total)) swap", "memory free \(facts.memoryFreePercent.map { "\($0)%" } ?? "unknown")"],
                            suggestedAction: "Memory is short. Fewer concurrent jobs or less local work on this host."))
            }
        }

        mutating func assessDocker(_ host: HostSpec, _ facts: HostFacts, runnersOnline: [GitHubRunner]) {
            let fleetCheckRunners = Set(github.map { inventory.checkRunners(in: $0).map(\.name) } ?? [])
            let checkRunnersOnline = runnersOnline.filter { fleetCheckRunners.contains($0.name) }
            let ownedCheckRunners = checkRunnersOnline.filter { owns(facts.runner(named: $0.name), $0.name) }
            if let orbstack = facts.orbstack, orbstack.dataMountFailed {
                add(Finding(id: "orbstack.\(host.id).data", severity: .critical, subject: .host(host.id),
                            title: "OrbStack data could not be mounted on \(host.name)",
                            evidence: orbstack.evidence + (orbstack.lastStartAt.map { ["last start \($0)"] } ?? []),
                            suggestedAction: "Open OrbStack and follow its recovery mode; back up what it can still read. Docker and every VM on this Mac stay down until it mounts."),
                    plans: PlanFactory.drainIdleRunners(host, ownedCheckRunners, reason: "OrbStack's data disk is not mounted"))
            }
            guard let docker = facts.docker else { return }
            if !docker.isServing {
                let evidence = [docker.socketExists ? "\(docker.socketPath) exists but the daemon does not answer" : "\(docker.socketPath) does not exist"]
                    + (docker.error.map { [String($0.prefix(200))] } ?? [])
                if checkRunnersOnline.isEmpty {
                    add(Finding(id: "docker.\(host.id)", severity: .warning, subject: .host(host.id), title: "Docker is down on \(host.name)",
                                evidence: evidence, suggestedAction: "Start OrbStack before this host takes jobs that need Docker."),
                        plans: PlanFactory.startOrbStack(host))
                } else {
                    add(Finding(id: "docker.\(host.id)", severity: .critical, subject: .host(host.id),
                                title: "Docker is down on \(host.name) while \(checkRunnersOnline.count) check runners take jobs",
                                evidence: evidence + ["jobs that start a database container fail within seconds"],
                                suggestedAction: "Start OrbStack, or stop this host's idle check runners until Docker answers."),
                        plans: PlanFactory.startOrbStack(host) + PlanFactory.drainIdleRunners(host, ownedCheckRunners, reason: "Docker is down"))
                }
            } else if docker.composeVersion == nil, !checkRunnersOnline.isEmpty {
                add(Finding(id: "compose.\(host.id)", severity: .critical, subject: .host(host.id),
                            title: "Docker Compose is missing on \(host.name)",
                            evidence: ["`docker compose version` failed with the runners' PATH",
                                       "database suites fail with \"unknown shorthand flag: 'f' in -f\""],
                            suggestedAction: "Install the Compose plugin (OrbStack includes it; check the runners' .path finds OrbStack's docker)."),
                    plans: PlanFactory.drainIdleRunners(host, ownedCheckRunners, reason: "Docker Compose is missing"))
            }
        }

        mutating func assessPower(_ host: HostSpec, _ facts: HostFacts, runnersOnline: [GitHubRunner]) {
            let recentSleeps = facts.recentPowerEvents.filter { $0.kind == "Sleep" && now.timeIntervalSince($0.at) < 3600 }
            guard !recentSleeps.isEmpty, !runnersOnline.isEmpty else { return }
            add(Finding(id: "sleep.\(host.id)", severity: .warning, subject: .host(host.id),
                        title: "\(host.name) slept \(recentSleeps.count) times in the last hour with runners online",
                        evidence: recentSleeps.suffix(3).map { "\(Format.time($0.at)) \($0.reason)" },
                        suggestedAction: "`caffeinate -s` does not block software sleep requests. Check what requested sleep (pmset -g log), and keep the lid open on power."))
        }

        enum MachineState { case absent, matches, mismatched }

        /// little-ci's isolation invariants, checked on every observation.
        mutating func assessVirtualMachine(_ host: HostSpec, _ vm: OrbStackVMHost, _ facts: HostFacts) -> MachineState {
            guard let machine = facts.virtualMachine else { return .mismatched }
            if machine.machineState == .unreadable {
                add(Finding(id: "vm.\(host.id).identity", severity: .critical, subject: .host(host.id),
                            title: "OrbStack machine \(vm.machine) could not be read", evidence: ["orbctl info failed or returned unreadable JSON"],
                            suggestedAction: "No plan is offered until orbctl info reads cleanly. Check OrbStack."))
                return .mismatched
            }
            guard machine.machineState == .present else {
                add(Finding(id: "vm.\(host.id).absent", severity: .info, subject: .host(host.id),
                            title: "OrbStack machine \(vm.machine) does not exist", evidence: ["orbctl info \(vm.machine) failed"],
                            suggestedAction: "Bring it up when you want this fleet."))
                return .absent
            }
            var problems: [String] = []
            if let config = machine.info?.record.config {
                if config.isolated != true { problems.append("isolated is not true") }
                if config.isolateNetwork != true { problems.append("isolate_network is not true") }
                if config.forwardSSHAgent != false { problems.append("forward_ssh_agent is not false") }
                if config.defaultUsername != vm.runnerUser {
                    problems.append("default user is \(config.defaultUsername ?? "unset"), expected \(vm.runnerUser)")
                }
            } else {
                problems.append("orbctl info returned no readable config")
            }
            let image = machine.info?.record.image
            if image?.arch != "arm64" { problems.append("architecture is not arm64") }
            if image?.distro != "ubuntu" || image?.version != "noble" {
                problems.append("image is \(image?.distro ?? "unknown") \(image?.version ?? "unknown"), expected ubuntu noble")
            }
            if machine.info?.record.osRelease?.versionID != "24.04" { problems.append("Ubuntu release is not 24.04") }
            if !machine.mountsReadable || !machine.mounts.isEmpty { problems.append("Mac mounts are not empty (\(machine.mounts.isEmpty ? "unreadable" : machine.mounts))") }
            problems += identityProblems(machine.identity, vm)
            guard !problems.isEmpty else { return .matches }
            add(Finding(id: "vm.\(host.id).identity", severity: .critical, subject: .host(host.id),
                        title: "\(host.name) does not match little-ci's machine rules",
                        evidence: problems,
                        suggestedAction: "No plan is offered for it. Run little-ci's doctor.sh and inspect the machine; never adopt it automatically."))
            return .mismatched
        }

        /// little-ci writes `/etc/little-ci/identity` as `key=value` lines (lib/orbstack-machine.sh). Every
        /// field the inventory knows must match exactly; `home` must be present.
        func identityProblems(_ identity: String?, _ vm: OrbStackVMHost) -> [String] {
            guard let identity else { return ["/etc/little-ci/identity is missing or unreadable"] }
            var fields: [String: String] = [:]
            for line in identity.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2, fields[String(parts[0])] == nil { fields[String(parts[0])] = String(parts[1]) }
            }
            let github = inventory.github
            let expected = ["machine": vm.machine, "scope": github.scope.rawValue,
                            "target": github.scope == .repository ? "\(github.owner)/\(github.repository)" : github.owner,
                            "prefix": vm.fleetPrefix, "user": vm.runnerUser]
            var problems = expected.sorted { $0.key < $1.key }.compactMap { key, value in
                fields[key] == value ? nil : "identity \(key) is \(fields[key].map { "\"\($0)\"" } ?? "missing"), expected \"\(value)\""
            }
            if (fields["home"] ?? "").isEmpty { problems.append("identity has no home") }
            return problems
        }

        // MARK: Runners

        /// The local runner is this fleet's: its `.runner` names this target and this exact runner.
        /// Plans that start, stop or retire a launchd service require it.
        func owns(_ local: RunnerServiceFacts?, _ name: String) -> Bool {
            local?.registeredURL == inventory.github.registrationURL && local?.registeredName == name
        }

        mutating func assess(_ runner: RunnerSpec, on host: HostSpec, facts: HostFacts, mayTakeJobs: Bool) {
            let local = facts.runner(named: runner.name)
            let owned = owns(local, runner.name)
            let running = local?.service.isRunning ?? false
            guard let github else { return }
            let remote = github.runner(named: runner.name)
            let subject = Subject.runner(runner.name)

            switch remote {
            case nil:
                if mayTakeJobs || local?.registeredURL != nil {
                    add(Finding(id: "runner.\(runner.name).unregistered", severity: .warning, subject: subject,
                                title: "\(runner.name) is not registered on GitHub",
                                evidence: [local?.registeredURL.map { "local .runner names \($0)" } ?? "no local registration",
                                           "service: \(Format.service(local?.service))"],
                                suggestedAction: "Register it with the host's install script, or remove it from the inventory."))
                }
            case let remote? where remote.status == .offline && remote.busy && !running:
                add(Finding(id: "runner.\(runner.name).lost", severity: .critical, subject: subject,
                            title: "GitHub shows \(runner.name) offline and busy; its service is not running",
                            evidence: ["GitHub: offline, busy", "\(host.name): \(Format.service(local?.service))"],
                            suggestedAction: "Its job is lost and will fail. Starting the service reconnects it so GitHub can close the job."),
                    plans: mayTakeJobs && owned ? PlanFactory.startService(host, runner.name, local: local) : [])
            case let remote? where remote.status == .offline && !running && mayTakeJobs:
                add(Finding(id: "runner.\(runner.name).stopped", severity: .critical, subject: subject,
                            title: "\(runner.name) is stopped",
                            evidence: ["GitHub: offline", "\(host.name): \(Format.service(local?.service))"],
                            suggestedAction: host.lendable ? "Start it, or mark \(host.name) as not lent." : "Start its service."),
                    plans: owned ? PlanFactory.startService(host, runner.name, local: local) : [])
            case let remote? where remote.status == .offline && running:
                add(Finding(id: "runner.\(runner.name).disconnected", severity: .warning, subject: subject,
                            title: "\(runner.name)'s service runs but GitHub shows it offline",
                            evidence: ["\(host.name): \(Format.service(local?.service))", "GitHub: offline"],
                            suggestedAction: "Usually a session conflict after a restart; it reconnects within a few minutes. Check _diag/Runner_*.log if it does not."))
            case let remote? where remote.status == .online && !mayTakeJobs:
                add(Finding(id: "runner.\(runner.name).unlent", severity: .warning, subject: subject,
                            title: "\(runner.name) takes jobs while \(host.name) is not lent",
                            evidence: ["GitHub: online, \(remote.busy ? "busy" : "idle")"],
                            suggestedAction: "Stop it once idle, or mark \(host.name) as lent."),
                    plans: remote.busy || !owned ? [] : PlanFactory.stopService(host, runner.name))
            default:
                break
            }

            guard running || (remote?.status == .online), let local, let requirement = github.toolchain else { return }
            var drift: [String] = []
            if let wanted = requirement.bunVersion, local.bunVersion != wanted {
                drift.append("Bun \(local.bunVersion ?? "missing"), package.json asks for \(wanted)")
            }
            if let minimum = requirement.minimumNodeMajor {
                let major = local.nodeVersion?.firstMatch(of: /^v?(\d+)/).flatMap { Int($0.1) }
                if (major ?? 0) < minimum { drift.append("Node \(local.nodeVersion ?? "missing"), package.json needs \(minimum) or newer") }
            }
            if !drift.isEmpty {
                add(Finding(id: "runner.\(runner.name).toolchain", severity: .critical, subject: subject,
                            title: "\(runner.name)'s toolchain does not match package.json",
                            evidence: drift + ["read with the runner's own .path"],
                            suggestedAction: "Update Bun or Node on \(host.name), then rewrite the runner's .path (scripts/ci_runners.sh install)."))
            }
        }

        mutating func assessRunnersWithoutFacts(_ host: HostSpec, mayTakeJobs: Bool) {
            guard let github else { return }
            for runner in host.runners {
                guard let remote = github.runner(named: runner.name), remote.status == .offline, remote.busy else { continue }
                add(Finding(id: "runner.\(runner.name).lost", severity: .critical, subject: .runner(runner.name),
                            title: "GitHub shows \(runner.name) offline and busy",
                            evidence: ["GitHub: offline, busy", "\(host.name) cannot be probed"],
                            suggestedAction: "Its job is lost. Reach \(host.name) and restart the runner."))
            }
        }

        // MARK: Fleet

        mutating func assessFleet() {
            guard let github else { return }
            let online = inventory.checkRunners(in: github).filter { $0.status == .online }
            let minimum = inventory.serviceLevels.minimumAvailableCheckRunners
            if online.count < minimum {
                add(Finding(id: "fleet.capacity", severity: .warning, subject: .fleet,
                            title: "\(online.count) check runners online; the target is \(minimum)",
                            evidence: ["online: \(online.isEmpty ? "none" : online.map(\.name).sorted().joined(separator: ", "))",
                                       "with job times held fixed, \(minimum) always-on runners keep the median queue wait under 2 min"],
                            suggestedAction: "Start stopped runners on hosts that are not lent, or lend a host."))
            }

            let queued = github.activeRuns.filter { $0.status == "queued" && $0.name == inventory.queue.checkWorkflow }
            let idle = online.filter { !$0.busy }
            if let oldest = queued.map(\.createdAt).min(), now.timeIntervalSince(oldest) > Assessor.stallAfter, !idle.isEmpty {
                add(Finding(id: "fleet.stall", severity: .warning, subject: .fleet,
                            title: "\(queued.count) runs queued for \(Format.duration(now.timeIntervalSince(oldest))) while \(idle.count) check runners sit idle",
                            evidence: ["idle: \(idle.map(\.name).sorted().joined(separator: ", "))",
                                       "a runner can listen for an hour after a session conflict while jobs wait"],
                            suggestedAction: "GitHub is not sending jobs. Restarting one idle runner opens a new session; check githubstatus.com."))
            }

            let declared = Set(inventory.hosts.flatMap { $0.runners.map(\.name) })
            for remote in github.runners where !declared.contains(remote.name) && belongsToDeclaredFamily(remote) {
                if remote.status == .offline && !remote.busy {
                    add(Finding(id: "runner.\(remote.name).stale", severity: .info, subject: .runner(remote.name),
                                title: "\(remote.name) is registered on GitHub but not in the inventory",
                                evidence: ["GitHub: offline, idle", "labels: \(remote.labelNames.joined(separator: ", "))"],
                                suggestedAction: "Delete the stale registration, or add the runner to the inventory."),
                        plans: [PlanFactory.deleteRegistration(remote, inventory: inventory)])
                } else {
                    add(Finding(id: "runner.\(remote.name).undeclared", severity: .info, subject: .runner(remote.name),
                                title: "\(remote.name) is online but not in the inventory",
                                evidence: ["GitHub: \(remote.status.rawValue), \(remote.busy ? "busy" : "idle")"],
                                suggestedAction: "Add it to the inventory so its host is probed."))
                }
            }
        }

        /// A runner numbered like a declared one (`mac-check-4` next to `mac-check-1`, or a little-ci
        /// fleet's `<prefix>-<n>`) that also carries one of that family's own labels.
        func belongsToDeclaredFamily(_ remote: GitHubRunner) -> Bool {
            let generic: Set<String> = ["self-hosted", "macOS", "Linux", "ARM64", "X64", "little-ci"]
            var families: [(prefix: String, labels: Set<String>)] = []
            for host in inventory.hosts {
                for runner in host.runners {
                    guard let number = runner.name.lastIndex(of: "-") else { continue }
                    families.append((String(runner.name[..<number]), Set(runner.labels).subtracting(generic)))
                }
                switch host.kind {
                case .orbstackVM(let vm): families.append((vm.fleetPrefix, [vm.fleetPrefix]))
                case .linuxServer(let server): families.append((server.fleetPrefix, [server.fleetPrefix]))
                case .macLaunchd: break
                }
            }
            return families.contains { family in
                remote.name.wholeMatch(of: try! Regex("\(NSRegularExpression.escapedPattern(for: family.prefix))-[0-9]+")) != nil
                    && !family.labels.isDisjoint(with: remote.labelNames)
            }
        }

        // MARK: Queue

        mutating func assessQueue() {
            guard let github else { return }
            let runs = github.activeRuns
            for run in runs {
                var dispositions: [QueueEntry.Disposition] = []
                let lane = QueueLane.of(run, policy: inventory.queue)
                if run.event == "pull_request", lane != .main,
                   runs.contains(where: { $0.id != run.id && $0.workflowId == run.workflowId && $0.name == run.name && $0.headBranch == run.headBranch
                       && $0.headRepository == run.headRepository && $0.createdAt > run.createdAt }) {
                    dispositions.append(.superseded)
                }
                if run.event == "pull_request", let branch = run.headBranch, github.pullRequests[branch]?.isOpen == false {
                    dispositions.append(.pullRequestClosed)
                }
                if !github.redMainJobs.isEmpty, run.name == inventory.queue.checkWorkflow, lane != .main {
                    dispositions.append(.likelyRedOnMain)
                }
                queue.append(QueueEntry(run: run, lane: lane, dispositions: dispositions))
            }

            if !github.redMainJobs.isEmpty {
                let doomed = queue.filter { $0.dispositions.contains(.likelyRedOnMain) }.count
                add(Finding(id: "queue.redMain", severity: .info, subject: .fleet,
                            title: "main is red; \(doomed) queued or running PR runs will likely fail the same jobs",
                            evidence: ["main's newest completed \(inventory.queue.checkWorkflow) run failed: \(github.redMainJobs.joined(separator: ", "))"],
                            suggestedAction: "Fix main first; PR failures in these jobs are not the PR's fault."))
            }
            let cancellable = queue.filter { $0.dispositions.contains(.superseded) || $0.dispositions.contains(.pullRequestClosed) }
            if !cancellable.isEmpty {
                let ordinary = cancellable.filter { $0.lane != .platform }.map(\.run)
                let platform = cancellable.filter { $0.lane == .platform }.map(\.run)
                var cancelPlans: [Plan] = []
                if !ordinary.isEmpty { cancelPlans.append(PlanFactory.cancelRuns(ordinary, platform: false)) }
                if !platform.isEmpty { cancelPlans.append(PlanFactory.cancelRuns(platform, platform: true)) }
                add(Finding(id: "queue.cancellable", severity: .info, subject: .fleet,
                            title: "\(cancellable.count) active runs are superseded or belong to closed PRs",
                            evidence: cancellable.prefix(8).map { entry in
                                let reasons = entry.dispositions.filter { $0 != .likelyRedOnMain }.map(\.rawValue)
                                return "\(entry.run.headBranch ?? "?") #\(entry.run.id): \(reasons.joined(separator: ", "))" },
                            suggestedAction: "Cancel them so runners serve current work."),
                    plans: cancelPlans)
            }
        }
    }
}

extension Inventory {
    /// GitHub runners that belong to this fleet: an exact declared name that carries every declared label.
    /// In organization scope GitHub lists every fleet's runners; only these count.
    func declaredRunners(in github: GitHubSnapshot) -> [GitHubRunner] {
        let declared = Dictionary(hosts.flatMap { host in host.runners.map { ($0.name, Set($0.labels)) } }, uniquingKeysWith: { first, _ in first })
        return github.runners.filter { runner in declared[runner.name]?.isSubset(of: runner.labelNames) ?? false }
    }

    /// This fleet's runners that serve the check pool.
    func checkRunners(in github: GitHubSnapshot) -> [GitHubRunner] {
        declaredRunners(in: github).filter { $0.labelNames.contains(queue.checkLabel) }
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    static func decimal(_ value: Double) -> String { String(format: "%.1f", value) }
    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 120 ? "\(Int(seconds)) s" : seconds < 7200 ? "\(Int(seconds / 60)) min" : String(format: "%.1f h", seconds / 3600)
    }
    static func time(_ date: Date) -> String { date.formatted(.dateTime.hour().minute()) }
    static func service(_ state: RunnerServiceFacts.ServiceState?) -> String {
        switch state {
        case nil: "no local facts"
        case .running(let pid)?: "service running (pid \(pid))"
        case .loadedNotRunning(let code)?: "service loaded, not running\(code.map { " (last exit \($0))" } ?? "")"
        case .notLoaded?: "service not loaded"
        case .unknown(let text)?: "service state unknown: \(text)"
        }
    }
}
