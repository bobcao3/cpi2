const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const cwd = std.Io.Dir.cwd();
    var source: []const u8 = try cwd.readFileAlloc(init.io, args[2], a, .limited(1024 * 1024));
    const replacements: []const Replacement =
        if (std.mem.eql(u8, args[1], "Compiler.cpp")) &compiler else if (std.mem.eql(u8, args[1], "lvmexecute.cpp")) &interpreter else if (std.mem.eql(u8, args[1], "lvmutils.cpp")) &metamethods else return error.UnexpectedSourceFile;
    for (replacements) |replacement| {
        if (std.mem.count(u8, source, replacement.before) != replacement.count) {
            std.debug.print("Luau call diagnostics: {s} has an unexpected source anchor:\n{s}\n", .{ args[1], replacement.before });
            return error.UpstreamSourceChanged;
        }
        source = try std.mem.replaceOwned(u8, a, source, replacement.before, replacement.after);
    }
    try cwd.writeFile(init.io, .{ .sub_path = args[3], .data = source });
}

const Replacement = struct {
    before: []const u8,
    after: []const u8,
    count: usize = 1,
};

const compiler = [_]Replacement{
    .{
        .before = "    uint32_t compileFunction(AstExprFunction* func, uint8_t& protoflags)",
        .after = @embedFile("call_target_compiler.inc") ++ "\n    uint32_t compileFunction(AstExprFunction* func, uint8_t& protoflags)",
    },
    .{
        .before = "        LUAU_TIMETRACE_SCOPE(\"Compiler::compileFunction\", \"Compiler\");",
        .after = "        LUAU_TIMETRACE_SCOPE(\"Compiler::compileFunction\", \"Compiler\");\n        hasCallTargets = false;",
    },
    .{
        .before = "        if (options.debugLevel >= 2 && !upvals.empty())",
        .after = "        if ((options.debugLevel >= 2 || hasCallTargets) && !upvals.empty())",
    },
    .{
        .before = "        // Without deoptimization we cannot break VARARG sequences.",
        .after =
        \\        if (options.debugLevel >= 1 && !expr->self)
        \\            recordCallTarget(expr->func, uint32_t(callLabel));
        \\
        \\        // Without deoptimization we cannot break VARARG sequences.
        ,
    },
};

const interpreter = [_]Replacement{
    .{
        .before = "LUAU_FASTFLAG(LuauFastpcall)",
        .after = "LUAU_FASTFLAG(LuauFastpcall)\n\nLUAI_FUNC void luaV_tryfuncTMAt(lua_State* L, StkId func, const Instruction* call);",
    },
    .{
        .before = "            VM_CASE(LOP_CALL)\n            {",
        .after = "            VM_CASE(LOP_CALL)\n            {\n                constexpr int callSize = 1;",
    },
    .{
        .before = "            VM_CASE(LOP_CALLFB)\n            {",
        .after = "            VM_CASE(LOP_CALLFB)\n            {\n                constexpr int callSize = 2;",
    },
    .{
        .before = "                    luaV_tryfuncTM(L, ra);",
        .after = "                    luaV_tryfuncTMAt(L, ra, pc - callSize);",
        .count = 2,
    },
};

const metamethods = [_]Replacement{
    .{
        .before = "#include \"ldo.h\"",
        .after = "#include \"ldo.h\"\n#include \"ldebug.h\"",
    },
    .{
        .before = "LUAU_NOINLINE void luaV_tryfuncTM(lua_State* L, StkId func)",
        .after = @embedFile("call_target_vm.inc") ++ "\nLUAI_FUNC LUAU_NOINLINE void luaV_tryfuncTMAt(lua_State* L, StkId func, const Instruction* call)",
    },
    .{
        .before = "    if (!ttisfunction(tm))\n        luaG_typeerror(L, func, \"call\");",
        .after =
        \\    if (!ttisfunction(tm))
        \\    {
        \\        if (call)
        \\            reportCallTarget(L, func, call);
        \\        luaG_typeerror(L, func, "call");
        \\    }
        ,
    },
    .{
        .before = "    setobj2s(L, func, tm); // tag method is the new function to be called\n}",
        .after =
        \\    setobj2s(L, func, tm); // tag method is the new function to be called
        \\}
        \\
        \\void luaV_tryfuncTM(lua_State* L, StkId func)
        \\{
        \\    luaV_tryfuncTMAt(L, func, nullptr);
        \\}
        ,
    },
};
