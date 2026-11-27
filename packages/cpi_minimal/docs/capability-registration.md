# Deferred tools in Minimal

Minimal owns discovery, helper definitions, and lazy execution. The shared
[session protocol](../../agent/docs/session-frames.md) stores private changes
through Minimal's context contract. It does not require a callable registry,
Luau, or MCP.

## Discover MCP tools from code

The default provider tool list contains `read`, `bash`, `edit`, and `write`.
Exposed MCP servers activate `execute_lua` when the tool selection permits it.
You can also activate scripts with `--tools +execute_lua`. Search for a tool
from within a script, inspect its schema, then call it by identifier. Discovered
tools stay callable through scripts. The system prompt lists exposed servers
without their complete catalogs. See the upstream workflow.
[Pi codemode documentation](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/codemode.md)

Use `execute_lua` with a `source` such as:

```lua
local matches = searchTools('echo text', {namespace='fixture', limit=5})
return matches
```

The script globals mirror Pi's discovery API: `searchTools` and `ALL_TOOLS`
return entries with the callable `name` and a `description` that includes the
JSON input schema. `describeTool(name)` returns that description, and
`describeNamespace(name)` returns the namespace and its tools. The lower-level
`tools.*` helpers are also available when you need raw schema objects,
per-server failures, or explicit refresh.

A search returns `{tools, errors}`. Each match has an exact callable
`identifier`, the tool's `name`, its `description`, and (for MCP) its `server`.
Search ranks names, titles, descriptions, and server descriptions. It defaults
to 8 matches and accepts limits from 1 to 50. Omit `server` to search the local
registry and all exposed MCP servers; a failing server appears in `errors`
without suppressing other results. A scoped search reports failure directly. An
omitted or empty `query` lists summaries in identifier order.

```lua
local entry = tools.describe_tool({server='fixture', name='echo'})
-- Inspect entry.input_schema before choosing arguments.
return tools[entry.identifier]({text='hello'})
```

`describe_tool({name=identifier})` works for local tools and already discovered
MCP tools. For an undiscovered MCP tool, pass its server and exact remote name.
`describe_namespace({server='fixture'})` returns server instructions and tool
identifiers. `discover_tools({server='fixture'})` still returns a full catalog,
including input schemas; `discover_tools` with a query, limit, or no server is a
search. Hyphens and underscores in server names are interchangeable, and the
`mcp__` namespace prefix is accepted.

Discovery and invocation can occur in one program. Scoped discovery waits only
for that server, inside its admitted service operation. Pass `refresh=true` to
search or discovery to request a new catalog. A successful refresh replaces that
server's definitions and removes helpers absent from the catalog. A failed
refresh leaves the installed private definitions unchanged.

## Script output

Script results start with `Script completed` or `Script failed`, the wall time,
and `Output:`. `text(value)` and a top-level `return` add text entries; several
entries are numbered. `console.log(...)` writes to a trailing `<console_output>`
block, and a failed script keeps partial output before `Script error:`. Use
`image({mimeType=..., data=...})` to attach an MCP image block. By default, long
text is reduced to the first and last parts of a 10,000 estimated token budget;
you can lower it with `-- @options: {"max_output_tokens": 2000}` on the first
line. Full truncated text and attached images are saved to private files in the
session's `tool-output` directory. `store(key, value)` and `load(key)` keep JSON
values between successful calls. `ctx` and `output.control` remain available to
existing scripts.

MCP `input_schema` remains the server's JSON Schema. Minimal preserves it for
inspection rather than interpreting it as its smaller Luau parameter-schema
language. MCP calls still require an argument object. The server validates its
own tool arguments. Results retain `CallToolResult`, including `isError`,
images, and `structuredContent`.

## Register code-only helpers

```lua
tools.register_deferred_tools({
    source='arithmetic',
    definitions={{
        name='double',
        description='Double an integer.',
        parameters={
            type='object', properties={n={type='integer'}}, required={'n'},
            additionalProperties=false,
        },
        handler={kind='luau', source='return function(args) return args.n * 2 end'},
    }},
})
return tools.double({n=3})
```

See [the batch parser](../src/tools/deferred_tools.luau) for fields and size
warnings. `replace_source` drops the old set from that source before the new set
takes effect. Names use ASCII identifiers. Built-ins are reserved.

Minimal checks and compiles source at setup. It runs the factory on first use,
not at setup. The function lives for one invocation. Save state in `ctx`, not in
the closure.

A batch takes effect only after its checkpoint commits. On failure the old set
stays live. Old function refs keep their old definitions; new lookups see the
new set.

`Controller.registerDeferredTools` saves the batch before it returns an owned
request. Install and receipt share one commit. A pending batch can run after
reopen. The same ID and batch return the first result; new content with that ID
conflicts. Rejection does not block the next turn.

## Discovery ownership

`preload=true` starts discovery after Minimal opens its Worker, without delaying
the first model request. Foreground service operations belong to Controller and
join before Minimal releases the gateway. The MCP guide owns the shared
[cached-read](../../mcp/README.md#cached-reads-and-operations) and
[shutdown](../../mcp/README.md#transport-and-lifetime-rules) contracts.

The gateway does not publish session actions. Minimal imports a completed
catalog into its private registry at an explicit discovery boundary. A source
completion cannot mutate an obsolete worker or overwrite an unrelated worker's
definitions.

## Authority and replay

Helper names grant no access. Controller still checks the grant, policy, and
server allowlist. The journal saves helper source and remote IDs, not live
sockets or functions. Replay does not run source or connect. A later call can
build the helper or connect. It does not replay an uncertain effect.

## Shared checks

```sh
anyzig 0.17.1 build --fork "$HOME/Kit.zig" test-controller test-mcp
```

These targets exercise shared Controller and MCP gateway contracts. Test the
Minimal CLI against isolated local providers and MCP servers when changing its
registration and discovery behavior.
