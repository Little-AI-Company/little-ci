"""Review record rules: stable finding IDs, evidence links, verdicts, append-only history."""
from __future__ import annotations

import copy
import unittest
from typing import Any

from review_record import check_append, check_rubric_coverage, derive_verdict, finding_statuses, render_report, validate_record

BASE_COMMIT = "1" * 40
REVIEWER = {"kind": "agent", "name": "crit reviewer", "provider": "Anthropic", "model": None}


def capture_files(phase: str) -> dict[str, Any]:
    return {
        "phase": phase,
        "data": "demo",
        "manifestSha256": "b" * 64,
        "files": [
            {"file": "overview-light.png", "surface": "overview", "appearance": "light", "sha256": "c" * 64},
            {"file": "panel-dark.png", "surface": "panel", "appearance": "dark", "sha256": "d" * 64},
        ],
    }


def final_record() -> dict[str, Any]:
    return {
        "version": 1,
        "reviewId": "menu-bar-review",
        "title": "Menu bar app review",
        "original": {
            "recordedAt": "2026-10-20T12:00:00Z",
            "code": {"kind": "committed", "baseCommit": BASE_COMMIT, "commits": []},
            "actors": {"reviewer": REVIEWER, "executor": None, "verifier": None},
            "captures": capture_files("before"),
            "findings": [
                {
                    "id": "OVR-01",
                    "surface": "overview",
                    "appearance": "light",
                    "screenshot": "overview-light.png",
                    "marker": {"x": 20, "y": 30},
                    "source": "ux",
                    "heuristics": ["nielsen.1"],
                    "severity": 3,
                    "confidence": "observed",
                    "claim": "The last-read time is missing.",
                    "expectedFix": "Show when GitHub was last read.",
                },
                {
                    "id": "PNL-01",
                    "surface": "panel",
                    "appearance": "dark",
                    "screenshot": "panel-dark.png",
                    "marker": {"x": 50, "y": 10},
                    "source": "hig",
                    "higRequirement": "accessibility.contrast.text",
                    "severity": 2,
                    "confidence": "measured",
                    "measurement": "panel caption 3.1:1, requires 4.5:1",
                    "claim": "Caption text is low contrast in dark mode.",
                    "expectedFix": "Use the secondary label color.",
                },
            ],
            "ux": {"score": 8, "failedRows": [{"row": 5, "findingIds": ["OVR-01"]}]},
            "hig": {
                "requirements": [
                    {"id": "accessibility.contrast.text", "outcome": "fail", "findingIds": ["PNL-01"]},
                    {"id": "menu-bar.glyph.static", "outcome": "pass", "evidence": "panel-dark.png: static symbol"},
                    {"id": "appearance.liquid-glass", "outcome": "na", "reason": "Standard window chrome only"},
                ],
                "measurements": None,
            },
            "verdict": "Changes required",
        },
        "fixSelections": [],
        "rounds": [],
        "commitLinks": [],
    }


def with_round(record: dict[str, Any], status: str = "verified") -> dict[str, Any]:
    record = copy.deepcopy(record)
    record["fixSelections"].append(
        {"id": "selection-1", "recordedAt": "2026-10-20T13:00:00Z", "findingIds": ["OVR-01"], "evidence": "Owner asked for fixes; smallest high-confidence change."}
    )
    record["rounds"].append(
        {
            "id": "round-1",
            "recordedAt": "2026-10-20T14:00:00Z",
            "code": {"kind": "uncommitted", "baseCommit": BASE_COMMIT, "changesSha256": "e" * 64, "paths": ["app/Sources/LittleCIApp/DetailsWindow.swift"]},
            "actors": {"reviewer": None, "executor": REVIEWER, "verifier": None},
            "captures": capture_files("after"),
            "changes": [
                {
                    "id": "change-1",
                    "findingIds": ["OVR-01"],
                    "problem": "The last-read time is missing.",
                    "outcome": "The overview shows the GitHub read time.",
                    "status": status,
                    "actors": {"reviewer": None, "executor": REVIEWER, "verifier": None},
                    "evidence": [{"kind": "test", "description": "swift test --package-path app: 0 failures"}],
                    "pairs": [{"surface": "overview", "appearance": "light"}],
                }
            ],
        }
    )
    return record


class ReviewRecordValidationTests(unittest.TestCase):
    def test_final_record_and_round_pass(self) -> None:
        self.assertEqual(validate_record(final_record()), [])
        self.assertEqual(validate_record(with_round(final_record())), [])

    def test_verdict_and_ux_score_must_match_findings(self) -> None:
        record = final_record()
        record["original"]["verdict"] = "Improvements identified"
        record["original"]["ux"]["score"] = 9
        problems = validate_record(record)
        self.assertIn("original.ux.score must be 8 for the failed rows given", problems)
        self.assertIn("original.verdict must be 'Changes required' for these findings and requirements", problems)

    def test_finding_ids_are_unique_and_well_formed(self) -> None:
        record = final_record()
        record["original"]["findings"][1]["id"] = "OVR-01"
        self.assertIn("finding id OVR-01 is used twice", validate_record(record))
        record["original"]["findings"][1]["id"] = "panel-1"
        self.assertIn("original.findings[1].id must look like OVR-01", validate_record(record))

    def test_screenshot_must_be_a_before_capture_of_the_same_surface(self) -> None:
        record = final_record()
        record["original"]["findings"][0]["screenshot"] = "panel-dark.png"
        self.assertIn("original.findings[0].screenshot does not show overview/light", validate_record(record))

    def test_hig_failures_need_findings_and_no_score(self) -> None:
        record = final_record()
        record["original"]["hig"]["requirements"][0]["findingIds"] = ["OVR-01"]
        record["original"]["hig"]["score"] = 87
        problems = validate_record(record)
        self.assertIn("original.hig.score is not allowed: HIG outcomes are counts, not a score", problems)
        self.assertIn("original.hig.requirements[0] cites OVR-01, which is not a finding for accessibility.contrast.text", problems)

    def test_fixes_need_a_recorded_selection_of_at_most_three(self) -> None:
        record = with_round(final_record())
        record["fixSelections"][0]["findingIds"] = ["PNL-01"]
        self.assertIn("rounds[0].changes[0] fixes OVR-01, which no fixSelection names", validate_record(record))
        record["fixSelections"][0]["findingIds"] = ["OVR-01", "PNL-01", "OVR-01"]
        self.assertIn("fixSelections[0].findingIds must name 1 to 3 distinct findings", validate_record(record))

    def test_verified_change_needs_a_before_after_pair(self) -> None:
        record = with_round(final_record())
        record["rounds"][0]["changes"][0]["pairs"] = []
        self.assertIn("rounds[0].changes[0] is verified, so it needs a before/after pair and test evidence", validate_record(record))

    def test_every_rubric_requirement_has_one_outcome(self) -> None:
        rubric = {"requirements": [{"id": "accessibility.contrast.text"}, {"id": "menu-bar.glyph.static"}, {"id": "accessibility.voiceover.labels"}]}
        self.assertEqual(
            check_rubric_coverage(final_record(), rubric),
            ["HIG requirement accessibility.voiceover.labels has no outcome", "HIG requirement appearance.liquid-glass is not in the rubric"],
        )

    def test_draft_cannot_have_rounds(self) -> None:
        record = with_round(final_record())
        record["draft"] = True
        self.assertIn("a draft record has no rounds or commit links yet", validate_record(record))


class ReviewRecordHistoryTests(unittest.TestCase):
    def test_appending_a_round_is_allowed(self) -> None:
        saved = final_record()
        self.assertEqual(check_append(saved, with_round(saved)), [])

    def test_saved_original_and_rounds_are_immutable(self) -> None:
        saved = with_round(final_record())
        edited = copy.deepcopy(saved)
        edited["original"]["findings"][0]["severity"] = 1
        edited["rounds"][0]["changes"][0]["outcome"] = "Rewritten later."
        problems = check_append(saved, edited)
        self.assertIn("original changed after the record was saved", problems)
        self.assertIn("rounds: earlier entries were edited or removed", problems)

    def test_draft_finding_ids_stay_stable(self) -> None:
        draft = final_record()
        draft["draft"] = True
        final = copy.deepcopy(draft)
        del final["draft"]
        final["original"]["findings"] = final["original"]["findings"][:1]
        self.assertIn("finding PNL-01 disappeared; list it in original.withdrawnFindingIds instead", check_append(draft, final))
        final["original"]["withdrawnFindingIds"] = ["PNL-01"]
        self.assertEqual(check_append(draft, final), [])
        final["original"]["findings"].append(copy.deepcopy(draft["original"]["findings"][1]))
        self.assertIn("withdrawn finding id PNL-01 is reused", validate_record(final))

    def test_verified_fix_lowers_the_current_verdict(self) -> None:
        record = with_round(final_record())
        statuses = finding_statuses(record)
        self.assertEqual(statuses, {"OVR-01": "verified", "PNL-01": "open"})
        requirements = record["original"]["hig"]["requirements"]
        self.assertEqual(derive_verdict(record["original"]["findings"], statuses, requirements), "Improvements identified")
        self.assertIn("Worst open severity 3 to 2", render_report(record))
        implemented = with_round(final_record(), status="implemented")
        self.assertEqual(derive_verdict(implemented["original"]["findings"], finding_statuses(implemented), requirements), "Changes required")


if __name__ == "__main__":
    unittest.main()
