return {
    name = "sh_screenshot",
    version = 1,
    description = "Save a running PTY job's terminal viewport as a PNG artifact and return its path.",
    parameters = {
        type = "object",
        properties = {
            id = { type = "string", minLength = 1 },
            font_size = { type = "integer", minimum = 6, maximum = 96 },
        },
        required = { "id" }, additionalProperties = false,
    },
    endpoints = { "process.screenshot" }, recovery = "retry_safe",
    execute = function(args) return host.call("process.screenshot", args) end,
}
