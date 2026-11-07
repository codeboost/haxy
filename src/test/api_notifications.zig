const std = @import("std");
const api_notifications = @import("../api/notifications.zig");

test "the inbox routes are the viewer's notifications and their unread count, and nothing below them" {
    try std.testing.expectEqual(.inbox, api_notifications.route("/api/v1/notifications").?);
    try std.testing.expectEqual(.count, api_notifications.route("/api/v1/notifications/count").?);
    for ([_][]const u8{
        "/api/v1/notifications/",
        "/api/v1/notifications/count/",
        "/api/v1/notifications/0123456789abcdef0123456789abcdef",
        "/api/v1/notificationsx",
        "/api/v1/repo/notifications",
    }) |path| {
        try std.testing.expectEqual(null, api_notifications.route(path));
    }
}

test "a thread's notification routes are its state and its acknowledgement, under the thread's own route" {
    const state = api_notifications.threadRoute("/api/v1/repos/bobby/linux/issues/0123456789abcdef0123456789abcdef/notifications", "issues").?;
    try std.testing.expectEqualStrings("bobby", state.thread.target.server.owner);
    try std.testing.expectEqualStrings("linux", state.thread.target.server.name);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", state.thread.resource.thread);
    try std.testing.expectEqual(.state, state.resource);

    const read = api_notifications.threadRoute("/api/v1/repo/issues/abc/notifications/read", "issues").?;
    try std.testing.expectEqual(.local, std.meta.activeTag(read.thread.target));
    try std.testing.expectEqualStrings("abc", read.thread.resource.thread);
    try std.testing.expectEqual(.read, read.resource);

    for ([_][]const u8{
        "/api/v1/repos/bobby/linux/issues/abc",
        "/api/v1/repos/bobby/linux/issues/notifications",
        "/api/v1/repos/bobby/linux/issues/labels/notifications",
        "/api/v1/repos/bobby/linux/issues/abc/notifications/",
        "/api/v1/repos/bobby/linux/issues/abc/notifications/unread",
        "/api/v1/repos/bobby/linux/issues/abc/notifications/read/x",
        "/api/v1/repos/bobby/linux/issues/abc/status/notifications",
        "/api/v1/repos/bobby/linux/issues/abc/comments/notifications",
        "/api/v1/repo/issues//notifications",
        "/api/v1/repo/discussions/abc/notifications",
    }) |path| {
        try std.testing.expectEqual(null, api_notifications.threadRoute(path, "issues"));
    }
}

test "a cursor is the hex of a notif's order key, and nothing else is one" {
    const key: api_notifications.OrderKey = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 } ++ @as([16]u8, @splat(0xab));
    var buffer: [api_notifications.cursor_len]u8 = undefined;
    const cursor = api_notifications.writeCursor(&buffer, key);
    try std.testing.expectEqualStrings("0001020304050607abababababababababababababababab", cursor);
    try std.testing.expectEqualSlices(u8, &key, &api_notifications.parseCursor(cursor).?);
    for ([_][]const u8{ "", "20", "0001020304050607ABABABABABABABABABABABABABABABAB", "0001020304050607abababababababababababababababab00", "zz01020304050607abababababababababababababababab" }) |text| {
        try std.testing.expectEqual(null, api_notifications.parseCursor(text));
    }
}

test "a full subscribed tier is a conflict that says how many subscribers a thread may have" {
    const err = api_notifications.subscribersFull("issue");
    try std.testing.expectEqual(.conflict, err.code);
    try std.testing.expectEqualStrings("This issue already has 100 subscribers, the most Haxy allows.", err.message);
}
