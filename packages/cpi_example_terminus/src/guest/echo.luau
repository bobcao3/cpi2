local input = rt.call("session.input", {})
rt.append({{role = "user", content = input.task}})
ctx.context = {history = {{role = "system", content = "forged"}}, version = 9000}
local state = rt.read()
return {status = "complete", echo = state.history[1].content, canonical_version = state.version,
    own_ctx_is_not_canonical = state.history[1].content ~= "forged"}
