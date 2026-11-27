local op, caller, target = packet.operation, packet.caller, packet.target
if caller.id == 0 then
    for _, allowed in ipairs({"model.request", "process.spawn", "process.signal", "process.wait"}) do
        if op == allowed then return {allow = true} end
    end
    return {allow = false}
end
if op == "history.read" then return {allow = packet.scope_covered} end
if op == "agents.spawn" then return {allow = caller.spawn} end
if op == "agents.wait" then return {allow = target.owner == caller.id} end
if string.sub(op, 1, 8) == "process." then
    if not caller.terminal or (op ~= "process.spawn" and target.owner ~= caller.id) then return {allow = false} end
    for _, allowed in ipairs({"process.spawn", "process.write", "process.capture", "process.status", "process.read", "process.signal", "process.resize", "process.screenshot"}) do
        if op == allowed then return {allow = true} end
    end
    return {allow = false}
end
if string.sub(op, 1, 8) == "context." then return {allow = target.owner == caller.id} end
if op == "model.request" then return {allow = packet.application == true} end
for _, allowed in ipairs({"session.input", "codec.parse", "clock.now", "clock.sleep", "model.prepare", "model.generate", "model.info", "events.begin", "events.finish"}) do
    if op == allowed then return {allow = true} end
end
return {allow = false}
