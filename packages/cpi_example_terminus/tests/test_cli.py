from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import gzip
import json
import os
import signal
import subprocess
import sys
import threading
import uuid

from test_support import configure_ghostmux_socket

BASE = Path(__file__).resolve().parent.parent
RUN = BASE / ".zig-cache" / "cli-runs" / uuid.uuid4().hex
RUN.mkdir(parents=True)
BINARY = Path(sys.argv[1]).resolve()
GHOSTMUX = str(Path(sys.argv[2]).resolve())
configure_ghostmux_socket(BASE)


def has_secret(data):
    if data.startswith(b"\x1f\x8b"):
        data = gzip.decompress(data)
    return b"synthetic-test-only" in data


assert has_secret(gzip.compress(b"synthetic-test-only"))


def action(keys=None, complete=False):
    return json.dumps(
        {
            "analysis": "a",
            "plan": "p",
            "commands": [] if keys is None else [{"keystrokes": keys, "duration": 0.1}],
            "task_complete": complete,
        }
    )


@contextmanager
def server(mode, scenario="normal", reasoning_effort=None):
    calls = []
    errors = []
    entered = threading.Event()
    release = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def do_POST(self):
            try:
                assert self.path == (
                    "/v1/responses" if mode == "live" else "/responses"
                )
                assert self.headers.get("Authorization") == (
                    "Bearer synthetic-test-only" if mode == "live" else None
                )
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                assert body["model"] == (
                    "synthetic-model" if mode == "live" else "fixture"
                )
                if mode == "live":
                    assert "metadata" not in body
                if reasoning_effort is None:
                    assert "reasoning" not in body
                else:
                    assert body["reasoning"] == {"effort": reasoning_effort}
                calls.append(body)
                entered.set()
                if scenario == "signal":
                    release.wait(5)
                n = len(calls)
                response_status = "completed"
                if (
                    scenario in ("large-output", "multi-megabyte-output")
                    and body["metadata"]["label"] != "main"
                ):
                    text = {
                        "summary": "The output command is running. Wait for its completion marker.",
                        "questions": "Has the terminal printed its completion marker?",
                        "answers": "Continue observing the terminal until the completion marker appears.",
                    }[body["metadata"]["label"]]
                elif scenario in ("compact", "overflow-truncated"):
                    label = body["metadata"]["label"]
                    call = body["metadata"]["call"]
                    if label == "summary":
                        text = "SUMMARY_RECEIPT"
                    elif label == "questions":
                        assert (
                            len(body["input"]) == 1
                            and "SUMMARY_RECEIPT" in body["input"][0]["content"]
                        )
                        text = "QUESTION_RECEIPT"
                    elif label == "answers":
                        assert body["input"][-2]["content"] == "SUMMARY_RECEIPT"
                        assert body["input"][-1]["content"].endswith("QUESTION_RECEIPT")
                        text = "ANSWER_RECEIPT"
                    else:
                        assert label == "main"
                        if call == 1:
                            text = action("printf compact-ok > compact.txt\n")
                        elif call == 2 and scenario == "overflow-truncated":
                            payload = json.dumps(
                                {"error": {"code": "context_length_exceeded"}}
                            ).encode()
                            self.send_response(400)
                            self.send_header("Content-Type", "application/json")
                            self.send_header("Content-Length", str(len(payload)))
                            self.end_headers()
                            self.wfile.write(payload)
                            return
                        elif call == 2 or (
                            scenario == "overflow-truncated" and call == 3
                        ):
                            assert "ANSWER_RECEIPT" in body["input"][-1]["content"]
                            if scenario == "overflow-truncated":
                                text = action("printf BAD > truncated-executed\n", True)
                                response_status = "incomplete"
                            else:
                                text = action(None, True)
                        elif scenario == "overflow-truncated" and call == 4:
                            assert "NONE of the actions" in body["input"][-1]["content"]
                            text = action(None, True)
                        else:
                            assert (
                                call == (5 if scenario == "overflow-truncated" else 3)
                                and "Are you sure" in body["input"][-1]["content"]
                            )
                            text = action(None, True)
                elif scenario == "budget":
                    text = action(None, True)
                elif scenario == "cleared-history":
                    command = "printf '\\033[H\\033[2J\\033[3J'; printf 'ERROR_\\122ETAINED\\n'; seq 1 300\n"
                    assert "ERROR_RETAINED" not in command
                    text = action(command, False) if n == 1 else action(None, True)
                    if n == 1:
                        parsed = json.loads(text)
                        parsed["commands"][0]["duration"] = 2.0
                        text = json.dumps(parsed)
                elif scenario == "blank-history":
                    command = "printf '\\033[H\\033[2J\\033[3J'; read -r reply; printf 'ERROR_\\122ETAINED\\n'; seq 1 300\n"
                    assert "ERROR_RETAINED" not in command
                    text = (
                        action(command if n == 1 else "\n", False)
                        if n <= 2
                        else action(None, True)
                    )
                    if n <= 2:
                        parsed = json.loads(text)
                        parsed["commands"][0]["duration"] = 2.0
                        text = json.dumps(parsed)
                elif scenario in ("large-output", "multi-megabyte-output"):
                    size, repeats = (
                        (700000, 2)
                        if scenario == "large-output"
                        else (2 * 1024 * 1024, 6)
                    )
                    command = f"yes {'0123456789abcdef' * repeats} | head -c {size}; printf 'BIG\\104ONE\\n'; printf complete > output.complete\n"
                    assert "BIGDONE" not in command
                    observed = n > 1 and "BIGDONE" in body["input"][-1]["content"]
                    confirmed = n > 1 and "Are you sure" in body["input"][-1]["content"]
                    text = (
                        action(command, False)
                        if n == 1
                        else action(
                            None if observed or confirmed else "", observed or confirmed
                        )
                    )
                    if n == 1 or not (observed or confirmed):
                        parsed = json.loads(text)
                        parsed["commands"][0]["duration"] = 2.0
                        text = json.dumps(parsed)
                elif scenario == "history":
                    if n <= 12:
                        command = (
                            'if [ -z "${OPENAI_API_KEY+x}" ]; then printf clean > secret-check; else printf leaked > secret-check; fi; printf worked > result.txt\n'
                            if n == 1
                            else f"printf 'stage-{n}\\n'\n"
                        )
                        parsed = json.loads(action(command, False))
                        parsed["analysis"] = "x" * 8000
                        text = json.dumps(parsed)
                    else:
                        assert n == 13 or (
                            n == 14 and "Are you sure" in body["input"][-1]["content"]
                        )
                        text = action(None, True)
                elif n == 1:
                    text = action(
                        'if [ -z "${OPENAI_API_KEY+x}" ]; then printf clean > secret-check; else printf leaked > secret-check; fi; printf worked > result.txt\n',
                        True,
                    )
                else:
                    assert "Are you sure" in body["input"][-1]["content"]
                    text = action(None, True)
                tokens = (
                    8100
                    if scenario == "compact"
                    and body["metadata"]["label"] == "main"
                    and body["metadata"]["call"] == 1
                    else 100
                )
                result = {
                    "id": "fixture",
                    "status": response_status,
                    "output": [
                        {
                            "type": "message",
                            "role": "assistant",
                            "content": [{"type": "output_text", "text": text}],
                        }
                    ],
                    "usage": {"input_tokens": tokens, "output_tokens": 10},
                }
                payload = json.dumps(result).encode()
                self.send_response(200)
            except Exception as exc:
                errors.append(repr(exc))
                payload = json.dumps({"error": {"code": "test_fixture"}}).encode()
                self.send_response(500)
            try:
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError):
                pass

    http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=http.serve_forever)
    thread.start()
    try:
        yield f"http://127.0.0.1:{http.server_port}", calls, errors, entered
    finally:
        release.set()
        http.shutdown()
        http.server_close()
        thread.join()


def run_case(mode, limit=False, reasoning_effort=None, scenario="normal"):
    case = mode + ("-limit" if limit else "")
    if reasoning_effort is not None:
        case += "-" + reasoning_effort
    if scenario != "normal":
        case += "-" + scenario
    root = RUN / case
    workspace = root / "workspace"
    workspace.mkdir(parents=True)
    state = root / "state"
    task_file = root / "task.txt"
    task_file.write_text("Write the requested output inside this workspace.\n")
    env = os.environ.copy()
    env["OPENAI_BASE_URL"] = "http://invalid-in-fixture.invalid"
    env["OPENAI_MODEL"] = "should-not-be-used"
    env["OPENAI_API_KEY"] = "synthetic-test-only"
    with server(mode, scenario, reasoning_effort=reasoning_effort) as (
        base,
        calls,
        errors,
        _,
    ):
        if mode == "live":
            env["OPENAI_BASE_URL"] = base + "/v1"
            env["OPENAI_MODEL"] = "synthetic-model"
        cmd = [
            str(BINARY),
            "--task-file",
            str(task_file),
            "--workspace",
            str(workspace),
            "--state-dir",
            str(state),
            "--ghostmux",
            GHOSTMUX,
            "--max-turns",
            "20" if scenario == "history" else "1" if limit else "4",
        ]
        cmd += ["--live"] if mode == "live" else ["--fixture-url", base]
        if reasoning_effort is not None:
            cmd += ["--reasoning-effort", reasoning_effort]
        process = subprocess.run(
            cmd, cwd=workspace, env=env, text=True, capture_output=True, timeout=90
        )
    (root / "stdout").write_text(process.stdout)
    (root / "stderr").write_text(process.stderr)
    (root / "requests.json").write_text(json.dumps(calls, indent=2))
    assert not errors, errors
    assert process.returncode == (1 if limit else 0), (
        process.returncode,
        process.stdout,
        process.stderr,
    )
    result = json.loads(process.stdout)
    assert result["worker_status"] == "completed"
    assert result["agent_status"] == ("limit" if limit else "complete")
    assert len(calls) == (14 if scenario == "history" else 1 if limit else 2)
    if scenario == "history":
        assert (
            sum("x" * 8000 in message["content"] for message in calls[-1]["input"])
            == 12
        )
    assert (workspace / "result.txt").read_text() == "worked"
    assert (workspace / "secret-check").read_text() == "clean"
    assert not (state / "result.txt").exists()
    assert state.stat().st_mode & 0o777 == 0o700
    for path in state.rglob("*"):
        if not path.is_file():
            continue
        assert not has_secret(path.read_bytes()), path
    return {
        "case": case,
        "requests": len(calls),
        "agent_status": result["agent_status"],
    }


def invalid_cases():
    root = RUN / "invalid"
    workspace = root / "workspace"
    workspace.mkdir(parents=True)
    base = [
        str(BINARY),
        "--task",
        "task",
        "--workspace",
        str(workspace),
        "--ghostmux",
        GHOSTMUX,
    ]
    p = subprocess.run(
        base
        + [
            "--state-dir",
            str(workspace / "state"),
            "--fixture-url",
            "http://127.0.0.1:1234",
        ],
        cwd=workspace,
        text=True,
        capture_output=True,
        timeout=10,
    )
    assert p.returncode != 0 and "StateInsideWorkspace" in p.stderr
    assert not (workspace / "state").exists()
    p = subprocess.run(
        base
        + [
            "--state-dir",
            str(root / "conflict"),
            "--fixture-url",
            "http://127.0.0.1:1234",
            "--live",
        ],
        cwd=workspace,
        text=True,
        capture_output=True,
        timeout=10,
    )
    assert p.returncode != 0 and "InvalidModelMode" in p.stderr
    assert not (root / "conflict").exists()
    p = subprocess.run(
        base
        + [
            "--state-dir",
            str(root / "bad-url"),
            "--fixture-url",
            "https://127.0.0.1:1234",
        ],
        cwd=workspace,
        text=True,
        capture_output=True,
        timeout=10,
    )
    assert p.returncode != 0 and "InvalidFixtureUrl" in p.stderr
    assert not (root / "bad-url").exists()
    return {"case": "invalid-cli-inputs"}


def stop_test_jobs(state):
    for job in (state / "processes").rglob("*.job"):
        uid = json.loads(job.read_text())["id"]
        stopped = subprocess.run(
            [
                GHOSTMUX,
                "-S",
                os.environ["CPI_GHOSTMUX_SOCKET"],
                "kill-session",
                "--uid",
                uid,
                "--json",
            ],
            text=True,
            capture_output=True,
            timeout=15,
        )
        assert stopped.returncode == 0 or any(
            name in stopped.stderr for name in ("UnknownUid", "SocketMissing")
        ), (stopped.returncode, stopped.stdout, stopped.stderr)


def review_case(scenario, sig=None):
    root = RUN / (scenario + (f"-{sig}" if sig else ""))
    workspace = root / "workspace"
    workspace.mkdir(parents=True)
    state = root / "state"
    with server("fixture", scenario) as (base, calls, errors, entered):
        cmd = [
            str(BINARY),
            "--task",
            "Synthetic terminal check.",
            "--workspace",
            str(workspace),
            "--state-dir",
            str(state),
            "--ghostmux",
            GHOSTMUX,
            "--fixture-url",
            base,
            "--max-turns",
            "10"
            if scenario in ("large-output", "multi-megabyte-output")
            else "4"
            if scenario == "blank-history"
            else "3",
        ]
        if scenario == "budget":
            cmd += [
                "--context-window",
                "100",
                "--reserve-tokens",
                "1",
                "--max-model-calls",
                "2",
            ]
        elif scenario == "compact":
            cmd += ["--context-window", "8192", "--reserve-tokens", "300"]
        proc = subprocess.Popen(
            cmd,
            cwd=workspace,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            if sig:
                assert entered.wait(20), "model request did not start"
                proc.send_signal(sig)
            stdout, stderr = proc.communicate(timeout=60)
        except BaseException:
            proc.kill()
            stdout, stderr = proc.communicate()
            (root / "stdout").write_text(stdout)
            (root / "stderr").write_text(stderr)
            (root / "requests.json").write_text(json.dumps(calls, indent=2))
            stop_test_jobs(state)
            raise
    (root / "stdout").write_text(stdout)
    (root / "stderr").write_text(stderr)
    (root / "requests.json").write_text(json.dumps(calls, indent=2))
    assert not errors, errors
    if scenario == "budget":
        assert proc.returncode != 0 and len(calls) == 2, (proc.returncode, len(calls))
        assert [c["metadata"]["label"] for c in calls] == ["main", "summary"]
        assert "ModelCallLimit" in stdout
    elif scenario in ("compact", "overflow-truncated"):
        result = json.loads(stdout)
        assert proc.returncode == 0 and result["result"]["compactions"] == 1
        assert (workspace / "compact.txt").read_text() == "compact-ok"
        expected = (
            ["main", "summary", "questions", "answers", "main", "main"]
            if scenario == "compact"
            else [
                "main",
                "main",
                "summary",
                "questions",
                "answers",
                "main",
                "main",
                "main",
            ]
        )
        assert [c["metadata"]["label"] for c in calls] == expected
        assert not (workspace / "truncated-executed").exists()
    elif scenario == "cleared-history":
        assert proc.returncode == 0 and len(calls) >= 2, (
            proc.returncode,
            stdout,
            stderr,
        )
        assert "ERROR_RETAINED" in calls[1]["input"][-1]["content"], calls[1]["input"][
            -1
        ]["content"]
        assert "could not be matched reliably" in calls[1]["input"][-1]["content"]
    elif scenario == "blank-history":
        assert proc.returncode == 0 and len(calls) >= 3, (
            proc.returncode,
            stdout,
            stderr,
        )
        assert "ERROR_RETAINED" in calls[2]["input"][-1]["content"], calls[2]["input"][
            -1
        ]["content"]
    elif scenario in ("large-output", "multi-megabyte-output"):
        assert proc.returncode == 0 and len(calls) >= 2, (
            proc.returncode,
            len(calls),
            stdout,
            stderr,
        )
        observations = [call["input"][-1]["content"] for call in calls[1:]]
        assert any("BIGDONE" in text for text in observations), observations
        assert json.loads(stdout)["agent_status"] == "complete", stdout
        assert (workspace / "output.complete").read_text() == "complete"
        assert any(
            "0123456789abcdef0123456789abcdef" in text
            and "interior bytes omitted" in text
            for text in observations
        ), observations
    elif scenario == "signal":
        assert proc.returncode != 0
        assert json.loads(stdout)["worker_status"] == "cancelled"
        jobs = list((state / "processes").rglob("*.job"))
        assert len(jobs) == 1
        uid = json.loads(jobs[0].read_text())["id"]
        status = json.loads(jobs[0].with_suffix(".status").read_text())["session"]
        capture = subprocess.run(
            [
                GHOSTMUX,
                "-S",
                os.environ["CPI_GHOSTMUX_SOCKET"],
                "capture-pane",
                "--uid",
                uid,
                "--history",
                "--join",
                "--json",
            ],
            text=True,
            capture_output=True,
            timeout=5,
        )
        try:
            assert (
                status["exit_code"] is not None
                and capture.returncode != 0
                and (
                    "UnknownUid" in capture.stderr or "SocketMissing" in capture.stderr
                )
            ), (status, capture.stdout, capture.stderr)
        finally:
            if capture.returncode == 0:
                subprocess.run(
                    [
                        GHOSTMUX,
                        "-S",
                        os.environ["CPI_GHOSTMUX_SOCKET"],
                        "signal-session",
                        "--uid",
                        uid,
                        "--signal",
                        "SIGKILL",
                    ],
                    capture_output=True,
                    timeout=5,
                )
    return {"case": scenario + (f"-{sig}" if sig else ""), "requests": len(calls)}


results = [
    invalid_cases(),
    run_case("fixture"),
    run_case("live"),
    run_case("live", reasoning_effort="medium"),
    run_case("fixture", scenario="history"),
    run_case("live", limit=True),
    review_case("compact"),
    review_case("overflow-truncated"),
    review_case("budget"),
    review_case("cleared-history"),
    review_case("blank-history"),
    review_case("large-output"),
    review_case("multi-megabyte-output"),
    review_case("signal", signal.SIGINT),
    review_case("signal", signal.SIGTERM),
]
(RUN / "results.json").write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps({"run": str(RUN), "checks": results}, indent=2))
