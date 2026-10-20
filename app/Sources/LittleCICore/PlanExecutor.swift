import Foundation

/// A plan the user reviewed. Single use; expires after 15 minutes.
public struct PlanReview: Sendable, Equatable, Identifiable {
    public static let lifetime: TimeInterval = 900

    public var id = UUID()
    public var plan: Plan
    public var reviewedAt: Date

    public init(plan: Plan, reviewedAt: Date) {
        self.plan = plan
        self.reviewedAt = reviewedAt
    }
}

public struct StepResult: Codable, Sendable, Equatable {
    public var description: String
    public var command: String
    public var succeeded: Bool
    public var output: String
}

public struct PlanOutcome: Codable, Sendable, Equatable {
    public var planID: String
    public var title: String
    public var finishedAt: Date
    /// Why the plan did not start. Nothing ran when this is not empty.
    public var refusals: [String]
    public var completedSteps: [StepResult]
    public var failedStep: StepResult?
    /// Exact commands that did not run, for recovery.
    public var remainingCommands: [String]

    public var succeeded: Bool { refusals.isEmpty && failedStep == nil }

    public var recovery: String? {
        guard let failedStep else { return nil }
        let done = completedSteps.isEmpty ? "No step completed." : "Completed: " + completedSteps.map(\.description).joined(separator: "; ") + "."
        let left = ([failedStep.command] + remainingCommands).map { "  \($0)" }.joined(separator: "\n")
        return "\(done)\nFailed: \(failedStep.description).\nAfter fixing the cause, run these on the host in order, or review the plan again in the app:\n\(left)"
    }
}

/// The GitHub reads and writes a plan needs. `GitHubClient` is the real one; tests replace it.
public protocol GitHubAccess: Sendable {
    /// `fresh: true` bypasses every cache, for reads right before a plan runs.
    func snapshot(for inventory: Inventory, now: Date, fresh: Bool) async throws -> GitHubSnapshot
    func allRunners(_ target: GitHubTarget) async throws -> [GitHubRunner]
    func registrationToken(_ target: GitHubTarget) async throws -> String
    func removalToken(_ target: GitHubTarget) async throws -> String
    func cancelRun(_ target: GitHubTarget, id: Int) async throws
    func deleteRunner(_ target: GitHubTarget, id: Int) async throws
}

extension GitHubClient: GitHubAccess {}

/// Runs reviewed plans: re-reads, re-derives, checks preconditions, then runs steps in order.
public actor PlanExecutor {
    private let github: any GitHubAccess
    private let prober: HostProber
    private let commandRunner: any CommandRunning
    private var usedReviews: Set<UUID> = []

    public init(github: any GitHubAccess, prober: HostProber, commandRunner: any CommandRunning = ProcessCommandRunner()) {
        self.github = github
        self.prober = prober
        self.commandRunner = commandRunner
    }

    public func execute(_ review: PlanReview, observations: FleetObservations, now: Date = Date()) async -> PlanOutcome {
        let plan = review.plan
        func refuse(_ reasons: [String]) -> PlanOutcome {
            PlanOutcome(planID: plan.id, title: plan.title, finishedAt: Date(), refusals: reasons, completedSteps: [],
                        failedStep: nil, remainingCommands: plan.steps.map { describe($0.action, observations.inventory) })
        }
        guard usedReviews.insert(review.id).inserted else { return refuse(["This review was already used. Review the plan again."]) }
        guard now.timeIntervalSince(review.reviewedAt) <= PlanReview.lifetime else {
            return refuse(["This review is older than 15 minutes. Review the plan again."])
        }

        // Read GitHub and every host the plan touches again, and derive the plan again from those reads.
        var fresh = observations
        do {
            fresh.github = try await github.snapshot(for: observations.inventory, now: now, fresh: true)
            fresh.githubError = nil
        } catch {
            return refuse(["GitHub could not be read: \(error)"])
        }
        for hostID in hostIDs(of: plan, inventory: observations.inventory) {
            guard let host = observations.inventory.host(hostID) else { return refuse(["Host \(hostID) is not in the inventory."]) }
            let observation = await prober.observe(host, in: observations.inventory, includePowerLog: false,
                                                   previous: observations.hosts[hostID], now: now)
            guard observation.facts != nil else { return refuse(["\(host.name) could not be probed."]) }
            fresh.hosts[hostID] = observation
        }
        let regenerated = Assessor.assess(fresh, now: now).plan(plan.id)
        guard regenerated == plan else {
            return refuse(["The fleet changed since the review, so this plan no longer applies as reviewed. Review it again."])
        }
        let failed = plan.preconditions.filter { !holds($0, in: fresh) }.map { "Not true now: \($0)" }
        guard failed.isEmpty else { return refuse(failed) }

        let mustStayIdle = plan.preconditions.compactMap { if case .runnerIdle(let name) = $0 { name } else { nil } }
        var completed: [StepResult] = []
        for (index, step) in plan.steps.enumerated() {
            var result: StepResult
            if let busy = await firstBusy(of: mustStayIdle, target: observations.inventory.github) {
                result = StepResult(description: step.description, command: describe(step.action, observations.inventory),
                                    succeeded: false, output: "\(busy) took a job before this step; stopped without running it")
            } else {
                result = await run(step, inventory: observations.inventory)
            }
            if !result.succeeded {
                return PlanOutcome(planID: plan.id, title: plan.title, finishedAt: Date(), refusals: [], completedSteps: completed,
                                   failedStep: result,
                                   remainingCommands: plan.steps.dropFirst(index + 1).map { describe($0.action, observations.inventory) })
            }
            completed.append(result)
        }
        return PlanOutcome(planID: plan.id, title: plan.title, finishedAt: Date(), refusals: [], completedSteps: completed,
                           failedStep: nil, remainingCommands: [])
    }

    /// GitHub's runner list read again now; a runner it cannot read counts as busy.
    func firstBusy(of names: [String], target: GitHubTarget) async -> String? {
        guard !names.isEmpty else { return nil }
        guard let runners = try? await github.allRunners(target) else { return names.first }
        return names.first { name in runners.first { $0.name == name }?.busy ?? false }
    }

    func holds(_ precondition: Precondition, in observations: FleetObservations) -> Bool {
        let github = observations.github
        switch precondition {
        case .runnerIdle(let name): return github?.runner(named: name).map { !$0.busy } ?? false
        case .runnerOffline(let name): return github?.runner(named: name)?.status == .offline
        case .runnerRegistered(let name): return github?.runner(named: name) != nil
        case .serviceNotRunning(let hostID, let runner):
            guard let facts = observations.hosts[hostID]?.facts?.runner(named: runner) else { return false }
            return !facts.service.isRunning
        case .hostMayTakeJobs(let hostID):
            guard let host = observations.inventory.host(hostID) else { return false }
            return !host.lendable || observations.lentHosts.contains(hostID)
        case .runActive(let id): return github?.activeRuns.contains { $0.id == id } ?? false
        case .fleetIdle(let prefix): return github.map { !$0.runners.contains { $0.name.hasPrefix(prefix + "-") && $0.busy } } ?? false
        }
    }

    func hostIDs(of plan: Plan, inventory: Inventory) -> [String] {
        var ids: [String] = []
        switch plan.subject {
        case .host(let id): ids.append(id)
        case .runner(let name): if let host = inventory.host(ofRunner: name) { ids.append(host.id) }
        case .fleet, .run: break
        }
        for step in plan.steps { if case .hostCommand(let hostID, _, _) = step.action, !ids.contains(hostID) { ids.append(hostID) } }
        for precondition in plan.preconditions {
            if case .serviceNotRunning(let hostID, _) = precondition, !ids.contains(hostID) { ids.append(hostID) }
        }
        return ids
    }

    func describe(_ action: PlanAction, _ inventory: Inventory) -> String {
        switch action {
        case .hostCommand(let hostID, let command, let token):
            let access = inventory.host(hostID).map { HostProber.access(for: $0, in: inventory) }?.description ?? hostID
            return "[\(access)] \(command)" + (token.map { " (reads a \($0.rawValue) token on stdin)" } ?? "")
        case .localCommand(let invocation): return invocation.displayText
        case .cancelRun(let id): return "gh api -X POST \(inventory.github.repositoryPath)/actions/runs/\(id)/cancel"
        case .deleteRunnerRegistration(let id, _): return "gh api -X DELETE \(inventory.github.runnersPath)/\(id)"
        }
    }

    func run(_ step: PlanStep, inventory: Inventory) async -> StepResult {
        let command = describe(step.action, inventory)
        func result(_ succeeded: Bool, _ output: String) -> StepResult {
            StepResult(description: step.description, command: command, succeeded: succeeded, output: String(output.suffix(4000)))
        }
        do {
            switch step.action {
            case .hostCommand(let hostID, let remoteCommand, let tokenKind):
                guard let host = inventory.host(hostID) else { return result(false, "host \(hostID) is not in the inventory") }
                var token: String?
                if let tokenKind {
                    token = switch tokenKind {
                    case .registration: try await github.registrationToken(inventory.github)
                    case .removal: try await github.removalToken(inventory.github)
                    }
                }
                let invocation = HostProber.access(for: host, in: inventory).invocation(remoteCommand: remoteCommand)
                let output = try await commandRunner.run(invocation, standardInput: token.map { Data(($0 + "\n").utf8) }, timeout: .seconds(1800))
                let text = redact(output.outputText + output.errorText, token)
                return result(output.exitCode == 0, text)
            case .localCommand(let invocation):
                let output = try await commandRunner.run(invocation, standardInput: nil, timeout: .seconds(3600))
                return result(output.exitCode == 0, output.outputText + output.errorText)
            case .cancelRun(let id):
                try await github.cancelRun(inventory.github, id: id)
                return result(true, "cancel requested")
            case .deleteRunnerRegistration(let id, let name):
                let current = try await github.allRunners(inventory.github).first { $0.id == id }
                guard let current, current.name == name, current.status == .offline, !current.busy else {
                    return result(false, "runner \(id) is no longer an offline, idle runner named \(name); nothing deleted")
                }
                try await github.deleteRunner(inventory.github, id: id)
                return result(true, "deleted")
            }
        } catch {
            return result(false, String(describing: error))
        }
    }

    func redact(_ text: String, _ token: String?) -> String {
        guard let token, !token.isEmpty else { return text }
        return text.replacingOccurrences(of: token, with: "***")
    }
}

extension GitHubClient {
    public func deleteRunner(_ target: GitHubTarget, id: Int) async throws {
        _ = try await request("DELETE", "\(target.runnersPath)/\(id)")
    }
}
