import argparse
import json
from pathlib import Path
import queue
import subprocess
import threading
import time


def main():
    parser = argparse.ArgumentParser(description='Verify ownership diagnostics appear and clear through ZLS.')
    parser.add_argument('--workdir', type=Path, required=True)
    parser.add_argument('--zls', type=Path, required=True)
    parser.add_argument('--zig', type=Path, required=True)
    args = parser.parse_args()
    root = args.workdir.resolve()
    root.mkdir(parents=True, exist_ok=True)
    if any(root.iterdir()):
        raise ValueError('workdir must be empty')
    repo = Path(__file__).resolve().parents[2]
    bad = root / 'bad.zig'
    prefix = 'const j = @import("json.zig");\nfn change(doc: *j.Document, a: j.Allocator) !void {\n'
    suffix = '    _ = j.get(doc.value, "active");\n}\n'
    broken = prefix + '    var active = j.get(doc.value, "active");\n    try j.put(a, &active, "continuation", .null);\n' + suffix
    fixed = prefix + '    const active = j.ptr(&doc.value, "active");\n    try j.put(a, active, "continuation", .null);\n' + suffix
    bad.write_text(broken)
    (root / 'json.zig').write_text('''const std = @import("std");
pub const Allocator = std.mem.Allocator;
pub const Value = std.json.Value;
pub const Document = struct { value: Value };
pub fn get(v: Value, key: []const u8) Value { return v.object.get(key) orelse .null; }
pub fn ptr(v: *Value, key: []const u8) *Value { return v.object.getPtr(key).?; }
pub fn put(a: Allocator, v: *Value, key: []const u8, item: Value) !void { try v.object.put(a, key, item); }
''')
    def literal(path):
        return json.dumps(str(path))
    (root / 'build.zig').write_text('''const std = @import("std");
pub fn build(b: *std.Build) void {
    const analysis = b.createModule(.{ .root_source_file = b.graph.cwdRelativePath(ANALYSIS), .target = b.graph.host });
    const exe = b.addExecutable(.{ .name = "ownership-editor-check", .root_module = b.createModule(.{
        .root_source_file = b.graph.cwdRelativePath(LINT),
        .target = b.graph.host,
        .imports = &.{.{ .name = "ownership_analysis", .module = analysis }},
    }) });
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    run.addArg("bad.zig");
    run.addFileInput(b.path("bad.zig"));
    run.enableProtocolMode();
    b.step("check", "Check ownership through the real build protocol").dependOn(&run.step);
}
'''.replace('ANALYSIS', literal(repo / 'tools/ownership/src/analysis.zig')).replace('LINT', literal(repo / 'tools/ownership/src/main.zig')))
    config = root / 'zls.json'
    config.write_text(json.dumps({'zig_exe_path': str(args.zig.resolve()), 'enable_build_on_save': True, 'build_on_save_args': ['-j2']}))
    events: queue.Queue[dict | Exception | None] = queue.Queue()
    messages = []
    with (root / 'zls.stderr').open('wb') as stderr:
        process = subprocess.Popen([str(args.zls.resolve()), '--config-path', str(config), '--log-file', str(root / 'zls.log')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, cwd=root)
        assert process.stdin is not None and process.stdout is not None

        def receive():
            try:
                while True:
                    headers = {}
                    while True:
                        line = process.stdout.readline()
                        if not line:
                            return
                        if line in (b'\r\n', b'\n'):
                            break
                        key, value = line.decode().split(':', 1)
                        headers[key.lower()] = value.strip()
                    size = int(headers['content-length'])
                    body = process.stdout.read(size)
                    if len(body) != size:
                        raise EOFError('truncated LSP message')
                    message = json.loads(body)
                    messages.append(message)
                    events.put(message)
            except Exception as error:
                events.put(error)
            finally:
                events.put(None)

        reader = threading.Thread(target=receive)
        reader.start()

        def send(message):
            data = json.dumps(message).encode()
            process.stdin.write(f'Content-Length: {len(data)}\r\n\r\n'.encode() + data)
            process.stdin.flush()

        def wait_for(predicate, label):
            deadline = time.monotonic() + 120
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(label)
                try:
                    message = events.get(timeout=remaining)
                except queue.Empty as error:
                    raise TimeoutError(label) from error
                if message is None:
                    raise EOFError(label)
                if isinstance(message, Exception):
                    raise message
                if 'method' in message and 'id' in message:
                    result = [None for _ in message.get('params', {}).get('items', [])] if message['method'] == 'workspace/configuration' else None
                    send({'jsonrpc': '2.0', 'id': message['id'], 'result': result})
                    continue
                if predicate(message):
                    return message

        uri = bad.as_uri()
        try:
            send({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'processId': None, 'rootUri': root.as_uri(), 'workspaceFolders': [{'uri': root.as_uri(), 'name': 'ownership-probe'}], 'capabilities': {'workspace': {'workspaceFolders': True}, 'textDocument': {'publishDiagnostics': {'relatedInformation': True}}}}})
            initialized = wait_for(lambda item: item.get('id') == 1 and 'method' not in item, 'ZLS initialization')
            assert 'error' not in initialized, initialized
            send({'jsonrpc': '2.0', 'method': 'initialized', 'params': {}})
            send({'jsonrpc': '2.0', 'method': 'textDocument/didOpen', 'params': {'textDocument': {'uri': uri, 'languageId': 'zig', 'version': 1, 'text': broken}}})
            finding = wait_for(lambda item: item.get('method') == 'textDocument/publishDiagnostics' and item['params']['uri'] == uri and any('OWN001' in diagnostic['message'] for diagnostic in item['params']['diagnostics']), 'ownership diagnostic')
            owned = next(item for item in finding['params']['diagnostics'] if 'OWN001' in item['message'])
            assert owned['range']['start']['line'] == 3, owned
            bad.write_text(fixed)
            send({'jsonrpc': '2.0', 'method': 'textDocument/didChange', 'params': {'textDocument': {'uri': uri, 'version': 2}, 'contentChanges': [{'text': fixed}]}})
            send({'jsonrpc': '2.0', 'method': 'textDocument/didSave', 'params': {'textDocument': {'uri': uri}}})
            wait_for(lambda item: item.get('method') == 'textDocument/publishDiagnostics' and item['params']['uri'] == uri and not item['params']['diagnostics'], 'ownership diagnostic clearing')
            send({'jsonrpc': '2.0', 'id': 2, 'method': 'shutdown', 'params': None})
            wait_for(lambda item: item.get('id') == 2 and 'method' not in item, 'ZLS shutdown')
            send({'jsonrpc': '2.0', 'method': 'exit', 'params': None})
            assert process.wait(timeout=10) == 0
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            reader.join(timeout=10)
            process.stdin.close()
            process.stdout.close()
            if reader.is_alive():
                reader.join(timeout=10)
            (root / 'messages.json').write_text(json.dumps(messages, indent=2))
    print(json.dumps({'case': 'ownership_zls_diagnostic_and_clear', 'passed': True}))


if __name__ == '__main__':
    main()
