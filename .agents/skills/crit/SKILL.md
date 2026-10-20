---
name: crit
description: Screenshot-backed design and usability review of little-ci's native macOS menu bar app (app/, SwiftUI). Captures the menu bar panel and every details-window pane in light and dark from the demo fleet, runs a UX heuristic audit and an Apple HIG audit with measurements as separate assessments, and records findings with stable IDs and screenshot markers in a JSON review record. Assessment only, unless the user explicitly authorizes implementation; then at most three small, high-confidence fixes per round, proven by tests and before/after recapture.
---

# Crit

Use this skill when the user asks for a crit, design review, or usability review of the Little CI menu bar app. A request to crit, audit, or review authorizes assessment only.

Owned elsewhere, do not restate:

- [ux-heuristics](../ux-heuristics/SKILL.md) owns the UX audit, the 0 to 4 severity scale, and the Quick Diagnostic.
- [apple-hig-expert](../apple-hig-expert/SKILL.md) owns HIG requirements, the rubric, and `scripts/hig_measure.py`. Its `--help` owns the measurement input format.
- The [little-ci macOS profile](../apple-hig-expert/references/little-ci-macos-profile.md) is the project's design contract. The owner set it and it overrides defaults: dense information; no decorative card or pill chrome; no light-gray subtitle lines above sections; no em dashes in UI text; no continuously repainting animation (ticking relative timestamps, spinners, pulse, shimmer); the menu bar glyph shows the worst finding with a static symbol; Apple HIG for menu bar extras.
- [references/review-record.md](references/review-record.md) owns the record format, verdict rules, and append-only rules.

## Files

| Path | Git | Purpose |
| ---- | --- | ------- |
| `.crit/<review-id>/` | ignored | Screenshots, `capture.json`, measurements, audits, draft record, `report.html` |
| `docs/design-reviews/<review-id>/review.json` | tracked | The saved review record. Text only: no images, no live host or repository names |

Pick a review ID such as `2026-10-21-menu-bar` (lowercase letters, digits, hyphens). Check `git check-ignore .crit/x` before writing evidence; it must be ignored.

## Procedure

1. **Read context.** `AGENTS.md`, `app/README.md`, the design contract above, both audit templates ([UX](../ux-heuristics/references/audit-template.md), [HIG](../apple-hig-expert/templates/hig-audit-template.md)), and the views in `app/Sources/LittleCIApp/` for the surfaces under review.

2. **Capture before.** One command captures the panel and all five panes (overview, hosts, runners, queue, events) in light and dark:

   ```bash
   python3 .agents/skills/crit/scripts/capture.py capture <review-id> before
   ```

   It builds `app/build/Little CI.app` with `app/scripts/build-app.sh` if it is missing, launches it once per pane and appearance with `--demo --appearance <mode> --show-details --pane <pane>` (plus `--show-panel` on the first launch), captures each window with `screencapture -x -o -l <window-id>`, and quits that instance. The demo runs in a temporary `LITTLE_CI_HOME` with no hosts and its own API port, so it contacts no host, reads only the example GitHub target, touches no real event history, and does not disturb a running copy of the app. It writes `<surface>-<appearance>.png` and `capture.json` (surface, appearance, window title, pixel and point size, scale, SHA-256, executable SHA-256) to `.crit/<review-id>/before/`. Any missing window or failed capture exits 1 and writes no manifest: an incomplete capture is not evidence. The terminal needs Screen Recording permission. Use `--live` only when the user asks; live captures may show private names and must not reach the tracked record. The plan review window, notifications, and the menu bar glyph itself are not captured; mark what depends on them untested, or capture by hand and say so.

   Look at every image before auditing.

3. **UX audit.** Fill the UX template in `.crit/<review-id>/ux-audit.md`: heuristic checks, the Quick Diagnostic with failed rows, a Trunk Test row per surface, findings, non-findings. Rate severity 0 to 4 with a one-line reason.

4. **HIG audit with measurements.** Fill the HIG template in `.crit/<review-id>/hig-audit.md` with one outcome per rubric requirement: `pass`, `fail`, `untested`, or `na`, each with its evidence or reason. Measure contrast and target size from the captures:

   ```bash
   python3 .agents/skills/crit/scripts/png_colors.py region .crit/<review-id>/before/panel-dark.png <x,y,width,height>
   ```

   This lists the most common colors in a pixel rectangle (the background, then the text cluster). Convert pixel sizes to points with the `scale` in `capture.json`. Write the measurements to `.crit/<review-id>/before/hig-measurements.json` in the format `hig_measure.py --help` gives, with each `evidence` naming the capture file and region, then:

   ```bash
   python3 .agents/skills/apple-hig-expert/scripts/hig_measure.py batch .crit/<review-id>/before/hig-measurements.json > .crit/<review-id>/before/hig-report.json
   ```

   Exit status 1 means a failed or unknown result, not a tool error. Unknown is never a pass. Keep the two audits separate: severity comes from the UX audit; a HIG-only finding gets your rating. Never compute a HIG score.

5. **Register findings with stable IDs.** As soon as the first evidence-backed findings exist, write the draft record `.crit/<review-id>/review.json` with `"draft": true`, then keep it current and render it:

   ```bash
   python3 .agents/skills/crit/scripts/review_record.py validate .crit/<review-id>/review.json
   python3 .agents/skills/crit/scripts/review_record.py render .crit/<review-id>/review.json
   ```

   Each finding has an ID such as `OVR-01`, the screenshot, a marker in percent of the image, the source (`ux`, `hig`, or `both`), heuristics or HIG requirement, severity, confidence, claim, and expected fix. Merge the same defect into one finding. A dropped draft ID goes into `withdrawnFindingIds`; never renumber. When the assessment is complete, copy the record to `docs/design-reviews/<review-id>/review.json` without `draft`, with the UX score, HIG outcomes, measurement report hash, verdict, code state (`review_record.py code-state`), and actors, and check it:

   ```bash
   python3 .agents/skills/crit/scripts/review_record.py validate docs/design-reviews/<review-id>/review.json --previous .crit/<review-id>/review.json --rubric .agents/skills/apple-hig-expert/config/hig-rubric.json
   ```

   Without implementation authority, stop here and report: the verdict line, the worst findings with IDs, and the paths of the record and `report.html`.

6. **Fix round (only with explicit implementation authority).** The user must ask for fixes, or have granted continuing implementation authority for this same crit. Then:
   - Select up to three small, high-confidence fixes. Append a `fixSelections` entry with the exact IDs and, in `evidence`, who authorized it and why these (and why fewer, if fewer). Never infer the selection from what changed.
   - Implement. Use the [executor brief](references/executor-brief.md) when delegating, with disjoint file ownership per executor and the user's chosen models, efforts, and round limits. One executor is the default; delegate only when the fixes are independent and it saves time.
   - Run `swift test --package-path app` and `app/scripts/build-app.sh`. Both must pass.
   - Recapture the affected surfaces into a new phase, from the new build:

     ```bash
     python3 .agents/skills/crit/scripts/capture.py capture <review-id> after --surfaces overview,panel
     ```

     Use `after-2`, `after-3` for later rounds. Measure again where a fix touched a measured property, and compare like with like (same element, appearance, and rule).
   - Optionally start a read-only reviewer with the [reviewer brief](references/reviewer-brief.md).

7. **Record the round.** Append a round to the tracked record: code state, actors (provider, exact model, reasoning effort, client; `null` when unknown), the after captures, and one change per fix with status, test evidence, and before/after pairs. `verified` needs a pair and test evidence; `implemented` needs test or behavior evidence. Before replacing the saved file, copy it to `.crit/<review-id>/review.saved.json` and validate the new version with `--previous .crit/<review-id>/review.saved.json`. After the work is committed, append a `commitLinks` entry with the real SHAs; never edit the round. Keep implementation, verification, commits, and release as separate facts. Do not run another round only to raise a score.

8. **Close the round.** When the tracked record holds the round and no selected fix is still open (no uncommitted change or open PR for it), delete the screenshots:

   ```bash
   find .crit/<review-id> -type f -name '*.png' -delete
   ```

   Keep the text files. The tracked `review.json` is the lasting record; its SHA-256 bindings stay valid after the images are gone, and `report.html` then shows missing images.

## Verdict line

Report one line, in this order: `UX 7/10 · HIG 30 pass, 3 fail, 6 untested, 10 N/A · Measurements 4 of 22 failed, 2 unknown · Changes required · Worst open severity 3`. After a round, give both worst values (`Worst open severity 3 to 2`). The verdict follows the worst open finding (see the record format). It is review evidence, not a release gate or a HIG compliance claim.

## Tooling checks

```bash
python3 -m unittest discover -s .agents/skills/crit/scripts
```

The tests cover manifest validation, finding-ID stability, evidence links, verdict derivation, and append-only rules. None needs a screen, the app, GitHub, or a host.
