import Foundation

/// A fictional fleet (`demo-*`, `acme/widgets`) that runs through the same assessment as live data.
/// It shows one of each 2026-10-20 incident. Demo state never touches the journal, the ledger or a host.
public enum DemoFleet {
    public static func state(now: Date = Date()) -> FleetState {
        let observations = self.observations(now: now)
        let assessment = Assessor.assess(observations, now: now)
        return FleetState(source: .demo, observations: observations, assessment: assessment,
                          events: EventJournal.transitions(from: nil, to: assessment), lastOutcome: nil,
                          settings: { var settings = AppSettings(); settings.lentHosts = ["studio"]; return settings }())
    }

    static let inventory = Inventory(
        github: GitHubTarget(scope: .repository, owner: "acme", repository: "widgets"),
        hosts: [
            HostSpec(id: "studio", name: "Studio", kind: .macLaunchd(MacLaunchdHost(user: "demo", runnerRoot: "/Users/demo/runners",
                                                                                     serviceLabelPrefix: "com.acme.runner.")),
                     access: .local, lendable: true,
                     runners: (1...3).map { RunnerSpec(name: "demo-studio-\($0)", labels: ["widgets-check"]) }),
            HostSpec(id: "mini", name: "Mini", kind: .macLaunchd(MacLaunchdHost(user: "demo", runnerRoot: "/Users/demo/runners",
                                                                                 serviceLabelPrefix: "com.acme.runner.")),
                     access: .ssh(destination: "demo@mini.demo"), maxConcurrentJobs: 2,
                     runners: (1...2).map { RunnerSpec(name: "demo-mini-\($0)", labels: ["widgets-check"]) }),
            HostSpec(id: "vm", name: "Studio VM", kind: .orbstackVM(OrbStackVMHost(parentHost: "studio", machine: "little-ci-acme-widgets-vm",
                     runnerUser: "deploy", fleetPrefix: "little-ci-acme-widgets-vm", littleCICheckout: "/Users/demo/little-ci-vm")),
                     access: .local, runners: [RunnerSpec(name: "little-ci-acme-widgets-vm-1", labels: ["little-ci"])]),
            HostSpec(id: "hetzner", name: "Hetzner", kind: .linuxServer(LinuxServerHost(runnerUser: "deploy",
                     fleetPrefix: "little-ci-acme-widgets-hetzner", littleCICheckout: "/home/deploy/little-ci")),
                     access: .ssh(destination: "deploy@ci.demo"), runners: [RunnerSpec(name: "little-ci-acme-widgets-hetzner-1", labels: ["little-ci"])]),
            HostSpec(id: "laptop", name: "Laptop", kind: .macLaunchd(MacLaunchdHost(user: "demo", runnerRoot: "/Users/demo/runners",
                                                                                     serviceLabelPrefix: "com.acme.runner.")),
                     access: .ssh(destination: "demo@laptop.demo"), runners: [RunnerSpec(name: "demo-laptop-1", labels: ["widgets-check"])]),
        ],
        queue: { var policy = QueuePolicy(); policy.checkLabel = "widgets-check"; return policy }())

    static func observations(now: Date) -> FleetObservations {
        let gib: Int64 = 1 << 30
        func runner(_ name: String, _ service: RunnerServiceFacts.ServiceState, node: String = "v24.14.1") -> RunnerServiceFacts {
            RunnerServiceFacts(name: name, directoryExists: true, registeredURL: "https://github.com/acme/widgets",
                               serviceDefinitionExists: true, service: service, bunVersion: "1.3.14", nodeVersion: node)
        }
        func facts(_ hostname: String, load: Double, cores: Int, dataFree: Int64, docker: Bool, runners: [RunnerServiceFacts]) -> HostFacts {
            HostFacts(probeVersion: ProbeScript.version, observedAt: now, hostname: hostname, userID: 501, cpuCount: cores,
                      memoryBytes: 64 * gib, loadAverage: [load, load, load], memoryFreePercent: 60, swapUsedBytes: 0, swapTotalBytes: 0,
                      onACPower: true,
                      volumes: [VolumeFacts(device: "/dev/disk3s5", mountPoint: "/System/Volumes/Data", totalBytes: 1000 * gib,
                                            availableBytes: dataFree * gib, isReadOnly: false),
                                VolumeFacts(device: "/dev/disk15s1", mountPoint: "/Library/Developer/CoreSimulator/Volumes/iOS_23F73",
                                            totalBytes: 17 * gib, availableBytes: gib / 2, isReadOnly: true)],
                      docker: DockerFacts(socketPath: "/var/run/docker.sock", socketExists: docker, serverVersion: docker ? "29.8.2" : nil,
                                          error: docker ? nil : "failed to connect to the docker API at unix:///var/run/docker.sock: no such file or directory",
                                          composeVersion: docker ? "5.5.0" : nil),
                      orbstack: OrbStackFacts(version: "2.2.4", status: "Running", dataMountFailed: false, lastStartAt: nil, evidence: []),
                      virtualMachine: nil, runners: runners, recentPowerEvents: [])
        }
        let studio = facts("demo-studio", load: 31, cores: 10, dataFree: 20, docker: false,
                           runners: (1...3).map { runner("demo-studio-\($0)", .running(pid: 4000 + $0), node: $0 == 3 ? "v22.20.0" : "v24.14.1") })
        let mini = facts("demo-mini", load: 3, cores: 12, dataFree: 300, docker: true,
                         runners: [runner("demo-mini-1", .running(pid: 512)), runner("demo-mini-2", .notLoaded)])

        func remote(_ id: Int, _ name: String, online: Bool, busy: Bool, label: String = "widgets-check") -> GitHubRunner {
            GitHubRunner(id: id, name: name, status: online ? .online : .offline, busy: busy,
                         labels: ["self-hosted", label].map { GitHubRunner.Label(name: $0) })
        }
        let runners = [
            remote(1, "demo-studio-1", online: true, busy: true), remote(2, "demo-studio-2", online: true, busy: false),
            remote(3, "demo-studio-3", online: true, busy: false), remote(4, "demo-mini-1", online: true, busy: false),
            remote(5, "demo-mini-2", online: false, busy: true), remote(6, "demo-laptop-1", online: false, busy: false),
            remote(7, "demo-old-4", online: false, busy: false),
        ]
        func run(_ id: Int, branch: String, minutesAgo: Double, status: String = "queued", event: String = "pull_request") -> WorkflowRun {
            WorkflowRun(id: id, name: "CI", event: event, status: status, conclusion: nil, headBranch: branch,
                        headRepository: .init(fullName: "acme/widgets"), headSha: String(repeating: "a", count: 40),
                        displayTitle: "Change on \(branch)", createdAt: now.addingTimeInterval(-minutesAgo * 60), runStartedAt: nil,
                        runAttempt: 1, updatedAt: nil, pullRequests: [], htmlUrl: "https://github.com/acme/widgets/actions/runs/\(id)")
        }
        let github = GitHubSnapshot(
            observedAt: now, runners: runners,
            activeRuns: [run(101, branch: "fix/login", minutesAgo: 42), run(102, branch: "fix/login", minutesAgo: 9),
                         run(103, branch: "platform-sync", minutesAgo: 30), run(104, branch: "platform-sync", minutesAgo: 4),
                         run(105, branch: "docs/readme", minutesAgo: 25), run(106, branch: "main", minutesAgo: 3, event: "push"),
                         run(107, branch: "webapp-perf-chat", minutesAgo: 12, status: "in_progress")],
            redMainJobs: ["Test 2"],
            pullRequests: ["docs/readme": PullRequestState(number: 12, state: "closed", merged: true, headBranch: "docs/readme")],
            toolchain: ToolchainRequirement(bunVersion: "1.3.14", minimumNodeMajor: 24))
        let ledger = LedgerSummary(windowStart: now.addingTimeInterval(-7 * 86_400),
                                   checkQueueWaits: (0..<200).map { Double(($0 * 37) % 1800) }, machineFailures: 18, codeFailures: 61,
                                   unsureFailures: 4, interruptedByStops: 2)
        return FleetObservations(
            inventory: inventory, github: github,
            hosts: ["studio": HostObservation(hostID: "studio", attemptedAt: now, outcome: .reached(studio)),
                    "mini": HostObservation(hostID: "mini", attemptedAt: now, outcome: .reached(mini)),
                    "laptop": HostObservation(hostID: "laptop", attemptedAt: now, outcome: .unreachable("ssh: connect to host laptop.demo port 22: Operation timed out"))],
            lentHosts: ["studio"], ledger: ledger)
    }
}
