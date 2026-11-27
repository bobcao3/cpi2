const std = @import("std");
const agent = @import("agent");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .unlimited);
    defer init.gpa.free(source);
    const code = try agent.compileBytecode(init.gpa, source);
    defer init.gpa.free(code);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = code });
}
