import gzip
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import zlib

from session_reference import runtime_state

binary = str(Path(sys.argv[1]).resolve())

def invoke(path, identity, source="return 2"):
    return subprocess.run([binary, "--session", "s", "--journal", str(path), "--request-id", identity, "--lua", source], capture_output=True, timeout=10)

def members(data):
    result = []
    offset = 0
    while offset < len(data):
        decoder = zlib.decompressobj(31)
        decoder.decompress(data[offset:])
        assert decoder.eof
        used = len(data) - offset - len(decoder.unused_data)
        result.append((offset, offset + used))
        offset += used
    return result

with tempfile.TemporaryDirectory(prefix="cpi-framing-") as directory:
    path = Path(directory) / "session.gz"
    assert invoke(path, "first", 'ctx.marker="KEEPME"; return 1').returncode == 0
    valid = path.read_bytes()
    boundaries = members(valid)
    tested = 0
    for start, end in (boundaries[0], boundaries[-1]):
        header = 22 if valid[start + 3] & 4 else 10
        found = 0
        for index in range(max(start + header, end - 24), end - 8):
            for mask in (1, 128, 255):
                mutant = bytearray(valid)
                mutant[index] ^= mask
                decoder = zlib.decompressobj(31)
                try:
                    decoder.decompress(mutant[start:end])
                except zlib.error:
                    continue
                if decoder.eof:
                    continue
                path.write_bytes(mutant)
                result = invoke(path, "bad")
                assert result.returncode != 0, ("accepted complete corrupt member", start, index, mask)
                assert path.read_bytes() == mutant, ("modified corrupt bytes", start, index, mask)
                tested += 1
                found += 1
                if found == 3:
                    break
            if found == 3:
                break
        assert found, ("no incomplete-decoder corruption candidates", start, end)
    for index in (3, 4, 10, 14, 16, 20, len(valid)-8, len(valid)-4, boundaries[-1][0]+10, boundaries[-1][0]+11):
        mutant = bytearray(valid)
        mutant[index] ^= 255
        path.write_bytes(mutant)
        assert invoke(path, "header").returncode != 0
        assert path.read_bytes() == mutant
    for cut in range(1, min(32, boundaries[-1][1] - boundaries[-1][0])):
        path.write_bytes(valid[:-cut])
        assert invoke(path, "repair-" + str(cut)).returncode == 0
        gzip.decompress(path.read_bytes())
    path.write_bytes(valid[:-5])
    large_source = 'ctx.large=string.rep("x",60000); return #ctx.large'
    assert invoke(path, "large", large_source).returncode == 0
    reopened = invoke(path, "large", large_source)
    assert reopened.returncode == 0, (reopened.stdout, reopened.stderr)
    assert runtime_state(path)["ctx"]["large"] == "x" * 60000
    gzip_members = [gzip.compress(gzip.decompress(valid[start:end]), mtime=0) for start, end in boundaries]
    gzip_data = b"".join(gzip_members)
    found = False
    for index in range(max(10, len(gzip_members[0]) - 24), len(gzip_members[0]) - 8):
        mutant = bytearray(gzip_data)
        mutant[index] ^= 1
        decoder = zlib.decompressobj(31)
        try:
            prefix = decoder.decompress(mutant[:len(gzip_members[0])])
        except zlib.error:
            continue
        if decoder.eof:
            continue
        # A flip can land on content whose change still parses; that is a content
        # change, not transport damage, and record lengths shift it around.
        try:
            json.loads(prefix.decode())
            continue
        except Exception:
            pass
        path.write_bytes(mutant)
        assert invoke(path, "gzip_data-middle").returncode != 0
        assert path.read_bytes() == mutant
        found = True
        break
    assert found
    path.write_bytes(gzip_data[:-5])
    assert invoke(path, "gzip_data-repair").returncode == 0
    gzip.decompress(path.read_bytes())
    for cut in range(boundaries[-1][0], boundaries[-1][0] + 22):
        path.write_bytes(valid[:cut])
        assert invoke(path, "header-repair").returncode == 0
    assert tested >= 2
print("Native framing rejects complete deflate EOF corruption; Python gzip reads repaired large records")
