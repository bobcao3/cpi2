return {
    name = "sh_repeat_until",
    version = 1,
    description = "Run a shell command repeatedly in the background while it exits zero. A nonzero exit stops the monitor. Each invocation must finish within the interval.",
    parameters = {
        type = "object",
        properties = {
            command = { type = "string", minLength = 1 },
            description = { type = "string", minLength = 1 },
            interval = { type = "number", minimum = 5, maximum = 60 },
            cwd = { type = "string" },
            env = { type = "object", additionalProperties = { type = "string" } },
        },
        required = { "command", "description", "interval" }, additionalProperties = false,
    },
    endpoints = { "process.repeat" }, recovery = "reconcile",
    execute = function(args)
        return host.call("process.repeat", {
            argv = { "/bin/sh", "-c", args.command },
            description = args.description,
            interval_ms = math.floor(args.interval * 1000),
            cwd = args.cwd,
            env = args.env,
        })
    end,
}
