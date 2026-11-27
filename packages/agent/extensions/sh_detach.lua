return {
    name = "sh_detach",
    version = 1,
    description = "Detach a running shell job so it survives session shutdown. Its output continues to its log; normal session cleanup will leave it running.",
    parameters = {
        type = "object", properties = { id = { type = "string", minLength = 1 } },
        required = { "id" }, additionalProperties = false,
    },
    endpoints = { "process.detach" }, recovery = "never",
    execute = function(args) return host.call("process.detach", args) end,
}
