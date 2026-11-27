-- A journal result is not a provider message. Only content (not UI details,
-- observations or controls) belongs to a tool-result envelope's model view.
local modelViewVersion = options.model_view_version
local envelopeFields = {content=true, structuredContent=true, details=true, isError=true, _meta=true}
local function toolEnvelope(value)
    if type(value) ~= 'table' or (value.content == nil and value.structuredContent == nil) then return false end
    -- `content` is also a perfectly ordinary JSON property. Explicit metadata
    -- identifies an envelope; otherwise require the content-block shape.
    if value.isError ~= nil or value.details ~= nil or value._meta ~= nil then return true end
    for key in pairs(value) do if not envelopeFields[key] then return false end end
    if value.structuredContent ~= nil then return true end
    local blocks = value.content
    if type(blocks) ~= 'table' then return false end
    if #blocks == 0 then return next(blocks) == nil and agent.encode(blocks) == '[]' end
    return type(blocks[1]) == 'table' and type(blocks[1].type) == 'string'
end
local function malformedToolText()
    local reason = 'Invalid tool result content. Output omitted; the operation may already have completed.'
    return 'Tool error: ' .. reason, {code='invalid_tool_output', message=reason}
end
local coreTools = {bash=true, read=true, write=true, edit=true, grep=true, find=true, ls=true}
local function modelToolText(value, core, normalized)
    if type(value) == 'string' then return value end
    if not toolEnvelope(value) then
        return agent.encode(value) -- arbitrary execute_lua return value
    end
    local parts = {}
    local scriptFraming = type(value.details) == 'table' and value.details.codemode == true
    if not core and value.isError == true and not scriptFraming then table.insert(parts, 'Tool error:') end
    if type(value.content) == 'string' then table.insert(parts, value.content)
    elseif type(value.content) == 'table' then
        for key in pairs(value.content) do if type(key) ~= 'number' then return malformedToolText() end end
        for _, part in ipairs(value.content) do
            if type(part) ~= 'table' or type(part.type) ~= 'string' then return malformedToolText() end
            if part.type == 'text' then
                if type(part.text) ~= 'string' then return malformedToolText() end
                table.insert(parts, part.text)
            elseif part.type == 'image' then
                -- Core read images travel separately in e.images, including on replay.
                if not core and not (normalized and type(part.image_index) == 'number') then table.insert(parts, '[Image]') end
            elseif part.type == 'audio' then table.insert(parts, '[Audio]')
            elseif part.type == 'resource' and type(part.resource) == 'table' then
                table.insert(parts, if type(part.resource.text) == 'string' then part.resource.text else '[Resource]')
            elseif part.type == 'resource_link' and type(part.uri) == 'string' then table.insert(parts, part.uri)
            else return malformedToolText() end
        end
    elseif value.content ~= nil then return malformedToolText() end
    if not core and value.structuredContent ~= nil then
        local structured = agent.encode(value.structuredContent)
        if not table.find(parts, structured) then table.insert(parts, structured) end
    end
    return table.concat(parts, '\n')
end
local function javascriptWhitespace(cp)
    return (cp >= 9 and cp <= 13) or cp == 32 or cp == 160 or cp == 0x1680
        or (cp >= 0x2000 and cp <= 0x200A) or cp == 0x2028 or cp == 0x2029
        or cp == 0x202F or cp == 0x205F or cp == 0x3000 or cp == 0xFEFF
end
local function hasToolText(text)
    for _, cp in utf8.codes(text) do if not javascriptWhitespace(cp) then return true end end
    return false
end
local function modelToolOutput(e)
    if e.result == nil and e.output ~= nil then return e.output end -- imported wire-only entry
    local core = coreTools[e.name] == true
    local output, diagnostic = modelToolText(e.result, core, e.normalized_images == true)
    if #(e.images or {}) > 0 then
        local parts = {}
        local details = type(e.result) == 'table' and e.result.details
        local labels = type(details) == 'table' and details.codemode == true and details.imageLabels
        if e.normalized_images == true then
            -- Responses joins all text before its ordered list of attachments.
            local texts, captured = {output}, 0
            for _, image in ipairs(e.images) do
                if image.embedded == true then continue end
                captured += 1
                if type(labels) == 'table' and type(labels[captured]) == 'string' then table.insert(texts, labels[captured]) end
                if type(image.note) == 'string' then table.insert(texts, image.note) end
            end
            output = table.concat(texts, '\n')
            if hasToolText(output) then table.insert(parts, {type='input_text', text=output}) end
        elseif not core or output ~= '' then
            table.insert(parts, {type='input_text', text=output})
        end
        for index, image in ipairs(e.images) do
            if e.normalized_images ~= true and type(labels) == 'table' and type(labels[index]) == 'string' then
                table.insert(parts, {type='input_text', text=labels[index]})
            end
            table.insert(parts, {type='input_image', detail=if core or e.normalized_images == true then 'auto' else nil,
                image_url='data:' .. image.mime_type .. ';base64,' .. image.data_base64})
        end
        output = parts
    elseif core and output == '' then output = '(no tool output)' end
    return {{type='function_call_output', call_id=e.call_id, output=output}}, diagnostic
end
local blockedImageText = 'Image reading is disabled.'
local function blockImageParts(parts)
    if type(parts) ~= 'table' then return nil end
    local hasImage = false
    for _, part in ipairs(parts) do
        if type(part) == 'table' and part.type == 'input_image' then
            hasImage = true
            break
        end
    end
    if not hasImage then return nil end

    local output = {}
    local previousBlocked = false
    for _, part in ipairs(parts) do
        local image = type(part) == 'table' and part.type == 'input_image'
        local blocked = image or (type(part) == 'table' and part.type == 'input_text' and part.text == blockedImageText)
        if not blocked or not previousBlocked then
            table.insert(output, if image then {type='input_text', text=blockedImageText} else part)
        end
        previousBlocked = blocked
    end
    return output
end
local function toolOutputWithoutImages(parts)
    local lines = {}
    for _, part in ipairs(parts) do
        if type(part) ~= 'table' or part.type ~= 'input_text' or type(part.text) ~= 'string' then return parts end
        table.insert(lines, part.text)
    end
    return table.concat(lines, '\n')
end
local function modelRequestInput(messages)
    local runtime = agent.runtimeOptions()
    if runtime == nil or runtime.block_images ~= true then return messages end
    local output
    for index, message in ipairs(messages) do
        if type(message) ~= 'table' then continue end
        local tool = message.type == 'function_call_output' or message.type == 'custom_tool_call_output'
        local field = if tool then 'output' elseif message.role == 'user' then 'content' else nil
        local parts = if field then blockImageParts(message[field]) else nil
        if parts == nil then continue end
        if output == nil then output = table.clone(messages) end
        local item = table.clone(message)
        item[field] = if tool then toolOutputWithoutImages(parts) else parts
        output[index] = item
    end
    return output or messages
end
-- Retired tool metadata can appear between a saved call and its result.
local function isRetiredScriptStore(entry)
    return entry.kind == 'branch' and entry.event_kind == 'pi.codemode-store'
end

local function sessionGraph()
    local function array() return agent.decode('[]') end
    local phaseTaken = false
    local function takePhase(phase)
        if type(input.foreground_task) ~= 'string' then return true end
        if phaseTaken or input.foreground_phase ~= phase then return false end
        phaseTaken = true
        return true
    end
    local function present(value) return value ~= nil and value ~= agent.decode('null') end
    if ctx.session == nil then
        ctx.session = {revision=0, next_id=1, head=options.conversation_head, config=options.config, context_tokens=0}
    end
    local s = ctx.session
    local fields = {revision=true, next_id=true, head=true, config=true, run=true, context_tokens=true, last_submission=true, forked=true}
    local function invalid() error('InvalidSessionState', 0) end
    local function integer(value, minimum)
        return type(value) == 'number' and value >= minimum and value < math.huge and value % 1 == 0
    end
    local function isArray(value)
        if type(value) ~= 'table' then return false end
        local count = 0
        for key in pairs(value) do
            if not integer(key, 1) or key > #value then return false end
            count += 1
        end
        return count == #value and (count > 0 or agent.encode(value) == '[]')
    end
    if type(s) ~= 'table' then invalid() end
    for key in pairs(s) do if fields[key] ~= true then invalid() end end
    if not integer(s.revision, 0) or not integer(s.next_id, 1) then invalid() end
    if present(s.head) and (type(s.head) ~= 'string' or #s.head == 0) then invalid() end
    if present(s.forked) and s.forked ~= true then invalid() end
    if present(s.last_submission) and type(s.last_submission) ~= 'string' then invalid() end
    do
        local config = s.config
        if type(config) ~= 'table' or type(config.model) ~= 'string' or #config.model == 0 or type(config.instructions) ~= 'string'
            or not integer(config.max_output_tokens, 1) or not integer(config.context_window, 1)
            or not integer(config.reserve_tokens, 0) or not integer(config.keep_recent_tokens, 0)
            or (present(config.background_compaction_tokens) and not integer(config.background_compaction_tokens, 0))
            or (present(config.reasoning_effort) and type(config.reasoning_effort) ~= 'string')
            or type(config.thinking_level) ~= 'string' then invalid() end
    end
    if not integer(s.context_tokens, 0) then invalid() end
    if present(ctx.after_run) then
        local pending = ctx.after_run
        if type(pending) ~= 'table' or type(pending.owner) ~= 'string' or #pending.owner == 0 or present(s.run) then invalid() end
        if pending.inbox_owner ~= nil and pending.inbox_owner ~= true then invalid() end
        local summary = pending.summary
        if type(summary) ~= 'table' or (summary.reason ~= 'answer' and summary.reason ~= 'terminate') then invalid() end
        for _, key in ipairs({'first', 'answer', 'last'}) do
            if type(summary[key]) ~= 'string' or #summary[key] == 0 then invalid() end
        end
    end
    if present(s.run) then
        if type(s.run) ~= 'table' or (s.run.phase ~= 'model' and s.run.phase ~= 'generation' and s.run.phase ~= 'tool'
            and s.run.phase ~= 'tool_result' and s.run.phase ~= 'retry_wait') or not isArray(s.run.pending)
            or type(s.run.overflow_attempted) ~= 'boolean' or type(s.run.input_id) ~= 'string' then invalid() end
        local runFields = {phase=true, pending=true, overflow_attempted=true, input_id=true, restarts=true, response_id=true, retry_safe=true, retry=true, joined=true,
            handoff=true, terminate_round=true, owner=true, first=true, inbox_owner=true, model_selection=true, skip_threshold_compaction=true,
            tool_preflight=true, tool_prepared=true, tool_result=true, generation_hook=true, request_messages=true, model_view=true}
        for key in pairs(s.run) do if runFields[key] ~= true then invalid() end end
        if s.run.restarts ~= nil and not integer(s.run.restarts, 0) then invalid() end
        if s.run.response_id ~= nil and type(s.run.response_id) ~= 'string' then invalid() end
        if s.run.retry_safe ~= nil and type(s.run.retry_safe) ~= 'boolean' then invalid() end
        if s.run.handoff ~= nil and type(s.run.handoff) ~= 'string' then invalid() end
        if s.run.terminate_round ~= nil and type(s.run.terminate_round) ~= 'boolean' then invalid() end
        if s.run.skip_threshold_compaction ~= nil and s.run.skip_threshold_compaction ~= true then invalid() end
        if s.run.owner ~= nil and type(s.run.owner) ~= 'string' then invalid() end
        if s.run.inbox_owner ~= nil and (s.run.inbox_owner ~= true or s.run.owner == nil) then invalid() end
        if s.run.model_selection ~= nil and type(s.run.model_selection) ~= 'table' then invalid() end
        if s.run.first ~= nil and type(s.run.first) ~= 'string' then invalid() end
        if s.run.joined ~= nil then
            if type(s.run.joined) ~= 'table' then invalid() end
            for submission, entry in pairs(s.run.joined) do
                if type(submission) ~= 'string' or type(entry) ~= 'string' then invalid() end
            end
        end
        local retry = s.run.retry
        if retry ~= nil and (type(retry) ~= 'table' or not integer(retry.failures, 1)
            or (retry.delay_ms ~= nil and not integer(retry.delay_ms, 0))
            or (retry.until_ms ~= nil and not integer(retry.until_ms, 0))) then invalid() end
        if s.run.phase == 'retry_wait' and (retry == nil or retry.delay_ms == nil) then invalid() end
        for _, call in ipairs(s.run.pending) do
            if type(call) ~= 'table' or type(call.name) ~= 'string' or type(call.call_id) ~= 'string' or call.arguments == nil then invalid() end
        end
        if s.run.tool_preflight ~= nil and s.run.tool_preflight ~= true then invalid() end
        if s.run.tool_prepared ~= nil and s.run.tool_prepared ~= true then invalid() end
        if (s.run.phase == 'tool_result') ~= (s.run.tool_result ~= nil) then invalid() end
        if s.run.tool_result ~= nil then
            local staged, call = s.run.tool_result, s.run.pending[1]
            if call == nil or type(staged) ~= 'table' or staged.call_id ~= call.call_id
                or type(staged.captured) ~= 'table' or type(staged.reply) ~= 'table' then invalid() end
        end
        if s.run.model_view ~= nil and not integer(s.run.model_view, 1) then invalid() end
        if s.run.request_messages ~= nil and not isArray(s.run.request_messages) then invalid() end
        local hook = s.run.generation_hook
        if hook ~= nil then
            if type(hook) ~= 'table' or not integer(hook.revision, 0) or #s.run.pending ~= 0 then invalid() end
            if hook.stage == 'request' then
                if not isArray(hook.data) or s.run.request_messages ~= nil then invalid() end
            elseif hook.stage == 'response' then
                local interrupted = ctx.__interrupted_application
                if type(interrupted) ~= 'table' or type(interrupted.model_reply) ~= 'table' or type(interrupted.model_reply.status) ~= 'string' then invalid() end
            elseif hook.stage == 'tools' then
                if type(hook.data) ~= 'table' or type(hook.data.assistant) ~= 'string' or not isArray(hook.data.results) then invalid() end
            else invalid() end
        end
    end
    local pending, cache = array(), {}
    local function observations(effects)
        local out = array()
        for _, effect in ipairs(effects or {}) do
            local args = if type(effect.arguments) == 'table' then effect.arguments else {}
            local result = if type(effect.result) == 'table' then effect.result else {}
            table.insert(out, {tool_name=effect.tool_name, endpoint=effect.endpoint,
                arguments={path=args.path}, failed=effect.failed == true, result={isError=result.isError == true}})
        end
        return out
    end
    local function projection(e)
        if e.kind ~= 'program' then return e end
        local out = {}
        for key, value in pairs(e) do
            if key ~= 'effects' and key ~= 'observations' then out[key] = value end
        end
        out.observations = observations(if present(e.observations) then e.observations else e.effects)
        return out
    end
    local function lookup(id)
        if cache[id] ~= nil then return cache[id] end
        local e = agent.history(id)
        if not present(e) then return nil end
        cache[id] = projection(e)
        return cache[id]
    end
    local function systemRef(id)
        while type(id) == 'string' do
            local entry = lookup(id)
            if entry == nil then error('InvalidSessionParent', 0) end
            if entry.system_revision == true then return entry.id end
            if entry.system_entry ~= nil then return entry.system_entry end
            id = entry.parent
        end
        return nil
    end
    local function thinkingRef(id)
        while type(id) == 'string' do
            local entry = lookup(id)
            if entry == nil then error('InvalidSessionParent', 0) end
            if entry.session_setting == 'thinking' then return entry.id end
            if entry.thinking_entry ~= nil then return entry.thinking_entry end
            id = entry.parent
        end
        return nil
    end
    local function treeMetadata(entry)
        return entry.session_setting == 'model' or entry.session_setting == 'thinking' or entry.tree_label == true
    end
    local function append(e, detached)
        local id = (options.conversation_entry_prefix or 'a') .. tostring(s.next_id)
        s.next_id += 1
        e.id, e.parent = id, s.head or agent.decode('null')
        if e.kind == 'input' or e.kind == 'response' or e.kind == 'program' then
            e.message_at_ms = agent.now()
        end
        if not detached and e.system_revision ~= true then e.system_entry = systemRef(s.head) end
        if not detached and e.session_setting ~= 'thinking' then e.thinking_entry = thinkingRef(s.head) end
        table.insert(pending, e)
        cache[id] = projection(e)
        if not detached then
            s.head = id
            ctx.tree_reopen = nil
        end
        s.revision += 1
        return e
    end
    local function thinkingLabel(config)
        if config.thinking_level == 'provider default' then return 'off' end
        return config.thinking_level
    end
    local function recordModelChoice(selection)
        if type(selection) ~= 'table' or type(selection.model) ~= 'string' then return end
        local provider = if type(selection.provider_ref) == 'string' then selection.provider_ref
            elseif selection.protocol == 'codex' then 'openai-codex' else selection.kind
        append({kind='write', session_setting='model', data={model=selection.model, provider=provider}})
    end
    local function recordThinkingChoice()
        append({kind='write', session_setting='thinking', data=thinkingLabel(s.config)})
    end
    local function configureTree(change, fresh, selection, previous)
        if change == 'open' then
            if fresh then recordModelChoice(selection) end
            if thinkingRef(s.head) == nil then recordThinkingChoice() end
        elseif change == 'model' or change == 'thinking' then
            if change == 'model' then recordModelChoice(selection) end
            if thinkingLabel(previous) ~= thinkingLabel(s.config) then recordThinkingChoice() end
        end
    end
    local levels = {'off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'}
    local function clampRecordedThinking(label)
        local supported = s.config.thinking_levels
        if type(supported) ~= 'table' or #supported == 0 or table.find(supported, label) ~= nil then return label end
        local ranked = table.find(levels, label)
        if ranked ~= nil then
            for i = ranked + 1, #levels do if table.find(supported, levels[i]) ~= nil then return levels[i] end end
            for i = ranked - 1, 1, -1 do if table.find(supported, levels[i]) ~= nil then return levels[i] end end
        end
        return supported[1]
    end
    local function reconcileThinking()
        local id = thinkingRef(s.head)
        if id ~= nil and clampRecordedThinking(lookup(id).data) ~= thinkingLabel(s.config) then recordThinkingChoice() end
    end
    local function sameJson(left, right)
        if left == right then return true end
        if type(left) ~= 'table' or type(right) ~= 'table' then return false end
        if next(left) == nil and next(right) == nil then return agent.encode(left) == agent.encode(right) end
        for key, value in pairs(left) do if not sameJson(value, right[key]) then return false end end
        for key in pairs(right) do if left[key] == nil then return false end end
        return true
    end
    local function recordedSystem(at)
        local id = systemRef(at)
        local entry = if id then lookup(id) else nil
        return if entry ~= nil and entry.system_revision == true then entry.data else nil
    end
    local function recordSystem(descriptors)
        local previous = recordedSystem(s.head)
        if previous ~= nil and previous.instructions == s.config.instructions
            and sameJson(previous.tools, descriptors) then
            return false
        end
        append({kind='write', event_kind='pi.system', system_revision=true, data={instructions=s.config.instructions, tools=descriptors}})
        return true
    end
    local cachedPath, cachedHead, cachedRevision
    local function path()
        if cachedPath ~= nil and cachedHead == s.head and cachedRevision == s.revision then return cachedPath end
        local reverse, cursor, first = {}, s.head, nil
        local seen = {}
        while present(cursor) do
            if type(cursor) ~= 'string' or seen[cursor] then invalid() end
            seen[cursor] = true
            local e = lookup(cursor)
            if e == nil or e.id ~= cursor then error('InvalidSessionParent', 0) end
            table.insert(reverse, e)
            if first == nil then
                if e.kind == 'checkpoint' then first = e.first_kept
                elseif e.kind == 'write' then first = e.context_start end
            end
            if e.id == first then break end
            cursor = e.parent
        end
        local out = {}
        for n = #reverse, 1, -1 do table.insert(out, reverse[n]) end
        cachedPath, cachedHead, cachedRevision = out, s.head, s.revision
        return out
    end
    local function visible()
        local chain, first, checkpoint = path(), 1, nil
        for n = #chain, 1, -1 do
            local e = chain[n]
            if e.kind == 'checkpoint' or (e.kind == 'write' and e.context_start ~= nil) then
                if e.kind == 'write' then break end
                local found
                for i = 1, n - 1 do if chain[i].id == e.first_kept then found = i; break end end
                if found == nil then error('InvalidCompaction', 0) end
                first, checkpoint = found, e
                break
            end
        end
        local out = {}
        for i = first, #chain do
            if chain[i].kind ~= 'checkpoint' and chain[i].kind ~= 'branch' then table.insert(out, chain[i]) end
        end
        return out, checkpoint
    end
    local function content(parts)
        if type(parts) == 'string' then return parts end
        local out = ''
        for _, part in ipairs(parts or {}) do if type(part.text) == 'string' then out ..= part.text end end
        return out
    end
    local function modelEntries()
        local entries, checkpoint = visible()
        local edits, head = {}, nil
        local changed = false
        for _, entry in ipairs(entries) do
            if entry.kind == 'write' then
                if entry.context_start ~= nil then head = entry end
                for _, edit in ipairs(entry.edits or {}) do
                    edits[edit.target] = edit
                    changed = true
                end
            end
        end
        if head == nil and not changed then return entries, checkpoint, false end
        local out = {}
        local function add(entry)
            local edit = edits[entry.id]
            if edit == nil then table.insert(out, entry)
            else table.insert(out, {id=entry.id, kind='write', model=if edit.action == 'replace' then edit.messages else nil}) end
        end
        if head ~= nil and checkpoint == nil then add(head) end
        for _, entry in ipairs(entries) do
            if entry.kind ~= 'write' or entry.context_start == nil then add(entry) end
        end
        return out, checkpoint, true
    end

    local function toolPairs(items)
        local results, pending, out = {}, array(), array()
        for i, item in ipairs(items) do
            if item.type == 'function_call_output' then results[item.call_id] = {position=i, item=item} end
        end
        local function flush()
            for _, item in ipairs(pending) do table.insert(out, item) end
            table.clear(pending)
        end
        for i, item in ipairs(items) do
            if item.type == 'function_call' then
                table.insert(out, item)
                local result = results[item.call_id]
                table.insert(pending, if result ~= nil and result.position > i then result.item
                    else {type='function_call_output', call_id=item.call_id, output='Tool result unavailable in the selected conversation context.'})
            elseif item.type ~= 'function_call_output' then
                flush()
                table.insert(out, item)
            end
        end
        flush()
        return out
    end
    local function assistant(e)
        if e.usage_format == 'openai.Result' then return e.text end
        local text = ''
        for _, item in ipairs(e.output or {}) do
            if item.type == 'message' then text ..= content(item.content) end
        end
        return text
    end
    local function characters(text)
        if utf8.len(text) == #text then return #text end
        local count = 0
        for _, codepoint in utf8.codes(text) do count += if codepoint > 65535 then 2 else 1 end
        return count
    end
    local function estimate(e)
        local chars = 0
        if e.kind == 'input' then
            if type(e.user_content) ~= 'table' then chars = characters(e.user_content or e.text)
            else
                for _, part in ipairs(e.user_content) do
                    chars += if part.type == 'input_image' then 4800 else characters(part.text or '')
                end
            end
        elseif e.kind == 'response' then
            for _, item in ipairs(e.output or {}) do
                if item.type == 'function_call' then chars += characters(item.name or '') + characters(item.arguments or '')
                else chars += characters(content(item.content)) + characters(content(item.summary)) end
            end
        elseif e.kind == 'program' then
            for _, item in ipairs(modelToolOutput(e)) do
                if type(item.output) == 'string' then chars += characters(item.output)
                else
                    for _, part in ipairs(item.output or {}) do
                        chars += if part.type == 'input_image' then 4800 else characters(part.text or '')
                    end
                end
            end
        elseif e.kind == 'checkpoint' or e.kind == 'branch_summary' then chars = characters(e.summary) end
        if e.kind == 'write' then
            for _, message in ipairs(e.model or {}) do chars += characters(content(message.content)) end
        end
        return math.ceil(chars / 4)
    end
    local function estimateTokens()
        local entries, checkpoint, altered = modelEntries()
        local trailing = 0
        for n = #entries, 1, -1 do
            local e = entries[n]
            if not altered and e.kind == 'response' and e.model == s.config.model and e.model_view == modelViewVersion then
                local after = checkpoint == nil
                if checkpoint ~= nil then
                    for _, prior in ipairs(path()) do
                        if prior.id == checkpoint.id then after = true end
                        if prior.id == e.id then break end
                    end
                end
                local usage = if type(e.usage) == 'table' then e.usage else {}
                local total = if type(usage.total_tokens) == 'number' then usage.total_tokens
                    else (if type(usage.input_tokens) == 'number' then usage.input_tokens else 0) + (if type(usage.output_tokens) == 'number' then usage.output_tokens else 0)
                if after and total > 0 then return total + trailing end
            end
            trailing += estimate(e)
        end
        return trailing + (if checkpoint then estimate(checkpoint) else 0) + math.ceil(characters(s.config.instructions) / 4)
    end
    local tokenPath, tokenModel, tokenInstructions, tokenCount
    local function tokens()
        local chain = path()
        if tokenPath ~= chain or tokenModel ~= s.config.model or tokenInstructions ~= s.config.instructions then
            tokenCount = estimateTokens()
            tokenPath, tokenModel, tokenInstructions = chain, s.config.model, s.config.instructions
        end
        return tokenCount
    end
    local function summaryContext(e)
        if e.kind == 'branch_summary' then
            return 'The following is a summary of a branch that this conversation came back from:\n\n<summary>\n' .. e.summary .. '</summary>'
        end
        return 'The conversation history before this point was compacted into the following summary:\n\n<summary>\n' .. e.summary .. '\n</summary>'
    end
    local function messagesFor(entries, checkpoint, altered)
        local out = array()
        if checkpoint then table.insert(out, {role='user', content=summaryContext(checkpoint)}) end
        for _, e in ipairs(entries) do
            if e.kind == 'input' then table.insert(out, {role='user', content=e.user_content or e.text})
            elseif e.kind == 'write' then for _, item in ipairs(e.model or {}) do table.insert(out, item) end
            elseif e.kind == 'branch_summary' then table.insert(out, {role='user', content=summaryContext(e)})
            elseif e.kind == 'response' then for _, item in ipairs(e.output) do table.insert(out, item) end
            elseif e.kind == 'program' then
                for _, item in ipairs(modelToolOutput(e)) do table.insert(out, item) end
            end
        end
        return if altered or s.forked == true then toolPairs(out) else out
    end
    local function modelInput()
        local entries, checkpoint, altered = modelEntries()
        return messagesFor(entries, checkpoint, altered)
    end
    local function checkpoint(event, boundary)
        s.context_tokens = tokens()
        local retained = {}
        for _, entry in ipairs(path()) do retained[entry.id] = entry end
        cache = retained
        if event.id ~= nil then event.slim=true; event.text=nil; event.data=nil; event.thinking=nil end
        agent.checkpoint(event, boundary, pending)
        pending = array()
    end
    local function nextRetry(previous, hint)
        local failures = if previous == nil then 1 else previous.failures + 1
        local policy = options.retry
        if type(policy.limit) == 'number' and failures > policy.limit then return nil end
        local delay = math.min(policy.max_ms, policy.initial_ms * 2 ^ math.min(failures - 1, 30))
        return {failures=failures, delay_ms=math.max(delay, hint or 0)}
    end
    local function waitForRetry(retry)
        if retry.until_ms == nil then
            retry.until_ms = agent.now() + retry.delay_ms
            checkpoint({
                kind='provider_retry',
                text='Retry ' .. tostring(retry.failures) .. ' · next attempt in ' .. tostring(retry.delay_ms) .. ' ms',
                data={attempt=retry.failures, max_attempts=options.retry.limit, delay_ms=retry.delay_ms},
            })
        end
        if type(input.foreground_task) == 'string' then
            if retry.until_ms > agent.now() then return retry.until_ms end
        else
            agent.waitUntil(retry.until_ms)
        end
        retry.until_ms, retry.delay_ms = nil, nil
    end
    local function modelEntry(reply, purpose)
        return {kind=if purpose == 'response' then 'response' else 'model_result', purpose=purpose,
            status=reply.status, stop_reason=if type(reply.stop_reason) == 'string' then reply.stop_reason else nil,
            model=if #reply.model > 0 then reply.model else s.config.model,
            text=reply.text, thinking=reply.thinking, output=reply.output, calls=reply.calls,
            usage=reply.usage, usage_format='openai.Result', error=reply.error}
    end
    local function recordModel(reply, purpose)
        local entry = append(modelEntry(reply, purpose), true)
        checkpoint({kind='model_result', id=entry.id})
        return entry
    end
    local function serialize(entries, first, last)
        local out = {}
        for n = first, last do
            local e = entries[n]
            if e.kind == 'input' then table.insert(out, '[User]: ' .. e.text)
            elseif e.kind == 'branch_summary' then table.insert(out, '[User]: ' .. summaryContext(e))
            elseif e.kind == 'write' then
                for _, item in ipairs(e.model or {}) do table.insert(out, '[' .. item.role .. ']: ' .. content(item.content)) end
            elseif e.kind == 'response' then
                local text = assistant(e)
                if #text > 0 then table.insert(out, '[Assistant]: ' .. text) end
                local calls = {}
                for _, item in ipairs(e.output or {}) do if item.type == 'function_call' then table.insert(calls, item.name .. '(' .. item.arguments .. ')') end end
                if #calls > 0 then table.insert(out, '[Assistant tool calls]: ' .. table.concat(calls, '; ')) end
            elseif e.kind == 'program' then
                for _, item in ipairs(modelToolOutput(e)) do
                    local text = content(item.output)
                    if #text > 0 then table.insert(out, '[Tool result]: ' .. text) end
                end
            end
        end
        return table.concat(out, '\n\n')
    end
    local function compactionRange(focus, reason, progress)
        local visibleEntries, previous = visible()
        local entries = {}
        for _, entry in ipairs(visibleEntries) do if not treeMetadata(entry) then table.insert(entries, entry) end end
        local contributions = {}
        local projected, _, altered = modelEntries()
        for _, entry in ipairs(projected) do if not treeMetadata(entry) then contributions[entry.id] = entry end end
        if #entries < 2 then return nil end
        local index
        local fresh = false
        if progress ~= nil and progress.head == s.head and progress.focus == focus then
            for i, e in ipairs(entries) do if e.id == progress.first_kept then index = i; break end end
        end
        if index == nil then
            local last, sum = 1, 0
            index = 1
            for i, e in ipairs(entries) do if e.kind ~= 'program' then last = i end end
            for i = #entries, 1, -1 do
                local count = estimate(contributions[entries[i].id] or {kind='write'})
                if count == 0 then continue end
                sum += count
                if sum >= s.config.keep_recent_tokens then
                    index = last
                    for n = i, #entries do if entries[n].kind ~= 'program' then index = n; break end end
                    break
                end
            end
            if index == 1 then return nil end
            fresh = true
            progress = {head=s.head, focus=focus, model=s.config.model, first_kept=entries[index].id, parts={}}
            if reason ~= nil and options.before_compact == true then
                local selected, effective = array(), array()
                if previous ~= nil then table.insert(selected, previous.id) end
                for n = 1, index - 1 do
                    local entry = entries[n]
                    table.insert(selected, entry.id)
                    local contribution = contributions[entry.id]
                    if contribution ~= nil then table.insert(effective, contribution) end
                end
                progress.hook = {reason=reason, head=s.head, first_kept=entries[index].id, entries=selected,
                    messages=messagesFor(effective, previous, altered), instructions=if #focus > 0 then focus else nil}
            end
        end
        local start
        if entries[index].kind ~= 'input' then for n = index - 1, 1, -1 do if entries[n].kind == 'input' then start = n; break end end end
        return {entries=entries, previous=previous, contributions=contributions, index=index, start=start, progress=progress, fresh=fresh}
    end
    local function summaryPrompt(range, first, lastIndex, prefix, focus)
        local entries, contributions, previous = range.entries, range.contributions, range.previous
        local context = {}
        for i = first, lastIndex do
            local contribution = contributions[entries[i].id]
            if contribution ~= nil then table.insert(context, contribution) end
        end
        local text = serialize(context, 1, #context)
        if prefix then text = '# Conversation\n' .. text .. '\n\n# Instructions\n' .. options.turn_prefix
        else
            text = '<conversation>\n' .. text .. '\n</conversation>\n\n' .. (if previous then '<previous-summary>\n' .. previous.summary .. '\n</previous-summary>\n\n' .. options.update_summary else options.summary)
        end
        if #focus > 0 then text ..= '\n\nAdditional focus: ' .. focus end
        return text
    end
    local function compactionDetails(range)
        local previous, entries, index = range.previous, range.entries, range.index
        local reads, modified = {}, {}
        local details = if previous then (previous.metadata or {}).details else nil
        for _, file in ipairs(if details then details.readFiles or {} else {}) do reads[file] = true end
        for _, file in ipairs(if details then details.modifiedFiles or {} else {}) do modified[file] = true end
        for n = 1, index - 1 do
            local e = entries[n]
            if e.kind ~= 'program' then continue end
            for _, effect in ipairs(e.observations or e.effects or {}) do
                if effect.failed or (effect.result or {}).isError then continue end
                local path = (effect.arguments or {}).path
                if type(path) ~= 'string' then continue end
                if effect.endpoint == 'files.read' then reads[path] = true end
                if effect.endpoint == 'files.write' then modified[path] = true end
            end
        end
        local readFiles, modifiedFiles = array(), array()
        for file in pairs(reads) do if not modified[file] then table.insert(readFiles, file) end end
        for file in pairs(modified) do table.insert(modifiedFiles, file) end
        table.sort(readFiles); table.sort(modifiedFiles)
        return {readFiles=readFiles, modifiedFiles=modifiedFiles}
    end
    local function compactionFileSuffix(details)
        local out = ''
        for _, group in ipairs({{'read-files',details.readFiles},{'modified-files',details.modifiedFiles}}) do
            if #group[2] > 0 then out ..= '\n\n<' .. group[1] .. '>\n' .. table.concat(group[2], '\n') .. '\n</' .. group[1] .. '>' end
        end
        return out
    end
    local function planTreeSummary(targetId, focus)
        local target = lookup(targetId)
        if target == nil then return {status='stale_selection'} end
        local result = {status='planned', revision=s.revision}
        local ancestors, cursor = {}, target
        while cursor ~= nil do
            if ancestors[cursor.id] then error('InvalidSessionParent', 0) end
            ancestors[cursor.id] = true
            cursor = if present(cursor.parent) then lookup(cursor.parent) else nil
        end
        local abandoned, seen = {}, {}
        cursor = if present(s.head) then lookup(s.head) else nil
        while cursor ~= nil and not ancestors[cursor.id] do
            if seen[cursor.id] then error('InvalidSessionParent', 0) end
            seen[cursor.id] = true
            table.insert(abandoned, cursor)
            cursor = if present(cursor.parent) then lookup(cursor.parent) else nil
        end
        if #abandoned == 0 then return result end

        local edits, reads, modified = {}, {}, {}
        for n = #abandoned, 1, -1 do
            local entry = abandoned[n]
            for _, edit in ipairs(entry.edits or {}) do edits[edit.target] = edit end
            if entry.kind == 'branch_summary' then
                local details = (entry.metadata or {}).details or {}
                for _, path in ipairs(details.readFiles or {}) do reads[path] = true end
                for _, path in ipairs(details.modifiedFiles or {}) do modified[path] = true end
            end
        end

        local budget = s.config.context_window - 16384
        local tokens, newest = 0, {}
        for _, entry in ipairs(abandoned) do
            local edit = edits[entry.id]
            local cost, message = estimate(entry), ''
            if edit ~= nil then
                if edit.action == 'replace' then
                    local replacement = {kind='write', model=edit.messages}
                    cost = estimate(replacement)
                    local parts = {}
                    for _, item in ipairs(edit.messages or {}) do
                        local text = content(item.content)
                        if #text > 0 then table.insert(parts, '[User]: ' .. text) end
                    end
                    message = table.concat(parts, '\n\n')
                else continue end
            elseif entry.kind == 'input' then
                message = '[User]: ' .. content(entry.user_content or entry.text)
            elseif entry.kind == 'response' then
                local text = assistant(entry)
                local parts, calls = {}, {}
                if #text > 0 then table.insert(parts, '[Assistant]: ' .. text) end
                for _, call in ipairs(entry.output or {}) do
                    if call.type ~= 'function_call' then continue end
                    local decoded, arguments = pcall(agent.decode, call.arguments)
                    local keys, pairsText = {}, {}
                    if decoded and type(arguments) == 'table' then
                        for key in pairs(arguments) do if type(key) == 'string' then table.insert(keys, key) end end
                        table.sort(keys)
                        for _, key in ipairs(keys) do table.insert(pairsText, key .. '=' .. agent.encode(arguments[key])) end
                        local path = arguments.path or arguments.file_path
                        if type(path) == 'string' then
                            if call.name == 'read' then reads[path] = true end
                            if call.name == 'edit' or call.name == 'write' then modified[path] = true end
                        end
                    end
                    table.insert(calls, call.name .. '(' .. table.concat(pairsText, ', ') .. ')')
                end
                if #calls > 0 then table.insert(parts, '[Assistant tool calls]: ' .. table.concat(calls, '; ')) end
                message = table.concat(parts, '\n\n')
            elseif entry.kind == 'checkpoint' or entry.kind == 'branch_summary' then
                message = '[User]: ' .. summaryContext(entry)
            elseif entry.kind == 'write' then
                local parts = {}
                for _, item in ipairs(entry.model or {}) do
                    local text = content(item.content)
                    if item.role == 'user' and #text > 0 then table.insert(parts, '[User]: ' .. text) end
                end
                message = table.concat(parts, '\n\n')
            else
                continue
            end
            local over = budget > 0 and tokens + cost > budget
            if not over or ((entry.kind == 'checkpoint' or entry.kind == 'branch_summary') and tokens < budget * 0.9) then
                if #message > 0 then table.insert(newest, message) end
                tokens += cost
            end
            if over then break end
        end
        if #newest == 0 then
            result.summary = 'No content to summarize'
            return result
        end
        local chronological = {}
        for n = #newest, 1, -1 do table.insert(chronological, newest[n]) end
        local readFiles, modifiedFiles = array(), array()
        for path in pairs(reads) do if not modified[path] then table.insert(readFiles, path) end end
        for path in pairs(modified) do table.insert(modifiedFiles, path) end
        table.sort(readFiles)
        table.sort(modifiedFiles)
        result.details = {readFiles=readFiles, modifiedFiles=modifiedFiles}
        result.suffix = compactionFileSuffix(result.details)
        result.prompt = '<conversation>\n' .. table.concat(chronological, '\n\n') .. '\n</conversation>\n\n' .. options.branch_summary
        if #focus > 0 then result.prompt ..= '\n\nAdditional focus: ' .. focus end
        return result
    end
    local function stageBackgroundCompaction(contextTokens, blockingThreshold)
        if type(s.run.owner) ~= 'string' or type(s.head) ~= 'string' then return false end
        local lead = s.config.background_compaction_tokens
        if type(lead) ~= 'number' then lead = options.config.background_compaction_tokens or 0 end
        if lead == 0 or contextTokens <= blockingThreshold - lead then return false end
        local previous = ctx.background_compaction
        if previous ~= nil and previous.head == s.head and previous.owner == s.run.owner then return false end
        if compactionRange('', nil, nil) == nil then return false end
        ctx.background_compaction = {head=s.head, owner=s.run.owner, at=agent.now()}
        return true
    end
    local function planCompaction(focus, reason)
        local range = compactionRange(focus, reason, nil)
        if range == nil then return {nothing=true} end
        local historyEnd = range.start or range.index
        local details = compactionDetails(range)
        return {
            hook=range.progress.hook, first_kept=range.progress.first_kept, head=range.progress.head,
            history=if historyEnd > 1 then summaryPrompt(range, 1, historyEnd - 1, false, focus) else nil,
            base_summary=if range.previous then range.previous.summary else 'No prior history.',
            turn=if range.start then summaryPrompt(range, range.start, range.index - 1, true, focus) else nil,
            metadata={tokensBefore=tokens(), details=details}, suffix=compactionFileSuffix(details),
            config=s.config, selection=(if s.run then s.run.model_selection else nil) or ctx.launch_model_selection or ctx.model_selection,
        }
    end
    local function compact(focus, submission, reason)
        local range = compactionRange(focus, reason, ctx.compaction_progress)
        if range == nil then return false end
        local entries, previous, index, start, progress = range.entries, range.previous, range.index, range.start, range.progress
        if range.fresh then
            local interrupted = ctx.__interrupted_application
            if type(interrupted) == 'table' and interrupted.model_part ~= nil then ctx.__interrupted_application = nil end
            ctx.compaction_progress = progress
        end
        local before = tokens()
        checkpoint({kind='compacting', tokens=before, data=reason})
        local override
        if progress.hook ~= nil then
            local decision = input.compaction_decision
            if type(decision) ~= 'table' or decision.head ~= progress.head or decision.first_kept ~= progress.first_kept
                or not takePhase('before_compact') then
                return false, {status='delegate', phase='before_compact'}
            end
            progress.hook = nil
            if decision.kind == 'decline' then
                ctx.compaction_progress = nil
                ctx.foreground_continuation = nil
                if submission ~= nil then s.last_submission = submission end
                if reason == 'threshold' and s.run ~= nil then s.run.skip_threshold_compaction = true end
                checkpoint({kind='compaction_declined'})
                return false, nil, true
            elseif decision.kind == 'summary' and type(decision.summary) == 'string' then
                override = decision.summary
            elseif decision.kind ~= 'provider' then
                error('InvalidCompactionDecision', 0)
            end
        end
        local function summary(first, lastIndex, prefix)
            local part = if prefix then 'turn' else 'history'
            local saved = progress.parts[part]
            if saved == nil then
                saved = {invalid=0}
                progress.parts[part] = saved
            end
            if saved.text ~= nil then return saved.text end
            local text = summaryPrompt(range, first, lastIndex, prefix, focus)
            while true do
                if saved.retry ~= nil and saved.retry.delay_ms ~= nil then
                    local deadline = waitForRetry(saved.retry)
                    if deadline ~= nil then return nil, {status='waiting', deadline_ms=deadline} end
                end
                local interrupted = ctx.__interrupted_application
                local recovering = type(interrupted) == 'table' and interrupted.model_part == part
                local recovered = if recovering and type(interrupted.model_reply) == 'table' then interrupted.model_reply else nil
                if not takePhase('model') and recovered == nil then return nil, {status='delegate', phase='model'} end
                progress.active_part = part
                local reply = recovered or agent.model({model=s.config.model, instructions=options.summary_system, input={{role='user',content=text}}, tools=array(), max_output_tokens=s.config.max_output_tokens, reasoning=if type(s.config.reasoning_effort) == 'string' then {effort=s.config.reasoning_effort} else nil},
                    recovering and type(interrupted.model_resume) == 'number')
                if reply.status == 'poll_pending' then
                    ctx.__interrupted_application = reply.continuation
                    return nil, {status='waiting', deadline_ms=reply.next_poll_ms}
                end
                progress.active_part = nil
                if recovering then
                    if submission ~= nil then
                        ctx.__interrupted_application = {request_id=interrupted.request_id, input_json=interrupted.input_json, restarts=interrupted.restarts}
                    else
                        ctx.__interrupted_application = nil
                    end
                end
                if reply.status == 'completed' and #reply.calls == 0 and #reply.text > 0 then
                    saved.text, saved.retry, saved.usage = reply.text, nil, reply.usage
                    recordModel(reply, 'summary')
                    return saved.text
                end
                local retry = if reply.retryable == true then nextRetry(saved.retry, reply.retry_after_ms) else nil
                if retry ~= nil then
                    saved.retry = retry
                    recordModel(reply, 'summary')
                    continue
                end
                saved.retry = nil
                saved.invalid += 1
                recordModel(reply, 'summary')
                if (reply.status ~= 'completed' and reply.status ~= 'incomplete') or saved.invalid >= 3 then
                    ctx.compaction_progress = nil
                    checkpoint({kind='compaction_failed'})
                    error('InvalidSummary', 0)
                end
                checkpoint({kind='notice', text='Summary retry ' .. tostring(saved.invalid) .. '/2'})
            end
        end
        local historyEnd = start or index
        local text = override
        if text == nil then
            if historyEnd > 1 then
                local step
                text, step = summary(1, historyEnd - 1, false)
                if step ~= nil then return false, step end
            else text = if previous then previous.summary else 'No prior history.' end
            if start then
                local prefix, nextStep = summary(start, index - 1, true)
                if nextStep ~= nil then return false, nextStep end
                text ..= '\n\n---\n\n**Turn Context (split turn):**\n\n' .. prefix
            end
        end
        local details = compactionDetails(range)
        if override == nil then text ..= compactionFileSuffix(details) end
        local summary_parts_usage = {}
        for part, saved in pairs(progress.parts) do
            if type(saved.usage) == 'table' then summary_parts_usage[part] = saved.usage end
        end
        local e = append({kind='checkpoint', summary=text, first_kept=entries[index].id, metadata={tokensBefore=before, details=details},
            summary_parts_usage=if next(summary_parts_usage) ~= nil then summary_parts_usage else nil})
        ctx.compaction_progress = nil
        ctx.foreground_continuation = nil
        if submission ~= nil then s.last_submission = submission end
        if reason == 'threshold' and s.run ~= nil then s.run.skip_threshold_compaction = true end
        checkpoint({kind='compacted', id=e.id, text=text, tokens=tokens()})
        return true
    end
    local function compactionWaiting()
        local progress = ctx.compaction_progress
        if progress ~= nil then
            for _, part in pairs(progress.parts) do
                if part.retry ~= nil and part.retry.delay_ms ~= nil then return true end
            end
        end
        return false
    end
    return {state=s, append=append, recordSystem=recordSystem, recordedSystem=recordedSystem, configureTree=configureTree, reconcileThinking=reconcileThinking,
        modelEntry=modelEntry, recordModel=recordModel, lookup=lookup, visible=visible, modelEntries=modelEntries, assistant=assistant, content=content,
        checkpoint=checkpoint, modelInput=modelInput, tokens=tokens, compact=compact, planCompaction=planCompaction, planTreeSummary=planTreeSummary,
        stageBackgroundCompaction=stageBackgroundCompaction, observations=observations,
        nextRetry=nextRetry, waitForRetry=waitForRetry, compactionWaiting=compactionWaiting, takePhase=takePhase}
end
