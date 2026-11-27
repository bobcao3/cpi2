local job = tools.sh({
    command = "printf 'hello from ghostmux\n'",
    description = "shell example",
    waitfor = 1,
})
return tools.process({ operation = "read", id = job.id })
