import Foundation
import Testing
@testable import LittleCICore

/// Findings from the Codex review of pull request 7.
@Suite("Codex review of the menu bar app")
struct CodexReviewTests {
    static let vm = OrbStackVMHost(parentHost: "m1", machine: "little-ci-example-owner-example-repo-studio", runnerUser: "deploy",
                                   fleetPrefix: "little-ci-example-owner-example-repo-studio", littleCICheckout: "/Users/builder1/little-ci")

    func vmObservation(identity: String) -> (Inventory, HostObservation) {
        var inventory = Fixture.inventory
        inventory.hosts.append(HostSpec(id: "vm", name: "VM", kind: .orbstackVM(Self.vm), access: .local, runners: []))
        let config = OrbStackVMFacts.Info.Config(isolated: true, isolateNetwork: true, defaultUsername: "deploy", forwardSSHAgent: false)
        let record = OrbStackVMFacts.Info.Record(name: Self.vm.machine, state: "running",
                                                 image: .init(distro: "ubuntu", arch: "arm64"), config: config,
                                                 osRelease: .init(versionID: "24.04"))
        var facts = ProbeFixture("m1-macos").facts(for: "m1")
        facts.virtualMachine = OrbStackVMFacts(info: .init(record: record), mountsReadable: true, mounts: "", identity: identity)
        return (inventory, HostObservation(hostID: "vm", attemptedAt: Fixture.now, outcome: .reached(facts)))
    }

    /// The format little-ci's `little_ci_machine_identity` writes (lib/orbstack-machine.sh).
    static let identity = """
        machine=little-ci-example-owner-example-repo-studio
        scope=repository
        target=example-owner/example-repo
        prefix=little-ci-example-owner-example-repo-studio
        user=deploy
        home=/home/deploy
        """

    @Test("A valid little-ci identity file matches, and its VM gets lifecycle plans")
    func identityMatches() {
        let (inventory, observation) = vmObservation(identity: Self.identity)
        let assessment = Assessor.assess(FleetObservations(inventory: inventory, github: Fixture.snapshot(online: []), hosts: ["vm": observation]),
                                         now: Fixture.now)
        #expect(assessment.finding("vm.vm.identity") == nil)
        #expect(Set(assessment.plans.filter { $0.subject == .host("vm") }.map(\.id)) == ["vm.up.vm", "vm.down.vm", "vm.delete.vm"])
    }

    @Test("An identity for another fleet or target is a mismatch with no plans")
    func identityMismatch() {
        let other = Self.identity.replacingOccurrences(of: "target=example-owner/example-repo", with: "target=example-owner/other")
        let (inventory, observation) = vmObservation(identity: other)
        let assessment = Assessor.assess(FleetObservations(inventory: inventory, github: Fixture.snapshot(online: []), hosts: ["vm": observation]),
                                         now: Fixture.now)
        let finding = assessment.finding("vm.vm.identity")
        #expect(finding?.evidence.contains { $0.contains("identity target is \"example-owner/other\"") } == true)
        #expect(assessment.plans.filter { $0.subject == .host("vm") }.isEmpty)
    }

    @Test("Another fleet's runner with the same check label does not count toward capacity")
    func capacityCountsOnlyThisFleet() {
        var snapshot = Fixture.snapshot(online: ["ci-m4-check-1"])
        snapshot.runners.append(contentsOf: (1...5).map {
            GitHubRunner(id: 800 + $0, name: "other-fleet-\($0)", status: .online, busy: false,
                         labels: ["self-hosted", "example-repo-check"].map { .init(name: $0) })
        })
        let assessment = assess(github: snapshot, hosts: [:])
        #expect(assessment.finding("fleet.capacity")?.title == "1 check runners online; the target is 4")
        #expect(assessment.serviceLevels.first { $0.id == "capacity" }?.measured == "1")
    }

    @Test("Capacity is unknown, not green or red, when GitHub data is stale")
    func staleCapacityIsUnknown() {
        var snapshot = Fixture.snapshot(online: Fixture.m1CheckRunners.union(Fixture.m4CheckRunners))
        snapshot.observedAt = Fixture.now.addingTimeInterval(-Assessor.staleAfter - 1)
        let level = assess(github: snapshot, hosts: [:]).serviceLevels.first { $0.id == "capacity" }
        #expect(level?.met == nil)
        #expect(level?.measured == "unknown")
    }

    @Test("Completed runs are read again only when they were updated since")
    func ledgerReadsOnlyChangedRuns() throws {
        struct Recorded: Decodable { var activeRuns: [WorkflowRun] }
        var runs = Array(Fixture.decode(Recorded.self, "github/queue-2026-10-20T0930Z.json").activeRuns.prefix(3))
        let earlier = Fixture.now.addingTimeInterval(-600)
        for index in runs.indices { runs[index].updatedAt = earlier }
        let ledgered: [Int: Date?] = [runs[0].id: earlier, runs[1].id: earlier]
        #expect(FleetMonitor.runsNeedingJobs(runs, ledgered: ledgered).map(\.id) == [runs[2].id])
        runs[1].updatedAt = Fixture.now  // a rerun updated it
        #expect(FleetMonitor.runsNeedingJobs(runs, ledgered: ledgered).map(\.id) == [runs[1].id, runs[2].id])
    }

    @Test("A timed-out command that ignores SIGTERM is killed before the step reports")
    func timeoutKillsTheProcess() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("little-ci-timeout-\(UUID().uuidString)")
        let script = "trap '' TERM; echo $$ > '\(marker.path)'; while :; do sleep 1; done"
        let started = Date()
        await #expect(throws: CommandError.self) {
            try await ProcessCommandRunner().run(CommandInvocation("/bin/sh", ["-c", script]), standardInput: nil, timeout: .seconds(1))
        }
        #expect(Date().timeIntervalSince(started) < 15)
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0, "the shell that ignored SIGTERM is gone")
        try? FileManager.default.removeItem(at: marker)
    }
}
