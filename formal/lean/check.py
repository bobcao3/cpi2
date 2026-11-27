#!/usr/bin/env python3
"""Check the pinned Lean proofs, theorem dependencies, and rejection controls."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
VERSION = (ROOT / 'lean-toolchain').read_text().strip().split(':v')[-1]
ALLOWED_AXIOMS = {'propext', 'Classical.choice', 'Quot.sound'}
DEPENDENCIES = re.compile(r"'([^']+)' (?:depends on axioms: \[([^\]]*)\]|does not depend on any axioms)")
FORBIDDEN_SOURCE = re.compile(r'\b(?:sorry|admit|axiom|unsafe|native_decide|implemented_by)\b')


def dependencies(output):
    audited = {}
    for name, values in DEPENDENCIES.findall(output):
        audited[name] = {value.strip() for value in values.split(',') if value.strip()}
    return audited


def main():
    requested = os.environ.get('LEAN')
    cached = Path.home() / '.cache' / 'cpi-formal' / f'lean-{VERSION}-linux' / 'bin' / 'lean'
    lean = requested if requested is not None else (shutil.which('lean') or (str(cached) if cached.is_file() else None))
    if not lean:
        raise RuntimeError(f'Install Lean {VERSION} or set LEAN to its executable. No proof was checked.')
    version = subprocess.run([lean, '--version'], text=True, capture_output=True, check=True)
    if not re.search(r'\bversion ' + re.escape(VERSION) + r'[, )]', version.stdout):
        raise RuntimeError(f'Expected Lean {VERSION}, got {version.stdout.strip()}')
    out = Path(os.environ.get('OUT', ROOT.parents[1] / '.zig-cache' / 'lean')).resolve()
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, LEAN_PATH=str(out))

    def run(source, output=None):
        args = [lean, '-DwarningAsError=true']
        if output:
            args.extend(['-o', str(output)])
        args.append(str(source.relative_to(ROOT)))
        result = subprocess.run(args, cwd=ROOT, env=env, text=True, capture_output=True, timeout=60)
        log = result.stdout + result.stderr
        (out / (source.stem + '.log')).write_text(log)
        return result.returncode, log

    modules = sorted((ROOT / 'Cpi').glob('*.lean'))
    expected_modules = {'Lifetime', 'Publication', 'Registry'}
    if {source.stem for source in modules} != expected_modules:
        raise RuntimeError('Proof portfolio must contain Lifetime, Publication, and Registry')
    for source in modules:
        text = source.read_text()
        if FORBIDDEN_SOURCE.search(text):
            raise RuntimeError(f'{source.name} contains a forbidden proof escape')
        declarations = re.findall(r'^(?:theorem|lemma)\s+([A-Za-z_][A-Za-z0-9_]*)', text, re.MULTILINE)
        if not declarations:
            raise RuntimeError(f'{source.name} has no theorems')
        expected = {f'Cpi.{source.stem}.{name}' for name in declarations}
        destination = out / 'Cpi' / source.with_suffix('.olean').name
        destination.parent.mkdir(parents=True, exist_ok=True)
        code, log = run(source, destination)
        if code:
            raise RuntimeError(log)
        audited = dependencies(log)
        if set(audited) != expected:
            raise RuntimeError(f'{source.name} missing or unexpected theorem audits: {expected ^ set(audited)}')
        for name, axioms in audited.items():
            if axioms - ALLOWED_AXIOMS:
                raise RuntimeError(f'{name} depends on forbidden axioms: {axioms - ALLOWED_AXIOMS}')
        print(f'PASS Cpi.{source.stem}; {len(expected)} theorem dependency checks', flush=True)

    for name in ('FalseArithmetic', 'SourceIsolation', 'EarlyPublication', 'UnjoinedRelease'):
        code, log = run(ROOT / 'negative' / (name + '.lean'))
        if code == 0 or not re.search(r'Tactic `decide` proved that the proposition.*is false', log, re.DOTALL):
            raise RuntimeError(f'{name} did not fail at its intended false proposition:\n{log}')
        print(f'EXPECTED REJECTION {name}', flush=True)
    code, log = run(ROOT / 'negative' / 'Incomplete.lean')
    if code == 0 or 'declaration uses `sorry`' not in log:
        raise RuntimeError(f'Incomplete proof did not fail at the intended admission:\n{log}')
    print('EXPECTED REJECTION Incomplete', flush=True)
    code, log = run(ROOT / 'negative' / 'CustomAxiom.lean')
    audited = dependencies(log)
    if code != 0 or 'untrusted' not in audited or not (audited['untrusted'] - ALLOWED_AXIOMS):
        raise RuntimeError(f'Custom axiom control did not exercise dependency rejection:\n{log}')
    print('EXPECTED REJECTION CustomAxiom dependency', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
