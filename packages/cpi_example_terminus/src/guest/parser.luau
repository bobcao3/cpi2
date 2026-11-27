local function truth(value)
    if value == nil or value == false then return false end
    if type(value) == "number" then return value ~= 0 end
    if type(value) == "string" then return #value > 0 end
    if type(value) == "table" then return next(value) ~= nil end
    return true
end
local function extract(response)
    local first, depth, quoted, escaped = nil, 0, false, false
    for index = 1, #response do
        local c = string.sub(response, index, index)
        if escaped then escaped = false
        elseif c == "\\" then escaped = true
        elseif c == '"' then quoted = not quoted
        elseif not quoted then
            if c == "{" then
                if depth == 0 then first = index end
                depth += 1
            elseif c == "}" then
                depth -= 1
                if depth == 0 and first then
                    local warnings = {}
                    if #rt.trim(string.sub(response, 1, first - 1)) > 0 then table.insert(warnings, "Extra text detected before JSON object") end
                    if #rt.trim(string.sub(response, index + 1)) > 0 then table.insert(warnings, "Extra text detected after JSON object") end
                    return string.sub(response, first, index), warnings
                end
            end
        end
    end
    return nil, {"No valid JSON object found"}
end
local function field_position(text, name)
    local cursor = 1
    while true do
        local first, last = string.find(text, '"' .. name .. '"', cursor)
        if not first then return nil end
        local after = last + 1
        while after <= #text and rt.trim(string.sub(text, after, after)) == "" do after += 1 end
        if string.sub(text, after, after) == ":" then return first end
        cursor = last + 1
    end
end
local function parse_attempt(response)
    local text, warnings = extract(response)
    local result = {commands = rt.array(), is_task_complete = false, error = "", warning = "", analysis = "", plan = ""}
    local function done(message)
        result.error = message or ""
        result.warning = if #warnings > 0 then "- " .. table.concat(warnings, "\n- ") else ""
        return result
    end
    if not text then return done("No valid JSON found in response") end
    local decoded = rt.decode(text)
    if not decoded.ok then return done("Invalid JSON: " .. decoded.error) end
    local data, types = decoded.value, decoded.types
    if types[""] ~= "object" then return done("Response must be a JSON object") end
    local missing = {}
    for _, key in ipairs({"analysis", "plan", "commands"}) do if data[key] == nil then table.insert(missing, key) end end
    if #missing > 0 then return done("Missing required fields: " .. table.concat(missing, ", ")) end
    if type(data.analysis) ~= "string" then table.insert(warnings, "Field 'analysis' should be a string") end
    if type(data.plan) ~= "string" then table.insert(warnings, "Field 'plan' should be a string") end
    if types["/commands"] ~= "array" then return done("Field 'commands' must be an array") end
    local expected, actual = {"analysis", "plan", "commands"}, {}
    for _, name in ipairs(expected) do table.insert(actual, {name = name, position = field_position(text, name) or math.huge}) end
    table.sort(actual, function(a, b) return a.position < b.position end)
    if actual[1].name ~= expected[1] or actual[2].name ~= expected[2] or actual[3].name ~= expected[3] then
        local found = {}
        for _, field in ipairs(actual) do table.insert(found, field.name) end
        table.insert(warnings, "Fields appear in wrong order. Found: " .. table.concat(found, " → ") .. ", expected: analysis → plan → commands")
    end
    local complete = data.task_complete
    if complete ~= nil and types["/task_complete"] ~= "null" and type(complete) ~= "boolean" and type(complete) ~= "string" then
        table.insert(warnings, "Field 'task_complete' should be a boolean or string")
    end
    if type(complete) == "string" then
        local lower = string.lower(complete)
        complete = lower == "true" or lower == "1" or lower == "yes"
    else complete = truth(complete) end
    result.is_task_complete, result.analysis, result.plan = complete, data.analysis, data.plan
    local parse_error = nil
    for index, command in ipairs(data.commands) do
        if types["/commands/" .. tostring(index - 1)] ~= "object" then parse_error = "Command " .. index .. " must be an object"; break end
        if command.keystrokes == nil then parse_error = "Command " .. index .. " missing required 'keystrokes' field"; break end
        if type(command.keystrokes) ~= "string" then parse_error = "Command " .. index .. " 'keystrokes' must be a string"; break end
        local duration = command.duration
        if duration == nil then
            table.insert(warnings, "Command " .. index .. ": Missing duration field, using default 1.0"); duration = 1
        elseif type(duration) == "boolean" then duration = if duration then 1 else 0
        elseif type(duration) ~= "number" then
            table.insert(warnings, "Command " .. index .. ": Invalid duration value, using default 1.0"); duration = 1
        end
        local unknown = {}
        for key in pairs(command) do if key ~= "keystrokes" and key ~= "duration" then table.insert(unknown, key) end end
        if #unknown > 0 then table.insert(warnings, "Command " .. index .. ": Unknown fields: " .. table.concat(unknown, ", ")) end
        if index < #data.commands and #command.keystrokes > 0 and string.sub(command.keystrokes, -1) ~= "\n" then
            table.insert(warnings, "Command " .. index .. " should end with newline when followed by another command. Otherwise the two commands will be concatenated together on the same line.")
        end
        table.insert(result.commands, {keystrokes = command.keystrokes, duration = duration})
    end
    if parse_error then
        result.commands = rt.array()
        if complete then table.insert(warnings, parse_error) else result.is_task_complete = false; return done(parse_error) end
    end
    return done()
end
local function parse_response(response)
    local result = parse_attempt(response)
    if result.error == "" then return result end
    local opened, closed = 0, 0
    for index = 1, #response do
        local c = string.sub(response, index, index)
        if c == "{" then opened += 1 elseif c == "}" then closed += 1 end
    end
    if opened > closed and (string.find(result.error, "Invalid JSON") or string.find(result.error, "No valid JSON found")) then
        local repaired = parse_attempt(response .. string.rep("}", opened - closed))
        if repaired.error == "" then
            repaired.warning = "- AUTO-CORRECTED: Fixed incomplete JSON by adding missing closing brace - please fix this in future responses" .. (if repaired.warning ~= "" then "\n" .. repaired.warning else "")
            return repaired
        end
    end
    for index = 1, #response do
        if string.sub(response, index, index) == "{" then
            local depth, ending = 0, nil
            for position = index, #response do
                local c = string.sub(response, position, position)
                if c == "{" then depth += 1 elseif c == "}" then depth -= 1 end
                if depth > 2 then break end
                if depth == 0 then ending = position; break end
            end
            local candidate = if ending then string.sub(response, index, ending) else nil
            if candidate and rt.decode(candidate).ok then
                local repaired = parse_attempt(candidate)
                if repaired.error == "" then
                    repaired.warning = "- AUTO-CORRECTED: Extracted JSON from mixed content - please fix this in future responses" .. (if repaired.warning ~= "" then "\n" .. repaired.warning else "")
                    return repaired
                end
                break
            end
        end
    end
    return result
end
