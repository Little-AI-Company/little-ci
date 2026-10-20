---
name: apple-hig-expert
description: Audit or design native macOS interfaces built with SwiftUI or AppKit, including menu bar extras, against Apple's current Human Interface Guidelines and this project's own design contract. Use for little-ci's menu bar app (app/), for macOS window, sidebar, toolbar, list, color, typography, SF Symbols, materials and Liquid Glass, motion, and accessibility questions, and to measure contrast and macOS target sizes with scripts/hig_measure.py.
license: MIT
metadata:
  version: 3.0.0
  author: Alireza Rezvani
  adapted-by: little-ci contributors (adapted from the original MIT-licensed skill and narrowed to native macOS)
  category: design
  updated: 2026-10-20
---

# Apple HIG Expert (native macOS)

Use Apple's Human Interface Guidelines (HIG) to make evidence-backed design decisions for a native macOS app. An audit records measured and observed findings. It does not prove HIG compliance or App Store readiness.

## Establish the context

1. Read [little-ci-macos-profile.md](references/little-ci-macos-profile.md) first. The owner set that contract. It overrides HIG defaults where they conflict, and the audit reports the conflict instead of recommending the HIG default.
2. Read `app/README.md` and the SwiftUI sources the question touches (`app/Sources/LittleCIApp/`).
3. Identify before applying any rule:
   - surface: menu bar extra (menu or window style), window, sidebar, toolbar, list or table, alert, menu
   - framework: SwiftUI, AppKit, or both
   - activation policy: menu-bar-only agent app (`LSUIElement`) or regular app with Dock icon and menu bar
   - inputs: pointer, keyboard (including Full Keyboard Access), VoiceOver, Voice Control
   - appearance and settings: light, dark, Increase Contrast, Reduce Transparency, Reduce Motion
   - evidence available: running app, screenshots, source, or specification only

Apply a rule only when its `applicability` predicates in the rubric match. Mark the rest `na` with a reason.

## Route to guidance

- [platform-specifics.md](references/platform-specifics.md): macOS structure, menu bar extras, windows, sidebars, toolbars, lists, controls, keyboard.
- [design-principles.md](references/design-principles.md): Apple's eight principles as audit questions.
- [visual-design.md](references/visual-design.md): Liquid Glass and materials, color, Dark Mode, typography, SF Symbols, layout, motion.
- [accessibility.md](references/accessibility.md): contrast, target size, VoiceOver, keyboard, display settings, evidence levels.
- [config/hig-rubric.json](config/hig-rubric.json): the rule catalog. Each rule has an ID, criterion, applicability, threshold when measurable, source, and `lastVerified`.

Other Apple platforms (iOS, iPadOS, watchOS, tvOS, visionOS) and web surfaces are out of scope. For those, read the live HIG directly and say that this skill's rubric does not cover them. If the app gains search, generative features, or a document model, read the matching live HIG page (Search fields, Generative AI, File management) and add rules to the rubric with a fresh `lastVerified`.

## Design or audit

For a new design, start with purpose, task flow, and the surface Apple recommends (a menu before a window-style extra, standard components before custom ones). Then choose layout, type, color, material, and motion inside the project contract.

For an audit:

1. State scope, context, evidence, and what you could not test.
2. List every rubric requirement with exactly one outcome: `pass`, `fail`, `untested`, or `na`.
3. Label each outcome's evidence: `measured` (tool output), `observed` (seen in the running app or a screenshot), `needs device test` (inferred from source or a static image), or `assumption` (stated, not checked).
4. Measure what the tool can measure. Inspect behavior, VoiceOver output, focus, and settings in the running app.
5. Report findings by impact with evidence, rule ID, and the smallest effective correction.

Use [hig-audit-template.md](templates/hig-audit-template.md). Report counts and findings. Never compute a synthetic total score. `untested` is not partial credit.

## Measurement tool

`scripts/hig_measure.py` is Python 3 standard library only. Run from the repository root:

```bash
python3 .agents/skills/apple-hig-expert/scripts/hig_measure.py contrast '#6E6E73' '#FFFFFF' --subject text --text-size 11 --text-unit pt --font-weight 400
```

```bash
python3 .agents/skills/apple-hig-expert/scripts/hig_measure.py target 24 22 --platform macos --input pointer
```

```bash
python3 .agents/skills/apple-hig-expert/scripts/hig_measure.py batch review/measurements.json
```

Every command accepts `--rubric <path>`; `--help` prints the batch schema. Contrast text options go together or not at all. Use `--subject non-text` only for a symbol, control boundary, or state indicator that people need.

Rules the tool applies:

- Text contrast follows the table on Apple's Accessibility page: 4.5:1 up to 17 pt, 3:1 at 18 pt or larger, 3:1 for bold (weight 700 or more) at any size. Text without metrics gets the stricter 4.5:1.
- Non-text contrast uses WCAG 2.2 SC 1.4.11 (3:1), because Apple gives no separate number. Cite it as WCAG.
- macOS pointer targets pass at the 20 by 20 pt minimum control size. `meetsDefaultSize` reports the 28 by 28 pt default as advice.
- Colors must be opaque `#RRGGBB` samples of the rendered pixels. Over a material or Liquid Glass, sample the least favorable composited background. A translucent, missing, or unsupported value gives `unknown`, which is never a pass.

### Batch input schema

```json
{
  "context": { "platform": "macos", "appearance": "light", "input": "pointer" },
  "measurements": [
    {
      "id": "panel-caption-light",
      "kind": "contrast",
      "element": "Panel: GitHub last-checked caption",
      "evidence": "review/panel-light.png",
      "foreground": "#6E6E73",
      "background": "#FFFFFF",
      "subject": "text",
      "text": { "size": 11, "unit": "pt", "weight": 400 }
    },
    {
      "id": "panel-host-switch",
      "kind": "target",
      "element": "Panel: lend switch for host m4",
      "evidence": "review/panel-light.png",
      "width": 32,
      "height": 20,
      "context": { "appearance": "dark" }
    }
  ]
}
```

- `context.platform` (string, required; only `macos` is measurable), `context.appearance` (`light` or `dark`, required), `context.input` (optional, default `pointer`).
- Each measurement: `id` (unique string), `element` (string), `evidence` (string path, such as a screenshot or `file:line`), `kind` (`contrast` or `target`). All four are required; a missing `id`, `element`, or `evidence`, or a duplicate `id`, is an input error.
- `contrast`: `foreground`, `background` (opaque `#RRGGBB`), `subject` (`text` default, or `non-text`), optional `text` with `size`, `unit` (`pt`), and `weight` (1 to 1000).
- `target`: `width`, `height` in pt of the hit region, not the visible glyph.
- Optional per measurement: `context` (overrides top-level keys) and `note` (copied to the result).

Output is JSON: `counts` and `countsByKind` (`total`, `passed`, `failed`, `unknown`) and `results`, each with `id`, `kind`, `element`, `evidence`, `context`, `requirementId`, `ruleId`, `threshold`, `value`, `result` (`pass`, `fail`, `unknown`), `source`, `lastVerified`, and `reason` when unknown. Exit status: 0 all pass, 1 any fail or unknown, 2 usage, rubric, or input-file error.

The output is measurement evidence for the sampled elements only. Do not extrapolate it to the whole interface. For before and after claims, compare the same element, context, and rule ID.

Run the tests after changing the tool or rubric:

```bash
python3 -m unittest discover -s .agents/skills/apple-hig-expert/scripts
```

## Keep guidance current

Apple revises the HIG after each WWDC (June) and platform release (September), and sometimes in between.

1. Check [What's new in design](https://developer.apple.com/design/whats-new/) when a rule's `lastVerified` predates the latest WWDC or September release, or when a claim drives a consequential recommendation.
2. The HIG pages render with JavaScript. If a page fetch returns only a title, read the page data at `https://developer.apple.com/tutorials/data/design/human-interface-guidelines/<page>.json`.
3. Record the source URL and the date you actually read the page. A reachable page alone is not verification. If you cannot read a page, set `"verified": false` and `"lastVerified": null` for its rules and say so in the audit.
4. Summarize Apple's guidance in your own words. Do not copy it into the skill.

Every packaged rule was read live on 2026-10-20 (macOS 27 cycle, after WWDC26 and the September 2026 releases) unless the rubric marks it unverified.
