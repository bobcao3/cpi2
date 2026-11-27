local function applicationApi(environment, native, takeImages, setEnvironment, guard, definition, captures, registered)
    local api = { encode = encode, decode = decode, encodeToolResult = encodeToolResult }
    function api.toolRecovery(name)
        local tool = registered[name]
        if tool ~= nil and environment.tools[name] == tool.invoke then return tool.recovery end
        return 'never'
    end
    function api.toolMetadata(name)
        local tool = registered[name]
        if tool ~= nil and environment.tools[name] == tool.invoke then return decode(tool.metadata) end
    end
    function api.checkpoint(event, boundary, history)
        guard()
        local payload = encode({event=event, boundary=boundary == true, history=history})
        native.call('__application', '__checkpoint', payload, encode(environment.ctx), takeImages())
    end
    function api.progress(event)
        guard()
        native.call('__application', '__progress', encode(event), '{}', '[]')
    end
    function api.history(id)
        guard()
        local raw, failed = native.call('__application', '__history', encode({id=id}), '{}', '[]')
        if failed then error(raw, 0) end
        return decode(raw)
    end
    function api.capture(fn)
        local capture = {images=decode('[]'), observations=decode('[]'), start_sequence=captures.sequence, start_image=captures.forwarded}
        local previous = environment.ctx.__capture
        if previous == nil then environment.ctx.__capture = capture end
        table.insert(captures, capture)
        local ok, result = pcall(fn)
        takeImages(false)
        table.remove(captures)
        environment.ctx.__capture = previous
        capture.ok = ok
        if ok then capture.result = result
        else capture.error = tostring(result); capture.control = nil end
        return capture
    end
    function api.decodeTyped(text)
        local ok, value = pcall(decode, text)
        if not ok then return {ok=false, error=tostring(value)} end
        local types = {}
        local function visit(item, path)
            local kind = type(item)
            if item == null then kind = 'null'
            elseif kind == 'table' then kind = shapes[item] or 'object' end
            types[path] = kind
            if kind == 'array' then
                for index, child in ipairs(item) do visit(child, path .. '/' .. tostring(index - 1)) end
            elseif kind == 'object' then
                for key, child in pairs(item) do visit(child, path .. '/' .. key) end
            end
        end
        visit(value, '')
        return {ok=true, value=value, types=types}
    end
    function api.compile(source)
        if type(source) ~= 'string' then error('source must be a string', 0) end
        local closure = native.compile(source)
        setEnvironment(closure, environment)
        return closure
    end
    function api.evaluate(source, globals)
        if globals == nil then return api.compile(source)() end
        local scope = table.clone(globals)
        setmetatable(scope, {__metatable='locked', __index=environment})
        local closure = native.compile(source)
        setEnvironment(closure, scope)
        return closure()
    end
    function api.prepareTools(candidate)
        if not native.mutable or type(candidate) ~= 'table' then error('application tools are fixed', 0) end
        local bindings = native.current()
        return function()
            environment.tools = candidate
            bindings.tools = candidate
        end
    end
    function api.checkSchema(schema)
        checkSchema(schema, {})
    end
    function api.validate(value, schema, name)
        validate(value, schema, name or 'deferred tool')
    end
    function api.define(name, source)
        if not native.mutable then error('application environment is fixed', 0) end
        if type(name) ~= 'string' or #name == 0 then error('invalid helper name', 0) end
        local helper = definition(function() return api.evaluate(source) end)
        if type(helper) ~= 'function' then error('definition must return a function', 0) end
        environment.ctx.definitions = environment.ctx.definitions or {}
        environment.ctx.definitions[name] = source
        environment[name] = helper
        return helper
    end
    function api.restore()
        for name, source in pairs(environment.ctx.definitions or {}) do
            environment[name] = definition(function() return api.evaluate(source) end)
        end
    end
    function api.context(name)
        local ctx = environment.ctx
        if ctx[name] == nil then ctx[name] = decode('[]') end
        return ctx[name]
    end
    function api.model(body, resume, beforeSend)
        guard()
        local raw = native.call('__application', 'model.request', encode({body=body, resume=if resume == true then true else nil,
            before_send=if beforeSend == true then true else nil}), encode(environment.ctx), takeImages())
        return decode(raw)
    end
    function api.now()
        guard()
        return decode(native.call('__application', '__clock', '{}', '{}', '[]'))
    end
    function api.claimBoundaryInput(mode)
        guard()
        local value = decode(native.call('__application', '__claim_boundary_input', if mode == nil then '{}' else encode({mode=mode}), '{}', '[]'))
        return if rawequal(value, null) then nil else value
    end
    function api.runtimeOptions()
        guard()
        local value = decode(native.call('__application', '__runtime_options', '{}', '{}', '[]'))
        return if rawequal(value, null) then nil else value
    end
    function api.warnSize(measurement, actual, threshold)
        guard()
        if actual <= threshold then return end
        native.call('__application', '__size_warning', encode({measurement=measurement, actual=actual, threshold=threshold}), '{}', '[]')
    end
    function api.waitUntil(until_ms)
        guard()
        local raw, failed = native.call('__application', 'harness.wait', encode({until_ms=until_ms}), encode(environment.ctx), '[]')
        if failed then error(raw, 0) end
    end
    return table.freeze(api)
end
