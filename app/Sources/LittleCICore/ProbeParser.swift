import Foundation

/// Turns one probe's JSON into `HostFacts`. Parsing lives here, in typed code, so recorded real
/// output from each host is the test fixture.
public enum ProbeParser {
    struct Envelope: Decodable {
        var probeVersion: Int
        var sections: [String: Section]
    }

    struct Section: Decodable {
        var exit: Int
        var output: String

        var text: String { String(decoding: Data(base64Encoded: output) ?? Data(), as: UTF8.self) }
        var succeeded: Bool { exit == 0 }
        var lines: [Substring] { text.split(separator: "\n", omittingEmptySubsequences: true) }
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case notJSON(String)
        case unsupportedVersion(Int)
        case missingSection(String)

        public var description: String {
            switch self {
            case .notJSON(let head): "The probe did not return JSON: \(head)"
            case .unsupportedVersion(let version): "Probe version \(version) is not supported (expected \(ProbeScript.version))"
            case .missingSection(let name): "The probe output has no \(name) section"
            }
        }
    }

    public static func parse(_ output: Data, for host: HostSpec, observedAt: Date) throws -> HostFacts {
        let envelope = try decodeEnvelope(output)
        switch host.kind {
        case .macLaunchd: return try parseMac(envelope.sections, runners: host.runners.map(\.name), observedAt: observedAt)
        case .linuxServer: return try parseLinux(envelope.sections, runners: host.runners.map(\.name), observedAt: observedAt)
        case .orbstackVM:
            let machine = try parseOrbStackVM(output)
            if machine.machineState != .present {
                // No guest to read (absent or unreadable), but the Mac side answered.
                return HostFacts(probeVersion: ProbeScript.version, observedAt: observedAt, hostname: "", userID: nil, cpuCount: nil,
                                 memoryBytes: nil, loadAverage: [], memoryFreePercent: nil, swapUsedBytes: nil, swapTotalBytes: nil,
                                 onACPower: nil, volumes: [], docker: nil, orbstack: nil, virtualMachine: machine, runners: [],
                                 recentPowerEvents: [])
            }
            guard let guest = envelope.sections["guest"] else { throw ParseError.missingSection("guest") }
            let guestEnvelope = try decodeEnvelope(Data(guest.text.utf8))
            var facts = try parseLinux(guestEnvelope.sections, runners: host.runners.map(\.name), observedAt: observedAt)
            facts.virtualMachine = try parseOrbStackVM(output)
            return facts
        }
    }

    /// VM-level facts that only the Mac side of an OrbStack probe has.
    public static func parseOrbStackVM(_ output: Data) throws -> OrbStackVMFacts {
        let sections = try decodeEnvelope(output).sections
        let section = sections["vm_info"]
        let info = section.flatMap { section -> OrbStackVMFacts.Info? in
            guard section.succeeded else { return nil }
            return try? JSONDecoder().decode(OrbStackVMFacts.Info.self, from: Data(section.text.utf8))
        }
        let state: OrbStackVMFacts.MachineState = if info != nil { .present }
            else if let section, !section.succeeded, section.text.contains("machine not found") { .absent }
            else { .unreadable }
        let mounts = sections["vm_mounts"]
        let identity = sections["vm_identity"]
        return OrbStackVMFacts(
            machineState: state,
            info: info,
            mountsReadable: mounts?.succeeded ?? false,
            mounts: mounts?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            identity: identity?.succeeded == true ? identity?.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
    }

    static func decodeEnvelope(_ output: Data) throws -> Envelope {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: output)
        } catch {
            throw ParseError.notJSON(String(decoding: output.prefix(200), as: UTF8.self))
        }
        guard envelope.probeVersion == ProbeScript.version else { throw ParseError.unsupportedVersion(envelope.probeVersion) }
        return envelope
    }

    // MARK: macOS

    static func parseMac(_ sections: [String: Section], runners: [String], observedAt: Date) throws -> HostFacts {
        guard let identity = sections["identity"], identity.succeeded else { throw ParseError.missingSection("identity") }
        let identityLines = identity.lines.map(String.init)
        let sysctl = sections["sysctl"]?.lines.map(String.init) ?? []
        let swap = sysctl.first { $0.hasPrefix("vm.swapusage") }

        return HostFacts(
            probeVersion: ProbeScript.version,
            observedAt: observedAt,
            hostname: identityLines.first ?? "",
            userID: identityLines.dropFirst().first.flatMap { Int($0) },
            cpuCount: sysctl.first.flatMap { Int($0) },
            memoryBytes: sysctl.dropFirst().first.flatMap { Int64($0) },
            loadAverage: sysctl.dropFirst(2).first.map(parseLoadAverage) ?? [],
            memoryFreePercent: sections["memory_pressure"]?.text.firstMatch(of: /free percentage: (\d+)%/).flatMap { Int($0.1) },
            swapUsedBytes: swap.flatMap { megabytes(in: $0, after: "used") },
            swapTotalBytes: swap.flatMap { megabytes(in: $0, after: "total") },
            onACPower: sections["power"].map { $0.text.contains("'AC Power'") },
            volumes: parseVolumes(df: sections["df"]?.text ?? "", readOnlyMounts: macReadOnlyMounts(sections["mount"]?.text ?? "")),
            docker: parseDocker(sections),
            orbstack: parseOrbStack(sections),
            virtualMachine: nil,
            runners: runners.map { parseMacRunner($0, sections) },
            recentPowerEvents: parsePowerLog(sections["power_log"]?.text ?? ""))
    }

    static func parseMacRunner(_ name: String, _ sections: [String: Section]) -> RunnerServiceFacts {
        let prefix = "runner.\(name)."
        let service = sections[prefix + "service"]
        let serviceState: RunnerServiceFacts.ServiceState
        if let service {
            let text = service.text
            if text.contains("Could not find service") {
                serviceState = .notLoaded
            } else if let pid = text.firstMatch(of: /pid = (\d+)/).flatMap({ Int($0.1) }) {
                serviceState = .running(pid: pid)
            } else if text.contains("state = ") {
                serviceState = .loadedNotRunning(lastExitCode: text.firstMatch(of: /last exit code = (-?\d+)/).flatMap { Int($0.1) })
            } else {
                serviceState = .unknown(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } else {
            serviceState = .unknown("no service section")
        }
        return RunnerServiceFacts(
            name: name,
            directoryExists: sections[prefix + "directory"]?.succeeded ?? false,
            registeredURL: registeredURL(sections[prefix + "registration"]),
            registeredName: registeredName(sections[prefix + "registration"]),
            serviceDefinitionExists: sections[prefix + "definition"]?.succeeded ?? false,
            service: serviceState,
            bunVersion: version(sections[prefix + "bun"]),
            nodeVersion: version(sections[prefix + "node"]))
    }

    static func macReadOnlyMounts(_ mount: String) -> Set<String> {
        Set(mount.split(separator: "\n").compactMap { line in
            guard let match = line.firstMatch(of: /^.+? on (.+) \(([^()]*)\)$/) else { return nil }
            return match.2.contains("read-only") ? String(match.1) : nil
        })
    }

    // MARK: Linux

    static func parseLinux(_ sections: [String: Section], runners: [String], observedAt: Date) throws -> HostFacts {
        guard let identity = sections["identity"], identity.succeeded else { throw ParseError.missingSection("identity") }
        let identityLines = identity.lines.map(String.init)
        let loadLines = sections["loadavg"]?.lines.map(String.init) ?? []
        var memory: [String: Int64] = [:]
        for line in sections["meminfo"]?.lines ?? [] {
            if let match = line.firstMatch(of: /^(\w+):\s+(\d+) kB/) { memory[String(match.1)] = Int64(match.2).map { $0 * 1024 } }
        }
        let readOnly = Set((sections["mount"]?.lines ?? []).compactMap { line -> String? in
            let fields = line.split(separator: " ")
            guard fields.count >= 4 else { return nil }
            return fields[3].split(separator: ",").contains("ro") ? String(fields[1]) : nil
        })
        let freePercent = memory["MemTotal"].flatMap { total in memory["MemAvailable"].map { Int($0 * 100 / max(total, 1)) } }

        return HostFacts(
            probeVersion: ProbeScript.version,
            observedAt: observedAt,
            hostname: identityLines.first ?? "",
            userID: identityLines.dropFirst().first.flatMap { Int($0) },
            cpuCount: loadLines.first.flatMap { Int($0) },
            memoryBytes: memory["MemTotal"],
            loadAverage: loadLines.dropFirst().first.map { $0.split(separator: " ").prefix(3).compactMap { Double($0) } } ?? [],
            memoryFreePercent: freePercent,
            swapUsedBytes: memory["SwapTotal"].flatMap { total in memory["SwapFree"].map { total - $0 } },
            swapTotalBytes: memory["SwapTotal"],
            onACPower: nil,
            volumes: parseVolumes(df: sections["df"]?.text ?? "", readOnlyMounts: readOnly),
            docker: parseDocker(sections),
            orbstack: nil,
            virtualMachine: nil,
            runners: runners.map { parseLinuxRunner($0, sections) },
            recentPowerEvents: [])
    }

    static func parseLinuxRunner(_ name: String, _ sections: [String: Section]) -> RunnerServiceFacts {
        let prefix = "runner.\(name)."
        var properties: [String: String] = [:]
        for line in sections[prefix + "service"]?.lines ?? [] {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { properties[String(parts[0])] = String(parts[1]) }
        }
        let serviceState: RunnerServiceFacts.ServiceState = switch (properties["LoadState"], properties["ActiveState"]) {
        case ("loaded", "active"): .running(pid: Int(properties["MainPID"] ?? "") ?? 0)
        case ("loaded", _): .loadedNotRunning(lastExitCode: Int(properties["ExecMainStatus"] ?? ""))
        case ("not-found", _): .notLoaded
        default: .unknown(properties.isEmpty ? "systemctl returned nothing" : properties.description)
        }
        return RunnerServiceFacts(
            name: name,
            directoryExists: sections[prefix + "directory"]?.succeeded ?? false,
            registeredURL: registeredURL(sections[prefix + "registration"]),
            registeredName: registeredName(sections[prefix + "registration"]),
            serviceDefinitionExists: sections[prefix + "definition"]?.succeeded ?? false,
            service: serviceState,
            bunVersion: nil,
            nodeVersion: nil)
    }

    // MARK: Shared

    static func parseLoadAverage(_ text: String) -> [Double] {
        text.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
            .split(separator: " ").compactMap { Double($0) }
    }

    static func megabytes(in line: String, after key: String) -> Int64? {
        guard let match = line.firstMatch(of: try! Regex("\(key) = ([0-9.]+)M")),
              let value = match.output[1].substring.flatMap({ Double($0) }) else { return nil }
        return Int64(value * 1_048_576)
    }

    /// `df -k -P`. Filesystem names and mount points may contain spaces, so match from the numbers.
    static func parseVolumes(df: String, readOnlyMounts: Set<String>) -> [VolumeFacts] {
        df.split(separator: "\n").dropFirst().compactMap { line in
            guard let match = line.firstMatch(of: /^(.+?)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)%\s+(\/.*)$/),
                  let total = Int64(match.2), let available = Int64(match.4) else { return nil }
            let mountPoint = String(match.6)
            return VolumeFacts(device: String(match.1), mountPoint: mountPoint, totalBytes: total * 1024,
                               availableBytes: available * 1024, isReadOnly: readOnlyMounts.contains(mountPoint))
        }
    }

    static func parseDocker(_ sections: [String: Section]) -> DockerFacts? {
        guard let socket = sections["docker_socket"] else { return nil }
        let info = sections["docker_info"]
        let serverVersion = info?.succeeded == true ? info?.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return DockerFacts(
            socketPath: "/var/run/docker.sock",
            socketExists: socket.succeeded && socket.text.hasPrefix("s"),
            serverVersion: serverVersion.flatMap { $0.isEmpty ? nil : $0 },
            error: info?.succeeded == true ? nil : info?.text.trimmingCharacters(in: .whitespacesAndNewlines),
            composeVersion: version(sections["docker_compose"]))
    }

    static func parseOrbStack(_ sections: [String: Section]) -> OrbStackFacts? {
        guard let versionSection = sections["orbstack_version"], versionSection.succeeded else { return nil }
        let vmgr = sections["orbstack_vmgr"]?.lines.map(String.init) ?? []
        let lastStart = vmgr.lastIndex { $0.contains("phase=verify_rosetta") }
        let sinceStart = lastStart.map { Array(vmgr[$0...]) } ?? vmgr
        let failures = sinceStart.filter { $0.contains("could not be mounted") || $0.contains("Init failed") || $0.contains("Failed to mount") }
        return OrbStackFacts(
            version: versionSection.text.firstMatch(of: /Version: (\S+)/).map { String($0.1) },
            status: sections["orbstack_status"]?.text.trimmingCharacters(in: .whitespacesAndNewlines),
            dataMountFailed: !failures.isEmpty,
            lastStartAt: lastStart.flatMap { vmgr[$0].firstMatch(of: /time="([^"]+)"/).map { String($0.1) } },
            evidence: failures.map { $0.replacingOccurrences(of: #"^\S+ \S+ \| "#, with: "", options: .regularExpression) })
    }

    static func parsePowerLog(_ text: String) -> [PowerEvent] {
        let format = Date.ISO8601FormatStyle()
        return text.split(separator: "\n").compactMap { line in
            guard let match = line.firstMatch(of: /^(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d) ([-+]\d\d)(\d\d) (Sleep|Wake|DarkWake)\s+(.*)$/),
                  let at = try? format.parse("\(match.1)T\(match.2)\(match.3):\(match.4)") else { return nil }
            return PowerEvent(at: at, kind: String(match.5), reason: String(match.6.prefix(120)))
        }
    }

    static func registeredURL(_ section: Section?) -> String? {
        section?.text.firstMatch(of: /"gitHubUrl": *"([^"]*)"/).map { String($0.1) }
    }

    static func registeredName(_ section: Section?) -> String? {
        section?.text.firstMatch(of: /"agentName": *"([^"]*)"/).map { String($0.1) }
    }

    static func version(_ section: Section?) -> String? {
        guard let section, section.succeeded else { return nil }
        let text = section.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

public struct OrbStackVMFacts: Codable, Sendable, Equatable {
    /// `absent` only when `orbctl info` said "machine not found"; anything else unreadable fails closed.
    public enum MachineState: String, Codable, Sendable, CaseIterable { case present, absent, unreadable }

    public struct Info: Codable, Sendable, Equatable {
        public struct Record: Codable, Sendable, Equatable {
            public var name: String
            public var state: String
            public var image: Image?
            public var config: Config?
            public var osRelease: OSRelease?

            enum CodingKeys: String, CodingKey { case name, state, image, config, osRelease = "os_release" }
        }
        public struct Image: Codable, Sendable, Equatable {
            public var distro: String?
            public var arch: String?
        }
        public struct OSRelease: Codable, Sendable, Equatable {
            public var versionID: String?
            enum CodingKeys: String, CodingKey { case versionID = "version_id" }
        }
        public struct Config: Codable, Sendable, Equatable {
            public var isolated: Bool?
            public var isolateNetwork: Bool?
            public var defaultUsername: String?
            public var forwardSSHAgent: Bool?

            enum CodingKeys: String, CodingKey {
                case isolated, isolateNetwork = "isolate_network", defaultUsername = "default_username"
                case forwardSSHAgent = "forward_ssh_agent"
            }
        }
        public var record: Record
    }

    public var machineState: MachineState
    public var info: Info?
    public var mountsReadable: Bool
    public var mounts: String
    public var identity: String?
}
