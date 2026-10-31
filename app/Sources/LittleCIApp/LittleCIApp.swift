import AppKit
import LittleCICore
import SwiftUI

struct LittleCIApp: App {
    @State private var store = FleetStore()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        if let appearance = LaunchOptions.current.appearance { NSApplication.shared.appearance = NSAppearance(named: appearance) }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(store: store)
                .task { store.start() }
        } label: {
            MenuBarGlyph(store: store)
                .task { store.start() }
        }
        .menuBarExtraStyle(.window)

        Window("Little CI", id: "details") {
            DetailsWindow(store: store)
                .task { store.start() }
        }
        .defaultSize(width: 980, height: 680)
        .defaultLaunchBehavior(.suppressed)

        Window("Little CI panel", id: "panel") {
            MenuBarPanel(store: store)
                .task { store.start() }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Review plan", id: "review") {
            PlanReviewWindow(store: store)
        }
        .windowResizability(.contentSize)
    }
}
