local contextJson, configs, program, registering, native = ...
parseNumber, jsonSpecial = native.number, native.jsonSpecial
local setEnvironment = setfenv
local nativeCall, ready, nativeGuard = native.call, native.ready, native.guard
local definitionDepth = 0
local function guard()
    nativeGuard()
    if definitionDepth > 0 then error('host effects are forbidden while reconstructing helper definitions', 0) end
end
local function definition(factory)
    definitionDepth += 1
    local ok, result = pcall(factory)
    definitionDepth -= 1
    if not ok then error(result, 0) end
    return result
end
local context = decode(contextJson)
local invocationInput = if native.input ~= '' then decode(native.input) else nil
local invocationOptions = if native.application then decode(native.environment) else nil
local function literalData(value)
    if value == null then return nil end
    if type(value) == 'table' then
        shapes[value] = nil
        for key, child in pairs(value) do value[key] = literalData(child) end
    end
    return value
end
if not native.application and not native.preserveInput then invocationInput = literalData(invocationInput) end
native.seal(safeFind)
local safe = {}
for _, key in ipairs({ 'assert', 'error', 'ipairs', 'pairs', 'next', 'select', 'tonumber', 'tostring',
    'type', 'typeof', 'unpack', 'pcall', 'xpcall', 'rawequal', 'rawget', 'rawset', 'rawlen',
    'getmetatable' }) do safe[key] = getfenv()[key] end
for _, key in ipairs({ 'math', 'string', 'utf8', 'bit32' }) do safe[key] = getfenv()[key] end
local safeMath = {}
for key, value in pairs(math) do safeMath[key] = value end
safeMath.random, safeMath.randomseed = native.random, native.randomseed
safe.math = table.freeze(safeMath)
local safeTable = {}
for key, value in pairs(table) do safeTable[key] = value end
safeTable.sort, safeTable.foreach, safeTable.foreachi = safeSort, nil, nil
safe.table = table.freeze(safeTable)
table.freeze(safe)
local tools = {}
local registered = {}
local emitted = decode('[]')
local captures = {sequence=0, forwarded=0}
local function takeImages(forward)
    for _, capture in ipairs(captures) do
        for _, part in ipairs(emitted) do
            local seen = false
            for _, prior in ipairs(capture.images) do if prior == part then seen = true; break end end
            if not seen then table.insert(capture.images, part) end
        end
    end
    local encoded = encode(emitted)
    if forward ~= false then
        captures.forwarded += #emitted
        emitted = decode('[]')
    end
    return encoded
end
local output = table.freeze({ image = function(part)
    guard()
    if type(part) ~= 'table' then error('image must be an object', 0) end
    local mime, data = part.mime_type, part.data_base64
    if mime ~= 'image/png' and mime ~= 'image/jpeg' and mime ~= 'image/gif' and mime ~= 'image/webp' and mime ~= 'image/bmp' then error('unsupported image MIME type', 0) end
    if type(data) ~= 'string' or #data == 0 or #data % 4 ~= 0 then error('invalid image base64', 0) end
    if string.find(data, '[^A-Za-z0-9+/=]') or string.find(string.sub(data, 1, -3), '=') then error('invalid image base64', 0) end
    table.insert(emitted, { mime_type = mime, data_base64 = data })
end, control = function(change)
    guard()
    local capture = captures[1]
    if type(invocationOptions) ~= 'table' or invocationOptions.tool_controls ~= true or capture == nil then
        error('tool control is unavailable outside an enabled tool call', 0)
    end
    if type(change) ~= 'table' then error('tool control must be an object', 0) end
    for key, value in pairs(change) do
        if key == 'handoff' and type(value) == 'string' then
            validText(value)
        elseif key ~= 'terminate' or value ~= true then error('invalid tool control', 0) end
    end
    local control = capture.control or {}
    if change.handoff ~= nil then control.handoff = change.handoff end
    if change.terminate == true then control.terminate = true end
    capture.control = control
end })
local environment = { ctx = context, tools = tools, output = output }
local environmentMeta = table.freeze({ __index = safe, __metatable = 'locked' })
setmetatable(environment, environmentMeta)
local current = native.current
local descriptors = {}
local function toolDescriptor(version)
    if not descriptors[version] then descriptors[version] = decode(version.metadata) end
    return descriptors[version]
end
local function hostCall(version, endpoint, args)
    guard()
    if type(endpoint) ~= 'string' or #endpoint == 0 then error('invalid host endpoint', 0) end
    validText(endpoint)
    if not native.controller then
        local permitted = false
        for _, granted in ipairs(toolDescriptor(version).endpoints) do
            if granted == endpoint then permitted = true; break end
        end
        if not permitted then error('endpoint not permitted: ' .. endpoint, 0) end
    end
    captures.sequence += 1
    local images = takeImages()
    local result, failed = nativeCall(version.name, endpoint, encode(args), encode(environment.ctx), images)
    local decoded = decode(result)
    for _, capture in ipairs(captures) do table.insert(capture.observations, {tool_name=version.name, endpoint=endpoint, arguments=args, result=decoded, failed=failed}) end
    if failed then error('host ' .. endpoint .. ' failed: ' .. result, 0) end
    return decoded
end
local function invoke(version, args)
    encode(args)
    local schema = toolDescriptor(version).parameters
    validate(args, schema, version.name)
    local value = version.execute(args)
    encodeToolResult(value)
    return value
end
for _, config in ipairs(configs) do
    local version = config.version
    if not version then
        version = {}
        local host = table.freeze({call=function(endpoint, args)
            nativeGuard()
            return current().host(version, endpoint, args)
        end})
        local moduleOutput = table.freeze({image=function(part)
            nativeGuard()
            return current().output.image(part)
        end, control=function(change)
            nativeGuard()
            return current().output.control(change)
        end})
        local moduleEnvironment = {host=host, output=moduleOutput}
        setmetatable(moduleEnvironment, table.freeze({__metatable='locked', __index=native.moduleIndex(safe)}))
        setEnvironment(config.chunk, moduleEnvironment)
        native.registration()
        local d = config.chunk()
        version.metadata = descriptor(d)
        version.execute, version.name = d.execute, d.name
        table.freeze(version)
    end
    if registering then return version.metadata, version end
    if version.name ~= config.name then error('registered tool name changed', 0) end
    if tools[version.name] then error('duplicate tool name', 0) end
    tools[version.name] = function(args)
        return current().invoke(version, args)
    end
    if native.application then registered[version.name] = {invoke=tools[version.name], recovery=toolDescriptor(version).recovery, metadata=version.metadata} end
end
if not native.mutable then table.freeze(tools) end
native.bind({host=hostCall, output=output, tools=tools, invoke=invoke})
if native.input ~= '' then environment.input = invocationInput end
if native.application then
    environment.options = invocationOptions
    environment.agent = applicationApi(environment, native, takeImages, setEnvironment, guard, definition, captures, registered)
end
setEnvironment(program, environment)
ready()
local ok, result, snapshot = pcall(function()
    local result = program()
    return encode(result), encode(environment.ctx)
end)
if not ok then return result, nil, takeImages(), true end
return result, snapshot, takeImages()
