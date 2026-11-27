from contextlib import suppress
import hashlib
import json
import logging
import os
import collections
from pathlib import Path
import signal
import subprocess
import threading
import time
import uuid

from .errors import ServiceError


log = logging.getLogger(__name__)


class ProcessService:
    endpoints = tuple(
        "process." + name
        for name in (
            "spawn",
            "repeat",
            "status",
            "list",
            "read",
            "wait",
            "write",
            "signal",
            "resize",
            "capture",
            "screenshot",
            "detach",
        )
    )

    def __init__(self, workspace, directory, *, binary=None, ghostmux=None):
        root = Path(__file__).resolve().parents[4]
        self.workspace = str(Path(workspace).resolve())
        self.directory = str(Path(directory).absolute())
        self.binary = str(
            Path(
                binary
                or os.environ.get("CPI_SERVICES_BINARY")
                or root / "zig-out/bin/cpi-services"
            ).resolve()
        )
        self.ghostmux = str(
            Path(
                ghostmux
                or os.environ.get("CPI_GHOSTMUX_BINARY")
                or root / "zig-out/bin/ghostmux"
            ).resolve()
        )
        self.closed = False
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._jobs = set()
        self._events = collections.deque()
        self._monitor = None

    def _observe(self, endpoint, arguments, result):
        job = result.get("id")
        if job is None:
            return
        with self._lock:
            finished = result.get("exit_code") is not None
            detached = result.get("detached", False)
            killed = endpoint == "process.signal" and arguments.get("signal") in (
                "SIGKILL",
                "9",
            )
            if finished or detached or killed:
                self._jobs.discard(job)
                self._events = collections.deque(
                    e
                    for e in self._events
                    if e["type"] != "process.completed" or e["job"]["id"] != job
                )
            elif (
                endpoint in ("process.spawn", "process.repeat", "process.wait")
                and result.get("status") == "running"
            ):
                self._jobs.add(job)
                if self._monitor is None:
                    self._monitor = threading.Thread(
                        target=self._watch, name="cpi-process-events", daemon=True
                    )
                    self._monitor.start()

    def _watch(self):
        while not self._stop.wait(0.1):
            with self._lock:
                jobs = tuple(self._jobs)
            if not jobs:
                continue
            try:
                statuses = self._invoke("process.list", {"include_completed": True})[
                    "jobs"
                ]
            except (ServiceError, OSError):
                continue
            with self._lock:
                for job in statuses:
                    if job["id"] in self._jobs and job.get("exit_code") is not None:
                        self._jobs.remove(job["id"])
                        self._events.append(
                            {
                                "id": "process:" + job["id"],
                                "type": "process.completed",
                                "job": job,
                            }
                        )

    def poll_events(self):
        with self._lock:
            events = list(self._events)
            self._events.clear()
            return events

    def _report_size(self, warning):
        event = {**warning, "id": "size:" + uuid.uuid4().hex, "type": "size_warning"}
        with self._lock:
            self._events.append(event)
        with suppress(Exception):
            log.warning(
                "%s %s is %d, above the expected %d",
                event["operation"],
                event["measurement"],
                event["actual"],
                event["threshold"],
            )

    def _invoke(self, endpoint, arguments, key="", token=None):
        data = json.dumps(
            {"endpoint": endpoint, "arguments": arguments, "idempotency_key": key},
            allow_nan=False,
        ).encode()
        process = subprocess.Popen(
            [self.binary, self.workspace, self.directory, self.ghostmux],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        deadline = time.monotonic() + 50
        try:
            first = True
            while True:
                if token is not None:
                    token.check()
                if time.monotonic() >= deadline:
                    raise ServiceError("timeout", "Service request timed out")
                try:
                    output, errors = process.communicate(
                        data if first else None, timeout=0.05
                    )
                    break
                except subprocess.TimeoutExpired:
                    first = False
            if token is not None:
                token.check()
            if process.returncode:
                raise ServiceError(
                    "service_failed", errors.decode("utf-8", "replace")[:4096]
                )
            envelope = json.loads(output)
            warnings = envelope.get("size_warnings", ())
            for warning in warnings:
                self._report_size(warning)
            for measurement, size, threshold in (
                ("request bytes", len(data), 1048576),
                ("response bytes", len(output), 8388608),
            ):
                if size <= threshold:
                    continue
                if any(
                    w["measurement"] == measurement and w["operation"] == "cpi-services"
                    for w in warnings
                ):
                    continue
                self._report_size(
                    {
                        "operation": "cpi-services",
                        "measurement": measurement,
                        "actual": size,
                        "threshold": threshold,
                        "request_id": "",
                        "principal": 0,
                    }
                )
            if "error" in envelope:
                error = envelope["error"]
                raise ServiceError(error["code"], error["message"])
            return envelope["result"]
        finally:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.communicate()

    def dispatch(self, endpoint, arguments, token, idempotency_key=""):
        if self.closed:
            raise ServiceError("service_closed", "Process service is closed")
        key = idempotency_key or uuid.uuid4().hex
        try:
            token.check()
            result = self._invoke(endpoint, arguments, key, token)
            self._observe(endpoint, arguments, result)
            return result
        except Exception:
            if token.event.is_set() and endpoint in (
                "process.spawn",
                "process.repeat",
                "process.wait",
            ):
                job = (
                    hashlib.sha256(key.encode()).hexdigest()
                    if endpoint in ("process.spawn", "process.repeat")
                    else arguments.get("id")
                )
                try:
                    self._invoke("process.signal", {"id": job, "signal": "SIGKILL"})
                except (ServiceError, OSError):
                    pass
            raise

    def close(self):
        if self.closed:
            return
        self._stop.set()
        if self._monitor is not None:
            self._monitor.join()
        try:
            for job in self._invoke("process.list", {}).get("jobs", []):
                try:
                    self._invoke(
                        "process.signal", {"id": job["id"], "signal": "SIGKILL"}
                    )
                    self._invoke("process.wait", {"id": job["id"], "wait_ms": 3000})
                except (ServiceError, OSError):
                    pass
        finally:
            self.closed = True
