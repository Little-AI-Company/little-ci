# little-ci macOS design contract

The project owner set these rules for the little-ci menu bar app (`app/`). They override HIG defaults where the two conflict. When a HIG recommendation conflicts with this contract, keep the contract and note the conflict in the audit; do not file it as a defect. Rubric IDs are in parentheses.

## The app

A menu-bar-only SwiftUI app (`LSUIElement`, no Dock icon) that watches self-hosted GitHub Actions runners and their hosts.

- Menu bar extra: `MenuBarExtra` in `.window` style. It shows service levels, the worst findings, and a switch for each lendable host.
- Details window: `NavigationSplitView` with a toolbar and the sections Overview, Hosts, Runners, Queue, and Events.
- Plan review window: shows a plan's exact commands before anything runs.

Because the app is an agent app, it has no menu bar of its own and no Dock menu. The HIG advice to also expose functions through the menu bar or a Dock menu therefore maps to the Details window, which must reach every function the menu bar extra offers (`macos.menu-bar-extra.not-sole-path`).

## Rules

1. **Information dense** (`project.density`). Show as much useful state as fits without strain. Follow Apple's compact pattern for menu bar extras: short rows, tight grouping, one line per item where possible. Do not adopt the roomier row height and padding that the Liquid Glass list and form styles introduce when a denser system style or control size (`.controlSize(.small)`, `.listStyle(.plain)` or `.inset`) works.
2. **No decorative card or pill chrome** (`project.chrome.no-decorative-containers`). No rounded boxes, tinted panels, or capsule badges whose only job is decoration. Group with alignment, spacing, separators, `Section`, and system list or form styles. A system control that happens to be capsule shaped (a toggle, a bordered button) is not decoration.
3. **No light-gray subtitle lines above sections** (`project.text.no-section-subtitles`). No eyebrow or kicker text above a heading. Make the heading say what the section is; put any needed explanation in normal body text below it.
4. **No em dashes in UI text** (`project.text.no-em-dashes`). No U+2014 in any user-visible string, including accessibility labels and help text. Use a period, comma, colon, or parentheses. Evidence: a source search such as `grep -rn $'\xe2\x80\x94' app/Sources`.
5. **No continuously repainting views** (`project.motion.no-continuous-repaint`). Pulse, shimmer, blur, and spinner animations keep the GPU busy on high-refresh displays. This also covers:
   - `Text(date, style: .relative)`, `.timer`, and `.offset` styles, which re-render on their own schedule. Show an absolute time, or a relative string that changes only when the app's own data refreshes.
   - Indefinite `ProgressView()` (spinner or bar). Show static state text or a static symbol, such as "Running" with a symbol, or a determinate `ProgressView(value:)` that changes only when real progress changes.
   - `.symbolEffect` with a repeating or indefinite option, `.repeatForever` animations, and `TimelineView(.animation)`.
   One-shot transitions in response to a person's action are allowed and must respect Reduce Motion.
6. **Menu bar glyph shows the worst current finding with a static symbol** (`project.menu-bar.worst-finding-glyph`). One template SF Symbol per state, distinguished by shape so it works without color in the system-tinted menu bar. The accessibility label names the state. The glyph never animates.
7. **Dense menu bar layout per Apple HIG**. The menu bar is 24 pt tall and the extra is one icon. Keep the window-style panel compact; long or detailed content belongs in the Details window.

## Known HIG tensions

- Apple's Progress indicators page prefers a spinner for background work on macOS. Rule 5 replaces it with static status. Not a finding.
- Apple's Menu bar page prefers a menu over a popover-like window. The app uses the window style for switches and findings. The audit must state whether that content is too complex for a menu (`macos.menu-bar-extra.menu-first`); if a plain menu would do, that is a finding.
- Apple suggests about 12 pt of padding around bezeled controls. Rule 1 asks for density. Density does not excuse targets below the 20 by 20 pt macOS minimum or adjacent targets that are easy to confuse (`accessibility.target.macos`, `accessibility.target.spacing`).
- The plan review expires after 15 minutes as a safety measure. That is a deliberate time limit, so the UI must state it in plain words before it matters (`accessibility.cognitive.timing`).

## Evidence for this app

Use screenshots of the menu bar extra and each window in light and dark appearance, with Increase Contrast, Reduce Transparency, and Reduce Motion each turned on once. Use Accessibility Inspector and VoiceOver for labels and order. For contrast, sample the rendered pixels from the screenshot, not the design value, because the panel sits on a system material.
