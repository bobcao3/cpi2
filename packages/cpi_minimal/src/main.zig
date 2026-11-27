const std = @import("std");
const builtin = @import("builtin");
const kit = @import("kit");
const dotenv = @import("dotenv");
const registry = @import("model_registry");
const configuration = @import("config.zig");
const providers = @import("providers.zig");
const sessions = @import("session.zig");
const tools = @import("tools.zig");
const ui = @import("tui.zig");
const trace = @import("trace.zig");

const Auth = providers.Auth;
const ClipboardX11 = ui.ClipboardX11;
const Config = configuration.Config;
const Controller = sessions.Controller;
const ModelRoutes = providers.ModelRoutes;
const Paths = configuration.Paths;
const SessionIndex = sessions.SessionIndex;
const Settings = configuration.Settings;
const StartupFiles = sessions.StartupFiles;
const Theme = ui.Theme;
const ToolLoadout = tools.ToolLoadout;
const UiPresentation = ui.Presentation;
const WorkspaceSession = sessions.WorkspaceSession;

const Options = struct {
    workspace: []const u8 = ".",
    memory_bytes: ?usize = null,
    session: ?[]const u8 = null,
    session_directory: ?[]const u8 = null,
    no_session: bool = false,
    continue_session: bool = false,
    resume_picker: bool = false,
    continue_queue: bool = false,
    continue_turn: bool = false,
    reset_context: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    receipt_id: ?[]const u8 = null,
    receipt_json: bool = false,
    view: ?enum { inspect, watch } = null,
    view_conversation: ?[]const u8 = null,
    conversation: ?[]const u8 = null,
    fork_at: ?[]const u8 = null,
    print: bool = false,
    interactive: bool = false,
    tui_mode: ?Settings.TuiMode = null,
    themes: std.ArrayList([]const u8) = .empty,
    compact: bool = false,
    no_env: bool = false,
    env_files: std.ArrayList([]const u8) = .empty,
    prompts: std.ArrayList([]const u8) = .empty,
    files: std.ArrayList([]const u8) = .empty,
    explicit_prompts: bool = false,
    skills: std.ArrayList([]const u8) = .empty,
    no_skills: bool = false,
    enable_skill_commands: ?bool = null,
    mcp: ?[]const u8 = null,
    no_mcp: bool = false,
    tool_loadout: ToolLoadout = .{},
    mcp_project: bool = false,
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model_registry: ?[]const u8 = null,
    list_models: bool = false,
    base_url: ?[]const u8 = null,
    context_window: ?u64 = null,
    reserve_tokens: u64 = 16384,
    keep_recent_tokens: u64 = 20000,
    background_compaction_tokens: u64 = 32768,
    max_output_tokens: ?u32 = null,
    effort: ?[]const u8 = null,
    thinking_levels: ?[]const u8 = null,
    provider_retries: ?u8 = null,
    provider_retry_delay_ms: ?u32 = null,
    provider_retry_max_delay_ms: ?u32 = null,
    trace_path: ?[]const u8 = null,
    trace: bool = false,
    timings: bool = false,
};

fn usage() void {
    std.debug.print(
        "cpi-minimal [options] [@file ...] [prompt]\n" ++
            "  -p, --print                 Print the response and exit\n" ++
            "  --prompt TEXT               Batch turn and exit; may repeat\n" ++
            "  --request-id ID             Deduplicate one prompt within its session\n" ++
            "  --receipt ID                Print the status of a named prompt\n" ++
            "  --receipt-json              Include the run outcome and entry IDs as JSON\n" ++
            "  --inspect                   Read a committed session snapshot as JSON\n" ++
            "  --watch                     Follow changes to that snapshot as JSON lines\n" ++
            "  --view-conversation ID      Select a conversation for --inspect or --watch\n" ++
            "  --fork ENTRY_ID             Create a conversation from a historical entry\n" ++
            "  --conversation ID           Address batch input, receipts, or a fork's parent\n" ++
            "  --interactive               Run initial prompts, then stay in the TUI\n" ++
            "  --tui-mode MODE             Fullscreen (default) or regular terminal scrollback\n" ++
            "  --theme PATH                Load a theme file or directory; may repeat\n" ++
            "  --workspace DIR             Working directory for all four tools\n" ++
            "  --session PATH              Open or create a Worker session file\n" ++
            "  --session ID                Find a saved session by ID or prefix\n" ++
            "  -r, --resume                Choose an existing session\n" ++
            "  -c, --continue              Continue the latest session for this workspace\n" ++
            "  --continue-queue            Release a paused follow-up queue\n" ++
            "  CPI_AFTER_FAILED_RUN        keep (default), continue, or withdraw\n" ++
            "  CPI_FOLLOW_UP_MODE          one-at-a-time (default) or all\n" ++
            "  --continue-turn             Answer the unresolved context without a new prompt\n" ++
            "  --reset-context TEXT        Reset the context with an optional note (pass '' for none)\n" ++
            "  --session-dir DIR           Store new sessions in DIR\n" ++
            "  --no-session                Keep the conversation in memory\n" ++
            "  --memory-bytes N            Shared allocation warning threshold in bytes\n" ++
            "  --compact                   Compact after the supplied turns\n" ++
            "  --skill PATH                Load a skill file or directory; may repeat\n" ++
            "  --no-skills, -ns            Disable discovery, keeping explicit paths\n" ++
            "  --tools, -t LIST            Tool names or * patterns, or +name/-name modifiers\n" ++
            "  --exclude-tools, -xt LIST   Exclude tool names or * patterns\n" ++
            "  --no-tools, -nt             Start with no active tools\n" ++
            "  --no-builtin-tools, -nbt    Start with built-in tools inactive\n" ++
            "  --config PATH               Load a key = value user config file\n" ++
            "  --no-config                 Do not load the user config file\n" ++
            "  --mcp-config PATH           Load MCP servers from a Lua registration file\n" ++
            "  --no-mcp                    Disable MCP servers entirely\n" ++
            "  --mcp-project               Allow .pi/mcp.lua from the workspace\n" ++
            "  --model NAME                Select the provider's model for this process\n" ++
            "  --provider ID               Select provider, e.g. deepseek (CPI_PROVIDER)\n" ++
            "  --model-registry PATH       Load a Lua registry (CPI_MODEL_REGISTRY)\n" ++
            "  --list-models               Sync configured providers; print registry JSON (local fallback)\n" ++
            "  --base-url URL              Explicit provider endpoint override\n" ++
            "  --reasoning-effort VALUE    Select thinking effort\n" ++
            "  --thinking-levels LIST      Override capabilities, comma-separated levels\n" ++
            "  --context-window N          Override registry context window, fallback 128000\n" ++
            "  --reserve-tokens N          Compaction reserve, default 16384\n" ++
            "  --keep-recent-tokens N      Recent context to retain, default 20000\n" ++
            "  --background-compaction-tokens N  Lead before blocking compaction, default 32768 (0 disables)\n" ++
            "  --max-output-tokens N       Override registry-aware output default (<=16384)\n" ++
            "  --provider-retries N        Limit fresh retries after a transient failure (default unlimited)\n" ++
            "  --provider-retry-delay-ms N Initial retry delay, doubled per attempt (default 500)\n" ++
            "  --provider-retry-max-delay-ms N  Maximum retry delay (default 30000)\n" ++
            "  --env-file PATH             Load an explicit dotenv file; may repeat\n" ++
            "  --no-env                    Do not load dotenv files\n" ++
            "  --timings                   Report TUI latency statistics on stderr at exit\n" ++
            "  --trace                     Record startup spans (boolean, no path)\n" ++
            "  --trace-file PATH           Enable tracing to an explicit Chrome trace\n" ++
            "                              and prints a latency summary on exit\n" ++
            "  -h, --help                  Show this help\n\n" ++
            "Positional prompts open the TUI on a terminal. Use --prompt or --print for batch mode.\n" ++
            "Positional @file arguments attach text or images to the first prompt.\n" ++
            "Batch slash text is model input, not interactive local commands.\n" ++
            "DeepSeek: --provider deepseek; DEEPSEEK_API_KEY or /login deepseek.\n" ++
            "DEEPSEEK_MODEL selects its model (default deepseek-flash); --model overrides.\n" ++
            "Named DeepSeek settings do not consume OpenAI keys, model, or transport.\n" ++
            "OpenAI-compatible servers use OPENAI_API_KEY and OPENAI_MODEL.\n" ++
            "OPENAI_BASE_URL defaults to\n" ++
            "https://api.openai.com/v1. OPENAI_TRANSPORT selects http, websocket,\n" ++
            "or websocket-cached (Codex only).\n" ++
            "OPENAI_PROTOCOL=codex selects subscription access and requires\n" ++
            "OPENAI_ACCESS_TOKEN and CHATGPT_ACCOUNT_ID instead of OPENAI_API_KEY.\n" ++
            "Loads .env from the launch directory unless --no-env or --env-file is given.\n" ++
            "Loads external model metadata from --model-registry, CPI_MODEL_REGISTRY,\n" ++
            "the per-user ~/.cpi-minimal/models.lua, or the installed share/cpi/models.lua.\n",
        .{},
    );
}

fn options(a: std.mem.Allocator, args: []const []const u8, config: Config) !Options {
    var out: Options = .{
        .session_directory = config.session_dir,
        .model = config.model,
        .provider = config.provider,
        .model_registry = config.model_registry,
        .base_url = config.base_url,
        .context_window = config.context_window,
        .reserve_tokens = config.reserve_tokens orelse 16384,
        .keep_recent_tokens = config.keep_recent_tokens orelse 20000,
        .background_compaction_tokens = config.background_compaction_tokens orelse 32768,
        .max_output_tokens = config.max_output_tokens,
        .effort = config.reasoning_effort,
        .thinking_levels = config.thinking_levels,
        .provider_retries = config.provider_retries,
        .provider_retry_delay_ms = config.provider_retry_delay_ms,
        .provider_retry_max_delay_ms = config.provider_retry_max_delay_ms,
        .mcp = config.mcp_config,
        .enable_skill_commands = config.enable_skill_commands,
    };
    try out.env_files.appendSlice(a, config.env_files);
    var positional: std.ArrayList([]const u8) = .empty;
    var explicit_env = false;
    var explicit_mcp = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return error.Help;
        if (std.mem.eql(u8, arg, "--list-models")) {
            out.list_models = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--print") or std.mem.eql(u8, arg, "-p")) {
            out.print = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--interactive")) {
            out.interactive = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-session")) {
            out.no_session = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "-c")) {
            out.continue_session = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--resume") or std.mem.eql(u8, arg, "-r")) {
            // Keep the previous explicit-path spelling. Other positional text is a prompt.
            if (std.mem.eql(u8, arg, "--resume") and i + 1 < args.len and resumePathAlias(args[i + 1])) {
                i += 1;
                out.session = args[i];
            } else out.resume_picker = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--continue-queue")) {
            out.continue_queue = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--continue-turn")) {
            out.continue_turn = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--reset-context")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            i += 1;
            out.reset_context = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--request-id") or std.mem.eql(u8, arg, "--receipt")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            i += 1;
            if (std.mem.eql(u8, arg, "--request-id")) out.request_id = args[i] else out.receipt_id = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--receipt-json")) {
            out.receipt_json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--inspect") or std.mem.eql(u8, arg, "--watch")) {
            if (out.view != null) return error.ConflictingViewOptions;
            out.view = if (std.mem.eql(u8, arg, "--inspect")) .inspect else .watch;
            continue;
        }
        if (std.mem.eql(u8, arg, "--view-conversation")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            i += 1;
            out.view_conversation = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--fork") or std.mem.eql(u8, arg, "--conversation")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            i += 1;
            if (args[i].len == 0) return error.MissingArgument;
            if (std.mem.eql(u8, arg, "--fork")) out.fork_at = args[i] else out.conversation = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--compact")) {
            out.compact = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-env")) {
            out.no_env = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-config")) continue;
        if (std.mem.eql(u8, arg, "--config")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            i += 1;
            continue;
        }

        if (std.mem.eql(u8, arg, "--timings")) {
            out.timings = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--trace")) {
            out.trace = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--trace-file")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            i += 1;
            out.trace = true;
            out.trace_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-skills") or std.mem.eql(u8, arg, "-ns")) {
            out.no_skills = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-mcp")) {
            out.no_mcp = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-tools") or std.mem.eql(u8, arg, "-nt")) {
            out.tool_loadout.disabled = .all;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-builtin-tools") or std.mem.eql(u8, arg, "-nbt")) {
            if (out.tool_loadout.disabled != .all) out.tool_loadout.disabled = .builtin;
            continue;
        }
        if (std.mem.eql(u8, arg, "--mcp-project")) {
            out.mcp_project = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--mcp-config")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            i += 1;
            out.mcp = args[i];
            explicit_mcp = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--skill")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            i += 1;
            try out.skills.append(a, args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            for (args[i + 1 ..]) |text| try collectPositional(a, &out, &positional, text);
            break;
        }
        if (!std.mem.startsWith(u8, arg, "-")) {
            try collectPositional(a, &out, &positional, arg);
            continue;
        }
        if (i + 1 >= args.len) return error.MissingArgument;
        i += 1;
        const value = args[i];
        if (std.mem.eql(u8, arg, "--tui-mode")) {
            out.tui_mode = std.meta.stringToEnum(Settings.TuiMode, value) orelse return error.InvalidTuiMode;
            continue;
        }
        if (std.mem.eql(u8, arg, "--tools") or std.mem.eql(u8, arg, "-t")) {
            const entries = try ToolLoadout.split(a, value);
            try ToolLoadout.validateSelection(entries);
            out.tool_loadout.selection = entries;
            continue;
        }
        if (std.mem.eql(u8, arg, "--exclude-tools") or std.mem.eql(u8, arg, "-xt")) {
            out.tool_loadout.excluded = try ToolLoadout.split(a, value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--theme")) {
            try out.themes.append(a, value);
            continue;
        }
        if (std.mem.eql(u8, arg, "--env-file")) explicit_env = true;
        if (std.mem.eql(u8, arg, "--memory-bytes")) out.memory_bytes = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, arg, "--workspace")) out.workspace = value else if (std.mem.eql(u8, arg, "--session")) out.session = value else if (std.mem.eql(u8, arg, "--session-dir")) out.session_directory = value else if (std.mem.eql(u8, arg, "--prompt")) try out.prompts.append(a, value) else if (std.mem.eql(u8, arg, "--env-file")) try out.env_files.append(a, value) else if (std.mem.eql(u8, arg, "--model")) out.model = value else if (std.mem.eql(u8, arg, "--provider")) out.provider = value else if (std.mem.eql(u8, arg, "--model-registry")) out.model_registry = value else if (std.mem.eql(u8, arg, "--base-url")) out.base_url = value else if (std.mem.eql(u8, arg, "--reasoning-effort")) out.effort = value else if (std.mem.eql(u8, arg, "--thinking-levels")) out.thinking_levels = value else if (std.mem.eql(u8, arg, "--context-window")) out.context_window = try std.fmt.parseInt(u64, value, 10) else if (std.mem.eql(u8, arg, "--reserve-tokens")) out.reserve_tokens = try std.fmt.parseInt(u64, value, 10) else if (std.mem.eql(u8, arg, "--keep-recent-tokens")) out.keep_recent_tokens = try std.fmt.parseInt(u64, value, 10) else if (std.mem.eql(u8, arg, "--background-compaction-tokens")) out.background_compaction_tokens = try std.fmt.parseInt(u64, value, 10) else if (std.mem.eql(u8, arg, "--max-output-tokens")) out.max_output_tokens = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, arg, "--provider-retries")) out.provider_retries = try std.fmt.parseInt(u8, value, 10) else if (std.mem.eql(u8, arg, "--provider-retry-delay-ms")) out.provider_retry_delay_ms = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, arg, "--provider-retry-max-delay-ms")) out.provider_retry_max_delay_ms = try std.fmt.parseInt(u32, value, 10) else return error.UnknownArgument;
    }
    out.explicit_prompts = out.prompts.items.len != 0;
    if (out.files.items.len > 0) {
        try out.prompts.appendSlice(a, positional.items);
    } else if (positional.items.len > 0) try out.prompts.append(a, try std.mem.join(a, " ", positional.items));
    const prompt_count = if (out.prompts.items.len == 0 and out.files.items.len > 0) 1 else out.prompts.items.len;
    if (out.no_session and (out.session != null or out.continue_session or out.resume_picker)) return error.ConflictingSessionOptions;
    if (out.session != null and out.continue_session) return error.ConflictingSessionOptions;
    if (out.resume_picker and (out.session != null or out.continue_session or out.receipt_id != null or out.view != null or out.fork_at != null or out.conversation != null)) return error.ConflictingSessionOptions;
    if (out.no_env and explicit_env) return error.ConflictingEnvironmentOptions;
    if (out.no_mcp and explicit_mcp) return error.ConflictingMcpOptions;
    if (out.no_env) out.env_files.clearRetainingCapacity();
    if (out.no_mcp) out.mcp = null;
    if (out.interactive and (out.print or out.compact or out.continue_turn or out.reset_context != null)) return error.ConflictingInteractionOptions;
    if (out.request_id != null and (prompt_count != 1 or out.interactive or out.no_session)) return error.RequestIdRequiresOneDurablePrompt;
    if (out.receipt_json and out.receipt_id == null) return error.ReceiptJsonRequiresReceipt;
    if (out.receipt_id != null and (prompt_count != 0 or out.interactive or out.compact or out.no_session or out.continue_queue or out.continue_turn or out.reset_context != null))
        return error.ConflictingReceiptOptions;
    if (out.fork_at != null and (prompt_count != 0 or out.receipt_id != null or out.print or out.list_models or out.compact))
        return error.ConflictingForkOptions;
    if (out.fork_at != null or out.conversation != null) {
        if (out.session == null and !out.continue_session) return error.ConversationRequiresSession;
        if (out.interactive or out.continue_turn or out.continue_queue or out.reset_context != null or out.list_models)
            return error.ConflictingConversationOptions;
    }
    if (out.view_conversation != null and out.view == null) return error.ConversationRequiresView;
    if (out.view != null) {
        if (out.session == null and !out.continue_session) return error.ViewRequiresSession;
        if (prompt_count != 0 or out.receipt_id != null or out.interactive or out.print or out.list_models or
            out.compact or out.continue_queue or out.continue_turn or out.reset_context != null or out.trace or
            out.fork_at != null or (out.conversation != null and out.view_conversation != null))
            return error.ConflictingViewOptions;
    }
    return out;
}

fn collectPositional(a: std.mem.Allocator, out: *Options, prompts: *std.ArrayList([]const u8), argument: []const u8) !void {
    if (std.mem.startsWith(u8, argument, "@")) {
        try out.files.append(a, argument[1..]);
    } else {
        try prompts.append(a, argument);
    }
}

fn looksLikeSessionPath(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "/\\") != null or std.mem.endsWith(u8, value, ".jsonl") or Controller.isSessionName(value);
}

fn resumePathAlias(value: []const u8) bool {
    return !std.mem.startsWith(u8, value, "-") and looksLikeSessionPath(value) and
        (std.fs.path.isAbsolute(value) or std.mem.indexOfAny(u8, value, " \t\r\n") == null);
}

fn takesValue(arg: []const u8) bool {
    if (std.mem.eql(u8, arg, "--request-id") or std.mem.eql(u8, arg, "--receipt") or
        std.mem.eql(u8, arg, "--reset-context") or std.mem.eql(u8, arg, "--view-conversation") or
        std.mem.eql(u8, arg, "--fork") or std.mem.eql(u8, arg, "--conversation") or std.mem.eql(u8, arg, "--tui-mode") or
        std.mem.eql(u8, arg, "--theme") or std.mem.eql(u8, arg, "--tools") or std.mem.eql(u8, arg, "-t") or
        std.mem.eql(u8, arg, "--exclude-tools") or std.mem.eql(u8, arg, "-xt")) return true;
    inline for (.{ "--config", "--memory-bytes", "--workspace", "--session", "--session-dir", "--prompt", "--env-file", "--skill", "--mcp-config", "--model", "--provider", "--model-registry", "--base-url", "--reasoning-effort", "--thinking-levels", "--context-window", "--reserve-tokens", "--keep-recent-tokens", "--background-compaction-tokens", "--max-output-tokens", "--provider-retries", "--provider-retry-delay-ms", "--provider-retry-max-delay-ms", "--trace-file" }) |name| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

fn helpRequested(args: []const []const u8) bool {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) break;
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) return true;
        if (takesValue(args[i])) i += 1;
    }
    return false;
}

const ConfigSelection = struct {
    path: ?[]const u8,
    required: bool = false,
};

fn configSelection(a: std.mem.Allocator, args: []const []const u8, env: *const std.process.Environ.Map) !ConfigSelection {
    var explicit: ?[]const u8 = null;
    var disabled = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) break;
        if (std.mem.eql(u8, args[i], "--no-config")) disabled = true else if (std.mem.eql(u8, args[i], "--config")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            i += 1;
            explicit = args[i];
        } else if (takesValue(args[i])) {
            if (i + 1 >= args.len) return error.MissingArgument;
            i += 1;
        }
    }
    if (disabled) {
        if (explicit != null) return error.ConflictingConfigOptions;
        return .{ .path = null };
    }
    if (explicit) |path| return .{ .path = path, .required = true };
    const paths = try Paths.init(a, env);
    return .{ .path = try paths.configPath() };
}

fn loadRegistry(a: std.mem.Allocator, io: std.Io, paths: Paths, configured: ?[]const u8, size_warnings: registry.SizeSink) !registry.Registry {
    if (configured) |path| return registry.Registry.loadObserved(a, io, path, size_warnings);
    const user_path = try paths.modelsPath();
    if (registry.Registry.loadObserved(a, io, user_path, size_warnings)) |catalog| return catalog else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const executable_dir = try std.process.executableDirPathAlloc(io, a);
    defer a.free(executable_dir);
    const installed_path = try std.fs.path.resolve(a, &.{ executable_dir, "..", "share", "cpi", "models.lua" });
    defer a.free(installed_path);
    return registry.Registry.loadObserved(a, io, installed_path, size_warnings) catch |err| {
        std.debug.print("Cannot load model registry {s}: {s}. Use --model-registry PATH or CPI_MODEL_REGISTRY.\n", .{ installed_path, @errorName(err) });
        return err;
    };
}

fn retrySetting(comptime T: type, explicit: ?T, environ: *const std.process.Environ.Map, name: []const u8, fallback: T) !T {
    if (explicit) |value| return value;
    const text = environ.get(name) orelse return fallback;
    return std.fmt.parseInt(T, text, 10) catch error.InvalidRetryPolicy;
}

fn latest(a: std.mem.Allocator, io: std.Io, directory: []const u8) !?[]const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    var last: ?[]const u8 = null;
    var time: i128 = std.math.minInt(i128);
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !Controller.isSessionName(entry.name)) continue;
        const stat = try dir.statFile(io, entry.name, .{});
        if (stat.mtime.nanoseconds > time) {
            time = stat.mtime.nanoseconds;
            last = try std.fs.path.join(a, &.{ directory, entry.name });
        }
    }
    return last;
}

fn confirmForeignSession(a: std.mem.Allocator, io: std.Io, workspace: []const u8) !bool {
    const location = try ui.cleanText(a, workspace);
    const question = try std.fmt.allocPrint(a, "Session found in different project: {s}\nFork this session into current directory? [y/N] ", .{location});
    try std.Io.File.stdout().writeStreamingAll(io, question);
    var storage: [256]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &storage);
    const raw = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => null,
        else => return err,
    };
    const answer = if (raw) |line| std.mem.trimEnd(u8, line, "\r") else "";
    if (std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes")) return true;
    try std.Io.File.stdout().writeStreamingAll(io, "Aborted.\n");
    return false;
}

fn forkStartupSession(a: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, journal: *@import("agent").PreparedJournal, workspace: []const u8, directory: []const u8) ![]const u8 {
    var fork = try Controller.forkSessionArchive(a, gpa, io, journal, workspace, directory);
    defer fork.deinit();
    journal.deinit();
    journal.* = fork.recovered.?;
    fork.recovered = null;
    return fork.path.?;
}

const Printer = struct {
    io: std.Io,
    a: std.mem.Allocator,
    fn emit(raw: ?*anyopaque, event: Controller.Event) !void {
        const self: *Printer = @ptrCast(@alignCast(raw.?));
        switch (event.kind) {
            .assistant => {
                const stdout = std.Io.File.stdout();
                var wrote = false;
                var blocks = event.reply.iterator();
                while (blocks.next()) |block| {
                    if (block.kind != .prose) continue;
                    try stdout.writeStreamingAll(self.io, block.text);
                    wrote = true;
                }
                if (wrote) try stdout.writeStreamingAll(self.io, "\n");
            },
            .notice, .provider_retry, .size_warning => {
                const text = try ui.cleanText(self.a, event.text);
                defer self.a.free(text);
                std.debug.print("{s}\n", .{text});
            },
            .compacted => std.debug.print("Compacted. Context estimate {d} tokens.\n", .{event.tokens}),
            else => {},
        }
    }
};

fn sessionView(gpa: std.mem.Allocator, io: std.Io, path: []const u8, conversation: ?[]const u8, follow: bool) !void {
    const agent = @import("agent");
    var viewer = try Controller.openSessionView(gpa, io, path);
    defer viewer.deinit();
    var query: agent.SessionView.Query = .{ .session = .{} };
    if (conversation) |id| query.session.id = id;
    var watch = viewer.watch(query);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &buffer);
    while (true) {
        var snapshot = if (follow) try watch.next(gpa) else try viewer.snapshot(gpa, query);
        defer snapshot.deinit();
        try agent.session_protocol.json.write(gpa, &output.interface, snapshot.value);
        try output.interface.writeByte('\n');
        try output.interface.flush();
        if (!follow) break;
    }
}

pub fn main(init: std.process.Init) !void {
    const started = kit.timing.Timestamp.now();
    const agent = @import("agent");
    var backing: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{ .stack_trace_frames = 16 });
    defer if (builtin.mode == .debug) {
        _ = backing.deinit();
    };
    const heap = if (builtin.mode == .debug) backing.allocator() else std.heap.smp_allocator;
    const budget = try agent.MemoryBudget.createAdvisory(heap, agent.default_memory_bytes);
    defer budget.release();
    const gpa = budget.allocator();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var startup_warnings: Controller.StartupSizeWarnings = .{ .allocator = a, .operation = "startup" };
    defer startup_warnings.log();
    const args = try init.minimal.args.toSlice(a);
    if (builtin.os.tag == .linux and args.len == 3 and std.mem.eql(u8, args[1], ClipboardX11.argument)) {
        const mode = std.meta.stringToEnum(ClipboardX11.Mode, args[2]) orelse return error.InvalidClipboardMode;
        return ClipboardX11.run(gpa, init.io, mode);
    }
    if (helpRequested(args)) {
        usage();
        return;
    }
    const selection = try configSelection(a, args, init.environ_map);
    const user_config = if (selection.path) |path| try Config.load(a, init.io, path, selection.required, startup_warnings.sink()) else Config{};
    const opt = options(a, args, user_config) catch |err| switch (err) {
        error.Help => {
            usage();
            return;
        },
        else => {
            usage();
            return err;
        },
    };
    if (opt.memory_bytes) |bytes| try budget.configure(bytes);
    const root = agent.TaskJournal.main_conversation;
    const conversation = opt.conversation orelse root;
    const scoped = !std.mem.eql(u8, conversation, root);
    const context_command = opt.continue_turn or opt.reset_context != null;
    const stdin_tty = try std.Io.File.stdin().isTty(init.io);
    const tty = stdin_tty and (try std.Io.File.stdout().isTty(init.io));
    const implicit_composer = (opt.prompts.items.len == 0 and opt.files.items.len == 0) or (tty and !opt.explicit_prompts);
    const interactive = opt.interactive or (!opt.print and implicit_composer and !opt.compact and !context_command and
        opt.request_id == null and opt.receipt_id == null and opt.fork_at == null and opt.conversation == null);
    var args_scope = kit.tracing.begin("cpi.startup.args");
    _ = args_scope.end();
    var workspace_scope = kit.tracing.begin("cpi.startup.workspace");
    const invocation_workspace = try std.Io.Dir.cwd().realPathFileAlloc(init.io, opt.workspace, a);
    _ = workspace_scope.end();
    const paths = try Paths.init(a, init.environ_map);
    const session_root = try paths.sessionsPath();
    const local_directory = opt.session_directory orelse try WorkspaceSession.defaultDirectory(a, session_root, invocation_workspace);
    if (opt.view) |view| {
        const requested = opt.session orelse (try latest(a, init.io, local_directory) orelse return error.NoPreviousSession);
        const target = try Controller.writableSessionPath(a, init.io, requested);
        return sessionView(gpa, init.io, target, opt.view_conversation orelse opt.conversation, view == .watch);
    }
    const settings_path = try paths.configFile("settings.json");
    var presentation: UiPresentation.Launch = .{
        .a = gpa,
        .io = init.io,
        .environ = init.environ_map,
        .config_dir = std.fs.path.dirname(settings_path),
    };
    defer presentation.deinit();
    const theme_resources: Theme.Resources = .{ .directory = try paths.configFile("themes"), .explicit = opt.themes.items };
    var settings_error: ?anyerror = null;
    const saved_settings = Settings.load(a, init.io, settings_path) catch |err| blk: {
        settings_error = err;
        break :blk Settings.Loaded{};
    };
    var preferences = saved_settings.preferences.withTerminalDefaults(init.environ_map);
    if (opt.tui_mode) |mode| preferences.tui_mode = mode;
    const has_launch_files = opt.files.items.len != 0 and !opt.list_models;
    const launch_files: StartupFiles.Files = if (has_launch_files) try StartupFiles.load(a, gpa, init.io, .{
        .cwd = try std.process.currentPathAlloc(init.io, a),
        .home = paths.home,
        .hyperlinks = false,
    }, opt.files.items) else .{};
    const launch_stdin = if (has_launch_files and !stdin_tty) try StartupFiles.pipedText(a, init.io) else "";
    if (opt.request_id != null and opt.prompts.items.len == 0 and launch_files.text.len == 0 and launch_stdin.len == 0)
        return error.RequestIdRequiresOneDurablePrompt;
    const trace_path = if (opt.trace) try trace.init(init.io, a, opt.trace_path, local_directory) else null;
    defer if (trace_path) |out| {
        const summary = trace.finish(init.io, a, out);
        if (trace.format(a, summary) catch null) |text| {
            std.debug.print("{s}", .{text});
            a.free(text);
        }
    };
    var session_scope = kit.tracing.begin("cpi.startup.session");
    const session_source: SessionIndex.Source = .{
        .directory = local_directory,
        .root = if (opt.session_directory == null) session_root else null,
        .workspace = invocation_workspace,
        .current = null,
    };
    var picked: ?ui.StartupSelection = null;
    var fork_into_current = false;
    var path = opt.session;
    if (opt.resume_picker and !opt.list_models) {
        if (!tty) return error.SessionPickerRequiresTerminal;
        const display = try presentation.get();
        picked = try ui.selectStartupSession(a, gpa, init.io, init.environ_map, session_source, preferences.show_hardware_cursor orelse false, theme_resources, preferences.theme, &display.pickers);
        if (picked) |choice| {
            path = choice.session.path;
        } else {
            try std.Io.File.stdout().writeStreamingAll(init.io, "No session selected\n");
            return;
        }
    }
    if (opt.list_models) {
        path = null;
    } else {
        if (opt.session) |argument| if (!looksLikeSessionPath(argument) and opt.receipt_id == null and opt.conversation == null and opt.fork_at == null) {
            const existing_path = if (std.Io.Dir.cwd().statFile(init.io, argument, .{})) |_| true else |err| switch (err) {
                error.FileNotFound => false,
                else => return err,
            };
            if (!existing_path) {
                const match = (try SessionIndex.lookup(a, gpa, init.io, session_source, argument)) orelse {
                    std.debug.print("No session found matching '{s}'\n", .{argument});
                    return error.SessionNotFound;
                };
                picked = .{ .session = match.target, .workspace_known = match.workspace.len != 0 };
                path = match.target.path;
                fork_into_current = match.global;
            }
        };
        if (opt.continue_session or (path == null and opt.receipt_id != null)) {
            if (opt.continue_session and opt.receipt_id == null) {
                if (try SessionIndex.latestInWorkspace(a, gpa, init.io, session_source)) |target| {
                    picked = .{ .session = target, .workspace_known = true };
                    path = target.path;
                }
            } else path = try latest(a, init.io, local_directory);
            if (path == null and (opt.receipt_id != null or opt.fork_at != null or opt.conversation != null)) return error.NoPreviousSession;
        }
        if (path) |requested| path = try Controller.writableSessionPath(a, init.io, requested);
        if (path == null and !opt.no_session) path = try Controller.newSessionPath(a, init.io, local_directory);
    }
    _ = session_scope.end();
    if (opt.receipt_id) |id| {
        var buffer: [256]u8 = undefined;
        var writer = std.Io.File.stdout().writer(init.io, &buffer);
        if (opt.receipt_json) {
            const receipt = try Controller.readConversationRunReceipt(a, init.io, path.?, conversation, id);
            try std.json.Stringify.value(receipt, .{ .emit_null_optional_fields = false }, &writer.interface);
            try writer.interface.writeByte('\n');
        } else {
            const status = if (try Controller.readConversationInputReceipt(gpa, init.io, path.?, conversation, id)) |value| @tagName(value) else "unknown";
            try writer.interface.print("{s}\n", .{status});
        }
        try writer.interface.flush();
        return;
    }
    if (opt.fork_at != null or opt.conversation != null) {
        _ = try std.Io.Dir.cwd().statFile(init.io, path.?, .{});
    }
    var recovered_journal = if (path) |file| try Controller.prepareResume(gpa, init.io, file, Controller.codec) else null;
    defer if (recovered_journal) |*journal| journal.deinit();
    if (picked != null and recovered_journal == null) return error.JournalReplaced;
    var workspace: []const u8 = invocation_workspace;
    var saved_workspace: ?[]const u8 = null;
    var directory = local_directory;
    if (recovered_journal) |*journal| {
        if (picked) |choice| try journal.requireFile(choice.session.inode);
        if (fork_into_current) {
            const stored = try Controller.savedWorkspace(a, init.io, journal);
            const location = switch (stored) {
                .unknown => "(unknown)",
                .available, .missing => |saved| saved,
            };
            if (!try confirmForeignSession(a, init.io, location)) return;
            path = try forkStartupSession(a, gpa, init.io, journal, invocation_workspace, local_directory);
        } else switch (try Controller.savedWorkspace(a, init.io, journal)) {
            .unknown => if (picked != null and !picked.?.workspace_known) return error.UnknownSessionWorkspace,
            .available => |saved| {
                workspace = saved;
                if (opt.session_directory == null) directory = std.fs.path.dirname(try std.Io.Dir.cwd().realPathFileAlloc(init.io, path.?, a)) orelse local_directory;
            },
            .missing => |missing| {
                if (!interactive or !tty) {
                    std.debug.print("Stored session working directory does not exist: {s}\nSession file: {s}\nCurrent working directory: {s}\n", .{ missing, path.?, invocation_workspace });
                    return error.MissingSessionWorkspace;
                }
                const display = try presentation.get();
                switch (try ui.chooseStartupWorkspace(gpa, init.io, init.environ_map, missing, invocation_workspace, theme_resources, preferences.theme, &display.pickers.workspace)) {
                    .cancel => return,
                    .proceed => {
                        try journal.revalidateFile();
                        saved_workspace = missing;
                        if (opt.session_directory == null) directory = std.fs.path.dirname(try std.Io.Dir.cwd().realPathFileAlloc(init.io, path.?, a)) orelse local_directory;
                    },
                    .fork => {
                        path = try forkStartupSession(a, gpa, init.io, journal, invocation_workspace, local_directory);
                    },
                }
            },
        }
    }
    const files: []const dotenv.File = if (opt.no_env) &.{} else if (opt.env_files.items.len > 0) blk: {
        const list = try a.alloc(dotenv.File, opt.env_files.items.len);
        for (opt.env_files.items, 0..) |env_path, i| list[i] = .{ .path = env_path };
        break :blk list;
    } else &.{.{ .path = if (recovered_journal == null) ".env" else try std.fs.path.join(a, &.{ workspace, ".env" }), .required = false }};
    var dotenv_scope = kit.tracing.begin("cpi.startup.dotenv");
    const size_sink = startup_warnings.sink();
    var loaded = try dotenv.load(a, init.io, init.environ_map, .{
        .files = files,
        .size_warnings = .{ .context = size_sink.context, .notify = size_sink.notify },
    });
    _ = dotenv_scope.end();
    defer loaded.deinit();
    const route_override = opt.provider != null or opt.base_url != null;
    const registry_path = opt.model_registry orelse loaded.get("CPI_MODEL_REGISTRY");
    var models = blk: {
        const scope = kit.tracing.beginEvent("cpi.startup.registry");
        defer kit.tracing.endEvent(scope);
        break :blk try loadRegistry(gpa, init.io, paths, registry_path, startup_warnings.sink());
    };
    defer models.deinit();
    const preference = blk: {
        const scope = kit.tracing.beginEvent("cpi.resume.model_selection");
        defer kit.tracing.endEvent(scope);
        break :blk if (recovered_journal) |*session| try Controller.decodeSelection(a, try session.contextDocument(a, "model_selection")) else null;
    };
    const provider_id = opt.provider orelse loaded.get("CPI_PROVIDER");
    const selected = if (opt.list_models and provider_id == null) null else try registry.selection.environmentProvider(&models, &loaded, provider_id);
    var auth = try Auth.Store.init(a, init.io, init.environ_map, startup_warnings.sink());
    var credential_environment = std.process.Environ.Map.init(a);
    defer credential_environment.deinit();
    var credentials = loaded.iterator();
    while (credentials.next()) |entry| try credential_environment.put(entry.key_ptr.*, entry.value_ptr.*);
    auth.environment = &credential_environment;
    auth.environment_provider_id = if (selected) |entry| entry.id else null;
    auth.base_url_override = opt.base_url;
    if (opt.list_models) {
        var entries: std.ArrayList(registry.Provider) = .empty;
        const targets = try ModelRoutes.collect(a, &models, &auth, null, selected);
        if (targets.len == 0) {
            if (selected) |p| try entries.append(a, p.*) else try entries.appendSlice(a, models.providers());
        }
        for (targets) |target| {
            const discovery = target.discovery();
            const listing = try registry.discovery.discover(a, init.io, discovery.route, discovery.reference, startup_warnings.sink());
            if (listing.fallback_reason) |err| {
                std.log.warn("model discovery unavailable ({s}); using reference catalog", .{@errorName(err)});
            }
            var entry: registry.Provider = if (target.reference) |p| p.* else .{ .id = try std.fmt.allocPrint(a, "custom-{x}", .{std.hash.Wyhash.hash(0, target.record.base_url)}), .name = "Custom provider", .base_url = target.record.base_url, .api_key_env = "", .models = &.{} };
            entry.models = listing.models;
            entry.base_url = target.record.base_url;
            const base_id = entry.id;
            var suffix: usize = 1;
            while (true) {
                for (entries.items) |prior| {
                    if (std.mem.eql(u8, prior.id, entry.id)) break;
                } else break;
                suffix += 1;
                entry.id = try std.fmt.allocPrint(a, "{s}-{d}", .{ base_id, suffix });
            }
            try entries.append(a, entry);
        }
        const text = try std.json.Stringify.valueAlloc(a, registry.Config{ .version = 2, .providers = entries.items }, .{ .whitespace = .indent_2 });
        try std.Io.File.stdout().writeStreamingAll(init.io, text);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return;
    }
    var saved_route = false;
    var saved_credential: ?Auth.Record = null;
    if (loaded.get("OPENAI_API_KEY") == null and loaded.get("OPENAI_ACCESS_TOKEN") == null and loaded.get("CPI_PROVIDER") == null and opt.provider == null and selected == null) {
        if (auth.active()) |saved| {
            // An endpoint override alone does not authorize forwarding a saved
            // credential to a different origin.
            if (opt.base_url == null or ModelRoutes.sameEndpoint(opt.base_url.?, saved.base_url)) {
                saved_credential = saved;
                saved_route = true;
            }
        }
    }
    var provider_scope = kit.tracing.begin("cpi.startup.provider");
    const restoring = preference != null and !route_override;
    const provider = if (restoring) blk: {
        const saved = preference.?;
        if (try saved.resolve(a, &auth, &models, opt.model)) |resolved| {
            saved_route = saved.source == .saved;
            break :blk resolved;
        }
        break :blk try Controller.unconfiguredProvider(a);
    } else defaults: {
        const provider = try a.create(Controller.Provider);
        provider.* = if (saved_credential) |saved| blk: {
            var options_value = Auth.providerOptions(saved);
            options_value.model = opt.model orelse loaded.get(if (saved.kind == .deepseek) registry.selection.deepseek.model_env else "OPENAI_MODEL") orelse saved.model;
            options_value.base_url = opt.base_url orelse saved.base_url;
            if (saved.kind == .openai) options_value.transport = try Controller.Provider.environmentTransport(&loaded, .@"websocket-cached");
            break :blk try Controller.Provider.initOptions(a, options_value);
        } else if (selected) |entry| blk: {
            const base = ModelRoutes.selectedEndpoint(&auth, entry.*);
            const native_deepseek = std.mem.eql(u8, entry.id, registry.selection.deepseek.id);
            const saved_kind: Auth.Kind = if (native_deepseek) .deepseek else if (std.mem.eql(u8, entry.id, "openai-codex")) .openai else .compatible;
            const saved = if (auth.find(saved_kind)) |record| (if (ModelRoutes.sameEndpoint(record.base_url, base)) record else null) else null;
            const name = registry.selection.providerModel(entry, &loaded, opt.model, if (saved) |record| record.model else null) orelse {
                if (interactive) break :defaults try Controller.unconfiguredProvider(a);
                return error.MissingModel;
            };
            const environment_key = loaded.get(entry.api_key_env);
            const key = environment_key orelse (if (saved) |record| record.token else {
                if (interactive) break :defaults try Controller.unconfiguredProvider(a);
                return error.MissingCredential;
            });
            if (environment_key == null) saved_route = true;
            const model_entry = entry.find(name);
            const subscription = saved_kind == .openai or (if (model_entry) |known| !known.supports("openai-responses") and known.supports("openai-codex-responses") else false);
            if (model_entry) |known| {
                if (!known.supports(if (subscription) "openai-codex-responses" else "openai-responses")) return error.UnsupportedRegistryApi;
            }
            break :blk try Controller.Provider.initOptions(a, .{
                .kind = if (native_deepseek) .deepseek else if (subscription) .openai_subscription else .compatible,
                .model = name,
                .base_url = base,
                .api_key = key,
                .protocol = if (subscription) .codex else .responses,
                .transport = if (native_deepseek) .http else try Controller.Provider.environmentTransport(&loaded, if (subscription) .@"websocket-cached" else .http),
                .account_id = if (environment_key != null) loaded.get("CHATGPT_ACCOUNT_ID") else if (saved) |record| record.account_id else null,
            });
        } else blk: {
            if (opt.model) |name| try loaded.put("OPENAI_MODEL", name);
            if (opt.base_url) |url| try loaded.put("OPENAI_BASE_URL", url);
            break :blk Controller.Provider.initWithCodexTransportDefault(a, &loaded, .@"websocket-cached") catch |err| switch (err) {
                error.MissingCredential, error.MissingModel, error.MissingAccountId => if (interactive)
                    try Controller.Provider.initOptions(a, .{ .base_url = "http://127.0.0.1:1/v1", .model = "unconfigured", .api_key = "unconfigured" })
                else
                    return err,
                else => return err,
            };
        };
        break :defaults provider;
    };
    if (provider.kind == .compatible and provider.transport == .http) {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, provider.base_url, "/"), registry.selection.deepseek.base_url)) provider.kind = .deepseek;
    }
    const unavailable = if (restoring and std.mem.eql(u8, provider.api_key, "unconfigured")) preference else null;
    const metadata_provider = if (unavailable) |missing|
        if (missing.provider_ref) |id| models.find(id) else models.matchEndpoint(missing.base_url, missing.model)
    else
        (if (restoring) null else selected) orelse (if (provider.kind == .deepseek) models.find(registry.selection.deepseek.id) else models.matchEndpoint(provider.base_url, provider.model));
    const metadata = if (metadata_provider) |entry| entry.find(if (unavailable) |missing| missing.model else provider.model) else null;
    const limits = registry.selection.limits(metadata, .{ .context_window = opt.context_window, .max_output_tokens = opt.max_output_tokens }, .{});
    auth.configured = !std.mem.eql(u8, provider.api_key, "unconfigured");
    if (auth.configured and !saved_route) auth.environment_route = try Auth.cloneRecord(a, .{
        .kind = Auth.kindFor(provider),
        .base_url = provider.base_url,
        .model = provider.model,
        .token = provider.api_key,
        .account_id = provider.account_id,
    });
    _ = provider_scope.end();
    const retries = try retrySetting(u8, opt.provider_retries, &loaded, "CPI_PROVIDER_RETRIES", 7);
    const native_retries: u8 = @min(retries, 7);
    const retry: Controller.Retry = .{
        .max_attempts = native_retries + 1,
        .initial_delay_ms = try retrySetting(u32, opt.provider_retry_delay_ms, &loaded, "CPI_PROVIDER_RETRY_DELAY_MS", 500),
        .max_delay_ms = try retrySetting(u32, opt.provider_retry_max_delay_ms, &loaded, "CPI_PROVIDER_RETRY_MAX_DELAY_MS", 30000),
    };
    try retry.validate();
    if (!interactive) if (settings_error) |err| std.log.warn("Failed to load settings: {s}", .{@errorName(err)});
    const run_defaults: Controller.RunPolicy = .{ .queue = .{
        .follow_up = if (loaded.get("CPI_FOLLOW_UP_MODE")) |mode|
            if (std.mem.eql(u8, mode, "one-at-a-time")) .one_at_a_time else if (std.mem.eql(u8, mode, "all")) .all else return error.InvalidFollowUpMode
        else
            .one_at_a_time,
    } };
    var codex_sessions: agent.provider.CodexSessions = .{ .allocator = gpa, .io = init.io };
    defer codex_sessions.deinit();
    const configured_transport = if (loaded.get("OPENAI_TRANSPORT")) |name|
        std.meta.stringToEnum(agent.provider.Transport, name)
    else
        null;
    const codex_transport_override = if (configured_transport) |value| Controller.CodexTransportPreference.fromTransport(value) else null;
    var codex_transport_preference = std.atomic.Value(Controller.CodexTransportPreference).init(codex_transport_override orelse preferences.codexTransportPreference());
    const launch_settings: Controller.Settings = .{
        .workspace = workspace,
        .saved_workspace = saved_workspace,
        .session_directory = directory,
        .session_root = if (opt.session_directory == null) session_root else null,
        .session_path = path,
        .context_window = limits.context_window,
        .reserve_tokens = opt.reserve_tokens,
        .keep_recent_tokens = opt.keep_recent_tokens,
        .background_compaction_tokens = opt.background_compaction_tokens,
        .max_output_tokens = limits.max_output_tokens,
        .registry_provider = metadata_provider,
        .registry = &models,
        .strict_registry = selected != null and !restoring,
        .registry_context = opt.context_window == null,
        .registry_output = opt.max_output_tokens == null,
        .reasoning_effort = opt.effort,
        .thinking_levels = opt.thinking_levels,
        .user_skill_paths = user_config.skills,
        .skill_paths = opt.skills.items,
        .no_skills = opt.no_skills,
        .enable_skill_commands = opt.enable_skill_commands,
        .mcp_config = opt.mcp,
        .no_mcp = opt.no_mcp,
        .tool_loadout = opt.tool_loadout,
        .default_tools = saved_settings.default_tools,
        .mcp_project = opt.mcp_project,
        .provider_retry = retry,
        .fresh_retry_limit = if (opt.provider_retries != null or loaded.get("CPI_PROVIDER_RETRIES") != null) retries else null,
        .after_failed_run = if (loaded.get("CPI_AFTER_FAILED_RUN")) |policy|
            std.meta.stringToEnum(Controller.AfterFailedRun, policy) orelse return error.InvalidAfterFailedRun
        else
            .keep,
        .run_policy = preferences.runPolicy(run_defaults),
        .codex_sessions = &codex_sessions,
        .image_processing = true,
        .codex_transport_preference = &codex_transport_preference,
        .codex_transport_pinned = codex_transport_override != null,
        .auth_path = auth.path,
        .auth_legacy_path = auth.legacy_path,
        .refresh_saved_auth = saved_route,
        .auth_store = &auth,
        .startup_size_warnings = startup_warnings.values.items,
        .model_override = opt.model,
        .route_override = route_override,
        .launch_effort = opt.effort,
        .batch_conversation = if (scoped and opt.fork_at == null) conversation else null,
        .task_settings = .{ .start_paused = scoped or opt.fork_at != null },
    };
    const controller = blk: {
        var scope = kit.tracing.begin("cpi.controller.create");
        defer _ = scope.end();
        break :blk try Controller.create(a, gpa, init.io, launch_settings, provider, init.environ_map, .{ .previous = preference, .prepared = if (recovered_journal) |*opened| opened else null });
    };
    var runtime: WorkspaceSession = .{ .current = controller, .launch = launch_settings, .environment = init.environ_map };
    defer runtime.deinit();
    startup_warnings.values.clearRetainingCapacity();
    auth.size_warnings = controller.authSizeSink();
    if (opt.fork_at) |anchor| {
        const id = try controller.forkConversation(a, conversation, anchor);
        var buffer: [128]u8 = undefined;
        var writer = std.Io.File.stdout().writer(init.io, &buffer);
        try writer.interface.print("{s}\n", .{id});
        try writer.interface.flush();
        return;
    }
    if (opt.continue_queue) try controller.resumeQueue();
    const initial: StartupFiles.Inputs = .{ .prompts = opt.prompts.items, .files = launch_files, .stdin_text = launch_stdin };
    if (!interactive) {
        var printer: Printer = .{ .io = init.io, .a = std.heap.smp_allocator };
        controller.setSink(.{ .context = &printer, .emit = Printer.emit });
        defer controller.setSink(null);
        try controller.reportSkills();
        const submissions = try initial.prepare(a, controller, if (scoped) conversation else null);
        if (scoped) {
            var inputs = submissions;
            if (opt.print and inputs.len == 0 and !has_launch_files) {
                var buffer: [4096]u8 = undefined;
                var reader = std.Io.File.stdin().reader(init.io, &buffer);
                const text = try reader.interface.allocRemaining(a, .unlimited);
                if (text.len != 0) {
                    inputs = try a.alloc(Controller.Prepared, 1);
                    inputs[0] = try controller.prepare(a, text);
                }
            }
            try controller.runConversationBatch(conversation, inputs, opt.request_id);
            if (opt.compact) try controller.compactQueued(try controller.enqueueConversationCompaction(a, conversation, ""));
            return controller.waitManualCompactions(conversation);
        }
        if (opt.reset_context) |note| {
            _ = try controller.enqueueReset(a, note);
            try controller.resumeInterrupted();
        }
        if (opt.continue_turn) try controller.continueTurn();
        try controller.submitBatchPrompts(submissions, opt.request_id);
        try controller.resumeInterrupted();
        const paused = try controller.queuePaused();
        if (!paused) while (true) {
            var pending: std.heap.ArenaAllocator = .init(gpa);
            defer pending.deinit();
            const inputs = try controller.pendingInputs(pending.allocator());
            const index = Controller.Prepared.firstReady(inputs) orelse break;
            try controller.runPrepared(inputs[index]);
        };
        if (opt.print and submissions.len == 0 and !has_launch_files and !opt.compact and !context_command) {
            var buffer: [4096]u8 = undefined;
            var reader = std.Io.File.stdin().reader(init.io, &buffer);
            const text = try reader.interface.allocRemaining(a, .unlimited);
            if (text.len > 0) {
                if (paused) {
                    var pending = [1]Controller.Prepared{try controller.prepare(a, text)};
                    try controller.enqueueInputs(a, &pending);
                } else try controller.run(text);
            }
        }
        if (paused and (try controller.pendingInputs(a)).len != 0) std.debug.print("Queue paused. Use --continue-queue or /queue continue to run pending inputs.\n", .{});
        if (opt.compact) try controller.compact("");
        try controller.waitManualCompactions(conversation);
        return;
    }
    var ui_scope = kit.tracing.begin("cpi.ui.run");
    defer _ = ui_scope.end();
    const timings = if (opt.timings) blk: {
        const stats = try a.create(ui.Timings);
        stats.* = .{ .started = started };
        break :blk stats;
    } else null;
    defer if (timings) |stats| stats.report();
    const display = try presentation.get();
    try ui.run(gpa, init.io, init.environ_map, &runtime, &auth, initial, .{
        .presentation = display,
        .presentation_warning = presentation.warning,
        .timings = timings,
        .external_editor = user_config.external_editor,
        .quiet_startup = user_config.quiet_startup,
        .settings_path = settings_path,
        .theme_resources = theme_resources,
        .preferences = preferences,
        .settings_error = settings_error,
        .run_defaults = run_defaults,
    });
    if (runtime.current.session.leaf != null) {
        if (runtime.current.session.path) |session_path| {
            const output = std.Io.File.stdout();
            const message = if (try output.isTty(init.io)) blk: {
                const quoted = try std.mem.replaceOwned(u8, a, session_path, "'", "'\"'\"'");
                break :blk try std.fmt.allocPrint(a, "To resume this session:\ncpi-minimal --session '{s}'\n", .{quoted});
            } else try std.fmt.allocPrint(a, "Session: {s}\n", .{session_path});
            try output.writeStreamingAll(init.io, message);
        }
    }
}
