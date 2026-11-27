import base64
import concurrent.futures
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest

import ctypes
import re

from cpi_services import ProcessService, ServiceError


class Cancelled(Exception):
    pass


class CancelToken:
    def __init__(self):
        self.event = threading.Event()
        self.lock = threading.Lock()
        self.callbacks = []

    def check(self):
        if self.event.is_set():
            raise Cancelled()

    def cancel(self):
        with self.lock:
            if self.event.is_set():
                return
            self.event.set()
            callbacks, self.callbacks = self.callbacks, []
        for callback in callbacks:
            callback()

    def on_cancel(self, callback):
        with self.lock:
            if not self.event.is_set():
                self.callbacks.append(callback)

                def remove():
                    with self.lock:
                        if callback in self.callbacks:
                            self.callbacks.remove(callback)

                return remove
        callback()

        def remove_set():
            return None

        return remove_set


class ProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cpi-services-")
        self.root = Path(self.temp.name)
        self.service = self.make_service("runtime")
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(self.service.close)

    def make_service(self, name):
        return ProcessService(
            self.root,
            self.root / name,
            binary=os.environ["CPI_SERVICES_BINARY"],
            ghostmux=os.environ["CPI_GHOSTMUX_BINARY"],
        )

    def call(self, endpoint, args=None, key=""):
        return self.service.dispatch(
            "process." + endpoint, args or {}, CancelToken(), key
        )

    def spawn(self, command, **options):
        return self.call("spawn", {"argv": ["/bin/sh", "-c", command], **options})

    def test_binary_output_nonzero_environment_cwd_and_retained_ranges(self):
        (self.root / "sub").mkdir()
        job = self.spawn(
            "printf '%s:%s:' \"$VALUE\" \"$PWD\"; printf '\\377\\000'; printf err >&2; exit 7",
            cwd="sub",
            env={"VALUE": "value"},
        )
        result = self.call("wait", {"id": job["id"], "wait_ms": 3000})
        expected = f"value:{self.root}/sub:".encode() + b"\xff\x00err"
        self.assertEqual(result["exit_code"], 7)
        self.assertEqual(base64.b64decode(result["base64"]), expected)
        self.assertEqual(Path(result["output_path"]).read_bytes(), expected)
        self.assertTrue(result["eof"])
        chunk = self.call("read", {"id": job["id"], "offset": 2, "limit": 3})
        self.assertEqual(base64.b64decode(chunk["base64"]), expected[2:5])
        self.assertEqual(chunk["next_offset"], 5)
        self.assertTrue(chunk["truncated"])

    def test_concurrent_spawn_deduplication_conflict_and_scope_isolation(self):
        args = {"argv": ["/bin/sh", "-c", "echo effect >> count; sleep 0.1"]}
        with concurrent.futures.ThreadPoolExecutor(4) as executor:
            results = list(
                executor.map(lambda _: self.call("spawn", args, "same"), range(4))
            )
        self.assertEqual(len({r["id"] for r in results}), 1)
        self.call("wait", {"id": results[0]["id"], "wait_ms": 3000})
        self.assertEqual((self.root / "count").read_text(), "effect\n")
        with self.assertRaises(ServiceError) as conflict:
            self.call("spawn", {"argv": ["true"]}, "same")
        self.assertEqual(conflict.exception.code, "RequestConflict")
        other = self.make_service("other")
        try:
            with self.assertRaises(ServiceError) as denied:
                other.dispatch(
                    "process.status", {"id": results[0]["id"]}, CancelToken()
                )
            self.assertEqual(denied.exception.code, "UnknownJob")
        finally:
            other.close()

    def test_pty_input_resize_capture_screenshot_and_group_signal(self):
        job = self.spawn(
            "printf READY; read answer; printf 'received:%s\\n' \"$answer\"; sleep 30",
            is_pty=True,
        )
        self.call("resize", {"id": job["id"], "columns": 100, "rows": 30})
        deadline = time.monotonic() + 5
        while "READY" not in self.call("capture", {"id": job["id"]})["text"]:
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.02)
        screenshot = self.call("screenshot", {"id": job["id"]})
        self.assertTrue(
            Path(screenshot["path"]).read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
        )
        self.call("write", {"id": job["id"], "data": "hello\n"})
        deadline = time.monotonic() + 5
        while "received:hello" not in self.call("capture", {"id": job["id"]})["text"]:
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.02)
        self.call("signal", {"id": job["id"], "signal": "SIGKILL"})
        done = self.call("wait", {"id": job["id"], "wait_ms": 3000})
        self.assertEqual(done["exit_code"], 137)

    def test_foreground_wait_background_detach_shutdown_and_reopen(self):
        owned = self.spawn("sleep 30")
        detached = self.spawn("sleep 30")
        running = self.call("wait", {"id": owned["id"], "wait_ms": 20})
        self.assertEqual(running["status"], "running")
        self.assertEqual(len(self.call("list")["jobs"]), 2)
        self.call("detach", {"id": detached["id"]})
        self.service.close()
        reopened = self.make_service("runtime")
        try:
            records = reopened.dispatch(
                "process.list", {"include_completed": True}, CancelToken()
            )["jobs"]
            by_id = {record["id"]: record for record in records}
            self.assertEqual(by_id[owned["id"]]["exit_code"], 137)
            self.assertEqual(by_id[detached["id"]]["status"], "detached")
            os.killpg(by_id[detached["id"]]["pid"], 9)
            reopened.dispatch(
                "process.wait", {"id": detached["id"], "wait_ms": 3000}, CancelToken()
            )
        finally:
            reopened.close()

    def test_repeat_stops_on_nonzero_and_bounds_each_invocation(self):
        job = self.call(
            "repeat",
            {
                "argv": [
                    "/bin/sh",
                    "-c",
                    "echo tick >> ticks; test $(wc -l < ticks) -lt 3",
                ],
                "interval_ms": 100,
            },
        )
        result = self.call("wait", {"id": job["id"], "wait_ms": 3000})
        self.assertEqual(result["exit_code"], 1)
        self.assertEqual((self.root / "ticks").read_text(), "tick\ntick\ntick\n")
        job = self.call(
            "repeat", {"argv": ["/bin/sh", "-c", "sleep 30"], "interval_ms": 100}
        )
        self.assertEqual(
            self.call("wait", {"id": job["id"], "wait_ms": 3000})["exit_code"], 124
        )

    def test_background_completion_events_are_available_without_provider_calls(self):
        job = self.spawn("while ! test -f released; do sleep 0.01; done; exit 6")
        self.assertEqual(
            self.call("wait", {"id": job["id"], "wait_ms": 0})["status"], "running"
        )
        (self.root / "released").write_text("")
        deadline = time.monotonic() + 5
        while True:
            events = self.service.poll_events()
            if events:
                break
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.02)
        self.assertEqual(events[0]["job"]["id"], job["id"])
        self.assertEqual(events[0]["job"]["exit_code"], 6)
        self.assertEqual(self.service.poll_events(), [])

    def test_cancellation_racing_wait_admission_stops_job_and_joins_caller(self):
        job = self.spawn("sleep 30")
        token = CancelToken()
        outcome = []

        def wait():
            try:
                self.service.dispatch(
                    "process.wait", {"id": job["id"], "wait_ms": 30000}, token
                )
            except Cancelled:
                outcome.append("cancelled")

        thread = threading.Thread(target=wait)
        thread.start()
        token.cancel()
        thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(outcome, ["cancelled"])
        self.assertEqual(
            self.call("wait", {"id": job["id"], "wait_ms": 3000})["exit_code"], 137
        )

    def test_shell_extension_endpoints_are_process_service_contracts(self):
        extensions = Path(__file__).resolve().parents[2] / "agent/extensions"
        declared = {"process.completed"}
        for path in extensions.glob("sh*.lua"):
            declared.update(
                re.findall(r'host\.call\(\s*["\']([^"\']+)', path.read_text())
            )
        self.assertEqual(declared - {"process.completed"} - set(self.service.endpoints), set())
        self.assertIn("process.spawn", self.service.endpoints)
        self.assertIn("process.capture", self.service.endpoints)

    def test_agent_foreign_boundary_reports_abi_v2_and_validates_registry(self):
        library = ctypes.CDLL(os.environ["CPI_AGENT_LIBRARY"])

        class Span(ctypes.Structure):
            _fields_ = [("ptr", ctypes.POINTER(ctypes.c_uint8)), ("len", ctypes.c_size_t)]

        def span(text):
            data = text.encode()
            return Span(ctypes.cast(ctypes.c_char_p(data), ctypes.POINTER(ctypes.c_uint8)), len(data))

        library.cpi_agent_abi_version.restype = ctypes.c_uint32
        self.assertEqual(library.cpi_agent_abi_version(), 2)
        handle = ctypes.c_void_p()
        self.assertEqual(library.cpi_agent_registry_create(2, ctypes.byref(handle)), 0)
        self.assertNotEqual(
            library.cpi_agent_registry_add_lua(handle, span("bad"), span("return {}")), 0
        )
        library.cpi_agent_registry_destroy(handle)


if __name__ == "__main__":
    unittest.main()
