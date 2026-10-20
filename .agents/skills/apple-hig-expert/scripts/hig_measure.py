#!/usr/bin/env python3
"""Measure contrast and target size for native macOS interfaces against the HIG rubric.

Python 3 standard library only. Results are measurement evidence, not an audit verdict.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Literal, Mapping, Sequence, TypedDict

DEFAULT_RUBRIC_PATH = Path(__file__).resolve().parent.parent / "config" / "hig-rubric.json"
HEX_COLOR = re.compile(r"^#[0-9A-Fa-f]{6}$")
ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
APPEARANCES = ("light", "dark")
SUBJECTS = ("text", "non-text")
EVIDENCE_TYPES = ("measurement", "manual")

Outcome = Literal["pass", "fail", "unknown"]

EXIT_ALL_PASS = 0
EXIT_FAIL_OR_UNKNOWN = 1
EXIT_INPUT_ERROR = 2

BATCH_SCHEMA = """\
batch input schema (measurements.json):

  {
    "context": {
      "platform": "macos",              required; only "macos" is measurable
      "appearance": "light" | "dark",   required
      "input": "pointer"                optional; default "pointer"
    },
    "measurements": [                   required; non-empty list
      {
        "id": "panel-caption-light",    required; unique string
        "kind": "contrast",             "contrast" or "target"
        "element": "Panel: GitHub last-checked caption",   required string
        "evidence": "review/panel-light.png",              required string
        "foreground": "#6E6E73",        contrast: opaque #RRGGBB
        "background": "#FFFFFF",        contrast: opaque #RRGGBB
        "subject": "text",              contrast: "text" (default) or "non-text"
        "text": {"size": 11, "unit": "pt", "weight": 400},
                                        contrast, optional: all three keys; text only
        "context": {"appearance": "dark"},
                                        optional; overrides top-level context keys
        "note": "free text"             optional; copied to the result
      },
      {
        "id": "panel-host-switch",
        "kind": "target",
        "element": "Panel: lend switch for host m4",
        "evidence": "review/panel-light.png",
        "width": 32,                    target: hit region width in pt
        "height": 20                    target: hit region height in pt
      }
    ]
  }

A missing, translucent, or unsupported value, a non-macOS platform, or a
non-pointer input gives result "unknown" with a reason. Unknown is never a pass.
Text without "text" metrics is judged by the stricter normal-text rule.

batch output: {"command", "rubric", "context", "counts", "countsByKind", "results"}.
Each result has id, kind, element, evidence, context, requirementId, ruleId,
threshold, value, result ("pass" | "fail" | "unknown"), source, lastVerified,
and reason when the result is unknown.

exit status: 0 every result passes; 1 any result fails or is unknown;
2 usage, rubric, or input-file error.
"""


class RubricError(ValueError):
    """The rubric file is missing or does not match the expected structure."""


class InputFileError(ValueError):
    """The batch input file is malformed at the file or measurement-identity level."""


@dataclass(frozen=True)
class ContrastRule:
    id: str
    minimum_ratio: float
    source: str
    last_verified: str | None


@dataclass(frozen=True)
class TargetRule:
    id: str
    platform: str
    input: str
    unit: str
    minimum_width: float
    minimum_height: float
    default_width: float
    default_height: float
    source: str
    last_verified: str | None


@dataclass(frozen=True)
class Rubric:
    path: str
    last_verified: str
    text_unit: str
    bold_minimum_weight: float
    large_text_minimum_size: float
    normal_text: ContrastRule
    large_text: ContrastRule
    non_text: ContrastRule
    targets: tuple[TargetRule, ...]
    requirement_by_rule: Mapping[str, str]


@dataclass(frozen=True)
class TextMetrics:
    size: float
    unit: str
    weight: float


class MeasurementContext(TypedDict):
    platform: str
    appearance: str
    input: str


class Counts(TypedDict):
    total: int
    passed: int
    failed: int
    unknown: int


# Rubric loading


def _object(value: object, path: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise RubricError(f"{path} must be an object")
    return value


def _string(container: Mapping[str, object], key: str, path: str) -> str:
    value = container.get(key)
    if not isinstance(value, str) or not value:
        raise RubricError(f"{path}.{key} must be a non-empty string")
    return value


def _positive(container: Mapping[str, object], key: str, path: str) -> float:
    value = container.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
        raise RubricError(f"{path}.{key} must be a positive number")
    return float(value)


def _source(container: Mapping[str, object], path: str) -> str:
    source = _string(container, "source", path)
    if not (source.startswith("https://") or source.startswith("references/")):
        raise RubricError(f"{path}.source must be an https URL or a references/ path")
    return source


def _verification(container: Mapping[str, object], path: str) -> str | None:
    verified = container.get("verified")
    last_verified = container.get("lastVerified")
    if not isinstance(verified, bool):
        raise RubricError(f"{path}.verified must be true or false")
    if verified:
        if not isinstance(last_verified, str) or not ISO_DATE.match(last_verified):
            raise RubricError(f"{path}.lastVerified must be YYYY-MM-DD when verified is true")
        return last_verified
    if last_verified is not None:
        raise RubricError(f"{path}.lastVerified must be null when verified is false")
    return None


def _contrast_rule(value: object, path: str) -> ContrastRule:
    rule = _object(value, path)
    return ContrastRule(
        id=_string(rule, "id", path),
        minimum_ratio=_positive(rule, "minimumRatio", path),
        source=_source(rule, path),
        last_verified=_verification(rule, path),
    )


def _target_rule(value: object, path: str) -> TargetRule:
    rule = _object(value, path)
    return TargetRule(
        id=_string(rule, "id", path),
        platform=_string(rule, "platform", path),
        input=_string(rule, "input", path),
        unit=_string(rule, "unit", path),
        minimum_width=_positive(rule, "minimumWidth", path),
        minimum_height=_positive(rule, "minimumHeight", path),
        default_width=_positive(rule, "defaultWidth", path),
        default_height=_positive(rule, "defaultHeight", path),
        source=_source(rule, path),
        last_verified=_verification(rule, path),
    )


def load_rubric(path: Path = DEFAULT_RUBRIC_PATH) -> Rubric:
    try:
        root = _object(json.loads(path.read_text(encoding="utf-8")), "rubric")
    except FileNotFoundError as error:
        raise RubricError(f"rubric file does not exist: {path}") from error
    except json.JSONDecodeError as error:
        raise RubricError(f"rubric is not valid JSON: {error}") from error

    if root.get("schemaVersion") != 1:
        raise RubricError("rubric.schemaVersion must be 1")
    last_verified = _string(root, "lastVerified", "rubric")
    if not ISO_DATE.match(last_verified):
        raise RubricError("rubric.lastVerified must be YYYY-MM-DD")

    rules = _object(root.get("measurementRules"), "rubric.measurementRules")
    contrast = _object(rules.get("contrast"), "rubric.measurementRules.contrast")
    contrast_path = "rubric.measurementRules.contrast"
    normal_text = _contrast_rule(contrast.get("normalText"), f"{contrast_path}.normalText")
    large_text = _contrast_rule(contrast.get("largeText"), f"{contrast_path}.largeText")
    non_text = _contrast_rule(contrast.get("nonText"), f"{contrast_path}.nonText")

    raw_targets = rules.get("targets")
    if not isinstance(raw_targets, list) or not raw_targets:
        raise RubricError("rubric.measurementRules.targets must be a non-empty list")
    targets = tuple(
        _target_rule(entry, f"rubric.measurementRules.targets[{index}]") for index, entry in enumerate(raw_targets)
    )

    rule_ids = [normal_text.id, large_text.id, non_text.id, *(target.id for target in targets)]
    if len(set(rule_ids)) != len(rule_ids):
        raise RubricError("rubric measurement rule IDs must be unique")

    raw_requirements = root.get("requirements")
    if not isinstance(raw_requirements, list) or not raw_requirements:
        raise RubricError("rubric.requirements must be a non-empty list")
    requirement_ids: set[str] = set()
    requirement_by_rule: dict[str, str] = {}
    for index, entry in enumerate(raw_requirements):
        path_label = f"rubric.requirements[{index}]"
        requirement = _object(entry, path_label)
        requirement_id = _string(requirement, "id", path_label)
        if requirement_id in requirement_ids:
            raise RubricError(f"duplicate requirement ID {requirement_id}")
        requirement_ids.add(requirement_id)
        for key in ("category", "title", "criterion"):
            _string(requirement, key, path_label)
        applicability = _object(requirement.get("applicability"), f"{path_label}.applicability")
        platforms = applicability.get("platforms")
        if not isinstance(platforms, list) or not platforms or not all(isinstance(p, str) for p in platforms):
            raise RubricError(f"{path_label}.applicability.platforms must be a non-empty list of names")
        _source(requirement, path_label)
        _verification(requirement, path_label)
        evidence = requirement.get("evidence")
        if evidence not in EVIDENCE_TYPES:
            raise RubricError(f"{path_label}.evidence must be measurement or manual")
        measurement_rule = requirement.get("measurementRule")
        if evidence == "measurement":
            if not isinstance(measurement_rule, str) or measurement_rule not in rule_ids:
                raise RubricError(f"requirement {requirement_id} must link to a known measurementRule")
            requirement_by_rule[measurement_rule] = requirement_id
        elif measurement_rule is not None:
            raise RubricError(f"requirement {requirement_id} is manual and cannot have a measurementRule")

    missing = [rule_id for rule_id in rule_ids if rule_id not in requirement_by_rule]
    if missing:
        raise RubricError(f"measurement rules without a requirement: {', '.join(missing)}")

    return Rubric(
        path=str(path),
        last_verified=last_verified,
        text_unit=_string(contrast, "textUnit", contrast_path),
        bold_minimum_weight=_positive(contrast, "boldMinimumWeight", contrast_path),
        large_text_minimum_size=_positive(contrast, "largeTextMinimumSize", contrast_path),
        normal_text=normal_text,
        large_text=large_text,
        non_text=non_text,
        targets=targets,
        requirement_by_rule=requirement_by_rule,
    )


# Measurement


def _linearize(channel: float) -> float:
    return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4


def relative_luminance(color: str) -> float:
    if not HEX_COLOR.match(color):
        raise ValueError(f"color must be #RRGGBB: {color}")
    red, green, blue = (int(color[offset : offset + 2], 16) / 255 for offset in (1, 3, 5))
    return 0.2126 * _linearize(red) + 0.7152 * _linearize(green) + 0.0722 * _linearize(blue)


def contrast_ratio(foreground: str, background: str) -> float:
    lighter, darker = sorted((relative_luminance(foreground), relative_luminance(background)), reverse=True)
    return (lighter + 0.05) / (darker + 0.05)


def _round_down(value: float, places: int = 2) -> float:
    """Round toward zero so a displayed ratio never looks better than the measured one."""
    factor = 10**places
    return math.floor(value * factor) / factor


def _unknown(base: dict[str, object], reason: str) -> dict[str, object]:
    return {**base, "result": "unknown", "reason": reason}


def _rule_fields(rubric: Rubric, rule: ContrastRule | TargetRule) -> dict[str, object]:
    return {
        "requirementId": rubric.requirement_by_rule[rule.id],
        "ruleId": rule.id,
        "source": rule.source,
        "lastVerified": rule.last_verified,
    }


def measure_contrast(
    rubric: Rubric,
    foreground: object,
    background: object,
    subject: object,
    text: object,
    context: MeasurementContext,
    base: Mapping[str, object] | None = None,
) -> dict[str, object]:
    result: dict[str, object] = {**(base or {}), "kind": "contrast", "context": dict(context)}
    if context["platform"] != "macos":
        return _unknown(result, f"platform {context['platform']} is outside this rubric (native macOS only)")
    if subject not in SUBJECTS:
        return _unknown(result, "subject must be text or non-text")
    for label, color in (("foreground", foreground), ("background", background)):
        if not isinstance(color, str) or not HEX_COLOR.match(color):
            return _unknown(
                result,
                f"{label} must be an opaque #RRGGBB sample; sample translucent, gradient, or material "
                "backgrounds as the composited color behind the element",
            )
    assert isinstance(foreground, str) and isinstance(background, str)

    text_class: str | None = None
    if subject == "non-text":
        if text is not None:
            return _unknown(result, "non-text contrast cannot include text metrics")
        rule = rubric.non_text
    else:
        if text is None:
            text_class = "normal"
            result["textClassAssumed"] = True
        else:
            metrics = _text_metrics(text)
            if isinstance(metrics, str):
                return _unknown(result, metrics)
            if metrics.unit != rubric.text_unit:
                return _unknown(result, f"text unit {metrics.unit} is unsupported; native macOS text uses pt")
            is_large = metrics.weight >= rubric.bold_minimum_weight or metrics.size >= rubric.large_text_minimum_size
            text_class = "large" if is_large else "normal"
            result["text"] = {"size": metrics.size, "unit": metrics.unit, "weight": metrics.weight}
        rule = rubric.large_text if text_class == "large" else rubric.normal_text

    ratio = contrast_ratio(foreground, background)
    outcome: Outcome = "pass" if ratio >= rule.minimum_ratio else "fail"
    result.update(
        {
            "subject": subject,
            "textClass": text_class,
            **_rule_fields(rubric, rule),
            "threshold": {"minimumRatio": rule.minimum_ratio},
            "value": {"ratio": _round_down(ratio), "foreground": foreground.upper(), "background": background.upper()},
            "result": outcome,
        }
    )
    return result


def _text_metrics(text: object) -> TextMetrics | str:
    if not isinstance(text, dict):
        return "text must be an object with size, unit, and weight"
    size, unit, weight = text.get("size"), text.get("unit"), text.get("weight")
    numbers_valid = all(
        not isinstance(number, bool) and isinstance(number, (int, float)) and math.isfinite(number) and number > 0
        for number in (size, weight)
    )
    if not numbers_valid or not isinstance(unit, str):
        return "text needs a positive size, a unit, and a positive weight"
    assert isinstance(size, (int, float)) and isinstance(weight, (int, float))
    if weight > 1000:
        return "text weight must be at most 1000"
    return TextMetrics(size=float(size), unit=unit, weight=float(weight))


def measure_target(
    rubric: Rubric,
    width: object,
    height: object,
    context: MeasurementContext,
    base: Mapping[str, object] | None = None,
) -> dict[str, object]:
    result: dict[str, object] = {**(base or {}), "kind": "target", "context": dict(context)}
    rule = next(
        (
            target
            for target in rubric.targets
            if target.platform == context["platform"] and target.input == context["input"]
        ),
        None,
    )
    if rule is None:
        return _unknown(
            result,
            f"no target rule for platform {context['platform']} with input {context['input']} "
            "(this rubric covers macOS pointer input only)",
        )
    dimensions = (width, height)
    if not all(
        not isinstance(number, bool) and isinstance(number, (int, float)) and math.isfinite(number) and number > 0
        for number in dimensions
    ):
        return _unknown(result, "width and height must be positive numbers in pt")
    assert isinstance(width, (int, float)) and isinstance(height, (int, float))

    outcome: Outcome = "pass" if width >= rule.minimum_width and height >= rule.minimum_height else "fail"
    result.update(
        {
            **_rule_fields(rubric, rule),
            "threshold": {
                "minimumWidth": rule.minimum_width,
                "minimumHeight": rule.minimum_height,
                "defaultWidth": rule.default_width,
                "defaultHeight": rule.default_height,
                "unit": rule.unit,
            },
            "value": {"width": width, "height": height, "unit": rule.unit},
            "meetsDefaultSize": width >= rule.default_width and height >= rule.default_height,
            "result": outcome,
        }
    )
    return result


# Batch


def _context(value: object, path: str, inherited: MeasurementContext | None = None) -> MeasurementContext:
    if not isinstance(value, dict):
        raise InputFileError(f"{path} must be an object")
    merged: dict[str, object] = {**(inherited or {}), **value}
    merged.setdefault("input", "pointer")
    platform, appearance, input_mode = merged.get("platform"), merged.get("appearance"), merged.get("input")
    if not isinstance(platform, str) or not platform:
        raise InputFileError(f"{path}.platform must be a non-empty string")
    if appearance not in APPEARANCES:
        raise InputFileError(f"{path}.appearance must be light or dark")
    if not isinstance(input_mode, str) or not input_mode:
        raise InputFileError(f"{path}.input must be a non-empty string")
    assert isinstance(appearance, str)
    return {"platform": platform, "appearance": appearance, "input": input_mode}


def _count(results: Sequence[Mapping[str, object]]) -> Counts:
    return {
        "total": len(results),
        "passed": sum(1 for result in results if result["result"] == "pass"),
        "failed": sum(1 for result in results if result["result"] == "fail"),
        "unknown": sum(1 for result in results if result["result"] == "unknown"),
    }


def measure_batch(rubric: Rubric, document: object) -> dict[str, object]:
    if not isinstance(document, dict):
        raise InputFileError("batch input must be a JSON object")
    context = _context(document.get("context"), "context")
    measurements = document.get("measurements")
    if not isinstance(measurements, list) or not measurements:
        raise InputFileError("measurements must be a non-empty list")

    seen_ids: set[str] = set()
    results: list[dict[str, object]] = []
    for index, entry in enumerate(measurements):
        path = f"measurements[{index}]"
        if not isinstance(entry, dict):
            raise InputFileError(f"{path} must be an object")
        base: dict[str, object] = {}
        for key in ("id", "element", "evidence"):
            value = entry.get(key)
            if not isinstance(value, str) or not value:
                raise InputFileError(f"{path}.{key} must be a non-empty string")
            base[key] = value
        if base["id"] in seen_ids:
            raise InputFileError(f"duplicate measurement id {base['id']}")
        seen_ids.add(str(base["id"]))
        if isinstance(entry.get("note"), str):
            base["note"] = entry["note"]
        local_context = context if "context" not in entry else _context(entry["context"], f"{path}.context", context)

        kind = entry.get("kind")
        if kind == "contrast":
            results.append(
                measure_contrast(
                    rubric,
                    entry.get("foreground"),
                    entry.get("background"),
                    entry.get("subject", "text"),
                    entry.get("text"),
                    local_context,
                    base,
                )
            )
        elif kind == "target":
            results.append(measure_target(rubric, entry.get("width"), entry.get("height"), local_context, base))
        else:
            results.append(_unknown({**base, "kind": kind, "context": dict(local_context)}, "kind must be contrast or target"))

    return {
        "command": "batch",
        "rubric": {"path": rubric.path, "lastVerified": rubric.last_verified},
        "context": dict(context),
        "counts": _count(results),
        "countsByKind": {
            kind: _count([result for result in results if result["kind"] == kind]) for kind in ("contrast", "target")
        },
        "results": results,
    }


# Command line


def _build_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--rubric", type=Path, default=DEFAULT_RUBRIC_PATH, help="rubric JSON (default: %(default)s)")

    parser = argparse.ArgumentParser(
        prog="hig_measure.py",
        description="Measure contrast and target size for native macOS UI against config/hig-rubric.json.",
        epilog=BATCH_SCHEMA,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    commands = parser.add_subparsers(dest="command", required=True)

    contrast = commands.add_parser(
        "contrast",
        parents=[common],
        help="contrast ratio of two opaque #RRGGBB colors",
        description="Contrast ratio of two opaque #RRGGBB colors. Text metrics: give all three or none.",
    )
    contrast.add_argument("foreground")
    contrast.add_argument("background")
    contrast.add_argument("--subject", choices=SUBJECTS, default="text")
    contrast.add_argument("--text-size", type=float)
    contrast.add_argument("--text-unit")
    contrast.add_argument("--font-weight", type=float)
    contrast.add_argument("--platform", default="macos")
    contrast.add_argument("--appearance", choices=APPEARANCES, default="light")

    target = commands.add_parser(
        "target",
        parents=[common],
        help="hit region size in pt",
        description="Hit region size in pt. Pass or fail uses the platform minimum control size.",
    )
    target.add_argument("width", type=float)
    target.add_argument("height", type=float)
    target.add_argument("--platform", required=True)
    target.add_argument("--input", default="pointer")
    target.add_argument("--appearance", choices=APPEARANCES, default="light")

    batch = commands.add_parser(
        "batch",
        parents=[common],
        help="measure every entry of a measurements.json file",
        description="Measure every entry of a measurements.json file.",
        epilog=BATCH_SCHEMA,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    batch.add_argument("measurements", type=Path)
    return parser


def _exit_status(results: Sequence[Mapping[str, object]]) -> int:
    return EXIT_ALL_PASS if all(result["result"] == "pass" for result in results) else EXIT_FAIL_OR_UNKNOWN


def main(argv: Sequence[str] | None = None) -> int:
    parser = _build_parser()
    arguments = parser.parse_args(argv)
    try:
        rubric = load_rubric(arguments.rubric)
        if arguments.command == "contrast":
            text_options = (arguments.text_size, arguments.text_unit, arguments.font_weight)
            if any(option is not None for option in text_options) and None in text_options:
                parser.error("--text-size, --text-unit, and --font-weight must be given together")
            text = (
                None
                if arguments.text_size is None
                else {"size": arguments.text_size, "unit": arguments.text_unit, "weight": arguments.font_weight}
            )
            context: MeasurementContext = {
                "platform": arguments.platform,
                "appearance": arguments.appearance,
                "input": "pointer",
            }
            output = measure_contrast(
                rubric, arguments.foreground, arguments.background, arguments.subject, text, context
            )
            results = [output]
        elif arguments.command == "target":
            context = {"platform": arguments.platform, "appearance": arguments.appearance, "input": arguments.input}
            output = measure_target(rubric, arguments.width, arguments.height, context)
            results = [output]
        else:
            try:
                document = json.loads(arguments.measurements.read_text(encoding="utf-8"))
            except FileNotFoundError as error:
                raise InputFileError(f"measurements file does not exist: {arguments.measurements}") from error
            except json.JSONDecodeError as error:
                raise InputFileError(f"measurements file is not valid JSON: {error}") from error
            output = measure_batch(rubric, document)
            batch_results = output["results"]
            assert isinstance(batch_results, list)
            results = batch_results
    except (RubricError, InputFileError) as error:
        print(f"hig_measure.py: {error}", file=sys.stderr)
        return EXIT_INPUT_ERROR

    json.dump(output, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return _exit_status(results)


if __name__ == "__main__":
    sys.exit(main())
