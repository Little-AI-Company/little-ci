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

    @Test("Runs on the same branch name from different forks are not superseded")
    func forkBranchesAreDistinct() {
        func run(_ id: Int, _ repository: String, minutesAgo: Double) -> WorkflowRun {
            WorkflowRun(id: id, name: "CI", event: "pull_request", status: "queued", conclusion: nil, headBranch: "fix/login",
                        headRepository: .init(fullName: repository), headSha: String(repeating: "b", count: 40), displayTitle: "fix",
                        createdAt: Fixture.now.addingTimeInterval(-minutesAgo * 60), runStartedAt: nil, runAttempt: 1, updatedAt: nil,
                        pullRequests: [], htmlUrl: "https://github.com/example-owner/example-repo/actions/runs/\(id)")
        }
        var snapshot = Fixture.snapshot(online: [])
        snapshot.activeRuns = [run(1, "fork-a/example-repo", minutesAgo: 30), run(2, "fork-b/example-repo", minutesAgo: 5),
                               run(3, "fork-a/example-repo", minutesAgo: 2)]
        let queue = assess(github: snapshot, hosts: [:]).queue
        #expect(queue.first { $0.id == 1 }?.dispositions.contains(.superseded) == true, "fork-a's newer run supersedes it")
        #expect(queue.first { $0.id == 2 }?.dispositions.contains(.superseded) == false, "fork-b has no newer run")
    }

    @Test("The ledger keeps only jobs that ran on this fleet's runners")
    func ledgerKeepsFleetJobs() {
        var ours = Fixture.decode(WorkflowJob.self, "logs/docker-down.job.json")
        var hosted = ours
        hosted.id += 1
        hosted.runnerName = "GitHub Actions 1000007139"
        ours.runnerName = "ci-m1-check-2"
        #expect(FleetMonitor.fleetJobs([ours, hosted], inventory: Fixture.inventory).map(\.id) == [ours.id])
    }

    @Test("The API summary counts only this fleet's runners")
    func apiSummaryIsFleetScoped() {
        var snapshot = Fixture.snapshot(online: ["ci-m4-check-1"])
        snapshot.runners.append(GitHubRunner(id: 990, name: "other-fleet-1", status: .online, busy: true,
                                             labels: [.init(name: "self-hosted")]))
        let observations = FleetObservations(inventory: Fixture.inventory, github: snapshot, hosts: [:])
        let state = FleetState(source: .live, observations: observations, assessment: Assessor.assess(observations, now: Fixture.now),
                               events: [], lastOutcome: nil, settings: AppSettings())
        let summary = APIRouter.summary(state)
        #expect(summary.runnersOnline == 1)
        #expect(summary.runnersBusy == 0)
    }

    @Test("A VM whose default user is not the runner user does not match")
    func defaultUserMustMatch() {
        var (inventory, observation) = vmObservation(identity: Self.identity)
        if case .reached(var facts) = observation.outcome {
            facts.virtualMachine?.info?.record.config?.defaultUsername = "admin"
            observation.outcome = .reached(facts)
        }
        inventory.queue = Fixture.inventory.queue
        let assessment = Assessor.assess(FleetObservations(inventory: inventory, github: Fixture.snapshot(online: []), hosts: ["vm": observation]),
                                         now: Fixture.now)
        #expect(assessment.finding("vm.vm.identity")?.evidence.contains("default user is admin, expected deploy") == true)
        #expect(assessment.plans.filter { $0.subject == .host("vm") }.isEmpty)
    }
}
