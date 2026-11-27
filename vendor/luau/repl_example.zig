const std = @import("std");
const builtin = @import("builtin");
const c = @import("luau").c;

extern "c" fn fflush(stream: ?*std.c.FILE) c_int;

const native_extensions = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
    else => false,
};

pub fn main(init: std.process.Init) !void {
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    var libraries: std.ArrayList(std.DynLib) = .empty;
    defer {
        c.lua_close(state);
        if (native_extensions) {
            var remaining = libraries.items.len;
            while (remaining > 0) {
                remaining -= 1;
                libraries.items[remaining].close();
            }
        }
        libraries.deinit(init.gpa);
    }
    c.luaL_openlibs(state);
    c.luaL_sandbox(state);
    c.luaL_sandboxthread(state);
    c.lua_pushvalue(state, c.LUA_GLOBALSINDEX);
    c.lua_setfield(state, c.LUA_GLOBALSINDEX, "_G");
    c.lua_setsafeenv(state, c.LUA_GLOBALSINDEX, 0);

    var input_buffer: [65536]u8 = undefined;
    var output_buffer: [4096]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(init.io, &input_buffer);
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    const interactive = try std.Io.File.stdin().isTty(init.io);
    var chunk: std.ArrayList(u8) = .empty;
    defer chunk.deinit(init.gpa);

    if (interactive) {
        try output.interface.writeAll("Luau REPL. :quit exits; :load NAME PATH loads a native module.\n");
    }
    while (true) {
        if (interactive) try output.interface.writeAll(if (chunk.items.len == 0) "luau> " else "...> ");
        try output.interface.flush();
        const line = (input.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try output.interface.writeAll("input error: line too long\n");
                _ = input.interface.discardDelimiterInclusive('\n') catch |discard_error| switch (discard_error) {
                    error.EndOfStream => 0,
                    else => return discard_error,
                };
                chunk.clearRetainingCapacity();
                continue;
            },
            else => return err,
        }) orelse {
            if (chunk.items.len > 0) _ = try evaluate(init.gpa, state, chunk.items, true, &output.interface);
            break;
        };
        const source = std.mem.trim(u8, line, " \t\r");
        if (chunk.items.len == 0) {
            if (std.mem.eql(u8, source, ":quit")) break;
            if (source.len == 0) continue;
            if (std.mem.eql(u8, source, ":load") or
                std.mem.startsWith(u8, source, ":load ") or
                std.mem.startsWith(u8, source, ":load\t"))
            {
                try loadExtension(init.gpa, state, &libraries, source[5..], &output.interface);
                continue;
            }
        }
        if (chunk.items.len + line.len + 1 > 1024 * 1024) {
            try output.interface.writeAll("input error: chunk too long\n");
            chunk.clearRetainingCapacity();
            continue;
        }
        try chunk.appendSlice(init.gpa, line);
        try chunk.append(init.gpa, '\n');
        if (try evaluate(init.gpa, state, chunk.items, false, &output.interface)) {
            chunk.clearRetainingCapacity();
        }
    }
    try output.interface.flush();
}

fn evaluate(
    allocator: std.mem.Allocator,
    main_state: *c.lua_State,
    source: []const u8,
    at_eof: bool,
    output: *std.Io.Writer,
) !bool {
    const code = std.mem.trim(u8, source, " \t\r\n");
    const explicit_expression = code.len > 0 and code[0] == '=';
    const expression = try std.fmt.allocPrint(allocator, "return {s}", .{if (explicit_expression) code[1..] else code});
    defer allocator.free(expression);
    var bytecode = try compile(expression);
    defer std.c.free(bytecode.ptr);
    if (bytecode.len > 0 and bytecode[0] == 0) {
        const expression_incomplete = std.mem.endsWith(u8, bytecode, "<eof>");
        if (explicit_expression) {
            if (expression_incomplete and !at_eof) return false;
        } else {
            const statement = try compile(code);
            if (statement.len > 0 and statement[0] == 0 and
                (expression_incomplete or std.mem.endsWith(u8, statement, "<eof>")))
            {
                if (!at_eof) {
                    std.c.free(statement.ptr);
                    return false;
                }
                if (expression_incomplete) {
                    std.c.free(statement.ptr);
                } else {
                    std.c.free(bytecode.ptr);
                    bytecode = statement;
                }
            } else {
                std.c.free(bytecode.ptr);
                bytecode = statement;
            }
        }
    }

    const state = c.lua_newthread(main_state) orelse return error.OutOfMemory;
    defer {
        c.lua_resetthread(state);
        c.lua_settop(main_state, 0);
    }

    const loaded = c.luau_load(state, "=repl", bytecode.ptr, bytecode.len, 0);
    if (loaded != c.LUA_OK) {
        try writeError(state, "compile error: ", output);
        return true;
    }
    const status = c.lua_resume(state, null, 0);
    if (fflush(null) != 0) return error.WriteFailed;
    if (status == c.LUA_YIELD or status == c.LUA_BREAK) {
        try output.writeAll("runtime error: thread yielded unexpectedly\n");
        return true;
    }
    if (status != c.LUA_OK) {
        try writeError(state, "runtime error: ", output);
        return true;
    }
    const count = c.lua_gettop(state);
    if (count > 0) {
        _ = c.lua_getfield(state, c.LUA_GLOBALSINDEX, "print");
        c.lua_insert(state, 1);
        const printed = c.lua_pcall(state, count, 0, 0);
        if (fflush(null) != 0) return error.WriteFailed;
        if (printed != c.LUA_OK) try writeError(state, "print error: ", output);
    }
    return true;
}

fn compile(source: []const u8) ![]u8 {
    var size: usize = 0;
    const bytecode = c.luau_compile(source.ptr, source.len, null, &size);
    if (bytecode == null) return error.OutOfMemory;
    return bytecode[0..size];
}

fn writeError(state: *c.lua_State, prefix: []const u8, output: *std.Io.Writer) !void {
    try output.writeAll(prefix);
    if (c.lua_type(state, -1) == c.LUA_TSTRING) {
        var size: usize = 0;
        const message = c.lua_tolstring(state, -1, &size);
        try output.writeAll(message[0..size]);
    } else {
        try output.writeAll("non-string error");
    }
    try output.writeByte('\n');
}

fn loadExtension(
    allocator: std.mem.Allocator,
    state: *c.lua_State,
    libraries: *std.ArrayList(std.DynLib),
    arguments: []const u8,
    output: *std.Io.Writer,
) !void {
    const args = std.mem.trim(u8, arguments, " \t");
    const separator = std.mem.findAny(u8, args, " \t") orelse {
        try output.writeAll("load error: usage: :load NAME PATH\n");
        return;
    };
    const name = args[0..separator];
    const path = std.mem.trim(u8, args[separator..], " \t");
    if (name.len == 0 or path.len == 0 or
        !(std.ascii.isAlphabetic(name[0]) or name[0] == '_'))
    {
        try output.writeAll("load error: expected a module identifier and library path\n");
        return;
    }
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') {
            try output.writeAll("load error: invalid module identifier\n");
            return;
        }
    }
    if (std.mem.findScalar(u8, path, 0) != null) {
        try output.writeAll("load error: library path contains a NUL byte\n");
        return;
    }
    if (!native_extensions) {
        try output.writeAll("load error: native modules are unsupported on this platform\n");
        return;
    }
    const symbol = try std.fmt.allocPrintSentinel(allocator, "luaopen_{s}", .{name}, 0);
    defer allocator.free(symbol);
    const global = try allocator.dupeSentinel(u8, name, 0);
    defer allocator.free(global);

    var library = std.DynLib.open(path) catch |err| {
        try output.print("load error: {s}: {s}\n", .{ path, @errorName(err) });
        return;
    };
    var retained = false;
    defer if (!retained) library.close();
    const OpenFunction = *const fn (?*c.lua_State) callconv(.c) c_int;
    const open = library.lookup(OpenFunction, symbol) orelse {
        try output.print("load error: missing symbol {s}\n", .{symbol});
        return;
    };
    try libraries.append(allocator, library);
    retained = true;
    defer c.lua_settop(state, 0);
    c.lua_pushcclosurek(state, open, null, 0, null);
    const status = c.lua_pcall(state, 0, 1, 0);
    if (fflush(null) != 0) return error.WriteFailed;
    if (status != c.LUA_OK) {
        try writeError(state, "load error: ", output);
        return;
    }
    if (c.lua_type(state, -1) == c.LUA_TNIL) {
        try output.writeAll("load error: module initializer returned nil\n");
        return;
    }
    c.lua_setfield(state, c.LUA_GLOBALSINDEX, global);
}
