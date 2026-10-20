import Foundation

/// Versioned, read-only probe scripts, one per host kind. Each runs in one shell (local or one SSH
/// session), prints one JSON object, and installs nothing. Every section is a command's exit code and
/// its output in base64, so arbitrary text crosses the boundary intact; `ProbeParser` interprets it.
/// Inputs travel as shell assignments at the top of the script on stdin, never as command-line arguments.
public enum ProbeScript {
    public static let version = 1

    /// The script for a host, with its inputs assigned. Names are validated by `Inventory.validate()`.
    public static func script(for host: HostSpec, includePowerLog: Bool) -> String {
        let runnerNames = host.runners.map(\.name).joined(separator: " ")
        switch host.kind {
        case .macLaunchd(let mac):
            return assignments([
                "RUNNER_ROOT": mac.runnerRoot, "SERVICE_PREFIX": mac.serviceLabelPrefix,
                "RUNNERS": runnerNames, "INCLUDE_POWER_LOG": includePowerLog ? "1" : "0",
            ]) + common + macLaunchd
        case .linuxServer(let server):
            return assignments(["RUNNER_USER": server.runnerUser, "FLEET_PREFIX": server.fleetPrefix, "RUNNERS": runnerNames])
                + common + linuxSystemd
        case .orbstackVM(let vm):
            let guest = assignments(["RUNNER_USER": vm.runnerUser, "FLEET_PREFIX": vm.fleetPrefix, "RUNNERS": runnerNames])
                + common + linuxSystemd
            return assignments(["ORB_MACHINE": vm.machine, "GUEST_USER": vm.runnerUser, "GUEST_PROBE": guest])
                + common + orbstackHost
        }
    }

    static func assignments(_ values: [String: String]) -> String {
        values.sorted { $0.key < $1.key }.map { key, value in
            "\(key)='\(value.replacingOccurrences(of: "'", with: "'\\''"))'\n"
        }.joined()
    }

    /// `section NAME COMMAND...` records one command; `finish` closes the JSON object.
    static let common = #"""
    set -u
    export LC_ALL=C
    probe_separator=''
    printf '{"probeVersion":1,"sections":{'
    section() {
      local name="$1" output status
      shift
      output="$("$@" 2>&1)"
      status=$?
      printf '%s"%s":{"exit":%d,"output":"%s"}' "$probe_separator" "$name" "$status" \
        "$(printf '%s' "$output" | base64 | tr -d '\n')"
      probe_separator=','
    }
    finish() { printf '}}\n'; }

    """#

    static let macLaunchd = #"""
    uid="$(id -u)"
    first_path=''
    for runner in $RUNNERS; do
      if [ -z "$first_path" ] && [ -f "$RUNNER_ROOT/$runner/.path" ]; then first_path="$(cat "$RUNNER_ROOT/$runner/.path")"; fi
    done
    job_path="${first_path:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
    section identity sh -c 'scutil --get LocalHostName; id -u; sw_vers -productVersion'
    section sysctl sh -c 'sysctl -n hw.ncpu hw.memsize vm.loadavg; sysctl vm.swapusage'
    section memory_pressure sh -c 'memory_pressure | tail -n 1'
    section power sh -c 'pmset -g batt | head -n 1'
    if [ "$INCLUDE_POWER_LOG" = 1 ]; then
      section power_log sh -c "pmset -g log | grep -E '^[0-9-]+ [0-9:]+ [-+][0-9]{4} (Sleep|Wake|DarkWake)  ' | tail -n 60"
    fi
    section df df -k -P
    section mount mount
    section docker_socket sh -c 'ls -lL /var/run/docker.sock; readlink /var/run/docker.sock'
    section docker_info env PATH="$job_path" docker info --format '{{.ServerVersion}}'
    section docker_compose env PATH="$job_path" docker compose version --short
    section orbstack_version env PATH="$job_path" orbctl version
    section orbstack_status env PATH="$job_path" orbctl status
    section orbstack_vmgr sh -c 'grep -E "phase=verify_rosetta|could not be mounted|Init failed|Failed to mount" "$HOME/.orbstack/log/vmgr.log" | tail -n 40'
    for runner in $RUNNERS; do
      dir="$RUNNER_ROOT/$runner"
      label="$SERVICE_PREFIX$runner"
      section "runner.$runner.directory" test -d "$dir"
      section "runner.$runner.registration" sh -c 'grep -aoE "\"(gitHubUrl|agentName)\": *\"[^\"]*\"" "$1/.runner" "$1/.runner_migrated" 2>/dev/null | head -n 2' sh "$dir"
      section "runner.$runner.definition" test -f "$HOME/Library/LaunchAgents/$label.plist"
      section "runner.$runner.service" sh -c 'launchctl print "gui/$1/$2" | grep -E "^[[:space:]](state|pid|last exit code) = "' sh "$uid" "$label"
      runner_path="$job_path"
      [ -f "$dir/.path" ] && runner_path="$(cat "$dir/.path")"
      section "runner.$runner.bun" env PATH="$runner_path" bun --version
      section "runner.$runner.node" env PATH="$runner_path" node --version
    done
    finish

    """#

    /// Runs as an ordinary user. In OrbStack it runs inside the guest; on a server, over SSH.
    static let linuxSystemd = #"""
    section identity sh -c 'hostname; id -u; . /etc/os-release && echo "$VERSION_ID"'
    section loadavg sh -c 'nproc; cat /proc/loadavg'
    section meminfo grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo
    section df df -k -P
    section mount cat /proc/mounts
    section docker_socket sh -c 'ls -lL /var/run/docker.sock'
    section docker_info docker info --format '{{.ServerVersion}}'
    section docker_compose docker compose version --short
    runner_home="$(getent passwd "${RUNNER_USER:-$(id -un)}" | cut -d: -f6)"
    for runner in $RUNNERS; do
      number="${runner##*-}"
      dir="$runner_home/actions-runner-$number"
      section "runner.$runner.directory" test -d "$dir"
      section "runner.$runner.registration" sh -c 'grep -aoE "\"(gitHubUrl|agentName)\": *\"[^\"]*\"" "$1/.runner" 2>/dev/null | head -n 2' sh "$dir"
      section "runner.$runner.definition" sh -c 'test -f "$1/.service" && cat "$1/.service"' sh "$dir"
      unit="$(cat "$dir/.service" 2>/dev/null)"
      section "runner.$runner.service" systemctl show "${unit:-actions.runner.missing.service}" -p LoadState -p ActiveState -p SubState -p MainPID -p ExecMainStatus
    done
    finish

    """#

    /// Runs on the Mac: the VM's OrbStack settings, then the Linux probe inside the guest.
    static let orbstackHost = #"""
    PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    export ORB_MACHINE GUEST_USER GUEST_PROBE
    section vm_info orbctl info "$ORB_MACHINE" --format json
    section vm_mounts orbctl config get "machine.$ORB_MACHINE.mounts"
    section vm_identity orbctl run -m "$ORB_MACHINE" -u root cat /etc/little-ci/identity
    section guest sh -c 'printf "%s" "$GUEST_PROBE" | orbctl run -m "$ORB_MACHINE" -u "$GUEST_USER" bash -s'
    finish

    """#
}
