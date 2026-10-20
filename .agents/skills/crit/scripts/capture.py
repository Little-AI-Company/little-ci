#!/usr/bin/env python3
"""Capture the Little CI menu bar app's windows as review evidence.

  capture.py capture <review-id> <phase> [--surfaces panel,overview,...] [--appearances light,dark] [--live]
  capture.py validate <capture.json>

`capture` launches app/build/Little CI.app (building it first when it is missing)
once per pane and appearance, captures each window with `screencapture -x -o -l`,
quits that instance, and writes PNGs plus capture.json under
.crit/<review-id>/<phase>/. The default is the demo fleet in a temporary
LITTLE_CI_HOME whose inventory has no hosts, so captures hold no private host
or repository names and the background monitor reads only the example GitHub
target. `--live` uses your real inventory; its captures may contain private
names.

The terminal needs Screen Recording permission. Any missing window, unreadable
title, or failed capture stops the run with exit status 1 and no capture.json.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

from png_colors import PNGFormatError, read_png_size

REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
APP_BUNDLE = REPOSITORY_ROOT / "app" / "build" / "Little CI.app"
APP_EXECUTABLE = APP_BUNDLE / "Contents" / "MacOS" / "LittleCI"
BUILD_SCRIPT = REPOSITORY_ROOT / "app" / "scripts" / "build-app.sh"
EXAMPLE_INVENTORY = REPOSITORY_ROOT / "app" / "inventory.example.json"
WINDOW_LISTER_SOURCE = Path(__file__).resolve().parent / "list-windows.swift"

MANIFEST_VERSION = 1
PANES = ("overview", "hosts", "runners", "queue", "events")
SURFACES = ("panel", *PANES)
APPEARANCES = ("light", "dark")
WINDOW_TITLES = {"panel": "Little CI panel", **{pane: "Little CI" for pane in PANES}}
REVIEW_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
PHASE_PATTERN = re.compile(r"^(before|after(-[1-9][0-9]*)?)$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


class CaptureError(RuntimeError):
    pass


def capture_file_name(surface: str, appearance: str) -> str:
    return f"{surface}-{appearance}.png"


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_choices(text: str, allowed: tuple[str, ...], label: str) -> list[str]:
    values = [value.strip() for value in text.split(",") if value.strip()]
    unknown = [value for value in values if value not in allowed]
    if not values or unknown or len(set(values)) != len(values):
        raise argparse.ArgumentTypeError(f"{label} must be distinct values from {', '.join(allowed)}; got {text!r}")
    return [value for value in allowed if value in values]


def validate_manifest(manifest: Any, directory: Path | None = None) -> list[str]:
    """Return every problem with a capture manifest. With `directory`, also check the files."""
    if not isinstance(manifest, dict):
        return ["manifest must be a JSON object"]
    problems: list[str] = []
    if manifest.get("version") != MANIFEST_VERSION:
        problems.append(f"version must be {MANIFEST_VERSION}")
    if not REVIEW_ID_PATTERN.match(str(manifest.get("reviewId", ""))):
        problems.append("reviewId must be lowercase letters, digits and hyphens")
    if not PHASE_PATTERN.match(str(manifest.get("phase", ""))):
        problems.append("phase must be before, after, or after-<n>")
    if manifest.get("data") not in ("demo", "live"):
        problems.append("data must be demo or live")
    app = manifest.get("app")
    if not isinstance(app, dict) or not SHA256_PATTERN.match(str(app.get("executableSha256", ""))):
        problems.append("app.executableSha256 must be a SHA-256 digest")
    requested = manifest.get("requested")
    if not isinstance(requested, dict):
        return [*problems, "requested must be an object with surfaces and appearances"]
    surfaces, appearances = requested.get("surfaces"), requested.get("appearances")
    for label, values, allowed in (("surfaces", surfaces, SURFACES), ("appearances", appearances, APPEARANCES)):
        if not isinstance(values, list) or not values or len(set(values)) != len(values) or any(v not in allowed for v in values):
            problems.append(f"requested.{label} must be distinct values from {', '.join(allowed)}")
    captures = manifest.get("captures")
    if not isinstance(captures, list):
        return [*problems, "captures must be a list"]
    if problems:
        return problems
    expected = {(surface, appearance) for surface in surfaces for appearance in appearances}
    seen: set[tuple[str, str]] = set()
    for index, capture in enumerate(captures):
        label = f"captures[{index}]"
        if not isinstance(capture, dict):
            problems.append(f"{label} must be an object")
            continue
        key = (capture.get("surface"), capture.get("appearance"))
        if key not in expected:
            problems.append(f"{label} is {key[0]}/{key[1]}, which was not requested")
            continue
        if key in seen:
            problems.append(f"{label} repeats {key[0]}/{key[1]}")
            continue
        seen.add(key)
        surface, appearance = key
        if capture.get("windowTitle") != WINDOW_TITLES[surface]:
            problems.append(f"{label} window title must be {WINDOW_TITLES[surface]!r}")
        if capture.get("file") != capture_file_name(surface, appearance):
            problems.append(f"{label} file must be {capture_file_name(surface, appearance)}")
        for field in ("pixelWidth", "pixelHeight", "pointWidth", "pointHeight"):
            value = capture.get(field)
            if not isinstance(value, (int, float)) or isinstance(value, bool) or value <= 0:
                problems.append(f"{label}.{field} must be a positive number")
        if not SHA256_PATTERN.match(str(capture.get("sha256", ""))):
            problems.append(f"{label}.sha256 must be a SHA-256 digest")
        elif directory is not None:
            problems.extend(check_capture_file(capture, directory, label))
    for surface, appearance in sorted(expected - seen):
        problems.append(f"missing capture for {surface}/{appearance}")
    return problems


def check_capture_file(capture: dict[str, Any], directory: Path, label: str) -> list[str]:
    path = directory / str(capture["file"])
    if path.is_symlink() or not path.is_file():
        return [f"{label}: {path.name} is not a regular file"]
    if sha256_of(path) != capture["sha256"]:
        return [f"{label}: {path.name} does not match its SHA-256"]
    try:
        size = read_png_size(path)
    except PNGFormatError as error:
        return [f"{label}: {error}"]
    if size != (capture["pixelWidth"], capture["pixelHeight"]):
        return [f"{label}: {path.name} is {size[0]}x{size[1]}, not the recorded size"]
    return []


# GUI side: everything below needs a logged-in macOS session.


def run_checked(command: list[str], label: str, **options: Any) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, capture_output=True, text=True, **options)
    if result.returncode != 0:
        raise CaptureError(f"{label} failed with status {result.returncode}: {result.stderr.strip()}")
    return result


def ensure_app_bundle() -> None:
    if APP_EXECUTABLE.is_file():
        return
    print(f"building {APP_BUNDLE.relative_to(REPOSITORY_ROOT)}", file=sys.stderr)
    run_checked([str(BUILD_SCRIPT)], "app/scripts/build-app.sh")
    if not APP_EXECUTABLE.is_file():
        raise CaptureError(f"the build did not produce {APP_EXECUTABLE}")


def compile_window_lister(work_directory: Path) -> Path:
    lister = work_directory / "list-windows"
    run_checked(["swiftc", "-O", str(WINDOW_LISTER_SOURCE), "-o", str(lister)], "swiftc list-windows.swift")
    return lister


def prepare_demo_home(work_directory: Path) -> Path:
    """A LITTLE_CI_HOME whose inventory names the example GitHub target and no hosts, so the
    background monitor contacts no host and the real event journal stays untouched."""
    home = work_directory / "home"
    home.mkdir()
    inventory = json.loads(EXAMPLE_INVENTORY.read_text())
    inventory["hosts"] = []
    (home / "inventory.json").write_text(json.dumps(inventory, indent=2))
    return home


def unused_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def list_windows(lister: Path, pid: int) -> list[dict[str, Any]]:
    result = run_checked([str(lister), str(pid)], "list-windows")
    windows = json.loads(result.stdout)
    return [window for window in windows if window["layer"] == 0 and window["width"] > 0 and window["height"] > 0]


def wait_for_windows(lister: Path, process: subprocess.Popen[bytes], titles: set[str], timeout: float) -> dict[str, dict[str, Any]]:
    deadline = time.monotonic() + timeout
    windows: list[dict[str, Any]] = []
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise CaptureError(f"the app exited with status {process.returncode} before its windows appeared")
        windows = list_windows(lister, process.pid)
        by_title: dict[str, list[dict[str, Any]]] = {}
        for window in windows:
            by_title.setdefault(window["title"], []).append(window)
        if titles <= by_title.keys():
            ambiguous = [title for title in titles if len(by_title[title]) > 1]
            if ambiguous:
                raise CaptureError(f"more than one window titled {ambiguous[0]!r}")
            return {title: by_title[title][0] for title in titles}
        time.sleep(0.25)
    if windows and all(window["title"] == "" for window in windows):
        raise CaptureError("window titles are unreadable: grant this terminal Screen Recording permission")
    found = sorted({window["title"] for window in windows})
    raise CaptureError(f"timed out waiting for windows {sorted(titles)}; found {found}")


def stop_app(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)


def capture_launch(
    lister: Path,
    environment: dict[str, str],
    output: Path,
    appearance: str,
    pane: str | None,
    includes_panel: bool,
    options: argparse.Namespace,
) -> list[dict[str, Any]]:
    arguments = [str(APP_EXECUTABLE), "--appearance", appearance]
    if not options.live:
        arguments.append("--demo")
    surfaces: list[str] = []
    if pane is not None:
        arguments += ["--show-details", "--pane", pane]
        surfaces.append(pane)
    if includes_panel:
        arguments.append("--show-panel")
        surfaces.append("panel")
    process = subprocess.Popen(arguments, env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_for_windows(lister, process, {WINDOW_TITLES[surface] for surface in surfaces}, options.timeout)
        time.sleep(options.settle)
        windows = wait_for_windows(lister, process, {WINDOW_TITLES[surface] for surface in surfaces}, options.timeout)
        records = []
        for surface in surfaces:
            window = windows[WINDOW_TITLES[surface]]
            path = output / capture_file_name(surface, appearance)
            run_checked(["screencapture", "-x", "-o", "-l", str(window["id"]), str(path)], f"screencapture {path.name}")
            if not path.is_file() or path.stat().st_size == 0:
                raise CaptureError(f"screencapture wrote no image for {surface}/{appearance}")
            width, height = read_png_size(path)
            records.append(
                {
                    "surface": surface,
                    "appearance": appearance,
                    "windowTitle": window["title"],
                    "file": path.name,
                    "pixelWidth": width,
                    "pixelHeight": height,
                    "pointWidth": window["width"],
                    "pointHeight": window["height"],
                    "scale": round(width / window["width"], 3),
                    "sha256": sha256_of(path),
                }
            )
            print(f"captured {path.relative_to(REPOSITORY_ROOT)} ({width}x{height})", file=sys.stderr)
        return records
    finally:
        stop_app(process)


def run_capture(options: argparse.Namespace) -> int:
    if not REVIEW_ID_PATTERN.match(options.review_id):
        raise CaptureError("review id must be lowercase letters, digits and hyphens")
    if not PHASE_PATTERN.match(options.phase):
        raise CaptureError("phase must be before, after, or after-<n>")
    output = REPOSITORY_ROOT / ".crit" / options.review_id / options.phase
    if output.exists() and any(output.iterdir()):
        raise CaptureError(f"{output.relative_to(REPOSITORY_ROOT)} already has files; delete it or use another phase")
    ensure_app_bundle()
    output.mkdir(parents=True, exist_ok=True)
    panes = [surface for surface in options.surfaces if surface in PANES]
    with tempfile.TemporaryDirectory(prefix="little-ci-crit-") as work:
        work_directory = Path(work)
        lister = compile_window_lister(work_directory)
        environment = dict(os.environ, LITTLE_CI_API_PORT=str(unused_loopback_port()))
        if not options.live:
            environment["LITTLE_CI_HOME"] = str(prepare_demo_home(work_directory))
        captures: list[dict[str, Any]] = []
        try:
            for appearance in options.appearances:
                launches: list[str | None] = list(panes) or [None]
                for index, pane in enumerate(launches):
                    includes_panel = "panel" in options.surfaces and index == 0
                    captures += capture_launch(lister, environment, output, appearance, pane, includes_panel, options)
        except BaseException:
            for path in output.glob("*.png"):
                path.unlink()
            raise
    manifest = {
        "version": MANIFEST_VERSION,
        "reviewId": options.review_id,
        "phase": options.phase,
        "capturedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "data": "live" if options.live else "demo",
        "app": {"bundle": str(APP_BUNDLE.relative_to(REPOSITORY_ROOT)), "executableSha256": sha256_of(APP_EXECUTABLE)},
        "requested": {"surfaces": options.surfaces, "appearances": options.appearances},
        "captures": captures,
    }
    problems = validate_manifest(manifest, output)
    if problems:
        raise CaptureError("incomplete capture: " + "; ".join(problems))
    manifest_path = output / "capture.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"{manifest_path.relative_to(REPOSITORY_ROOT)} sha256 {sha256_of(manifest_path)}")
    return 0


def run_validate(options: argparse.Namespace) -> int:
    path: Path = options.manifest
    problems = validate_manifest(json.loads(path.read_text()), path.parent)
    for problem in problems:
        print(f"{path}: {problem}", file=sys.stderr)
    return 1 if problems else 0


def main(arguments: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    capture = commands.add_parser("capture", help="launch the app and capture its windows")
    capture.add_argument("review_id")
    capture.add_argument("phase", help="before, after, or after-<n>")
    capture.add_argument("--surfaces", type=lambda text: parse_choices(text, SURFACES, "surfaces"), default=list(SURFACES))
    capture.add_argument("--appearances", type=lambda text: parse_choices(text, APPEARANCES, "appearances"), default=list(APPEARANCES))
    capture.add_argument("--live", action="store_true", help="use the real inventory instead of the demo fleet")
    capture.add_argument("--settle", type=float, default=2.0, help="seconds to wait after the windows appear")
    capture.add_argument("--timeout", type=float, default=30.0, help="seconds to wait for the windows")
    validate = commands.add_parser("validate", help="check a capture.json and its files")
    validate.add_argument("manifest", type=Path)
    options = parser.parse_args(arguments)
    try:
        return run_capture(options) if options.command == "capture" else run_validate(options)
    except (CaptureError, OSError, PNGFormatError, json.JSONDecodeError) as error:
        print(f"capture: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
