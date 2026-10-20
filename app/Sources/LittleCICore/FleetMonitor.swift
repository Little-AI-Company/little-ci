import Foundation

/// Per-Mac choices that are not part of the shared inventory.
public struct AppSettings: Codable, Sendable, Equatable {
    public var lentHosts: Set<String> = []
    public var localAPIEnabled = true
    public var notificationsEnabled = false
    /// Hosts whose notifications are paused until a time (history and in-app findings continue).
    public var maintenanceUntil: [String: Date] = [:]

    public init() {}

    public static func load(from url: URL = AppPaths.settings) -> AppSettings {
        (try? JobLedger.decoder.decode(AppSettings.self, from: Data(contentsOf: url))) ?? AppSettings()
    }

    public func save(to url: URL = AppPaths.settings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JobLedger.encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum DataSource: String, Codable, Sendable, CaseIterable { case live, demo }

/// What the UI and the local API read: one consistent snapshot.
public struct FleetState: Codable, Sendable, Equatable {
    public var source: DataSource
    public var observations: FleetObservations
    public var assessment: Assessment
    public var events: [FleetEvent]
    public var lastOutcome: PlanOutcome?
    public var settings: AppSettings
}

/// observe (GitHub and probes) -> assess against the inventory -> publish. Never writes to a host or GitHub.
public actor FleetMonitor {
    public static let githubInterval: TimeInterval = 20
    public static let probeInterval: TimeInterval = 60
    static let ledgerInterval: TimeInterval = 60
    static let powerLogInterval: TimeInterval = 600
    static let maximumConcurrentProbes = 4

    private let inventory: Inventory
    private let github: GitHubClient
    private let prober: HostProber
    private let ledger: JobLedger
    private let journal: EventJournal
    public let executor: PlanExecutor
    private let publish: @Sendable (FleetState) async -> Void

    private var settings: AppSettings
    private var snapshot: GitHubSnapshot?
    private var githubError: String?
    private var hostObservations: [String: HostObservation] = [:]
    private var lastPowerLog: [String: Date] = [:]
    private var ledgerSummary = LedgerSummary.empty
    /// Completed runs already in the ledger, by run ID, at the update time they were read.
    private var ledgeredRuns: [Int: Date?]?
    static let ledgerWindow: TimeInterval = 7 * 86_400
    private var assessment: Assessment?
    private var lastOutcome: PlanOutcome?
    private var loops: [Task<Void, Never>] = []
    private var wake = AsyncStream<Void>.makeStream()

    public init(inventory: Inventory, settings: AppSettings, github: GitHubClient = GitHubClient(), prober: HostProber = HostProber(),
                ledger: JobLedger = JobLedger(), journal: EventJournal = EventJournal(url: AppPaths.events),
                publish: @escaping @Sendable (FleetState) async -> Void) {
        self.inventory = inventory
        self.settings = settings
        self.github = github
        self.prober = prober
        self.ledger = ledger
        self.journal = journal
        self.executor = PlanExecutor(github: github, prober: prober)
        self.publish = publish
    }

    public func start() {
        guard loops.isEmpty else { return }
        loops = [
            Task { await self.repeatEvery(Self.githubInterval) { await $0.readGitHub() } },
            Task { await self.repeatEvery(Self.probeInterval) { await $0.probeHosts() } },
            Task { await self.repeatEvery(Self.ledgerInterval) { await $0.updateLedger() } },
        ]
    }

    public func stop() {
        loops.forEach { $0.cancel() }
        loops = []
    }

    /// Reads GitHub and every host now.
    public func refreshNow() async {
        async let github: Void = readGitHub()
        async let hosts: Void = probeHosts()
        _ = await (github, hosts)
    }

    public func setLent(_ hostID: String, _ lent: Bool) async {
        if lent { settings.lentHosts.insert(hostID) } else { settings.lentHosts.remove(hostID) }
        try? settings.save()
        await assessAndPublish()
    }

    public func setMaintenance(_ hostID: String, until: Date?) async {
        settings.maintenanceUntil[hostID] = until
        try? settings.save()
        await assessAndPublish()
    }

    public func updateSettings(_ change: @Sendable (inout AppSettings) -> Void) async {
        change(&settings)
        try? settings.save()
        await assessAndPublish()
    }

    /// Runs a reviewed plan, records the outcome as an event, and reads the fleet again.
    public func execute(_ review: PlanReview) async -> PlanOutcome {
        let outcome = await executor.execute(review, observations: currentObservations())
        lastOutcome = outcome
        let detail = outcome.refusals.first ?? outcome.recovery ?? outcome.completedSteps.map(\.description).joined(separator: "; ")
        try? await journal.append([FleetEvent(at: Date(), kind: outcome.succeeded ? .planExecuted : .planFailed,
                                              subject: review.plan.subject, title: review.plan.title, detail: detail)])
        await refreshNow()
        return outcome
    }

    // MARK: Loops

    private func repeatEvery(_ interval: TimeInterval, _ work: @Sendable (FleetMonitor) async -> Void) async {
        while !Task.isCancelled {
            await work(self)
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func readGitHub() async {
        let started = Date()
        do {
            let fresh = try await github.snapshot(for: inventory, now: started)
            if fresh.observedAt >= snapshot?.observedAt ?? .distantPast {
                snapshot = fresh
                githubError = nil
            }
        } catch {
            githubError = String(describing: error)
        }
        await assessAndPublish()
    }

    private func probeHosts() async {
        let now = Date()
        let hosts = inventory.hosts
        var due: [(HostSpec, Bool)] = []
        for host in hosts {
            let powerLog = now.timeIntervalSince(lastPowerLog[host.id] ?? .distantPast) >= Self.powerLogInterval
            if powerLog, case .macLaunchd = host.kind { lastPowerLog[host.id] = now }
            due.append((host, powerLog))
        }
        let previous = hostObservations
        let inventory = self.inventory
        let prober = self.prober
        let results = await withTaskGroup(of: HostObservation.self) { group in
            var collected: [HostObservation] = []
            var pending = due[...]
            for _ in 0..<Self.maximumConcurrentProbes {
                guard let (host, powerLog) = pending.popFirst() else { break }
                group.addTask { await prober.observe(host, in: inventory, includePowerLog: powerLog, previous: previous[host.id]) }
            }
            for await observation in group {
                collected.append(observation)
                if let (host, powerLog) = pending.popFirst() {
                    group.addTask { await prober.observe(host, in: inventory, includePowerLog: powerLog, previous: previous[host.id]) }
                }
            }
            return collected
        }
        for observation in results {
            // A probe without the power log keeps the power events from the last one that had it.
            var observation = observation
            if case .reached(var facts) = observation.outcome, facts.recentPowerEvents.isEmpty,
               let earlier = previous[observation.hostID]?.facts?.recentPowerEvents {
                facts.recentPowerEvents = earlier
                observation.outcome = .reached(facts)
            }
            if observation.attemptedAt >= hostObservations[observation.hostID]?.attemptedAt ?? .distantPast {
                hostObservations[observation.hostID] = observation
            }
        }
        await assessAndPublish()
    }

    /// Records finished jobs with their failure class, so service levels come from real jobs.
    private func updateLedger() async {
        let target = inventory.github
        do {
            var known: [Int: Date?]
            if let ledgeredRuns { known = ledgeredRuns } else { known = await ledger.processedRuns() }
            // Every completed run in the reporting window, newest first, so a busy hour or a stopped app leaves no gap.
            let since = Date().addingTimeInterval(-Self.ledgerWindow).formatted(.iso8601.year().month().day())
            var runs: [WorkflowRun] = []
            for page in 1...10 {
                let batch = try await github.runs(target, query: "status=completed&created=%3E%3D\(since)&exclude_pull_requests=true&per_page=100&page=\(page)")
                runs += batch
                // Stop at the end, or at a page with nothing new: after the first backfill a minute costs one page.
                if batch.count < 100 || Self.runsNeedingJobs(batch, ledgered: known).isEmpty { break }
            }
            for run in Self.runsNeedingJobs(runs, ledgered: known) {
                let jobs = try await github.jobs(target, runID: run.id, filter: "all")
                var entries: [LedgerEntry] = []
                for job in Self.fleetJobs(jobs, inventory: inventory) {
                    guard await !ledger.contains(jobID: job.id) else { continue }
                    var failure: FailureClass?
                    if job.conclusion == "failure" {
                        let log = try? await github.jobLog(target, jobID: job.id)
                        let annotations = (try? await github.jobAnnotations(target, jobID: job.id)) ?? []
                        failure = FailureClassifier.classify(job, log: log, annotations: annotations, context: context(for: job, among: jobs))
                    }
                    entries.append(LedgerEntry(job: job, workflow: run.name, failure: failure, runUpdatedAt: run.updatedAt))
                }
                try await ledger.record(entries)
                known[run.id] = run.updatedAt
                ledgeredRuns = known
            }
            ledgeredRuns = known
            ledgerSummary = await ledger.summary(since: Date().addingTimeInterval(-7 * 86_400), checkLabel: inventory.queue.checkLabel)
        } catch {
            githubError = "job ledger: \(error)"
        }
        await assessAndPublish()
    }

    /// Finished jobs that ran on one of this fleet's declared runners. Hosted runners and other
    /// fleets would skew the failure shares and queue waits.
    static func fleetJobs(_ jobs: [WorkflowJob], inventory: Inventory) -> [WorkflowJob] {
        jobs.filter { $0.tookRunner && $0.conclusion != nil && $0.runnerName.flatMap(inventory.host(ofRunner:)) != nil }
    }

    /// A rerun updates its run, so a run is read again only when its update time changed.
    /// Skipped runs never took a runner, so they are not read at all.
    static func runsNeedingJobs(_ runs: [WorkflowRun], ledgered: [Int: Date?]) -> [WorkflowRun] {
        runs.filter { run in
            guard run.conclusion != "skipped" else { return false }
            guard let seen = ledgered[run.id] else { return true }
            return seen != run.updatedAt
        }
    }

    private func context(for job: WorkflowJob, among jobs: [WorkflowJob]) -> FailureClassifier.Context {
        let hostOfJob = job.runnerName.flatMap { inventory.host(ofRunner: $0)?.id }
        let passes = jobs.filter { $0.name == job.name && $0.conclusion == "success" && $0.tookRunner }
        return FailureClassifier.Context(
            passedOnAnotherHost: passes.contains { $0.headSha == job.headSha && $0.runnerName.flatMap { inventory.host(ofRunner: $0)?.id } != hostOfJob },
            passedOnRerun: passes.contains { $0.runId == job.runId && $0.runAttempt > job.runAttempt })
    }

    // MARK: Assessment

    private func currentObservations() -> FleetObservations {
        FleetObservations(inventory: inventory, github: snapshot, githubError: githubError, hosts: hostObservations,
                          lentHosts: settings.lentHosts, ledger: ledgerSummary,
                          previouslyActive: Set(assessment?.findings.map(\.id) ?? []))
    }

    private func assessAndPublish() async {
        let observations = currentObservations()
        let next = Assessor.assess(observations, now: Date())
        try? await journal.append(EventJournal.transitions(from: assessment, to: next))
        assessment = next
        await publish(FleetState(source: .live, observations: observations, assessment: next,
                                 events: await journal.recent(200), lastOutcome: lastOutcome, settings: settings))
    }
}
