# Contributing to Little-CI

Thanks for helping improve Little-CI. Keep changes focused, and include a
reproduction and the commands you ran.

## Before changing code

Open an issue first for a new platform, a new setting, or a change to the
security model. Small fixes with a clear scope can go straight to a pull request.
Check open issues and pull requests for the same fix before you start.

Read [AGENTS.md](AGENTS.md) before changing architecture. It holds the live-runner
safety rules, the configuration contract, and which script owns what. These are
not planned:

- Intel Mac support.
- Mac mounts, SSH-agent forwarding, host access, or inbound services in the
  OrbStack guest.
- Running public-fork or other untrusted workflows on a persistent runner.
- A force path that interrupts a busy runner or touches runners outside the
  configured fleet.
- Dependencies beyond Bash and the Python standard library without a clear
  requirement.

## Development setup

You need Bash 4 or newer (`brew install bash` on macOS) and, ideally, ShellCheck.
The tests mock commands at the process boundary, so they need no OrbStack machine,
GitHub token, or runner registration.

```bash
git clone https://github.com/ParkerRex/little-ci.git
cd little-ci
bash -n ./*.sh lib/*.sh tests/*.sh
./tests/run.sh
shellcheck ./*.sh lib/*.sh tests/*.sh
```

`./tests/run.sh` must end with 0 failures. Do not add new ShellCheck findings.
Run the tests as a regular user, not root: several scripts refuse to run as root
by design. Run `swift test --package-path app` when you change `app/`.

The **Check** status runs these on every pull request and push to `main`, on
GitHub-hosted runners: syntax, ShellCheck at warning severity, and the test suite
on Ubuntu 24.04, and the app tests on macOS 15. Check must pass before a merge.

## Verification expectations

- Bug fixes: reproduce the bug on a named `main` commit first. Show it failing,
  then passing with the fix.
- Settings: update `config.env.example` and the README in the same change. Test
  the default, valid variants, and invalid values.
- Install, uninstall, and cleanup: cover the partial-failure and retry path, not
  only the happy path.
- Guest packages: run `provision-job-dependencies.sh` on a real Ubuntu 24.04
  guest when you can, and say so when you could not.
- Live runs are welcome as extra evidence. Point them only at a machine and
  GitHub target you own.

Add a test only when it catches a failure the existing tests miss. Do not weaken
a check, skip a scenario, or delete a test to get green.

## Pull requests

- One change per pull request. Keep dependency bumps, formatting, and refactors
  out of fixes.
- Use a conventional, lowercase title, for example
  `fix(ci): enable package sources before runner provisioning`.
- Rebase onto current `main` before opening.
- In the body, say what was broken and what it does now, the reproduction, the
  root cause with file and line, the exact commands you ran with their pass
  counts, and what you did not verify.

Never include registration or removal tokens, PATs, `config.env`, `.runner`,
`.credentials*`, `_work`, `_diag`, or runner archives. A registered runner
directory is a live credential.

AI-assisted work is welcome. You are responsible for every line, so read the full
diff before you open the pull request.
