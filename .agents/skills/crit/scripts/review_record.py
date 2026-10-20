#!/usr/bin/env python3
"""Validate, render, and stamp crit review records (format version 1).

  review_record.py validate <review.json> [--previous <earlier review.json>] [--rubric <hig-rubric.json>]
  review_record.py render <review.json> [--output <report.html>]
  review_record.py code-state

`validate` checks one record; with --previous, also the append-only rules
between two versions of it; with --rubric, also that every HIG rubric
requirement has exactly one outcome. `render` writes a static HTML report (default
.crit/<review-id>/report.html) with numbered markers over the screenshots.
`code-state` prints the current Git state as a record `code` object without
copying any source content. references/review-record.md describes the format.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

from capture import APPEARANCES, PHASE_PATTERN, REVIEW_ID_PATTERN, SHA256_PATTERN, SURFACES, capture_file_name

REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
TRACKED_DIRECTORY = ("docs", "design-reviews")
RECORD_VERSION = 1
FINDING_ID_PATTERN = re.compile(r"^(PNL|OVR|HST|RUN|QUE|EVT|APP)-[0-9]{2,}$")
RECORD_ID_PATTERN = re.compile(r"^[a-z][a-z0-9-]{0,63}$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
TIMESTAMP_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$")
SOURCES = ("ux", "hig", "both")
CONFIDENCES = ("measured", "observed", "needs device test", "assumption")
OUTCOMES = ("pass", "fail", "untested", "na")
CHANGE_STATUSES = ("open", "implemented", "verified", "deferred", "rejected")
CLOSED_STATUSES = ("verified", "rejected")
EVIDENCE_KINDS = ("test", "behavior", "verification", "other")
ROLES = ("reviewer", "executor", "verifier")
MAXIMUM_FIXES_PER_ROUND = 3
VERDICTS = ("Blocked", "Changes required", "Review incomplete", "Improvements identified", "Ready for decision")


class RecordProblems:
    def __init__(self) -> None:
        self.messages: list[str] = []

    def add(self, message: str) -> None:
        self.messages.append(message)

    def require(self, condition: bool, message: str) -> bool:
        if not condition:
            self.add(message)
        return condition


def is_text(value: Any) -> bool:
    return isinstance(value, str) and value.strip() != ""


def is_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def check_timestamp(value: Any, label: str, problems: RecordProblems) -> None:
    problems.require(isinstance(value, str) and bool(TIMESTAMP_PATTERN.match(value)), f"{label} must be an ISO 8601 timestamp")


def check_actor(value: Any, label: str, problems: RecordProblems) -> None:
    if value is None:
        return
    if not problems.require(isinstance(value, dict), f"{label} must be null or an object"):
        return
    kind = value.get("kind")
    problems.require(kind in ("human", "agent"), f"{label}.kind must be human or agent")
    problems.require(is_text(value.get("name")), f"{label}.name must be text")
    if kind == "agent":
        problems.require(is_text(value.get("provider")), f"{label}.provider is required for an agent")
    model = value.get("model")
    problems.require(model is None or is_text(model), f"{label}.model must be text or null (null when unknown)")
    for field in ("reasoning", "harness"):
        problems.require(field not in value or is_text(value[field]), f"{label}.{field} must be text when present")


def check_actors(value: Any, label: str, problems: RecordProblems) -> None:
    if not problems.require(isinstance(value, dict) and set(value) == set(ROLES), f"{label} must have exactly the keys {', '.join(ROLES)}"):
        return
    for role in ROLES:
        check_actor(value[role], f"{label}.{role}", problems)


def check_code(value: Any, label: str, problems: RecordProblems) -> None:
    if not problems.require(isinstance(value, dict), f"{label} must be an object"):
        return
    kind = value.get("kind")
    if kind == "committed":
        problems.require(bool(COMMIT_PATTERN.match(str(value.get("baseCommit", "")))), f"{label}.baseCommit must be a full commit SHA")
        commits = value.get("commits")
        problems.require(
            isinstance(commits, list) and all(COMMIT_PATTERN.match(str(commit)) for commit in commits),
            f"{label}.commits must be a list of full commit SHAs",
        )
    elif kind == "uncommitted":
        problems.require(bool(COMMIT_PATTERN.match(str(value.get("baseCommit", "")))), f"{label}.baseCommit must be a full commit SHA")
        problems.require(bool(SHA256_PATTERN.match(str(value.get("changesSha256", "")))), f"{label}.changesSha256 must be a SHA-256 digest")
        paths = value.get("paths")
        problems.require(isinstance(paths, list) and bool(paths) and all(is_text(path) for path in paths), f"{label}.paths must list the changed paths")
    elif kind == "unavailable":
        problems.require(is_text(value.get("reason")), f"{label}.reason must say why the code state is unknown")
    else:
        problems.add(f"{label}.kind must be committed, uncommitted, or unavailable")


def check_captures(value: Any, label: str, problems: RecordProblems) -> dict[str, dict[str, Any]]:
    """Return capture files by name."""
    if not problems.require(isinstance(value, dict), f"{label} must be an object"):
        return {}
    problems.require(bool(PHASE_PATTERN.match(str(value.get("phase", "")))), f"{label}.phase must be before, after, or after-<n>")
    problems.require(value.get("data") in ("demo", "live"), f"{label}.data must be demo or live")
    problems.require(bool(SHA256_PATTERN.match(str(value.get("manifestSha256", "")))), f"{label}.manifestSha256 must be the capture.json SHA-256")
    files = value.get("files")
    if not problems.require(isinstance(files, list) and bool(files), f"{label}.files must list the captured files"):
        return {}
    by_name: dict[str, dict[str, Any]] = {}
    for index, entry in enumerate(files):
        entry_label = f"{label}.files[{index}]"
        if not problems.require(isinstance(entry, dict), f"{entry_label} must be an object"):
            continue
        surface, appearance = entry.get("surface"), entry.get("appearance")
        if not problems.require(surface in SURFACES and appearance in APPEARANCES, f"{entry_label} has an unknown surface or appearance"):
            continue
        name = capture_file_name(surface, appearance)
        problems.require(entry.get("file") == name, f"{entry_label}.file must be {name}")
        problems.require(bool(SHA256_PATTERN.match(str(entry.get("sha256", "")))), f"{entry_label}.sha256 must be a SHA-256 digest")
        problems.require(name not in by_name, f"{entry_label} repeats {name}")
        by_name[name] = entry
    return by_name


def check_finding(finding: Any, label: str, before_files: dict[str, dict[str, Any]], problems: RecordProblems) -> None:
    if not problems.require(isinstance(finding, dict), f"{label} must be an object"):
        return
    surface, appearance, screenshot = finding.get("surface"), finding.get("appearance"), finding.get("screenshot")
    problems.require(surface in SURFACES, f"{label}.surface must be one of {', '.join(SURFACES)}")
    problems.require(appearance in APPEARANCES, f"{label}.appearance must be light or dark")
    captured = before_files.get(str(screenshot))
    if problems.require(captured is not None, f"{label}.screenshot {screenshot!r} is not a before capture"):
        problems.require(
            captured["surface"] == surface and captured["appearance"] == appearance,
            f"{label}.screenshot does not show {surface}/{appearance}",
        )
    marker = finding.get("marker")
    problems.require(
        isinstance(marker, dict)
        and all(isinstance(marker.get(axis), (int, float)) and not isinstance(marker.get(axis), bool) and 0 <= marker[axis] <= 100 for axis in ("x", "y")),
        f"{label}.marker must have x and y between 0 and 100 (percent of the image)",
    )
    source = finding.get("source")
    problems.require(source in SOURCES, f"{label}.source must be ux, hig, or both")
    if source in ("ux", "both"):
        heuristics = finding.get("heuristics")
        problems.require(isinstance(heuristics, list) and bool(heuristics) and all(is_text(h) for h in heuristics), f"{label}.heuristics must name the failed heuristics")
    if source in ("hig", "both"):
        problems.require(is_text(finding.get("higRequirement")), f"{label}.higRequirement is required for a HIG finding")
    problems.require(is_integer(finding.get("severity")) and 0 <= finding["severity"] <= 4, f"{label}.severity must be an integer from 0 to 4")
    problems.require(finding.get("confidence") in CONFIDENCES, f"{label}.confidence must be one of {', '.join(CONFIDENCES)}")
    if finding.get("confidence") == "measured":
        problems.require(is_text(finding.get("measurement")), f"{label}.measurement must quote the measured result")
    for field in ("claim", "expectedFix"):
        problems.require(is_text(finding.get(field)), f"{label}.{field} must be text")
    problems.require("doctrine" not in finding or is_text(finding["doctrine"]), f"{label}.doctrine must be text when present")


def ux_diagnostic_score(failed_rows: list[dict[str, Any]], severity_by_id: dict[str, int]) -> int:
    penalty = 0
    for row in failed_rows:
        worst = max((severity_by_id.get(finding_id, 0) for finding_id in row["findingIds"]), default=0)
        penalty += 2 if worst >= 3 else 1
    return max(0, 10 - penalty)


def check_ux(value: Any, severity_by_id: dict[str, int], problems: RecordProblems) -> None:
    if not problems.require(isinstance(value, dict), "original.ux must be an object"):
        return
    rows = value.get("failedRows")
    if not problems.require(isinstance(rows, list), "original.ux.failedRows must be a list"):
        return
    seen_rows: set[int] = set()
    valid = True
    for index, row in enumerate(rows):
        label = f"original.ux.failedRows[{index}]"
        if not (isinstance(row, dict) and is_integer(row.get("row")) and 1 <= row["row"] <= 10 and isinstance(row.get("findingIds"), list) and row["findingIds"]):
            problems.add(f"{label} must have a row from 1 to 10 and its findingIds")
            valid = False
            continue
        problems.require(row["row"] not in seen_rows, f"{label} repeats row {row['row']}")
        seen_rows.add(row["row"])
        for finding_id in row["findingIds"]:
            problems.require(finding_id in severity_by_id, f"{label} names unknown finding {finding_id}")
    if valid:
        expected = ux_diagnostic_score(rows, severity_by_id)
        problems.require(value.get("score") == expected, f"original.ux.score must be {expected} for the failed rows given")


def check_hig(value: Any, findings: list[dict[str, Any]], draft: bool, problems: RecordProblems) -> None:
    if not problems.require(isinstance(value, dict), "original.hig must be an object"):
        return
    for forbidden in ("score", "compliance", "passRate"):
        problems.require(forbidden not in value, f"original.hig.{forbidden} is not allowed: HIG outcomes are counts, not a score")
    requirements = value.get("requirements")
    if not problems.require(isinstance(requirements, list) and (draft or bool(requirements)), "original.hig.requirements must list every requirement outcome"):
        return
    finding_by_id = {finding.get("id"): finding for finding in findings if isinstance(finding, dict)}
    outcome_by_id: dict[str, str] = {}
    for index, requirement in enumerate(requirements):
        label = f"original.hig.requirements[{index}]"
        if not problems.require(isinstance(requirement, dict) and is_text(requirement.get("id")), f"{label} must be an object with an id"):
            continue
        requirement_id, outcome = requirement["id"], requirement.get("outcome")
        problems.require(requirement_id not in outcome_by_id, f"{label} repeats {requirement_id}")
        problems.require(outcome in OUTCOMES, f"{label}.outcome must be pass, fail, untested, or na")
        outcome_by_id[requirement_id] = str(outcome)
        if outcome == "fail":
            linked = requirement.get("findingIds")
            if problems.require(isinstance(linked, list) and bool(linked), f"{label} fails, so it must cite findingIds"):
                for finding_id in linked:
                    finding = finding_by_id.get(finding_id)
                    problems.require(
                        finding is not None and finding.get("higRequirement") == requirement_id,
                        f"{label} cites {finding_id}, which is not a finding for {requirement_id}",
                    )
        elif outcome == "pass":
            problems.require(is_text(requirement.get("evidence")), f"{label} passes, so it must cite evidence")
        elif outcome == "untested":
            problems.require(is_text(requirement.get("testNeeded")), f"{label} is untested, so it must say what test is needed")
        elif outcome == "na":
            problems.require(is_text(requirement.get("reason")), f"{label} is N/A, so it must give a reason")
    for finding in findings:
        if isinstance(finding, dict) and finding.get("source") in ("hig", "both") and not draft:
            problems.require(
                outcome_by_id.get(str(finding.get("higRequirement"))) == "fail",
                f"finding {finding.get('id')} needs a failed requirement {finding.get('higRequirement')}",
            )
    measurements = value.get("measurements")
    if measurements is not None:
        if problems.require(isinstance(measurements, dict), "original.hig.measurements must be null or an object"):
            for field in ("input", "report"):
                problems.require(str(measurements.get(field, "")).startswith(".crit/"), f"original.hig.measurements.{field} must be a path under .crit/")
            problems.require(bool(SHA256_PATTERN.match(str(measurements.get("reportSha256", "")))), "original.hig.measurements.reportSha256 must be a SHA-256 digest")


def finding_statuses(record: dict[str, Any]) -> dict[str, str]:
    """The current status of every original finding: the latest change that names it, else open."""
    statuses = {finding["id"]: "open" for finding in record["original"]["findings"]}
    for round_record in record.get("rounds", []):
        for change in round_record["changes"]:
            for finding_id in change["findingIds"]:
                statuses[finding_id] = change["status"]
    return statuses


def derive_verdict(findings: list[dict[str, Any]], statuses: dict[str, str], requirements: list[dict[str, Any]]) -> str:
    open_severities = [finding["severity"] for finding in findings if statuses.get(finding["id"], "open") not in CLOSED_STATUSES]
    if 4 in open_severities:
        return "Blocked"
    if 3 in open_severities:
        return "Changes required"
    if any(requirement.get("outcome") == "untested" for requirement in requirements):
        return "Review incomplete"
    if any(severity in (1, 2) for severity in open_severities):
        return "Improvements identified"
    return "Ready for decision"


def validate_record(record: Any) -> list[str]:
    problems = RecordProblems()
    if not isinstance(record, dict):
        return ["record must be a JSON object"]
    draft = record.get("draft", False) is True
    problems.require(record.get("version") == RECORD_VERSION, f"version must be {RECORD_VERSION}")
    problems.require("draft" not in record or record["draft"] is True, "draft must be true or absent")
    problems.require(bool(REVIEW_ID_PATTERN.match(str(record.get("reviewId", "")))), "reviewId must be lowercase letters, digits and hyphens")
    problems.require(is_text(record.get("title")), "title must be text")
    original = record.get("original")
    if not problems.require(isinstance(original, dict), "original must be an object"):
        return problems.messages
    check_timestamp(original.get("recordedAt"), "original.recordedAt", problems)
    check_code(original.get("code"), "original.code", problems)
    check_actors(original.get("actors"), "original.actors", problems)
    before_files = check_captures(original.get("captures"), "original.captures", problems)
    findings = original.get("findings")
    if not problems.require(isinstance(findings, list), "original.findings must be a list"):
        return problems.messages
    ids: list[str] = []
    for index, finding in enumerate(findings):
        finding_id = finding.get("id") if isinstance(finding, dict) else None
        if problems.require(bool(FINDING_ID_PATTERN.match(str(finding_id))), f"original.findings[{index}].id must look like OVR-01"):
            problems.require(finding_id not in ids, f"finding id {finding_id} is used twice")
            ids.append(str(finding_id))
        check_finding(finding, f"original.findings[{index}]", before_files, problems)
    withdrawn = original.get("withdrawnFindingIds", [])
    if problems.require(isinstance(withdrawn, list), "original.withdrawnFindingIds must be a list"):
        for finding_id in withdrawn:
            problems.require(finding_id not in ids, f"withdrawn finding id {finding_id} is reused")
    for index, non_finding in enumerate(original.get("nonFindings", [])):
        problems.require(
            isinstance(non_finding, dict) and non_finding.get("surface") in SURFACES and is_text(non_finding.get("claim")),
            f"original.nonFindings[{index}] needs a surface and a claim",
        )
    if problems.messages:
        return problems.messages
    severity_by_id = {finding["id"]: finding["severity"] for finding in findings}
    if not draft or "ux" in original:
        check_ux(original.get("ux"), severity_by_id, problems)
    if not draft or "hig" in original:
        check_hig(original.get("hig"), findings, draft, problems)
    if not draft or "verdict" in original:
        requirements = original.get("hig", {}).get("requirements", []) if isinstance(original.get("hig"), dict) else []
        expected = derive_verdict(findings, {}, requirements if isinstance(requirements, list) else [])
        problems.require(original.get("verdict") == expected, f"original.verdict must be {expected!r} for these findings and requirements")
    check_history(record, set(ids), draft, problems)
    return problems.messages


def check_history(record: dict[str, Any], finding_ids: set[str], draft: bool, problems: RecordProblems) -> None:
    selections, rounds, links = record.get("fixSelections", []), record.get("rounds", []), record.get("commitLinks", [])
    for name, value in (("fixSelections", selections), ("rounds", rounds), ("commitLinks", links)):
        if not problems.require(isinstance(value, list), f"{name} must be a list"):
            return
    if draft:
        problems.require(not rounds and not links, "a draft record has no rounds or commit links yet")
    selected: set[str] = set()
    record_ids: set[str] = set()
    for index, selection in enumerate(selections):
        label = f"fixSelections[{index}]"
        if not problems.require(isinstance(selection, dict), f"{label} must be an object"):
            continue
        check_record_id(selection.get("id"), label, record_ids, problems)
        check_timestamp(selection.get("recordedAt"), f"{label}.recordedAt", problems)
        chosen = selection.get("findingIds")
        if problems.require(
            isinstance(chosen, list) and 1 <= len(chosen) <= MAXIMUM_FIXES_PER_ROUND and len(set(chosen)) == len(chosen),
            f"{label}.findingIds must name 1 to {MAXIMUM_FIXES_PER_ROUND} distinct findings",
        ):
            for finding_id in chosen:
                problems.require(finding_id in finding_ids, f"{label} selects unknown finding {finding_id}")
            selected.update(chosen)
        problems.require(is_text(selection.get("evidence")), f"{label}.evidence must say who authorized the fixes and why these")
    change_ids: dict[str, set[str]] = {}
    for index, round_record in enumerate(rounds):
        label = f"rounds[{index}]"
        if not problems.require(isinstance(round_record, dict), f"{label} must be an object"):
            continue
        check_record_id(round_record.get("id"), label, record_ids, problems)
        check_timestamp(round_record.get("recordedAt"), f"{label}.recordedAt", problems)
        check_code(round_record.get("code"), f"{label}.code", problems)
        check_actors(round_record.get("actors"), f"{label}.actors", problems)
        after_files = check_captures(round_record.get("captures"), f"{label}.captures", problems) if "captures" in round_record else {}
        changes = round_record.get("changes")
        if not problems.require(isinstance(changes, list) and bool(changes), f"{label}.changes must list at least one change"):
            continue
        fixed: set[str] = set()
        change_ids[str(round_record.get("id"))] = set()
        for change_index, change in enumerate(changes):
            change_label = f"{label}.changes[{change_index}]"
            if not problems.require(isinstance(change, dict), f"{change_label} must be an object"):
                continue
            check_record_id(change.get("id"), change_label, record_ids, problems)
            change_ids[str(round_record.get("id"))].add(str(change.get("id")))
            fixed.update(check_change(change, change_label, finding_ids, selected, after_files, record, problems))
        problems.require(len(fixed) <= MAXIMUM_FIXES_PER_ROUND, f"{label} changes {len(fixed)} findings; the limit is {MAXIMUM_FIXES_PER_ROUND}")
    for index, link in enumerate(links):
        label = f"commitLinks[{index}]"
        if not problems.require(isinstance(link, dict), f"{label} must be an object"):
            continue
        check_record_id(link.get("id"), label, record_ids, problems)
        check_timestamp(link.get("recordedAt"), f"{label}.recordedAt", problems)
        round_changes = change_ids.get(str(link.get("roundId")))
        if problems.require(round_changes is not None, f"{label}.roundId names no round"):
            linked = link.get("changeIds")
            problems.require(
                isinstance(linked, list) and bool(linked) and all(change_id in round_changes for change_id in linked),
                f"{label}.changeIds must name changes in {link.get('roundId')}",
            )
        code = link.get("code")
        check_code(code, f"{label}.code", problems)
        problems.require(isinstance(code, dict) and code.get("kind") == "committed" and bool(code.get("commits")), f"{label}.code must be committed with at least one commit")


def check_record_id(value: Any, label: str, seen: set[str], problems: RecordProblems) -> None:
    if problems.require(bool(RECORD_ID_PATTERN.match(str(value))), f"{label}.id must be lowercase letters, digits and hyphens"):
        problems.require(value not in seen, f"{label}.id {value} is used twice")
        seen.add(str(value))


def check_change(
    change: dict[str, Any],
    label: str,
    finding_ids: set[str],
    selected: set[str],
    after_files: dict[str, dict[str, Any]],
    record: dict[str, Any],
    problems: RecordProblems,
) -> set[str]:
    """Return the findings this change claims to have fixed."""
    named = change.get("findingIds")
    if not problems.require(isinstance(named, list) and bool(named), f"{label}.findingIds must name findings"):
        return set()
    for finding_id in named:
        problems.require(finding_id in finding_ids, f"{label} names unknown finding {finding_id}")
    status = change.get("status")
    problems.require(status in CHANGE_STATUSES, f"{label}.status must be one of {', '.join(CHANGE_STATUSES)}")
    for field in ("problem", "outcome"):
        problems.require(is_text(change.get(field)), f"{label}.{field} must be text")
    check_actors(change.get("actors"), f"{label}.actors", problems)
    evidence = change.get("evidence", [])
    kinds: set[str] = set()
    if problems.require(isinstance(evidence, list), f"{label}.evidence must be a list"):
        for index, item in enumerate(evidence):
            if problems.require(isinstance(item, dict) and item.get("kind") in EVIDENCE_KINDS and is_text(item.get("description")), f"{label}.evidence[{index}] needs a kind and a description"):
                kinds.add(item["kind"])
    pairs = change.get("pairs", [])
    before_files = {entry["file"]: entry for entry in record["original"]["captures"]["files"]}
    if problems.require(isinstance(pairs, list), f"{label}.pairs must be a list"):
        for index, pair in enumerate(pairs):
            pair_label = f"{label}.pairs[{index}]"
            if not problems.require(isinstance(pair, dict) and pair.get("surface") in SURFACES and pair.get("appearance") in APPEARANCES, f"{pair_label} needs a surface and an appearance"):
                continue
            name = capture_file_name(pair["surface"], pair["appearance"])
            problems.require(name in before_files, f"{pair_label}: {name} is not a before capture")
            problems.require(name in after_files, f"{pair_label}: {name} is not in this round's after captures")
    if status in ("implemented", "verified"):
        unselected = [finding_id for finding_id in named if finding_id not in selected]
        problems.require(not unselected, f"{label} fixes {', '.join(map(str, unselected))}, which no fixSelection names")
        problems.require(bool(kinds & {"test", "behavior"}), f"{label} is {status}, so it needs test or behavior evidence")
    if status == "verified":
        problems.require(bool(pairs) and "test" in kinds, f"{label} is verified, so it needs a before/after pair and test evidence")
    return set(named) if status in ("implemented", "verified") else set()


def check_append(previous: dict[str, Any], current: dict[str, Any]) -> list[str]:
    """Rules between two versions of one record. A saved record only grows; IDs never change meaning."""
    problems = RecordProblems()
    problems.require(current.get("reviewId") == previous.get("reviewId"), "reviewId changed")
    if previous.get("draft") is True:
        current_surfaces = {finding["id"]: finding["surface"] for finding in current["original"]["findings"]}
        withdrawn = set(current["original"].get("withdrawnFindingIds", []))
        for finding in previous["original"]["findings"]:
            finding_id = finding["id"]
            if finding_id in withdrawn:
                continue
            problems.require(finding_id in current_surfaces, f"finding {finding_id} disappeared; list it in original.withdrawnFindingIds instead")
            problems.require(current_surfaces.get(finding_id, finding["surface"]) == finding["surface"], f"finding {finding_id} moved to another surface")
        problems.require(set(previous["original"].get("withdrawnFindingIds", [])) <= withdrawn, "a withdrawn finding id came back")
        return problems.messages
    problems.require(current.get("draft") is not True, "a saved record cannot become a draft again")
    for field in ("version", "title", "original"):
        problems.require(current.get(field) == previous.get(field), f"{field} changed after the record was saved")
    for field in ("fixSelections", "rounds", "commitLinks"):
        earlier, later = previous.get(field, []), current.get(field, [])
        problems.require(later[: len(earlier)] == earlier, f"{field}: earlier entries were edited or removed")
    return problems.messages


def check_rubric_coverage(record: dict[str, Any], rubric: Any) -> list[str]:
    """Every requirement ID in the HIG rubric has exactly one outcome, and no other IDs appear."""
    rubric_ids = [requirement.get("id") for requirement in rubric.get("requirements", [])] if isinstance(rubric, dict) else []
    if not rubric_ids:
        return ["the rubric has no requirements[].id entries"]
    recorded = [requirement.get("id") for requirement in record["original"].get("hig", {}).get("requirements", [])]
    problems = [f"HIG requirement {requirement_id} has no outcome" for requirement_id in rubric_ids if requirement_id not in recorded]
    problems += [f"HIG requirement {requirement_id} is not in the rubric" for requirement_id in recorded if requirement_id not in rubric_ids]
    return problems


def current_code_state() -> dict[str, Any]:
    def git(*arguments: str) -> bytes:
        return subprocess.run(["git", "-C", str(REPOSITORY_ROOT), *arguments], check=True, capture_output=True).stdout

    head = git("rev-parse", "HEAD").decode().strip()
    tracked_diff = git("diff", "--binary", "HEAD")
    changed = git("diff", "--name-only", "HEAD").decode().split()
    untracked = git("ls-files", "--others", "--exclude-standard", "-z").decode().split("\0")
    untracked = sorted(path for path in untracked if path)
    if not tracked_diff and not untracked:
        return {"kind": "committed", "baseCommit": head, "commits": []}
    digest = hashlib.sha256(tracked_diff)
    for path in untracked:
        file_path = REPOSITORY_ROOT / path
        content = file_path.read_bytes() if file_path.is_file() and not file_path.is_symlink() else b""
        digest.update(b"\0" + path.encode() + b"\0" + hashlib.sha256(content).digest())
    return {"kind": "uncommitted", "baseCommit": head, "changesSha256": digest.hexdigest(), "paths": sorted({*changed, *untracked})}


def describe_actor(actor: dict[str, Any] | None) -> str:
    if actor is None:
        return "not recorded"
    if actor["kind"] == "human":
        return actor["name"]
    model = actor.get("model") or "model not recorded"
    reasoning = f", {actor['reasoning']}" if actor.get("reasoning") else ""
    harness = f" via {actor['harness']}" if actor.get("harness") else ""
    return f"{actor['name']} ({model}{reasoning}; {actor['provider']}{harness})"


def render_report(record: dict[str, Any]) -> str:
    original = record["original"]
    findings = original["findings"]
    statuses = finding_statuses(record)
    requirements = original.get("hig", {}).get("requirements", [])
    counts = {outcome: sum(1 for requirement in requirements if requirement["outcome"] == outcome) for outcome in OUTCOMES}
    open_findings = [finding for finding in findings if statuses[finding["id"]] not in CLOSED_STATUSES]
    worst_before = max((finding["severity"] for finding in findings), default=0)
    worst_now = max((finding["severity"] for finding in open_findings), default=0)
    escape = html.escape
    parts = [
        "<!doctype html><html lang=en><meta charset=utf-8>",
        f"<title>{escape(record['title'])}</title>",
        "<style>:root{color-scheme:light dark;--line:#8884;--mark:#d70015}body{font:13px/1.4 -apple-system,system-ui,sans-serif;margin:16px;max-width:1400px}"
        "table{border-collapse:collapse;width:100%}td,th{border-bottom:1px solid var(--line);padding:3px 6px;text-align:left;vertical-align:top}"
        ".shot{position:relative;display:inline-block;max-width:100%}.shot img{max-width:100%;display:block;border:1px solid var(--line)}"
        ".mark{position:absolute;transform:translate(-50%,-50%);background:var(--mark);color:#fff;font-weight:600;padding:0 4px;text-decoration:none}"
        ".pair{display:grid;grid-template-columns:1fr 1fr;gap:8px}.pair img{max-width:100%}</style>",
        f"<h1>{escape(record['title'])}{' (draft, in progress)' if record.get('draft') else ''}</h1>",
    ]
    header = []
    if "ux" in original:
        header.append(f"UX {original['ux']['score']}/10")
    if requirements:
        header.append(f"HIG {counts['pass']} pass, {counts['fail']} fail, {counts['untested']} untested, {counts['na']} N/A")
    verdict_now = derive_verdict(findings, statuses, requirements)
    header.append(verdict_now)
    header.append(f"Worst open severity {worst_before} to {worst_now}" if record.get("rounds") else f"Worst open severity {worst_before}")
    parts.append(f"<p>{escape(' · '.join(header))}</p>")
    parts.append(f"<p>Reviewer: {escape(describe_actor(original['actors']['reviewer']))}. Code: {escape(json.dumps(original['code']))}. Data: {escape(original['captures']['data'])}.</p>")
    parts.append("<h2>Findings</h2><table><tr><th>ID<th>Severity<th>Status<th>Surface<th>Source<th>Claim<th>Expected fix</tr>")
    for finding in sorted(findings, key=lambda finding: (-finding["severity"], SURFACES.index(finding["surface"]), finding["id"])):
        parts.append(
            f"<tr id={escape(finding['id'])}><td>{escape(finding['id'])}<td>{finding['severity']}<td>{escape(statuses[finding['id']])}"
            f"<td>{escape(finding['surface'])}/{escape(finding['appearance'])}<td>{escape(finding['source'])}"
            f"<td>{escape(finding['claim'])}<td>{escape(finding['expectedFix'])}</tr>"
        )
    parts.append("</table><h2>Annotations</h2>")
    phase = original["captures"]["phase"]
    for entry in original["captures"]["files"]:
        marked = [finding for finding in findings if finding["screenshot"] == entry["file"]]
        if not marked:
            continue
        parts.append(f"<h3>{escape(entry['file'])}</h3><div class=shot><img src='{escape(phase)}/{escape(entry['file'])}' alt='{escape(entry['file'])} (deleted after the round closed)'>")
        for finding in marked:
            parts.append(f"<a class=mark href='#{escape(finding['id'])}' style='left:{finding['marker']['x']}%;top:{finding['marker']['y']}%'>{escape(finding['id'])}</a>")
        parts.append("</div>")
    if requirements:
        parts.append("<h2>HIG requirements</h2><table><tr><th>Requirement<th>Outcome<th>Detail</tr>")
        for requirement in requirements:
            detail = requirement.get("evidence") or requirement.get("testNeeded") or requirement.get("reason") or ", ".join(requirement.get("findingIds", []))
            parts.append(f"<tr><td>{escape(requirement['id'])}<td>{escape(requirement['outcome'])}<td>{escape(str(detail))}</tr>")
        parts.append("</table>")
    for selection in record.get("fixSelections", []):
        parts.append(f"<p>Fix selection {escape(selection['id'])}: {escape(', '.join(selection['findingIds']))}. {escape(selection['evidence'])}</p>")
    for round_record in record.get("rounds", []):
        after_phase = round_record.get("captures", {}).get("phase", "after")
        parts.append(f"<h2>{escape(round_record['id'])}</h2><p>Executor: {escape(describe_actor(round_record['actors']['executor']))}. Code: {escape(json.dumps(round_record['code']))}.</p>")
        for change in round_record["changes"]:
            parts.append(f"<h3>{escape(change['id'])}: {escape(', '.join(change['findingIds']))} ({escape(change['status'])})</h3><p>{escape(change['outcome'])}</p><ul>")
            parts.extend(f"<li>{escape(item['kind'])}: {escape(item['description'])}</li>" for item in change.get("evidence", []))
            parts.append("</ul>")
            for pair in change.get("pairs", []):
                name = escape(capture_file_name(pair["surface"], pair["appearance"]))
                parts.append(f"<div class=pair><img src='{escape(phase)}/{name}' alt='before {name}'><img src='{escape(after_phase)}/{name}' alt='after {name}'></div>")
    return "\n".join(parts) + "\n"


def load_json(path: Path) -> Any:
    return json.loads(path.read_text())


def main(arguments: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate")
    validate.add_argument("record", type=Path)
    validate.add_argument("--previous", type=Path)
    validate.add_argument("--rubric", type=Path, help="apple-hig-expert config/hig-rubric.json")
    render = commands.add_parser("render")
    render.add_argument("record", type=Path)
    render.add_argument("--output", type=Path)
    commands.add_parser("code-state")
    options = parser.parse_args(arguments)
    try:
        if options.command == "code-state":
            print(json.dumps(current_code_state(), indent=2))
            return 0
        record = load_json(options.record)
        problems = validate_record(record)
        tracked = options.record.resolve().parent.parent == REPOSITORY_ROOT.joinpath(*TRACKED_DIRECTORY)
        if tracked and isinstance(record, dict) and record.get("draft") is True:
            problems.append("a draft record belongs under .crit/, not docs/design-reviews/")
        if not problems and options.command == "validate" and options.rubric:
            problems = check_rubric_coverage(record, load_json(options.rubric))
        if not problems and options.command == "validate" and options.previous:
            previous = load_json(options.previous)
            problems = [f"previous record: {problem}" for problem in validate_record(previous)] or check_append(previous, record)
        for problem in problems:
            print(f"{options.record}: {problem}", file=sys.stderr)
        if problems:
            return 1
        if options.command == "render":
            output = options.output or REPOSITORY_ROOT / ".crit" / record["reviewId"] / "report.html"
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(render_report(record))
            print(output)
        return 0
    except (OSError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"review_record: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
