//! Known JSON headers within one function. Branch joins retain possible aliases.
//! Loops visit one body and the skip path. This is not a control-flow proof.
//! Unmodeled helpers, casts, deferred effects, and OWN003 invalidation are not checked.
const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node.Index;
const Token = Ast.TokenIndex;

pub const Finding = struct {
    token: Token,
    rule: []const u8,
    message: []const u8,
    origin: ?Token = null,
};

const Header = struct {
    path: []const u8,
    borrow: ?[]const u8 = null,
    origin: ?Token = null,
    dirty: ?Token = null,
    published: ?Token = null,
    fresh: bool = false,
    root: bool = false,
    slot: bool = false,
    stored: bool = false,
};
const Binding = struct { name: []const u8, ids: []const usize };
const Ids = []const usize;

// Paths passed by the adapter are normalized, repository-relative paths.
pub fn analyze(a: std.mem.Allocator, tree: *const Ast, path: []const u8) ![]Finding {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var checker: Checker = .{ .a = arena.allocator(), .tree = tree, .allow_slots = std.mem.eql(u8, path, "packages/agent/src/RunState.zig") };
    for (0..tree.nodes.len) |i| {
        const node: Node = @fromBackingInt(@intCast(i));
        if (tree.nodeTag(node) == .fn_decl) {
            checker.bindings = .empty;
            checker.headers = .empty;
            _ = try checker.walk(tree.nodeData(node).node_and_node[1]);
        }
    }
    return a.dupe(Finding, checker.findings.items);
}

const Checker = struct {
    a: std.mem.Allocator,
    tree: *const Ast,
    allow_slots: bool,
    headers: std.ArrayList(Header) = .empty,
    bindings: std.ArrayList(Binding) = .empty,
    findings: std.ArrayList(Finding) = .empty,

    fn token(self: *Checker, n: Node) Token {
        return self.tree.nodeMainToken(n);
    }
    fn text(self: *Checker, t: Token) []const u8 {
        return self.tree.tokenSlice(t);
    }
    fn field(self: *Checker, n: Node) ?[]const u8 {
        if (self.tree.nodeTag(n) != .field_access) return null;
        return self.text(self.tree.nodeData(n).node_and_token[1]);
    }
    fn string(self: *Checker, n: Node) !?[]const u8 {
        if (self.tree.nodeTag(n) != .string_literal) return null;
        return try std.zig.string_literal.parseAlloc(self.a, self.text(self.token(n)));
    }
    fn one(self: *Checker, id: usize) !Ids {
        const ids = try self.a.alloc(usize, 1);
        ids[0] = id;
        return ids;
    }
    fn header(self: *Checker, path: []const u8) !usize {
        for (self.headers.items, 0..) |h, i| if (std.mem.eql(u8, h.path, path)) return i;
        try self.headers.append(self.a, .{ .path = path });
        return self.headers.items.len - 1;
    }
    fn unique(self: *Checker, n: Node) !usize {
        return self.header(try std.fmt.allocPrint(self.a, "@{d}", .{@backingInt(n)}));
    }
    fn child(self: *Checker, parent: usize, key: []const u8) !usize {
        const h = self.headers.items[parent];
        const id = try self.header(try std.fmt.allocPrint(self.a, "{s}/{s}", .{ h.path, key }));
        self.headers.items[id].stored = h.stored;
        if (std.mem.eql(u8, key, "value")) self.headers.items[id].root = true;
        return id;
    }
    fn lookup(self: *Checker, name: []const u8) ?usize {
        var i = self.bindings.items.len;
        while (i != 0) {
            i -= 1;
            if (std.mem.eql(u8, self.bindings.items[i].name, name)) return i;
        }
        return null;
    }
    fn unionIds(self: *Checker, left: Ids, right: Ids) !Ids {
        var result: std.ArrayList(usize) = .empty;
        try result.appendSlice(self.a, left);
        for (right) |id| {
            if (std.mem.indexOfScalar(usize, result.items, id) == null) try result.append(self.a, id);
        }
        return result.toOwnedSlice(self.a);
    }
    fn copyBorrow(self: *Checker, ids: Ids, site: Node) !Ids {
        var result: std.ArrayList(usize) = .empty;
        for (ids) |id| {
            const original = self.headers.items[id];
            if (original.borrow != null) {
                const path = try std.fmt.allocPrint(self.a, "@{d}:copy:{d}", .{ @backingInt(site), id });
                const copied = try self.header(path);
                self.headers.items[copied] = original;
                self.headers.items[copied].path = path;
                try result.append(self.a, copied);
            } else try result.append(self.a, id);
        }
        return result.toOwnedSlice(self.a);
    }
    fn finding(self: *Checker, token_index: Token, rule: []const u8, origin: ?Token) !void {
        for (self.findings.items) |f| if (f.token == token_index and std.mem.eql(u8, f.rule, rule)) return;
        try self.findings.append(self.a, .{
            .token = token_index,
            .rule = rule,
            .origin = origin,
            .message = if (std.mem.eql(u8, rule, "OWN001"))
                "borrowed container header mutated before owner observation or publication without matching write-back"
            else if (std.mem.eql(u8, rule, "OWN002"))
                "published container mutated through its former local header or alias"
            else
                "root run slots may only be written by packages/agent/src/RunState.zig",
        });
    }
    fn containsPath(parent: []const u8, child_path: []const u8) bool {
        return std.mem.eql(u8, parent, child_path) or
            (std.mem.startsWith(u8, child_path, parent) and child_path.len > parent.len and child_path[parent.len] == '/');
    }
    fn observe(self: *Checker, ids: Ids) !void {
        for (ids) |id| {
            const path = self.headers.items[id].path;
            for (self.headers.items) |h| {
                if (h.dirty) |mutation| if (h.borrow) |borrow| {
                    if (containsPath(path, borrow) or containsPath(borrow, path)) try self.finding(mutation, "OWN001", h.origin);
                };
            }
        }
    }
    fn mutate(self: *Checker, ids: Ids, token_index: Token) !void {
        for (ids) |id| {
            const h = self.headers.items[id];
            if (h.fresh) if (h.published) |publication| try self.finding(token_index, "OWN002", publication);
            if (h.borrow != null and h.dirty == null) self.headers.items[id].dirty = token_index;
        }
    }
    fn publish(self: *Checker, ids: Ids, destinations: Ids, token_index: Token) !void {
        for (ids) |id| {
            const h = self.headers.items[id];
            var restored = false;
            if (h.borrow) |borrow| {
                for (destinations) |destination| {
                    if (std.mem.eql(u8, self.headers.items[destination].path, borrow)) restored = true;
                }
            }
            if (restored) {
                if (h.dirty) |mutation| {
                    for (self.headers.items) |*other| {
                        if (other.dirty == mutation and other.borrow != null and std.mem.eql(u8, other.borrow.?, h.borrow.?)) other.dirty = null;
                    }
                }
            } else if (h.dirty) |mutation| {
                try self.finding(mutation, "OWN001", h.origin);
            }
            if (h.fresh and h.published == null) self.headers.items[id].published = token_index;
        }
    }
    fn namespace(self: *Checker, n: Node) bool {
        if (self.tree.nodeTag(n) == .identifier) {
            const name = self.text(self.token(n));
            if (std.mem.eql(u8, name, "j")) return true;
            for (self.tree.rootDecls()) |decl| {
                if (self.tree.fullVarDecl(decl)) |v| {
                    if (!std.mem.eql(u8, name, self.text(v.ast.mut_token + 1))) continue;
                    const init = v.ast.init_node.unwrap() orelse continue;
                    if (self.field(init)) |f| return std.mem.eql(u8, f, "j") or std.mem.eql(u8, f, "json");
                    var buffer: [2]Node = undefined;
                    if (self.tree.builtinCallParams(&buffer, init)) |params| {
                        if (params.len == 1) {
                            const raw = self.text(self.token(params[0]));
                            return std.mem.endsWith(u8, raw, "json.zig\"");
                        }
                    }
                }
            }
        }
        return false;
    }
    fn eval(self: *Checker, n: Node, reading: bool) anyerror!Ids {
        const data = self.tree.nodeData(n);
        const tag = self.tree.nodeTag(n);
        var ids: Ids = &.{};
        switch (tag) {
            .identifier => {
                const name = self.text(self.token(n));
                ids = if (self.lookup(name)) |i| self.bindings.items[i].ids else try self.one(try self.header(name));
            },
            .address_of, .deref, .@"try" => return self.eval(data.node, reading),
            .grouped_expression, .unwrap_optional => return self.eval(data.node_and_token[0], reading),
            .@"orelse", .@"catch" => {
                ids = try self.eval(data.node_and_node[0], reading);
                _ = try self.eval(data.node_and_node[1], false);
                return ids;
            },
            .field_access => {
                const parent = try self.eval(data.node_and_token[0], false);
                const key = self.text(data.node_and_token[1]);
                if (std.mem.eql(u8, key, "object") or std.mem.eql(u8, key, "array")) {
                    ids = parent;
                } else {
                    var children: std.ArrayList(usize) = .empty;
                    for (parent) |id| try children.append(self.a, try self.child(id, key));
                    ids = try children.toOwnedSlice(self.a);
                }
            },
            .array_access => {
                const parent = try self.eval(data.node_and_node[0], false);
                _ = try self.eval(data.node_and_node[1], true);
                var children: std.ArrayList(usize) = .empty;
                for (parent) |id| {
                    const child_id = try self.child(id, "[]");
                    self.headers.items[child_id].stored = true;
                    try children.append(self.a, child_id);
                }
                ids = try children.toOwnedSlice(self.a);
            },
            else => {
                var call_buffer: [1]Node = undefined;
                if (self.tree.fullCall(&call_buffer, n)) |invocation| return self.call(n, invocation, reading);
                if (self.tree.fullIf(n) != null or self.tree.fullSwitch(n) != null) {
                    _ = try self.walk(n);
                    return &.{};
                }
                var init_buffer: [2]Node = undefined;
                if (self.tree.fullStructInit(&init_buffer, n)) |init| {
                    for (init.ast.fields) |value| _ = try self.eval(value, true);
                    const id = try self.unique(n);
                    self.headers.items[id].fresh = true;
                    return self.one(id);
                }
                if (self.tree.fullArrayInit(&init_buffer, n)) |init| {
                    for (init.ast.elements) |value| _ = try self.eval(value, true);
                    return &.{};
                }
                if (self.tree.builtinCallParams(&init_buffer, n)) |params| {
                    for (params) |value| _ = try self.eval(value, true);
                    return &.{};
                }
                switch (tag) {
                    .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal, .add, .sub, .mul, .div, .mod, .bool_and, .bool_or, .bit_and, .bit_or, .bit_xor, .array_cat, .shl, .shr, .error_union, .slice_open => {
                        _ = try self.eval(data.node_and_node[0], true);
                        _ = try self.eval(data.node_and_node[1], true);
                    },
                    .for_range => {
                        _ = try self.eval(data.node_and_opt_node[0], true);
                        if (data.node_and_opt_node[1].unwrap()) |end| _ = try self.eval(end, true);
                    },
                    .bool_not, .negation, .bit_not, .negation_wrap => {
                        _ = try self.eval(data.node, reading);
                    },
                    .@"return" => if (data.opt_node.unwrap()) |value| {
                        _ = try self.eval(value, true);
                    },
                    else => {},
                }
                return &.{};
            },
        }
        if (reading) try self.observe(ids);
        return ids;
    }
    fn call(self: *Checker, n: Node, c: Ast.full.Call, reading: bool) !Ids {
        const method = self.field(c.ast.fn_expr) orelse {
            for (c.ast.params) |p| _ = try self.eval(p, true);
            return &.{};
        };
        const receiver = self.tree.nodeData(c.ast.fn_expr).node_and_token[0];
        const json = self.namespace(receiver);
        const params = c.ast.params;
        const token_index = self.tree.nodeData(c.ast.fn_expr).node_and_token[1];
        const get = std.mem.eql(u8, method, "get");
        const ptr = std.mem.eql(u8, method, "ptr") or std.mem.eql(u8, method, "getPtr");
        if ((get or ptr) and params.len == @as(usize, if (json) 2 else 1)) {
            const parents = try self.eval(if (json) params[0] else receiver, false);
            const key = try self.string(params[params.len - 1]) orelse {
                for (params) |p| _ = try self.eval(p, true);
                return &.{};
            };
            var result: std.ArrayList(usize) = .empty;
            for (parents) |parent| {
                const child_id = try self.child(parent, key);
                if (reading and get) try self.observe(try self.one(child_id));
                if (ptr) {
                    self.headers.items[child_id].stored = true;
                    self.headers.items[child_id].slot = self.headers.items[parent].root and isSlot(key);
                    try result.append(self.a, child_id);
                } else {
                    const id = try self.unique(n);
                    self.headers.items[id].borrow = self.headers.items[child_id].path;
                    self.headers.items[id].origin = token_index;
                    try result.append(self.a, id);
                }
            }
            return result.toOwnedSlice(self.a);
        }
        const put = std.mem.eql(u8, method, "put");
        const array_insert = std.mem.eql(u8, method, "append") or std.mem.eql(u8, method, "appendAssumeCapacity") or std.mem.eql(u8, method, "insert");
        const removal = std.mem.eql(u8, method, "remove") or std.mem.eql(u8, method, "swapRemove") or std.mem.eql(u8, method, "orderedRemove") or std.mem.eql(u8, method, "resize") or std.mem.eql(u8, method, "clearRetainingCapacity");
        if ((put and params.len >= @as(usize, if (json) 4 else 2)) or array_insert or removal) {
            const targets = try self.eval(if (json and put) params[1] else receiver, false);
            var destinations: std.ArrayList(usize) = .empty;
            var item: Ids = &.{};
            if (put) {
                const key_index: usize = if (json) 2 else params.len - 2;
                const key = try self.string(params[key_index]);
                if (key) |k| for (targets) |id| {
                    if (!self.allow_slots and self.headers.items[id].root and isSlot(k)) try self.finding(token_index, "OWN004", null);
                    try destinations.append(self.a, try self.child(id, k));
                };
                item = try self.eval(params[params.len - 1], true);
            } else {
                for (params, 0..) |p, i| {
                    const value = try self.eval(p, true);
                    if (array_insert and i == params.len - 1) item = value;
                }
            }
            try self.mutate(targets, token_index);
            try self.publish(item, destinations.items, token_index);
            return &.{};
        }
        for (params) |p| _ = try self.eval(p, true);
        if (!json) _ = try self.eval(receiver, true);
        if (json and (std.mem.eql(u8, method, "object") or std.mem.eql(u8, method, "array") or std.mem.eql(u8, method, "copy") or std.mem.eql(u8, method, "parse") or std.mem.eql(u8, method, "value"))) {
            const id = try self.unique(n);
            self.headers.items[id].fresh = true;
            return self.one(id);
        }
        return &.{};
    }
    fn isSlot(key: []const u8) bool {
        return std.mem.eql(u8, key, "active") or std.mem.eql(u8, key, "suspended");
    }
    fn branch(self: *Checker, yes: Node, no: ?Node) !bool {
        const before = try self.a.dupe(Binding, self.bindings.items);
        const before_headers = try self.a.dupe(Header, self.headers.items);
        const left_alive = try self.walk(yes);
        const left = try self.a.dupe(Binding, self.bindings.items);
        const left_headers = try self.a.dupe(Header, self.headers.items);
        for (self.headers.items, 0..) |*h, i| {
            h.dirty = if (i < before_headers.len) before_headers[i].dirty else null;
            h.published = if (i < before_headers.len) before_headers[i].published else null;
        }
        self.bindings.clearRetainingCapacity();
        try self.bindings.appendSlice(self.a, before);
        const right_alive = if (no) |n| try self.walk(n) else true;
        for (self.headers.items, 0..) |*h, i| {
            const old: Header = if (i < before_headers.len) before_headers[i] else .{ .path = h.path };
            const l: Header = if (left_alive and i < left_headers.len) left_headers[i] else old;
            h.dirty = if (right_alive) h.dirty orelse l.dirty else l.dirty;
            h.published = if (right_alive) h.published orelse l.published else l.published;
        }
        if (!right_alive) {
            self.bindings.clearRetainingCapacity();
            try self.bindings.appendSlice(self.a, if (left_alive) left else before);
        } else if (left_alive) {
            for (self.bindings.items, 0..) |*binding, i| {
                if (i < left.len) binding.ids = try self.unionIds(binding.ids, left[i].ids);
            }
        }
        return left_alive or right_alive;
    }
    fn walk(self: *Checker, n: Node) anyerror!bool {
        const data = self.tree.nodeData(n);
        const tag = self.tree.nodeTag(n);
        var buffer: [2]Node = undefined;
        if (self.tree.blockStatements(&buffer, n)) |statements| {
            const scope = self.bindings.items.len;
            defer self.bindings.shrinkRetainingCapacity(scope);
            for (statements) |statement| if (!try self.walk(statement)) return false;
            return true;
        }
        if (self.tree.fullVarDecl(n)) |decl| {
            var ids = if (decl.ast.init_node.unwrap()) |init| try self.eval(init, true) else &.{};
            if (ids.len == 0) ids = try self.one(try self.unique(n));
            ids = try self.copyBorrow(ids, n);
            try self.bindings.append(self.a, .{ .name = self.text(decl.ast.mut_token + 1), .ids = ids });
            return true;
        }
        if (self.tree.fullIf(n)) |condition| {
            _ = try self.eval(condition.ast.cond_expr, true);
            return self.branch(condition.ast.then_expr, condition.ast.else_expr.unwrap());
        }
        if (self.tree.fullFor(n)) |loop| {
            for (loop.ast.inputs) |input| _ = try self.eval(input, true);
            const scope = self.bindings.items.len;
            var payload = loop.payload_token;
            const pointer = std.mem.eql(u8, self.text(payload), "*");
            if (pointer) payload += 1;
            const id = try self.unique(n);
            self.headers.items[id].stored = pointer;
            try self.bindings.append(self.a, .{ .name = self.text(payload), .ids = try self.one(id) });
            _ = try self.branch(loop.ast.then_expr, loop.ast.else_expr.unwrap());
            self.bindings.shrinkRetainingCapacity(scope);
            return true;
        }
        if (self.tree.fullWhile(n)) |loop| {
            _ = try self.eval(loop.ast.cond_expr, true);
            _ = try self.branch(loop.ast.then_expr, loop.ast.else_expr.unwrap());
            if (loop.ast.cont_expr.unwrap()) |cont| _ = try self.walk(cont);
            return true;
        }
        if (self.tree.fullSwitch(n)) |selection| {
            _ = try self.eval(selection.ast.condition, true);
            const before = try self.a.dupe(Binding, self.bindings.items);
            const before_headers = try self.a.dupe(Header, self.headers.items);
            var merged_headers: std.ArrayList(Header) = .empty;
            try merged_headers.appendSlice(self.a, before_headers);
            const merged = try self.a.dupe(Binding, before);
            for (selection.ast.cases) |case_node| {
                for (self.headers.items, 0..) |*h, i| {
                    h.dirty = if (i < before_headers.len) before_headers[i].dirty else null;
                    h.published = if (i < before_headers.len) before_headers[i].published else null;
                }
                self.bindings.clearRetainingCapacity();
                try self.bindings.appendSlice(self.a, before);
                const case = self.tree.fullSwitchCase(case_node).?;
                if (try self.walk(case.ast.target_expr)) {
                    for (merged, 0..) |*b, i| b.ids = try self.unionIds(b.ids, self.bindings.items[i].ids);
                    for (self.headers.items, 0..) |h, i| {
                        if (i == merged_headers.items.len) try merged_headers.append(self.a, .{ .path = h.path });
                        merged_headers.items[i].dirty = merged_headers.items[i].dirty orelse h.dirty;
                        merged_headers.items[i].published = merged_headers.items[i].published orelse h.published;
                    }
                }
            }
            for (self.headers.items, 0..) |*h, i| {
                h.dirty = if (i < merged_headers.items.len) merged_headers.items[i].dirty else null;
                h.published = if (i < merged_headers.items.len) merged_headers.items[i].published else null;
            }
            self.bindings.clearRetainingCapacity();
            try self.bindings.appendSlice(self.a, merged);
            return true;
        }
        switch (tag) {
            .assign => {
                const lhs = data.node_and_node[0];
                const rhs = try self.eval(data.node_and_node[1], true);
                if (self.tree.nodeTag(lhs) == .identifier) {
                    if (self.lookup(self.text(self.token(lhs)))) |i| self.bindings.items[i].ids = try self.copyBorrow(rhs, n);
                } else {
                    const targets = try self.eval(lhs, false);
                    for (targets) |id| {
                        const h = self.headers.items[id];
                        if (!self.allow_slots and h.slot) try self.finding(self.token(n), "OWN004", null);
                        if (h.stored) try self.publish(rhs, targets, self.token(n));
                    }
                    try self.mutate(targets, self.token(n));
                }
            },
            .@"return" => {
                if (data.opt_node.unwrap()) |value| _ = try self.eval(value, true);
                return false;
            },
            .@"break", .@"continue" => return false,
            .@"defer", .@"errdefer" => {},
            else => {
                _ = try self.eval(n, true);
            },
        }
        return true;
    }
};
