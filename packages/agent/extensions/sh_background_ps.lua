return {
    name = "sh_background_ps",
    version = 1,
    description = "List this session's active shell jobs and repeat monitors.",
    parameters = { type = "object", properties = {}, additionalProperties = false },
    endpoints = { "process.list" }, recovery = "retry_safe",
    execute = function(args)
        return host.call("process.list", {})
    end,
}
