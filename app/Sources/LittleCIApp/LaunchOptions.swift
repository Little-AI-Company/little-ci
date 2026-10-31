import AppKit

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
