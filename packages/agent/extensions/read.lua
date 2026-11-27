return {
    name = "read",
    version = 1,
    description = "Read UTF-8 text from a file with a bounded byte range.",
    parameters = {
        type = "object",
        properties = {
            path = { type = "string", minLength = 1 },
            offset_bytes = { type = "integer", minimum = 0 },
            max_bytes = { type = "integer", minimum = 1 },
        },
        required = { "path" },
        additionalProperties = false,
    },
    endpoints = { "files.read" },
    recovery = "retry_safe",
    execute = function(args)
        local ok, result = pcall(host.call, "files.read", {
            path = args.path,
            offset = args.offset_bytes or 0,
            limit = args.max_bytes or 65536,
        })
        if not ok then
            if string.find(result, "PermissionDenied", 1, true) then error("permission_denied", 0) end
            error("invalid_argument: " .. tostring(result), 0)
        end
        if type(result.text) ~= 'string' then error("invalid_utf8", 0) end
        return {text=result.text, next_offset_bytes=result.offset + #result.text, truncated=not result.eof}
    end,
}
