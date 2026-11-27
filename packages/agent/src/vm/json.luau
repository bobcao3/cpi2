local byte, sub = string.byte, string.sub
local match = originalMatch
local parseNumber, jsonSpecial
local function finite(n) return n == n and n ~= math.huge and n ~= -math.huge end
local function validText(s)
    if not utf8.len(s) then error("JSON requires valid UTF-8", 0) end
    return s
end
local function decode(text)
    validText(text)
    local p, size = 1, #text
    local function fail() error("invalid JSON at byte " .. p, 0) end
    local function space()
        while p <= size do
            local b = byte(text, p)
            if b ~= 32 and b ~= 9 and b ~= 10 and b ~= 13 then break end
            p += 1
        end
    end
    local function hex()
        local s = sub(text, p, p + 3)
        if #s ~= 4 or not match(s, "^%x%x%x%x$") then fail() end
        p += 4
        return tonumber(s, 16)
    end
    local function str()
        p += 1
        local out, start = {}, p
        while p <= size do
            p = jsonSpecial(text, p) or size + 1
            if p > size then fail() end
            local b = byte(text, p)
            if b == 34 then
                table.insert(out, sub(text, start, p - 1))
                p += 1
                return validText(table.concat(out))
            elseif b == 92 then
                table.insert(out, sub(text, start, p - 1))
                p += 1
                local esc = sub(text, p, p)
                p += 1
                local simple = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
                if esc == 'u' then
                    local cp = hex()
                    if cp >= 0xD800 and cp <= 0xDBFF then
                        if sub(text, p, p + 1) ~= '\\u' then fail() end
                        p += 2
                        local low = hex()
                        if low < 0xDC00 or low > 0xDFFF then fail() end
                        cp = 0x10000 + (cp - 0xD800) * 1024 + low - 0xDC00
                    elseif cp >= 0xDC00 and cp <= 0xDFFF then fail() end
                    table.insert(out, utf8.char(cp))
                elseif simple[esc] then table.insert(out, simple[esc])
                else fail() end
                start = p
            else fail() end
        end
        fail()
    end
    local value
    value = function()
        space()
        local b = byte(text, p)
        if b == 34 then return str() end
        if b == 123 or b == 91 then
            local object = b == 123
            local out, seen, index = {}, {}, 1
            shapes[out] = if object then "object" else "array"
            p += 1
            space()
            local close = if object then 125 else 93
            if byte(text, p) == close then p += 1; return out end
            while true do
                local key = index
                if object then
                    if byte(text, p) ~= 34 then fail() end
                    key = str()
                    if seen[key] then error("duplicate JSON object key", 0) end
                    seen[key] = true
                    space()
                    if byte(text, p) ~= 58 then fail() end
                    p += 1
                end
                out[key] = value()
                index += 1
                space()
                local sep = byte(text, p)
                p += 1
                if sep == close then return out end
                if sep ~= 44 then fail() end
                space()
            end
        end
        for literal, result in pairs({ ["true"] = true, ["false"] = false, ["null"] = null }) do
            if sub(text, p, p + #literal - 1) == literal then p += #literal; return result end
        end
        local start = p
        if b == 45 then p += 1 end
        b = byte(text, p)
        if b == 48 then p += 1
        elseif b and b >= 49 and b <= 57 then
            repeat p += 1; b = byte(text, p) until not b or b < 48 or b > 57
        else fail() end
        if byte(text, p) == 46 then
            p += 1
            local first = p
            b = byte(text, p)
            while b and b >= 48 and b <= 57 do p += 1; b = byte(text, p) end
            if first == p then fail() end
        end
        b = byte(text, p)
        if b == 69 or b == 101 then
            p += 1
            b = byte(text, p)
            if b == 43 or b == 45 then p += 1 end
            local first = p
            b = byte(text, p)
            while b and b >= 48 and b <= 57 do p += 1; b = byte(text, p) end
            if first == p then fail() end
        end
        local n = parseNumber(sub(text, start, p - 1))
        if not n or not finite(n) then fail() end
        return n
    end
    local out = value()
    space()
    if p ~= size + 1 then fail() end
    return out
end
local function encodeJson(root, toolResult)
    local out, active = {}, {}
    local bytes = 0
    local function add(s)
        if toolResult then
            bytes += #s
            if bytes > 128 * 1024 then error('Tool result text exceeds 128 KiB. Output omitted; the operation may already have completed.', 0) end
        end
        table.insert(out, s)
    end
    local function quoted(s)
        validText(s)
        add('"')
        local start = 1
        local p = jsonSpecial(s, start)
        while p ~= nil do
            local b = byte(s, p)
            add(sub(s, start, p - 1))
            add(if b == 34 then '\\"' elseif b == 92 then '\\\\' else string.format('\\u%04x', b))
            start = p + 1
            p = jsonSpecial(s, start)
        end
        add(sub(s, start)); add('"')
    end
    local visit
    visit = function(v)
        local kind = type(v)
        if rawequal(v, null) or v == nil then add('null')
        elseif kind == 'boolean' then add(if v then 'true' else 'false')
        elseif kind == 'string' then quoted(v)
        elseif kind == 'number' then
            if not finite(v) then error("non-finite JSON number", 0) end
            add(tostring(v))
        elseif kind == 'table' then
            if active[v] then error("cyclic JSON table", 0) end
            if getmetatable(v) ~= nil then error("JSON tables cannot have metatables", 0) end
            active[v] = true
            local count, largest, numeric, strings = 0, 0, false, false
            for k in next, v do
                count += 1
                if type(k) == 'number' and k >= 1 and k % 1 == 0 then numeric = true; largest = math.max(largest, k)
                elseif type(k) == 'string' then strings = true
                else error("invalid JSON table key", 0) end
            end
            local array = shapes[v] == 'array' or numeric
            if (numeric and strings) or (array and strings) or (array and largest ~= count) then
                error("JSON arrays must be dense and cannot mix key types", 0)
            end
            add(if array then '[' else '{')
            local first = true
            if array then
                for i = 1, count do
                    if not first then add(',') end
                    first = false; visit(v[i])
                end
            else
                local keys = {}
                for k in next, v do table.insert(keys, k) end
                table.sort(keys)
                for _, k in ipairs(keys) do
                    if not first then add(',') end
                    first = false; quoted(k); add(':'); visit(v[k])
                end
            end
            add(if array then ']' else '}')
            active[v] = nil
        else error("unsupported JSON value: " .. kind, 0) end
    end
    visit(root)
    return table.concat(out)
end
local function encode(root) return encodeJson(root, false) end
local function encodeToolResult(root) return encodeJson(root, true) end
