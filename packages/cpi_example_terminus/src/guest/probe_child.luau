local input = rt.call("session.input", {})
local allowed = rt.call("history.read", {snapshot = input.snapshot, ids = {input.allowed_id}})
local wider = pcall(function() rt.call("history.read", {snapshot = input.snapshot, ids = {input.allowed_id, input.forbidden_id}}) end)
local other = pcall(function() rt.call("history.read", {snapshot = input.other_snapshot, ids = {1}}) end)
local empty = rt.call("history.read", {snapshot = input.snapshot, ids = rt.array()})
local write, write_error = pcall(function() rt.call("context.commit", {target_session = input.parent, snapshot = input.other_snapshot,
    selected = {input.write_id}, replacement = rt.array()}) end)
local mismatch, mismatch_error = pcall(function() rt.call("clock.sleep", {ms = 0, caller = {id = input.parent}}) end)
local terminal = if input.terminal then pcall(function() rt.call("process.capture", {id = input.terminal}) end) else nil
local terminal_spawn = pcall(function() rt.call("process.spawn", {argv = {"/usr/bin/touch", "unauthorized-process"}, is_pty = true}) end)
local spawn = pcall(function() rt.call("agents.spawn", {program = "once", input = {label = "forged"}}) end)
local begin = pcall(function() rt.call("events.begin", {}) end)
rt.append(allowed)
local pressure = rt.call("model.prepare", {prompt = input.prompt})
assert(pressure.kind == "ready")
local response = rt.generate(input.prompt)
assert(response.ok)
return {allowed_read = #allowed == 1 and allowed[1].content == "old-a", wider_denied = not wider,
    other_snapshot_denied = not other, empty_is_empty = #empty == 0, parent_write_denied = not write and string.find(tostring(write_error), "PermissionDenied") ~= nil,
    contract_mismatch_denied = not mismatch and string.find(tostring(mismatch_error), "InvalidSchema") ~= nil,
    terminal_denied = if input.terminal then not terminal else nil, terminal_spawn_denied = not terminal_spawn, spawn_denied = not spawn, recursive_trigger_denied = not begin, model = response.text}
