from contextlib import contextmanager
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import subprocess
import sys
import threading
import time
import uuid

from test_support import configure_ghostmux_socket

BASE = Path(__file__).resolve().parent.parent
RUN = (
    Path(sys.argv[3]).resolve()
    if len(sys.argv) > 3 and not sys.argv[3].startswith("--")
    else BASE / ".zig-cache" / "runs" / uuid.uuid4().hex
)
POINTERS = RUN.parent
RUN.mkdir(parents=True)
BINARY = Path(sys.argv[1]).resolve()
GHOSTMUX = str(Path(sys.argv[2]).resolve())
configure_ghostmux_socket(BASE)


def reply(text, tokens=100, status="completed"):
    return {
        "id": "fixture-response",
        "status": status,
        "output": [
            {
                "type": "message",
                "role": "assistant",
                "content": [{"type": "output_text", "text": text}],
            }
        ],
        "usage": {"input_tokens": tokens, "output_tokens": 10},
    }


def action(keys=None, complete=False, analysis="fixture", duration=0.1):
    return json.dumps(
        {
            "analysis": analysis,
            "plan": "continue",
            "commands": []
            if keys is None
            else [{"keystrokes": keys, "duration": duration}],
            "task_complete": complete,
        }
    )


class Fixture:
    def __init__(self, scenario, root):
        self.scenario, self.root = scenario, root
        self.calls, self.errors = [], []
        self.release = threading.Event()
        self.model_seen = threading.Event()

    def respond(self, body):
        self.calls.append(body)
        metadata = body["metadata"]
        label, call = metadata.get("label"), metadata["call"]
        messages = body["input"]
        assert all("execute_lua" not in json.dumps(x.get("tools", [])) for x in [body])
        if label == "probe_child":
            assert messages[0]["content"] == "old-a"
            assert len(messages) == 2
            return 200, reply("CHILD_OK")
        if label in ("summary", "questions", "answers", "short"):
            if label == "summary":
                assert len(messages) >= 3
                assert messages[-1]["content"].startswith("You are about to hand off")
                if self.scenario == "happy":
                    prior = next(
                        r
                        for r in self.calls
                        if r["metadata"]["label"] == "main"
                        and r["metadata"]["call"] == 2
                    )
                    assert messages[:-1] == prior["input"] + [
                        {
                            "role": "assistant",
                            "content": action(
                                'printf "PERSIST:%s|%s" "$TERM_REPLICA_TOKEN" "${PWD##*/}" > persistent.txt'
                            ),
                        }
                    ]
                self.summary_prefix = messages[:-1]
                if self.scenario in ("short", "screen"):
                    return 500, {"error": {"code": "summary_failure"}}
                return 200, reply("SUMMARY_RECEIPT")
            if label == "questions":
                assert len(messages) == 1 and messages[0]["role"] == "user"
                assert "SUMMARY_RECEIPT" in messages[0]["content"]
                return 200, reply("QUESTION_RECEIPT")
            if label == "answers":
                assert messages[:-3] == self.summary_prefix
                assert messages[-3]["content"].startswith("You are about to hand off")
                assert messages[-2] == {
                    "role": "assistant",
                    "content": "SUMMARY_RECEIPT",
                }
                assert messages[-1]["content"].endswith("QUESTION_RECEIPT")
                return 200, reply("ANSWER_RECEIPT")
            assert len(messages) == 1
            if self.scenario == "screen":
                return 500, {"error": {"code": "short_failure"}}
            response = reply("SHORT_RECEIPT")
            response["output"][0]["content"].insert(
                0, {"type": "refusal", "text": "Not assistant output."}
            )
            return 200, response
        assert label == "main", label
        self.model_seen.set()
        if self.scenario in ("failed", "cancelled", "queued"):
            if call == 1:
                return 200, reply(
                    action("printf BAD > non-completed-executed\n"),
                    status=self.scenario,
                )
            return 200, reply(action(None, True))
        if self.scenario == "cancel":
            self.release.wait(10)
            return 200, reply(action("printf BAD > late.txt\n", True))
        if self.scenario == "happy":
            if call == 1:
                return 200, reply(
                    action(
                        "export TERM_REPLICA_TOKEN=kept; mkdir -p nested; cd nested\n"
                    )
                )
            if call == 2:
                return 200, reply(
                    action(
                        'printf "PERSIST:%s|%s" "$TERM_REPLICA_TOKEN" "${PWD##*/}" > persistent.txt'
                    ),
                    tokens=8100,
                )
            if call == 3:
                assert not (self.root / "nested/persistent.txt").exists(), (
                    "missing newline executed early"
                )
                assert [m["role"] for m in messages] == [
                    "user",
                    "user",
                    "assistant",
                    "user",
                ]
                assert "Task Description:" in messages[0]["content"]
                assert "SUMMARY_RECEIPT" in messages[1]["content"]
                assert messages[2]["content"] == "QUESTION_RECEIPT"
                assert "ANSWER_RECEIPT" in messages[3]["content"]
                return 200, reply(action("\n"))
            assert (
                self.root / "nested/persistent.txt"
            ).read_text() == "PERSIST:kept|nested"
            if call in (4, 6):
                return 200, reply(action("" if call == 4 else None, True))
            if call == 5:
                assert (
                    "Are you sure you want to mark the task as complete?"
                    in messages[-1]["content"]
                )
                return 200, reply(action(None, False))
            if call == 7:
                assert (
                    "Are you sure you want to mark the task as complete?"
                    in messages[-1]["content"]
                )
                return 200, reply(action(None, True))
            raise AssertionError(f"extra main call {call}")
        if self.scenario == "keys":
            return 200, reply(
                action(
                    [
                        "printf BAD > interrupted.txt",
                        "C-c",
                        "printf CONTROL_OK > control.txt\n",
                        None,
                    ][call - 1],
                    call >= 3,
                )
            )
        if self.scenario == "truncated":
            if call == 1:
                return 200, reply(
                    action("printf BAD > truncated-was-executed\n"), status="incomplete"
                )
            if call == 2:
                assert "NONE of the actions" in messages[-1]["content"]
                return 200, reply(action("printf SAFE > safe.txt\n", True))
            assert call == 3
            return 200, reply(action(None, True))
        if self.scenario in (
            "overflow",
            "overflow-truncated",
            "short",
            "screen",
            "unwind",
        ):
            if call == 1:
                return 200, reply(
                    action(
                        "export OVERFLOW_MARKER=live\n",
                        analysis="x" * 18000
                        if self.scenario == "unwind"
                        else "fixture",
                    )
                )
            if call == 2:
                return 400, {"error": {"code": "context_length_exceeded"}}
            if call == 3:
                prompt = messages[-1]["content"]
                if self.scenario == "overflow":
                    assert "ANSWER_RECEIPT" in prompt
                if self.scenario == "overflow-truncated":
                    assert "ANSWER_RECEIPT" in prompt
                    return 200, reply(
                        action("printf BAD > overflow-truncated-executed\n", True),
                        status="incomplete",
                    )
                if self.scenario == "short":
                    assert "Summary: SHORT_RECEIPT" in prompt
                if self.scenario == "screen":
                    assert "Current state:" in prompt
                if self.scenario == "unwind":
                    assert len(messages) == 1 and prompt == "Synthetic shell task."
                return 200, reply(
                    action('printf "%s" "$OVERFLOW_MARKER" > recovered.txt\n', True)
                )
            if self.scenario == "overflow-truncated" and call == 4:
                assert "NONE of the actions" in messages[-1]["content"]
                return 200, reply(
                    action('printf "%s" "$OVERFLOW_MARKER" > recovered.txt\n', True)
                )
            assert call == (5 if self.scenario == "overflow-truncated" else 4)
            return 200, reply(action(None, True))
        raise AssertionError((self.scenario, label, call))


@contextmanager
def serving(fixture):
    class Handler(BaseHTTPRequestHandler):
        timeout = 15

        def log_message(self, format: str, *args: object) -> None:
            pass

        def do_POST(self):
            try:
                assert self.path == "/responses"
                assert self.headers.get("Authorization") is None
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                status, response = fixture.respond(body)
            except Exception as error:
                fixture.errors.append(repr(error))
                status, response = (
                    500,
                    {"error": {"code": "fixture_assertion", "detail": repr(error)}},
                )
            encoded = json.dumps(response).encode()
            try:
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = False
    thread = threading.Thread(target=server.serve_forever)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        fixture.release.set()
        server.shutdown()
        server.server_close()
        thread.join()


def execute(
    name,
    program,
    payload,
    scenario="unused",
    extra=(),
    expected_return=0,
    sources=BASE / "src/guest",
):
    root = RUN / name
    root.mkdir()
    input_path = root / "input.json"
    input_path.write_text(json.dumps(payload))
    fixture = Fixture(scenario, root)
    with serving(fixture) as url:
        command = [
            str(BINARY),
            "--root",
            str(root),
            "--sources",
            str(sources),
            "--fixture-url",
            url,
            "--program",
            program,
            "--input",
            str(input_path),
            "--ghostmux",
            GHOSTMUX,
            "--socket",
            os.environ["CPI_GHOSTMUX_SOCKET"],
            *extra,
        ]
        process = subprocess.run(
            command, cwd=BASE, text=True, capture_output=True, timeout=90
        )
    (root / "stdout").write_text(process.stdout)
    (root / "stderr").write_text(process.stderr)
    (root / "requests.json").write_text(json.dumps(fixture.calls, indent=2))
    (root / "command.json").write_text(json.dumps(command))
    assert process.returncode == expected_return, (
        name,
        process.returncode,
        process.stdout[-3000:],
        process.stderr[-3000:],
    )
    if expected_return == 0:
        assert not process.stderr, (name, process.stderr[-3000:])
    assert not fixture.errors, (name, fixture.errors)
    for job in (root / "processes").rglob("*.job"):
        state = json.loads(job.with_suffix(".status").read_text())["session"]
        assert state["is_pty"] and state["exit_code"] is not None, state
    return json.loads(process.stdout), fixture, root


def replay_check(root, original):
    command = json.loads((root / "command.json").read_text())
    trace = (root / "broker.jsonl").read_bytes()
    fixture = Fixture("must-not-call-model", root)
    with serving(fixture) as url:
        command[command.index("--fixture-url") + 1] = url
        process = subprocess.run(
            command, cwd=BASE, text=True, capture_output=True, timeout=30
        )
    (root / "replay.stdout").write_text(process.stdout)
    (root / "replay.stderr").write_text(process.stderr)
    assert process.returncode == 0 and not process.stderr, process.stderr
    replay = json.loads(process.stdout)
    assert (
        replay["outcome"] == original["outcome"]
        and replay["context"] == original["context"]
    )
    assert not fixture.calls and not fixture.errors
    assert (root / "broker.jsonl").read_bytes() == trace
    changed = root / "changed-input.json"
    changed.write_text(json.dumps({"task": "different-task", "label": "main"}))
    command[command.index("--input") + 1] = str(changed)
    conflict = subprocess.run(
        command, cwd=BASE, text=True, capture_output=True, timeout=30
    )
    (root / "conflict.stderr").write_text(conflict.stderr)
    assert conflict.returncode == 1 and conflict.stderr == "SessionConflict\n", (
        conflict.stderr
    )


def parser_check() -> dict[str, object]:
    valid = {
        "analysis": "a",
        "plan": "p",
        "commands": [{"keystrokes": "pwd\n", "duration": 0.1}],
    }
    variants = [
        json.dumps(valid),
        "prose\n" + json.dumps(valid) + "\ntrailing",
        json.dumps(valid)[:-1],
        "{}",
        "{broken}",
        json.dumps({**valid, "commands": []}),
        json.dumps({**valid, "commands": {}}),
        json.dumps({**valid, "commands": [{"duration": 0.1}], "task_complete": True}),
        json.dumps({**valid, "commands": [{"duration": 0.1}]}),
        json.dumps({**valid, "commands": [{"keystrokes": "", "duration": 0.1}]}),
        json.dumps(
            {
                **valid,
                "commands": [
                    {"keystrokes": "pwd", "duration": 0},
                    {"keystrokes": "\n", "duration": 0},
                ],
            }
        ),
        json.dumps({**valid, "commands": [{"keystrokes": "pwd", "duration": True}]}),
        json.dumps({**valid, "commands": [{"keystrokes": "pwd", "duration": "bad"}]}),
        json.dumps({**valid, "commands": [{"keystrokes": "pwd"}]}),
        json.dumps({**valid, "commands": [None]}),
        json.dumps({**valid, "analysis": 12, "plan": False}),
        json.dumps({**valid, "task_complete": "YES"}),
        json.dumps({**valid, "task_complete": 1}),
        json.dumps({"commands": [], "plan": "p", "analysis": "a"}),
        json.dumps(
            {
                **valid,
                "commands": [{"keystrokes": '"\\\n☃', "duration": -1, "extra": 3}],
            }
        ),
        "bad { invalid } and " + json.dumps(valid),
        json.dumps(
            {
                **valid,
                "commands": [4],
                "commands/0": {"keystrokes": "must-not-confuse-shape"},
            }
        ),
        "null",
        "[]",
        "42",
        "true",
        "bad { invalid } and "
        + json.dumps(
            {
                "analysis": "a",
                "plan": "p",
                "commands": [
                    {
                        "keystrokes": "NESTED_ACTION\n",
                        "duration": 0,
                        "metadata": {"x": 1},
                    }
                ],
            }
        ),
    ]
    expected = json.loads((BASE / "tests/parser_expected.json").read_text())
    result, _, root = execute("parser", "parser_driver", {"responses": variants})
    actual = result["outcome"]["result"]
    assert len(actual) == len(expected)
    for index, (want, got) in enumerate(zip(expected, actual)):
        want["is_task_complete"] = bool(want["is_task_complete"])
        assert bool(want["error"]) == bool(got["error"]), (index, want, got)
        if want["error"].startswith("Invalid JSON:"):
            want["error"] = got["error"]
        assert want == got, (index, want, got)
    (root / "reference.json").write_text(json.dumps(expected, indent=2))
    return {"case": "parser", "variants": len(variants), "verified": True}


def metadata_checks():
    checks: list[dict[str, object]] = []
    echo, _, _ = execute("echo", "echo", {"task": "different-program", "label": "echo"})
    assert echo["outcome"]["result"]["own_ctx_is_not_canonical"]
    checks.append({"case": "echo-private-owner", "verified": True})
    checks.append(parser_check())
    for name, source in (
        ("deny", "return {allow=false}"),
        ("malformed", 'return {allow="yes"}'),
        ("policy-error", 'error("policy failure")'),
    ):
        policy = RUN / (name + ".luau")
        policy.write_text(source)
        denied, fixture, _ = execute(
            name,
            "echo",
            {"task": "must-not-run"},
            extra=("--policy", str(policy)),
            expected_return=1,
        )
        assert (
            denied["outcome"]["status"] == "failed"
            and denied["context"]["history"] == []
        )
        assert any(code in denied["outcome"]["error"]["message"] for code in ("PermissionDenied", "InvalidControllerPolicy"))
        assert not fixture.calls
        checks.append({"case": name, "verified": True})
    for name, extra in (("authority", ()), ("authority-allow-all", ("--policy", str(RUN / "allow-all.luau")))):
        if extra:
            (RUN / "allow-all.luau").write_text("return {allow=true}")
        result, _, root = execute(name, "probe", {"label": "probe", "without_terminal": True}, extra=extra)
        proof = result["outcome"]["result"]
        for key, value in proof["child"].items():
            if key != "model":
                assert value is True, (name, key, proof)
        assert not (root / "unauthorized-process").exists()
        assert not list((root / "processes").rglob("*.job"))
        if name == "authority":
            replay_check(root, result)
        checks.append({"case": name, "verified": True})
    generated, fixture, _ = execute("model-route", "once", {"label": "short", "prompt": "Synthetic route check."})
    assert generated["outcome"]["result"]["text"] == "SHORT_RECEIPT" and len(fixture.calls) == 1, generated["outcome"]["result"]
    checks.append({"case": "registered-model-route", "verified": True})
    denied_policy = RUN / "deny-model.luau"
    denied_policy.write_text('if packet.operation == "model.request" then return {allow=false} end\n' + (BASE / "src/guest/access.luau").read_text())
    denied, fixture, _ = execute("denied-model", "once", {"label": "short", "prompt": "Must not reach provider."}, extra=("--policy", str(denied_policy)), expected_return=1)
    assert denied["outcome"]["status"] == "failed" and not fixture.calls and denied["context"]["history"] == []
    checks.append({"case": "denied-model-zero-http", "verified": True})
    checks.append(cancelled_model_check("cancelled-model"))
    return checks


def cancelled_model_check(name):
    started = time.monotonic()
    cancelled, fixture, root = execute(name, "once", {"label": "main", "prompt": "Stalled model."}, scenario="cancel", extra=("--cancel-ms", "400"))
    assert fixture.model_seen.is_set() and cancelled["outcome"]["status"] == "cancelled"
    assert time.monotonic() - started < 5 and cancelled["context"]["history"] == []
    assert not list((root / "processes").rglob("*.job"))
    return {"case": name, "verified": True}


def main():
    if "--cancellation-only" in sys.argv[3:]:
        with ThreadPoolExecutor(max_workers=4) as pool:
            checks = list(pool.map(cancelled_model_check, (f"cancelled-model-{index}" for index in range(16))))
        (RUN / "results.json").write_text(json.dumps(checks, indent=2))
        print(json.dumps({"run": str(RUN), "checks": checks}, indent=2))
        return
    checks = metadata_checks()
    if "--metadata-only" in sys.argv[3:]:
        (RUN / "results.json").write_text(json.dumps(checks, indent=2))
        print(json.dumps({"run": str(RUN), "checks": checks}, indent=2))
        return
    probe, fixture, root = execute("scope", "probe", {"label": "probe"})
    proof = probe["outcome"]["result"]
    for key, value in proof["child"].items():
        if key != "model":
            assert value is True, (key, value)
    events = [
        json.loads(line) for line in (root / "broker.jsonl").read_text().splitlines()
    ]
    assert any(e["event"] == "trigger_suppressed" and e["pressured"] for e in events)
    checks.append({"case": "scope-broker-suppression", "verified": True})
    for scenario in (
        "happy",
        "keys",
        "truncated",
        "failed",
        "cancelled",
        "queued",
        "overflow",
        "overflow-truncated",
        "short",
        "screen",
        "unwind",
        "cancel",
    ):
        result, fixture, root = execute(
            scenario,
            "terminus",
            {"label": "main", "task": "Synthetic shell task.", "max_turns": 16},
            scenario,
            ("--cancel-ms", "4000") if scenario == "cancel" else (),
        )
        status = result["outcome"]["status"]
        if scenario == "cancel":
            assert fixture.model_seen.is_set() and status == "cancelled"
            assert result["context"]["history"] == []
            assert not (root / "late.txt").exists()
        else:
            assert (
                status == "completed"
                and result["outcome"]["result"]["status"] == "complete"
            ), result
        if scenario == "happy":
            assert result["outcome"]["result"]["turns"] == 7
            assert result["outcome"]["result"]["compactions"] == 1
            assert len(result["outcome"]["result"]["children"]) == 3
            assert [
                r["metadata"]["label"]
                for r in fixture.calls
                if r["metadata"]["label"] != "main"
            ] == ["summary", "questions", "answers"]
            assert any(
                m["kind"] == "summary" and m["role"] == "user"
                for m in result["context"]["history"]
            )
            assert "mkdir" in result["context"]["history"][1]["content"]
            replay_check(root, result)
            checks.append({"case": "completed-replay-and-binding", "verified": True})
        if scenario == "keys":
            assert (root / "control.txt").read_text() == "CONTROL_OK"
            assert not (root / "interrupted.txt").exists()
        if scenario == "truncated":
            assert (root / "safe.txt").read_text() == "SAFE"
            assert not (root / "truncated-was-executed").exists()
        if scenario in ("failed", "cancelled", "queued"):
            assert not (root / "non-completed-executed").exists()
        if scenario == "overflow-truncated":
            assert not (root / "overflow-truncated-executed").exists()
        if scenario in ("overflow", "overflow-truncated", "short", "screen", "unwind"):
            assert (root / "recovered.txt").read_text() == "live"
        if scenario == "unwind":
            assert result["outcome"]["result"]["compactions"] == 0
            assert not any(r["metadata"]["label"] != "main" for r in fixture.calls)
            assert len(result["context"]["history"]) > len(result["context"]["view"])
        checks.append(
            {"case": scenario, "verified": True, "requests": len(fixture.calls)}
        )
        print(f"PASS {scenario}", flush=True)
    (RUN / "results.json").write_text(json.dumps(checks, indent=2))
    (POINTERS / "latest-run.txt").write_text(str(RUN) + "\n")
    print(json.dumps({"run": str(RUN), "checks": checks}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        (POINTERS / "latest-failed-run.txt").write_text(str(RUN) + "\n")
        raise
