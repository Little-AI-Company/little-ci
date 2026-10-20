import Foundation
import Testing
@testable import LittleCICore

/// Each 2026-10-20 incident, replayed from recorded output, must produce the right finding.
@Suite("2026-10-20 incident replays")
struct IncidentReplayTests {
    let m1 = ProbeFixture("m1-macos")
    let m4 = ProbeFixture("m4-macos")

    @Test("The recorded probes raise only M4's real low-disk warning, though three simulator images are 98% full")
    func recordedBaseline() {
        let assessment = assess(github: Fixture.snapshot(online: Fixture.m4CheckRunners),
                                hosts: ["m1": m1.observation(for: "m1"), "m4": m4.observation(for: "m4")], lent: ["m1"])
        let disks = assessment.findings.filter { $0.id.hasPrefix("disk.") }
        #expect(disks.map(\.id) == ["disk.m4./System/Volumes/Data"], "\(disks.map { "\($0.id): \($0.evidence)" })")
        #expect(disks.first?.severity == .warning, "6.3% free on 2026-10-20")
        #expect(assessment.finding("docker.m1") == nil)
        #expect(assessment.finding("orbstack.m1.data") == nil)
    }

    @Test("1. M1 boot disk at 98%")
    func bootDiskFull() throws {
        // The real df line for the Data volume, with available set to 2% of its size.
        let df = m1.section("df").split(separator: "\n").map { line -> String in
            guard line.hasSuffix("/System/Volumes/Data") else { return String(line) }
            return "/dev/disk3s5 971350180 951923177 19427003 98% /System/Volumes/Data"
        }.joined(separator: "\n")
        let assessment = assess(github: Fixture.snapshot(online: Fixture.m1CheckRunners),
                                hosts: ["m1": m1.replacing("df", with: df).observation(for: "m1")], lent: ["m1"])
        let finding = try #require(assessment.finding("disk.m1./System/Volumes/Data"))
        #expect(finding.severity == .critical)
        #expect(finding.title == "M1 /System/Volumes/Data is 98% full")
        #expect(assessment.findings.filter { $0.id.hasPrefix("disk.m1.") }.count == 1, "one finding per APFS container")
    }

    @Test("2. OrbStack data mount failure")
    func orbStackDataMountFailure() throws {
        let probe = m1.replacing("orbstack_vmgr", with: Fixture.text("sections/orbstack-vmgr-mount-failure.txt"))
        let assessment = assess(github: Fixture.snapshot(online: Fixture.m1CheckRunners), hosts: ["m1": probe.observation(for: "m1")], lent: ["m1"])
        let finding = try #require(assessment.finding("orbstack.m1.data"))
        #expect(finding.severity == .critical)
        #expect(finding.evidence.contains { $0.contains("OrbStack data could not be mounted") })
        #expect(finding.planIDs == ["drain.m1"], "idle check runners can be stopped until it mounts")
    }

    @Test("3. Docker socket missing while the host's runners take MySQL jobs")
    func dockerSocketMissing() throws {
        let probe = m1
            .replacing("docker_socket", with: Fixture.text("sections/docker-socket-missing.txt"), exit: 1)
            .replacing("docker_info", with: Fixture.text("sections/docker-info-socket-missing.txt"), exit: 1)
        let assessment = assess(github: Fixture.snapshot(online: Fixture.m1CheckRunners, busy: ["ci-m1-check-1"]),
                                hosts: ["m1": probe.observation(for: "m1")], lent: ["m1"])
        let finding = try #require(assessment.finding("docker.m1"))
        #expect(finding.severity == .critical)
        #expect(finding.title == "Docker is down on M1 while 4 check runners take jobs")
        let drain = try #require(assessment.plan("drain.m1"))
        #expect(drain.preconditions == [.runnerIdle(name: "ci-m1-check-2"), .runnerIdle(name: "ci-m1-check-3"), .runnerIdle(name: "ci-m1-check-4")],
                "the busy runner keeps its job")

        let job = Fixture.decode(WorkflowJob.self, "logs/docker-down.job.json")
        #expect(FailureClassifier.classify(job, log: Fixture.text("logs/docker-down.log")).reason == "Docker down")
    }

    @Test("4. GitHub reports a runner offline and busy while launchd has it unloaded")
    func offlineBusyWhileUnloaded() throws {
        // M4's real `launchctl print` output for its unloaded runner, applied to ci-m4-check-2.
        let unloaded = m4.section("runner.ci-m4-candidate-1.service")
            .replacingOccurrences(of: "ci-m4-candidate-1", with: "ci-m4-check-2")
        let probe = m4.replacing("runner.ci-m4-check-2.service", with: unloaded, exit: 1)
        let assessment = assess(github: Fixture.snapshot(online: ["ci-m4-check-1"], busy: ["ci-m4-check-2"]),
                                hosts: ["m4": probe.observation(for: "m4")])
        let finding = try #require(assessment.finding("runner.ci-m4-check-2.lost"))
        #expect(finding.severity == .critical)
        let start = try #require(assessment.plan("start.ci-m4-check-2"))
        #expect(start.preconditions.contains(.serviceNotRunning(hostID: "m4", runner: "ci-m4-check-2")))
    }

    @Test("5. Node on a host differs from package.json")
    func toolchainDrift() throws {
        let probe = m1.replacing("runner.ci-m1-check-1.node", with: Fixture.text("sections/node-v22.txt"))
        let assessment = assess(github: Fixture.snapshot(online: Fixture.m1CheckRunners), hosts: ["m1": probe.observation(for: "m1")], lent: ["m1"])
        let finding = try #require(assessment.finding("runner.ci-m1-check-1.toolchain"))
        #expect(finding.severity == .critical)
        #expect(finding.evidence.first == "Node v22.20.0, package.json needs 24 or newer")
        #expect(assessment.finding("runner.ci-m1-check-2.toolchain") == nil)

        let job = Fixture.decode(WorkflowJob.self, "logs/toolchain-node.job.json")
        #expect(FailureClassifier.classify(job, log: Fixture.text("logs/toolchain-node.log")).reason == "toolchain drift")
    }

    @Test("6a. At 01:00 UTC the queue held runs of closed PRs and superseded runs; platform runs need a second confirmation")
    func queueOfClosedAndSupersededRuns() throws {
        let (snapshot, moment) = queueSnapshot("0100Z")
        let assessment = Assessor.assess(FleetObservations(inventory: Fixture.inventory, github: snapshot, hosts: [:]), now: moment)
        let closed = assessment.queue.filter { $0.dispositions.contains(.pullRequestClosed) }
        let superseded = assessment.queue.filter { $0.dispositions.contains(.superseded) }
        #expect(!closed.isEmpty)
        #expect(!superseded.isEmpty)
        #expect(assessment.queue.allSatisfy { $0.lane != .main || !$0.dispositions.contains(.superseded) }, "main runs are never superseded")
        let finding = try #require(assessment.finding("queue.cancellable"))
        let plans = finding.planIDs.compactMap(assessment.plan)
        #expect(plans.allSatisfy { plan in plan.steps.allSatisfy { if case .cancelRun = $0.action { true } else { false } } })
        let platformRuns = assessment.queue.filter { $0.lane == .platform && !$0.dispositions.filter { $0 != .likelyRedOnMain }.isEmpty }
        if !platformRuns.isEmpty {
            #expect(plans.contains { $0.requiresSecondConfirmation && $0.steps.count == platformRuns.count })
        }
        #expect(plans.filter { !$0.requiresSecondConfirmation }.allSatisfy { plan in
            plan.steps.allSatisfy { step in
                guard case .cancelRun(let id) = step.action else { return false }
                return assessment.queue.first { $0.id == id }?.lane != .platform
            }
        })
    }

    @Test("6b. At 09:30 UTC main was red; queued PR runs are marked as likely to fail the same jobs")
    func queueBehindRedMain() throws {
        let (snapshot, moment) = queueSnapshot("0930Z")
        let assessment = Assessor.assess(FleetObservations(inventory: Fixture.inventory, github: snapshot, hosts: [:]), now: moment)
        let finding = try #require(assessment.finding("queue.redMain"))
        #expect(finding.evidence.first?.contains("Database suite 2, Database suite 3, Test 1, Test 2") == true)
        #expect(assessment.queue.filter { $0.lane != .main }.allSatisfy { $0.dispositions.contains(.likelyRedOnMain) })
    }

    func queueSnapshot(_ label: String) -> (GitHubSnapshot, Date) {
        struct Recorded: Decodable {
            var moment: Date
            var activeRuns: [WorkflowRun]
            var recentMainRuns: [WorkflowRun]
            var redMainJobs: [String]
            var pullRequests: [String: PullRequestState]
        }
        let recorded = Fixture.decode(Recorded.self, "github/queue-2026-10-20T\(label).json")
        let snapshot = GitHubSnapshot(observedAt: recorded.moment, runners: Fixture.runners(online: Fixture.m4CheckRunners),
                                      activeRuns: recorded.activeRuns, recentMainRuns: recorded.recentMainRuns,
                                      redMainJobs: recorded.redMainJobs, pullRequests: recorded.pullRequests,
                                      toolchain: Fixture.toolchain)
        return (snapshot, recorded.moment)
    }
}
