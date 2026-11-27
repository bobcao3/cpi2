import copy
import gzip
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from session_reference import action_frame, command_records, encode, fixture_frames, read_frames, runtime_state, write_frames

binary = str(Path(sys.argv[1]).resolve())
source = "ctx.count=(ctx.count or 0)+1; return ctx.count"


def invoke(path, identity, lua=source, success=True):
    result = subprocess.run([binary, '--session', 'native-cli', '--journal', str(path), '--request-id', identity, '--lua', lua], capture_output=True, text=True, timeout=10)
    assert (result.returncode == 0) == success, (result.returncode, result.stdout, result.stderr)
    if success:
        outcome = json.loads(result.stdout)
        assert outcome['status'] == 'completed', outcome
        return outcome['result']
    assert result.stderr.startswith('cpi-agent: '), result.stderr


with tempfile.TemporaryDirectory(prefix='cpi-agent-native-') as directory:
    path = Path(directory) / 'session.gz'
    assert invoke(path, 'first') == 1
    prefix = path.read_bytes()
    assert invoke(path, 'second') == 2
    assert path.read_bytes().startswith(prefix)
    assert invoke(path, 'first') == 1
    frames = read_frames(path)
    assert runtime_state(path)['ctx']['count'] == 2
    assert all(frame['op'] not in ('control.session.open', 'control.session.close') for frame in frames)
    assert len([entry for entry in command_records(path) if entry['id'] == 'first']) == 1
    assert not Path(str(path) + '.history').exists()
    python_path = Path(directory) / 'python.gz'
    imported = runtime_state(path)
    write_frames(python_path, fixture_frames('native-cli', imported))
    assert invoke(python_path, 'third') == 3
    malformed_state = copy.deepcopy(imported)
    malformed_state['commands'] = {}
    unexpected_state = dict(imported, unexpected=True)
    unknown = action_frame('native-cli', 1, 'control.session.open', {})
    extra = action_frame('native-cli', 1, 'control.context.select', {'context': 'main'})
    extra['unexpected'] = True
    cases = [encode([unknown]), encode([extra]), encode(fixture_frames('native-cli', malformed_state)), encode(fixture_frames('native-cli', unexpected_state))]
    cases.append(gzip.compress(b'{"kind":"checkpoint","sequence":1,"session_id":"native-cli","snapshot":{}}\n'))
    for index, data in enumerate(cases):
        for suffix in (b'', b'\x1f'):
            malformed_path = Path(directory) / f'malformed-{index}-{len(suffix)}.gz'
            original = data + suffix
            malformed_path.write_bytes(original)
            invoke(malformed_path, 'must-reject', success=False)
            assert malformed_path.read_bytes() == original
    valid = path.read_bytes()
    for offset in (-8, -4):
        corrupt = bytearray(valid)
        corrupt[offset] ^= 0xff
        path.write_bytes(corrupt)
        invoke(path, 'corrupt', success=False)
        assert path.read_bytes() == corrupt
    path.write_bytes(valid + b'garbage')
    invoke(path, 'garbage', success=False)
    assert path.read_bytes() == valid + b'garbage'
    path.write_bytes(valid)
    invoke(path, 'failure', 'error("native failure")', success=False)
print('Native semantic journal reopen, append-only deduplication, gzip interoperability and legacy/corruption rejection passed')
