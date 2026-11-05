const std = @import("std");
const api_events = @import("../api/events.zig");

test "event routes name a repo's lists or one transaction's, on a server or the local repo" {
    const list = api_events.route("/api/v1/repos/bobby/linux/events").?;
    try std.testing.expectEqualStrings("bobby", list.target.server.owner);
    try std.testing.expectEqualStrings("linux", list.target.server.name);
    try std.testing.expectEqual(null, list.transaction);
    const one = api_events.route("/api/v1/repos/bobby/linux/transactions/12/events").?;
    try std.testing.expectEqualStrings("12", one.transaction.?);
    // names stay encoded until the handler decodes them
    try std.testing.expectEqualStrings("a%20b", api_events.route("/api/v1/repos/a%20b/c/events").?.target.server.owner);

    const local = api_events.route("/api/v1/repo/events").?;
    try std.testing.expectEqual(.local, std.meta.activeTag(local.target));
    try std.testing.expectEqual(null, local.transaction);
    try std.testing.expectEqualStrings("abc", api_events.route("/api/v1/repo/transactions/abc/events").?.transaction.?);

    for ([_][]const u8{
        "/api/v1/repos/bobby/linux",
        "/api/v1/repos/bobby/linux/events/",
        "/api/v1/repos/bobby/linux/events/active",
        "/api/v1/repos/bobby/linux/eventsx",
        "/api/v1/repos/bobby/linux/transactions",
        "/api/v1/repos/bobby/linux/transactions/events",
        "/api/v1/repos/bobby/linux/transactions//events",
        "/api/v1/repos/bobby/linux/transactions/1/2/events",
        "/api/v1/repos//linux/events",
        "/api/v1/repos/bobby/events",
        "/api/v1/repo/events/",
        "/api/v1/repo/issues",
        "/api/v1/repo",
    }) |path| {
        try std.testing.expectEqual(null, api_events.route(path));
    }
}

test "a transaction id is its history index in canonical decimal" {
    try std.testing.expectEqual(0, api_events.parseTransaction("0").?);
    try std.testing.expectEqual(42, api_events.parseTransaction("42").?);
    try std.testing.expectEqual(std.math.maxInt(u64), api_events.parseTransaction("18446744073709551615").?);
    for ([_][]const u8{ "", "01", "+1", "-1", "0x1", "1.0", "abc", "18446744073709551616" }) |text| {
        try std.testing.expectEqual(null, api_events.parseTransaction(text));
    }
}

test "an event cursor names the kind and id of the event a window starts at" {
    const cursor = api_events.Cursor.parse("comment:0123456789abcdef0123456789abcdef").?;
    try std.testing.expectEqual(.comment, cursor.kind);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", cursor.id);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("issue:abc", try api_events.Cursor.format(arena.allocator(), .{ .kind = .issue, .id = "abc" }));

    for ([_][]const u8{ "", "nonsense", "issue:", "thread:abc", ":abc" }) |text| {
        try std.testing.expectEqual(null, api_events.Cursor.parse(text));
    }
}
