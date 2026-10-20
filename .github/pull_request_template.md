<!--
Read CONTRIBUTING.md first. One change per pull request.
Use a conventional, lowercase title, for example "fix(ci): enable package sources before runner provisioning".
-->

## Problem

<!-- What was broken or missing, and how to reproduce it on a named main commit. -->

## Change

<!-- What it does now, and the root cause with file and line. -->

## Test plan

- [ ] `bash -n ./*.sh lib/*.sh tests/*.sh`
- [ ] `./tests/run.sh`: <!-- pass count -->
- [ ] `shellcheck ./*.sh lib/*.sh tests/*.sh`: no new findings

<!-- List any live run (host, OrbStack version, what you checked) and anything you could not verify. -->
