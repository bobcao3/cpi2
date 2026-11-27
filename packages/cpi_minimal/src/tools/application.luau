if input.command == 'plan_compaction' then
    return sessionGraph().planCompaction(input.focus or '', if input.reason == 'threshold' then 'threshold' else 'manual')
end
if input.command == 'plan_tree_summary' then
    local graph = sessionGraph()
    if graph.state.run ~= nil or ctx.after_run ~= nil or ctx.foreground_continuation ~= nil then
        return {status='conversation_busy'}
    end
    return graph.planTreeSummary(input.at, input.focus or '')
end
if input.command ~= nil and input.command ~= 'configure' and input.command ~= 'select' and input.command ~= 'compact'
    and input.command ~= 'register_tools' and input.command ~= 'resume' and input.command ~= 'continue_turn' and input.command ~= 'reset'
    and input.command ~= 'drain_writes' and input.command ~= 'plan_abort_tools'
    and input.command ~= 'navigate_tree' and input.command ~= 'label_tree' then
    error('UnsupportedApplicationCommand', 0)
end
if input.admit_only ~= true and input.command ~= 'plan_abort_tools' then agent.restore() end
local freshSession = ctx.session == nil and options.conversation_head == nil
local session = sessionGraph()
local s = session.state
local loadout = toolLoadout(session)
local restoreOnOpen = input.command == 'configure' and input.restore_tool_selection == true
if not restoreOnOpen and (ctx.tool_launch ~= options.tool_policy.id or type(ctx.tool_names) ~= 'table') then
    loadout.restore(true)
end
local function setInstructions(config)
    config.instructions = loadout.instructions(ctx.tool_resources or options.tool_resources)
end
local function offeredTool(name)
    local admitted = if s.run then session.recordedSystem(s.run.response_id) else nil
    for _, descriptor in ipairs(if admitted then admitted.tools else loadout.tools()) do
        if descriptor.name == name then return descriptor end
    end
    return nil
end
local function scriptCanCall(name)
    return table.find(options.direct_tools or {}, name) == nil or offeredTool(name) ~= nil
end
local deferred = deferredTools(scriptCanCall)
local function admissionWait()
    return {status='admission_waiting', deadline_ms=agent.now() + 500}
end
local activeOwner = if s.run ~= nil then s.run else ctx.after_run
if input.command == 'navigate_tree' or input.command == 'label_tree' then
    if activeOwner ~= nil or ctx.foreground_continuation ~= nil then return {status='conversation_busy'} end
    if input.expected_revision ~= s.revision or type(input.at) ~= 'string' then return {status='stale_selection'} end
    local target = session.lookup(input.at)
    if target == nil then return {status='stale_selection'} end
    if input.command == 'navigate_tree' then
        local outgoing = s.head
        local anchor = if target.kind == 'input' then (if type(input.display_parent) == 'string' then input.display_parent else target.parent) else target.id
        if anchor == agent.decode('null') then anchor = nil end
        if anchor ~= nil and (type(anchor) ~= 'string' or session.lookup(anchor) == nil) then return {status='stale_selection'} end
        s.head = anchor
        if type(input.summary) == 'string' and #input.summary > 0 then
            session.append({kind='branch_summary', summary=input.summary, metadata={from=outgoing, details=input.details},
                summary_usage=input.summary_usage})
        else
            s.revision += 1
            ctx.tree_reopen = true
        end
        ctx.tree_navigation = {revision=s.revision, target=anchor or ''}
        loadout.restore(false)
        setInstructions(s.config)
        session.checkpoint({kind='selected'})
    else
        if type(input.label) ~= 'string' then return {status='invalid_label'} end
        local labels = ctx.tree_labels or {}
        local label = if #input.label == 0 then nil else input.label
        local timestamp = agent.now()
        labels[target.id] = if label == nil then nil else {text=label, at_ms=timestamp}
        ctx.tree_labels = labels
        session.append({kind='write', tree_label=true, data={target=target.id, label=label}, placed_at_ms=timestamp})
        session.checkpoint({kind='tree_label'})
    end
    return {status='completed'}
end
local abortTools = if type(input.abort_tools) == 'table' then input.abort_tools else nil
if abortTools ~= nil and activeOwner ~= nil and activeOwner.owner ~= nil and activeOwner.owner ~= abortTools.owner then
    return {status='completed'}
end
if activeOwner ~= nil and activeOwner.inbox_owner and activeOwner.owner ~= input.foreground_task then
    if input.command == nil or input.command == 'resume' then return admissionWait() end
    if input.command == 'compact' or input.command == 'select' or input.command == 'continue_turn' then
        return {status='conversation_busy'}
    end
end
if type(input.expected_selection) == 'string' then
    local previous = ctx.model_selection
    if input.expected_selection ~= (if type(previous) == 'table' then previous.id else '') then
        error('SessionSelectionChanged', 0)
    end
end
local previousConfig = s.config
local config = input.config or previousConfig or options.config
if input.preserve_thinking and s.config ~= nil and s.config.model == config.model then
    config.reasoning_effort = s.config.reasoning_effort
    config.thinking_level = s.config.thinking_level
end
s.config = config
if input.command == 'configure' and type(input.tool_resources) == 'table' then ctx.tool_resources = input.tool_resources end
if not restoreOnOpen then setInstructions(s.config) end
if type(input.selection) == 'table' and type(input.selection.id) == 'string' then
    input.selection.reasoning_effort = config.reasoning_effort or agent.decode('null')
    input.selection.thinking_level = config.thinking_level
    if input.launch_selection then
        ctx.launch_model_selection = input.selection
    else
        ctx.model_selection = input.selection
        ctx.launch_model_selection = nil
    end
elseif input.launch_selection then
    ctx.launch_model_selection = nil
end
local function result(status, text, err)
    local continuation = ctx.foreground_continuation
    if type(continuation) == 'table' and continuation.task == input.foreground_task then ctx.foreground_continuation = nil end
    s.context_tokens = session.tokens()
    return {status=status, text=text or '', error=err}
end
local function deferTask(kind, step, compacting)
    ctx.foreground_continuation = {task=input.foreground_task, kind=kind, compacting=compacting}
    return step
end
local generationHooks = options.generation_hooks or {}
local function stageGenerationHook(stage, data)
    if stage == 'request' then s.run.model_view = modelViewVersion end
    s.run.generation_hook = {stage=stage, revision=s.revision, data=data}
    return deferTask('generation_hook', {status='delegate', phase='generation_hook'})
end
local function takeGenerationHook(staged)
    local decision = input.generation_decision
    if type(decision) ~= 'table' or decision.stage ~= staged.stage or decision.revision ~= staged.revision
        or not session.takePhase('generation_hook') then
        return nil, deferTask('generation_hook', {status='delegate', phase='generation_hook'})
    end
    s.run.generation_hook = nil
    return if decision.value == agent.decode('null') then nil else decision.value, nil
end
local function scheduleRetry(run, hint, reply)
    local retry = session.nextRetry(run.retry, hint)
    if retry == nil then return false end
    run.retry = retry
    run.phase = 'retry_wait'
    if reply ~= nil then session.recordModel(reply, 'conversation') else session.checkpoint({kind='retry_scheduled'}) end
    return true
end
local function toolValue(captured)
    local value = captured.result
    if not captured.ok and value == nil then value = {content={{type='text', text=captured.error}}, isError=true} end
    if value == nil then value = {content={{type='text',text='null'}}} end
    return value
end
local function boundedToolValue(value)
    local ok, output = pcall(agent.encodeToolResult, value)
    if ok then return value end
    local diagnostic = {code='invalid_tool_output', message=tostring(output)}
    local failure = {content={{type='text', text=diagnostic.message}}, isError=true}
    return failure, diagnostic
end
local function toolResult(call, captured, replacement, diagnostic, images)
    local value = if replacement ~= nil then replacement.result else toolValue(captured)
    local control = if replacement ~= nil then replacement.control else captured.control
    if type(control) ~= 'table' or not captured.ok then control = nil
    elseif replacement ~= nil then
        control = {handoff=if type(control.handoff) == 'string' then control.handoff else nil,
            terminate=if control.terminate == true then true else nil}
    end
    -- execute_lua and after_tool replacements need the same check as registered tools.
    local invalid
    value, invalid = boundedToolValue(value)
    if invalid then diagnostic, control = invalid, nil end
    local normalized = type(images) == 'table'
    local entry = {kind='program', name=call.name, call_id=call.call_id, arguments=call.arguments, result=value,
        images=if normalized then images else captured.images, normalized_images=if normalized then true else nil,
        observations=session.observations(captured.observations)}
    local wire, malformed = modelToolOutput(entry)
    if malformed then diagnostic, control = malformed, nil end
    entry.output, entry.control, entry.diagnostic = wire, control, diagnostic
    entry.failed = not captured.ok or malformed ~= nil or (type(value)=='table' and value.isError==true)
    return session.append(entry)
end
local function afterToolEnabled()
    return options.after_tool == true and type(input.foreground_task) == 'string'
end
local function shouldNormalizeToolImages(captured)
    if options.normalize_tool_images ~= true or type(input.foreground_task) ~= 'string' then return false end
    if #(captured.images or {}) > 0 then return true end
    local value = captured.result
    if not toolEnvelope(value) or type(value.content) ~= 'table' then return false end
    for _, part in ipairs(value.content) do
        if type(part) == 'table' and part.type == 'image' and type(part.data) == 'string' and type(part.mimeType) == 'string' then return true end
    end
    return false
end
local function stageToolResult(call, captured, diagnostic)
    local value, invalid = boundedToolValue(toolValue(captured))
    local ok = captured.ok and not invalid
    s.run.tool_result = {call_id=call.call_id, captured={ok=ok, images=captured.images, observations=captured.observations},
        reply={result=value, control=if ok then captured.control else nil, diagnostic=invalid or diagnostic}}
    s.run.phase = 'tool_result'
    ctx.__capture = nil
    session.checkpoint({kind='tool_result_ready'})
    return deferTask('tool_result', {status='delegate', phase='after_tool'})
end
local function toolDecision(phase, call)
    local decision = input.tool_decision
    if type(decision) == 'table' and decision.call_id == call.call_id and decision.response == s.run.response_id and session.takePhase(phase) then
        return decision
    end
    return nil
end
local function invalidToolArguments(call, arguments, schema)
    local ok, detail = pcall(agent.validate, arguments, schema, call.name)
    if not ok then return {code='invalid_arguments', message=tostring(detail)} end
    return nil
end
local function prepareTool(call)
    local before = options.before_tool == true and type(input.foreground_task) == 'string' or s.run.tool_preflight
    local descriptor = offeredTool(call.name)
    if descriptor == nil or (call.name ~= 'execute_lua' and type(tools[call.name]) ~= 'function') then
        return {code='tool_unavailable', message='Tool ' .. call.name .. ' is not available.'}, nil
    end
    if s.run.tool_prepared or (not before and not afterToolEnabled()) then return nil, nil end
    local schema = descriptor.parameters
    local invalid = invalidToolArguments(call, call.arguments, schema)
    if invalid ~= nil then return invalid, nil end
    if before then
        local decision = toolDecision('before_tool', call)
        if decision == nil then
            s.run.tool_preflight = true
            return nil, deferTask('tool_preflight', {status='delegate', phase='before_tool'})
        end
        s.run.tool_preflight = nil
        if decision.kind == 'blocked' or decision.kind == 'restart_limit' then
            return {code=decision.kind, message=decision.message}, nil
        end
        if decision.kind ~= 'execute' then error('InvalidToolHookDecision', 0) end
        invalid = invalidToolArguments(call, decision.arguments, schema)
        if invalid ~= nil then return invalid, nil end
        call.arguments = decision.arguments
        call.arguments_replaced = true
    end
    s.run.tool_prepared = true
    return nil, nil
end
local finishToolRound
local function interruptedCapture(call, message)
    local captured = ctx.__capture or {images=agent.decode('[]'), observations=agent.decode('[]')}
    captured.ok, captured.error = false, message or 'Interrupted before a tool result was recorded. Inspect the current state before repeating the operation.'
    if captured.script ~= nil then
        captured.result = interruptedScript(captured.script, call.call_id, captured.error, agent.now())
    end
    return captured
end
local function abortedTool(call, first, reason, at)
    local code, message
    if offeredTool(call.name) == nil then
        code, message = 'tool_unavailable', 'Tool ' .. call.name .. ' is not available.'
    elseif reason == 'restart_limit' then
        code, message = 'restart_limit', 'Tool ' .. call.name .. ' reached the restart limit.'
    elseif reason == 'restart' and (not first or (s.run.phase ~= 'tool' and s.run.phase ~= 'tool_result')) then
        code, message = 'abandoned', 'Tool ' .. call.name .. ' did not start because its caller restarted.'
    elseif reason == 'restart' or reason == 'indeterminate_effect' then
        code, message = 'interrupted', 'Tool ' .. call.name .. ' was interrupted and may have partially run.'
    else
        code, message = 'aborted', 'Tool ' .. call.name .. ' was aborted.'
    end
    local staged = if first then s.run.tool_result else nil
    if staged ~= nil and staged.call_id ~= call.call_id then staged = nil end
    local partial = if staged ~= nil then staged.captured else if first then ctx.__capture else nil
    local captured = {ok=false, error=message, images=partial and partial.images, observations=partial and partial.observations}
    local reply = if staged ~= nil then staged.reply.result else
        interruptedScript(partial and partial.script, call.call_id,
            if code == 'aborted' then 'Script aborted: This operation was aborted' else message, at) or toolValue(captured)
    return captured, {
        result=reply,
        diagnostic={code=code, message=message},
    }
end
if input.command == 'plan_abort_tools' then
    local calls = agent.decode('[]')
    if s.run == nil or (s.run.owner ~= nil and s.run.owner ~= input.owner) then return {calls=calls} end
    for i, call in ipairs(s.run.pending) do
        local _, reply = abortedTool(call, i == 1, input.reason, input.at_ms)
        table.insert(calls, {call=call, reply=reply})
    end
    return {response=s.run.response_id, calls=calls}
end
local function interruptedTool(message, boundary, abortDecision)
    local call = s.run.pending[1]
    local staged = s.run.tool_result
    local entry
    if abortTools ~= nil then
        local captured, raw = abortedTool(call, true, abortTools.reason, abortTools.at_ms)
        local reply = if type(abortDecision) == 'table' and abortDecision.response == s.run.response_id
            and abortDecision.call_id == call.call_id then abortDecision.reply else raw
        entry = toolResult(call, captured, reply, raw.diagnostic)
    else
        entry = if staged ~= nil then toolResult(call, staged.captured, staged.reply, staged.reply.diagnostic)
            else toolResult(call, interruptedCapture(call, message))
    end
    ctx.__capture = nil
    s.run.tool_result = nil
    s.run.tool_preflight = nil
    s.run.tool_prepared = nil
    table.remove(s.run.pending, 1)
    s.run.phase = 'model'
    s.run.retry_safe = nil
    s.run.terminate_round = false
    local handoff
    if boundary then
        ctx.steering_boundary = nil
        ctx.reset_boundary = #s.run.pending == 0
        if ctx.reset_boundary then handoff = finishToolRound() end
    end
    session.checkpoint({kind='tool_end', id=entry.id, call_id=call.call_id, name=call.name, data=entry.result, handoff=handoff}, boundary)
end
local interrupted = ctx.__interrupted_application
local continuation = ctx.foreground_continuation
local continuing = input.command == 'resume' and type(continuation) == 'table' and continuation.task == input.foreground_task
local unstarted = nil
local continuedWithoutAnswer = false
if type(interrupted) == 'table' and s.run == nil and type(interrupted.input_json) == 'string' then
    local saved = agent.decode(interrupted.input_json)
    continuedWithoutAnswer = type(saved) == 'table' and saved.command == 'continue_turn'
        and type(saved.submission) == 'string' and saved.submission == s.last_submission
    if type(saved) == 'table' and (saved.command == nil or saved.command == 'compact' or saved.command == 'continue_turn' or saved.command == 'reset')
        and type(saved.submission) == 'string' and saved.submission ~= (if saved.command == 'reset' then ctx.last_reset else s.last_submission)
        and (type(saved.steering_invocation) ~= 'string' or saved.steering_invocation ~= ctx.admitted_invocation) then
        unstarted = saved
    end
end
local pendingRecovery = type(interrupted) == 'table' and (s.run ~= nil or unstarted ~= nil or continuedWithoutAnswer)
local resuming = input.command == 'resume' and (pendingRecovery or continuing)
local preserving = (input.command == 'register_tools' or (input.command == 'configure' and input.preserve_interrupted)) and (pendingRecovery or type(continuation) == 'table')
local recoveringGeneration = resuming and type(interrupted) == 'table' and s.run ~= nil and s.run.phase == 'generation' and interrupted.model_part == nil
local recoveredReply = if recoveringGeneration and type(interrupted.model_reply) == 'table' then interrupted.model_reply else nil
local recoverModel = recoveringGeneration and recoveredReply == nil and type(interrupted.model_resume) == 'number'
local recoverCompaction = resuming and type(interrupted) == 'table' and type(interrupted.model_part) == 'string' and ctx.compaction_progress ~= nil
local function startRun(admitted, inputId, first)
    s.last_submission = admitted.submission
    ctx.admitted_invocation = ctx.steering_invocation
    s.run = {phase='model', pending=agent.decode('[]'), overflow_attempted=false, input_id=inputId, owner=input.foreground_task, first=first,
        inbox_owner=if input.inbox_owner then true else nil,
        model_selection=if type(admitted.submission_selection) == 'table' then admitted.submission_selection else nil}
    ctx.steering_boundary = nil
    ctx.reset_boundary = nil
    ctx.__interrupted_application = nil
    ctx.foreground_continuation = nil
end
local function appendInput(admitted)
    session.recordSystem(loadout.tools())
    local custom = if type(admitted.entry) == 'table' then admitted.entry else nil
    return session.append({kind='input', text=admitted.text, original=admitted.original, submission=admitted.submission,
        user_content=admitted.user_content,
        event_kind=if custom then custom.kind else nil, data=if custom then custom.data else nil,
        placed_at_ms=if custom then agent.now() else nil})
end
local function beginTurn(admitted, first)
    session.reconcileThinking()
    local user = appendInput(admitted)
    startRun(admitted, user.id, first or user.id)
    session.checkpoint({kind='user', id=user.id, text=admitted.text})
end
local function settleRun(status, detail)
    if s.run == nil then return end
    local function receipt(inputId)
        local run = {status=status, input_entry=inputId}
        if status == 'answered' then run.answer_entry = detail else run.reason = detail end
        return run
    end
    if type(s.last_submission) == 'string' and string.sub(s.last_submission, 1, 8) == 'request/' then
        ctx.submission_outcome = {submission=s.last_submission, run=receipt(s.run.input_id)}
    end
    if s.run.joined ~= nil then
        local outcomes = {}
        for submission, inputId in pairs(s.run.joined) do
            if string.sub(submission, 1, 8) == 'request/' then outcomes[submission] = receipt(inputId) end
        end
        ctx.joined_submission_outcomes = outcomes
    end
    s.run = nil
end
local function answerRun(reason, answer)
    if options.after_run == true and type(input.foreground_task) == 'string' then
        ctx.after_run = {owner=input.foreground_task, inbox_owner=s.run.inbox_owner, summary={reason=reason, first=s.run.first or answer,
            answer=answer, last=s.head or answer}}
        ctx.foreground_continuation = {task=input.foreground_task, kind='after_run'}
    end
    settleRun('answered', answer)
end

local function holdInbox(terminalFailure)
    ctx.steering_boundary = nil
    ctx.reset_boundary = nil
    ctx.inbox_hold = (ctx.inbox_hold or 0) + 1
    ctx.inbox_hold_schema = 1
    ctx.inbox_failed_policy = if terminalFailure then options.after_failed_run else nil
end
local function drainWrites(idle, staged, claimed)
    local writes = claimed or agent.claimBoundaryInput(if idle then 'idle_writes' else 'writes')
    if writes == nil then return false end
    local receipts = {}
    local reset, first, activates = false, nil, false
    for _, write in ipairs(writes) do
        local draft = write.entry
        activates = activates or write.activates == true
        local head = if type(draft.head) == 'string' then draft.head else nil
        local stale = false
        if head == 'self' then
            settleRun('unanswered', 'reset')
            s.head = nil
            ctx.compaction_progress = nil
            reset = true
        elseif head ~= nil then
            stale = true
            for _, entry in ipairs(session.visible()) do if entry.id == head then stale = false; break end end
        end
        if stale then
            receipts[write.submission] = {reason='stale'}
        elseif draft.kind == 'pi.compaction' then
            local data = draft.data
            local entry = session.append({kind='checkpoint', submission=write.submission,
                summary=data.summary, first_kept=head, metadata=data.metadata,
                fork_summary_usage=if type(data.fork_summary_usage) == 'table' then data.fork_summary_usage else nil})
            s.context_tokens = session.tokens()
            if first == nil then first = entry.id end
            receipts[write.submission] = {entry=entry.id}
        else
            local entry = session.append({kind='write', submission=write.submission, event_kind=draft.kind, data=draft.data,
                model=if type(draft.model) == 'table' then draft.model else nil,
                edits=if type(draft.edits) == 'table' then draft.edits else nil,
                context_start=if head ~= 'self' then head else nil})
            if head == 'self' then entry.context_start = entry.id end
            if first == nil then first = entry.id end
            receipts[write.submission] = {entry=entry.id}
        end
    end
    ctx.write_receipts = receipts
    if not staged then session.checkpoint({kind='writes_placed'}) end
    return reset, first, activates
end
local function autoCompactEnabled()
    local runtime = agent.runtimeOptions()
    return runtime == nil or runtime.auto_compact ~= false
end
local function finalBoundary(claimed, writesStaged, first)
    if not writesStaged then
        local _, placed = drainWrites(false, true)
        first = placed
    end
    local prompts = claimed or agent.claimBoundaryInput('final')
    if prompts == nil then return nil end
    session.reconcileThinking()
    local placements, joined, added = {}, {}, agent.decode('[]')
    for index, prompt in ipairs(prompts) do
        local entry = appendInput(prompt)
        placements[prompt.submission] = entry.id
        if index == 1 then startRun(prompt, entry.id, first or entry.id) else joined[prompt.submission] = entry.id end
        table.insert(added, prompt.text)
    end
    s.run.joined = joined
    ctx.final_placements = placements
    ctx.foreground_continuation = {task=input.foreground_task, kind='generation'}
    return added
end
local function finishFailedRun(status, text, detail, reply)
    settleRun('unanswered', status)
    local event = {kind='submission_settled'}
    if reply ~= nil then
        event = {kind='model_result', id=session.append(session.modelEntry(reply, 'conversation'), true).id}
    end
    local claimed = if options.after_failed_run == 'continue' then nil else agent.claimBoundaryInput('recover_final')
    if options.after_failed_run == 'continue' or claimed ~= nil then
        event.inputs = finalBoundary(claimed)
        if event.inputs ~= nil then event.failed_run = status end
    else
        holdInbox(true)
    end
    session.checkpoint(event)
    if event.inputs ~= nil then return {status='delegate', phase='model'} end
    return result(status, text, detail)
end
local function replaceContext(note)
    s.head = nil
    ctx.compaction_progress = nil
    return session.append(if #note > 0 then {kind='input', text=note, original=note, reset=true} else {kind='branch', reset=true})
end
finishToolRound = function()
    local handoff = s.run.handoff
    if handoff ~= nil then replaceContext(handoff) end
    local terminate = s.run.terminate_round
    local answer = s.run.response_id
    s.run.handoff = nil
    s.run.terminate_round = nil
    s.run.response_id = nil
    if terminate then answerRun('terminate', answer) end
    return handoff
end
local function toolRoundEntries()
    local reverse, cursor = {}, s.head
    while cursor ~= s.run.response_id do
        local entry = session.lookup(cursor)
        if entry == nil then error('InvalidToolRound', 0) end
        if entry.kind == 'program' then table.insert(reverse, entry.id)
        elseif not isRetiredScriptStore(entry) then error('InvalidToolRound', 0) end
        cursor = entry.parent
    end
    local results = agent.decode('[]')
    for index = #reverse, 1, -1 do table.insert(results, reverse[index]) end
    return {assistant=s.run.response_id, results=results}
end
local function beginContinuation(admitted)
    local _, first = drainWrites()
    if ctx.continue_boundary ~= admitted.submission then
        ctx.steering_boundary = nil
        ctx.reset_boundary = nil
        ctx.continue_boundary = admitted.submission
        session.checkpoint({kind='continue_pending'})
    end
    local pending = agent.claimBoundaryInput()
    if pending == nil then error('InvalidContinuation', 0) end
    local entries, _, altered = session.modelEntries()
    local tail, lastRole
    for index = #entries, 1, -1 do
        local entry = entries[index]
        if entry.kind ~= 'write' then tail = entry; break end
        for part = #(entry.model or {}), 1, -1 do
            local role = entry.model[part].role
            if role == 'user' or role == 'assistant' then tail, lastRole = entry, role; break end
        end
        if tail ~= nil then break end
    end
    local joined, added = {}, agent.decode('[]')
    for _, prompt in ipairs(pending.prompts) do
        tail = appendInput(prompt)
        if first == nil then first = tail.id end
        lastRole = 'user'
        joined[prompt.submission] = tail.id
        table.insert(added, prompt.text)
    end
    ctx.continue_boundary = nil
    local answerable = tail ~= nil and (tail.kind == 'input' or tail.kind == 'program' or lastRole == 'user')
    if altered and #added == 0 then
        answerable = false
        local model = session.modelInput()
        for index = #model, 1, -1 do
            local item = model[index]
            if item.role ~= 'system' and item.role ~= 'developer' and item.type ~= 'reasoning' then
                answerable = item.role == 'user' or item.type == 'function_call_output'
                break
            end
        end
    end
    if not answerable or tail == nil then
        s.last_submission = admitted.submission
        ctx.__interrupted_application = nil
        holdInbox(true)
        session.checkpoint({kind='notice', text='Nothing to answer.'})
        return false
    end
    local anchor = tail.id
    if tail.kind == 'program' then
        for index = #entries, 1, -1 do
            if entries[index].kind == 'input' then anchor = entries[index].id; break end
        end
    end
    startRun(admitted, anchor, first)
    if #added > 0 then
        s.run.joined = joined
        s.run.model_selection = pending.prompts[1].submission_selection
        session.checkpoint({kind='continued_inputs', inputs=added})
    else session.checkpoint({kind='notice', text='Continuing the current context.'}) end
    return true
end
local function compactRun(kind)
    local compacted, step = session.compact('', nil, if kind == 'overflow_compaction' then 'overflow' else 'threshold')
    if step ~= nil then return deferTask(kind, step) end
    if not compacted and kind == 'overflow_compaction' then
        return finishFailedRun('overflow')
    end
    return nil
end
local function resetContext(admitted)
    settleRun('unanswered', 'reset')
    s.last_submission = nil
    ctx.continue_boundary = nil
    ctx.steering_boundary = nil
    ctx.reset_boundary = nil
    ctx.__interrupted_application = nil
    ctx.last_reset = admitted.submission
    local entry = replaceContext(admitted.note)
    if #admitted.note > 0 then
        session.checkpoint({kind='user', id=entry.id, text=entry.text})
    else
        session.checkpoint({kind='notice', text='Context reset.'})
    end
    drainWrites()
end
local function takeBoundary()
    if ctx.continue_boundary ~= nil or (ctx.steering_boundary == nil and not ctx.reset_boundary) then return nil end
    if ctx.reset_boundary then
        local reset, first = drainWrites(false, true)
        if reset then
            ctx.reset_boundary = nil
            local added = finalBoundary(nil, true, first)
            session.checkpoint({kind='continued_inputs', inputs=added})
            return if added ~= nil then 'successor' else 'reset'
        end
    end
    local admitted = agent.claimBoundaryInput()
    if admitted == nil then
        if ctx.reset_boundary then
            local added = agent.decode('[]')
            if s.run ~= nil and #s.run.pending == 0 then
                local steers = agent.claimBoundaryInput('post_tools')
                if steers ~= nil then
                    local placements = {}
                    s.run.joined = s.run.joined or {}
                    for _, steer in ipairs(steers) do
                        local entry = appendInput(steer)
                        s.run.joined[steer.submission] = entry.id
                        placements[steer.submission] = entry.id
                        table.insert(added, steer.text)
                    end
                    ctx.post_tool_placements = placements
                end
            end
            ctx.reset_boundary = nil
            session.checkpoint({kind='continued_inputs', inputs=added})
        end
        return nil
    end
    if admitted.command == 'reset' then
        resetContext(admitted)
        return 'reset'
    end
    while s.run ~= nil and #s.run.pending > 0 do interruptedTool('Steering superseded this tool call before it ran.') end
    settleRun('unanswered', 'steered')
    beginTurn(admitted)
    recoveredReply, recoverModel, recoverCompaction = nil, false, false
    return 'steer'
end
if input.command == 'drain_writes' then
    if s.run ~= nil and input.foreground_task ~= nil and s.run.owner == input.foreground_task then
        return {status='delegate', phase='model'}
    end
    if ctx.after_run ~= nil then return {status='after_run_pending'} end
    if s.run ~= nil or (ctx.compaction_progress ~= nil and (type(continuation) == 'table' or type(interrupted) == 'table')) then return admissionWait() end
    ctx.steering_invocation = input.steering_invocation
    local _, first, activates = drainWrites(true, true)
    if activates == nil then return admissionWait() end
    local inputs = if activates and input.foreground_task ~= nil then finalBoundary(nil, true, first) else nil
    session.checkpoint({kind='writes_placed', inputs=inputs})
    if input.admit_only == true then return {admission_commit=true} end
    if inputs ~= nil then return {status='delegate', phase='model'} end
    return result('completed')
end
if ctx.after_run ~= nil then
    if input.command == 'resume' and input.foreground_task == ctx.after_run.owner then
        if input.foreground_phase ~= 'after_run' then return {status='delegate', phase='after_run'} end
        ctx.after_run = nil
        ctx.reset_boundary = true
        ctx.__interrupted_application = nil
        local added = finalBoundary()
        session.checkpoint({kind='continued_inputs', inputs=added})
        if added ~= nil then return {status='delegate', phase='model'} end
        takeBoundary()
        return result('completed')
    elseif input.command == 'configure' then
        if input.end_run == 'cancelled' or input.end_run == 'faulted' or input.end_run == 'after_run_interrupted' then
            ctx.after_run = nil
            holdInbox()
        end
    elseif input.command ~= 'register_tools' then
        return {status='conversation_busy'}
    end
end
if not resuming and not preserving then
    if input.command == 'configure' and input.end_run == 'cancelled' and type(interrupted) == 'table' and interrupted.model_reply == nil then
        ctx.cancelled_model_resume = interrupted.model_resume
    end
    ctx.__interrupted_application = nil
    ctx.foreground_continuation = nil
    ctx.continue_boundary = nil
end
if s.run ~= nil and not resuming and not preserving then
    local decisions = if abortTools ~= nil and type(abortTools.decisions) == 'table' then abortTools.decisions else {}
    while #(s.run.pending or {}) > 0 do
        interruptedTool(nil, false, decisions[s.run.pending[1].call_id])
    end
    settleRun('unanswered', if input.command == 'reset' then 'reset' else input.end_run or 'superseded')
    if input.end_run == 'cancelled' or input.end_run == 'faulted' then holdInbox() end
end
if input.command == 'register_tools' then
    return deferred.install(input.batch, if type(input.submission) == 'string' then input.submission else nil)
end
if input.command == 'configure' then
    if input.end_run == 'compaction_interrupted' or ((input.end_run == 'cancelled' or input.end_run == 'faulted')
        and ctx.compaction_progress ~= nil and ctx.compaction_progress.hook ~= nil) then
        ctx.compaction_progress = nil
    end
    if not preserving and s.run == nil and ctx.after_run == nil then
        if ctx.tree_reopen == true and type(input.reopen_tip) == 'table' then
            local tip = input.reopen_tip
            local head = if type(tip.head) == 'string' then tip.head else nil
            if type(tip.target) ~= 'string' or session.lookup(tip.target) == nil
                or (head ~= nil and session.lookup(head) == nil) then error('InvalidSessionParent', 0) end
            s.head = head
            s.revision += 1
            ctx.tree_navigation = {revision=s.revision, target=tip.target}
            ctx.tree_reopen = nil
        end
        session.configureTree(input.tree_settings, freshSession, input.selection, previousConfig)
    end
    if restoreOnOpen then
        ctx.tool_resources = nil
        loadout.restore(true)
        setInstructions(s.config)
    end
    session.checkpoint({kind='configured'})
    return result('completed')
end
if input.command == 'select' then
    if input.expected_revision ~= s.revision or session.lookup(input.at) == nil then return result('stale_selection') end
    s.head = input.at
    loadout.restore(false)
    setInstructions(s.config)
    session.append({kind='branch'})
    session.checkpoint({kind='selected'})
    return result('completed')
end
if resuming and continuedWithoutAnswer then
    ctx.__interrupted_application = nil
    return result('nothing_to_answer')
end
local admitted = if input.command == 'resume' then unstarted else input
if admitted ~= nil and admitted.command == 'reset' then
    resetContext(admitted)
    return result('completed')
end
ctx.steering_invocation = input.steering_invocation
local compacting = if input.command == 'compact' then input
    elseif continuing and continuation.kind == 'manual_compaction' then continuation.compacting
    elseif resuming and unstarted ~= nil and unstarted.command == 'compact' then unstarted
    else nil
if compacting ~= nil then
    if resuming and type(interrupted) == 'table' and not recoverCompaction and not session.compactionWaiting() then
        interrupted.restarts = (interrupted.restarts or 0) + 1
        if interrupted.restarts >= 5 then
            ctx.__interrupted_application = nil
            ctx.compaction_progress = nil
            s.last_submission = compacting.submission
            return result('restart_limit', '', {message='The interrupted compaction reached its restart limit.'})
        end
        session.checkpoint({kind='notice', text='Resuming interrupted compaction.'})
    end
    local reason = compacting.reason or 'manual'
    local ok, compacted, step, declined = pcall(session.compact, compacting.focus or '', compacting.submission, reason)
    if ok and step ~= nil then
        return deferTask('manual_compaction', step, {focus=compacting.focus, submission=compacting.submission, reason=reason})
    end
    ctx.__interrupted_application = nil
    if type(compacting.submission) == 'string' then s.last_submission = compacting.submission end
    if not ok then return result('compaction_failed', '', {message=tostring(compacted)}) end
    if not compacted and not resuming and not declined then return result('nothing_to_compact') end
    return result('completed')
end
local boundary = if input.command == 'resume' then takeBoundary() else nil
if boundary == 'reset' then
    return result('completed')
elseif boundary == 'successor' then
    return {status='delegate', phase='model'}
elseif boundary == 'steer' then
elseif input.command == 'resume' and unstarted == nil then
    if not resuming or s.run == nil then return result('completed') end
    local waiting = type(interrupted) ~= 'table' or s.run.phase == 'retry_wait' or s.run.phase == 'tool_result' or s.run.generation_hook ~= nil
        or session.compactionWaiting() or recoverModel or recoverCompaction or recoveredReply ~= nil
    if not waiting then s.run.restarts = (s.run.restarts or 0) + 1 end
    if not waiting and (s.run.restarts or 0) >= 5 then
        if s.run.phase == 'tool' and #s.run.pending > 0 then
            s.run.restarts = 0
            if afterToolEnabled() or generationHooks.tools then
                local captured = interruptedCapture(s.run.pending[1], 'The interrupted tool reached its restart limit.')
                return stageToolResult(s.run.pending[1], captured, {code='restart_limit', message=captured.error})
            end
            session.takePhase('tool')
            interruptedTool('restart_limit: the interrupted tool reached its restart limit.', true)
            boundary = takeBoundary()
            if boundary == 'reset' then return result('completed') end
            if boundary == 'successor' then return {status='delegate', phase='model'} end
        else
            while #s.run.pending > 0 do interruptedTool() end
            ctx.__interrupted_application = nil
            return finishFailedRun('restart_limit', '', {message='The interrupted turn reached its restart limit.'})
        end
    elseif s.run.phase == 'tool' and #s.run.pending > 0 then
        if s.run.retry_safe and agent.toolRecovery(s.run.pending[1].name) == 'retry_safe' then
            ctx.__capture = nil
            s.run.tool_prepared = true
        else
            if afterToolEnabled() or generationHooks.tools then
                local captured = interruptedCapture(s.run.pending[1])
                return stageToolResult(s.run.pending[1], captured, {code='interrupted', message=captured.error})
            end
            session.takePhase('tool')
            interruptedTool(nil, true)
            boundary = takeBoundary()
            if boundary == 'reset' then return result('completed') end
            if boundary == 'successor' then return {status='delegate', phase='model'} end
        end
    elseif s.run.phase == 'generation' and recoveredReply == nil and not recoverModel then
        s.run.request_messages = nil
        if not scheduleRetry(s.run, 0) then
            ctx.__interrupted_application = nil
            return finishFailedRun('interrupted', '', {message='The interrupted model request has no retry left.'})
        end
    end
    local stagedResponse = s.run.generation_hook ~= nil and s.run.generation_hook.stage == 'response'
    if type(interrupted) == 'table' and not stagedResponse and not (continuing and (recoverModel or recoverCompaction)) then
        session.checkpoint({kind='notice', text='Resuming interrupted turn.'})
    end
    if not stagedResponse and not recoverModel and not recoverCompaction and recoveredReply == nil then ctx.__interrupted_application = nil end
else
    if admitted.command == 'continue_turn' then
        if not beginContinuation(admitted) then return result('nothing_to_answer') end
        session.recordSystem(loadout.tools())
    else
        if type(admitted.submission) ~= 'string' then return result('nothing_to_answer') end
        local queued = agent.claimBoundaryInput('idle:' .. admitted.submission)
        if queued ~= nil then
            session.checkpoint({kind='continued_inputs', inputs=finalBoundary(queued)})
        else
            if not agent.claimBoundaryInput('prompt:' .. admitted.submission) then return result('nothing_to_answer') end
            local _, first = drainWrites()
            beginTurn(admitted, first)
        end
    end
end
if input.admit_only == true then
    if s.run == nil then return {admission_commit=false} end
    return deferTask('generation', {admission_commit=true})
end
while true do
    if #s.run.pending == 0 then
        local staged = s.run.generation_hook
        -- Hook decisions may replace the entire message list. There is no safe
        -- field-by-field migration of a decision computed from old raw results.
        -- For an unsent request restart projection (including before_request).
        if s.run.model_view ~= modelViewVersion then
            if staged ~= nil and staged.stage == 'request' then
                staged, s.run.generation_hook = nil, nil
            end
            s.run.request_messages = nil
        end
        if staged ~= nil and staged.stage == 'tools' then
            local _, step = takeGenerationHook(staged)
            if step ~= nil then return step end
            local handoff = finishToolRound()
            ctx.reset_boundary = ctx.after_run == nil
            local added = if s.run == nil and ctx.after_run == nil then finalBoundary() else nil
            session.checkpoint({kind='continued_inputs', handoff=handoff, inputs=added}, true)
            if ctx.after_run ~= nil then return {status='delegate', phase='after_run'} end
            if added ~= nil then return {status='delegate', phase='model'} end
            boundary = takeBoundary()
            if boundary == 'reset' then return result('completed') end
            if boundary == 'successor' then return {status='delegate', phase='model'} end
            if s.run == nil then return result('completed') end
            continue
        end
        local reply, yielded
        if staged ~= nil and staged.stage == 'response' then
            local step
            yielded, step = takeGenerationHook(staged)
            if step ~= nil then return step end
            reply = ctx.__interrupted_application.model_reply
            ctx.__interrupted_application = nil
        else
            if staged == nil and s.run.request_messages == nil then
                if s.run.phase == 'retry_wait' then
                    ctx.steering_boundary = nil
                    local deadline = session.waitForRetry(s.run.retry)
                    if deadline ~= nil then return deferTask('generation', {status='waiting', deadline_ms=deadline}) end
                    s.run.phase = 'model'
                elseif continuing and continuation.kind == 'overflow_compaction' and ctx.compaction_progress ~= nil then
                    local outcome = compactRun('overflow_compaction')
                    if outcome ~= nil then return outcome end
                    recoverCompaction = false
                elseif recoverCompaction or (not s.run.skip_threshold_compaction and not recoverModel and recoveredReply == nil) then
                    if recoverCompaction or (resuming and ctx.compaction_progress ~= nil) then
                        local outcome = compactRun('threshold_compaction')
                        if outcome ~= nil then return outcome end
                        recoverCompaction = false
                    elseif autoCompactEnabled() then
                        local estimate = session.tokens()
                        local blockingThreshold = s.config.context_window - s.config.reserve_tokens
                        if estimate > blockingThreshold then
                            local outcome = compactRun('threshold_compaction')
                            if outcome ~= nil then return outcome end
                        elseif session.stageBackgroundCompaction(estimate, blockingThreshold) then
                            return deferTask('generation', {status='delegate', phase='model'})
                        end
                    end
                end
            end
            if staged ~= nil then
                local messages, step = takeGenerationHook(staged)
                if step ~= nil then return step end
                s.run.request_messages = messages or staged.data
                return deferTask('generation', {status='delegate', phase='model'})
            end
            if generationHooks.request and type(input.foreground_task) == 'string' and s.run.request_messages == nil
                and not recoverModel and recoveredReply == nil then
                return stageGenerationHook('request', session.modelInput())
            end
            if not session.takePhase('model') and recoveredReply == nil then
                return deferTask('generation', {status='delegate', phase='model'})
            end
            s.run.skip_threshold_compaction = nil
            ctx.steering_boundary = nil
            ctx.reset_boundary = nil
            if not recoverModel and recoveredReply == nil then
                s.run.model_view = modelViewVersion
                if session.recordSystem(loadout.tools()) then
                    -- The next provider action can checkpoint the head on its own.
                    session.checkpoint({kind='system'})
                end
            end
            s.run.phase = 'generation'
            local admitted = if recoverModel then session.recordedSystem(s.head) else nil
            reply = recoveredReply or agent.model({model=s.config.model, instructions=if admitted then admitted.instructions else s.config.instructions,
                input=modelRequestInput(s.run.request_messages or session.modelInput()), tools=if admitted then admitted.tools else loadout.tools(),
                max_output_tokens=s.config.max_output_tokens, reasoning=if type(s.config.reasoning_effort) == 'string' then {effort=s.config.reasoning_effort} else nil}, recoverModel,
                options.provider_payload_hook == true)
            if reply.status == 'poll_pending' then
                ctx.__interrupted_application = reply.continuation
                return deferTask('generation', {status='waiting', deadline_ms=reply.next_poll_ms})
            end
            local retained = recoveredReply ~= nil
            recoveredReply, recoverModel = nil, false
            s.run.phase = 'model'
            s.run.restarts = 0
            s.run.request_messages = nil
            if generationHooks.response and type(input.foreground_task) == 'string' then
                local step = stageGenerationHook('response')
                if not retained then step.retain_model_reply = true end
                return step
            end
            ctx.__interrupted_application = nil
        end
        if reply.retryable == true and scheduleRetry(s.run, reply.retry_after_ms, reply) then continue end
        s.run.retry = nil
        if reply.status == 'overflow' then
            if s.run.overflow_attempted or not autoCompactEnabled() then
                return finishFailedRun('overflow', reply.text, reply.error, reply)
            end
            s.run.overflow_attempted = true
            session.recordModel(reply, 'conversation')
            local outcome = compactRun('overflow_compaction')
            if outcome ~= nil then return outcome end
            continue
        end
        if reply.status ~= 'completed' and reply.stop_reason ~= 'length' then
            return finishFailedRun(reply.status, reply.text, reply.error, reply)
        end
        local entry = session.modelEntry(reply, 'response')
        entry.model_view = s.run.model_view -- version of the request, not the executable reading the reply
        local response = session.append(entry)
        s.run.pending = reply.calls
        s.run.response_id = response.id
        if #reply.calls > 0 then s.run.terminate_round = true end
        if yielded ~= nil then
            local writes = agent.claimBoundaryInput('yield_writes')
            if writes ~= nil then
                if #writes > 0 then drainWrites(false, true, writes) end
                local nextText = session.content(yielded)
                local user = session.append({kind='input', text=nextText, original=nextText,
                    user_content=if type(yielded) == 'table' then yielded else nil})
                s.run.first = s.run.first or user.id
                s.run.response_id = nil
                local step = deferTask('generation', {status='delegate', phase='model'})
                session.checkpoint({kind='assistant', id=response.id, tokens=session.tokens(), inputs={nextText}}, true)
                return step
            end
        end
        if #reply.calls == 0 then answerRun('answer', response.id) end
        ctx.steering_boundary = nil
        ctx.reset_boundary = #reply.calls == 0 and ctx.after_run == nil
        local added = if s.run == nil and ctx.after_run == nil then finalBoundary() else nil
        session.checkpoint({kind='assistant', id=response.id, tokens=session.tokens(), inputs=added}, true)
        if ctx.after_run ~= nil then return {status='delegate', phase='after_run'} end
        if added ~= nil then return {status='delegate', phase='model'} end
        boundary = takeBoundary()
        if boundary == 'reset' then return result('completed') end
        if boundary == 'successor' then return {status='delegate', phase='model'} end
        if boundary == 'steer' then continue end
        if s.run == nil then return result('completed', text) end
    end
    while #s.run.pending > 0 do
        local call = s.run.pending[1]
        local staged = s.run.tool_result
        local captured, replacement, diagnostic, images
        if staged ~= nil then
            local decision = toolDecision('after_tool', call)
            if decision == nil then return deferTask('tool_result', {status='delegate', phase='after_tool'}) end
            captured, replacement, diagnostic, images = staged.captured, decision.reply, staged.reply.diagnostic, decision.images
        else
            local step
            diagnostic, step = prepareTool(call)
            if step ~= nil then return step end
            if diagnostic ~= nil then
                captured = {ok=false, error=diagnostic.message, images=agent.decode('[]'), observations=agent.decode('[]')}
            else
                if not session.takePhase('tool') then return deferTask('tool', {status='delegate', phase='tool'}) end
                ctx.steering_boundary = nil
                ctx.reset_boundary = nil
                s.run.phase = 'tool'
                s.run.retry_safe = agent.toolRecovery(call.name) == 'retry_safe'
                session.checkpoint({kind='tool_start', id=s.run.response_id or s.head, call_id=call.call_id, name=call.name,
                    effective_arguments=if call.arguments_replaced then call.arguments else nil})
                if call.name == 'execute_lua' then
                    captured = captureLuaScript(call.arguments.source, deferred, call.call_id)
                else
                    captured = agent.capture(function()
                        local tool = tools[call.name]
                        if type(tool) ~= 'function' then error('unsupported tool: ' .. tostring(call.name), 0) end
                        return tool(call.arguments)
                    end)
                end
                if not captured.ok and afterToolEnabled() then diagnostic = {code='tool_error', message=captured.error} end
            end
            if afterToolEnabled() or shouldNormalizeToolImages(captured) then return stageToolResult(call, captured, diagnostic) end
        end
        local entry = toolResult(call, captured, replacement, diagnostic, images)
        local control = entry.control
        if control ~= nil and control.handoff ~= nil then s.run.handoff = control.handoff end
        s.run.terminate_round = s.run.terminate_round == true and control ~= nil and control.terminate == true
        table.remove(s.run.pending, 1)
        s.run.tool_result = nil
        s.run.tool_preflight = nil
        s.run.tool_prepared = nil
        s.run.phase = 'model'
        s.run.retry_safe = nil
        s.run.restarts = 0
        ctx.steering_boundary = nil
        if #s.run.pending == 0 and generationHooks.tools and type(input.foreground_task) == 'string' then
            ctx.reset_boundary = nil
            local step = stageGenerationHook('tools', toolRoundEntries())
            session.checkpoint({kind='tool_end', id=entry.id, call_id=call.call_id, name=call.name, data=entry.result}, true)
            return step
        end
        ctx.reset_boundary = #s.run.pending == 0
        local handoff = if ctx.reset_boundary then finishToolRound() else nil
        if ctx.after_run ~= nil then ctx.reset_boundary = nil end
        local added = if s.run == nil and ctx.after_run == nil then finalBoundary() else nil
        session.checkpoint({kind='tool_end', id=entry.id, call_id=call.call_id, name=call.name, data=entry.result, handoff=handoff, inputs=added}, true)
        if ctx.after_run ~= nil then return {status='delegate', phase='after_run'} end
        if added ~= nil then return {status='delegate', phase='model'} end
        boundary = takeBoundary()
        if boundary == 'reset' then return result('completed') end
        if boundary == 'successor' then return {status='delegate', phase='model'} end
        if boundary == 'steer' then break end
        if s.run == nil then return result('completed') end
    end
end
s.run = nil
