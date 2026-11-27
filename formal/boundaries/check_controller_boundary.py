#!/usr/bin/env python3
"""Reject product wiring that bypasses agent.Controller."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
PRODUCTS = (
    ROOT / "packages/cpi_minimal/src",
    ROOT / "packages/cpi_example_terminus/src",
    ROOT / "packages/agent/examples",
)
RULES = (
    (re.compile(r"\bagent\.(?:Worker|Adapters?|AdapterRequest|AdapterResponse|Observer)\b"), "native Worker or split adapter API"),
    (re.compile(r"\.adapters\s*\("), "direct provider adapter"),
    (re.compile(r"@import\([^\n]*(?:agent/src/|engine_tests_api\.zig|(?:Worker|Runtime|Foreign)\.zig)"), "private Worker implementation"),
    (re.compile(r"host\.call\s*\(\s*['\"](?:coding\.|runtime\.call)"), "product-specific host ABI"),
    (re.compile(r"\.registry\.dispatch\s*\("), "product-owned service dispatcher"),
)


def violations(path, source):
    findings = []
    for number, line in enumerate(source.splitlines(), 1):
        if line.lstrip().startswith(("//", "//!")):
            continue
        for pattern, reason in RULES:
            if pattern.search(line):
                findings.append(f"{path}:{number}: {reason}; use agent.Controller and declared service operations")
    return findings


def negative_controls():
    directory = Path(__file__).resolve().parent / "fixtures/controller-prior"
    manifest = json.loads((directory / "manifest.json").read_text())
    if manifest["revision"] != "ca76e6e3847ace2ac1fa482f72078cd07e8a6967":
        raise ValueError("unexpected controller negative-control revision")
    for record in manifest["files"]:
        path = directory / record["fixture"]
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != record["sha256"]:
            raise ValueError(f"modified prior-source negative control: {path}")
        errors = violations(record["source"], data.decode())
        if not errors or not any("agent.Controller" in error for error in errors):
            raise ValueError(f"prior source no longer rejected: {path}")
        print(f"Rejected verbatim {manifest['revision']}:{record['source']} ({len(errors)} violations)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--negative-controls", action="store_true")
    parser.add_argument("paths", nargs="*", type=Path)
    arguments = parser.parse_args()
    if arguments.negative_controls:
        negative_controls()
        if not arguments.paths:
            return 0
    paths = arguments.paths or [path for directory in PRODUCTS for path in directory.rglob("*") if path.suffix in (".zig", ".lua", ".luau") and not path.name.endswith("_tests.zig")]
    failures = []
    for path in sorted(paths):
        failures.extend(violations(path, path.read_text()))
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("Product controller boundary passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
