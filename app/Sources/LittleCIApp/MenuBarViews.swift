import LittleCICore
import SwiftUI

extension Severity {
    var symbol: String {
        switch self {
        case .critical: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .critical: .red
        case .warning: .orange
        case .info: .secondary
        }
    }
}

/// The menu bar glyph: the worst current finding. A static symbol; nothing repaints continuously.
struct MenuBarGlyph: View {
    let store: FleetStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        glyph.task {
            // The label is the one view that always renders, so it opens the windows launch flags ask for.
            if LaunchOptions.current.showsDetails { openWindow(id: "details") }
            if LaunchOptions.current.showsPanel { openWindow(id: "panel") }
            if LaunchOptions.current.showsDetails || LaunchOptions.current.showsPanel { NSApp.activate() }
        }
    }

    @ViewBuilder private var glyph: some View {
        let worst = store.state?.assessment.worstSeverity
        let critical = store.state?.assessment.findings.filter { $0.severity == .critical }.count ?? 0
        HStack(spacing: 2) {
            Image(systemName: worst.map { $0 == .info ? "checkmark.circle" : $0.symbol } ?? (store.setupProblem == nil ? "circle.dotted" : "questionmark.circle"))
            if critical > 0 { Text("\(critical)").monospacedDigit() }
        }
        .accessibilityLabel(worst.map { "Little CI: worst finding \($0.rawValue)" } ?? "Little CI")
    }
}

struct MenuBarPanel: View {
    let store: FleetStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Little CI").font(.headline)
                if store.isDemo { Text("DEMO DATA").font(.caption.bold()).foregroundStyle(.orange) }
                Spacer()
                if let observed = store.state?.observations.github?.observedAt {
                    Text("GitHub \(observed, style: .relative) ago").font(.caption).monospacedDigit()
                }
            }
            if let problem = store.setupProblem {
                Text(problem).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let state = store.state {
                ServiceLevelGrid(levels: state.assessment.serviceLevels, compact: true)
                Divider()
                let findings = state.assessment.findings.filter { $0.severity >= .warning }
                if findings.isEmpty {
                    Label("No warnings", systemImage: "checkmark.circle").font(.callout)
                } else {
                    ForEach(findings.prefix(6)) { FindingRow(finding: $0, store: store, showsEvidence: false) }
                    if findings.count > 6 { Text("\(findings.count - 6) more in Details").font(.caption) }
                }
                let lendable = state.observations.inventory.hosts.filter(\.lendable)
                if !lendable.isEmpty {
                    Divider()
                    ForEach(lendable) { host in
                        Toggle("\(host.name) is lent to CI", isOn: Binding(
                            get: { state.settings.lentHosts.contains(host.id) },
                            set: { store.setLent(host.id, $0) }))
                        .disabled(store.isDemo)
                    }
                }
            }
            Divider()
            HStack {
                Button("Details") {
                    openWindow(id: "details")
                    NSApp.activate()
                }
                .keyboardShortcut("d")
                Button("Refresh") { store.refresh() }.keyboardShortcut("r").disabled(store.isDemo)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 380)
    }
}

struct ServiceLevelGrid: View {
    let levels: [ServiceLevel]
    var compact = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            ForEach(levels) { level in
                GridRow {
                    Image(systemName: level.met == nil ? "minus.circle" : level.met! ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(level.met == nil ? Color.secondary : level.met! ? Color.green : Color.red)
                    Text(level.name)
                    Text(level.measured).monospacedDigit()
                    if !compact { Text("target \(level.target)"); Text(level.basis).font(.caption) }
                }
                .font(compact ? .callout : .body)
            }
        }
    }
}

struct FindingRow: View {
    let finding: Finding
    let store: FleetStore
    var showsEvidence = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: finding.severity.symbol).foregroundStyle(finding.severity.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).fixedSize(horizontal: false, vertical: true)
                if showsEvidence {
                    ForEach(finding.evidence, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                    Text(finding.suggestedAction).font(.callout)
                }
                let plans = store.plans(for: finding.planIDs)
                if !plans.isEmpty {
                    HStack {
                        ForEach(plans) { PlanButton(plan: $0, store: store) }
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

/// Opens a plan for review. Nothing runs until the review window's Run button.
struct PlanButton: View {
    let plan: Plan
    let store: FleetStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("\(plan.title)…") {
            store.beginReview(plan)
            openWindow(id: "review")
            NSApp.activate()
        }
        .disabled(store.isDemo)
    }
}
