const std = @import("std");
const paths = @import("skills/skill_paths.zig");
const frontmatter = @import("skills/frontmatter.zig");
const Self = @This();
const A = std.mem.Allocator;

pub const Diagnostic = paths.Diagnostic;
pub const Options = paths.Options;
pub const Scope = paths.Scope;
pub const Source = paths.Source;
pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    file_path: []const u8,
    base_dir: []const u8,
    source: Source,
    disable_model_invocation: bool,
};
pub const Prepared = struct { text: []const u8, original: []const u8 };
pub const Expansion = struct { input: Prepared, diagnostic: ?Diagnostic = null };

arena: std.heap.ArenaAllocator,
skills: []const Skill,
by_name: std.StringHashMapUnmanaged(usize),
diagnostics: []const Diagnostic,
enable_commands: bool,

pub fn load(gpa: A, io: std.Io, options: Options) !Self {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const discovered = try paths.discover(a, io, options);
    var skills: std.ArrayList(Skill) = .empty;
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    try diagnostics.appendSlice(a, discovered.diagnostics);
    var names: std.StringHashMapUnmanaged(usize) = .empty;
    for (discovered.resources) |resource| {
        const path = resource.path;
        var temporary = std.heap.ArenaAllocator.init(gpa);
        defer temporary.deinit();
        const scratch = temporary.allocator();
        const declared = std.mem.eql(u8, std.fs.path.basename(path), "SKILL.md");
        const raw = std.Io.Dir.cwd().readFileAlloc(io, path, scratch, .unlimited) catch |err| {
            if (err == error.OutOfMemory) return err;
            try diagnostics.append(a, .{ .kind = .warning, .path = path, .message = try std.fmt.allocPrint(a, "failed to read skill file: {s}", .{@errorName(err)}) });
            continue;
        };
        const parsed = frontmatter.parse(scratch, raw) catch |err| {
            if (err == error.OutOfMemory) return err;
            if (declared) try diagnostics.append(a, .{ .kind = .warning, .path = path, .message = "failed to parse skill file: invalid YAML" });
            continue;
        };
        const description = parsed.description orelse "";
        const has_description = trim(description).len > 0;
        if (!declared and !has_description) continue;
        if (!has_description) {
            try diagnostics.append(a, .{ .kind = .warning, .path = path, .message = "description is required" });
        } else if (length(description) > 1024) {
            try diagnostics.append(a, .{ .kind = .warning, .path = path, .message = try std.fmt.allocPrint(a, "description exceeds 1024 characters ({d})", .{length(description)}) });
        }
        const base_dir = std.fs.path.dirname(path) orelse ".";
        const name = if (parsed.name) |name| if (name.len > 0) name else std.fs.path.basename(base_dir) else std.fs.path.basename(base_dir);
        if (!std.unicode.utf8ValidateSlice(name)) {
            try diagnostics.append(a, .{ .kind = .warning, .path = path, .message = "name contains invalid characters (must be lowercase a-z, 0-9, hyphens only)" });
            continue;
        }
        if (length(name) > 64) try diagnostics.append(a, .{ .kind = .warning, .path = path, .message = try std.fmt.allocPrint(a, "name exceeds 64 characters ({d})", .{length(name)}) });
        var valid = name.len > 0;
        for (name) |byte| if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-')) {
            valid = false;
        };
        if (!valid) try diagnostics.append(a, .{ .kind = .warning, .path = path, .message = "name contains invalid characters (must be lowercase a-z, 0-9, hyphens only)" });
        if (std.mem.startsWith(u8, name, "-") or std.mem.endsWith(u8, name, "-")) try diagnostics.append(a, .{ .kind = .warning, .path = path, .message = "name must not start or end with a hyphen" });
        if (std.mem.indexOf(u8, name, "--") != null) try diagnostics.append(a, .{ .kind = .warning, .path = path, .message = "name must not contain consecutive hyphens" });
        if (!has_description) continue;
        if (names.get(name)) |index| {
            try diagnostics.append(a, .{
                .kind = .{ .collision = skills.items[index].name },
                .path = path,
                .message = try std.fmt.allocPrint(a, "name \"{s}\" collision", .{name}),
            });
            continue;
        }
        const owned_name = try a.dupe(u8, name);
        const owned_description = try a.dupe(u8, description);
        try names.put(a, owned_name, skills.items.len);
        try skills.append(a, .{
            .name = owned_name,
            .description = owned_description,
            .file_path = path,
            .base_dir = base_dir,
            .source = resource.source,
            .disable_model_invocation = parsed.disable_model_invocation,
        });
    }
    var ordered: std.ArrayList(Diagnostic) = .empty;
    for (diagnostics.items) |item| if (item.kind != .collision) try ordered.append(a, item);
    for (diagnostics.items) |item| if (item.kind == .collision) try ordered.append(a, item);
    return .{ .arena = arena, .skills = skills.items, .by_name = names, .diagnostics = ordered.items, .enable_commands = discovered.enable_skill_commands };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

pub fn find(self: *const Self, name: []const u8) ?*const Skill {
    const index = self.by_name.get(name) orelse return null;
    return &self.skills[index];
}

pub fn prompt(self: *const Self, a: A, reader: ?@import("tools.zig").ToolLoadout.Reader) ![]const u8 {
    const tool = reader orelse return "";
    var out: std.Io.Writer.Allocating = .init(a);
    for (self.skills) |skill| {
        if (skill.disable_model_invocation) continue;
        if (out.written().len == 0) try out.writer.print(
            "The following skills provide specialized instructions for specific tasks.\n" ++
                "Use the {s} tool to load a skill's file when the task matches its description.\n" ++
                "Resolve relative paths against the skill's directory (parent of SKILL.md). Use absolute paths in tool calls.\n\n<available_skills>\n",
            .{@tagName(tool)},
        );
        try out.writer.writeAll("  <skill>\n    <name>");
        try xml(&out.writer, skill.name);
        try out.writer.writeAll("</name>\n    <description>");
        try xml(&out.writer, skill.description);
        try out.writer.writeAll("</description>\n    <location>");
        try xml(&out.writer, skill.file_path);
        try out.writer.writeAll("</location>\n  </skill>\n");
    }
    if (out.written().len > 0) try out.writer.writeAll("</available_skills>");
    return out.toOwnedSlice();
}

pub fn expand(self: *const Self, a: A, io: std.Io, text: []const u8) !Expansion {
    const unchanged: Expansion = .{ .input = .{ .text = text, .original = text } };
    if (!std.mem.startsWith(u8, text, "/skill:")) return unchanged;
    const end = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
    const skill = self.find(text[7..end]) orelse return unchanged;
    const raw = std.Io.Dir.cwd().readFileAlloc(io, skill.file_path, a, .unlimited) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .input = unchanged.input, .diagnostic = .{ .kind = .warning, .path = skill.file_path, .message = try std.fmt.allocPrint(a, "skill_expansion: {s}", .{@errorName(err)}) } };
    };
    const parsed = frontmatter.parse(a, raw) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .input = unchanged.input, .diagnostic = .{ .kind = .warning, .path = skill.file_path, .message = "skill_expansion: invalid YAML" } };
    };
    const args = trim(text[end..]);
    const block = try std.fmt.allocPrint(a, "<skill name=\"{s}\" location=\"{s}\">\nReferences are relative to {s}.\n\n{s}\n</skill>", .{ skill.name, skill.file_path, skill.base_dir, trim(parsed.body) });
    return .{ .input = .{ .text = if (args.len > 0) try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ block, args }) else block, .original = text } };
}

fn xml(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| try writer.writeAll(switch (byte) {
        '&' => "&amp;",
        '<' => "&lt;",
        '>' => "&gt;",
        '"' => "&quot;",
        '\'' => "&apos;",
        else => &.{byte},
    });
}

fn length(text: []const u8) usize {
    var count: usize = 0;
    var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (iterator.nextCodepoint()) |cp| count += if (cp > 0xffff) @as(usize, 2) else 1;
    return count;
}

fn whitespace(cp: u21) bool {
    return switch (cp) {
        9...13, 32, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff => true,
        else => false,
    };
}

fn trim(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len) {
        const size = std.unicode.utf8ByteSequenceLength(text[start]) catch break;
        if (start + size > text.len) break;
        const cp = std.unicode.utf8Decode(text[start..][0..size]) catch break;
        if (!whitespace(cp)) break;
        start += size;
    }
    var end = text.len;
    while (end > start) {
        var at = end - 1;
        while (at > start and text[at] & 0xc0 == 0x80) at -= 1;
        const cp = std.unicode.utf8Decode(text[at..end]) catch break;
        if (!whitespace(cp)) break;
        end = at;
    }
    return text[start..end];
}

pub const Block = struct { name: []const u8, location: []const u8, content: []const u8, user_message: ?[]const u8 };

pub fn parseBlock(text: []const u8) ?Block {
    const prefix = "<skill name=\"";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    const name_end = std.mem.indexOfScalarPos(u8, text, prefix.len, '"') orelse return null;
    if (name_end == prefix.len) return null;
    const location_prefix = "\" location=\"";
    if (!std.mem.startsWith(u8, text[name_end..], location_prefix)) return null;
    const location_start = name_end + location_prefix.len;
    const location_end = std.mem.indexOfScalarPos(u8, text, location_start, '"') orelse return null;
    if (location_end == location_start or !std.mem.startsWith(u8, text[location_end..], "\">\n")) return null;
    const content_start = location_end + 3;
    const end = std.mem.indexOfPos(u8, text, content_start, "\n</skill>") orelse return null;
    const suffix = text[end + "\n</skill>".len ..];
    const user_message = if (suffix.len == 0 or std.mem.eql(u8, suffix, "\n")) null else if (std.mem.startsWith(u8, suffix, "\n\n") and suffix.len > 2) suffix[2..] else return null;
    return .{ .name = text[prefix.len..name_end], .location = text[location_start..location_end], .content = text[content_start..end], .user_message = user_message };
}
