import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import traceback

BINARY = str(Path(sys.argv[1]).resolve())
GHOSTMUX = str(Path(sys.argv[2]).resolve())
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'agent/scripts'))
from session_reference import read_frames, runtime_state, session_state


def action(keys=None, complete=False):
    return json.dumps({
        "analysis": "a",
        "plan": "p",
        "commands": [] if keys is None else [{"keystrokes": keys, "duration": 0.1}],
        "task_complete": complete,
    })


def response(text):
    return {
        "object": "response", "status": "completed", "model": "fixture",
        "output": [{"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": text}]}],
        "usage": {"input_tokens": 10, "output_tokens": 5, "total_tokens": 15},
    }


class Provider:
    def __init__(self):
        self.requests = []
        self.errors = []
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                pass

            def do_POST(self):
                try:
                    assert self.path == "/responses", self.path
                    body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    outer.requests.append(body)
                    number = len(outer.requests)
                    if number == 1:
                        keys = "printf dGVybWludXMtb2JzZXJ2ZWQ= | base64 -d | tee receipt.txt\n"
                        assert 'terminus-observed' not in keys
                        text = action(keys)
                    else:
                        assert "terminus-observed" in body["input"][-1]["content"], body["input"]
                        assert number == 2 or "task_complete" in body["input"][-1]["content"], body["input"]
                        text = action(complete=True)
                    payload = response(text)
                except Exception:
                    outer.errors.append(traceback.format_exc())
                    payload = {"error": {"code": "fixture_assertion"}}
                data = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        assert not self.errors, self.errors


def main():
    provider = Provider()
    try:
        with tempfile.TemporaryDirectory(prefix="terminus-prototype-") as directory, tempfile.TemporaryDirectory(prefix="gm-") as sockets:
            base = Path(directory)
            workspace = base / "workspace"
            workspace.mkdir()
            socket = str(Path(sockets) / "control.sock")
            env = {key: value for key, value in os.environ.items() if not key.startswith(("OPENAI_", "PI_"))}
            try:
                proc = subprocess.run([
                    BINARY, "--task", "create the receipt", "--workspace", str(workspace),
                    "--state-dir", str(base / "state"), "--fixture-url", f"http://127.0.0.1:{provider.server.server_port}",
                    "--ghostmux", GHOSTMUX, "--socket", socket,
                    "--max-turns", "5", "--max-model-calls", "8",
                ], env=env, capture_output=True, text=True, timeout=60)
                assert proc.returncode == 0, (proc.returncode, proc.stdout, proc.stderr)
                result = json.loads(proc.stdout)
                assert result["agent_status"] == "complete", result
                assert (workspace / "receipt.txt").read_text() == "terminus-observed"
                assert len(provider.requests) == 3, len(provider.requests)
                assert "task_complete" in provider.requests[-1]["input"][-1]["content"]
                assert all("tools" not in body for body in provider.requests)
                assert not (base / 'state' / 'worker-1.context.gz').exists()
                snapshot = runtime_state(base / 'state' / 'worker-1.guest.gz')
                assert snapshot['ctx']['state']['turn'] == 3
                assert snapshot['ctx']['state']['pending'] is True
                assert 'conversation' not in snapshot['ctx']
                path = base / 'state' / 'worker-1.guest.gz'
                state = session_state(path)
                selected = [state['messages'][identity] for identity in state['contexts']['main']]
                assert sum(message['role'] == 'assistant' for message in selected) == 3
                assert sum(message['role'] == 'user' for message in selected) == 3
                assert len(state['requests']) == 3, state['requests']
                assert all(request['finish']['status'] == 'completed' for request in state['requests'].values())
                assert all('snapshot' not in frame and 'kind' not in frame for frame in read_frames(path))
                assert not Path(str(path) + '.history').exists()
                print(json.dumps({"case": "terminus_json_actions_and_confirmation", "passed": True, "requests": len(provider.requests)}), flush=True)
            finally:
                subprocess.run([GHOSTMUX, "-S", socket, "kill-server"], capture_output=True, timeout=10)
    finally:
        provider.close()


if __name__ == "__main__":
    main()
