---
name: ux-heuristics
description: 'Evaluate the usability of the little-ci macOS menu bar app (menu bar panel and details window) with heuristic analysis: Krug''s laws, Nielsen''s 10 heuristics, a 0 to 4 severity scale, the Quick Diagnostic, and an accessibility checklist. Use for "usability audit", "is this easy to use", "users are confused", "Nielsen heuristics", "cognitive walkthrough", or navigation and information problems. Measured contrast and target size belong to apple-hig-expert. A full screenshot-backed review, with optional fixes, belongs to crit.'
license: MIT
metadata:
  author: wondelai
  version: "1.6.0"
  adaptation: "little-ci: desktop utility wording; web marketing, dark-pattern and cultural material removed"
---

# UX heuristics

Practical usability principles for judging an interface. People do not read, they scan. They do not choose the best option, they take the first reasonable one. They do not learn how things work, they muddle through. A monitoring utility is opened for seconds at a time, so this matters more, not less.

little-ci's design contract overrides generic advice here. Read `../apple-hig-expert/references/little-ci-macos-profile.md` first. In short: dense information; no decorative card or pill chrome; no light-gray subtitle lines above sections; no em dashes in UI text; no continuously repainting animation (ticking relative timestamps, spinners, pulse, shimmer); the menu bar glyph is a static symbol for the worst finding. Do not report a defect that the contract requires, and do not propose a fix the contract forbids (for example, "add a spinner" for system status: propose a static state label instead).

## Scoring

Use the Quick Diagnostic as a diagnostic, not a target. Start at 10. Subtract 2 for each failed row whose worst finding is severity 3 or 4, otherwise subtract 1. Report the failed rows and the finding IDs behind each one. Rank by observed task impact. Do not invent fixes to reach 10/10.

For a screenshot-backed review with stable finding IDs and fix rounds, hand findings to [crit](../crit/SKILL.md). Crit owns the record format.

## Krug's principles

1. **Don't make me think.** Every question a label raises costs attention. Clear names beat clever names. If a label needs an explanation, change the label. Use plain verbs: "Stop runner", not "Quiesce".
2. **Clicks are cheap; doubt is expensive.** Three obvious clicks beat one click that needs thought. Panel to details window to pane is fine when each step is predictable.
3. **Remove half the words, then half of the rest.** No welcome text, no instructions nobody reads, no polite filler. Error and empty states say the fact and the next step: "No runners online. Check the host in Hosts."
4. **The Trunk Test.** Open any window or pane cold. A person must answer at once: which app is this, which pane, what are the other panes, what can I do here, where am I. On macOS the answers are the window title, the selected sidebar item, the sidebar or tab list, the toolbar and inline controls, and the selection highlight. Search applies only where a pane has a long list.

Clarity must serve the person. Plain language must never hide a consequence, such as a plan that removes a runner.

See [references/krug-principles.md](references/krug-principles.md) for the full method: scanning, satisficing, goodwill, navigation, and a $0 usability test.

## Nielsen's 10 heuristics

1. **Visibility of system status.** Show when data was last read, whether a host is reachable, and what a plan is doing. Silent failure destroys trust. Under the contract, status is a static label or symbol that changes on a state change, not a repainting indicator.
2. **Match with the real world.** Use the words the operator uses: runner, host, queue, job, busy, idle. Order follows the task.
3. **User control and freedom.** Every flow has a clear exit. Closing the panel or a review window must be safe. Destructive plans show exactly what will happen before they run.
4. **Consistency and standards.** One term per concept everywhere ("host" never also "machine" in the same sense). Follow macOS conventions: window title, sidebar, toolbar, standard shortcuts.
5. **Error prevention.** Disable actions that cannot apply (a busy runner cannot be stopped) and say why. Sensible defaults.
6. **Recognition over recall.** Show the facts needed for a decision next to the decision. Do not make the operator remember a value from another pane.
7. **Flexibility and efficiency.** Keyboard shortcuts for frequent actions (refresh, open details), keyboard navigation of lists.
8. **Aesthetic and minimalist design.** Every element earns its place. Dense is not cluttered: dense means many facts with a clear hierarchy; cluttered means decoration and repetition.
9. **Recognize, diagnose, recover from errors.** Say what happened, why, and how to fix it, in plain words. "Cannot reach studio-m4 over SSH: host key not trusted. Add it to known_hosts." Not "exit 255".
10. **Help and documentation.** Help is contextual: a tooltip or inline sentence where a term is not obvious, and the README for setup.

See [references/nielsen-heuristics.md](references/nielsen-heuristics.md) for good implementations, common violations, and severity examples for each heuristic.

## Severity scale

| Severity | Rating       | Description                       | Priority       |
| -------- | ------------ | --------------------------------- | -------------- |
| 0        | Not a problem | Disagreement, not a usability issue | Ignore        |
| 1        | Cosmetic     | Minor annoyance, low impact       | Fix if time    |
| 2        | Minor        | Causes delay or frustration       | Schedule a fix |
| 3        | Major        | Significant task failure          | Fix soon       |
| 4        | Catastrophic | Prevents task completion          | Fix now        |

Weigh three factors: frequency (how often), impact (how bad when it happens), and persistence (once, or every time). A wrong or misleading fleet state is high impact: the operator acts on it.

Use [references/audit-template.md](references/audit-template.md) for a full evaluation, one section per surface.

## Common mistakes in a desktop utility

| Mistake | Why it fails | Fix |
| ------- | ------------ | --- |
| Icon-only controls with no label or help text | People guess | Text label, or `.help` tooltip and accessibility label |
| No "last updated" fact | People cannot tell stale data from live data | Absolute time, or a relative time that does not tick |
| A state shown only by color | Color-blind people and grayscale miss it | Symbol shape or word as well as color |
| Jargon or internal codes in labels | People do not speak the code's language | The operator's words |
| Disabled control with no reason | People cannot fix the cause | Say why next to it or in its help text |
| Error text that is raw command output | No way to recover | What happened, why, next step |
| Hover-only information | Keyboard and VoiceOver users miss it | Visible text, or an accessibility label |
| Too many equal-weight items | Nothing stands out | Order by severity; the worst first |
| Inconsistent terms between panel and window | People think they are different things | One term per concept |
| Low-contrast secondary text | Hard to read, especially in dark mode | Measure it with apple-hig-expert |

See [references/wcag-checklist.md](references/wcag-checklist.md) for the accessibility checklist (keyboard, VoiceOver, focus, contrast).

## Quick Diagnostic

| Row | Question | If no | Action |
| --- | -------- | ----- | ------ |
| 1 | Can I tell which app, window, and pane this is at once? | People are lost | Window title, selected sidebar item |
| 2 | Is the main fact or action obvious? | People do not know what matters | Visual hierarchy, worst finding first |
| 3 | Is the navigation clear? | People cannot find a pane | Trunk Test, selection indicator |
| 4 | Can I find a specific runner, host, or job? | Goal-driven people are blocked | Stable ordering, or search where lists are long; N/A when lists are short |
| 5 | Does the app show what is happening and how fresh it is? | People lose trust | Static state labels, observed-at times |
| 6 | Are error messages helpful? | People get stuck | Plain words with a specific fix |
| 7 | Can I cancel or back out safely? | People are afraid to act | Cancel in every plan, review before run |
| 8 | Does it work with the keyboard and without hover? | Keyboard and VoiceOver users are excluded | Focus order, shortcuts, labels |
| 9 | Are all interactive elements labeled? | People guess at icons | Text labels or help text |
| 10 | Does anything make me stop and think "huh?" | Too much effort | Simplify; if it needs an explanation, redesign it |

## Heuristic conflicts

- **Simplicity vs. flexibility:** progressive disclosure. The panel shows the summary; the details window shows everything.
- **Consistency vs. context:** consistent patterns, contextual prominence.
- **Efficiency vs. error prevention:** undo where possible; for irreversible fleet changes, a review step is correct.
- **Discoverability vs. minimalism:** primary actions visible, secondary actions in menus.

See [references/heuristic-conflicts.md](references/heuristic-conflicts.md) when two heuristics pull in opposite directions.

## Methods

| Method | When | Time | Finds |
| ------ | ---- | ---- | ----- |
| Heuristic evaluation | Before user testing | 1 to 2 hours | Major violations |
| User testing | After heuristic fixes | 2 to 4 hours | Real behavior |
| Event and job history review | Ongoing | 30 minutes | Patterns and problems |

## Sources

Based on usability principles by Steve Krug and Jakob Nielsen. Original skill by wondelai (MIT), adapted for little-ci.

- *Don't Make Me Think, Revisited* by Steve Krug.
- *Rocket Surgery Made Easy* by Steve Krug (do-it-yourself usability testing).
- [10 Usability Heuristics for User Interface Design](https://www.nngroup.com/articles/ten-usability-heuristics/) by Jakob Nielsen, Nielsen Norman Group.
