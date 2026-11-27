local function object(v) return type(v) == 'table' and not rawequal(v, null) and getmetatable(v) == nil end
local function array(v)
    if not object(v) or shapes[v] == 'object' then return false end
    local count = 0
    for k in next, v do
        count += 1
        if type(k) ~= 'number' or k % 1 ~= 0 or k < 1 then return false end
    end
    if count ~= #v then return false end
    shapes[v] = 'array'
    return true
end
local schemaKeys = {
    type = true, properties = true, required = true, additionalProperties = true,
    items = true, enum = true, minimum = true, maximum = true,
    minLength = true, maxLength = true, minItems = true, maxItems = true,
    description = true, title = true, default = true,
}
local kinds = { object = true, array = true, string = true, number = true, integer = true, boolean = true, null = true }
local function checkSchema(s, active)
    if not object(s) or active[s] then error('invalid or cyclic parameter schema', 0) end
    active[s] = true
    for key in next, s do
        if not schemaKeys[key] then error('unsupported schema keyword: ' .. tostring(key), 0) end
    end
    if not kinds[s.type] then error('schema requires a supported type', 0) end
    if s.properties ~= nil then
        if s.type ~= 'object' or not object(s.properties) then error('invalid schema properties', 0) end
        for key, child in next, s.properties do
            if type(key) ~= 'string' then error('invalid property name', 0) end
            checkSchema(child, active)
        end
    end
    if s.required ~= nil then
        if s.type ~= 'object' or not array(s.required) then error('invalid required array', 0) end
        local seen = {}
        for _, key in ipairs(s.required) do
            if type(key) ~= 'string' or seen[key] or not s.properties or not s.properties[key] then
                error('invalid required property', 0)
            end
            seen[key] = true
        end
    end
    if s.items ~= nil then
        if s.type ~= 'array' then error('items requires array type', 0) end
        checkSchema(s.items, active)
    end
    if s.additionalProperties ~= nil then
        if s.type ~= 'object' then error('additionalProperties requires object type', 0) end
        if type(s.additionalProperties) ~= 'boolean' then checkSchema(s.additionalProperties, active) end
    end
    if s.enum ~= nil and (not array(s.enum) or #s.enum == 0) then error('invalid enum', 0) end
    for _, key in ipairs({ 'minimum', 'maximum', 'minLength', 'maxLength', 'minItems', 'maxItems' }) do
        local n = s[key]
        if n ~= nil and (type(n) ~= 'number' or not finite(n) or
            ((key ~= 'minimum' and key ~= 'maximum') and (n < 0 or n % 1 ~= 0))) then
            error('invalid schema bound: ' .. key, 0)
        end
        if n ~= nil then
            local allowed = if key == 'minimum' or key == 'maximum' then s.type == 'number' or s.type == 'integer'
                elseif key == 'minLength' or key == 'maxLength' then s.type == 'string' else s.type == 'array'
            if not allowed then error('schema bound has incompatible type: ' .. key, 0) end
        end
    end
    for _, bounds in ipairs({ {'minimum', 'maximum'}, {'minLength', 'maxLength'}, {'minItems', 'maxItems'} }) do
        if s[bounds[1]] ~= nil and s[bounds[2]] ~= nil and s[bounds[1]] > s[bounds[2]] then error('inverted schema bounds', 0) end
    end
    for _, key in ipairs({ 'title', 'description' }) do
        if s[key] ~= nil and type(s[key]) ~= 'string' then error('invalid schema annotation', 0) end
    end
    active[s] = nil
end
local function validate(v, s, path)
    local kind = if rawequal(v, null) then 'null' else type(v)
    local expected = s.type
    local ok = kind == expected
    if expected == 'object' then
        ok = object(v) and shapes[v] ~= 'array'
        if ok then for k in next, v do if type(k) ~= 'string' then ok = false; break end end end
    elseif expected == 'array' then ok = array(v)
    elseif expected == 'integer' then ok = kind == 'number' and finite(v) and v % 1 == 0 end
    if not ok then error(path .. ': expected ' .. expected, 0) end
    if s.enum then
        local found = false
        local encoded = encode(v)
        for _, option in ipairs(s.enum) do if encode(option) == encoded then found = true; break end end
        if not found then error(path .. ': value not in enum', 0) end
    end
    if kind == 'number' then
        if not finite(v) or (s.minimum and v < s.minimum) or (s.maximum and v > s.maximum) then error(path .. ': number out of bounds', 0) end
    elseif kind == 'string' then
        local size = utf8.len(v)
        if not size or (s.minLength and size < s.minLength) or (s.maxLength and size > s.maxLength) then error(path .. ': string length out of bounds', 0) end
    elseif expected == 'array' then
        if (s.minItems and #v < s.minItems) or (s.maxItems and #v > s.maxItems) then error(path .. ': array length out of bounds', 0) end
        if s.items then for i, item in ipairs(v) do validate(item, s.items, path .. '[' .. i .. ']') end end
    elseif expected == 'object' then
        for _, key in ipairs(s.required or {}) do if rawget(v, key) == nil then error(path .. ': missing ' .. key, 0) end end
        for key, item in next, v do
            local child = s.properties and s.properties[key]
            if child then validate(item, child, path .. '.' .. key)
            elseif s.additionalProperties == false then error(path .. ': unknown property ' .. key, 0)
            elseif type(s.additionalProperties) == 'table' then validate(item, s.additionalProperties, path .. '.' .. key) end
        end
    end
end
local function descriptor(d)
    if not object(d) or type(d.name) ~= 'string' or not match(d.name, '^[%a_][%w_.-]*$') then error('invalid tool name', 0) end
    if type(d.version) ~= 'number' or not finite(d.version) or d.version < 1 or d.version % 1 ~= 0 then error('invalid tool version', 0) end
    if type(d.description) ~= 'string' or #d.description == 0 then error('invalid tool description', 0) end
    if type(d.execute) ~= 'function' then error('tool execute must be a function', 0) end
    if not array(d.endpoints) then error('invalid endpoints array', 0) end
    local seen = {}
    for _, endpoint in ipairs(d.endpoints) do
        if type(endpoint) ~= 'string' or #endpoint == 0 or seen[endpoint] then error('invalid endpoint', 0) end
        seen[endpoint] = true
    end
    if d.recovery ~= 'retry_safe' and d.recovery ~= 'never' and d.recovery ~= 'reconcile' then error('invalid recovery policy', 0) end
    checkSchema(d.parameters, {})
    if d.parameters.type ~= 'object' then error('tool parameters must be an object schema', 0) end
    local metadata = {}
    for key, value in next, d do if key ~= 'execute' then metadata[key] = value end end
    return encode(metadata)
end
