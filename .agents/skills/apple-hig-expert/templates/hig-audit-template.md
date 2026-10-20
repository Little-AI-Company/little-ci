# HIG audit: [surface or feature]

**App:** little-ci menu bar app (`app/`)
**Surfaces:** [menu bar extra / Details window / Plan review window / other]
**macOS version and hardware:** [for example macOS 27.0, MacBook Pro 120 Hz]
**Appearances and settings tested:** [light, dark, Increase Contrast, Reduce Transparency, Reduce Motion]
**Inputs tested:** [pointer, keyboard, Full Keyboard Access, VoiceOver, Voice Control]
**Evidence:** [running app, screenshots, source at commit SHA]
**Rubric:** `config/hig-rubric.json`, lastVerified [date]
**Auditor:** [name]
**Date:** YYYY-MM-DD

This report records evidence. It does not certify HIG compliance.

## Outcomes

Give every rubric requirement exactly one outcome. Keep `na` rows visible with a reason.

- `pass`: the evidence shows the requirement is met.
- `fail`: the evidence shows a defect. Give severity 1 to 4 and a finding ID.
- `untested`: not enough evidence. Name the test or capture that is needed.
- `na`: the requirement does not apply to this surface or input. Say why.

Label each outcome's evidence `measured`, `observed`, `needs device test`, or `assumption`.

## Summary

| Outcome  | Count |
| -------- | ----: |
| Pass     |   [0] |
| Fail     |   [0] |
| Untested |   [0] |
| N/A      |   [0] |

**Worst open severity:** [0 / 1 / 2 / 3 / 4]
**Verdict:** [ready / improvements identified / changes required / blocked / review incomplete]

The verdict follows the worst open finding. With no open severity 3 or 4 finding, any applicable `untested` requirement makes the verdict `review incomplete`. Do not compute a total score.

## Measurements

```bash
python3 .agents/skills/apple-hig-expert/scripts/hig_measure.py batch review/measurements.json > review/hig-measurements.json
```

| Kind     | Passed | Failed | Unknown | Total |
| -------- | -----: | -----: | ------: | ----: |
| Contrast |    [0] |    [0] |     [0] |   [0] |
| Target   |    [0] |    [0] |     [0] |   [0] |

Unknown results stay unknown; give each one's reason and the capture that would resolve it. Counts describe the sampled elements, not the app.

## Project contract conflicts

List each place where a HIG default conflicts with `references/little-ci-macos-profile.md`, the contract rule that was kept, and why. These are not findings.

## Requirement results

| Requirement ID | Outcome | Evidence label | Severity | Evidence or reason | Finding |
| -------------- | ------- | -------------- | -------: | ------------------ | ------- |
| [accessibility.contrast.text] | [pass/fail/untested/na] | [measured/observed/needs device test/assumption] | [1-4 or blank] | [result ID, screenshot, file:line, or N/A reason] | [ID or blank] |

## Findings

Order by severity, then by surface.

1. **[ID] [Severity] [Claim].** Evidence: [measurement ID, screenshot, file:line, or test]. Requirement: [rubric ID]. Fix: [smallest effective change].

## Limits

[States, settings, or inputs not captured, and the device or assistive-technology tests still needed.]
