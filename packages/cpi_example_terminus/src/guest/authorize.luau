return function(event, state)
    if event.kind == "command" and (event.operation == "register_capability" or event.operation == "unregister_capability") then return {allow=event.principal ~= 0} end
    local packet = metadata(event, state)
    if not packet then return {allow=false} end
    if event.kind == "command" then return {allow=(event.operation == "lua" or event.operation == "deliver" or event.operation == "cancel_invocation") and event.principal ~= 0} end
    if event.kind == "snapshot" then return {allow=event.operation == "context" and event.principal ~= 0} end
    if event.principal ~= 0 then
        local op, caller = packet.operation, packet.caller
        if op == "history.read" and not packet.scope_covered then return {allow=false} end
        if op == "agents.spawn" and not caller.spawn then return {allow=false} end
        if op == "agents.wait" and packet.target.owner ~= caller.id then return {allow=false} end
        if string.sub(op,1,8) == "context." and packet.target.owner ~= caller.id then return {allow=false} end
        if string.sub(op,1,8) == "process." and
            (not caller.terminal or (op ~= "process.spawn" and packet.target.owner ~= caller.id)) then return {allow=false} end
    end
    local decision = applicationPolicy(packet)
    if event.principal == 0 and type(decision) == "table" and decision.operation and decision.operation ~= event.operation then
        return {allow=false}
    end
    return decision
end
