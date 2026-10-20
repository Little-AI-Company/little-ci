import AppKit
import LittleCICore
import Observation
import UserNotifications

/// The app's one source of truth: the latest fleet state, and the plan under review.
@Observable @MainActor
final class FleetStore {
    private(set) var state: FleetState?
    private(set) var setupProblem: String?
    private(set) var isDemo = false
    var review: PlanReview?
    private(set) var runningPlanID: String?
    private(set) var outcome: PlanOutcome?

    private var monitor: FleetMonitor?
    private var launchedInDemo = false
    private var liveState: FleetState?
    private var apiServer: LocalAPIServer?
    /// Nil until the first state arrives; then history already on disk counts as announced.
    private var announced: Set<UUID>?
    private let apiState = APIStateBox()

    /// Starts live monitoring, unless the app was launched with demo data (then it waits until demo is turned off).
    func start() {
        if LaunchOptions.current.demo, !launchedInDemo {
            launchedInDemo = true
            setDemo(true)
        }
        if !isDemo { startLive() }
    }

    private func startLive() {
        guard monitor == nil, setupProblem == nil else { return }
        let inventory: Inventory
        do {
            inventory = try Inventory.load(from: AppPaths.inventory)
        } catch {
            setupProblem = "No usable inventory at \(AppPaths.inventory.path): \(error). Copy app/inventory.example.json there and edit it, or turn on demo data."
            return
        }
        let settings = AppSettings.load()
        let monitor = FleetMonitor(inventory: inventory, settings: settings) { [weak self] state in
            await self?.receive(state)
        }
        self.monitor = monitor
        Task { await monitor.start() }
        if settings.localAPIEnabled { startAPI() }
    }

    private func receive(_ state: FleetState) {
        liveState = state
        Task { await apiState.set(isDemo ? DemoFleet.state() : state) }
        guard !isDemo else { return }
        self.state = state
        announce(state)
    }

    // MARK: Actions

    func refresh() {
        guard let monitor, !isDemo else { return }
        Task { await monitor.refreshNow() }
    }

    func setDemo(_ on: Bool) {
        isDemo = on
        state = on ? DemoFleet.state() : liveState
        Task { await apiState.set(state) }
        if !on { startLive() }
    }

    func setLent(_ hostID: String, _ lent: Bool) {
        guard let monitor, !isDemo else { return }
        Task { await monitor.setLent(hostID, lent) }
    }

    func pauseNotifications(_ hostID: String, for duration: TimeInterval?) {
        guard let monitor else { return }
        Task { await monitor.setMaintenance(hostID, until: duration.map { Date().addingTimeInterval($0) }) }
    }

    func setNotifications(_ enabled: Bool) {
        guard let monitor else { return }
        if enabled { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
        Task { await monitor.updateSettings { $0.notificationsEnabled = enabled } }
    }

    func beginReview(_ plan: Plan) {
        outcome = nil
        review = PlanReview(plan: plan, reviewedAt: Date())
    }

    func run(_ review: PlanReview) {
        guard let monitor, !isDemo, runningPlanID == nil else { return }
        runningPlanID = review.plan.id
        Task {
            let result = await monitor.execute(review)
            outcome = result
            runningPlanID = nil
        }
    }

    func plans(for ids: [String]) -> [Plan] { ids.compactMap { state?.assessment.plan($0) } }

    // MARK: Local API and notifications

    private func startAPI() {
        let port = ProcessInfo.processInfo.environment["LITTLE_CI_API_PORT"].flatMap(UInt16.init) ?? APIRouter.defaultPort
        let box = apiState
        do {
            let server = try LocalAPIServer(port: port) { await box.get() }
            server.start()
            apiServer = server
        } catch {
            setupProblem = "The local API could not listen on 127.0.0.1:\(port): \(error)"
        }
    }

    private func announce(_ state: FleetState) {
        guard var seen = announced else {
            announced = Set(state.events.map(\.id))
            return
        }
        defer { announced = seen }
        guard state.settings.notificationsEnabled, Bundle.main.bundleIdentifier != nil else {
            seen.formUnion(state.events.map(\.id))
            return
        }
        let fresh = state.events.filter { $0.kind == .findingRaised && ($0.severity ?? .info) >= .warning && !seen.contains($0.id) }
        for event in fresh {
            seen.insert(event.id)
            if case .host(let id) = event.subject, let until = state.settings.maintenanceUntil[id], until > Date() { continue }
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.detail ?? ""
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil))
        }
    }
}

/// The state the local API serves, readable from the server's queue.
actor APIStateBox {
    private var state: FleetState?
    func set(_ state: FleetState?) { self.state = state }
    func get() -> FleetState? { state }
}
