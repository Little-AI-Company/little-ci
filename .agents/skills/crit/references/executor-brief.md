# Executor brief

Send exactly this shape. An executor that gets less drifts into other files or skips validation.

- Finding ID, claim, expected fix, and the design-contract lines that apply, quoted.
- The executor model and reasoning effort the user chose, if any. The executor reports the provider, exact model, reasoning effort, and client it actually used. Unknown stays unknown.
- Files it owns (for example one view in `app/Sources/LittleCIApp/`). Files it must not touch, including every other executor's files, `.crit/`, and the review record.
- Budget in minutes. Do not commit, push, or switch branches.
- Validation: `swift test --package-path app` and `app/scripts/build-app.sh` must pass. Retarget a test when behavior changes on purpose; never delete one without naming it and saying why.
- Do not run a capture. The orchestrator recaptures `after` once all executors finish, so the images match one build.
- Report: files changed, UI strings before and after, exact commands and results, and anything not finished.
