return {
    name = "process",
    version = 1,
    description = "Inspect, read, wait for, send input to, resize, or capture a process job. Reads use byte offsets and retain raw output in a log.",
    parameters = {
        type = "object",
        properties = {
            operation = { type = "string", enum = { "status", "read", "wait", "write", "resize", "capture" } },
            id = { type = "string", minLength = 1 },
            offset = { type = "integer", minimum = 0 },
            limit = { type = "integer", minimum = 1, maximum = 65536 },
            wait_ms = { type = "integer", minimum = 0, maximum = 30000 },
            data = { type = "string" },
            columns = { type = "integer", minimum = 1, maximum = 500 },
            rows = { type = "integer", minimum = 1, maximum = 500 },
        },
        required = { "operation", "id" }, additionalProperties = false,
    },
    endpoints = { "process.status", "process.read", "process.wait", "process.write", "process.resize", "process.capture" },
    recovery = "never",
    execute = function(args)
        local endpoint = "process." .. args.operation
        args.operation = nil
        return host.call(endpoint, args)
    end,
}
