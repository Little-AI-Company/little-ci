import Foundation

public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var standardOutput: Data
    public var standardError: Data

    public init(exitCode: Int32, standardOutput: Data, standardError: Data) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var outputText: String { String(decoding: standardOutput, as: UTF8.self) }
    public var errorText: String { String(decoding: standardError, as: UTF8.self) }
}

public struct CommandInvocation: Sendable, Equatable, Codable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String?

    public init(_ executable: String, _ arguments: [String], workingDirectory: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    /// The command as a person would type it, for plan review and recovery text.
    public var displayText: String {
        let words = ([executable] + arguments).map { word in
            word.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@,+".contains($0) }) ? word : "'\(word.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        return (workingDirectory.map { "cd '\($0)' && " } ?? "") + words.joined(separator: " ")
    }
}

/// The process boundary. Tests replace it; nothing else in the core starts processes.
public protocol CommandRunning: Sendable {
    func run(_ invocation: CommandInvocation, standardInput: Data?, timeout: Duration) async throws -> CommandResult
}

public enum CommandError: Error, Equatable, CustomStringConvertible {
    case timedOut(String)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .timedOut(let command): "Timed out: \(command)"
        case .launchFailed(let reason): "Could not start the command: \(reason)"
        }
    }
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ invocation: CommandInvocation, standardInput: Data?, timeout: Duration) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try Self.runBlocking(invocation, standardInput: standardInput, timeout: timeout) })
            }
        }
    }

    private static func runBlocking(_ invocation: CommandInvocation, standardInput: Data?, timeout: Duration) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        if let directory = invocation.workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch { throw CommandError.launchFailed(error.localizedDescription) }

        let reader = DispatchGroup()
        nonisolated(unsafe) var standardOutput = Data(), standardError = Data()
        reader.enter()
        DispatchQueue.global().async { standardOutput = output.fileHandleForReading.readDataToEndOfFile(); reader.leave() }
        reader.enter()
        DispatchQueue.global().async { standardError = error.fileHandleForReading.readDataToEndOfFile(); reader.leave() }
        if let standardInput { try? input.fileHandleForWriting.write(contentsOf: standardInput) }
        try? input.fileHandleForWriting.close()

        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        if reader.wait(timeout: .now() + seconds) == .timedOut {
            process.terminate()
            _ = reader.wait(timeout: .now() + 5)
            throw CommandError.timedOut(invocation.displayText)
        }
        process.waitUntilExit()
        return CommandResult(exitCode: process.terminationStatus, standardOutput: standardOutput, standardError: standardError)
    }
}

extension HostAccess {
    /// A shell on this host that reads its script from standard input.
    public var shellInvocation: CommandInvocation { invocation(remoteCommand: "/bin/bash -s") }

    /// One command on this host. Remote commands go through OpenSSH with agent and port forwarding off.
    public func invocation(remoteCommand: String) -> CommandInvocation {
        switch self {
        case .local:
            CommandInvocation("/bin/bash", ["-c", remoteCommand])
        case .ssh(let destination):
            CommandInvocation("/usr/bin/ssh", [
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=yes",
                "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes", destination, remoteCommand,
            ])
        }
    }
}

/// Runs one probe round trip against one host and returns a timestamped observation.
public struct HostProber: Sendable {
    public var runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) { self.runner = runner }

    public func observe(_ host: HostSpec, in inventory: Inventory, includePowerLog: Bool, previous: HostObservation?,
                        now: Date = Date()) async -> HostObservation {
        let access = Self.access(for: host, in: inventory)
        let script = ProbeScript.script(for: host, includePowerLog: includePowerLog)
        let outcome: HostObservation.Outcome
        do {
            let result = try await runner.run(access.shellInvocation, standardInput: Data(script.utf8),
                                              timeout: includePowerLog ? .seconds(60) : .seconds(30))
            if result.exitCode == 255, case .ssh = access {
                outcome = .unreachable(result.errorText.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                outcome = .reached(try ProbeParser.parse(result.standardOutput, for: host, observedAt: now))
            }
        } catch {
            outcome = .unreachable(String(describing: error))
        }
        return HostObservation(hostID: host.id, attemptedAt: now, outcome: outcome,
                               lastFacts: outcome.facts ?? previous?.facts ?? previous?.lastFacts)
    }

    /// A VM is reached through the Mac that runs it.
    public static func access(for host: HostSpec, in inventory: Inventory) -> HostAccess {
        if case .orbstackVM(let vm) = host.kind, let parent = inventory.host(vm.parentHost) { return parent.access }
        return host.access
    }
}

extension HostObservation.Outcome {
    var facts: HostFacts? { if case .reached(let facts) = self { facts } else { nil } }
}
