-- Launch constraints come from the current worker. The active names follow
-- the conversation, and recovered calls use the descriptors on their response.
local function toolLoadout(session)
    local policy = options.tool_policy
    local catalog = {}
    for _, descriptor in ipairs(options.tool_catalog) do catalog[descriptor.name] = descriptor end
    local descriptors

    local function selectNames(names, wanted)
        local selected = agent.decode('[]')
        for _, list in ipairs({names, wanted}) do
            for _, name in ipairs(list) do
                if catalog[name] and table.find(policy.allowed, name) and table.find(wanted, name)
                    and not table.find(selected, name) then
                    table.insert(selected, name)
                end
            end
        end
        ctx.tool_names = selected
        ctx.tool_launch = policy.id
        descriptors = nil
    end

    local function restoredNames(head)
        local snapshot = session.recordedSystem(head)
        if snapshot == nil or type(snapshot.tools) ~= 'table' then return nil end
        -- Before tool selection existed, Minimal advertised its Luau helper
        -- unconditionally and annotated the four built-in descriptions.
        local legacy = false
        for _, descriptor in ipairs(snapshot.tools) do
            if descriptor.strict == false and type(descriptor.description) == 'string'
                and string.find(descriptor.description, '\n\nCodemode:', 1, true) then legacy = true; break end
        end
        local names = {}
        for _, descriptor in ipairs(snapshot.tools) do
            if not legacy or descriptor.name ~= 'execute_lua' then table.insert(names, descriptor.name) end
        end
        return names
    end

    local function restore(launch)
        local current = if launch then policy.initial else (ctx.tool_names or policy.initial)
        local restored = if not launch or policy.restore_at_launch then restoredNames(session.state.head) else nil
        if restored == nil then
            selectNames(current, current)
            return
        end
        if launch then
            for _, modifier in ipairs(policy.modifiers) do
                local name = string.sub(modifier, 2)
                local index = table.find(restored, name)
                if string.sub(modifier, 1, 1) == '+' then
                    if index == nil then table.insert(restored, name) end
                elseif index ~= nil then
                    table.remove(restored, index)
                end
            end
            if policy.auto_script and not table.find(restored, 'execute_lua') then table.insert(restored, 'execute_lua') end
        end
        selectNames(if launch then {} else current, restored)
    end

    local function toolsForRequest()
        if descriptors == nil then
            descriptors = agent.decode('[]')
            for _, name in ipairs(ctx.tool_names or policy.initial) do table.insert(descriptors, catalog[name]) end
        end
        return descriptors
    end

    local function instructions(resources)
        local text = options.tool_prompt
        local names = ctx.tool_names
        local bash = table.find(names, 'bash') ~= nil
        local read = table.find(names, 'read') ~= nil
        local script = table.find(names, 'execute_lua') ~= nil
        local parts = {text.preamble, '\n\n<tools>\n'}
        if #names == 0 then table.insert(parts, '(none)\n') end
        for _, name in ipairs(names) do table.insert(parts, '- ' .. name .. ': ' .. text.snippets[name] .. '\n') end
        table.insert(parts, '\nAdditional tools may be available.\n</tools>\n\n<rules>\n')
        if bash then
            local hasSearch = false
            for _, name in ipairs(text.bash_files.unless) do
                if table.find(names, name) then hasSearch = true; break end
            end
            if not hasSearch then table.insert(parts, text.bash_files.rule) end
        end
        for _, name in ipairs(names) do
            if name ~= 'read' or bash then table.insert(parts, text.rules[name]) end
        end
        table.insert(parts, text.general_rules .. '</rules>\n\n')
        local skills = if read then resources.read_skills elseif bash then resources.bash_skills else ''
        if skills ~= '' then table.insert(parts, '<skills>\n' .. skills .. '\n</skills>\n\n') end
        table.insert(parts, '<cwd>\n' .. resources.cwd .. '\n</cwd>\n\n')
        if script and resources.mcp ~= '' then table.insert(parts, '<mcp_servers>\n' .. resources.mcp .. '\n</mcp_servers>\n\n') end
        return table.concat(parts)
    end

    return {restore=restore, tools=toolsForRequest, instructions=instructions}
end
