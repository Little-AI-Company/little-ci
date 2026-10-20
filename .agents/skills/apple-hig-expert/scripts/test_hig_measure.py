"""Focused tests for the hig_measure.py contract."""

from __future__ import annotations

import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import hig_measure  # noqa: E402

SCRIPT = Path(__file__).resolve().parent / "hig_measure.py"
MACOS_LIGHT: hig_measure.MeasurementContext = {"platform": "macos", "appearance": "light", "input": "pointer"}


def run_main(arguments: list[str]) -> tuple[int, str]:
    output = io.StringIO()
    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
        status = hig_measure.main(arguments)
    return status, output.getvalue()


class ContrastTests(unittest.TestCase):
    rubric = hig_measure.load_rubric()

    def measure(self, foreground: str, background: str, subject: str = "text", text: object = None) -> dict[str, object]:
        return hig_measure.measure_contrast(self.rubric, foreground, background, subject, text, MACOS_LIGHT)

    def test_ratio_matches_known_values(self) -> None:
        self.assertAlmostEqual(hig_measure.contrast_ratio("#000000", "#FFFFFF"), 21.0, places=6)
        self.assertAlmostEqual(hig_measure.contrast_ratio("#777777", "#777777"), 1.0, places=6)
        self.assertAlmostEqual(hig_measure.contrast_ratio("#FFFFFF", "#767676"), 4.54, places=2)

    def test_normal_text_fails_just_below_four_and_a_half(self) -> None:
        result = self.measure("#777777", "#FFFFFF", text={"size": 13, "unit": "pt", "weight": 400})
        self.assertEqual(result["ruleId"], "apple-contrast-text-normal")
        self.assertEqual(result["requirementId"], "accessibility.contrast.text")
        self.assertEqual(result["result"], "fail")
        self.assertEqual(result["value"], {"ratio": 4.47, "foreground": "#777777", "background": "#FFFFFF"})

    def test_large_and_bold_text_use_three_to_one(self) -> None:
        large = self.measure("#777777", "#FFFFFF", text={"size": 18, "unit": "pt", "weight": 400})
        bold = self.measure("#777777", "#FFFFFF", text={"size": 11, "unit": "pt", "weight": 700})
        semibold = self.measure("#777777", "#FFFFFF", text={"size": 17, "unit": "pt", "weight": 600})
        self.assertEqual((large["textClass"], large["result"]), ("large", "pass"))
        self.assertEqual((bold["ruleId"], bold["result"]), ("apple-contrast-text-large", "pass"))
        self.assertEqual((semibold["textClass"], semibold["result"]), ("normal", "fail"))

    def test_text_without_metrics_uses_the_stricter_rule(self) -> None:
        result = self.measure("#777777", "#FFFFFF")
        self.assertEqual((result["ruleId"], result["textClassAssumed"]), ("apple-contrast-text-normal", True))

    def test_non_text_uses_wcag_non_text_rule(self) -> None:
        result = self.measure("#949494", "#FFFFFF", subject="non-text")
        self.assertEqual((result["ruleId"], result["result"]), ("wcag-1.4.11-non-text", "pass"))


class TargetTests(unittest.TestCase):
    rubric = hig_measure.load_rubric()

    def measure(self, width: object, height: object, **context: str) -> dict[str, object]:
        return hig_measure.measure_target(self.rubric, width, height, {**MACOS_LIGHT, **context})

    def test_macos_minimum_and_default_sizes(self) -> None:
        at_minimum = self.measure(20, 20)
        below = self.measure(19.5, 30)
        at_default = self.measure(28, 28)
        self.assertEqual((at_minimum["result"], at_minimum["meetsDefaultSize"]), ("pass", False))
        self.assertEqual(below["result"], "fail")
        self.assertEqual((at_default["result"], at_default["meetsDefaultSize"]), ("pass", True))
        self.assertEqual(at_default["ruleId"], "apple-target-macos")

    def test_other_platforms_and_inputs_are_unknown(self) -> None:
        self.assertEqual(self.measure(44, 44, platform="ios")["result"], "unknown")
        self.assertEqual(self.measure(44, 44, input="touch")["result"], "unknown")


class BatchTests(unittest.TestCase):
    rubric = hig_measure.load_rubric()

    def write_batch(self, document: object) -> Path:
        directory = Path(tempfile.mkdtemp())
        path = directory / "measurements.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        self.addCleanup(lambda: (path.unlink(), directory.rmdir()))
        return path

    def entry(self, identifier: str, kind: str, **values: object) -> dict[str, object]:
        return {"id": identifier, "kind": kind, "element": f"element {identifier}", "evidence": "shot.png", **values}

    def test_batch_counts_and_preserves_identity(self) -> None:
        path = self.write_batch(
            {
                "context": {"platform": "macos", "appearance": "light"},
                "measurements": [
                    self.entry("label", "contrast", foreground="#000000", background="#FFFFFF"),
                    self.entry("caption", "contrast", foreground="#999999", background="#FFFFFF",
                               text={"size": 11, "unit": "pt", "weight": 400}),
                    self.entry("switch", "target", width=32, height=20, context={"appearance": "dark"}),
                    self.entry("glass", "contrast", foreground="#FFFFFF", background="#FFFFFF80"),
                ],
            }
        )
        status, stdout = run_main(["batch", str(path)])
        report = json.loads(stdout)
        self.assertEqual(status, hig_measure.EXIT_FAIL_OR_UNKNOWN)
        self.assertEqual(report["counts"], {"total": 4, "passed": 2, "failed": 1, "unknown": 1})
        self.assertEqual(report["countsByKind"]["target"], {"total": 1, "passed": 1, "failed": 0, "unknown": 0})
        by_id = {result["id"]: result for result in report["results"]}
        self.assertEqual(by_id["caption"]["evidence"], "shot.png")
        self.assertEqual(by_id["switch"]["context"]["appearance"], "dark")
        self.assertEqual(by_id["glass"]["result"], "unknown")
        self.assertIn("opaque", by_id["glass"]["reason"])

    def test_unsupported_or_incomplete_measurements_are_never_pass(self) -> None:
        document = {
            "context": {"platform": "macos", "appearance": "dark"},
            "measurements": [
                self.entry("no-colors", "contrast"),
                self.entry("px-text", "contrast", foreground="#000000", background="#FFFFFF",
                           text={"size": 30, "unit": "px", "weight": 400}),
                self.entry("no-size", "target"),
                self.entry("focus-ring", "keyboard-focus"),
                self.entry("ios", "target", width=44, height=44, context={"platform": "ios"}),
            ],
        }
        report = hig_measure.measure_batch(self.rubric, document)
        self.assertEqual([result["result"] for result in report["results"]], ["unknown"] * 5)

    def test_all_pass_exits_zero(self) -> None:
        path = self.write_batch(
            {
                "context": {"platform": "macos", "appearance": "light"},
                "measurements": [self.entry("button", "target", width=28, height=28)],
            }
        )
        self.assertEqual(run_main(["batch", str(path)])[0], hig_measure.EXIT_ALL_PASS)

    def test_malformed_file_is_an_input_error(self) -> None:
        duplicate = self.entry("same", "target", width=28, height=28)
        cases = [
            {"context": {"platform": "macos", "appearance": "light"}, "measurements": [duplicate, duplicate]},
            {"context": {"platform": "macos", "appearance": "sepia"}, "measurements": [duplicate]},
            {"context": {"platform": "macos", "appearance": "light"}, "measurements": [{"id": "x", "kind": "target"}]},
            {"context": {"platform": "macos", "appearance": "light"}, "measurements": []},
        ]
        for document in cases:
            with self.subTest(document=document):
                self.assertEqual(run_main(["batch", str(self.write_batch(document))])[0], hig_measure.EXIT_INPUT_ERROR)


class RubricTests(unittest.TestCase):
    def rubric_document(self) -> dict[str, object]:
        return json.loads(hig_measure.DEFAULT_RUBRIC_PATH.read_text(encoding="utf-8"))

    def load_modified(self, document: dict[str, object]) -> hig_measure.Rubric:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rubric.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            return hig_measure.load_rubric(path)

    def test_packaged_rubric_links_every_measurement_rule(self) -> None:
        rubric = hig_measure.load_rubric()
        self.assertEqual(
            dict(rubric.requirement_by_rule),
            {
                "apple-contrast-text-normal": "accessibility.contrast.text",
                "apple-contrast-text-large": "accessibility.contrast.large-text",
                "wcag-1.4.11-non-text": "accessibility.contrast.non-text",
                "apple-target-macos": "accessibility.target.macos",
            },
        )

    def test_invalid_rubrics_are_rejected(self) -> None:
        duplicate = self.rubric_document()
        requirements = duplicate["requirements"]
        assert isinstance(requirements, list)
        requirements.append(requirements[0])

        unknown_rule = self.rubric_document()
        unknown_requirements = unknown_rule["requirements"]
        assert isinstance(unknown_requirements, list)
        measured = next(item for item in unknown_requirements if item["evidence"] == "measurement")
        measured["measurementRule"] = "no-such-rule"

        false_verification = self.rubric_document()
        false_requirements = false_verification["requirements"]
        assert isinstance(false_requirements, list)
        false_requirements[0]["verified"] = False

        for document in (duplicate, unknown_rule, false_verification):
            with self.assertRaises(hig_measure.RubricError):
                self.load_modified(document)

    def test_unverified_rule_with_null_date_loads(self) -> None:
        document = self.rubric_document()
        requirements = document["requirements"]
        assert isinstance(requirements, list)
        requirements[0]["verified"] = False
        requirements[0]["lastVerified"] = None
        self.load_modified(document)


class CommandLineTests(unittest.TestCase):
    def test_help_documents_batch_schema(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), "--help"], capture_output=True, text=True, check=True
        )
        self.assertIn('"measurements": [', completed.stdout)
        self.assertIn("Unknown is never a pass", completed.stdout)

    def test_contrast_text_options_must_be_complete(self) -> None:
        with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(io.StringIO()):
            hig_measure.main(["contrast", "#000000", "#FFFFFF", "--text-size", "13"])
        self.assertEqual(raised.exception.code, 2)

    def test_contrast_command_reports_result(self) -> None:
        status, stdout = run_main(
            ["contrast", "#000000", "#FFFFFF", "--text-size", "13", "--text-unit", "pt", "--font-weight", "400"]
        )
        self.assertEqual((status, json.loads(stdout)["result"]), (0, "pass"))


if __name__ == "__main__":
    unittest.main()
