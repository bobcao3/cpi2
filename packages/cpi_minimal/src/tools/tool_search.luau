-- BM25 over names, descriptions, and namespace metadata. Identifiers and
-- human-readable words share a tokenizer (snake-case, kebab-case, camelCase).
local function rankTools(documents, descriptions, query, limit)
    if query == '' then
        table.sort(documents, function(a, b) return a.identifier < b.identifier end)
        return table.move(documents, 1, math.min(limit, #documents), 1, {})
    end
    local function lower(b) return b >= 97 and b <= 122 end
    local function upper(b) return b >= 65 and b <= 90 end
    local function wordByte(b) return lower(b) or upper(b) or (b >= 48 and b <= 57) or b >= 128 end
    local function words(text)
        local at = 1
        return function()
            while at <= #text and not wordByte(string.byte(text, at)) do at += 1 end
            if at > #text then return nil end
            local start = at
            at += 1
            while at <= #text do
                local b = string.byte(text, at)
                if not wordByte(b) then break end
                if upper(b) then
                    local previous = string.byte(text, at - 1)
                    if lower(previous) or (upper(previous) and lower(string.byte(text, at + 1) or 0)) then break end
                end
                at += 1
            end
            return string.lower(string.sub(text, start, at - 1))
        end
    end
    local terms, frequency = {}, {}
    for word in words(query) do
        if frequency[word] == nil then
            table.insert(terms, word)
            frequency[word] = 0
        end
    end
    if #terms == 0 then return {} end
    local ranked = {}
    local total = 0
    for _, doc in ipairs(documents) do
        local counts, length = {}, 0
        local function add(text, weight)
            for word in words(text or '') do
                length += weight
                if frequency[word] ~= nil then counts[word] = (counts[word] or 0) + weight end
            end
        end
        add(doc.identifier, 3)
        if doc.name ~= doc.identifier then add(doc.name, 3) end
        add(doc.title, 2)
        add(doc.description, 1)
        add(descriptions[doc.server], 1)
        total += length
        for word in pairs(counts) do frequency[word] += 1 end
        if next(counts) ~= nil then
            table.insert(ranked, {doc=doc, length=length, counts=counts})
        end
    end
    local n = #documents
    local average = if total > 0 then total / n else 1
    local exact = string.lower(query)
    for word, df in pairs(frequency) do frequency[word] = math.log(1 + (n - df + 0.5) / (df + 0.5)) end
    for _, item in ipairs(ranked) do
        local score = 0
        local norm = 1.2 * (0.25 + 0.75 * item.length / average)
        for _, word in ipairs(terms) do
            local tf = item.counts[word]
            if tf ~= nil then score += frequency[word] * tf * 2.2 / (tf + norm) end
        end
        item.score = score
        item.exact = exact == string.lower(item.doc.identifier) or exact == string.lower(item.doc.name)
    end
    table.sort(ranked, function(left, right)
        if left.exact ~= right.exact then return left.exact end
        if left.score ~= right.score then return left.score > right.score end
        return left.doc.identifier < right.doc.identifier
    end)
    local matches = {}
    for index=1,math.min(limit, #ranked) do matches[index] = ranked[index].doc end
    return matches
end
