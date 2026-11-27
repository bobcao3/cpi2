local input = rt.call("session.input", {})
local results = rt.array()
for _, text in ipairs(input.responses) do table.insert(results, parse_response(text)) end
return results
