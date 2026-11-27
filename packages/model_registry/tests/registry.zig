const std = @import("std");
const json_text = @import("agent").session_protocol.json.text;
const registry = @import("model_registry");

const prelude =
    \\local function provider(id, url, models)
    \\ return {id=id,name=id,base_url=url,api_key_env='MUST_NOT_READ_CREDENTIAL',api='unknown',models=models or {}}
    \\end
    \\local function model(id) return {id=id,name=id} end
;

fn parse(source: []const u8) !registry.Registry {
    const bytes = try std.mem.concat(std.testing.allocator, u8, &.{ prelude, "\n", source });
    defer std.testing.allocator.free(bytes);
    return registry.Registry.parse(std.testing.allocator, bytes);
}

test "computed Lua owns source and VM strings and preserves provider lookup contracts" {
    const a = std.testing.allocator;
    const source = try a.dupe(u8, prelude ++ "\n" ++
        \\local providers={}
        \\for i=1,2 do
        \\ local m=model('shared')
        \\ m.name='Café\000\010\031\127'..i
        \\ m.context_window=2^53-1
        \\ m.max_output_tokens=2^32-1
        \\ m.pricing={input=i*2.5,output=nil}
        \\ if i==2 then m.api='openai-responses' end
        \\ providers[i]=provider('p'..i,'https://example.test/'..i,{m})
        \\end
        \\return {version=2-1,providers=providers}
    );
    var loaded = try registry.Registry.parse(a, source);
    defer loaded.deinit();
    @memset(source, 'x');
    a.free(source);
    const p1 = loaded.find("p1").?;
    const p2 = loaded.find("p2").?;
    const m1 = p1.find("shared").?;
    const m2 = p2.find("shared").?;
    try std.testing.expectEqualStrings("Café\x00\n\x1f\x7f1", m1.name);
    try std.testing.expectEqual(@as(?f64, 2.5), m1.pricing.input);
    try std.testing.expectEqual(@as(?f64, 5), m2.pricing.input);
    try std.testing.expectEqual(@as(?f64, null), m1.pricing.output);
    try std.testing.expectEqual(@as(?u64, 9007199254740991), m1.context_window);
    try std.testing.expectEqual(@as(?u32, 4294967295), m1.max_output_tokens);
    try std.testing.expectEqual(@as(usize, 0), m1.transports.len);
    try std.testing.expect(m2.supports("openai-responses"));
    try std.testing.expect(loaded.find("missing") == null);
    try std.testing.expect(p1.find("missing") == null);
    try std.testing.expect(loaded.matchEndpoint("https://example.test/1/", "shared") == p1);
    try std.testing.expect(loaded.matchEndpoint("https://example.test/3", "shared") == null);
    try std.testing.expect(loaded.matchEndpoint("https://example.test/1", "missing") == null);
}

test "nil optional fields default and overlapping endpoint matches remain ambiguous" {
    var loaded = try parse(
        \\local m=model('shared'); m.context_window=nil; m.pricing=nil
        \\return {version=1,providers={provider('a','https://example.test',{m}),provider('b','https://example.test/',{m})}}
    );
    defer loaded.deinit();
    try std.testing.expect(loaded.matchEndpoint("https://example.test", "shared") == null);
    const m = loaded.find("a").?.find("shared").?;
    try std.testing.expectEqual(@as(?u64, null), m.context_window);
    try std.testing.expectEqual(@as(?u32, null), m.max_output_tokens);
    try std.testing.expectEqual(@as(usize, 0), m.transports.len);
    try std.testing.expectEqual(@as(?f64, null), m.pricing.input);
}

test "typed result rejects invalid shapes numbers identities and executable values" {
    const cases = .{
        .{ "return {version=3,providers={}}", error.UnsupportedRegistryVersion },
        .{ "return {version='1',providers={}}", error.InvalidRegistryNumber },
        .{ "return {version=1.5,providers={}}", error.InvalidRegistryNumber },
        .{ "return {version=true,providers={}}", error.InvalidRegistryNumber },
        .{ "return {version=1,providers={},extra=true}", error.UnknownField },
        .{ "return {version=1,providers={[2]=provider('p','')}}", error.InvalidRegistryShape },
        .{ "return {version=1,providers={provider('p',''),extra=1}}", error.InvalidRegistryShape },
        .{ "return {version=1,providers={provider('p','',{[2]=model('m')})}}", error.InvalidRegistryShape },
        .{ "local p=provider('p',''); p.api=nil; return {version=1,providers={p}}", error.InvalidRegistryShape },
        .{ "local m=model('m'); m.extra=true; return {version=1,providers={provider('p','',{m})}}", error.UnknownField },
        .{ "return {version=1,providers={provider('p',''),provider('p','')}}", error.DuplicateProvider },
        .{ "return {version=1,providers={provider('p','',{model('m'),model('m')})}}", error.DuplicateModel },
        .{ "return {version=1,providers={provider('','')}}", error.InvalidProvider },
        .{ "return {version=1,providers={provider('p','',{model('')})}}", error.InvalidModel },
        .{ "return {version=1,providers=function() end}", error.InvalidRegistryShape },
        .{ "local m=model('m'); m.name=function() end; return {version=1,providers={provider('p','',{m})}}", error.InvalidRegistryShape },
        .{ "return setmetatable({version=1,providers={}},{})", error.RegistryMetatable },
        .{ "local x={version=1}; x.providers=x; return x", error.RegistryCycle },
        .{ "return {version=1,providers={}},{}", error.InvalidRegistryShape },
        .{ "return nil", error.InvalidRegistryShape },
        .{ "return {", error.RegistrySyntax },
    };
    inline for (cases) |case| try std.testing.expectError(case[1], parse(case[0]));
    const numeric = .{
        .{ "context_window", "2^53" },
        .{ "context_window", "1.5" },
        .{ "context_window", "'1024'" },
        .{ "max_output_tokens", "2^32" },
        .{ "max_output_tokens", "-1" },
        .{ "max_output_tokens", "0/0" },
        .{ "pricing", "{input=math.huge}" },
        .{ "pricing", "{input=0/0}" },
        .{ "pricing", "{input=true}" },
        .{ "pricing", "{input=-0.01}" },
        .{ "pricing", "{cache_read='2'}" },
    };
    inline for (numeric) |case| {
        try std.testing.expectError(error.InvalidRegistryNumber, parse("local m=model('m'); m." ++ case[0] ++ "=" ++ case[1] ++ "; return {version=1,providers={provider('p','',{m})}}"));
    }
    try std.testing.expectError(error.InvalidModelLimits, parse("local m=model('m'); m.context_window=0; return {version=1,providers={provider('p','',{m})}}"));
}

test "sandbox excludes effect capabilities and stops an infinite loop even inside pcall" {
    var loaded = try parse(
        \\for _,name in ipairs({'io','os','debug','require','loadstring','load','dofile','loadfile','getfenv','setfenv','print','collectgarbage','newproxy','coroutine'}) do
        \\ assert(_G[name]==nil,name)
        \\end
        \\assert(math.floor(3.5)==3 and string.upper('abc')=='ABC')
        \\return {version=1,providers={}}
    );
    defer loaded.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(workspace);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "denied", .data = "observer-control" });
    const observed = try tmp.dir.readFileAlloc(std.testing.io, "denied", std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(observed);
    try std.testing.expectEqualStrings("observer-control", observed);
    try tmp.dir.deleteFile(std.testing.io, "denied");
    const attempts = .{
        "return io.open([=[{s}/denied]=],'w')",
        "return os.execute([=[touch '{s}/denied']=])",
    };
    inline for (attempts) |attempt| {
        const source = try std.fmt.allocPrint(std.testing.allocator, attempt, .{workspace});
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.RegistryRuntime, parse(source));
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "denied", .{}));
    }
    try std.testing.expectError(error.RegistryExecutionLimit, parse("while true do pcall(function() while true do end end) end"));
}

fn allocationCase(a: std.mem.Allocator) !void {
    var loaded = try registry.Registry.parse(a,
        \\return {version=1,providers={{id='p',name='P',base_url='',api_key_env='',api='unknown',models={{id='a',name='A',pricing={input=2.5}}}}}}
    );
    defer loaded.deinit();
    try std.testing.expectEqual(@as(?f64, 2.5), loaded.find("p").?.find("a").?.pricing.input);
}

fn concurrentEvaluation(id: []const u8) !void {
    const a = std.heap.page_allocator;
    const source = try std.fmt.allocPrint(a, "{s}\nreturn {{version=1,providers={{provider('{s}','')}}}}", .{ prelude, id });
    defer a.free(source);
    for (0..16) |_| {
        var loaded = try registry.Registry.parse(a, source);
        defer loaded.deinit();
        try std.testing.expectEqualStrings(id, loaded.providers()[0].id);
    }
}

fn invalidAllocationCase(a: std.mem.Allocator) !void {
    var loaded = registry.Registry.parse(a, "return {version=1,providers=function() end}") catch |err| switch (err) {
        error.InvalidRegistryShape => return,
        else => return err,
    };
    loaded.deinit();
    return error.ExpectedInvalidRegistry;
}

test "concurrent callers own independent compiler and VM evaluations" {
    const io = std.testing.io;
    var other = try io.concurrent(concurrentEvaluation, .{"other"});
    defer other.cancel(io) catch {};
    try concurrentEvaluation("main");
    try other.await(io);
}

test "parse releases VM and typed arena on allocation failure" {
    // Force reallocations through alloc/free so arena growth cannot change the
    // number of injectable allocations according to backing page placement.
    const NoResize = struct {
        fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            return std.testing.allocator.rawAlloc(len, alignment, ra);
        }
        fn free(_: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            std.testing.allocator.rawFree(bytes, alignment, ra);
        }
    };
    const deterministic: std.mem.Allocator = .{ .ptr = undefined, .vtable = &.{ .alloc = NoResize.alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = NoResize.free } };
    try std.testing.checkAllAllocationFailures(deterministic, allocationCase, .{});
    try std.testing.checkAllAllocationFailures(deterministic, invalidAllocationCase, .{});
}

test "future source effort levels remain data without blocking known picker choices" {
    const model: registry.Model = .{ .id = "future", .name = "Future", .reasoning_efforts = &.{ "low", "future-native-effort" } };
    try std.testing.expect((try model.thinkingProfile()).?.supports(.low));
    const unknown: registry.Model = .{ .id = "future-only", .name = "Future", .reasoning_efforts = &.{"future-native-effort"} };
    try std.testing.expect((try unknown.thinkingProfile()) == null);
}

test "runtime providers cannot carry transport defaults" {
    try std.testing.expect(!@hasField(registry.Provider, "api"));
    try std.testing.expectError(error.UnknownField, registry.Registry.parse(std.testing.allocator,
        \\return {version=2,providers={{id='p',name='P',base_url='',api_key_env='',api='openai-responses',models={}}}}
    ));
}

test "harness injection and live metadata survive caller teardown and registry growth" {
    const a = std.testing.allocator;
    var catalog = try registry.Registry.parse(a, "return {version=2,providers={}}");
    defer catalog.deinit();
    {
        var job: std.heap.ArenaAllocator = .init(a);
        defer job.deinit();
        const j = job.allocator();
        const provider: registry.Provider = .{ .id = try j.dupe(u8, "fixture"), .name = "Fixture", .base_url = "https://fixture.test", .api_key_env = "FIXTURE_KEY", .models = &.{.{ .id = "model", .name = "Model", .transports = &.{"openai-responses"}, .context_window = 4000 }} };
        try catalog.putProvider(provider);
        const body = try json_text.parseFromSliceLeaky(std.json.Value, j,
            \\{"data":[{"id":"model","context_window":8000,"max_output_tokens":2000,"effort":{"supported_levels":["low","max"]}}]}
        , .{});
        const models = try registry.discovery.parse(j, body, .standard, null, "https://fixture.test/models");
        try catalog.mergeDiscovery(provider.base_url, models);
    }
    for (0..40) |i| {
        const id = try std.fmt.allocPrint(a, "injected-{d}", .{i});
        defer a.free(id);
        try catalog.putProvider(.{ .id = id, .name = id, .base_url = "", .api_key_env = "", .models = &.{} });
    }
    try std.testing.expectError(error.InvalidModelLimits, catalog.putProvider(.{
        .id = "fixture",
        .name = "Invalid replacement",
        .base_url = "",
        .api_key_env = "",
        .models = &.{.{ .id = "model", .name = "Model", .context_window = 9007199254740992 }},
    }));
    const model = catalog.find("fixture").?.find("model").?;
    try std.testing.expectEqual(@as(?u64, 8000), model.context_window);
    try std.testing.expectEqual(@as(?u32, 2000), model.max_output_tokens);
    try std.testing.expect(model.supports("openai-responses"));
    try std.testing.expect((try model.thinkingProfile()).?.supports(.max));
    try std.testing.expectEqualStrings("https://fixture.test/models", model.source_url.?);
}

test "direct DeepSeek environment selection uses framework service and model settings" {
    const a = std.testing.allocator;
    var catalog = try registry.Registry.bundled(a);
    defer catalog.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("DEEPSEEK_API_KEY", "synthetic-only");
    const provider = (try registry.selection.environmentProvider(&catalog, &env, null)).?;
    try std.testing.expectEqualStrings("deepseek", provider.id);
    const selected_model = registry.selection.providerModel(provider, &env, null, null).?;
    try std.testing.expectEqualStrings("deepseek-flash", selected_model);
    try std.testing.expect(env.get("OPENAI_MODEL") == null);
    try std.testing.expect(env.get("DEEPSEEK_MODEL") == null);
    const model = provider.find(selected_model).?;
    try std.testing.expect(model.supports("openai-responses"));
    try std.testing.expectEqual(@as(u64, 1048576), registry.selection.limits(model, .{}, .{}).context_window);
    try env.put("OPENAI_MODEL", "unrelated-openai-model");
    try std.testing.expectEqualStrings("deepseek-flash", registry.selection.providerModel(provider, &env, null, null).?);
    try std.testing.expectEqualStrings("remembered-model", registry.selection.providerModel(provider, &env, null, "remembered-model").?);
    try env.put("DEEPSEEK_MODEL", "deepseek-v4-pro");
    try std.testing.expectEqualStrings("deepseek-v4-pro", registry.selection.providerModel(provider, &env, null, null).?);
    try std.testing.expectEqualStrings("explicit-model", registry.selection.providerModel(provider, &env, "explicit-model", null).?);
    try env.put("OPENAI_API_KEY", "another-synthetic-key");
    try std.testing.expect((try registry.selection.environmentProvider(&catalog, &env, null)) == null);
}

test "bundled Lua catalog loads through public API" {
    var loaded = try registry.Registry.bundled(std.testing.allocator);
    defer loaded.deinit();
    try std.testing.expect(loaded.providers().len > 1);
}
