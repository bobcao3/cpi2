const std = @import("std");
const c = @import("luau").c;

test "Zig consumer links translated C bindings" {
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(state);
    c.lua_pushinteger(state, -13);
    try std.testing.expectEqual(@as(c_int, -13), c.lua_tointegerx(state, -1, null));
}
