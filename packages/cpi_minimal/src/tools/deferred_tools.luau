local function deferredTools(canCall)
    local discover, remoteCall = tools.mcp_discover, tools.mcp_call
    local saveOutput = tools.script_output
    local reserved = {discover_tools=true, search_tools=true, describe_tool=true, describe_namespace=true, register_deferred_tools=true}
    for name in pairs(tools) do reserved[name] = true end
    tools.mcp_discover, tools.mcp_call, tools.script_output = nil, nil, nil
    local installed = {}
    local scriptTools = nil
    local wrapScriptTool = nil

    local function syncScriptTools()
        if scriptTools == nil or table.isfrozen(scriptTools) then return end
        table.clear(scriptTools)
        for name, helper in pairs(tools) do
            if canCall(name) then
                scriptTools[name] = wrapScriptTool(name, helper)
            end
        end
    end

    local function validName(name)
        if type(name) ~= 'string' or #name == 0 then return false end
        for index=1,#name do
            local byte = string.byte(name, index)
            local letter = (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or byte == 95
            if not letter and not (index > 1 and byte >= 48 and byte <= 57) then return false end
        end
        return true
    end

    local function validDefinition(entry, compile)
        if type(entry) ~= 'table' or not validName(entry.name) or reserved[entry.name] then
            error('InvalidDeferredToolName', 0)
        end
        agent.warnSize('deferred tool name bytes', #entry.name, 64)
        if type(entry.description) ~= 'string' or type(entry.parameters) ~= 'table'
            or type(entry.handler) ~= 'table' then error('InvalidDeferredToolDefinition', 0) end
        local handler = entry.handler
        if handler.kind == 'luau' then
            agent.checkSchema(entry.parameters)
            if entry.parameters.type ~= 'object' then error('DeferredToolParametersMustBeObject', 0) end
            if type(handler.source) ~= 'string' or #handler.source == 0 then
                error('InvalidDeferredToolSource', 0)
            end
            agent.warnSize('deferred tool source bytes', #handler.source, 1048576)
            if compile then return agent.compile(handler.source) end
        elseif handler.kind == 'mcp' then
            if type(handler.server) ~= 'string' or #handler.server == 0
                or type(handler.tool) ~= 'string' or #handler.tool == 0 then error('InvalidDeferredMcpHandler', 0) end
        else
            error('InvalidDeferredToolHandler', 0)
        end
    end

    local function callable(entry, factory)
        local helper
        return function(args)
            if entry.handler.kind == 'mcp' then
                return remoteCall({server=entry.handler.server, tool=entry.handler.tool, arguments=args})
            end
            agent.validate(args, entry.parameters, entry.name)
            if helper == nil then
                local materialize = factory or agent.compile(entry.handler.source)
                local value = materialize()
                if type(value) ~= 'function' then error('DeferredToolMustReturnFunction', 0) end
                helper = value
                factory = nil
            end
            return helper(args)
        end
    end

    local function publication(prepared)
        local candidate = {}
        for name, helper in pairs(tools) do
            if installed[name] == nil then candidate[name] = helper end
        end
        for name, helper in pairs(prepared) do candidate[name] = helper end
        return agent.prepareTools(candidate)
    end

    local function restore()
        local current = ctx.deferred_tools or {}
        if type(current) ~= 'table' then error('InvalidDeferredToolRegistry', 0) end
        local prepared = {}
        local count = 0
        for name, entry in pairs(current) do
            if name ~= entry.name then error('InvalidDeferredToolRegistry', 0) end
            -- A helper saved by an older version may use a newly reserved name.
            if not reserved[name] then
                validDefinition(entry, false)
                prepared[name] = callable(entry)
                count += 1
            end
        end
        agent.warnSize('deferred tools', count, 4096)
        publication(prepared)()
        installed = prepared
    end

    local function sequence(value)
        if type(value) ~= 'table' then error('InvalidDeferredToolBatch', 0) end
        local count = 0
        for key in pairs(value) do
            if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 then error('InvalidDeferredToolBatch', 0) end
            count += 1
        end
        if count ~= #value then error('InvalidDeferredToolBatch', 0) end
    end

    local function prepareBatch(batch)
        if type(batch) ~= 'table' then error('InvalidDeferredToolBatch', 0) end
        sequence(batch.definitions)
        sequence(batch.remove or {})
        batch = agent.decode(agent.encode(batch))
        local source = batch.source or 'local'
        if type(source) ~= 'string' or #source == 0 then error('InvalidDeferredToolSource', 0) end
        local next, prepared, seen = {}, {}, {}
        for name, entry in pairs(ctx.deferred_tools or {}) do
            if not reserved[name] and (batch.replace_source ~= true or entry.source ~= source) then next[name] = entry end
        end
        for _, name in ipairs(batch.remove or {}) do
            if type(name) ~= 'string' or reserved[name] then error('InvalidDeferredToolName', 0) end
            next[name] = nil
        end
        for _, entry in ipairs(batch.definitions) do
            if seen[entry.name] then error('DuplicateDeferredTool', 0) end
            local factory = validDefinition(entry, true)
            seen[entry.name] = true
            entry.source = source
            next[entry.name] = entry
            prepared[entry.name] = callable(entry, factory)
        end
        local count = 0
        for name, entry in pairs(next) do
            count += 1
            if prepared[name] == nil then prepared[name] = installed[name] or callable(entry) end
        end
        agent.warnSize('deferred tools', count, 4096)
        return next, prepared, publication(prepared), count
    end

    local function commitRegistration(receipt, submission, next)
        local previousSubmission = ctx.last_registration
        local previousReceipts = ctx.registration_receipts
        local previous = ctx.deferred_tools
        if next ~= nil then ctx.deferred_tools = next end
        if submission ~= nil then
            local receipts = table.clone(previousReceipts or {})
            receipts[submission] = receipt
            ctx.registration_receipts = receipts
            ctx.last_registration = submission
        end
        local event = if receipt.error then 'tools_rejected' else 'tools_registered'
        local committed, failure = pcall(agent.checkpoint, {kind=event}, true)
        if not committed then
            ctx.deferred_tools = previous
            ctx.last_registration = previousSubmission
            ctx.registration_receipts = previousReceipts
            error(failure, 0)
        end
    end

    local function install(batch, submission)
        local prior = if submission ~= nil and ctx.registration_receipts then ctx.registration_receipts[submission] else nil
        if prior ~= nil then
            if prior.error then error(prior.error, 0) end
            return prior
        end
        local ok, next, prepared, publish, count = pcall(prepareBatch, batch)
        if not ok then
            if submission ~= nil then commitRegistration({error=tostring(next)}, submission, nil) end
            error(next, 0)
        end
        local receipt = {installed=count}
        commitRegistration(receipt, submission, next)
        publish()
        installed = prepared
        syncScriptTools()
        return receipt
    end

    local catalogs = {}
    local function normalized(name)
        local parts = {}
        for index=1,#name do
            local byte = string.byte(name, index)
            parts[index] = if byte == 45 then '_' else string.char(byte)
        end
        return table.concat(parts)
    end
    local function findServer(name)
        if type(name) ~= 'string' or #name == 0 then error('InvalidMcpServer', 0) end
        local key = normalized(name)
        for _, server in ipairs(options.mcp_servers or {}) do
            if normalized(server) == key then return server end
        end
        if string.sub(key, 1, 5) == 'mcp__' then
            for _, server in ipairs(options.mcp_servers or {}) do
                if normalized(server) == string.sub(key, 6) then return server end
            end
        end
        error('UnknownMcpServer: ' .. name, 0)
    end

    local function loadCatalog(server, refresh)
        if not refresh and catalogs[server] ~= nil then return catalogs[server] end
        catalogs[server] = nil
        local catalog = discover({server=server, refresh=refresh})
        if catalog.isError == true then error(catalog.content[1].text, 0) end
        if type(catalog.tools) ~= 'table' or catalog.server ~= server then error('McpDiscoveryFailed: ' .. server, 0) end
        local definitions, source = {}, 'mcp/' .. server
        local current, seen = ctx.deferred_tools or {}, {}
        local changed = false
        for index, entry in ipairs(catalog.tools) do
            local name = entry.identifier
            local definition = {name=name, source=source, description=entry.description or '',
                parameters=entry.input_schema or {type='object', properties={}, additionalProperties=true},
                handler={kind='mcp', server=server, tool=entry.name}}
            definitions[index], seen[name] = definition, true
            local prior = current[name]
            if not changed and (prior == nil or agent.encode(definition) ~= agent.encode(prior)) then changed = true end
        end
        if not changed then
            for name, entry in pairs(current) do
                if entry.source == source and not seen[name] then changed = true; break end
            end
        end
        if changed then install({definitions=definitions, source=source, replace_source=true}) end
        catalogs[server] = catalog
        return catalog
    end

    local function localDescriptor(name)
        if not canCall(name) then return nil end
        local entry = (ctx.deferred_tools or {})[name]
        if entry ~= nil and entry.handler.kind == 'luau' and tools[name] == installed[name] then
            return {name=name, identifier=name, description=entry.description, input_schema=entry.parameters}
        end
        if reserved[name] then
            local fixed = agent.toolMetadata(name)
            if fixed ~= nil then
                return {name=name, identifier=name, description=fixed.description, input_schema=fixed.parameters}
            end
        end
    end

    local searchSchema = {type='object', properties={query={type='string', maxLength=1024}, limit={type='integer', minimum=1, maximum=50},
        server={type='string'}, refresh={type='boolean'}}, additionalProperties=false}
    local function search(args, listAll)
        agent.validate(args, searchSchema, 'search_tools')
        local documents, descriptions, errors = {}, {}, agent.decode('[]')
        local selected = if args.server ~= nil then findServer(args.server) else nil
        if selected == nil then
            for name in pairs(tools) do
                local entry = localDescriptor(name)
                if entry ~= nil then table.insert(documents, entry) end
            end
        end
        local function collect(server)
            local catalog = loadCatalog(server, args.refresh == true)
            local description = catalog.description
            if description == '' then
                local instructions = catalog.instructions
                local stop = math.min(string.find(instructions, '\r') or #instructions + 1,
                    string.find(instructions, '\n') or #instructions + 1)
                description = string.sub(instructions, 1, stop - 1)
            end
            descriptions[server] = description
            table.move(catalog.tools, 1, #catalog.tools, #documents + 1, documents)
        end
        if selected ~= nil then collect(selected)
        else
            for _, server in ipairs(options.mcp_servers or {}) do
                local ok, failure = pcall(collect, server)
                if not ok then table.insert(errors, {server=server, message=tostring(failure)}) end
            end
        end
        return rankTools(documents, descriptions, args.query or '', if listAll then #documents else args.limit or 8), errors
    end

    tools.register_deferred_tools = function(batch)
        local receipt = install(batch, nil)
        table.clear(catalogs) -- A local batch may replace or remove an MCP helper.
        return receipt
    end
    tools.search_tools = function(args)
        local entries, errors = search(args)
        local matches = agent.decode('[]')
        for index, entry in ipairs(entries) do
            matches[index] = {name=entry.name, identifier=entry.identifier, description=entry.description, server=entry.server}
        end
        return {tools=matches, errors=errors}
    end
    tools.discover_tools = function(args)
        if args == nil then args = {} end
        agent.validate(args, searchSchema, 'discover_tools')
        if args.server == nil or args.query ~= nil or args.limit ~= nil then return tools.search_tools(args) end
        local catalog = loadCatalog(findServer(args.server), args.refresh == true)
        return agent.decode(agent.encode(catalog))
    end
    tools.describe_tool = function(args)
        agent.validate(args, {type='object', properties={name={type='string', minLength=1}, server={type='string'}},
            required={'name'}, additionalProperties=false}, 'describe_tool')
        if args.server == nil then
            local entry = localDescriptor(args.name)
            if entry ~= nil then return agent.decode(agent.encode(entry)) end
        end
        -- An installed identifier gives us its source without opening unrelated servers.
        local entry = (ctx.deferred_tools or {})[args.name]
        local server = if args.server ~= nil then findServer(args.server)
            elseif entry ~= nil and entry.handler.kind == 'mcp' then findServer(entry.handler.server) else nil
        if server == nil then error('UnknownTool: ' .. args.name .. ' (search first, or pass server)', 0) end
        local catalog = loadCatalog(server, false)
        for _, tool in ipairs(catalog.tools) do
            if tool.identifier == args.name or tool.name == args.name then
                return agent.decode(agent.encode(tool))
            end
        end
        error('UnknownTool: ' .. args.name, 0)
    end
    tools.describe_namespace = function(args)
        agent.validate(args, {type='object', properties={server={type='string'}}, required={'server'},
            additionalProperties=false}, 'describe_namespace')
        local catalog = loadCatalog(findServer(args.server), false)
        local names = agent.decode('[]')
        for _, tool in ipairs(catalog.tools) do table.insert(names, tool.identifier) end
        return {server=catalog.server, description=catalog.description, instructions=catalog.instructions, tools=names}
    end
    local function sample(entry)
        return entry.description .. '\n\nCall: tools[' .. agent.encode(entry.identifier) .. '](args)\nInput schema: ' .. agent.encode(entry.input_schema)
    end
    local function scriptSearch(query, settings)
        if type(query) ~= 'string' then error('searchTools() expects a query string', 0) end
        settings = settings or {}
        local out = agent.decode('[]')
        if query == '' then return out end
        for index, entry in ipairs(search({query=query, server=settings.namespace, limit=settings.limit})) do
            out[index] = {name=entry.identifier, description=sample(entry)}
        end
        return out
    end
    local function scriptDescribe(name)
        if type(name) ~= 'string' then error('describeTool() expects a tool name', 0) end
        local localEntry = localDescriptor(name)
        if localEntry ~= nil then return sample(localEntry) end
        local prior = (ctx.deferred_tools or {})[name]
        if prior ~= nil and prior.handler.kind == 'mcp' then
            local ok, entry = pcall(tools.describe_tool, {name=name})
            if ok then return sample(entry) end
        end
        for _, entry in ipairs(search({}, true)) do
            if entry.identifier == name then return sample(entry) end
        end
        return nil
    end
    local function scriptNamespace(name)
        if type(name) ~= 'string' then error('describeNamespace() expects a namespace name', 0) end
        local ok, server = pcall(findServer, name)
        if not ok then return nil end
        local namespace = tools.describe_namespace({server=server})
        return {name='mcp__' .. server, tools=namespace.tools,
            description=if namespace.description ~= '' then namespace.description else nil,
            instructions=if namespace.instructions ~= '' then namespace.instructions else nil}
    end
    local function scriptAll()
        local entries = agent.decode('[]')
        for _, entry in ipairs(search({}, true)) do
            table.insert(entries, {name=entry.identifier, description=sample(entry)})
        end
        return entries
    end
    restore()
    local function startScript(wrap)
        scriptTools = {}
        wrapScriptTool = wrap
        syncScriptTools()
        return scriptTools
    end
    return {install=install, search=scriptSearch, describe=scriptDescribe, namespace=scriptNamespace, all=scriptAll, saveOutput=saveOutput, startScript=startScript}
end
