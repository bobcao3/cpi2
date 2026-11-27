const std = @import("std");
const protocol = @import("session_protocol");
const frames = protocol.frames;
const examples = @embedFile("session_frame_examples");
const Transaction = protocol.Transaction;

test {
    _ = protocol.Extensions;
}

test "documented JSONL histories decode into the native action model" {
    var remaining: []const u8 = examples;
    var histories: usize = 0;
    var count: usize = 0;
    while (std.mem.indexOf(u8, remaining, "```jsonl\n")) |start| {
        remaining = remaining[start + "```jsonl\n".len ..];
        const end = std.mem.indexOf(u8, remaining, "\n```") orelse return error.InvalidFixture;
        var lines = std.mem.splitScalar(u8, remaining[0..end], '\n');
        var sequence: u64 = 0;
        while (lines.next()) |line| {
            var decoded = try frames.Owned.parse(std.testing.allocator, line, 8 * 1024 * 1024);
            defer decoded.deinit();
            sequence += 1;
            try std.testing.expectEqual(sequence, decoded.frame.seq);
            count += 1;
        }
        histories += 1;
        remaining = remaining[end + "\n```".len ..];
    }
    try std.testing.expectEqual(@as(usize, 3), histories);
    try std.testing.expectEqual(@as(usize, 40), count);
}

test "documented histories split into complete native transactions" {
    var remaining: []const u8 = examples;
    var count: usize = 0;
    while (std.mem.indexOf(u8, remaining, "```jsonl\n")) |start| {
        remaining = remaining[start + "```jsonl\n".len ..];
        const end = std.mem.indexOf(u8, remaining, "\n```") orelse return error.InvalidFixture;
        const jsonl = remaining[0 .. end + 1];
        var lines = std.mem.splitScalar(u8, jsonl, '\n');
        var position: usize = 0;
        var batch_start: usize = 0;
        var next_sequence: u64 = 1;
        while (lines.next()) |line| {
            if (line.len == 0) break;
            var decoded = try frames.Owned.parse(std.testing.allocator, line, 8 * 1024 * 1024);
            defer decoded.deinit();
            position += line.len + 1;
            if (decoded.frame.tx.index + 1 == decoded.frame.tx.count) {
                var batch = try Transaction.parse(std.testing.allocator, decoded.frame.session_id, next_sequence, jsonl[batch_start..position], .{});
                defer batch.deinit();
                next_sequence = batch.lastSequence() + 1;
                count += batch.frames.len;
                batch_start = position;
            }
        }
        try std.testing.expectEqual(jsonl.len, batch_start);
        remaining = remaining[end + "\n```".len ..];
    }
    try std.testing.expectEqual(@as(usize, 40), count);
}

test "insert at the beginning has a required nullable anchor" {
    var decoded = try frames.Owned.parse(std.testing.allocator,
        \\{"v":1,"session_id":"test","seq":1,"tx":{"id":"t1","index":0,"count":1},"class":"control","op":"control.document_mutation","actor":{"kind":"host","id":"host"},"cause":null,"data":{"context":"main","expected_head":0,"edits":[{"op":"insert","after":null,"ids":["m1"]}]}}
    , 8192);
    defer decoded.deinit();
    const edit = decoded.frame.action.@"control.document_mutation".edits[0];
    try std.testing.expect(edit == .insert);
    try std.testing.expect(edit.insert.after == null);
    try std.testing.expectEqualStrings("m1", edit.insert.ids[0]);
}

test "binary message parts validate the decoded content hash" {
    const source =
        \\{"v":1,"session_id":"test","seq":1,"tx":{"id":"t1","index":0,"count":1},"class":"document","op":"document.message.append","actor":{"kind":"host","id":"host"},"cause":null,"data":{"message":{"id":"m1","role":"user","content":[{"type":"binary","media_type":"application/octet-stream","base64":"aGVsbG8=","sha256":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"}]},"placement":null}}
    ;
    var decoded = try frames.Owned.parse(std.testing.allocator, source, 8192);
    defer decoded.deinit();
    try std.testing.expectEqual(frames.Role.user, decoded.frame.action.@"document.message.append".message.role);
    const corrupted = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        source,
        "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        "3cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
    );
    defer std.testing.allocator.free(corrupted);
    try std.testing.expectError(error.InvalidHash, frames.Owned.parse(std.testing.allocator, corrupted, 8192));
}
