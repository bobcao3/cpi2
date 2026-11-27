-- Pi 1.6.1 script result framing, adapted to the Luau application VM.
local function scriptFailure(message, calls)
    if #calls == 0 then
        return 'Script error:\n' .. message
    end
    local summary = {}
    for i, call in ipairs(calls) do summary[i] = call.name .. ' (' .. call.status .. ')' end
    return 'Script error:\n' .. message .. '\n\nTool calls made before the failure (they are not undone): ' .. table.concat(summary, ', ')
end
local function scriptFrame(ok, text, details)
    local header = string.format('%s\nWall time %.1f seconds\nOutput:\n',
        if ok then 'Script completed' else 'Script failed', details.durationMs / 1000)
    return {content={{type='text', text=header .. text}}, details=details, isError=not ok}
end
local function interruptedScript(record, callId, message, at)
    if type(record) ~= 'table' or record.call_id ~= callId or type(at) ~= 'number' then return nil end
    local calls = agent.decode('[]')
    for i, call in ipairs(record.calls) do
        calls[i] = table.clone(call)
        if call.status == 'running' then calls[i].status = 'cancelled' end
    end
    return scriptFrame(false, scriptFailure(message, calls), {
        codemode=true, calls=calls, durationMs=math.max(0, at - record.started),
    })
end

local function captureLuaScript(source, discovery, parentId)
    local started = agent.now()
    local calls = agent.decode('[]')
    local textItems, consoleLines = {}, {}
    local stopped = {}
    local pending, deleted = {}, {}
    local bytes, count = 0, 0
    local maxTokens = 10000

    local function preview(value, limit)
        if not utf8.len(value) then return '' end
        local units, cut = 0, #value + 1
        for at, cp in utf8.codes(value) do
            units += if cp > 65535 then 2 else 1
            if units > limit - 3 and cut > #value then cut = at end
            if units > limit then return string.sub(value, 1, cut - 1) .. '...' end
        end
        return value
    end
    local function publish(index, record)
        agent.progress({kind='tool_update', call_id=parentId, data={index=index, call=record}})
    end
    local function track(name, tool)
        return function(...)
            local args = select(1, ...)
            local encoded, arguments = pcall(agent.encode, args)
            local index = #calls + 1
            local record = {id=parentId .. '/' .. index, name=name,
                args=if args ~= nil and encoded then preview(arguments, 200) else '', status='running'}
            calls[index] = record
            publish(index, record)
            local callStarted = agent.now()
            local reply = table.pack(pcall(tool, ...))
            local value = reply[2]
            local finished = agent.now()
            record.durationMs = math.max(0, finished - callStarted)
            local failed = not reply[1] or (type(value) == 'table' and rawget(value, 'isError') == true)
            record.status = if failed then 'error' else 'ok'
            if failed then
                local describe = if not reply[1] then tostring else modelToolText
                local described, message = pcall(describe, value, true)
                if not described or message == '' then message = 'Tool "' .. name .. '" failed' end
                record.error = preview(message, 500)
            end
            publish(index, record)
            if not reply[1] then error(value, 0) end
            return table.unpack(reply, 2, reply.n)
        end
    end

    local function valueText(value)
        return if type(value) == 'string' then value else agent.encode(value)
    end
    local function append(items, value)
        count += 1
        bytes += #value
        if count > 100000 or bytes > 16777216 then error('Script output exceeds the output limit.', 0) end
        -- Validate text before accepting it so a later failure keeps valid partial output.
        if not utf8.len(value) then error('Script output must be UTF-8 text.', 0) end
        table.insert(items, value)
    end
    local function log(...)
        local fields = {}
        for i=1,select('#', ...) do fields[i] = valueText((select(i, ...))) end
        append(consoleLines, table.concat(fields, ' '))
    end
    local function store(key, value)
        if type(key) ~= 'string' then error('store() expects a string key', 0) end
        if value == nil then pending[key], deleted[key] = nil, true; return end
        local encoded = agent.encode(value)
        if #encoded > 262144 then error('store() value exceeds 262144 bytes', 0) end
        pending[key], deleted[key] = encoded, nil
    end
    local function load(key)
        if type(key) ~= 'string' then error('load() expects a string key', 0) end
        if deleted[key] then return nil end
        local prior = (ctx.codemode_store or {})[key]
        if pending[key] ~= nil then return agent.decode(pending[key]) end
        if prior ~= nil then return agent.decode(agent.encode(prior)) end
        return nil
    end
    local globals = {
        tools=discovery.startScript(track),
        agent=false, ctx=false, input=false, options=false, output=false,
        text=function(value) append(textItems, valueText(value)) end,
        image=function(part)
            if type(part) == 'table' and part.image_url ~= nil then part = part.image_url end
            if type(part) == 'string' then
                local first, last = string.find(part, ';base64,')
                if string.sub(part, 1, 5) ~= 'data:' or first == nil then error('image() expects a base64 data URL', 0) end
                part = {mime_type=string.sub(part, 6, first - 1), data_base64=string.sub(part, last + 1)}
            end
            if type(part) ~= 'table' then error('image() expects an image block', 0) end
            local data = part.data or part.data_base64
            if type(data) ~= 'string' then error('image() expects base64 image data', 0) end
            count += 1
            bytes += #data
            if count > 100000 or bytes > 16777216 then error('Script output exceeds the output limit.', 0) end
            output.image({mime_type=part.mimeType or part.mime_type, data_base64=data})
        end,
        console=table.freeze({log=log, info=log, warn=log, error=log, debug=log}),
        exit=function() error(stopped, 0) end,
        store=store, load=load,
        searchTools=discovery.search, describeTool=discovery.describe, describeNamespace=discovery.namespace,
    }
    local captured = agent.capture(function()
        ctx.__capture.script = {call_id=parentId, started=started, calls=calls}
        if type(source) ~= 'string' then error('execute_lua requires source', 0) end
        local prefix = '-- @options: '
        if string.sub(source, 1, #prefix) == prefix then
            local stop = string.find(source, '\n') or #source + 1
            local settings = agent.decode(string.sub(source, #prefix + 1, stop - 1))
            agent.validate(settings, {type='object', properties={max_output_tokens={type='integer', minimum=1, maximum=10000}},
                additionalProperties=false}, 'script options')
            maxTokens = settings.max_output_tokens or maxTokens
        end
        -- Host calls can suspend, so materialize before evaluation rather than
        -- trying to discover tools inside a Luau __index metamethod.
        if string.find(source, 'ALL_TOOLS') then globals.ALL_TOOLS = discovery.all() end
        local ok, value = pcall(agent.evaluate, source, globals)
        if not ok and not rawequal(value, stopped) then error(value, 0) end
        if ok and value ~= nil then append(textItems, valueText(value)) end
        if next(pending) ~= nil or next(deleted) ~= nil then
            local saved = table.clone(ctx.codemode_store or {})
            for key in pairs(deleted) do saved[key] = nil end
            for key, encoded in pairs(pending) do saved[key] = agent.decode(encoded) end
            if #agent.encode(saved) > 1048576 then error('Script store exceeds 1048576 bytes', 0) end
            ctx.codemode_store = saved
        end
    end)
    local parts = {}
    for index, value in ipairs(textItems) do
        table.insert(parts, if #textItems > 1 then string.format('==> text %d/%d <==\n%s', index, #textItems, value) else value)
    end
    if #consoleLines > 0 then table.insert(parts, '<console_output>\n' .. table.concat(consoleLines, '\n') .. '\n</console_output>') end
    if not captured.ok then table.insert(parts, scriptFailure(captured.error, calls)) end
    local function saveOutput(mime, data)
        local ok, value = pcall(discovery.saveOutput, {mime_type=mime, data=data})
        if not ok then return nil, tostring(value) end
        if type(value.path) ~= 'string' then return nil, value.content and value.content[1].text or 'unknown error' end
        return value
    end
    local combined = table.concat(parts, '\n')
    local details = {codemode=true, calls=calls}
    local budget = maxTokens * 4
    if #combined > budget then
        local head, tail = math.floor(budget / 2), #combined - math.ceil(budget / 2) + 1
        local function continuation(at)
            local b = string.byte(combined, at)
            return b ~= nil and b >= 128 and b < 192
        end
        while continuation(head + 1) do head -= 1 end
        while continuation(tail) do tail += 1 end
        local lines, at = 1, 1
        while true do
            local newline = string.find(combined, '\n', at)
            if newline == nil then break end
            lines += 1
            at = newline + 1
        end
        local spilled, failure = saveOutput('text/plain', combined)
        combined = string.format('Warning: truncated output (original token count: %d)\nTotal output lines: %d\n\n%s…%d tokens truncated…%s',
            math.ceil(#combined / 4), lines, string.sub(combined, 1, head), math.ceil((tail - head - 1) / 4), string.sub(combined, tail))
        if spilled ~= nil then
            details.fullOutputPath = spilled.path
            combined ..= '\n\n[Full output: ' .. spilled.path .. ' (read with offset/limit)]'
        else
            combined ..= '\n\n[Could not save the full output: ' .. failure .. ']'
        end
    end
    local function sizeLabel(n)
        if n < 1024 then return tostring(n) .. ' B' end
        if n < 1048576 then return string.format('%.1f KB', n / 1024) end
        return string.format('%.1f MB', n / 1048576)
    end
    local imageLabels = agent.decode('[]')
    local byData = {}
    for index, part in ipairs(captured.images) do
        local key = part.mime_type .. ':' .. part.data_base64
        local label = byData[key]
        if label == nil then
            local saved, failure = saveOutput(part.mime_type, part.data_base64)
            label = if saved ~= nil then '[Image saved to ' .. saved.path .. ' (' .. part.mime_type .. ', ' .. sizeLabel(saved.bytes) .. ')]'
                else '[Image (' .. part.mime_type .. ') could not be saved: ' .. failure .. ']'
            byData[key] = label
        end
        imageLabels[index] = label
    end
    if #imageLabels > 0 then details.imageLabels = imageLabels end
    details.durationMs = math.max(0, agent.now() - started)
    captured.result = scriptFrame(captured.ok, combined, details)
    return captured
end
