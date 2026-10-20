import Foundation
import Testing
@testable import LittleCICore

actor FakeGitHub: GitHubAccess {
    var current: GitHubSnapshot
    var cancelled: [Int] = []
    let token = "AAAAREMOVALTOKEN0123456789"

    init(_ snapshot: GitHubSnapshot) { current = snapshot }

    func set(_ snapshot: GitHubSnapshot) { current = snapshot }
    var freshReads = 0
    func snapshot(for inventory: Inventory, now: Date, fresh: Bool) async throws -> GitHubSnapshot {
        if fresh { freshReads += 1 }
        return current
    }
    func allRunners(_ target: GitHubTarget) async throws -> [GitHubRunner] { current.runners }
    func registrationToken(_ target: GitHubTarget) async throws -> String { token }
    func removalToken(_ target: GitHubTarget) async throws -> String { token }
    func cancelRun(_ target: GitHubTarget, id: Int) async throws { cancelled.append(id) }
    func deleteRunner(_ target: GitHubTarget, id: Int) async throws {}
}

/// Answers probes with a recorded probe; records every other command with what it got on stdin.
final class RecordingRunner: CommandRunning, @unchecked Sendable {
    struct Call { var invocation: CommandInvocation; var standardInput: String }
    private let lock = NSLock()
    private var recorded: [Call] = []
    let probe: Data
    let failing: (String) -> Bool
    let echoStandardInput: Bool

    init(probe: ProbeFixture, failing: @escaping (String) -> Bool = { _ in false }, echoStandardInput: Bool = false) {
        self.probe = try! JSONSerialization.data(withJSONObject: probe.envelope)
        self.failing = failing
        self.echoStandardInput = echoStandardInput
    }

    var calls: [Call] { lock.withLock { recorded } }

    func run(_ invocation: CommandInvocation, standardInput: Data?, timeout: Duration) async throws -> CommandResult {
        let input = String(decoding: standardInput ?? Data(), as: UTF8.self)
        if invocation.arguments.last == "/bin/bash -s", input.contains("probe_separator") {
            return CommandResult(exitCode: 0, standardOutput: probe, standardError: Data())
        }
        lock.withLock { recorded.append(Call(invocation: invocation, standardInput: input)) }
        let command = invocation.arguments.joined(separator: " ")
        let output = echoStandardInput ? "received \(input)" : "ok"
        return CommandResult(exitCode: failing(command) ? 1 : 0, standardOutput: Data(output.utf8), standardError: Data())
    }
}

@Suite("Plans run only as reviewed, and never interrupt a job")
struct PlanSafetyTests {
    let m1 = ProbeFixture("m1-macos")

    func observations(_ snapshot: GitHubSnapshot, lent: Set<String> = ["m1"]) -> FleetObservations {
        FleetObservations(inventory: Fixture.inventory, github: snapshot, hosts: ["m1": m1.observation(for: "m1")], lentHosts: lent)
    }

    func executor(_ github: FakeGitHub, _ runner: RecordingRunner) -> PlanExecutor {
        PlanExecutor(github: github, prober: HostProber(runner: runner), commandRunner: runner)
    }

    @Test("A runner that became busy after the review is not stopped")
    func busyAtExecutionIsRefused() async throws {
        let idle = Fixture.snapshot(online: Fixture.m1CheckRunners)
        let plan = try #require(Assessor.assess(observations(idle, lent: []), now: Fixture.now).plan("stop.ci-m1-check-2"))
        let github = FakeGitHub(Fixture.snapshot(online: Fixture.m1CheckRunners, busy: ["ci-m1-check-2"]))
        let runner = RecordingRunner(probe: m1)
        let outcome = await executor(github, runner).execute(PlanReview(plan: plan, reviewedAt: Fixture.now),
                                                             observations: observations(idle, lent: []), now: Fixture.now)
        #expect(!outcome.succeeded)
        #expect(!outcome.refusals.isEmpty)
        #expect(runner.calls.isEmpty, "no command ran")
    }

    @Test("Reviews expire after 15 minutes and are single use")
    func reviewLifetime() async throws {
        let snapshot = Fixture.snapshot(online: Fixture.m1CheckRunners)
        let plan = try #require(Assessor.assess(observations(snapshot, lent: []), now: Fixture.now).plan("stop.ci-m1-check-2"))
        let runner = RecordingRunner(probe: m1)
        let executor = executor(FakeGitHub(snapshot), runner)

        let expired = await executor.execute(PlanReview(plan: plan, reviewedAt: Fixture.now.addingTimeInterval(-901)),
                                             observations: observations(snapshot, lent: []), now: Fixture.now)
        #expect(expired.refusals.first?.contains("older than 15 minutes") == true)

        let review = PlanReview(plan: plan, reviewedAt: Fixture.now)
        let first = await executor.execute(review, observations: observations(snapshot, lent: []), now: Fixture.now)
        #expect(first.succeeded)
        let again = await executor.execute(review, observations: observations(snapshot, lent: []), now: Fixture.now)
        #expect(again.refusals.first?.contains("already used") == true)
        #expect(runner.calls.count == 1)
    }

    @Test("A lendable host that is not lent gets no start plan; once lent it does")
    func lendingGatesStart() {
        let offline = Fixture.snapshot(online: [])
        let stopped = m1.replacing("runner.ci-m1-check-1.service",
                                   with: "Could not find service \"com.example.ci-runner.ci-m1-check-1\" in domain for user gui: 501", exit: 1)
        func assessment(lent: Set<String>) -> Assessment {
            Assessor.assess(FleetObservations(inventory: Fixture.inventory, github: offline,
                                              hosts: ["m1": stopped.observation(for: "m1")], lentHosts: lent), now: Fixture.now)
        }
        #expect(assessment(lent: []).plan("start.ci-m1-check-1") == nil)
        #expect(assessment(lent: []).finding("runner.ci-m1-check-1.stopped") == nil)
        #expect(assessment(lent: ["m1"]).finding("runner.ci-m1-check-1.stopped")?.severity == .critical)
        #expect(assessment(lent: ["m1"]).plan("start.ci-m1-check-1") != nil)
    }

    @Test("Retiring a runner sends the removal token on stdin only, and never shows it")
    func tokenTravelsOnStandardInput() async throws {
        let snapshot = Fixture.snapshot(online: Fixture.m1CheckRunners)
        let plan = try #require(Assessor.assess(observations(snapshot), now: Fixture.now).plan("retire.ci-m1-check-2"))
        #expect(plan.requiresSecondConfirmation)
        let github = FakeGitHub(snapshot)
        let runner = RecordingRunner(probe: m1, echoStandardInput: true)
        let outcome = await executor(github, runner).execute(PlanReview(plan: plan, reviewedAt: Fixture.now),
                                                             observations: observations(snapshot), now: Fixture.now)
        #expect(outcome.succeeded)
        #expect(await github.freshReads == 1, "the read before running skips every cache")
        let token = github.token
        #expect(runner.calls.count == 3)
        #expect(runner.calls.allSatisfy { !$0.invocation.arguments.joined().contains(token) })
        #expect(runner.calls[1].standardInput == token + "\n")
        #expect(runner.calls[1].invocation.arguments.last?.contains("./config.sh remove --unattended") == true)
        #expect(outcome.completedSteps.allSatisfy { !$0.output.contains(token) })
    }

    @Test("A failed step stops the plan and reports the exact remaining commands")
    func partialFailureRecovery() async throws {
        let snapshot = Fixture.snapshot(online: Fixture.m1CheckRunners)
        let plan = try #require(Assessor.assess(observations(snapshot), now: Fixture.now).plan("retire.ci-m1-check-3"))
        let runner = RecordingRunner(probe: m1, failing: { $0.contains("config.sh remove") })
        let outcome = await executor(FakeGitHub(snapshot), runner).execute(PlanReview(plan: plan, reviewedAt: Fixture.now),
                                                                           observations: observations(snapshot), now: Fixture.now)
        #expect(outcome.completedSteps.count == 1)
        #expect(outcome.failedStep?.description == "Unregister on GitHub with a removal token from stdin")
        #expect(outcome.remainingCommands.count == 1)
        let recovery = try #require(outcome.recovery)
        #expect(recovery.contains("config.sh remove"))
        #expect(recovery.contains("rm -f -- \"$HOME/Library/LaunchAgents/\"'com.example.ci-runner.ci-m1-check-3.plist'"))
        #expect(runner.calls.count == 2, "the agent is not removed after unregistration failed")
    }

    @Test("Cancelling refuses when the runs it was reviewed for are no longer the same")
    func changedFleetIsRefused() async throws {
        struct Recorded: Decodable { var moment: Date; var activeRuns: [WorkflowRun]; var pullRequests: [String: PullRequestState] }
        let recorded = Fixture.decode(Recorded.self, "github/queue-2026-10-20T0100Z.json")
        let snapshot = GitHubSnapshot(observedAt: recorded.moment, runners: [], activeRuns: recorded.activeRuns,
                                      pullRequests: recorded.pullRequests)
        let reviewed = FleetObservations(inventory: Fixture.inventory, github: snapshot, hosts: [:])
        let plan = try #require(Assessor.assess(reviewed, now: recorded.moment).plans.first { $0.id.hasPrefix("cancel.superseded") })
        var later = snapshot
        later.activeRuns.removeAll { run in plan.steps.first.map { if case .cancelRun(let id) = $0.action { id == run.id } else { false } } ?? false }
        let github = FakeGitHub(later)
        let outcome = await executor(github, RecordingRunner(probe: m1)).execute(PlanReview(plan: plan, reviewedAt: recorded.moment),
                                                                                 observations: reviewed, now: recorded.moment)
        #expect(outcome.refusals.first?.contains("changed since the review") == true)
        #expect(await github.cancelled.isEmpty)
    }
}

@Suite("Inventory and probe contracts")
struct ContractTests {
    @Test("Organization scope needs a runner group; repository scope rejects one")
    func scopeValidation() {
        #expect(throws: InventoryError.self) { try GitHubTarget(scope: .organization, owner: "acme", repository: "app").validate() }
        #expect(throws: InventoryError.self) { try GitHubTarget(scope: .repository, owner: "acme", repository: "app", runnerGroup: "ci").validate() }
        #expect(throws: Never.self) { try GitHubTarget(scope: .organization, owner: "acme", repository: "app", runnerGroup: "ci").validate() }
        #expect(GitHubTarget(scope: .organization, owner: "acme", repository: "app", runnerGroup: "ci").runnersPath == "orgs/acme/actions/runners")
    }

    @Test("The example inventory decodes and validates")
    func exampleInventory() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../inventory.example.json")
        let inventory = try Inventory.load(from: url.standardizedFileURL)
        #expect(!inventory.hosts.isEmpty)
    }

    @Test("Access must be local or ssh:user@host", arguments: ["local", "ssh:builder@studio.local"])
    func validAccess(text: String) throws {
        let decoded = try JSONDecoder().decode(HostAccess.self, from: Data("\"\(text)\"".utf8))
        #expect(decoded.description == text)
    }

    @Test("Access with shell characters is rejected", arguments: ["ssh:host;rm -rf ~", "ssh:", "ssh:a b", "mosh:host"])
    func invalidAccess(text: String) {
        let json = try! JSONEncoder().encode(text)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(HostAccess.self, from: json) }
    }

    @Test("Every probe script is valid Bash")
    func probeSyntax() async throws {
        let vm = HostSpec(id: "vm", name: "VM", kind: .orbstackVM(OrbStackVMHost(parentHost: "m1", machine: "little-ci-example-studio",
                          runnerUser: "deploy", fleetPrefix: "little-ci-example-studio", littleCICheckout: "/tmp/little-ci")),
                          access: .local, runners: [RunnerSpec(name: "little-ci-example-studio-1", labels: ["little-ci"])])
        let server = HostSpec(id: "server", name: "Server", kind: .linuxServer(LinuxServerHost(runnerUser: "deploy",
                              fleetPrefix: "little-ci-example-hetzner", littleCICheckout: "/home/deploy/little-ci")),
                              access: .ssh(destination: "deploy@server"), runners: [RunnerSpec(name: "little-ci-example-hetzner-1", labels: ["little-ci"])])
        for host in Fixture.inventory.hosts + [vm, server] {
            let result = try await ProcessCommandRunner().run(CommandInvocation("/bin/bash", ["-n"]),
                                                              standardInput: Data(ProbeScript.script(for: host, includePowerLog: true).utf8),
                                                              timeout: .seconds(10))
            #expect(result.exitCode == 0, "\(host.id): \(result.errorText)")
        }
    }

    @Test("A recorded M4 probe parses to the facts the commands showed by hand")
    func m4ProbeFacts() {
        let facts = ProbeFixture("m4-macos").facts(for: "m4")
        #expect(facts.cpuCount == 12)
        #expect(facts.runner(named: "ci-m4-candidate-1")?.service == .notLoaded)
        #expect(facts.runner(named: "ci-m4-check-1")?.service.isRunning == true)
        #expect(facts.runner(named: "ci-m4-check-1")?.nodeVersion == "v24.14.1")
        #expect(facts.docker?.composeVersion != nil)
        #expect(facts.volumes.contains { $0.mountPoint == "/System/Volumes/Data" && $0.countsForHealth })
        #expect(!facts.volumes.contains { $0.mountPoint.contains("SimulatorRuntime") && $0.countsForHealth })
    }
}
