from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile


def run(repl, source):
    result = subprocess.run(
        [repl],
        input=source,
        text=True,
        capture_output=True,
        timeout=10,
        umask=0o077 if os.name == "posix" else -1,
    )
    assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
    assert not result.stderr, result.stderr
    return result.stdout.splitlines()


def quote(path):
    return '"' + str(path).replace("\\", "\\\\").replace('"', '\\"') + '"'


def check_repl(repl):
    lines = run(
        repl,
        """print("native print")
answer = 41
answer += 1; return answer
answer
_G.answer
ctx == nil and tools == nil
record = {value = 1}; record.value = 17; return record.value
function add(a: number, b: number): number
    return a + b
end
add(19, 23)
answer = 7; error("expected error")
answer
local =
6 * 7
math.abs = nil
math.abs(-11)
:quit
""",
    )
    errors = [line for line in lines if "error: " in line]
    values = [line for line in lines if "error: " not in line]
    assert values == [
        "native print",
        "42",
        "42",
        "42",
        "true",
        "17",
        "42",
        "7",
        "42",
        "11",
    ], lines
    assert len(errors) == 3, lines
    assert any("expected error" in line for line in errors), lines
    assert any("compile error:" in line for line in errors), lines
    assert any("readonly" in line or "read-only" in line for line in errors), lines
    incomplete = run(repl, "function unfinished()\n")
    assert len(incomplete) == 1 and incomplete[0].startswith("compile error:"), (
        incomplete
    )
    assert "<eof>" in incomplete[0], incomplete
    oversized = run(repl, "a" * 65537 + "\n42\n")
    assert oversized == ["input error: line too long", "42"], oversized


def check_extension(repl, extension, failing):
    with tempfile.TemporaryDirectory(prefix="luau repl ") as temporary:
        directory = Path(temporary)
        library = directory / ("native extension" + Path(extension).suffix)
        shutil.copyfile(extension, library)
        payload = directory / "payload.bin"
        payload.write_bytes(b"A\x00B\n")
        created = directory / "created.bin"
        source = f""":load posix {library}
file = assert(posix.open({quote(payload)}))
first = assert(posix.read(file, 2))
second = assert(posix.read(file, 16))
do assert(first == "A\\0" and second == "B\\n") end
do assert(posix.read(file, 1) == "") end
do assert(posix.close(file)) end
value, message, code = posix.read(file, 1); assert(value == nil and code == posix.EBADF)
value, message, code = posix.close(file); assert(value == nil and code == posix.EBADF)
dir = assert(posix.opendir({quote(directory)}))
names = {{}}
while true do
    local name, err = posix.readdir(dir)
    assert(err == nil, err)
    if name == nil then break end
    names[name] = true
end
do assert(names["payload.bin"] and names[{quote(library.name)}]) end
do assert(posix.closedir(dir)) end
value, message, code = posix.readdir(dir); assert(value == nil and code == posix.EBADF)
value, message, code = posix.closedir(dir); assert(value == nil and code == posix.EBADF)
value, message, code = posix.open({quote(directory / "missing")}); assert(value == nil and code == posix.ENOENT)
do assert(not pcall(posix.read, "not a file", 1)) end
file = assert(posix.open({quote(created)}, posix.O_CREAT + posix.O_RDWR, 384))
do assert(posix.read(file, 0) == "") end
do assert(posix.close(file)) end
left_open = assert(posix.open({quote(payload)}))
left_directory = assert(posix.opendir({quote(directory)}))
do assert(not pcall(posix.read, left_open, posix.READ_LIMIT + 1)) end
do assert(not pcall(posix.read, left_open, 0.5)) end
do assert(not pcall(posix.open, "invalid\\0path")) end
"posix ok"
:load missing {library}
:load broken {failing}
retained_from_broken()
:load void {failing}
"still running"
:quit
"""
        lines = run(repl, source)
        errors = [line for line in lines if line.startswith("load error:")]
        values = [line for line in lines if not line.startswith("load error:")]
        assert values == ["posix ok", "73", "still running"], lines
        assert len(errors) == 3, lines
        assert any("luaopen_missing" in line for line in errors), lines
        assert any("intentional initialization failure" in line for line in errors), (
            lines
        )
        assert any("nil" in line for line in errors), lines
        assert created.read_bytes() == b""
        assert created.stat().st_mode & 0o777 == 0o600


if __name__ == "__main__":
    check_repl(sys.argv[1])
    if len(sys.argv) == 4:
        check_extension(sys.argv[1], sys.argv[2], sys.argv[3])
    print("REPL and native extension checks passed")
