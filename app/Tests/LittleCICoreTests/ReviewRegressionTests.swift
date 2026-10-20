import Foundation
import Testing
@testable import LittleCICore

/// A GitHub whose runner list marks one runner busy from the Nth read on.
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

    func snapshot(for inventory: Inventory, now: Date) async throws -> GitHubSnapshot { snapshotValue }
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

    @Test("A runner that takes a job between drain steps is not stopped")
    func busyBetweenSteps() async throws {
        let dockerDown = m1
            .replacing("docker_socket", with: Fixture.text("sections/docker-socket-missing.txt"), exit: 1)
            .replacing("docker_info", with: Fixture.text("sections/docker-info-socket-missing.txt"), exit: 1)
        let snapshot = Fixture.snapshot(online: Fixture.m1CheckRunners, busy: ["ci-m1-check-1"])
        let observations = FleetObservations(inventory: Fixture.inventory, github: snapshot,
                                             hosts: ["m1": dockerDown.observation(for: "m1")], lentHosts: ["m1"])
        let plan = try #require(Assessor.assess(observations, now: Fixture.now).plan("drain.m1"))
        #expect(plan.steps.count == 3)
        #expect(plan.steps.allSatisfy { step in
            if case .hostCommand(_, let command, _) = step.action { command.contains("pgrep -f") && command.contains("exit 75") } else { false }
        }, "the host refuses to unload a runner whose worker is running")

        let runner = RecordingRunner(probe: dockerDown)
        let github = ShiftingGitHub(snapshot, becomesBusy: "ci-m1-check-3", fromRead: 2)
        let outcome = await PlanExecutor(github: github, prober: HostProber(runner: runner), commandRunner: runner)
            .execute(PlanReview(plan: plan, reviewedAt: Fixture.now), observations: observations, now: Fixture.now)
        #expect(outcome.completedSteps.count == 1)
        #expect(outcome.failedStep?.output.contains("ci-m1-check-3 took a job") == true)
        #expect(runner.calls.count == 1, "only ci-m1-check-2 was unloaded")
    }

    @Test("Bring-up plans for VM and server fleets require the host to be lent or not lendable")
    func bringUpNeedsLending() {
        let vm = HostSpec(id: "vm", name: "VM", kind: .orbstackVM(OrbStackVMHost(parentHost: "m1", machine: "little-ci-example-vm",
                          runnerUser: "deploy", fleetPrefix: "little-ci-example-vm", littleCICheckout: "/Users/builder1/little-ci")),
                          access: .local, lendable: true, runners: [])
        let server = HostSpec(id: "server", name: "Server", kind: .linuxServer(LinuxServerHost(runnerUser: "deploy",
                              fleetPrefix: "little-ci-example-server", littleCICheckout: "/home/deploy/little-ci")),
                              access: .ssh(destination: "deploy@server"), lendable: true, runners: [])
        var inventory = Fixture.inventory
        inventory.hosts += [vm, server]
        let vmUp = PlanFactory.lifecyclePlans(vm, inventory: inventory).first { $0.id == "vm.up.vm" }
        let serverUp = PlanFactory.lifecyclePlans(server, inventory: inventory).first { $0.id == "server.up.server" }
        #expect(vmUp?.preconditions.contains(.hostMayTakeJobs(hostID: "vm")) == true)
        #expect(vmUp?.preconditions.contains(.hostMayTakeJobs(hostID: "m1")) == true)
        #expect(serverUp?.preconditions.contains(.hostMayTakeJobs(hostID: "server")) == true)
        #expect(PlanFactory.lifecyclePlans(vm, inventory: inventory, machineExists: false).map(\.id) == ["vm.up.vm"],
                "a VM that does not exist can only be brought up")
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
