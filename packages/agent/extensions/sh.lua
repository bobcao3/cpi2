return {
    name = "sh",
    version = 1,
    description = "Run a shell command, wait briefly, and leave unfinished work running in the background. Output and exit status remain available by job ID.",
    parameters = {
        type = "object",
        properties = {
            command = { type = "string", minLength = 1 },
            description = { type = "string", minLength = 1 },
            cwd = { type = "string" },
            env = { type = "object", additionalProperties = { type = "string" } },
            waitfor = { type = "number", minimum = 0, maximum = 30 },
            is_pty = { type = "boolean" },
        },
        required = { "command", "description" },
        additionalProperties = false,
    },
    endpoints = { "process.spawn", "process.wait" },
    recovery = "reconcile",
    execute = function(args)
        local job = host.call("process.spawn", {
            argv = { "/bin/sh", "-c", args.command },
            description = args.description,
            cwd = args.cwd,
            env = args.env,
            is_pty = args.is_pty or false,
        })
        return host.call("process.wait", {
            id = job.id,
            wait_ms = math.floor((args.waitfor or 5) * 1000),
        })
    end,
}
