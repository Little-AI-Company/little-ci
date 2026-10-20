import LittleCICore
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case overview = "Overview", hosts = "Hosts", runners = "Runners", queue = "Queue", events = "Events"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .hosts: "desktopcomputer"
        case .runners: "figure.run"
        case .queue: "list.number"
        case .events: "clock"
        }
    }
}

struct DetailsWindow: View {
    let store: FleetStore
    @State private var pane: Pane = LaunchOptions.current.pane

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                .navigationSplitViewColumnWidth(150)
        } detail: {
            if let state = store.state {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if store.isDemo { Text("DEMO DATA: a fictional fleet. Plans are disabled.").font(.callout.bold()).foregroundStyle(.orange) }
                        switch pane {
                        case .overview: OverviewPane(state: state, store: store)
                        case .hosts: HostsPane(state: state, store: store)
                        case .runners: RunnersPane(state: state, store: store)
                        case .queue: QueuePane(state: state, store: store)
                        case .events: EventsPane(events: state.events)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(store.setupProblem ?? "Reading GitHub and the hosts…").padding()
            }
        }
        .toolbar {
            Toggle("Demo data", isOn: Binding(get: { store.isDemo }, set: { store.setDemo($0) }))
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Refresh", systemImage: "arrow.clockwise") { store.refresh() }.disabled(store.isDemo)
        }
        .frame(minWidth: 820, minHeight: 520)
    }
}

/// A plain bold heading: section titles are primary text, not gray captions.
struct Heading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.headline) }
}

struct OverviewPane: View {
    let state: FleetState
    let store: FleetStore

    var body: some View {
        Heading("Service levels")
        ServiceLevelGrid(levels: state.assessment.serviceLevels)
        Heading("Findings (\(state.assessment.findings.count))")
        if state.assessment.findings.isEmpty { Text("Nothing needs attention.") }
        ForEach(state.assessment.findings) { finding in
            FindingRow(finding: finding, store: store)
            Divider()
        }
        if let outcome = state.lastOutcome { Heading("Last plan"); OutcomeView(outcome: outcome) }
    }
}

struct HostsPane: View {
    let state: FleetState
    let store: FleetStore

    var body: some View {
        ForEach(state.observations.inventory.hosts) { host in
            let observation = state.observations.hosts[host.id]
            HStack(alignment: .firstTextBaseline) {
                Heading(host.name)
                Text(kind(host)).font(.callout)
                Text(host.access.description).font(.callout.monospaced())
                Spacer()
                if host.lendable {
                    Toggle("Lent to CI", isOn: Binding(get: { state.settings.lentHosts.contains(host.id) },
                                                      set: { store.setLent(host.id, $0) })).disabled(store.isDemo)
                }
                Menu("Notifications") {
                    Button("Pause for 1 hour") { store.pauseNotifications(host.id, for: 3600) }
                    Button("Resume") { store.pauseNotifications(host.id, for: nil) }
                }
                .fixedSize()
            }
            if let facts = observation?.facts ?? observation?.lastFacts {
                FactsGrid(facts: facts, stale: observation?.facts == nil)
            }
            if case .unreachable(let reason)? = observation?.outcome { Text("Not reached: \(reason)").font(.callout) }
            ForEach(state.assessment.findings.filter { $0.subject == .host(host.id) }) { FindingRow(finding: $0, store: store) }
            let lifecycle = state.assessment.plans.filter { $0.subject == .host(host.id) && ($0.id.hasPrefix("vm.") || $0.id.hasPrefix("server.")) }
            if !lifecycle.isEmpty { HStack { ForEach(lifecycle) { PlanButton(plan: $0, store: store) } }.controlSize(.small) }
            Divider()
        }
    }

    func kind(_ host: HostSpec) -> String {
        switch host.kind {
        case .macLaunchd: "Mac, launchd"
        case .orbstackVM(let vm): "OrbStack VM \(vm.machine) on \(vm.parentHost)"
        case .linuxServer: "Linux server, systemd"
        }
    }
}

struct FactsGrid: View {
    let facts: HostFacts
    let stale: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
            GridRow {
                Text("load")
                Text(facts.loadAverage.map { String(format: "%.1f", $0) }.joined(separator: " ")
                     + (facts.cpuCount.map { " on \($0) cores" } ?? "")).monospacedDigit()
                Text("memory free")
                Text(facts.memoryFreePercent.map { "\($0)%" } ?? "unknown")
                Text("swap")
                Text(swap).monospacedDigit()
            }
            GridRow {
                Text("Docker")
                Text(facts.docker.map { $0.serverVersion ?? "down" } ?? "not checked")
                Text("Compose")
                Text(facts.docker?.composeVersion ?? "missing")
                Text("observed")
                Text(age(facts.observedAt) + (stale ? " (stale)" : ""))
            }
            ForEach(facts.volumes.filter(\.countsForHealth), id: \.mountPoint) { volume in
                GridRow {
                    Text("disk")
                    Text(volume.mountPoint).lineLimit(1).gridCellColumns(3)
                    Text("\(Int((volume.usedFraction * 100).rounded()))% used")
                    Text(ByteCountFormatter.string(fromByteCount: volume.availableBytes, countStyle: .file) + " free")
                }
            }
        }
        .font(.callout)
    }

    var swap: String {
        guard let used = facts.swapUsedBytes, let total = facts.swapTotalBytes else { return "unknown" }
        return "\(ByteCountFormatter.string(fromByteCount: used, countStyle: .memory)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .memory))"
    }
}

struct RunnersPane: View {
    let state: FleetState
    let store: FleetStore

    struct Row: Identifiable {
        var id: String { name }
        var name: String
        var host: String
        var github: String
        var service: String
        var toolchain: String
        var plans: [Plan]
    }

    var rows: [Row] {
        let inventory = state.observations.inventory
        let github = state.observations.github
        var rows: [Row] = inventory.hosts.flatMap { host in
            host.runners.map { spec in
                let remote = github?.runner(named: spec.name)
                let local = state.observations.hosts[host.id]?.facts?.runner(named: spec.name)
                return Row(name: spec.name, host: host.name,
                           github: remote.map { "\($0.status.rawValue)\($0.busy ? ", busy" : "")" } ?? (github == nil ? "unknown" : "not registered"),
                           service: local.map { service($0.service) } ?? "unknown",
                           toolchain: local.map { "bun \($0.bunVersion ?? "?"), node \($0.nodeVersion ?? "?")" } ?? "",
                           plans: state.assessment.plans.filter { $0.subject == .runner(spec.name) })
            }
        }
        let declared = Set(rows.map(\.name))
        rows += (github?.runners ?? []).filter { !declared.contains($0.name) }.map { remote in
            Row(name: remote.name, host: "not in inventory", github: "\(remote.status.rawValue)\(remote.busy ? ", busy" : "")",
                service: "", toolchain: "", plans: state.assessment.plans.filter { $0.subject == .runner(remote.name) })
        }
        return rows
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow { ForEach(["Runner", "Host", "GitHub", "Service", "Toolchain", ""], id: \.self) { Text($0).bold() } }
            Divider()
            ForEach(rows) { row in
                GridRow {
                    Text(row.name).font(.callout.monospaced())
                    Text(row.host)
                    Text(row.github)
                    Text(row.service)
                    Text(row.toolchain).font(.callout)
                    HStack { ForEach(row.plans) { PlanButton(plan: $0, store: store) } }.controlSize(.small)
                }
            }
        }
        ForEach(state.assessment.findings.filter { if case .runner = $0.subject { true } else { false } }) {
            FindingRow(finding: $0, store: store)
        }
    }

    func service(_ state: RunnerServiceFacts.ServiceState) -> String {
        switch state {
        case .running(let pid): "running (\(pid))"
        case .loadedNotRunning(let code): "loaded, stopped\(code.map { " (\($0))" } ?? "")"
        case .notLoaded: "not loaded"
        case .unknown: "unknown"
        }
    }
}

struct QueuePane: View {
    let state: FleetState
    let store: FleetStore

    var body: some View {
        let queue = state.assessment.queue
        if queue.isEmpty { Text("Nothing is queued or running.") }
        ForEach(QueueLane.allCases, id: \.self) { lane in
            let entries = queue.filter { $0.lane == lane }
            if !entries.isEmpty {
                Heading("\(lane.title) (\(entries.count))")
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    ForEach(entries) { entry in
                        GridRow {
                            Text(entry.run.headBranch ?? "?").font(.callout.monospaced()).lineLimit(1)
                            Text(entry.run.status)
                            Text(age(entry.run.createdAt)).monospacedDigit()
                            Text(entry.dispositions.map(label).joined(separator: ", "))
                            Link("run", destination: URL(string: entry.run.htmlUrl)!)
                        }
                    }
                }
                .font(.callout)
            }
        }
        ForEach(state.assessment.findings.filter { $0.id.hasPrefix("queue.") }) { FindingRow(finding: $0, store: store) }
    }

    func label(_ disposition: QueueEntry.Disposition) -> String {
        switch disposition {
        case .superseded: "superseded"
        case .pullRequestClosed: "PR closed"
        case .likelyRedOnMain: "main is red"
        }
    }
}

struct EventsPane: View {
    let events: [FleetEvent]

    var body: some View {
        if events.isEmpty { Text("No events yet. History is kept while the app runs.") }
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            ForEach(events) { event in
                GridRow {
                    Text(event.at, format: .dateTime.month().day().hour().minute()).monospacedDigit()
                    Image(systemName: event.severity?.symbol ?? "circle").foregroundStyle(event.severity?.tint ?? .secondary)
                    Text(event.title)
                    Text(event.detail ?? "").font(.caption).lineLimit(2)
                }
            }
        }
        .font(.callout)
    }
}

/// Shows the exact commands, their effect and preconditions. Runs only on the Run button.
struct PlanReviewWindow: View {
    let store: FleetStore
    @State private var confirmedTwice = false

    var body: some View {
        if let review = store.review {
            let plan = review.plan
            VStack(alignment: .leading, spacing: 10) {
                Text(plan.title).font(.title3.bold())
                Text(plan.effect).fixedSize(horizontal: false, vertical: true)
                Heading("Checked again right before it runs")
                ForEach(plan.preconditions, id: \.self) { Label($0.description, systemImage: "checkmark.shield") }
                if plan.preconditions.isEmpty { Text("No preconditions.") }
                Heading("Commands, in order")
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(index + 1). \(step.description)")
                        Text(command(step.action, plan: plan)).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
                Text("The review expires at \(review.reviewedAt.addingTimeInterval(PlanReview.lifetime).formatted(date: .omitted, time: .shortened)). If GitHub or the host changed since the review, nothing runs.")
                    .font(.callout)
                if plan.requiresSecondConfirmation {
                    Toggle("I checked the names above; this cannot be undone from the app", isOn: $confirmedTwice)
                }
                HStack {
                    Button("Cancel") { store.review = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if store.runningPlanID == plan.id { ProgressView().controlSize(.small) }
                    // No default-button shortcut: Return must never run a plan, some of which cannot be undone.
                    Button("Run") { store.run(review) }
                        .disabled(store.runningPlanID != nil || (plan.requiresSecondConfirmation && !confirmedTwice) || store.isDemo)
                }
                if let outcome = store.outcome, outcome.planID == plan.id { OutcomeView(outcome: outcome) }
            }
            .padding(16)
            .frame(width: 620, alignment: .leading)
            .onChange(of: review.id) { confirmedTwice = false }
        } else {
            Text("No plan under review.").padding()
        }
    }

    func command(_ action: PlanAction, plan: Plan) -> String {
        switch action {
        case .hostCommand(let hostID, let command, let token): "[\(hostID)] \(command)" + (token.map { "   (a \($0.rawValue) token arrives on stdin)" } ?? "")
        case .localCommand(let invocation): invocation.displayText
        case .cancelRun(let id): "POST actions/runs/\(id)/cancel"
        case .deleteRunnerRegistration(let id, let name): "DELETE actions/runners/\(id) (\(name))"
        }
    }
}

struct OutcomeView: View {
    let outcome: PlanOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(outcome.succeeded ? "\(outcome.title): done" : "\(outcome.title): did not complete",
                  systemImage: outcome.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(outcome.succeeded ? .green : .red)
            ForEach(outcome.refusals, id: \.self) { Text($0) }
            ForEach(outcome.completedSteps, id: \.description) { Text("Done: \($0.description)").font(.callout) }
            if let failed = outcome.failedStep {
                Text("Failed: \(failed.description)").bold()
                Text(failed.output).font(.caption.monospaced()).textSelection(.enabled).lineLimit(12)
            }
            if let recovery = outcome.recovery {
                Text(recovery).font(.callout.monospaced()).textSelection(.enabled)
            }
        }
    }
}
