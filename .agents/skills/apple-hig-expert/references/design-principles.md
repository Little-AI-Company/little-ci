# Apple design principles

Apple reintroduced eight design principles on its Design principles page on 2026-06-08 (read live 2026-10-20). They are tools for weighing tradeoffs, not a checklist or a score. Rubric IDs are `design.principles.<name>`.

## Audit questions

**Purpose: make something meaningful.** Does each view serve a goal worth the person's attention? Is the most important outcome obvious before secondary detail? For little-ci: does the menu bar extra answer "is CI healthy, and if not, what is worst?" at a glance?

**Agency: let people do things their own way.** Can people see what is happening, act without being forced through a flow, and recover from mistakes? For little-ci: can someone inspect a plan, see exactly what it will run, and back out without losing context?

**Responsibility: act in people's best interest.** Is the app transparent about what it does and why? Does it collect only what it needs? Does it prevent harm instead of only warning about it? Does it never show success before the owning system confirms it?

**Familiarity: build on what people know.** Do controls use the expected macOS placement, label, symbol, and behavior? Do look-alike controls behave alike? Does feedback show when controls are available and when content changes?

**Flexibility: adapt to diverse contexts and needs.** Does the app work with pointer, keyboard, VoiceOver, and Voice Control; in light and dark appearance; with Increase Contrast, Reduce Transparency, and Reduce Motion; and at the window sizes people choose?

**Simplicity: be clear and direct.** Has every element earned its place? Is the copy the fewest exact words? Does hierarchy show where people are and what comes next? Apple notes that simplicity is not minimalism; a dense view can be simple when it is well organized.

**Craft: care about every detail.** Are type, color, alignment, wording, and state transitions precise? Does the interface stay stable while loading, refreshing, resizing, and failing? Has it been tested with real data and settings, not only the ideal state?

**Delight: make it human.** Does character come from usefulness and care? Apple warns against mistaking decoration for delight. Has decoration or motion begun to compete with the task or with performance?

## Emphasis for an operations tool

Weight purpose, agency, responsibility, and simplicity together. People need the current state, the worst problem, the next safe action, and a recovery path. Use one precise name for each domain object (host, runner, fleet, plan, finding) across the menu bar extra, windows, notifications, and accessibility labels.

## Sources

- [Apple HIG: Design principles](https://developer.apple.com/design/human-interface-guidelines/design-principles), read 2026-10-20.
- [Apple HIG: Writing](https://developer.apple.com/design/human-interface-guidelines/writing), read 2026-10-20.
- WWDC26 session "Principles of great design" is listed on What's new in design (read 2026-10-20). The video itself was not reviewed; do not cite it as verified.
