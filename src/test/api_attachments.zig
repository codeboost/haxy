const std = @import("std");
const api_thread = @import("../api/thread.zig");
const api_attachments = @import("../api/attachments.zig");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");

fn expectJson(expected: []const u8, value: anytype) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "attachment routes name a thread's attachments, or one attachment of it, on a server or the local repo" {
    const all = api_thread.route("/api/v1/repos/bobby/linux/issues/0123/attachments", "issues").?;
    try std.testing.expectEqualStrings("0123", all.resource.attachments);
    const one = api_thread.route("/api/v1/repo/issues/0123/attachments/4567", "issues").?;
    try std.testing.expectEqual(.local, std.meta.activeTag(one.target));
    try std.testing.expectEqualStrings("0123", one.resource.attachment.thread);
    try std.testing.expectEqualStrings("4567", one.resource.attachment.attachment);

    for ([_][]const u8{
        "/api/v1/repos/bobby/linux/issues/abc/attachments/",
        "/api/v1/repos/bobby/linux/issues/abc/attachments/x/y",
        "/api/v1/repos/bobby/linux/issues//attachments",
        "/api/v1/repos/bobby/linux/issues/labels/attachments",
        "/api/v1/repos/bobby/linux/issues/abc/attachmentsx",
        "/api/v1/repos/bobby/linux/issues/abc/comments/def/attachments",
    }) |path| {
        try std.testing.expectEqual(null, api_thread.route(path, "issues"));
    }
}

test "an attachment says how it is served and whether the viewer may remove it, as the TUI decides" {
    const id: [evt.event_id_size * 2]u8 = "0123456789abcdef0123456789abcdef".*;
    const writer: ui.Viewer = .{ .role = .write, .email = "wren@example.test" };
    const reader: ui.Viewer = .{ .role = .read, .email = "reed@example.test" };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entry: ui.Repo.Attachment.WithId = .{ .id = id, .name = "shot.png", .author_email = "reed@example.test" };

    // its author, or a writer, may remove it
    try expectJson(
        "{\"id\":\"0123456789abcdef0123456789abcdef\",\"name\":\"shot.png\",\"content_type\":\"image/png\",\"inline\":true,\"actions\":{\"remove\":{\"available\":true}}}",
        try api_attachments.item(arena.allocator(), entry, .{ .viewer = reader, .signed_in = true }),
    );
    try expectJson("{\"available\":true}", (try api_attachments.item(arena.allocator(), entry, .{ .viewer = writer, .signed_in = true })).actions.remove);
    try expectJson(
        "{\"available\":false,\"reason\":{\"code\":\"forbidden\",\"message\":\"Only the attachment's author and the repository's writers can remove it.\"}}",
        (try api_attachments.item(arena.allocator(), entry, .{ .viewer = .{ .role = .read, .email = "someone@example.test" }, .signed_in = true })).actions.remove,
    );
    try expectJson(
        "{\"available\":false,\"reason\":{\"code\":\"unauthenticated\",\"message\":\"Log in to remove attachments.\"}}",
        (try api_attachments.item(arena.allocator(), entry, .{ .viewer = null, .signed_in = false })).actions.remove,
    );

    // a name that isn't UTF-8 is shown with replacement characters; active content downloads
    const odd: ui.Repo.Attachment.WithId = .{ .id = id, .name = "caf\xe9.svg", .author_email = null };
    try expectJson(
        "{\"id\":\"0123456789abcdef0123456789abcdef\",\"name\":\"caf\u{fffd}.svg\",\"content_type\":\"application/octet-stream\",\"inline\":false,\"actions\":{\"remove\":{\"available\":true}}}",
        try api_attachments.item(arena.allocator(), odd, .{ .viewer = writer, .signed_in = true }),
    );
}

test "a thread's limits on attachments are the shared upload rules'" {
    try expectJson("{\"max_bytes\":10485760,\"max_name_bytes\":255}", api_attachments.limits);
}

test "a refused upload's body is read to the end only when its declared length is bounded and the client isn't waiting to send it" {
    try std.testing.expect(api_attachments.drainable(1, .none, false));
    try std.testing.expect(api_attachments.drainable(api_attachments.max_drain, .none, false));
    try std.testing.expect(!api_attachments.drainable(api_attachments.max_drain + 1, .none, false));
    // a chunked body declares no length, so it could be any size
    try std.testing.expect(!api_attachments.drainable(null, .chunked, false));
    // nor does a declared length bound it: the body reader follows the chunks
    try std.testing.expect(!api_attachments.drainable(0, .chunked, false));
    try std.testing.expect(!api_attachments.drainable(1, .chunked, false));
    // a client waiting on 100-continue hasn't sent it
    try std.testing.expect(!api_attachments.drainable(1, .none, true));
}
