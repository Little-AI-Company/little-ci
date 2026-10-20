# UX heuristic audit template

Structured template for a heuristic evaluation of the little-ci menu bar app. Fill one copy per review. When the audit is part of a crit, every finding row becomes one finding in the crit review record; keep the field names.

## Audit information

- Review ID:
- Auditor (person, or agent with provider, exact model, reasoning effort, client):
- Date:
- Code state (commit, or base commit plus uncommitted changes):
- Data: demo fleet / live fleet
- Surfaces: panel, overview, hosts, runners, queue, events
- Appearances: light, dark
- User context: an operator who glances at the menu bar, opens the panel to see what is wrong, and opens the details window to diagnose and act.

## Severity reference

| Rating | Severity      | Priority | Description                 |
| ------ | ------------- | -------- | --------------------------- |
| 0      | Not a problem | None     | Disagreement, not a defect  |
| 1      | Cosmetic      | Low      | Minor annoyance             |
| 2      | Minor         | Medium   | Delays or frustrates        |
| 3      | Major         | High     | Significant task failure    |
| 4      | Catastrophic  | Critical | Prevents task completion    |

Weigh frequency, impact, and persistence. State the reason in one line.

## Heuristic checklist

Mark each check pass, fail (with finding ID), or N/A (with reason).

### 1. Visibility of system status

| Check | Result | Finding |
| ----- | ------ | ------- |
| The time each source was last read is visible | | |
| Unreachable hosts and failed reads are visible, not silent | | |
| A running plan shows its current step and result | | |
| Status uses static labels or symbols, not repainting animation | | |

### 2. Match with the real world

| Check | Result | Finding |
| ----- | ------ | ------- |
| Labels use the operator's words (runner, host, job, queue, busy, idle) | | |
| Symbols are recognizable SF Symbols with a clear meaning | | |
| Order follows the task (worst first, then by host or lane) | | |

### 3. User control and freedom

| Check | Result | Finding |
| ----- | ------ | ------- |
| Every review and plan window has Cancel or Close | | |
| Closing the panel or a window never changes the fleet | | |
| Destructive plans show exact effects before Run | | |

### 4. Consistency and standards

| Check | Result | Finding |
| ----- | ------ | ------- |
| One term per concept in the panel and all panes | | |
| The same kind of fact looks the same everywhere | | |
| macOS conventions: window title, sidebar, toolbar, standard shortcuts | | |

### 5. Error prevention

| Check | Result | Finding |
| ----- | ------ | ------- |
| Actions that cannot apply are disabled, with the reason given | | |
| Demo mode visibly disables plans | | |
| Defaults are safe | | |

### 6. Recognition rather than recall

| Check | Result | Finding |
| ----- | ------ | ------- |
| Facts needed for a decision are next to the decision | | |
| Icons have labels or help text | | |
| Selection and current pane are visible | | |

### 7. Flexibility and efficiency

| Check | Result | Finding |
| ----- | ------ | ------- |
| Frequent actions have keyboard shortcuts | | |
| Lists can be navigated with the keyboard | | |
| Frequent tasks take few, obvious steps | | |

### 8. Aesthetic and minimalist design

| Check | Result | Finding |
| ----- | ------ | ------- |
| Dense information with a clear hierarchy | | |
| No decorative card or pill chrome | | |
| No light-gray subtitle lines above sections | | |
| No em dashes in UI text | | |
| The most important fact is the most prominent | | |

### 9. Error recovery

| Check | Result | Finding |
| ----- | ------ | ------- |
| Errors are in plain words | | |
| Errors say what went wrong and how to fix it | | |
| A failed plan shows exactly which commands did not run | | |

### 10. Help and documentation

| Check | Result | Finding |
| ----- | ------ | ------- |
| Non-obvious terms have help text | | |
| Setup problems point to the file or command that fixes them | | |

## Quick Diagnostic

Use the ten rows in `../SKILL.md`. Score: start at 10, subtract 2 per failed row whose worst finding is severity 3 or 4, otherwise 1.

| Row | Pass | Worst finding |
| --- | ---- | ------------- |
| 1 | | |
| 2 | | |
| 3 | | |
| 4 | | |
| 5 | | |
| 6 | | |
| 7 | | |
| 8 | | |
| 9 | | |
| 10 | | |

Score: __ / 10. Failed rows: __.

## Trunk Test (one row per surface)

| Surface | Which app | Which pane | Other panes | Options here | Where am I |
| ------- | --------- | ---------- | ----------- | ------------ | ---------- |
| panel | | | | | |
| overview | | | | | |
| hosts | | | | | |
| runners | | | | | |
| queue | | | | | |
| events | | | | | |

## Findings

One row per defect. The same defect on several surfaces is one finding that names its main surface and lists the others in the claim.

| ID | Surface | Appearance | Screenshot | Marker (x%, y%) | Heuristic | Severity | Reason | Claim | Expected fix |
| -- | ------- | ---------- | ---------- | --------------- | --------- | -------- | ------ | ----- | ------------ |
| | | | | | | | | | |

IDs are stable: `<SURFACE>-NN`, for example `PNL-01`, `OVR-02`, `HST-01`, `RUN-01`, `QUE-01`, `EVT-01`, and `APP-01` for a defect that spans the app. Never reuse or renumber an ID.

## Task walkthroughs (optional)

| Task | Step | Expected | Actual | Finding |
| ---- | ---- | -------- | ------ | ------- |
| Find why CI is slow right now | | | | |
| Find which runner is offline and why | | | | |
| Lend a host, then take it back | | | | |
| Review a stop plan and cancel it | | | | |

## Non-findings

Plausible concerns that are correct under the design contract (for example, dense rows without card backgrounds). One line each with the surface.
