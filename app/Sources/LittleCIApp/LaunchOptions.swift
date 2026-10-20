import AppKit

/// Launch flags for reproducible screenshots (the crit skill uses them). None of them changes the fleet.
///
///   --show-details        open the details window at launch
///   --show-panel          also show the menu bar panel's content in a window
///   --pane <name>         overview, hosts, runners, queue or events
///   --demo                start with demo data
///   --appearance <mode>   light or dark
struct LaunchOptions {
    var showsDetails = false
    var showsPanel = false
    var pane: Pane = .overview
    var demo = false
    var appearance: NSAppearance.Name?

    static let current = LaunchOptions(arguments: CommandLine.arguments)

    init(arguments: [String]) {
        var remaining = arguments.dropFirst()[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--show-details": showsDetails = true
            case "--show-panel": showsPanel = true
            case "--demo": demo = true
            case "--pane": pane = remaining.popFirst().flatMap { Pane(rawValue: $0.capitalized) } ?? .overview
            case "--appearance":
                appearance = switch remaining.popFirst() {
                case "dark": .darkAqua
                case "light": .aqua
                default: nil
                }
            default: break
            }
        }
    }
}
