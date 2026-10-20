# Reviewer brief

Use this to start a read-only reviewer on one slice of a crit fix round. One slice per reviewer. Verdict first.

Send:

- Base commit and head (or "uncommitted on <base>"), and the slice's exact paths.
- The finding IDs the slice claims to fix, with each claim and expected fix from the review record.
- The before and after screenshots for those findings (file names under `.crit/<review-id>/`).
- The design contract: `.agents/skills/apple-hig-expert/references/little-ci-macos-profile.md`.

The reviewer must:

- Change no files. Run no capture.
- Judge behavior regressions, accessibility (VoiceOver labels, keyboard focus, contrast), breaks of the design contract (decorative chrome, gray subtitle lines, em dashes in UI text, repainting animation, a menu bar glyph that is not static), weakened or deleted tests, dead code, and missing tests.
- Check every candidate against the source and the after screenshot. Drop speculation.
- Run `swift test --package-path app`.
- Report, under 400 words: PASS or FAIL; then findings ordered by consequence, each with file:line, failure mode, and smallest fix; then the commands run and their results; then its own provider, exact model, reasoning effort, and client, or "not known" for any of them.
