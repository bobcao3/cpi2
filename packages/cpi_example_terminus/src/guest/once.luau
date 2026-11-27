local input = rt.call("session.input", {})
if input.snapshot then
    local groups = rt.call("history.read", {snapshot = input.snapshot, ids = input.ids})
    if #groups > 0 then rt.append(groups) end
end
if input.extra and #input.extra > 0 then rt.append(input.extra) end
local event = rt.call("model.prepare", {prompt = input.prompt})
assert(event.kind == "ready", "one-completion worker must not start a recursive compaction")
local response = rt.generate(input.prompt)
if not response.ok then error("model failure: " .. tostring(response.error)) end
if response.finish_reason ~= "completed" then error("incomplete one-completion response") end
return {text = response.text, usage = response.usage, finish_reason = response.finish_reason, snapshot = input.snapshot}
