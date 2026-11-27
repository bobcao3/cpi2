const std = @import("std");
const agent = @import("agent");
const services = @import("services");
const coding_tools = @import("../../tools.zig").builtins;
const j = @import("../../json.zig");
const UiWake = @import("../UiWake.zig");
const Self = @This();
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Body = union(enum) { diff: []const u8, failure: []const u8 };

arena: std.heap.ArenaAllocator,
io: Io,
wake: *UiWake,
workspace: []const u8,
input: j.Value,
key: []const u8,
future: Io.Future(void) = undefined,
done: Io.Event = .unset,
body: ?Body = null,

fn editPair(args: j.Value) bool {
    return j.get(args, "oldText") == .string and j.get(args, "newText") == .string;
}

pub fn accepts(args: j.Value) bool {
    if (j.text(j.get(args, "path")).len == 0) return false;
    const edits = j.get(args, "edits");
    if (edits == .array and edits.array.items.len > 0) {
        for (edits.array.items) |edit| if (!editPair(edit)) return false;
        return true;
    }
    return editPair(edits) or editPair(args);
}

pub fn start(a: Allocator, io: Io, wake: *UiWake, workspace: []const u8, home: []const u8, args: j.Value, key: []const u8) !*Self {
    const self = try a.create(Self);
    errdefer a.destroy(self);
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const own = arena.allocator();
    const directory = try own.dupe(u8, workspace);
    const input = try j.value(own, .{ .workspace = directory, .home = home, .args = args });
    const owned_key = try own.dupe(u8, key);
    self.* = .{
        .arena = arena,
        .io = io,
        .wake = wake,
        .workspace = directory,
        .input = input,
        .key = owned_key,
    };
    self.future = try io.concurrent(run, .{self});
    return self;
}

pub fn destroy(self: *Self, a: Allocator) void {
    self.future.cancel(self.io);
    self.arena.deinit();
    a.destroy(self);
}

pub fn result(self: *const Self) ?Body {
    return if (self.done.isSet()) self.body else null;
}

fn run(self: *Self) void {
    self.body = self.compute() catch null;
    self.done.set(self.io);
    self.wake.notify();
}

fn compute(self: *Self) !?Body {
    var files: services.Files = .{ .workspace = self.workspace, .read_size_limit = services.Files.max_bytes };
    const controller = try agent.Controller.open(self.arena.child_allocator, self.io, .{
        .services = &.{.{ .context = &files, .operations = &.{ &services.Files.read_operation, &services.Files.normalize_operation } }},
        .program_grants = &.{ "files.read", "text.normalize_nfkc" },
        .authorize =
        \\return function(event)
        \\    return {allow=event.kind=='host' and (event.operation=='files.read' or event.operation=='text.normalize_nfkc')}
        \\end
        ,
    });
    defer controller.close();
    const request = try controller.program("edit-preview", coding_tools.edit_preview_source, self.input);
    defer request.deinit();
    var outcome = try request.wait(self.io);
    defer outcome.deinit();
    const a = self.arena.allocator();
    const failure = j.text(j.get(outcome.result, "errorText"));
    // Preview has a read ceiling and uses the controller program's bounded
    // result envelope for each host call. Either can leave the preview empty.
    if (std.mem.startsWith(u8, failure, "edit: host files.read failed: {\"code\":\"FileTooBig\"}") or
        std.mem.startsWith(u8, failure, "edit: Tool result text exceeds 128 KiB.")) return null;
    if (failure.len > 0) return .{ .failure = try a.dupe(u8, failure) };
    const diff = j.get(outcome.result, "diff");
    return if (diff == .string) .{ .diff = try a.dupe(u8, diff.string) } else null;
}
