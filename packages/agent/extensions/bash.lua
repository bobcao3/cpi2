return {
    name = "bash",
    version = 1,
    description = "Run a Bash command and return bounded output and exit status.",
    parameters = {
        type = "object",
        properties = {
            command = { type = "string", minLength = 1 },
            cwd = { type = "string", minLength = 1 },
            timeout_ms = { type = "integer", minimum = 1 },
        },
        required = { "command" },
        additionalProperties = false,
    },
    endpoints = { "process.exec" },
    recovery = "never",
    execute = function(args)
        return host.call("process.exec", {
            argv = { "bash", "-lc", args.command },
            cwd = args.cwd,
            timeout_ms = args.timeout_ms or 30000,
        })
    end,
}
