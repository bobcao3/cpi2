# Session frame examples

**Schema draft. Documentation fixtures, not runtime conformance tests.** Read
the [action catalog](session-frames.md). Each JSONL block is a standalone
logical log. Transaction IDs determine compressed member boundaries.

## Fixture contracts

The fixture adapter is `fixture/1` and renderer is `example/1`. They are example
contracts, not installed production providers. Host services are `files/1` and
`process/1`. No example performs network or OS work.

The renderer hashes three RFC 8785 JSON values. Instructions are the selected
messages with system/developer roles, in order. The message value contains the
other selected messages, in order. Placement and provenance are not message
content. Tools are current `definition` objects sorted by session-local tool
name. Handler payloads never enter the provider tool value. These fixtures use
only the subset where sorted compact Python JSON equals RFC 8785 output. Hashes
cover no trailing newline.

Harness-owned contracts used only by these examples:

- `example.python/1` owns the handler payload's package, source, entry point and
  source SHA-256. The shared framework knows none of those fields.
- `example.context-jobs/1` starts with a list `[]`. `begin` appends a pending
  job; `finish` replaces its status with completed. Its head is namespace-local.
- `example.command/1` starts with null. `plan` replaces it with a command
  string. The framework does not interpret or execute that string.

## Provider tool, replacement and compaction

A Python harness owns the handler descriptor. The core neither loads its source
nor requires a callable registration. Replacement takes two controls. Compaction
pending state belongs to a fixture extension contract; the document cut remains
a core action.

```jsonl
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"capability","data":{"config":{},"name":"files.read","service":{"id":"files","version":"1"}},"op":"capability.bind","seq":1,"session_id":"provider-example","tx":{"count":1,"id":"tx-1","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"control","data":{"definition":{"description":"Read a file","name":"read","parameters":{"additionalProperties":false,"properties":{"path":{"type":"string"}},"required":["path"],"type":"object"},"type":"function"},"handler":{"contract":{"id":"example.python","version":"1"},"value":{"entry":"run","package":"example/read.py","sha256":"8036348f53161f6860498e7884195d8e8270edc832371e80365f400ca26d0e05","source":"def run(args, native):\n    return native(\"files.read\", args)\n"}},"name":"read"},"op":"control.provider_tool.register","seq":2,"session_id":"provider-example","tx":{"count":1,"id":"tx-2","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"control","data":{"adapter":{"id":"fixture","version":"1"},"credential_ref":null,"kwargs":{},"model":"model-a","provider":"fixture","route":"fixture-loopback"},"op":"control.set_model","seq":3,"session_id":"provider-example","tx":{"count":1,"id":"tx-3","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"document","data":{"message":{"content":[{"text":"Inspect the requested file.","type":"text"}],"id":"system-1","role":"system"},"placement":{"after":null,"context":"main"}},"op":"document.message.append","seq":4,"session_id":"provider-example","tx":{"count":1,"id":"tx-4","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"document","data":{"message":{"content":[{"text":"Read /fixture/example.txt","type":"text"}],"id":"user-1","role":"user"},"placement":{"after":"system-1","context":"main"}},"op":"document.message.append","seq":5,"session_id":"provider-example","tx":{"count":1,"id":"tx-5","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"control","data":{"context":"main","input_at":5,"instructions_sha256":"94cafb6fd7b7fe4ae1d5cfe583826dc27fff2b9f73510ff4604aee8a240fdb95","kwargs":{},"messages_sha256":"b4fc3e2af520731ee75f0c4b332d8f87e5150a7fae1bc5e5eb0cc71ad95605c7","model_frame":3,"renderer":{"id":"example","version":"1"},"request_id":"model-1","tools_sha256":"68cb34bcf819745601a474a9454843ea980de0f37b18cb224098fd0fd6f2ea14"},"op":"control.model.request","seq":6,"session_id":"provider-example","tx":{"count":1,"id":"tx-6","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":6,"class":"document","data":{"message":{"content":[],"id":"call-document-1","role":"assistant","tool_calls":[{"arguments":{"path":"/fixture/example.txt"},"id":"call-1","name":"read"}]},"placement":{"after":"user-1","context":"main"},"request":"model-1"},"op":"document.message.append","seq":7,"session_id":"provider-example","tx":{"count":2,"id":"tx-7","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":6,"class":"control","data":{"diagnostic":null,"request_id":"model-1","status":"completed","usage":null},"op":"control.model.finish","seq":8,"session_id":"provider-example","tx":{"count":2,"id":"tx-7","index":1},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":7,"class":"control","data":{"arguments":{"path":"/fixture/example.txt"},"effect_id":"effect-1","endpoint":{"binding":1,"name":"files.read"},"key":"file-read-1","recovery":"never","source_message":"call-document-1"},"op":"control.effect.intent","seq":9,"session_id":"provider-example","tx":{"count":1,"id":"tx-8","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":9,"class":"control","data":{"effect_id":"effect-1","result":{"text":"hello"},"status":"completed"},"op":"control.effect.result","seq":10,"session_id":"provider-example","tx":{"count":1,"id":"tx-9","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":10,"class":"document","data":{"message":{"content":[{"text":"hello","type":"text"}],"id":"result-document-1","role":"tool","tool_call_id":"call-1"},"placement":{"after":"call-document-1","context":"main"},"source":10},"op":"document.message.append","seq":11,"session_id":"provider-example","tx":{"count":1,"id":"tx-10","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"control","data":{"context":"main","input_at":11,"instructions_sha256":"94cafb6fd7b7fe4ae1d5cfe583826dc27fff2b9f73510ff4604aee8a240fdb95","kwargs":{},"messages_sha256":"919497a7f9f91d83f52fbd550eec10231659134675a0fc9fdfad18cbb22f05b0","model_frame":3,"renderer":{"id":"example","version":"1"},"request_id":"model-2","tools_sha256":"68cb34bcf819745601a474a9454843ea980de0f37b18cb224098fd0fd6f2ea14"},"op":"control.model.request","seq":12,"session_id":"provider-example","tx":{"count":1,"id":"tx-11","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":12,"class":"document","data":{"message":{"content":[{"text":"The file contains hello.","type":"text"}],"id":"agent-1","role":"assistant"},"placement":{"after":"result-document-1","context":"main"},"request":"model-2"},"op":"document.message.append","seq":13,"session_id":"provider-example","tx":{"count":2,"id":"tx-12","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":12,"class":"control","data":{"diagnostic":null,"request_id":"model-2","status":"completed","usage":null},"op":"control.model.finish","seq":14,"session_id":"provider-example","tx":{"count":2,"id":"tx-12","index":1},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"control","data":{"name":"read","registration":2},"op":"control.provider_tool.deregister","seq":15,"session_id":"provider-example","tx":{"count":2,"id":"tx-13","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"control","data":{"definition":{"description":"Read a file","name":"read","parameters":{"additionalProperties":false,"properties":{"path":{"type":"string"}},"required":["path"],"type":"object"},"type":"function"},"handler":{"contract":{"id":"example.python","version":"1"},"value":{"entry":"run","package":"implicit/read-2.py","sha256":"206d07a77b6976cefb40f6abfd2dff3bc47cedc961c8bb821d0b351dab39527c","source":"def run(args, native):\n    result = native(\"files.read\", args)\n    return result\n"}},"name":"read"},"op":"control.provider_tool.register","seq":16,"session_id":"provider-example","tx":{"count":2,"id":"tx-13","index":1},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"control","data":{"adapter":{"id":"fixture","version":"1"},"credential_ref":null,"kwargs":{},"model":"model-b","provider":"fixture","route":"fixture-loopback"},"op":"control.set_model","seq":17,"session_id":"provider-example","tx":{"count":1,"id":"tx-14","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"control","data":{"action":"begin","expected_head":0,"input":{"contract":{"id":"example.context-jobs","version":"1"},"value":{"context":"main","head":13,"id":"compact-1"}},"namespace":"example.context-jobs"},"op":"control.extension","seq":18,"session_id":"provider-example","tx":{"count":1,"id":"tx-15","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":18,"class":"document","data":{"message":{"content":[{"text":"The requested file was read and contained hello.","type":"text"}],"id":"summary-1","role":"system"},"placement":null},"op":"document.message.append","seq":19,"session_id":"provider-example","tx":{"count":3,"id":"tx-16","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":18,"class":"control","data":{"context":"main","edits":[{"ids":["user-1","call-document-1","result-document-1","agent-1"],"op":"drop"},{"after":"system-1","ids":["summary-1"],"op":"insert"}],"expected_head":13},"op":"control.document_mutation","seq":20,"session_id":"provider-example","tx":{"count":3,"id":"tx-16","index":1},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":18,"class":"control","data":{"action":"finish","expected_head":18,"input":{"contract":{"id":"example.context-jobs","version":"1"},"value":{"id":"compact-1"}},"namespace":"example.context-jobs"},"op":"control.extension","seq":21,"session_id":"provider-example","tx":{"count":3,"id":"tx-16","index":2},"v":1}
```

## Custom JSON action without provider tools

The harness parses agent JSON and records its selected command as scalar private
state. Native execution uses a bound service. There is no provider
advertisement, shared callable, invocation record or prescribed ctx object.

```jsonl
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"capability","data":{"config":{},"name":"process.exec","service":{"id":"process","version":"1"}},"op":"capability.bind","seq":1,"session_id":"custom-example","tx":{"count":1,"id":"tx-1","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"control","data":{"adapter":{"id":"fixture","version":"1"},"credential_ref":null,"kwargs":{},"model":"model-a","provider":"fixture","route":"fixture-loopback"},"op":"control.set_model","seq":2,"session_id":"custom-example","tx":{"count":1,"id":"tx-2","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"document","data":{"message":{"content":[{"text":"Return JSON with a command string. No provider tools are exposed.","type":"text"}],"id":"system-1","role":"system"},"placement":{"after":null,"context":"main"}},"op":"document.message.append","seq":3,"session_id":"custom-example","tx":{"count":1,"id":"tx-3","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"document","data":{"message":{"content":[{"text":"Print hello.","type":"text"}],"id":"user-1","role":"user"},"placement":{"after":"system-1","context":"main"}},"op":"document.message.append","seq":4,"session_id":"custom-example","tx":{"count":1,"id":"tx-4","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"control","data":{"context":"main","input_at":4,"instructions_sha256":"a632f7e1f7424ff246c2d519bd8852d9514fa7b029bf0711df59761f048c9022","kwargs":{},"messages_sha256":"c561963c8f53df5baa65b4c0012798eda19b86a3612d6e0c915518c89d4cbcc0","model_frame":2,"renderer":{"id":"example","version":"1"},"request_id":"model-1","tools_sha256":"4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"},"op":"control.model.request","seq":5,"session_id":"custom-example","tx":{"count":1,"id":"tx-5","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":5,"class":"document","data":{"message":{"content":[{"type":"json","value":{"command":"printf hello"}}],"id":"agent-1","role":"assistant"},"placement":{"after":"user-1","context":"main"},"request":"model-1"},"op":"document.message.append","seq":6,"session_id":"custom-example","tx":{"count":2,"id":"tx-6","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":5,"class":"control","data":{"diagnostic":null,"request_id":"model-1","status":"completed","usage":null},"op":"control.model.finish","seq":7,"session_id":"custom-example","tx":{"count":2,"id":"tx-6","index":1},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"control","data":{"action":"plan","expected_head":0,"input":{"contract":{"id":"example.command","version":"1"},"value":"printf hello"},"namespace":"example.command"},"op":"control.extension","seq":8,"session_id":"custom-example","tx":{"count":1,"id":"tx-7","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":8,"class":"control","data":{"arguments":{"command":"printf hello"},"effect_id":"effect-1","endpoint":{"binding":1,"name":"process.exec"},"key":"terminal-command-1","recovery":"never","source_message":"agent-1"},"op":"control.effect.intent","seq":9,"session_id":"custom-example","tx":{"count":1,"id":"tx-8","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":9,"class":"control","data":{"effect_id":"effect-1","result":{"exit_code":0,"stdout":"hello"},"status":"completed"},"op":"control.effect.result","seq":10,"session_id":"custom-example","tx":{"count":1,"id":"tx-9","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":10,"class":"document","data":{"message":{"content":[{"text":"hello","type":"text"}],"id":"observation-1","role":"user"},"placement":{"after":"agent-1","context":"main"},"source":10},"op":"document.message.append","seq":11,"session_id":"custom-example","tx":{"count":1,"id":"tx-10","index":0},"v":1}
```

## Provider-executed tool without a local handler

The provider definition has no function parameters. Its handler is null. The
response records call, result and agent content without inventing any local
invocation or native effect.

```jsonl
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"control","data":{"adapter":{"id":"fixture","version":"1"},"credential_ref":null,"kwargs":{},"model":"model-a","provider":"fixture","route":"fixture-loopback"},"op":"control.set_model","seq":1,"session_id":"hosted-example","tx":{"count":1,"id":"tx-1","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"control","data":{"definition":{"type":"web_search"},"handler":null,"name":"search"},"op":"control.provider_tool.register","seq":2,"session_id":"hosted-example","tx":{"count":1,"id":"tx-2","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"document","data":{"message":{"content":[{"text":"Search for the project documentation.","type":"text"}],"id":"user-1","role":"user"},"placement":{"after":null,"context":"main"}},"op":"document.message.append","seq":3,"session_id":"hosted-example","tx":{"count":1,"id":"tx-3","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":null,"class":"control","data":{"context":"main","input_at":3,"instructions_sha256":"4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945","kwargs":{},"messages_sha256":"535d5f4a5c581387e0f5cfaf4b6f5b13400997b92f19d94aa73fdda902fb5279","model_frame":1,"renderer":{"id":"example","version":"1"},"request_id":"model-1","tools_sha256":"5d1e03d0542eaf2f5a8ceb00225a916490fd0e9992143db63dd29497dbd9e718"},"op":"control.model.request","seq":4,"session_id":"hosted-example","tx":{"count":1,"id":"tx-4","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":4,"class":"document","data":{"message":{"content":[],"id":"call-document-1","role":"assistant","tool_calls":[{"arguments":{"query":"project documentation"},"id":"search-1","name":"search"}]},"placement":{"after":"user-1","context":"main"},"request":"model-1"},"op":"document.message.append","seq":5,"session_id":"hosted-example","tx":{"count":4,"id":"tx-5","index":0},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":4,"class":"document","data":{"message":{"content":[{"text":"Found the documentation.","type":"text"}],"id":"result-document-1","role":"tool","tool_call_id":"search-1"},"placement":{"after":"call-document-1","context":"main"}},"op":"document.message.append","seq":6,"session_id":"hosted-example","tx":{"count":4,"id":"tx-5","index":1},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":4,"class":"document","data":{"message":{"content":[{"text":"The documentation was found.","type":"text"}],"id":"agent-1","role":"assistant"},"placement":{"after":"result-document-1","context":"main"},"request":"model-1"},"op":"document.message.append","seq":7,"session_id":"hosted-example","tx":{"count":4,"id":"tx-5","index":2},"v":1}
{"actor":{"id":"fixture-host","kind":"host"},"cause":4,"class":"control","data":{"diagnostic":null,"request_id":"model-1","status":"completed","usage":null},"op":"control.model.finish","seq":8,"session_id":"hosted-example","tx":{"count":4,"id":"tx-5","index":3},"v":1}
```

## Required negative cases

- Reject stale tool registrations and context/extension heads.
- Reject incomplete provider call/result selections before another model
  request.
- Reject a source-hash mismatch under the fixture Python contract, not a core
  language rule.
- Reject missing extension contracts for full state reconstruction. Raw
  inspection remains possible.
- Never skip unknown extension state and report a complete reconstructed
  session.
- Keep recorded effects uncertain when no confirmed receipt exists. Do not
  redispatch on replay.
- Preserve original instructions and dropped documents after compaction.
- Accept further document actions without any process open, close or resume
  frame.

These examples define fixture contracts only. They impose no Python, Luau,
shared-context, helper registry or execution-scope requirement on other
harnesses.
