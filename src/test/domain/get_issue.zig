const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

const issue: fixture.Id = @splat(0x11);
const issue_hex = "11111111111111111111111111111111";
const other: fixture.Id = @splat(0x22);

test "domain: GetIssue reads one issue with its comments" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addEvent(server.open, Server.alice_author, issue, .{ .issue = .{ .title = "the issue", .description = "what's wrong", .labels = "bug" } });
    try server.addEvent(server.open, Server.bob_author, other, .{ .issue = .{ .title = "another", .description = "", .labels = "" } });
    // twelve comments, more than one window of ten
    for (0..12) |i| {
        try server.addEvent(server.open, Server.bob_author, @splat(@intCast(0x30 + i)), .{ .comment = .{ .thread_id = issue_hex.*, .parent_id = issue_hex.*, .body = "a comment" } });
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    {
        const entry = try (domain.GetIssue{ .repo = "alice:open", .id = issue_hex }).run(&ctx);
        try std.testing.expectEqualStrings(issue_hex, entry.id);
        try std.testing.expectEqualStrings("the issue", entry.record.event.title);
        try std.testing.expectEqualStrings("what's wrong", entry.record.event.description);
        try std.testing.expectEqualStrings("bug", entry.record.event.labels);
        try std.testing.expectEqual(12, entry.comments.count);
        try std.testing.expectEqual(0, entry.comments.start);
        try std.testing.expectEqual(10, entry.comments.comments.len);
        try std.testing.expectEqualStrings("a comment", entry.comments.comments[0].comment.event.body);
    }
    {
        const entry = try (domain.GetIssue{ .repo = "alice:open", .id = issue_hex, .comments_from = 10 }).run(&ctx);
        try std.testing.expectEqual(10, entry.comments.start);
        try std.testing.expectEqual(2, entry.comments.comments.len);
    }
}

test "domain: GetIssue reads a closed issue and finds no unknown one" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addEvent(server.secret, Server.alice_author, issue, .{ .issue = .{ .title = "closed", .description = "", .labels = "", .status = .closed } });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var bob = try server.ctx(&arena, server.bob);
    const entry = try (domain.GetIssue{ .repo = "alice:secret", .id = issue_hex }).run(&bob);
    try std.testing.expectEqual(.closed, entry.record.event.status);
    for ([_][]const u8{ "22222222222222222222222222222222", "not an id", "" }) |id| {
        try std.testing.expectError(error.NotFound, (domain.GetIssue{ .repo = "alice:secret", .id = id }).run(&bob));
    }
    // a repo the viewer can't see has no issues
    for ([_]?fixture.Id{ server.carol, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.NotFound, (domain.GetIssue{ .repo = "alice:secret", .id = issue_hex }).run(&ctx));
    }
}
