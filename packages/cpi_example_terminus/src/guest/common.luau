local rt = {}
function rt.call(op, args)
    if op == "process.spawn" then op = "terminal.open" end
    local dot = string.find(op, ".", 1, true)
    local name = if dot then string.sub(op, 1, dot - 1) .. "_" .. string.sub(op, dot + 1) else op
    return tools[name](args or {})
end
local handlers = {}
function rt.on(kind, handler) handlers[kind] = handler end
function rt.prepare(prompt)
    local event = rt.call("model.prepare", {prompt = prompt})
    local handler = handlers[event.kind]
    if not handler then return event end
    local ok, diagnostic = pcall(handler, event)
    rt.call("events.finish", {job = event.job})
    return {kind = "ready", handler_ok = ok, diagnostic = if ok then "" else tostring(diagnostic)}
end
function rt.array() return rt.call("codec.parse", {text = "[]"}).value end
function rt.decode(text) return rt.call("codec.parse", {text = text}) end
function rt.append(messages)
    local appended = rt.array()
    for _, message in ipairs(messages) do table.insert(appended, {role = message.role, content = message.content}) end
    return rt.call("context.append", {messages = appended})
end
function rt.read() return rt.call("context.read", {}) end
function rt.snapshot() return rt.call("context.snapshot", {}) end
function rt.ids(snapshot)
    local ids = rt.array()
    for _, group in ipairs(snapshot.data.groups) do table.insert(ids, group.id) end
    return ids
end
function rt.visible(state)
    local result = rt.array()
    for _, id in ipairs(state.view) do
        for _, message in ipairs(state.history) do
            if message.id == id then table.insert(result, message); break end
        end
    end
    return result
end
function rt.generate(prompt)
    return rt.call("model.generate", {prompt = prompt})
end
function rt.child(input, snapshot, ids, program)
    local request = {program = program or "once", input = input}
    if snapshot then request.snapshot = snapshot.id; request.ids = ids end
    local child = rt.call("agents.spawn", request)
    local result = rt.call("agents.wait", {child = child.child})
    if result.status ~= "completed" then error("child failed: " .. tostring(result.status)) end
    return result.result, result.child
end
function rt.trim(text)
    local first, last = 1, #text
    local function whitespace(b) return b == 32 or b == 9 or b == 10 or b == 13 or b == 11 or b == 12 end
    while first <= last and whitespace(string.byte(text, first)) do first += 1 end
    while last >= first and whitespace(string.byte(text, last)) do last -= 1 end
    return string.sub(text, first, last)
end
function rt.replace(text, key, value)
    local result, cursor = {}, 1
    while true do
        local first, last = string.find(text, key, cursor)
        if not first then table.insert(result, string.sub(text, cursor)); break end
        table.insert(result, string.sub(text, cursor, first - 1)); table.insert(result, value)
        cursor = last + 1
    end
    return table.concat(result)
end
