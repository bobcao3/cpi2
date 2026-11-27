local function lineStarts(text)
    local offsets, at = {1}, 1
    while true do
        local newline = string.find(text, '\n', at, true)
        if not newline then break end
        at = newline + 1
        table.insert(offsets, at)
    end
    table.insert(offsets, #text + 1)
    return offsets
end

local function lineAt(offsets, pos)
    local first, last = 1, #offsets
    while first < last do
        local mid = math.floor((first + last + 1) / 2)
        if offsets[mid] <= pos then first = mid else last = mid - 1 end
    end
    return first
end

local function newlines(text)
    local count, at = 0, 1
    while true do
        local newline = string.find(text, '\n', at, true)
        if not newline then return count end
        count += 1
        at = newline + 1
    end
end

-- Compare whole lines around the applied ranges, with enough margin to align
-- repeated lines before choosing the four context rows shown to the user.
local function diffWindows(original, replacements)
    local offsets = lineStarts(original)
    local windows, byteDelta, lineDelta = {}, 0, 0
    for _, replacement in ipairs(replacements) do
        local first = math.max(1, lineAt(offsets, replacement.start) - 32)
        local last = math.min(#offsets, lineAt(offsets, replacement.stop - 1) + 33)
        local start, stop = offsets[first], offsets[last]
        local newDelta = byteDelta + #replacement.replacement - (replacement.stop - replacement.start)
        local previous = windows[#windows]
        if previous and start <= previous.oldStop then
            previous.oldStop = math.max(previous.oldStop, stop)
            previous.newStop = previous.oldStop + newDelta
        else
            table.insert(windows, {
                oldStart = start, oldStop = stop, oldLine = first,
                newStart = start + byteDelta, newStop = stop + newDelta, newLine = first + lineDelta,
            })
        end
        byteDelta = newDelta
        lineDelta += newlines(replacement.replacement) - newlines(string.sub(original, replacement.start, replacement.stop - 1))
    end
    return windows, #tostring(#offsets - 1 + math.max(0, lineDelta))
end

local function extendRun(previous, kind, count)
    if previous and previous.kind == kind then
        return {kind = kind, count = previous.count + count, previous = previous.previous}
    end
    return {kind = kind, count = count, previous = previous}
end

-- Myers line diff. Each diagonal keeps its farthest reachable old line and
-- the runs needed to reconstruct that path. Line tokens include their LF.
local function lineDiff(old, new, budget)
    local function advance(path, diagonal)
        local x, y = path.old, path.old - diagonal
        local start = x
        while x < #old and y < #new and old[x + 1] == new[y + 1] do
            x += 1
            y += 1
        end
        if x > start then path.run = extendRun(path.run, ' ', x - start) end
        path.old = x
        return y
    end
    local function runs(last)
        local out = {}
        while last do
            table.insert(out, last)
            last = last.previous
        end
        return out
    end
    local best = {[0] = {old = 0}}
    local y = advance(best[0], 0)
    if best[0].old == #old and y == #new then return runs(best[0].run) end
    local low, high = -#new, #old
    for distance = 1, #old + #new do
        local first = math.max(-distance, low)
        if (distance - first) % 2 ~= 0 then first += 1 end
        for diagonal = first, math.min(distance, high), 2 do
            if diagonal > high then break end
            budget.remaining -= 1
            if budget.remaining < 0 then return nil end
            local remove, add = best[diagonal - 1], best[diagonal + 1]
            best[diagonal - 1] = nil
            local canRemove = remove and remove.old < #old
            local canAdd = add and add.old - diagonal > 0 and add.old - diagonal <= #new
            if canRemove or canAdd then
                local path
                if not canRemove or (canAdd and remove.old < add.old) then
                    path = {old = add.old, run = extendRun(add.run, '+', 1)}
                else
                    path = {old = remove.old + 1, run = extendRun(remove.run, '-', 1)}
                end
                y = advance(path, diagonal)
                if path.old == #old and y == #new then return runs(path.run) end
                best[diagonal] = path
                if path.old == #old then high = math.min(high, diagonal - 1) end
                if y == #new then low = math.max(low, diagonal + 1) end
            else
                best[diagonal] = nil
            end
        end
    end
    return nil
end

local function jsonStringBytes(text)
    local bytes = #text
    for at = 1, #text do
        local byte = string.byte(text, at)
        if byte < 32 then bytes += 5
        elseif byte == 34 or byte == 92 then bytes += 1 end
    end
    return bytes
end

-- Leave room for the rest of the existing VM tool result envelope.
local editResultTextBudget = 128 * 1024 - 256

local function editDisplayDiff(original, updated, replacements, success)
    local windows, width = diffWindows(original, replacements)
    local output, firstChanged = {}, nil
    local remaining = editResultTextBudget - jsonStringBytes(success)
    local budget = {remaining = 32768}
    local marker = string.rep(' ', width + 2) .. '...'
    local numeral = '%s%' .. tostring(width) .. 'd %s'
    local function row(text)
        if #text > remaining then return false end
        remaining -= jsonStringBytes(text) + 6 -- escaped newline between rows
        if remaining < 0 then return false end
        table.insert(output, text)
        return true
    end
    local function skip()
        return output[#output] == marker or row(marker)
    end
    for _, window in ipairs(windows) do
        if window.oldStop - window.oldStart + window.newStop - window.newStart > 512 * 1024 then return nil end
        local old = lines(string.sub(original, window.oldStart, window.oldStop - 1))
        local new = lines(string.sub(updated, window.newStart, window.newStop - 1))
        local runs = lineDiff(old, new, budget)
        if not runs then return nil end
        local oldAt, newAt = 1, 1
        for i = #runs, 1, -1 do
            local run = runs[i]
            if run.kind == ' ' then
                local leading = if i < #runs then math.min(run.count, 4) else 0
                local trailing = if i > 1 then math.min(run.count - leading, 4) else 0
                for index = 0, leading - 1 do
                    if not row(string.format(numeral, ' ', window.oldLine + oldAt + index - 1, trimNewline(old[oldAt + index]))) then return nil end
                end
                if leading + trailing > 0 and leading + trailing < run.count and not skip() then return nil end
                for index = run.count - trailing, run.count - 1 do
                    if not row(string.format(numeral, ' ', window.oldLine + oldAt + index - 1, trimNewline(old[oldAt + index]))) then return nil end
                end
                oldAt += run.count
                newAt += run.count
            else
                firstChanged = firstChanged or (window.newLine + newAt - 1)
                local removed = run.kind == '-'
                local source, at, line = if removed then old else new, if removed then oldAt else newAt, if removed then window.oldLine else window.newLine
                for offset = 0, run.count - 1 do
                    if not row(string.format(numeral, run.kind, line + at + offset - 1, trimNewline(source[at + offset]))) then return nil end
                end
                if removed then oldAt += run.count else newAt += run.count end
            end
        end
    end
    return table.concat(output, '\n'), firstChanged
end
