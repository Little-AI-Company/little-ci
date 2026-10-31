import Foundation
@testable import LittleCICore

enum Fixture {
    static let directory = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    static func data(_ path: String) -> Data { try! Data(contentsOf: directory.appendingPathComponent(path)) }
    static func text(_ path: String) -> String { String(decoding: data(path), as: UTF8.self) }

    static func decode<Value: Decodable>(_ type: Value.Type, _ path: String) -> Value {
        try! GitHubClient.decoder.decode(type, from: data(path))
    }

    static let now = try! Date("2026-10-20T16:30:00Z", strategy: .iso8601)

    static func runner(_ name: String, labels: [String]) -> RunnerSpec { RunnerSpec(name: name, labels: labels) }

    static let inventory = Inventory(
        github: GitHubTarget(scope: .repository, owner: "example-owner", repository: "example-repo"),
        hosts: [
            HostSpec(id: "m1", name: "M1",
                     kind: .macLaunchd(MacLaunchdHost(user: "builder1", runnerRoot: "/Users/builder1/actions-runners.noindex",
                                                      serviceLabelPrefix: "com.example.ci-runner.")),
                     access: .local, lendable: true,
                     runners: (1...4).map { runner("ci-m1-check-\($0)", labels: ["example-repo-m1", "example-repo-check"]) }
                        + [runner("ci-m1-candidate-1", labels: ["example-repo-m1", "example-repo-candidate"])]),
            HostSpec(id: "m4", name: "M4",
                     kind: .macLaunchd(MacLaunchdHost(user: "builder2", runnerRoot: "/Users/builder2/actions-runners.noindex",
                                                      serviceLabelPrefix: "com.example.ci-runner.")),
                     access: .ssh(destination: "builder2@studio-m4.local"), maxConcurrentJobs: 2,
                     runners: (1...2).map { runner("ci-m4-check-\($0)", labels: ["example-repo-m4", "example-repo-check"]) }
                        + [runner("ci-m4-candidate-1", labels: ["example-repo-m4", "example-repo-candidate"])]),
        ],
        queue: {
            var policy = QueuePolicy()
            policy.checkLabel = "example-repo-check"
            return policy
        }())

    static let toolchain = ToolchainRequirement(bunVersion: "1.3.14", minimumNodeMajor: 24)

    static func runners(online: Set<String>, busy: Set<String> = []) -> [GitHubRunner] {
        struct Page: Decodable { var runners: [GitHubRunner] }
        return decode(Page.self, "github/runners-2026-10-20.json").runners.map { runner in
            var runner = runner
            runner.status = online.contains(runner.name) ? .online : .offline
            runner.busy = busy.contains(runner.name)
            return runner
        }
    }

    static func snapshot(online: Set<String>, busy: Set<String> = [], activeRuns: [WorkflowRun] = [],
                         redMainJobs: [String] = [], pullRequests: [String: PullRequestState] = [:]) -> GitHubSnapshot {
        GitHubSnapshot(observedAt: now, runners: runners(online: online, busy: busy), activeRuns: activeRuns,
                       redMainJobs: redMainJobs, pullRequests: pullRequests, toolchain: toolchain)
    }

    static let m1CheckRunners: Set<String> = Set((1...4).map { "ci-m1-check-\($0)" })
    static let m4CheckRunners: Set<String> = ["ci-m4-check-1", "ci-m4-check-2"]
}

struct ProbeFixture {
    var envelope: [String: Any]

    init(_ name: String) {
        envelope = try! JSONSerialization.jsonObject(with: Fixture.data("probes/\(name).json")) as! [String: Any]
    }

    init(sections: [String: (exit: Int, text: String)]) {
        envelope = ["probeVersion": ProbeScript.version,
                    "sections": sections.mapValues { ["exit": $0.exit, "output": Data($0.text.utf8).base64EncodedString()] }]
    }

    static func linuxHost(_ hostname: String) -> ProbeFixture {
        ProbeFixture(sections: ["identity": (0, "\(hostname)\n1000\n")])
    }

    static func absentOrbStackVM(_ machine: String) -> ProbeFixture {
        ProbeFixture(sections: ["vm_info": (1, "[-32098] machine not found: '\(machine)'")])
    }

    static func orbStackVM(_ machine: String, runnerUser: String, identity: String) -> ProbeFixture {
        let record = OrbStackVMFacts.Info.Record(
            name: machine, state: "running", image: .init(distro: "ubuntu", version: "noble", arch: "arm64"),
            config: .init(isolated: true, isolateNetwork: true, defaultUsername: runnerUser, forwardSSHAgent: false),
            osRelease: .init(versionID: "24.04"))
        let info = String(decoding: try! JSONEncoder().encode(OrbStackVMFacts.Info(record: record)), as: UTF8.self)
        let guest = String(decoding: try! JSONSerialization.data(withJSONObject: linuxHost(machine).envelope), as: UTF8.self)
        return ProbeFixture(sections: ["vm_info": (0, info), "vm_mounts": (0, ""), "vm_identity": (0, identity), "guest": (0, guest)])
    }

    func section(_ name: String) -> String {
        let sections = envelope["sections"] as! [String: [String: Any]]
        return String(decoding: Data(base64Encoded: sections[name]!["output"] as! String)!, as: UTF8.self)
    }

    func replacing(_ name: String, with text: String, exit: Int = 0) -> ProbeFixture {
        var copy = self
        var sections = envelope["sections"] as! [String: [String: Any]]
        sections[name] = ["exit": exit, "output": Data(text.utf8).base64EncodedString()]
        copy.envelope["sections"] = sections
        return copy
    }

    func facts(for hostID: String) -> HostFacts {
        let data = try! JSONSerialization.data(withJSONObject: envelope)
        return try! ProbeParser.parse(data, for: Fixture.inventory.host(hostID)!, observedAt: Fixture.now)
    }

    func observation(for hostID: String) -> HostObservation {
        HostObservation(hostID: hostID, attemptedAt: Fixture.now, outcome: .reached(facts(for: hostID)))
    }
}

func assess(github: GitHubSnapshot?, hosts: [String: HostObservation], lent: Set<String> = []) -> Assessment {
    Assessor.assess(FleetObservations(inventory: Fixture.inventory, github: github, hosts: hosts, lentHosts: lent), now: Fixture.now)
}

extension Assessment {
    func finding(_ id: String) -> Finding? { findings.first { $0.id == id } }
}
