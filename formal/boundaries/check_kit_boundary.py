import os
from pathlib import Path
import sys

SKIP = {'.git', '.jj', '.zig-cache', 'zig-out', 'zig-pkg', 'node_modules', 'vendor', '__pycache__'}
PRIVATE_FIELDS = {'builder', 'import_table', 'root_source_file', 'owner'}
PRIVATE_IMPORTS = {'uucode', 'unicode_data', 'base_unicode', 'category_ranges'}


def tokens(source):
    result = []
    i = 0
    while i < len(source):
        if source[i].isspace():
            i += 1
        elif source.startswith('//', i) or source.startswith('\\\\', i):
            end = source.find('\n', i)
            i = len(source) if end < 0 else end
        elif source.startswith('/*', i):
            depth = 1
            i += 2
            while i < len(source) and depth:
                if source.startswith('/*', i):
                    depth += 1
                    i += 2
                elif source.startswith('*/', i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
        else:
            start = i
            if source[i] == '"':
                i += 1
                while i < len(source):
                    if source[i] == '\\':
                        i += 2
                    elif source[i] == '"':
                        i += 1
                        break
                    else:
                        i += 1
            elif source[i].isalnum() or source[i] == '_':
                i += 1
                while i < len(source) and (source[i].isalnum() or source[i] == '_'):
                    i += 1
            else:
                i += 1
            result.append((source[start:i], start))
    return result


def check(path):
    source = path.read_text()
    lexed = tokens(source)
    values = [item[0] for item in lexed]
    assignments = []
    for i, value in enumerate(values):
        if value not in {'const', 'var'} or i + 3 >= len(values):
            continue
        end = i + 2
        while end < len(values) and values[end] not in {'=', ';', '{', '}'}:
            end += 1
        if end < len(values) and values[end] == '=':
            assignments.append((values[i + 1], end + 1))
    dependencies = set()
    modules = set()
    for _ in range(len(assignments) + 1):
        previous = (dependencies.copy(), modules.copy())
        for name, rhs in assignments:
            if values[rhs + 1:rhs + 5] in (['.', 'dependency', '(', '"kit"'], ['.', 'lazyDependency', '(', '"kit"']):
                dependencies.add(name)
            elif values[rhs] in dependencies:
                if values[rhs + 1:rhs + 4] == ['.', 'module', '(']:
                    modules.add(name)
                elif values[rhs + 1:rhs + 2] == [';']:
                    dependencies.add(name)
            elif values[rhs] in modules and values[rhs + 1:rhs + 2] == [';']:
                modules.add(name)
        if previous == (dependencies, modules):
            break
    failures = set()
    for i, value in enumerate(values):
        if value in dependencies and values[i + 1:i + 3] == ['.', 'builder']:
            failures.add(i)
        if value in modules and i + 2 < len(values) and values[i + 1] == '.' and values[i + 2] in PRIVATE_FIELDS:
            failures.add(i)
        if value in dependencies and values[i + 1:i + 4] == ['.', 'module', '(']:
            depth = 1
            end = i + 4
            while end < len(values) and depth:
                if values[end] == '(':
                    depth += 1
                elif values[end] == ')':
                    depth -= 1
                end += 1
            if end + 1 < len(values) and values[end] == '.' and values[end + 1] in PRIVATE_FIELDS:
                failures.add(i)
        if value == '@' and values[i + 1:i + 3] == ['import', '('] and i + 3 < len(values) and values[i + 3].strip('"') in PRIVATE_IMPORTS:
            failures.add(i)
        if value.startswith('"') and ('src/unicode/uucode/' in value.replace('\\\\', '/') or '/Kit.zig/src/' in value):
            failures.add(i)
    return list(dict.fromkeys(f'{path}:{source.count(chr(10), 0, lexed[i][1]) + 1}: Kit internals are private. Depend on kit.module("kit") and use kit.unicode.generalCategory or another public Kit API.' for i in sorted(failures)))


def files(paths):
    for path in paths:
        if path.is_file():
            yield path
        else:
            for directory, names, filenames in os.walk(path):
                names[:] = [name for name in names if name not in SKIP]
                for name in sorted(filenames):
                    if name.endswith('.zig'):
                        yield Path(directory) / name


def main():
    roots = [Path(arg) for arg in sys.argv[1:]] or [Path(__file__).resolve().parents[2]]
    failures = [message for path in files(roots) for message in check(path)]
    if failures:
        print('\n'.join(failures), file=sys.stderr)
        return 1
    print('Kit consumer boundary passed.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
