local file = tools.read({path = "README.md"})
local process = tools.bash({command = "printf 'hello from Bash'"})
ctx.example_runs = (ctx.example_runs or 0) + 1
return {
    runs = ctx.example_runs,
    read_bytes = #file.text,
    bash_stdout = process.stdout,
    exit_code = process.exit_code,
}
