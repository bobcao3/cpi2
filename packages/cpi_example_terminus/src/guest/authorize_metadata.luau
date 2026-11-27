local function metadata(event, state)
    local caller = if event.principal == 0 then {id=0, terminal=true, spawn=false}
        else (state.principals or {})[tostring(event.principal)]
    if not caller then return nil end
    local op, args = event.operation, event.arguments
    if op == "terminal.open" then op = "process.spawn" end
    local owner, covered = caller.id, false
    if args.target_session ~= nil then owner = args.target_session end
    if op == "history.read" then
        local snapshot = (state.snapshots or {})[tostring(args.snapshot)]
        if not snapshot then return nil end
        owner = snapshot.owner
        covered = owner == caller.id
        if not covered and caller.grant and caller.grant.snapshot == args.snapshot then
            covered = true
            for _, id in ipairs(args.ids) do
                local found = false
                for _, allowed in ipairs(caller.grant.ids) do if id == allowed then found = true; break end end
                if not found then covered = false end
            end
        end
    end
    if string.sub(op,1,8) == "process." and op ~= "process.spawn" then
        owner = -1
        for key, id in pairs(state.terminals or {}) do if id == args.id then owner = tonumber(key); break end end
        if caller.id == 0 then owner = 0 end
        if caller.application then owner = caller.id end
    end
    if op == "agents.wait" then owner = (state.children or {})[tostring(args.child)] or -1 end
    return {operation=op, caller=caller, target={owner=owner}, scope_covered=covered, application=caller.application == true}
end
