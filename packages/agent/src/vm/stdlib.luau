local function safeFind(s, needle, init)
    if type(s) ~= 'string' or type(needle) ~= 'string' then error('find requires strings', 2) end
    local start = init or 1
    if type(start) ~= 'number' or not finite(start) then error('invalid find position', 2) end
    start = math.floor(start)
    if start < 0 then start = #s + start + 1 end
    start = math.max(1, start)
    if start > #s + 1 then return nil end
    if #needle == 0 then return start, start - 1 end
    local prefix, matched = { 0 }, 0
    for i = 2, #needle do
        local b = byte(needle, i)
        while matched > 0 and byte(needle, matched + 1) ~= b do matched = prefix[matched] end
        if byte(needle, matched + 1) == b then matched += 1 end
        prefix[i] = matched
    end
    matched = 0
    for i = start, #s do
        local b = byte(s, i)
        while matched > 0 and byte(needle, matched + 1) ~= b do matched = prefix[matched] end
        if byte(needle, matched + 1) == b then matched += 1 end
        if matched == #needle then return i - #needle + 1, i end
    end
    return nil
end
local function safeSort(list, compare)
    if type(list) ~= 'table' then error('sort requires a table', 2) end
    if compare ~= nil and type(compare) ~= 'function' then error('sort comparator must be a function', 2) end
    local less = compare or function(a, b) return a < b end
    local count, width = #list, 1
    local scratch = table.create(count)
    while width < count do
        for start = 1, count, width * 2 do
            local middle, last = math.min(start + width, count + 1), math.min(start + width * 2 - 1, count)
            local left, right = start, middle
            for index = start, last do
                if left < middle and (right > last or not less(list[right], list[left])) then
                    scratch[index] = list[left]; left += 1
                else scratch[index] = list[right]; right += 1 end
            end
        end
        for index = 1, count do list[index] = scratch[index] end
        width *= 2
    end
end
