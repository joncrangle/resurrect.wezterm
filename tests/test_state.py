"""Exercise the installed plugin with WezTerm's Lua runtime and real age encryption.

Run: python3 tests/test_state.py --age /path/to/age
Requires wezterm and age-keygen next to the age executable.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--age", default=shutil.which("age"))
    parser.add_argument("--gui", action="store_true", help="also restore a temporary workspace in an isolated GUI")
    args = parser.parse_args()
    if not args.age:
        parser.error("age is required")
    age = Path(args.age).resolve()
    keygen = age.with_name("age-keygen")
    plugin = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="resurrect-test-") as directory:
        root = Path(directory)
        for kind in ("workspace", "window", "tab"):
            (root / "state" / kind).mkdir(parents=True)
        subprocess.run([str(keygen), "-o", str(root / "key.txt")], check=True, capture_output=True)
        recipient = subprocess.check_output([str(keygen), "-y", str(root / "key.txt")], text=True).strip()
        env = dict(os.environ, RESURRECT_TEST_ROOT=str(root), RESURRECT_TEST_PLUGIN=str(plugin),
                   RESURRECT_TEST_AGE=str(age), RESURRECT_TEST_RECIPIENT=recipient)
        subprocess.run(["wezterm", "--config-file", str(plugin / "tests" / "state.lua"),
                        "show-keys", "--lua"], env=env, capture_output=True, check=True)
        report = root / "results.json"
        if not report.exists():
            raise SystemExit("FAIL: WezTerm did not finish running the checks")
        results = json.loads(report.read_text())
        for result in results:
            print(("PASS" if result["passed"] else "FAIL") + ": " + result["name"])
            if not result["passed"]:
                print("  " + result["error"])
        if args.gui:
            report = root / "workspace-results.json"
            with (root / "gui.log").open("w") as log:
                process = subprocess.Popen(
                    ["wezterm", "--config-file", str(plugin / "tests" / "workspace.lua"),
                     "start", "--always-new-process", "--no-auto-connect", "--class", "resurrect-test"],
                    env=env, stdout=subprocess.DEVNULL, stderr=log)
                try:
                    deadline = time.monotonic() + 15
                    while not report.exists() and time.monotonic() < deadline:
                        time.sleep(0.1)
                    if not report.exists():
                        raise SystemExit("FAIL: temporary GUI did not produce a test result")
                    result = json.loads(report.read_text())
                finally:
                    process.terminate()
                    process.wait(timeout=5)
            result["name"] = "real GUI restore preserves tabs, split panes, titles, and scrollback"
            results.append(result)
            print(("PASS" if result["passed"] else "FAIL") + ": " + result["name"])
            if not result["passed"]:
                print("  " + result["error"])
        raise SystemExit(0 if all(result["passed"] for result in results) else 1)


if __name__ == "__main__":
    main()
