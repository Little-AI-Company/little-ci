# Claude Code entry point

[AGENTS.md](AGENTS.md) holds the rules for this repository. Read it first.
This file adds no rules of its own.

## The two rules people forget

- Never add a new code comment.
- Never write a new unit or integration test unless explicitly asked. New
  coverage is an end-to-end check. Never write snapshot, exhaustive
  permutation, mock choreography, declaration check or wrapper tests unless
  that kind is asked for by name.

Both are in [AGENTS.md: Rules for every agent](AGENTS.md#rules-for-every-agent)
with what they allow.

## Shipping

Commit on `main` and land it with `scripts/push_main.sh`; there are no pull
requests, branches or CI gates. Follow
[AGENTS.md: Shipping on main](AGENTS.md#shipping-on-main).
