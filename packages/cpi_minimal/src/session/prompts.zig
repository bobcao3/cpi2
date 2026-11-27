const std = @import("std");
const ToolLoadout = @import("../tools.zig").ToolLoadout;

pub const upstream_revision = "90b42bca6ed161b8e7ee40ceda9755205c2882ec";

pub const tool_text = .{
    .preamble = "You are a coding assistant running inside pi, a coding agent harness. Help users inspect files, run commands, and modify code.",
    .snippets = .{
        .read = "Read file contents",
        .bash = "Execute bash commands (ls, grep, find, etc.)",
        .edit = "Make precise file edits with exact text replacement, including multiple disjoint edits in one call",
        .write = "Create or overwrite files",
        .grep = "Search file contents for patterns (respects .gitignore)",
        .find = "Find files by glob pattern (respects .gitignore)",
        .ls = "List directory contents",
        .execute_lua = "Run Luau that calls other tools",
    },
    .rules = .{
        .read = "- Use read to examine files instead of cat or sed.\n",
        .bash = "- You can inspect PI_* environment variables for current model and session details.\n",
        .edit = "- Use edit for targeted changes. Batch changes to one file in a single call.\n" ++
            "- Each edits[].oldText must exactly and uniquely match the original file. Keep matches short and non-overlapping; merge nearby changes without including large unchanged regions.\n",
        .write = "- Use write only for new files or complete rewrites.\n",
        .grep = "",
        .find = "",
        .ls = "",
        .execute_lua = "- Use execute_lua to batch independent tool calls, chain them, or filter large output, instead of many separate calls.\n",
    },
    .bash_files = .{
        .rule = "- Use bash for file operations like ls, rg, find\n",
        .unless = @as([]const ToolLoadout.Tool, &.{ .grep, .find, .ls }),
    },
    .general_rules = "- Be concise in your responses\n- Show file paths clearly when working with files\n",
};

/// Builds the system prompt in a single owned buffer. Callers free exactly one
/// slice; formatting a temporary per section and returning only the last one
/// leaks every earlier allocation.
pub fn system(a: std.mem.Allocator, cwd: []const u8, tools: []const ToolLoadout.Tool, skills: []const u8, mcp: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(tool_text.preamble ++ "\n\n<tools>\n");
    if (tools.len == 0) try w.writeAll("(none)\n");
    for (tools) |tool| try w.print("- {s}: {s}\n", .{ @tagName(tool), switch (tool) {
        inline else => |name| @field(tool_text.snippets, @tagName(name)),
    } });
    try w.writeAll("\nAdditional tools may be available.\n</tools>\n\n<rules>\n");
    const bash = std.mem.indexOfScalar(ToolLoadout.Tool, tools, .bash) != null;
    const has_search = for (tool_text.bash_files.unless) |tool| {
        if (std.mem.indexOfScalar(ToolLoadout.Tool, tools, tool) != null) break true;
    } else false;
    if (bash and !has_search) try w.writeAll(tool_text.bash_files.rule);
    for (tools) |tool| {
        if (tool == .read and !bash) continue;
        try w.writeAll(switch (tool) {
            inline else => |name| @field(tool_text.rules, @tagName(name)),
        });
    }
    try w.writeAll(tool_text.general_rules ++ "</rules>\n\n");
    if (skills.len > 0) try w.print("<skills>\n{s}\n</skills>\n\n", .{skills});
    try w.writeAll("<cwd>\n");
    try w.writeAll(cwd);
    try w.writeAll("\n</cwd>\n\n");
    if (mcp.len > 0) try w.print("<mcp_servers>\n{s}\n</mcp_servers>\n\n", .{mcp});
    return out.toOwnedSlice();
}

pub const summary_system =
    \\You are a context summarization assistant. Your task is to read a conversation between a user and an AI assistant, then produce a structured summary following the exact format specified.
    \\
    \\Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.
;

// Pi v1.6.1 branch summarization prompt. See THIRD_PARTY_NOTICES.md.
pub const branch_summary =
    \\Create a structured summary of this conversation branch for context when returning later.
    \\
    \\Use this EXACT format:
    \\
    \\## Goal
    \\[What was the user trying to accomplish in this branch?]
    \\
    \\## Constraints & Preferences
    \\- [Any constraints, preferences, or requirements mentioned]
    \\- [Or "(none)" if none were mentioned]
    \\
    \\## Progress
    \\### Done
    \\- [x] [Completed tasks/changes]
    \\
    \\### In Progress
    \\- [ ] [Work that was started but not finished]
    \\
    \\### Blocked
    \\- [Issues preventing progress, if any]
    \\
    \\## Key Decisions
    \\- **[Decision]**: [Brief rationale]
    \\
    \\## Next Steps
    \\1. [What should happen next to continue this work]
    \\
    \\Keep each section concise. Preserve exact file paths, function names, and error messages.
;

pub const summary =
    \\The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.
    \\
    \\Use this EXACT format:
    \\
    \\## Goal
    \\[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]
    \\
    \\## Constraints & Preferences
    \\- [Any constraints, preferences, or requirements mentioned by user]
    \\- [Or "(none)" if none were mentioned]
    \\
    \\## Progress
    \\### Done
    \\- [x] [Completed tasks/changes]
    \\
    \\### In Progress
    \\- [ ] [Current work]
    \\
    \\### Blocked
    \\- [Issues preventing progress, if any]
    \\
    \\## Key Decisions
    \\- **[Decision]**: [Brief rationale]
    \\
    \\## Next Steps
    \\1. [Ordered list of what should happen next]
    \\
    \\## Critical Context
    \\- [Any data, examples, or references needed to continue]
    \\- [Or "(none)" if not applicable]
    \\
    \\Keep each section concise. Preserve exact file paths, function names, and error messages.
;

pub const update_summary =
    \\The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.
    \\
    \\Update the existing structured summary with new information. RULES:
    \\- PRESERVE all existing information from the previous summary
    \\- ADD new progress, decisions, and context from the new messages
    \\- UPDATE the Progress section: move items from "In Progress" to "Done" when completed
    \\- UPDATE "Next Steps" based on what was accomplished
    \\- PRESERVE exact file paths, function names, and error messages
    \\- If something is no longer relevant, you may remove it
    \\
    \\Use this EXACT format:
    \\
    \\## Goal
    \\[Preserve existing goals, add new ones if the task expanded]
    \\
    \\## Constraints & Preferences
    \\- [Preserve existing, add new ones discovered]
    \\
    \\## Progress
    \\### Done
    \\- [x] [Include previously done items AND newly completed items]
    \\
    \\### In Progress
    \\- [ ] [Current work - update based on progress]
    \\
    \\### Blocked
    \\- [Current blockers - remove if resolved]
    \\
    \\## Key Decisions
    \\- **[Decision]**: [Brief rationale] (preserve all previous, add new)
    \\
    \\## Next Steps
    \\1. [Update based on current state]
    \\
    \\## Critical Context
    \\- [Preserve important context, add new if needed]
    \\
    \\Keep each section concise. Preserve exact file paths, function names, and error messages.
;

pub const turn_prefix =
    \\The messages above are earlier context from an ongoing conversation. Later messages are stored separately and do not need to be reconstructed.
    \\
    \\Create a concise checkpoint of the user's request and the progress shown above. This checkpoint will be placed before the later messages so the conversation can continue with the necessary context.
    \\
    \\## Original Request
    \\[What did the user ask for?]
    \\
    \\## Progress So Far
    \\- [Key decisions and work completed in these messages]
    \\
    \\## Context Needed to Continue
    \\- [Information from these messages needed to understand the later work]
    \\
    \\Only summarize information explicitly present above. Do not infer or recreate later messages.
;
