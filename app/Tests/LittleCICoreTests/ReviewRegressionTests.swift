import Foundation
import Testing
@testable import LittleCICore

actor ShiftingGitHub: GitHubAccess {
    let snapshotValue: GitHubSnapshot
    let becomesBusy: String
    let fromRead: Int
    var reads = 0

    init(_ snapshot: GitHubSnapshot, becomesBusy: String, fromRead: Int) {
        snapshotValue = snapshot
        self.becomesBusy = becomesBusy
        self.fromRead = fromRead
    }

    func snapshot(for inventory: Inventory, now: Date, fresh: Bool) async throws -> GitHubSnapshot { snapshotValue }
    func allRunners(_ target: GitHubTarget) async throws -> [GitHubRunner] {
        reads += 1
        return snapshotValue.runners.map { runner in
            var runner = runner
            if runner.name == becomesBusy && reads >= fromRead { runner.busy = true }
            return runner
        }
    }
    func registrationToken(_ target: GitHubTarget) async throws -> String { "" }
    func removalToken(_ target: GitHubTarget) async throws -> String { "" }
    func cancelRun(_ target: GitHubTarget, id: Int) async throws {}
    func deleteRunner(_ target: GitHubTarget, id: Int) async throws {}
}

@Suite("Rules the 2026-10-20 review found unguarded")
struct ReviewRegressionTests {
    let m1 = ProbeFixture("m1-macos")

    @Test("A runner whose worker is running, or that takes a job between drain steps, is not stopped")
    func busyBetweenSteps() async throws {
        let dockerDown = m1
            .replacing("docker_socket", with: Fixture.text("sections/docker-socket-missing.txt"), exit: 1)
            .replacing("docker_info", with: Fixture.text("sections/docker-info-socket-missing.txt"), exit: 1)
        let snapshot = Fixture.snapshot(online: Fixture.m1CheckRunners, busy: ["ci-m1-check-1"])
        let observations = FleetObservations(inventory: Fixture.inventory, github: snapshot,
                                             hosts: ["m1": dockerDown.observation(for: "m1")], lentHosts: ["m1"])
        let plan = try #require(Assessor.assess(observations, now: Fixture.now).plan("drain.m1"))

        let host = FileManager.default.temporaryDirectory.appendingPathComponent("little-ci-drain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: host) }
        let runningWorkers = host.appendingPathComponent("running-workers")
        let unloaded = host.appendingPathComponent("unloaded")
        for (tool, body) in [("pgrep", "grep -Fqx -- \"$3\" '\(runningWorkers.path)'"),
                             ("launchctl", "printf '%s\\n' \"$2\" >> '\(unloaded.path)'")] {
            let path = host.appendingPathComponent(tool).path
            try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        let onHost: (CommandInvocation) -> CommandInvocation? = { invocation in
            CommandInvocation("/usr/bin/env", ["PATH=\(host.path):/usr/bin:/bin", invocation.executable] + invocation.arguments)
        }
        func unloadedServices() -> String { (try? String(contentsOf: unloaded, encoding: .utf8)) ?? "" }

        try "/Users/builder1/actions-runners.noindex/ci-m1-check-2/bin/Runner.Worker\n"
            .write(to: runningWorkers, atomically: true, encoding: .utf8)
        let workerRunning = await PlanExecutor(github: FakeGitHub(snapshot), prober: HostProber(runner: RecordingRunner(probe: dockerDown)),
                                               commandRunner: RecordingRunner(probe: dockerDown, executing: onHost))
            .execute(PlanReview(plan: plan, reviewedAt: Fixture.now), observations: observations, now: Fixture.now)
        #expect(workerRunning.failedStep?.output.contains("ci-m1-check-2 is running a job; not stopped") == true)
        #expect(unloadedServices().isEmpty, "the host refused to unload a runner whose worker is running")

        try "".write(to: runningWorkers, atomically: true, encoding: .utf8)
        let github = ShiftingGitHub(snapshot, becomesBusy: "ci-m1-check-3", fromRead: 2)
        let outcome = await PlanExecutor(github: github, prober: HostProber(runner: RecordingRunner(probe: dockerDown)),
                                         commandRunner: RecordingRunner(probe: dockerDown, executing: onHost))
            .execute(PlanReview(plan: plan, reviewedAt: Fixture.now), observations: observations, now: Fixture.now)
        #expect(outcome.failedStep?.output.contains("ci-m1-check-3 took a job") == true)
        #expect(unloadedServices().contains("com.example.ci-runner.ci-m1-check-2"))
        #expect(!unloadedServices().contains("ci-m1-check-3") && !unloadedServices().contains("ci-m1-check-4"),
                "nothing after the runner that took a job was unloaded")
    }

    @Test("Bring-up for VM and server fleets is refused unless the host and the VM's parent are lent or not lendable")
    func bringUpNeedsLending() async throws {
        let vm = HostSpec(id: "vm", name: "VM", kind: .orbstackVM(OrbStackVMHost(parentHost: "m1", machine: "little-ci-example-vm",
                          runnerUser: "deploy", fleetPrefix: "little-ci-example-vm", littleCICheckout: "/Users/builder1/little-ci")),
                          access: .local, lendable: true, runners: [])
        let server = HostSpec(id: "server", name: "Server", kind: .linuxServer(LinuxServerHost(runnerUser: "deploy",
                              fleetPrefix: "little-ci-example-server", littleCICheckout: "/home/deploy/little-ci")),
                              access: .ssh(destination: "deploy@server"), lendable: true, runners: [])
        var inventory = Fixture.inventory
        inventory.hosts += [vm, server]
        let snapshot = Fixture.snapshot(online: [])

        func bringUp(_ host: HostSpec, _ probe: ProbeFixture, lent: Set<String>) async throws -> (PlanOutcome, [String], RecordingRunner) {
            let runner = RecordingRunner(probe: probe)
            let observation = await HostProber(runner: runner).observe(host, in: inventory, includePowerLog: false, previous: nil, now: Fixture.now)
            let observations = FleetObservations(inventory: inventory, github: snapshot, hosts: [host.id: observation], lentHosts: lent)
            let offered = Assessor.assess(observations, now: Fixture.now).plans.filter { $0.subject == .host(host.id) }
            let plan = try #require(offered.first { $0.id.hasSuffix(".up.\(host.id)") })
            let outcome = await PlanExecutor(github: FakeGitHub(snapshot), prober: HostProber(runner: runner), commandRunner: runner)
                .execute(PlanReview(plan: plan, reviewedAt: Fixture.now), observations: observations, now: Fixture.now)
            return (outcome, offered.map(\.id), runner)
        }

        let absentVM = ProbeFixture.absentOrbStackVM("little-ci-example-vm")
        for lent: Set<String> in [[], ["m1"], ["vm"]] {
            let (outcome, offered, runner) = try await bringUp(vm, absentVM, lent: lent)
            #expect(offered == ["vm.up.vm"], "a VM that does not exist can only be brought up")
            #expect(!outcome.refusals.isEmpty && runner.calls.isEmpty, "VM bring-up ran with only \(lent.sorted()) lent")
        }
        let (vmUp, _, _) = try await bringUp(vm, absentVM, lent: ["vm", "m1"])
        #expect(vmUp.succeeded, "\(vmUp.refusals)")

        let linux = ProbeFixture.linuxHost("server")
        let (serverRefused, _, serverRunner) = try await bringUp(server, linux, lent: [])
        #expect(!serverRefused.refusals.isEmpty && serverRunner.calls.isEmpty, "server bring-up ran while the server was not lent")
        let (serverUp, _, _) = try await bringUp(server, linux, lent: ["server"])
        #expect(serverUp.succeeded, "\(serverUp.refusals)")
    }

    @Test("A VM's parent must be this Mac")
    func vmParentMustBeLocal() {
        var inventory = Fixture.inventory
        inventory.hosts.append(HostSpec(id: "vm", name: "VM", kind: .orbstackVM(OrbStackVMHost(parentHost: "m4", machine: "little-ci-example-vm",
                               runnerUser: "deploy", fleetPrefix: "little-ci-example-vm", littleCICheckout: "/Users/builder2/little-ci")),
                               access: .local, runners: []))
        #expect(throws: InventoryError.self) { try inventory.validate() }
    }

    @Test("Inventory values with shell characters are rejected", arguments: [
        "/Users/builder1/runners$(touch /tmp/x)", "/Users/builder1/run ners", "relative/path", "/Users/builder1/\"q\"",
    ])
    func shellCharacters(runnerRoot: String) {
        var inventory = Fixture.inventory
        inventory.hosts[0].kind = .macLaunchd(MacLaunchdHost(user: "builder1", runnerRoot: runnerRoot, serviceLabelPrefix: "com.example.ci-runner."))
        #expect(throws: InventoryError.self) { try inventory.validate() }
    }

    @Test("An SSH destination cannot start with a dash")
    func sshOption() {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(HostAccess.self, from: Data(#""ssh:-oProxyCommand=x""#.utf8)) }
    }

    @Test("Without GitHub data, an unreachable host is not reported as away")
    func unknownIsNotAway() {
        let observations = FleetObservations(inventory: Fixture.inventory, github: nil,
                                             hosts: ["m4": HostObservation(hostID: "m4", attemptedAt: Fixture.now, outcome: .unreachable("timeout"))])
        let assessment = Assessor.assess(observations, now: Fixture.now)
        #expect(assessment.finding("host.m4.away") == nil)
        #expect(assessment.finding("host.m4.unreachable")?.severity == .warning)
    }

    @Test("Only runners of a declared family, carrying its label, get a stale-registration delete")
    func staleRegistrationScope() {
        var snapshot = Fixture.snapshot(online: [])
        snapshot.runners += [
            GitHubRunner(id: 900, name: "ci-m1-check-9", status: .offline, busy: false,
                         labels: ["self-hosted", "example-repo-m1", "example-repo-check"].map { .init(name: $0) }),
            GitHubRunner(id: 901, name: "lw-other-1", status: .offline, busy: false, labels: [.init(name: "self-hosted")]),
            GitHubRunner(id: 902, name: "ci-m1-check-10", status: .offline, busy: false, labels: [.init(name: "self-hosted")]),
        ]
        let assessment = assess(github: snapshot, hosts: [:])
        #expect(assessment.plan("unregister.ci-m1-check-9") != nil)
        #expect(assessment.plan("unregister.lw-other-1") == nil)
        #expect(assessment.plan("unregister.ci-m1-check-10") == nil, "same name pattern, but none of the family's labels")
    }

    @Test("A request with a repeated header is refused, not a crash")
    func repeatedHeader() {
        let response = APIRouter.respond(method: "GET", target: "/v1/summary",
                                         headers: ["Host": "127.0.0.1:47623", "host": "evil.example"], state: nil, port: 47623)
        #expect(response.status == 400)
    }
}
