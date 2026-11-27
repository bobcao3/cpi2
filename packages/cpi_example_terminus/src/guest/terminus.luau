local input = rt.call("session.input", {})
ctx.state = ctx.state or {turn = 0, pending = false, compactions = 0, children = {}, prompt = ""}
local s = ctx.state
local info = rt.call("model.info", {})
local key_names = { ["C-c"] = "\003", ["C-d"] = "\004", Enter = "\r", ["C-m"] = "\r", ["C-j"] = "\n", KPEnter = "\r", ["^M"] = "\r", ["^J"] = "\n", Tab = "\t", Escape = "\027", BSpace = "\127", Space = " " }
local output_bytes = input.output_bytes or 10000
local function capture(history)
    return rt.call("process.capture", {
        id = s.terminal,
        history = history,
        join = true,
        max_bytes = output_bytes,
    })
end
local function capture_text(sample)
    if sample.omitted_bytes == 0 then
        return sample.text
    end
    return string.sub(sample.text, 1, sample.head_bytes)
        .. "\n[... output limited to " .. output_bytes .. " bytes; "
        .. sample.omitted_bytes .. " interior bytes omitted ...]\n"
        .. string.sub(sample.text, sample.head_bytes + 1)
end
local function incremental()
    local sample = capture(true)
    local previous = s.previous
    s.previous = sample
    if sample.omitted_bytes > 0 then
        return "Retained Terminal Output:\n" .. capture_text(sample)
    end
    if previous == nil then
        return "Current Terminal Screen:\n" .. capture_text(capture(false))
    end
    local current = sample.text
    local anchor = if previous.omitted_bytes == 0 then rt.trim(previous.text) else ""
    local position = if #anchor > 0 then string.find(current, anchor, 1, true) else nil
    local fresh = nil
    if position then
        fresh = string.sub(current, position + #anchor)
    end
    if fresh and #rt.trim(fresh) > 0 then
        return "New Terminal Output:\n" .. fresh
    end
    if #rt.trim(current) > 0 and (not position or rt.trim(current) ~= anchor) then
        return "The previous capture could not be matched reliably. Retained terminal history follows and may repeat earlier output:\n" .. current
    end
    return "Current Terminal Screen:\n" .. capture_text(capture(false))
end
local function send(command)
    local started = rt.call("clock.now", {}).ms
    local keys = key_names[command.keystrokes] or command.keystrokes
    if #keys > 0 then rt.call("process.write", {id = s.terminal, data = keys}) end
    local elapsed = rt.call("clock.now", {}).ms - started
    local remaining = math.ceil(math.min(command.duration, 60) * 1000 - elapsed)
    if remaining > 0 then rt.call("clock.sleep", {ms = remaining}) end
end
local function child(label, prompt, snapshot, ids, extra)
    local seed = {label = label, prompt = prompt, extra = extra}
    if snapshot then seed.snapshot = snapshot.id; seed.ids = ids end
    local result, id = rt.child(seed, snapshot, ids)
    table.insert(s.children, id)
    return result.text
end
local function compact()
    local snapshot = rt.snapshot()
    local groups = snapshot.data.groups
    if #groups == 0 then return input.task end
    s.compactions += 1
    local ids = rt.ids(snapshot)
    local summary_prompt = fill(prompts.summary_prompt, {task = input.task})
    local summary = child("summary", summary_prompt, snapshot, ids)
    local screen = capture_text(capture(false))
    local question_prompt = fill(prompts.question_prompt, {task = input.task, summary = summary, screen = screen})
    local questions = child("questions", question_prompt)
    local answer_prompt = "The next agent has a few questions for you, please answer each of them one by one in detail:\n\n" .. questions
    local answers = child("answers", answer_prompt, snapshot, ids, {
        {role = "user", content = summary_prompt}, {role = "assistant", content = summary},
    })
    local selected = rt.array()
    for index = 2, #groups do table.insert(selected, groups[index].id) end
    rt.call("context.commit", {snapshot = snapshot.id, selected = selected, after = groups[1].id,
        replacement = {{role = "user", content = question_prompt}, {role = "assistant", content = questions}}})
    return "Here are the answers the other agent provided.\n\n" .. answers .. "\n\n" ..
        "Continue working on this task from where the previous agent left off. You can no longer ask questions. Please follow the spec to interact with the terminal."
end
local function estimated_tokens(groups)
    local count = 0
    for _, group in ipairs(groups) do count += math.ceil((#group.content + #group.role) / 4) + 4 end
    return count
end
local function unwind()
    while true do
        local snapshot = rt.snapshot()
        local groups = snapshot.data.groups
        if #groups <= 1 or info.context_window - estimated_tokens(groups) >= 4000 then return end
        local selected = rt.array()
        for index = math.max(1, #groups - 1), #groups do table.insert(selected, groups[index].id) end
        rt.call("context.commit", {snapshot = snapshot.id, selected = selected, replacement = rt.array()})
    end
end
local function tail_characters(text, count)
    if utf8.len(text) <= count then return text end
    return string.sub(text, utf8.offset(text, -count))
end
local function recover_overflow()
    if input.enable_summarize == false then error("context_length_exceeded with summarization disabled") end
    local trigger = rt.call("events.begin", {})
    unwind()
    local ok, next_prompt = pcall(compact)
    if not ok then
        local screen = tail_characters(capture_text(capture(false)), 1000)
        local short_prompt = "Briefly continue this task: " .. input.task .. "\n\nCurrent state: " .. screen .. "\n\nNext steps (2-3 sentences):"
        local short_ok, summary = pcall(function() return child("short", short_prompt) end)
        next_prompt = if short_ok then input.task .. "\n\nSummary: " .. summary else input.task .. "\n\nCurrent state: " .. screen
    end
    rt.call("events.finish", {job = trigger.job})
    return next_prompt
end
local function query(prompt)
    local overflow_fallback = false
    for attempt = 1, 3 do
        local response = rt.generate(prompt)
        if response.ok and response.finish_reason == "completed" then return response
        elseif response.error == "output_incomplete" or response.finish_reason == "incomplete" then
            local parsed = parse_response(response.text or "")
            local warnings = if parsed.warning ~= "" then "\n\nParser warnings from your truncated response:\n" .. parsed.warning else ""
            prompt = "ERROR!! NONE of the actions you just requested were performed because you exceeded " .. info.max_output_tokens .. " tokens. Your outputs must be less than " .. info.max_output_tokens .. " tokens. Re-issue this request, breaking it into chunks each of which is less than " .. info.max_output_tokens .. " tokens." .. warnings
        elseif response.error == "context_length_exceeded" then
            if overflow_fallback then return {ok = true, text = "Technical difficulties. Please continue with the task."} end
            prompt = recover_overflow()
            overflow_fallback = true
        elseif overflow_fallback then
            return {ok = true, text = "Technical difficulties. Please continue with the task."}
        elseif attempt == 3 then error("model failure: " .. tostring(response.error)) end
    end
    error("output recovery exhausted")
end
if not s.terminal then
    local terminal = rt.call("process.spawn", {argv = {"/bin/bash", "--noprofile", "--norc", "-i"}, is_pty = true, columns = 100, rows = 30, description = "Terminus replica terminal"})
    s.terminal = terminal.id
    s.prompt = fill(prompts.initial, {instruction = input.task, terminal_state = incremental()})
end
rt.on("context_near_full", function() s.prompt = compact() end)
while type(input.max_turns) ~= 'number' or s.turn < input.max_turns do
    s.turn += 1
    if input.enable_summarize ~= false then
        rt.prepare(s.prompt)
    end
    local response = query(s.prompt)
    local parsed = parse_response(response.text)
    if parsed.error ~= "" then
        local feedback = "ERROR: " .. parsed.error
        if parsed.warning ~= "" then feedback ..= "\nWARNINGS: " .. parsed.warning end
        s.prompt = "Previous response had parsing errors:\n" .. feedback .. "\n\nPlease fix these issues and provide a proper JSON response."
        continue
    end
    for _, command in ipairs(parsed.commands) do send(command) end
    local output = incremental()
    if parsed.is_task_complete then
        if s.pending then
            return {status = "complete", turns = s.turn, compactions = s.compactions, children = s.children, terminal = s.terminal, output = output}
        end
        s.pending = true
        s.prompt = "Current terminal state:\n" .. output .. "\n\nAre you sure you want to mark the task as complete? This will trigger your solution to be graded and you won't be able to make any further corrections. If so, include \"task_complete\": true in your JSON response again."
    else
        s.pending = false
        s.prompt = if parsed.warning ~= "" then "Previous response had warnings:\nWARNINGS: " .. parsed.warning .. "\n\n" .. output else output
    end
end
return {status = "limit", turns = s.turn, compactions = s.compactions}
