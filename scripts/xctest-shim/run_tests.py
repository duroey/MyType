#!/usr/bin/env python3
"""Build and run the XCTest suite on a machine that has no Xcode.

The Command Line Tools ship neither XCTest nor the SwiftUI macro plugins the
newest SDK needs, so `swift test` cannot work there. This script builds the
XCTest shim in this directory as a framework, builds the test bundle against
it with SwiftPM, and runs every test class in its own process.

Usage:
    python3 scripts/xctest-shim/run_tests.py                  # whole suite
    python3 scripts/xctest-shim/run_tests.py FooTests BarTests
    python3 scripts/xctest-shim/run_tests.py --list
    python3 scripts/xctest-shim/run_tests.py --skip-build FooTests

Tests run against the app's isolated test profile
(`~/Library/Application Support/Type4MeTests`) and file-backed credentials,
never the user's data or keychain. With Xcode installed, use `swift test`.
"""
from __future__ import annotations

import argparse
import os
import platform
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

SHIM_DIR = Path(__file__).resolve().parent
REPO_ROOT = SHIM_DIR.parent.parent
WORK_DIR = REPO_ROOT / ".build" / "xctest-shim"
TESTS_DIR = REPO_ROOT / "Type4MeTests"
TEST_BUNDLE_NAME = "Type4MeTests.xctest"

# Matches `platforms: [.macOS(.v14)]` in Package.swift.
DEPLOYMENT_TARGET = "14.0"
# Matches `.swiftLanguageMode(.v5)` in Package.swift.
SWIFT_LANGUAGE_VERSION = "5"
# Newest SDK whose SwiftUI property wrappers are not macros. Later SDKs need the
# SwiftUIMacros compiler plugin, which only ships with Xcode.
FALLBACK_SDK_NAME = "MacOSX26.sdk"
DEFAULT_CLASS_TIMEOUT_SECONDS = 150
# The app detects a test run from this process name.
HOST_EXECUTABLE_NAME = "xctest"

TEST_DECLARATION = re.compile(
    r"class\s+(?P<cls>\w+)\s*:\s*XCTestCase|func\s+(?P<name>test\w*)\s*\(\s*\)\s*(?P<quals>[^{]*)\{"
)


@dataclass(frozen=True)
class Toolchain:
    """Locations derived from the active developer directory."""

    developer_dir: Path
    sdk: Path | None

    @property
    def testing_plugin_dir(self) -> Path:
        return self.developer_dir / "usr/lib/swift/host/plugins/testing"

    @property
    def developer_frameworks(self) -> Path:
        return self.developer_dir / "Library/Developer/Frameworks"

    @property
    def developer_libraries(self) -> Path:
        return self.developer_dir / "Library/Developer/usr/lib"


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Parses command-line arguments.

    Args:
        argv: Arguments without the program name.

    Returns:
        The parsed namespace.
    """
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("classes", nargs="*", help="Test class names to run (default: all).")
    parser.add_argument("--list", action="store_true", help="Print the discovered test classes and exit.")
    parser.add_argument("--skip-build", action="store_true", help="Reuse the previously built shim and test bundle.")
    parser.add_argument(
        "--sdk",
        type=Path,
        default=None,
        help=f"SDK to build against (default: $SDKROOT, else {FALLBACK_SDK_NAME} of the active developer dir).",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_CLASS_TIMEOUT_SECONDS,
        help="Seconds allowed per test class before it is killed (default: %(default)s).",
    )
    return parser.parse_args(argv)


def resolve_toolchain(sdk_override: Path | None) -> Toolchain:
    """Finds the developer directory and the SDK to build against.

    Args:
        sdk_override: SDK path given on the command line, if any.

    Returns:
        The resolved toolchain locations.

    Raises:
        SystemExit: If the developer directory or an explicit SDK is missing.
    """
    result = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise SystemExit(f"xcode-select -p failed: {result.stderr.strip()}")
    developer_dir = Path(result.stdout.strip())

    if sdk_override is not None:
        if not sdk_override.is_dir():
            raise SystemExit(f"SDK not found: {sdk_override}")
        return Toolchain(developer_dir, sdk_override)
    if os.environ.get("SDKROOT"):
        return Toolchain(developer_dir, Path(os.environ["SDKROOT"]))
    fallback = developer_dir / "SDKs" / FALLBACK_SDK_NAME
    # Without the fallback SDK, leave SDK selection to the toolchain's default.
    return Toolchain(developer_dir, fallback if fallback.is_dir() else None)


def build_environment(toolchain: Toolchain) -> dict[str, str]:
    """Returns the environment for compiler invocations.

    Args:
        toolchain: Resolved toolchain locations.

    Returns:
        A copy of the current environment with `SDKROOT` set when known.
    """
    env = dict(os.environ)
    if toolchain.sdk is not None:
        env["SDKROOT"] = str(toolchain.sdk)
    return env


def run_checked(command: list[str], env: dict[str, str], what: str) -> None:
    """Runs a build step and stops with its output when it fails.

    Args:
        command: Command and arguments.
        env: Environment for the command.
        what: Short description used in messages.

    Raises:
        SystemExit: If the command exits with a non-zero status.
    """
    print(f"==> {what}", flush=True)
    result = subprocess.run(command, cwd=REPO_ROOT, env=env, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        output = (result.stdout + result.stderr).strip()
        errors = [line for line in output.splitlines() if "error" in line.lower()]
        tail = "\n".join(errors[:40] or output.splitlines()[-40:])
        raise SystemExit(f"{what} failed (exit {result.returncode}):\n{tail}")


def build_shim(toolchain: Toolchain, env: dict[str, str]) -> Path:
    """Builds the XCTest shim framework and the host executable.

    Args:
        toolchain: Resolved toolchain locations.
        env: Environment for compiler invocations.

    Returns:
        The directory that contains `XCTest.framework`.
    """
    frameworks = WORK_DIR / "fw"
    module_dir = frameworks / "XCTest.framework" / "Modules" / "XCTest.swiftmodule"
    module_dir.mkdir(parents=True, exist_ok=True)
    arch = platform.machine()
    target = f"{arch}-apple-macosx{DEPLOYMENT_TARGET}"
    common = ["swiftc", "-swift-version", SWIFT_LANGUAGE_VERSION, "-target", target]

    run_checked(
        common
        + [
            "-emit-library",
            "-emit-module",
            "-module-name",
            "XCTest",
            "-parse-as-library",
            str(SHIM_DIR / "XCTest.swift"),
            "-o",
            str(frameworks / "XCTest.framework" / "XCTest"),
            "-emit-module-path",
            str(module_dir / f"{arch}-apple-macos.swiftmodule"),
            "-Xlinker",
            "-install_name",
            "-Xlinker",
            "@rpath/XCTest.framework/XCTest",
        ],
        env,
        "Building XCTest shim framework",
    )
    run_checked(
        common
        + [
            "-F",
            str(frameworks),
            "-Xlinker",
            "-rpath",
            "-Xlinker",
            str(frameworks),
            str(SHIM_DIR / "main.swift"),
            "-o",
            str(WORK_DIR / HOST_EXECUTABLE_NAME),
        ],
        env,
        "Building test host",
    )
    return frameworks


def build_test_bundle(toolchain: Toolchain, env: dict[str, str], frameworks: Path) -> None:
    """Builds the SwiftPM test bundle against the shim.

    Args:
        toolchain: Resolved toolchain locations.
        env: Environment for compiler invocations.
        frameworks: Directory that contains the shim framework.
    """
    command = ["swift", "build", "--build-tests", "-Xswiftc", f"-F{frameworks}"]
    if toolchain.testing_plugin_dir.is_dir():
        # SwiftPM does not add the Swift Testing macro plugin on its own here.
        command += ["-Xswiftc", "-plugin-path", "-Xswiftc", str(toolchain.testing_plugin_dir)]
    command += ["-Xlinker", f"-F{frameworks}", "-Xlinker", "-rpath", "-Xlinker", str(frameworks)]
    run_checked(command, env, "Building test bundle")


def find_test_bundle() -> Path:
    """Locates the most recently built test bundle.

    Returns:
        Path to the `.xctest` bundle.

    Raises:
        SystemExit: If no bundle has been built.
    """
    candidates = [
        path
        for path in (REPO_ROOT / ".build").glob(f"**/{TEST_BUNDLE_NAME}")
        if (path / "Contents" / "MacOS").is_dir()
    ]
    if not candidates:
        raise SystemExit(f"{TEST_BUNDLE_NAME} not found under .build; run without --skip-build.")
    return max(candidates, key=lambda path: path.stat().st_mtime)


def write_async_throws_list() -> Path:
    """Records which tests are `async throws`.

    The Objective-C runtime exposes `async` and `async throws` tests with the
    same selector shape, but their completion handlers differ, so the runner
    needs this list to call each one correctly.

    Returns:
        Path to the generated list, one `Class.method` per line.
    """
    names: set[str] = set()
    for source in sorted(TESTS_DIR.rglob("*.swift")):
        current_class: str | None = None
        for match in TEST_DECLARATION.finditer(source.read_text(encoding="utf-8")):
            if match.group("cls"):
                current_class = match.group("cls")
            elif current_class:
                qualifiers = match.group("quals")
                if "async" in qualifiers and "throws" in qualifiers:
                    names.add(f"{current_class}.{match.group('name')}")
    destination = WORK_DIR / "async_throws.txt"
    destination.write_text("\n".join(sorted(names)) + "\n", encoding="utf-8")
    return destination


def host_environment(toolchain: Toolchain, frameworks: Path) -> dict[str, str]:
    """Returns the environment for running the test host.

    Args:
        toolchain: Resolved toolchain locations.
        frameworks: Directory that contains the shim framework.

    Returns:
        Environment with the loader paths the test bundle depends on.
    """
    env = dict(os.environ)
    env["DYLD_FRAMEWORK_PATH"] = f"{toolchain.developer_frameworks}:{frameworks}"
    env["DYLD_LIBRARY_PATH"] = str(toolchain.developer_libraries)
    return env


def list_classes(host: Path, bundle: Path, async_list: Path, env: dict[str, str]) -> list[str]:
    """Asks the host for every test class in the bundle.

    Args:
        host: Test host executable.
        bundle: Test bundle to load.
        async_list: Generated `async throws` list.
        env: Environment for the host.

    Returns:
        Test class names in run order.

    Raises:
        SystemExit: If the bundle cannot be loaded.
    """
    result = subprocess.run(
        [str(host), str(bundle), str(async_list), "--list"],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(f"Listing test classes failed (exit {result.returncode}):\n{result.stderr.strip()}")
    return result.stdout.split()


def run_class(
    name: str, host: Path, bundle: Path, async_list: Path, env: dict[str, str], timeout: int, log_dir: Path
) -> tuple[str, int, int, int]:
    """Runs one test class in its own process.

    A separate process per class keeps a crash or hang from taking the rest of
    the suite down with it.

    Args:
        name: Test class name.
        host: Test host executable.
        bundle: Test bundle to load.
        async_list: Generated `async throws` list.
        env: Environment for the host.
        timeout: Seconds allowed before the class is killed.
        log_dir: Directory that receives the class log.

    Returns:
        A tuple of status label, passed count, failed count and skipped count.
    """
    class_env = dict(env)
    class_env["XCT_FILTER"] = name
    try:
        result = subprocess.run(
            [str(host), str(bundle), str(async_list)],
            cwd=REPO_ROOT,
            env=class_env,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        output, code = result.stdout + result.stderr, result.returncode
    except subprocess.TimeoutExpired as expired:
        partial = expired.stdout or ""
        output = (partial if isinstance(partial, str) else partial.decode(errors="replace")) + "\nTIMEOUT\n"
        code = None
    (log_dir / f"{name}.log").write_text(output, encoding="utf-8")

    lines = output.splitlines()
    passed = sum(line.startswith("PASS ") for line in lines)
    failed = sum(line.startswith("FAIL ") for line in lines)
    skipped = sum(line.startswith("SKIP ") for line in lines)
    finished = any(line.startswith("SUMMARY ") for line in lines)
    if code is None:
        status = "TIMEOUT"
    elif not finished:
        status = f"CRASH(exit={code})"
    elif failed:
        status = "FAILURES"
    else:
        status = "ok"
    return status, passed, failed, skipped


def print_failures(name: str, log_dir: Path) -> None:
    """Prints the failing tests of one class with their messages.

    Args:
        name: Test class name.
        log_dir: Directory that holds the class log.
    """
    lines = (log_dir / f"{name}.log").read_text(encoding="utf-8").splitlines()
    for index, line in enumerate(lines):
        if not line.startswith("FAIL "):
            continue
        print(f"    {line}")
        for detail in lines[index + 1:]:
            if not detail.startswith("     "):
                break
            print(f"    {detail}")


def main(argv: list[str]) -> int:
    """Entry point.

    Args:
        argv: Arguments without the program name.

    Returns:
        Process exit status: 0 when every executed class passed.
    """
    args = parse_args(argv)
    toolchain = resolve_toolchain(args.sdk)
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    frameworks = WORK_DIR / "fw"
    host = WORK_DIR / HOST_EXECUTABLE_NAME

    if not args.skip_build:
        env = build_environment(toolchain)
        print(f"SDK: {toolchain.sdk or 'toolchain default'}")
        frameworks = build_shim(toolchain, env)
        build_test_bundle(toolchain, env, frameworks)
    elif not host.is_file():
        raise SystemExit("No previous build found; run without --skip-build.")

    bundle = find_test_bundle()
    async_list = write_async_throws_list()
    run_env = host_environment(toolchain, frameworks)
    available = list_classes(host, bundle, async_list, run_env)
    if args.list:
        print("\n".join(available))
        return 0

    unknown = sorted(set(args.classes) - set(available))
    if unknown:
        raise SystemExit(f"Unknown test classes: {', '.join(unknown)}")
    selected = args.classes or available

    log_dir = WORK_DIR / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    totals = {"passed": 0, "failed": 0, "skipped": 0}
    problems: list[str] = []
    for name in selected:
        status, passed, failed, skipped = run_class(
            name, host, bundle, async_list, run_env, args.timeout, log_dir
        )
        totals["passed"] += passed
        totals["failed"] += failed
        totals["skipped"] += skipped
        print(f"{status:16} {name}  pass={passed} fail={failed} skip={skipped}", flush=True)
        if status != "ok":
            problems.append(name)
            print_failures(name, log_dir)

    print(
        f"TOTAL classes={len(selected)} passed={totals['passed']} failed={totals['failed']} "
        f"skipped={totals['skipped']} problem_classes={len(problems)}"
    )
    if problems:
        print(f"PROBLEMS: {' '.join(problems)}")
        print(f"Logs: {log_dir.relative_to(REPO_ROOT)}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
