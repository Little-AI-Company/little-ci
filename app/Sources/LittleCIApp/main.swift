import Foundation
import LittleCICore

// `LittleCI probe <host-id> [--raw] [--power-log]` prints one probe's facts as JSON and exits.
// With no subcommand, the menu bar app starts.
let arguments = CommandLine.arguments.dropFirst()
if arguments.first == "probe", let hostID = arguments.dropFirst().first {
    await runProbeCommand(hostID: hostID, raw: arguments.contains("--raw"), powerLog: arguments.contains("--power-log"))
} else {
    LittleCIApp.main()
}

func runProbeCommand(hostID: String, raw: Bool, powerLog: Bool) async {
    do {
        let inventory = try Inventory.load(from: AppPaths.inventory)
        guard let host = inventory.host(hostID) else {
            FileHandle.standardError.write(Data("No host \(hostID) in \(AppPaths.inventory.path)\n".utf8))
            exit(2)
        }
        let access = HostProber.access(for: host, in: inventory)
        let script = ProbeScript.script(for: host, includePowerLog: powerLog)
        let result = try await ProcessCommandRunner().run(access.shellInvocation, standardInput: Data(script.utf8), timeout: .seconds(90))
        if raw {
            FileHandle.standardOutput.write(result.standardOutput)
        } else {
            let facts = try ProbeParser.parse(result.standardOutput, for: host, observedAt: Date())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            FileHandle.standardOutput.write(try encoder.encode(facts))
        }
        exit(result.exitCode == 0 ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}
