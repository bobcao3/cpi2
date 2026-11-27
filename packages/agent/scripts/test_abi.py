import copy
import ctypes as C
import json
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from session_reference import encode, runtime_state, command_records, fixture_frames


class Span(C.Structure):
    _fields_ = [("ptr", C.c_void_p), ("len", C.c_size_t)]


class Config(C.Structure):
    _fields_ = [("size", C.c_uint32), ("abi", C.c_uint32), ("session", Span), ("workspace", Span), ("journal", Span), ("options", Span)]


class Command(C.Structure):
    _fields_ = [("size", C.c_uint32), ("kind", C.c_uint32), ("identity", Span), ("payload", Span)]


class Event(C.Structure):
    _fields_ = [("size", C.c_uint32), ("kind", C.c_uint32), ("lease", C.c_uint64), ("operation", C.c_uint64), ("sequence", C.c_uint64), ("identity", Span), ("method", Span), ("json", Span)]


def span(text):
    data = text.encode() if isinstance(text, str) else text
    value = Span(C.cast(C.c_char_p(data), C.c_void_p), len(data))
    value._data = data
    return value


def raw(value):
    return C.string_at(value.ptr, value.len)


library_path = str(Path(sys.argv[1]).resolve())
lib = C.CDLL(library_path)
for name, args in {
    "registry_create": [C.c_uint32, C.POINTER(C.c_void_p)],
    "registry_add_lua": [C.c_void_p, Span, Span],
    "registry_destroy": [C.c_void_p],
    "open": [C.c_void_p, C.POINTER(Config), C.POINTER(C.c_void_p)],
    "send": [C.c_void_p, C.POINTER(Command)],
    "next_event": [C.c_void_p, C.POINTER(Event)],
    "event_release": [C.c_void_p, C.c_uint64],
    "io_feed": [C.c_void_p, C.c_uint64, C.c_uint32, Span],
    "destroy": [C.c_void_p],
}.items():
    getattr(lib, "cpi_agent_" + name).argtypes = args
assert lib.cpi_agent_abi_version() == 2


def next_event(handle, wanted, no_io=False):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        event = Event(size=C.sizeof(Event))
        status = lib.cpi_agent_next_event(handle, C.byref(event))
        assert status in (0, 1), status
        if status == 0:
            if no_io and event.kind == 2:
                lib.cpi_agent_io_feed(handle, event.operation, 5, span("{}"))
                lib.cpi_agent_event_release(handle, event.lease)
                raise AssertionError("interrupted effect was dispatched again")
            if event.kind == wanted:
                return event
            assert lib.cpi_agent_event_release(handle, event.lease) == 0
        else:
            time.sleep(0.001)
    raise AssertionError(("event timeout", wanted))


def send(handle, identity, kind, payload):
    command = Command(C.sizeof(Command), kind, span(identity), span(json.dumps(payload)))
    assert lib.cpi_agent_send(handle, C.byref(command)) == 0


def open_session(path, registry=None, invalid=False):
    config = Config(C.sizeof(Config), 2, span("abi"), span(str(path.parent)), span(str(path)), span("{}"))
    handle = C.c_void_p()
    if invalid:
        config.abi = 99
        assert lib.cpi_agent_open(registry, C.byref(config), C.byref(handle)) == 3
        assert not handle.value
        config.abi = 2
        config.options = span("[]")
        assert lib.cpi_agent_open(registry, C.byref(config), C.byref(handle)) != 0
        assert not handle.value
        config.options = span("{}")
    assert lib.cpi_agent_open(registry, C.byref(config), C.byref(handle)) == 0
    return handle


if len(sys.argv) > 2:
    path = Path(sys.argv[2])
    registry = C.c_void_p()
    assert lib.cpi_agent_registry_create(2, C.byref(registry)) == 0
    source = 'return {name="effect",version=1,description="Effect",parameters={type="object",properties={},additionalProperties=false},endpoints={"test.effect"},recovery="never",execute=function(args) return host.call("test.effect",args) end}'
    assert lib.cpi_agent_registry_add_lua(registry, span("effect.lua"), span(source)) == 0
    config = Config(C.sizeof(Config), 2, span("abi"), span(str(path.parent)), span(str(path)), span('{"endpoint_grants":["test.effect"]}'))
    handle = C.c_void_p()
    assert lib.cpi_agent_open(registry, C.byref(config), C.byref(handle)) == 0
    send(handle, "crash-effect", 4, {"source": "ctx.before=73; return tools.effect({})"})
    event = next_event(handle, 2)
    assert raw(event.method) == b"rpc.call"
    with (path.parent / "effect-marker").open("a") as marker:
        marker.write("once\n")
        marker.flush()
        os.fsync(marker.fileno())
    os._exit(0)


with tempfile.TemporaryDirectory(prefix="cpi-abi-") as temporary:
    root = Path(temporary)
    for index, identity in enumerate((b"\xff", b"session\xc0\xaf")):
        path = root / f"invalid-identity-{index}.gz"
        config = Config(C.sizeof(Config), 2, span(identity), span(str(root)), span(str(path)), span("{}"))
        rejected = C.c_void_p()
        status = lib.cpi_agent_open(None, C.byref(config), C.byref(rejected))
        if rejected.value:
            lib.cpi_agent_destroy(rejected)
        assert status == 2, ("invalid UTF-8 session accepted", status)
        assert not path.exists(), "invalid identity created a journal"
    handle = open_session(root / "lease.gz", invalid=True)
    try:
        invalid = Command(C.sizeof(Command), 4, span(b"\xff"), span('{"source":"return 1"}'))
        assert lib.cpi_agent_send(handle, C.byref(invalid)) == 2
        ready = next_event(handle, 1)
        frozen = (raw(ready.json), raw(ready.identity), raw(ready.method))
        send(handle, "input", 1, {"content": "hello"})
        pending = next_event(handle, 2)
        packet = raw(pending.json)
        response = json.dumps({"status": 200, "body": {"object": "response", "status": "completed", "model": "fixture", "output": [{"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "ABI-OK"}]}]}})
        operation = pending.operation
        assert lib.cpi_agent_io_feed(handle, operation, 3, span(response)) == 0
        assert raw(pending.json) == packet
        assert (raw(ready.json), raw(ready.identity), raw(ready.method)) == frozen
        assert lib.cpi_agent_io_feed(handle, operation, 3, span(response)) == 11
        assert lib.cpi_agent_event_release(handle, pending.lease) == 0
        assert lib.cpi_agent_event_release(handle, pending.lease) == 12
        finished = next_event(handle, 5)
        assert json.loads(raw(finished.json))["status"] == "completed"
        assert lib.cpi_agent_event_release(handle, finished.lease) == 0
        assert raw(ready.json) == frozen[0]
        assert lib.cpi_agent_event_release(handle, ready.lease) == 0
        errors = []
        def handoff():
            try:
                send(handle, "thread", 4, {"source": "return 29"})
                result = next_event(handle, 5)
                assert json.loads(raw(result.json))["result"] == 29
                assert lib.cpi_agent_event_release(handle, result.lease) == 0
            except BaseException as error:
                errors.append(error)
        thread = threading.Thread(target=handoff)
        thread.start()
        thread.join(10)
        assert not thread.is_alive()
        assert not errors, errors
        send(handle, "close", 5, {})
        closed = next_event(handle, 5)
        assert lib.cpi_agent_event_release(handle, closed.lease) == 0
    finally:
        lib.cpi_agent_destroy(handle)
    snapshot = runtime_state(root / "lease.gz")
    assert isinstance(snapshot["capabilities"], list)
    assert isinstance(snapshot["capabilities_revision"], int)
    assert "tools" not in snapshot and "registry_revision" not in snapshot
    for field, old_field in (("capabilities", "tools"), ("capabilities_revision", "registry_revision")):
        for retain_current in (False, True):
            rejected_snapshot = copy.deepcopy(snapshot)
            rejected_snapshot[old_field] = rejected_snapshot[field]
            if not retain_current:
                del rejected_snapshot[field]
            path = root / f"rejected-{old_field}-{retain_current}.gz"
            original = encode(fixture_frames("abi", rejected_snapshot))
            path.write_bytes(original)
            config = Config(C.sizeof(Config), 2, span("abi"), span(str(root)), span(str(path)), span("{}"))
            rejected = C.c_void_p()
            status = lib.cpi_agent_open(None, C.byref(config), C.byref(rejected))
            if rejected.value:
                lib.cpi_agent_destroy(rejected)
            assert status == 14, ("invalid journal schema accepted", old_field, status)
            assert not rejected.value
            assert path.read_bytes() == original, "invalid journal was rewritten"
    for slot in ("active", "suspended"):
        for field, old_field in (("capabilities", "tools"), ("capabilities_revision", "registry_revision")):
            for retain_current in (False, True):
                rejected_snapshot = copy.deepcopy(snapshot)
                run = {"id": "run", "kind": 4, "phase": "lua", "capabilities": [], "capabilities_revision": 0}
                run[old_field] = run[field]
                if not retain_current:
                    del run[field]
                rejected_snapshot[slot] = run
                path = root / f"rejected-{slot}-{old_field}-{retain_current}.gz"
                original = encode(fixture_frames("abi", rejected_snapshot))
                path.write_bytes(original)
                config = Config(C.sizeof(Config), 2, span("abi"), span(str(root)), span(str(path)), span("{}"))
                rejected = C.c_void_p()
                status = lib.cpi_agent_open(None, C.byref(config), C.byref(rejected))
                if rejected.value:
                    lib.cpi_agent_destroy(rejected)
                assert status == 14, ("invalid run schema accepted", slot, old_field, status)
                assert not rejected.value
                assert path.read_bytes() == original
    crash_path = root / "crash.gz"
    subprocess.run([sys.executable, __file__, library_path, str(crash_path)], check=True, timeout=12)
    handle = open_session(crash_path)
    try:
        snapshot = runtime_state(crash_path)
        assert snapshot["ctx"]["before"] == 73
        interrupted = [item for item in command_records(crash_path) if item["id"] == "crash-effect"]
        assert interrupted[0]["status"] == "failed", interrupted
        send(handle, "verify", 4, {"source": "return ctx.before"})
        result = next_event(handle, 5, no_io=True)
        assert json.loads(raw(result.json))["result"] == 73
        assert lib.cpi_agent_event_release(handle, result.lease) == 0
        assert (root / "effect-marker").read_text() == "once\n"
        for _ in range(20):
            event = Event(size=C.sizeof(Event))
            status = lib.cpi_agent_next_event(handle, C.byref(event))
            if status == 1:
                break
            assert status == 0 and event.kind != 2
            assert lib.cpi_agent_event_release(handle, event.lease) == 0
    finally:
        lib.cpi_agent_destroy(handle)
print("ABI leases, validation, synchronized thread handoff and real crash no-replay passed")
