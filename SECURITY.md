# Security policy

Little-CI handles runner registration tokens and runs workflow code on your
hardware, so security reports matter here.

## Report a vulnerability

Report it privately through
[GitHub security advisories](https://github.com/Little-AI-Company/little-ci/security/advisories/new).
Do not open a public issue. Include the affected script, the configuration
needed to reproduce it, and what an attacker gains.

## In scope

- A token, PAT, or runner credential written to disk, a log, or an archive.
- A Mac path, mount, network route, or SSH agent reachable from the guest.
- Teardown that removes runners, services, or files outside the configured fleet.
- Isolation or identity checks that accept a machine they should reject.

## Out of scope

These are documented limits, not vulnerabilities. See the
[security model](README.md#security-model).

- Trusted workflow code taking over the Linux guest. Docker access is
  root-equivalent there.
- Escaping the shared OrbStack Linux kernel. Isolated machines reduce risk; they
  are not a separate-kernel boundary.
- Running public-fork or other untrusted workflows on a persistent runner.
