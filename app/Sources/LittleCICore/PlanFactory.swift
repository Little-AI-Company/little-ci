import Foundation

/// Builds plans with exact commands. Names in commands come from the validated inventory or GitHub's
/// runner list, and are quoted again here, so no observed text is ever run as shell code.
public enum PlanFactory {
    static func quote(_ text: String) -> String { "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'" }

    /// Unloads a launchd runner unless its worker process is running a job. GitHub's busy flag lags the
    /// moment a runner accepts a job, so the host itself is the last check (exit 75: busy, nothing changed).
    static func unloadIfIdle(_ mac: MacLaunchdHost, _ runner: String) -> String {
        let worker = "\(mac.runnerRoot)/\(runner)/bin/Runner.Worker"
        return "if pgrep -f -- \(quote(worker)) >/dev/null; then echo \(quote("\(runner) is running a job; not stopped")) >&2; exit 75; fi; "
            + "launchctl bootout gui/$(id -u)/\(quote(mac.serviceLabel(of: runner)))"
    }

    // MARK: launchd runners

    static func startService(_ host: HostSpec, _ runner: String, local: RunnerServiceFacts?) -> [Plan] {
        guard case .macLaunchd(let mac) = host.kind, local?.serviceDefinitionExists == true else { return [] }
        let label = mac.serviceLabel(of: runner)
        return [Plan(
            id: "start.\(runner)", title: "Start \(runner)", subject: .runner(runner),
            effect: "Loads \(label) in \(host.name)'s login session. The runner connects to GitHub and takes jobs.",
            steps: [PlanStep("Load the launchd agent", .hostCommand(hostID: host.id,
                command: "launchctl bootstrap gui/$(id -u) \"$HOME/Library/LaunchAgents/\"\(quote(label + ".plist"))", token: nil))],
            preconditions: [.hostMayTakeJobs(hostID: host.id), .serviceNotRunning(hostID: host.id, runner: runner)])]
    }

    static func stopService(_ host: HostSpec, _ runner: String) -> [Plan] {
        guard case .macLaunchd(let mac) = host.kind else { return [] }
        return [Plan(
            id: "stop.\(runner)", title: "Stop \(runner) (idle only)", subject: .runner(runner),
            effect: "Unloads \(mac.serviceLabel(of: runner)). The registration stays; Start loads it again.",
            steps: [PlanStep("Unload the launchd agent", .hostCommand(hostID: host.id, command: unloadIfIdle(mac, runner), token: nil))],
            preconditions: [.runnerIdle(name: runner)])]
    }

    /// Stops the given runners that GitHub reports idle; busy ones keep their jobs.
    static func drainIdleRunners(_ host: HostSpec, _ runners: [GitHubRunner], reason: String) -> [Plan] {
        guard case .macLaunchd(let mac) = host.kind else { return [] }
        let idle = runners.filter { !$0.busy }.map(\.name).sorted()
        guard !idle.isEmpty else { return [] }
        return [Plan(
            id: "drain.\(host.id)", title: "Stop \(host.name)'s idle check runners", subject: .host(host.id),
            effect: "\(reason). Unloads \(idle.joined(separator: ", ")) so they stop taking jobs that will fail. Busy runners are left alone.",
            steps: idle.map { name in PlanStep("Unload \(name)", .hostCommand(hostID: host.id, command: unloadIfIdle(mac, name), token: nil)) },
            preconditions: idle.map { .runnerIdle(name: $0) })]
    }

    static func startOrbStack(_ host: HostSpec) -> [Plan] {
        guard case .macLaunchd = host.kind else { return [] }
        return [Plan(
            id: "orbstack.start.\(host.id)", title: "Start OrbStack on \(host.name)", subject: .host(host.id),
            effect: "Runs `orbctl start`. Starting Docker interrupts no job.",
            steps: [PlanStep("Start OrbStack", .hostCommand(hostID: host.id,
                command: "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH orbctl start && docker info --format '{{.ServerVersion}}'", token: nil))],
            preconditions: [])]
    }

    /// Unregisters on GitHub first (config.sh remove deletes the local credentials itself), then removes the agent.
    /// The runner directory and its _work checkouts stay.
    static func retireLaunchdRunner(_ host: HostSpec, _ runner: String, inventory: Inventory) -> Plan? {
        guard case .macLaunchd(let mac) = host.kind else { return nil }
        let label = mac.serviceLabel(of: runner)
        let directory = "\(mac.runnerRoot)/\(runner)"
        return Plan(
            id: "retire.\(runner)", title: "Retire \(runner)", subject: .runner(runner),
            effect: "Stops \(label), unregisters \(runner) from \(inventory.github.owner)/\(inventory.github.repository), deletes its credentials and launchd agent. \(directory) and its _work folder stay.",
            steps: [
                PlanStep("Stop the service if it is loaded and idle", .hostCommand(hostID: host.id, command:
                    "if launchctl print gui/$(id -u)/\(quote(label)) >/dev/null 2>&1; then \(unloadIfIdle(mac, runner)); fi", token: nil)),
                PlanStep("Unregister on GitHub with a removal token from stdin", .hostCommand(hostID: host.id, command:
                    "IFS= read -r ACTIONS_RUNNER_INPUT_TOKEN && export ACTIONS_RUNNER_INPUT_TOKEN && cd \(quote(directory)) && ./config.sh remove --unattended",
                    token: .removal)),
                PlanStep("Remove the launchd agent", .hostCommand(hostID: host.id,
                    command: "rm -f -- \"$HOME/Library/LaunchAgents/\"\(quote(label + ".plist"))", token: nil)),
            ],
            preconditions: [.runnerRegistered(name: runner), .runnerIdle(name: runner)],
            requiresSecondConfirmation: true)
    }

    // MARK: GitHub

    static func deleteRegistration(_ runner: GitHubRunner, inventory: Inventory) -> Plan {
        Plan(
            id: "unregister.\(runner.name)", title: "Delete the stale registration \(runner.name)", subject: .runner(runner.name),
            effect: "Removes runner \(runner.id) from \(inventory.github.owner)/\(inventory.github.repository) on GitHub. No host is touched; no local credentials exist in the inventory for it.",
            steps: [PlanStep("Delete runner \(runner.id)", .deleteRunnerRegistration(id: runner.id, name: runner.name))],
            preconditions: [.runnerOffline(name: runner.name), .runnerIdle(name: runner.name)])
    }

    static func cancelRuns(_ runs: [WorkflowRun], platform: Bool) -> Plan {
        let ids = runs.map(\.id).sorted()
        return Plan(
            id: "cancel.\(platform ? "platform" : "superseded").\(ids.map(String.init).joined(separator: "-"))",
            title: platform ? "Cancel \(runs.count) platform runs" : "Cancel \(runs.count) superseded or closed-PR runs",
            subject: .fleet,
            effect: "Cancels: " + runs.map { "\($0.headBranch ?? "?") (\($0.displayTitle.prefix(50)))" }.joined(separator: "; "),
            steps: ids.map { PlanStep("Cancel run \($0)", .cancelRun(id: $0)) },
            preconditions: ids.map { .runActive(id: $0) },
            requiresSecondConfirmation: platform)
    }

    // MARK: little-ci fleets (OrbStack VM, Linux server)

    /// Bring-up and teardown through little-ci's own scripts, which carry its identity, busy and teardown checks.
    /// Loads a little-ci checkout's config.env the way its scripts do (lib/github-target.sh) and exits 1, before
    /// anything changes, when the effective scope, target, prefix, user, runner group or machine differs from the
    /// reviewed plan. Arguments: checkout, scope, target, prefix, user, runner group (empty in repository scope), machine.
    static let configurationCheck = #"""
        set -euo pipefail
        cd "$1"
        . ./lib/github-target.sh
        if [ -f ./config.env ]; then . ./config.env; fi
        github_target_init >/dev/null
        github_fleet_init >/dev/null
        RUNNER_USER="${RUNNER_USER:-deploy}"
        ORB_MACHINE="${ORB_MACHINE:-$RUNNER_NAME_PREFIX}"
        mismatch=0
        check() { if [ "$2" != "$3" ]; then echo "config.env gives $1 '$2'; the reviewed plan expects '$3'" >&2; mismatch=1; fi; }
        check GITHUB_SCOPE "$GITHUB_SCOPE" "$2"
        check GITHUB_TARGET "$GITHUB_TARGET" "$3"
        check RUNNER_NAME_PREFIX "$RUNNER_NAME_PREFIX" "$4"
        check RUNNER_USER "$RUNNER_USER" "$5"
        check RUNNER_GROUP "${RUNNER_GROUP:-}" "$6"
        if [ -n "${7:-}" ]; then check ORB_MACHINE "$ORB_MACHINE" "$7"; fi
        exit "$mismatch"
        """#

    static func configurationArguments(_ checkout: String, _ inventory: Inventory, prefix: String, user: String, machine: String?) -> [String] {
        let github = inventory.github
        let target = github.scope == .repository ? "\(github.owner)/\(github.repository)" : github.owner
        return [checkout, github.scope.rawValue, target, prefix, user, github.runnerGroup ?? ""] + (machine.map { [$0] } ?? [])
    }

    /// `machineExists`: false offers only bring-up. Callers offer nothing while a VM fails its identity checks.
    static func lifecyclePlans(_ host: HostSpec, inventory: Inventory, machineExists: Bool = true) -> [Plan] {
        let plans = allLifecyclePlans(host, inventory: inventory)
        return machineExists ? plans : plans.filter { $0.id.hasPrefix("vm.up.") || $0.id.hasPrefix("server.up.") }
    }

    static func allLifecyclePlans(_ host: HostSpec, inventory: Inventory) -> [Plan] {
        switch host.kind {
        case .macLaunchd:
            return []
        case .orbstackVM(let vm):
            let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            func script(_ name: String, _ arguments: [String] = []) -> PlanAction {
                .localCommand(CommandInvocation("/usr/bin/env", ["PATH=\(path)", "./\(name)"] + arguments, workingDirectory: vm.littleCICheckout))
            }
            let check = PlanStep("Check that \(vm.littleCICheckout)/config.env describes this machine and fleet",
                                 .localCommand(CommandInvocation("/bin/bash", ["-c", configurationCheck, "bash"]
                                     + configurationArguments(vm.littleCICheckout, inventory, prefix: vm.fleetPrefix, user: vm.runnerUser, machine: vm.machine))))
            return withCheck(check, [
                Plan(id: "vm.up.\(host.id)", title: "Bring up \(host.name)", subject: .host(host.id),
                     effect: "Provisions OrbStack machine \(vm.machine) if needed, registers fleet \(vm.fleetPrefix), and checks it on GitHub. Uses \(vm.littleCICheckout)/config.env.",
                     steps: [PlanStep("Provision the machine", script("provision-orbstack.sh")),
                             PlanStep("Install and register the runners", script("install-runners-orb.sh")),
                             PlanStep("Check the fleet on GitHub", script("check-runners.sh"))],
                     preconditions: [.hostMayTakeJobs(hostID: host.id), .hostMayTakeJobs(hostID: vm.parentHost)]),
                Plan(id: "vm.down.\(host.id)", title: "Tear down \(host.name)'s runners", subject: .host(host.id),
                     effect: "Unregisters every runner of fleet \(vm.fleetPrefix) and removes their services, scratch and directories. The machine stays.",
                     steps: [PlanStep("Uninstall the fleet", script("uninstall-runners-orb.sh", ["--all", "--confirm"])),
                             PlanStep("Confirm no registration is left", script("check-runners.sh"))],
                     preconditions: [.fleetIdle(prefix: vm.fleetPrefix)]),
                Plan(id: "vm.delete.\(host.id)", title: "Delete machine \(vm.machine)", subject: .host(host.id),
                     effect: "Uninstalls the fleet if any runner is left, then permanently deletes OrbStack machine \(vm.machine) and everything in it.",
                     steps: [PlanStep("Uninstall the fleet and delete the machine",
                                      script("uninstall-runners-orb.sh", ["--all", "--confirm", "--delete-machine"]))],
                     preconditions: [.fleetIdle(prefix: vm.fleetPrefix)], requiresSecondConfirmation: true),
            ])
        case .linuxServer(let server):
            let checkout = quote(server.littleCICheckout)
            let user = quote(server.runnerUser)
            let check = PlanStep("Check that the server's config.env describes this fleet", .hostCommand(hostID: host.id,
                command: "bash -c \(quote(configurationCheck)) bash "
                    + configurationArguments(server.littleCICheckout, inventory, prefix: server.fleetPrefix, user: server.runnerUser, machine: nil)
                        .map(quote).joined(separator: " "), token: nil))
            return withCheck(check, [
                Plan(id: "server.up.\(host.id)", title: "Bring up \(host.name)", subject: .host(host.id),
                     effect: "Provisions \(host.name) and registers fleet \(server.fleetPrefix) as \(server.runnerUser). Uses \(server.littleCICheckout)/config.env on the server.",
                     steps: [PlanStep("Provision the box", .hostCommand(hostID: host.id, command: "cd \(checkout) && sudo -n ./provision-box.sh", token: nil)),
                             PlanStep("Install job dependencies", .hostCommand(hostID: host.id, command: "cd \(checkout) && sudo -n ./provision-job-dependencies.sh", token: nil)),
                             PlanStep("Register and install the runners with a token from stdin", .hostCommand(hostID: host.id, command:
                                "IFS= read -r REGTOKEN && export REGTOKEN && cd \(checkout) && sudo -n -u \(user) -H --preserve-env=REGTOKEN ./install-runners.sh",
                                token: .registration))],
                     preconditions: [.hostMayTakeJobs(hostID: host.id)]),
                Plan(id: "server.down.\(host.id)", title: "Tear down \(host.name)'s runners", subject: .host(host.id),
                     effect: "Unregisters every runner of fleet \(server.fleetPrefix) and removes their services, scratch, swapfiles it owns and directories.",
                     steps: [PlanStep("Uninstall the fleet with a removal token from stdin", .hostCommand(hostID: host.id, command:
                                "IFS= read -r REMOVETOKEN && export REMOVETOKEN && cd \(checkout) && sudo -n -u \(user) -H --preserve-env=REMOVETOKEN ./uninstall-runners.sh --all --confirm",
                                token: .removal))],
                     preconditions: [.fleetIdle(prefix: server.fleetPrefix)]),
            ])
        }
    }

    private static func withCheck(_ check: PlanStep, _ plans: [Plan]) -> [Plan] {
        plans.map { plan in
            var plan = plan
            plan.steps.insert(check, at: 0)
            return plan
        }
    }
}
