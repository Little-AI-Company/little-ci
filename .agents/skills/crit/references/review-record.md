# Review record (format version 1)

One JSON file holds one crit review: the original assessment, the fix selections, the fix rounds, and links to the commits that landed them. `scripts/review_record.py validate` is the authority; this page explains the rules. The test fixture in `scripts/test_review_record.py` is a complete valid example.

## Where records live

| File | Git | Content |
| ---- | --- | ------- |
| `.crit/<review-id>/<phase>/*.png`, `capture.json` | ignored | Screenshots and their manifest |
| `.crit/<review-id>/<phase>/hig-measurements.json`, `hig-report.json` | ignored | HIG measurement input and `hig_measure.py batch` output |
| `.crit/<review-id>/ux-audit.md`, `hig-audit.md` | ignored | Filled audit templates |
| `.crit/<review-id>/review.json` | ignored | The draft record (`"draft": true`) while the assessment is in progress |
| `.crit/<review-id>/report.html` | ignored | Rendered report with screenshot markers |
| `docs/design-reviews/<review-id>/review.json` | tracked | The saved record. Text only |

The tracked record holds no images, no base64, and no host or repository names from a live fleet. It binds screenshots by file name and SHA-256 only, so it stays valid after the screenshots are deleted. Phases are `before`, `after`, and `after-<n>` for later rounds.

## Shape

```text
version: 1
draft: true                      only in .crit/; never in docs/design-reviews/
reviewId, title
original:
  recordedAt, code, actors
  captures: { phase: "before", data: demo|live, manifestSha256, files: [{file, surface, appearance, sha256}] }
  findings: [finding]
  withdrawnFindingIds: []        IDs dropped while the record was a draft; never reused
  nonFindings: [{surface, claim}]
  ux: { score, failedRows: [{row, findingIds}] }
  hig: { requirements: [{id, outcome, findingIds | evidence | testNeeded | reason}], measurements: null | {input, report, reportSha256} }
  verdict
fixSelections: [{id, recordedAt, findingIds (1 to 3), evidence}]
rounds: [{id, recordedAt, code, actors, captures, changes: [change]}]
commitLinks: [{id, recordedAt, roundId, changeIds, code: committed}]
```

`files` copies `file`, `surface`, `appearance`, and `sha256` from `capture.json`; `manifestSha256` is the SHA-256 of that `capture.json`.

## Findings

| Field | Rule |
| ----- | ---- |
| `id` | `<SURFACE>-NN`: `PNL` panel, `OVR` overview, `HST` hosts, `RUN` runners, `QUE` queue, `EVT` events, `APP` across the app. Unique. Never renumbered or reused |
| `surface`, `appearance`, `screenshot` | The screenshot must be a before capture of that surface and appearance |
| `marker` | `{x, y}` in percent of the image, 0 to 100, at the defect |
| `source` | `ux`, `hig`, or `both`. `ux` and `both` need `heuristics` (for example `nielsen.1`, `krug.trunk-test`, `diagnostic.5`); `hig` and `both` need `higRequirement` |
| `severity` | 0 to 4 from the UX audit. A HIG-only finding gets the orchestrator's rating |
| `confidence` | `measured`, `observed`, `needs device test`, or `assumption`. `measured` needs `measurement`, the exact result line from `hig_measure.py` |
| `doctrine` | Optional quote from the design contract |
| `claim`, `expectedFix` | One sentence each: the defect, and the smallest effective fix |

The same defect on several surfaces is one finding. Name the main surface, and list the others in the claim. When both audits describe it, keep the finer claim and set `source: both`.

## Assessments stay separate

- **UX:** `score` is the Quick Diagnostic owned by `ux-heuristics`: 10 minus 2 per failed row whose worst finding is severity 3 or 4, minus 1 for other failed rows, never below 0. The validator recomputes it.
- **HIG:** one outcome per requirement in the HIG rubric (`validate --rubric .agents/skills/apple-hig-expert/config/hig-rubric.json` checks coverage) (`pass`, `fail`, `untested`, `na`). `fail` cites findings whose `higRequirement` is that ID; `pass` cites `evidence`; `untested` says `testNeeded`; `na` gives a `reason`. Every HIG finding needs its requirement marked `fail`. There is no HIG score; a `score`, `compliance`, or `passRate` field is rejected.
- **Measurements:** the measurement input format belongs to `python3 .agents/skills/apple-hig-expert/scripts/hig_measure.py --help`. This record only points at the input and report under `.crit/` and binds the report by SHA-256.

## Verdict

Derived from open findings and untested requirements. Nothing is averaged.

| Condition | Verdict |
| --------- | ------- |
| Any open severity 4 | Blocked |
| Any open severity 3 | Changes required |
| No severity 3 or 4, but a requirement is untested | Review incomplete |
| Only severity 1 or 2 open | Improvements identified |
| Nothing open, nothing untested | Ready for decision |

`original.verdict` must equal the derived verdict with every finding open. A finding's current status is the status of the latest change that names it, else `open`. Only `verified` and `rejected` close a finding; `implemented` and `deferred` stay open. Never call the result HIG compliant, accepted, or ready to ship.

## Fix selections and rounds

- No selection and no round without explicit implementation authority from the user.
- A `fixSelections` entry names 1 to 3 findings and says, in `evidence`, who authorized the fixes and why these were chosen (and why fewer than three, if so).
- A change with status `implemented` or `verified` may only fix selected findings. One round fixes at most 3 findings.
- `implemented` needs `test` or `behavior` evidence. `verified` also needs a `test` item and a before/after pair: `{surface, appearance}`, present in the before captures and in this round's `captures`.
- Change statuses: `open`, `implemented`, `verified`, `deferred`, `rejected`. These are review states. Do not claim a release or deployment from a test or a commit.

## Actors and code state

`actors` always has `reviewer`, `executor`, and `verifier`. Each is `null` (unknown) or `{kind: human|agent, name, provider, model, reasoning?, harness?}`. An agent needs a provider. `model` is the exact model string or `null`; never infer it from the provider. Record attribution for the original, each round, and each change.

`code` is one of:

- `{"kind": "committed", "baseCommit": "<sha>", "commits": ["<sha>", ...]}`. An empty `commits` means exactly `baseCommit`.
- `{"kind": "uncommitted", "baseCommit": "<sha>", "changesSha256": "<digest>", "paths": [...]}`. Produce it with `python3 .agents/skills/crit/scripts/review_record.py code-state`; it hashes the diff and untracked files without copying source.
- `{"kind": "unavailable", "reason": "..."}` when the state cannot be proven.

Use only SHAs that Git produced. After committing an uncommitted round, append a `commitLinks` entry; do not edit the round.

## Append-only rules

Check every replacement of a saved record before writing it:

```bash
python3 .agents/skills/crit/scripts/review_record.py validate <new review.json> --previous <saved review.json>
```

- After a record is saved (no `draft`), `version`, `title`, and `original` never change, and earlier `fixSelections`, `rounds`, and `commitLinks` entries are never edited or removed. New entries go at the end.
- While a record is a draft, findings may change, but an ID never moves to another surface, and a dropped ID goes into `withdrawnFindingIds` so it is never reused.
