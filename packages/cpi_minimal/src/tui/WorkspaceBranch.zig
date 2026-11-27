//! Read the live Git label for the configured workspace.
const std = @import("std");
const Self = @This();
const Io = std.Io;
const Allocator = std.mem.Allocator;
const path = std.fs.path;

name: ?[]const u8 = null,
next: ?Io.Timestamp = null,

pub fn deinit(self: *Self, a: Allocator) void {
    if (self.name) |name| a.free(name);
    self.* = .{};
}

pub const Sample = struct { deadline: Io.Timestamp, changed: bool };

pub fn sample(self: *Self, a: Allocator, io: Io, workspace: []const u8) !Sample {
    const now = Io.Timestamp.now(io, .awake);
    if (self.next) |next| if (now.compare(.lt, next)) return .{ .deadline = next, .changed = false };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const branch = try readBranch(arena.allocator(), io, workspace);
    const changed = !same(self.name, branch);
    if (changed) {
        const next = if (branch) |name| try a.dupe(u8, name) else null;
        if (self.name) |name| a.free(name);
        self.name = next;
    }
    const deadline = now.addDuration(.fromMilliseconds(500));
    self.next = deadline;
    return .{ .deadline = deadline, .changed = changed };
}

fn same(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |l| return if (right) |r| std.mem.eql(u8, l, r) else false;
    return right == null;
}

fn readRegular(a: Allocator, io: Io, file: []const u8) ?[]const u8 {
    const cwd = Io.Dir.cwd();
    const info = cwd.statFile(io, file, .{}) catch return null;
    if (info.kind != .file) return null;
    const bytes = cwd.readFileAlloc(io, file, a, .limited(16 * 1024)) catch return null;
    return std.mem.trim(u8, bytes, " \t\r\n");
}

fn readBranch(a: Allocator, io: Io, workspace: []const u8) !?[]const u8 {
    const cwd = Io.Dir.cwd();
    var directory = workspace;
    while (true) {
        const dot_git = try path.join(a, &.{ directory, ".git" });
        const stat = cwd.statFile(io, dot_git, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                directory = path.dirname(directory) orelse return null;
                continue;
            },
            else => return null,
        };
        const git_dir = switch (stat.kind) {
            .directory => dot_git,
            .file => blk: {
                const pointer = readRegular(a, io, dot_git) orelse return null;
                const prefix = "gitdir: ";
                if (!std.mem.startsWith(u8, pointer, prefix)) return null;
                const name = std.mem.trim(u8, pointer[prefix.len..], " \t");
                if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return null;
                break :blk if (path.isAbsolute(name)) name else try path.join(a, &.{ directory, name });
            },
            else => return null,
        };
        const head = try path.join(a, &.{ git_dir, "HEAD" });
        const contents = readRegular(a, io, head) orelse return null;
        const prefix = "ref: refs/heads/";
        if (!std.mem.startsWith(u8, contents, prefix)) return "detached";
        const branch = contents[prefix.len..];
        if (std.mem.eql(u8, branch, ".invalid")) return reftableBranch(a, io, directory);
        return if (branch.len == 0) null else branch;
    }
}

fn reftableBranch(a: Allocator, io: Io, cwd: []const u8) []const u8 {
    const result = std.process.run(a, io, .{
        .argv = &.{ "git", "--no-optional-locks", "symbolic-ref", "--quiet", "--short", "HEAD" },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(4096),
        .cwd = .{ .path = cwd },
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(250) } },
    }) catch return "detached";
    if (result.term != .exited or result.term.exited != 0) return "detached";
    const name = std.mem.trim(u8, result.stdout, " \t\r\n");
    return if (name.len == 0) "detached" else name;
}
