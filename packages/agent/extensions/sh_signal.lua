return {
    name = "sh_signal",
    version = 1,
    description = "Send a signal to a shell job's process group. SIGINT is the default; SIGKILL stops jobs that ignore ordinary signals.",
    parameters = {
        type = "object",
        properties = {
            id = { type = "string", minLength = 1 },
            signal = { type = "string", minLength = 1 },
        },
        required = { "id" }, additionalProperties = false,
    },
    endpoints = { "process.signal" }, recovery = "never",
    execute = function(args)
        return host.call("process.signal", { id = args.id, signal = args.signal or "SIGINT" })
    end,
}
