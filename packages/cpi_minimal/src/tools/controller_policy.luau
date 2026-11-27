return function(event, state)
    if state.product ~= 'cpi-minimal' then return {allow=false} end
    if event.kind == 'command' then
        local commands={deliver=true,cancel_invocation=true,run=true,compact=true,branch=true,import_conversation=true,steer=true,input=true,lua=true,register_capability=true,unregister_capability=true}
        return {allow=commands[event.operation] == true}
    end
    if event.kind == 'snapshot' then return {allow=true} end
    if type(state.operations) ~= 'table' or state.operations[event.operation] ~= true then return {allow=false} end
    if event.operation == 'model.request' then
        local selected = if type(event.application_model) == 'table' then event.application_model else state.application_model
        if selected == nil then return {allow=true} end
        local body = event.arguments.body
        return {allow=type(body) == 'table' and body.model == selected.model
            and type(body.max_output_tokens) == 'number' and body.max_output_tokens >= 1
            and body.max_output_tokens % 1 == 0 and body.max_output_tokens <= selected.max_output_tokens
            and ((type(selected.reasoning_effort) ~= 'string' and body.reasoning == nil)
                or (type(selected.reasoning_effort) == 'string' and type(body.reasoning) == 'table' and body.reasoning.effort == selected.reasoning_effort))}
    end
    if event.kind == 'model' then return {allow=event.operation == 'model.request'} end
    if event.kind ~= 'host' then return {allow=false} end
    if event.operation == 'harness.wait' or event.operation == 'script.output' then return {allow=true} end
    if event.operation == 'process.exec' then
        local args=event.arguments
        return {allow=args.cwd == state.workspace and #args.argv == 3 and args.argv[1] == '/bin/bash' and args.argv[2] == '-c' and args.environment == nil}
    end
    if event.operation == 'mcp.tools' or event.operation == 'mcp.call' or event.operation == 'mcp.resources.list'
        or event.operation == 'mcp.resources.read' then
        local args=event.arguments
        if type(state.mcp_servers) ~= 'table' or type(args) ~= 'table' then return {allow=false} end
        local function allowed(name)
            if type(name) ~= 'string' then return false end
            local normalized = {}
            for index=1,#name do
                local byte = string.byte(name, index)
                normalized[index] = byte == 45 and '_' or string.char(byte)
            end
            return state.mcp_servers[table.concat(normalized)] == true
        end
        return {allow=allowed(args.server)}
    end
    if event.operation == 'workspace.grep' or event.operation == 'workspace.find' or event.operation == 'workspace.ls' then
        return {allow=type(event.arguments.path) == 'string' and string.sub(event.arguments.path, 1, 1) == '/'}
    end
    return {allow=event.operation == 'files.read' or event.operation == 'files.write' or event.operation == 'text.normalize_nfkc'}
end
