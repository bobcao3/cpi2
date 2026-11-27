local input = rt.call("session.input", {})
local nested = rt.decode(string.rep("[", 65) .. "0" .. string.rep("]", 65))
assert(not nested.ok and nested.error == "JsonDepthLimit")
assert(not rt.decode("}").ok)
assert(rt.read().history[1].content == "protected-prefix")
rt.append({{role = "user", content = "old-a"}, {role = "assistant", content = "old-b"}})
local base = rt.snapshot()
rt.append({{role = "user", content = "new-tail"}})
local edit = {snapshot = base.id, selected = {2, 3}, replacement = {{role = "user", content = "derived-handoff"}}}
local committed = rt.call("context.commit", edit)
local stale_ok = pcall(function() rt.call("context.commit", edit) end)
local protected_ok = pcall(function() rt.call("context.commit", {snapshot = base.id, selected = {1}, replacement = rt.array()}) end)
ctx.control = {canonical = {history = {{role = "system", content = "guest-forged"}}}}
local unchanged = rt.read()
local second = rt.snapshot()
local terminal = nil
if not input.without_terminal then
    local bad_spawn, bad_spawn_error = pcall(function() rt.call("process.spawn", {argv = rt.array(), is_pty = true}) end)
    assert(not bad_spawn and string.find(tostring(bad_spawn_error), "InvalidArguments"))
    terminal = rt.call("process.spawn", {argv = {"/bin/bash", "--noprofile", "--norc", "-i"}, is_pty = true, description = "ACL probe terminal"})
    local detached = pcall(function() rt.call("process.detach", {id = terminal.id}) end)
    assert(not detached)
end
local pressure = rt.call("model.prepare", {prompt = string.rep("pressure", 5000)})
assert(pressure.kind == "context_near_full")
local coalesced = rt.call("events.begin", {})
assert(coalesced.job == pressure.job and coalesced.coalesced)
local child, child_id = rt.child({label = "probe_child", parent = base.owner, snapshot = base.id, other_snapshot = second.id,
    allowed_id = 2, forbidden_id = 3, write_id = 5, terminal = if terminal then terminal.id else nil, prompt = string.rep("pressure", 5000)}, base, {2}, "probe_child")
assert(rt.read().history[5].content == "derived-handoff")
rt.call("events.finish", {job = pressure.job})
local spawn_root_ok = pcall(function() rt.call("agents.spawn", {program = "terminus", input = {task = "forbidden widening"}}) end)
return {status = "complete", stale_denied = not stale_ok, protected_denied = not protected_ok,
    canonical_not_guest_owned = unchanged.history[1].content == "protected-prefix",
    tail_preserved = committed.view[3] == 4, original_history_retained = #committed.history == 5,
    projection = committed.view, child = child, child_id = child_id, widening_denied = not spawn_root_ok}
