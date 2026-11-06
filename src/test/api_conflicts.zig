const std = @import("std");
const api_conflicts = @import("../api/conflicts.zig");
const shapes = @import("../api/conflict_shapes.zig");

fn parsed(arena: std.mem.Allocator, body: []const u8) !shapes.Request {
    return switch (try shapes.parseRequest(arena, body)) {
        .ok => |request| request,
        .invalid => error.TestUnexpectedResult,
    };
}

fn checked(arena: std.mem.Allocator, offered: shapes.Offered, body: []const u8) !shapes.Checked {
    return shapes.check(arena, .patch, offered, try parsed(arena, body));
}

fn refusedField(result: shapes.Checked) []const u8 {
    return switch (result) {
        .ok => "",
        .invalid => |err| err.field_errors[0].field,
    };
}

test "a resolution request is a JSON object of a revision, texts, the description's chunks and their side's choices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const request = try parsed(aa, "{\"revision\":\"ab\",\"title\":\"T\",\"description\":[\"one\",\"\"],\"theirs\":[\"target\"]}");
    try std.testing.expectEqualStrings("ab", request.revision);
    try std.testing.expectEqualStrings("T", request.title.?);
    try std.testing.expectEqual(null, request.labels);
    try std.testing.expectEqual(2, request.description.?.len);
    try std.testing.expectEqualStrings("target", request.theirs[0]);

    for ([_][]const u8{ "[]", "{\"title\":3}", "{\"description\":\"text\"}", "{\"theirs\":[1]}", "not json" }) |body| {
        try std.testing.expect(try shapes.parseRequest(aa, body) == .invalid);
    }
}

test "a resolution settles only what the conflict offers, as the TUI's resolve form does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const offered: shapes.Offered = .{ .title = true, .hunks = 2, .choices = &.{ .status, .target } };

    const ok = (try checked(aa, offered, "{\"revision\":\"r\",\"title\":\"Both\",\"description\":[\"a\\r\\nb\",\"\"],\"theirs\":[\"target\",\"status\"]}")).ok;
    try std.testing.expectEqualStrings("Both", ok.title.?);
    try std.testing.expectEqualStrings("a\nb", ok.hunks[0]);
    try std.testing.expectEqualStrings("target_branch,status", ok.theirs);

    try std.testing.expectEqualStrings("labels", refusedField(try checked(aa, offered, "{\"labels\":\"bug\"}")));
    try std.testing.expectEqualStrings("description", refusedField(try checked(aa, offered, "{\"description\":[\"only one\"]}")));
    try std.testing.expectEqualStrings("theirs", refusedField(try checked(aa, offered, "{\"theirs\":[\"revision\"]}")));
    try std.testing.expectEqualStrings("theirs", refusedField(try checked(aa, offered, "{\"theirs\":[\"title\"]}")));
    try std.testing.expectEqualStrings("title", refusedField(try checked(aa, offered, "{\"title\":\"  \"}")));
    try std.testing.expectEqualStrings("description", refusedField(try checked(aa, .{ .title = true }, "{\"description\":[]}")));
}

test "the conflict routes sit under a kind's threads, beside their own thread routes" {
    const list = api_conflicts.route("/api/v1/repos/alice/tools/issues/conflicts").?;
    try std.testing.expectEqual(.issues, list.kind);
    try std.testing.expectEqual(null, list.thread);
    const one = api_conflicts.route("/api/v1/repo/patches/0123/conflict").?;
    try std.testing.expectEqual(.patches, one.kind);
    try std.testing.expectEqualStrings("0123", one.thread.?);
    try std.testing.expectEqual(null, api_conflicts.route("/api/v1/repo/discussions/conflicts"));
    try std.testing.expectEqual(null, api_conflicts.route("/api/v1/repo/issues/conflicts/conflict"));
    try std.testing.expectEqual(null, api_conflicts.route("/api/v1/repo/issues/0123"));
}
