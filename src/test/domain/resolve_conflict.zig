const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

const issue: fixture.Id = @splat(0x11);
const issue_hex = "11111111111111111111111111111111";

test "domain: ResolveConflict settles a conflicted issue with the chosen fields" {
    var local = try fixture.Local(.xit, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    try local.conflictIssueLabels(issue, "ours", "theirs");
    try std.testing.expect((try (domain.GetIssue{ .repo = "", .id = issue_hex }).run(&ctx)).conflicted);

    // an invalid field leaves the conflict for another try
    try std.testing.expectError(error.InvalidTitle, (domain.ResolveConflict{ .repo = "", .kind = .issue, .thread_id = issue_hex, .title = " " }).run(&ctx));
    try std.testing.expectError(error.InvalidLabels, (domain.ResolveConflict{ .repo = "", .kind = .issue, .thread_id = issue_hex, .labels = &@as([65]u8, @splat('x')) }).run(&ctx));
    try std.testing.expect((try (domain.GetIssue{ .repo = "", .id = issue_hex }).run(&ctx)).conflicted);

    try (domain.ResolveConflict{ .repo = "", .kind = .issue, .thread_id = issue_hex, .labels = "chosen" }).run(&ctx);
    const entry = try (domain.GetIssue{ .repo = "", .id = issue_hex }).run(&ctx);
    try std.testing.expect(!entry.conflicted);
    try std.testing.expectEqualStrings("chosen", entry.record.event.labels);
    try std.testing.expectEqualStrings("an issue", entry.record.event.title);
}

test "domain: ResolveConflict needs a login, the write role, a known thread and a thread kind with conflicts" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, issue);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.ResolveConflict{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex }).run(&ctx));
    }
    // resolving takes writers, even on a thread the user may edit
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectError(error.Forbidden, (domain.ResolveConflict{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex }).run(&carol));
    try std.testing.expectError(error.NotFound, (domain.ResolveConflict{ .repo = "alice:secret", .kind = .issue, .thread_id = issue_hex }).run(&carol));
    var bob = try server.ctx(&arena, server.bob);
    for ([_][]const u8{ "22222222222222222222222222222222", "not an id" }) |id| {
        try std.testing.expectError(error.NotFound, (domain.ResolveConflict{ .repo = "alice:open", .kind = .issue, .thread_id = id }).run(&bob));
    }
    // a missing thread is missing, whatever its fields
    try std.testing.expectError(error.NotFound, (domain.ResolveConflict{ .repo = "alice:open", .kind = .issue, .thread_id = "22222222222222222222222222222222", .title = " " }).run(&bob));
    try std.testing.expectError(error.NotFound, (domain.ResolveConflict{ .repo = "alice:open", .kind = .patch, .thread_id = "22222222222222222222222222222222", .labels = &@as([65]u8, @splat('x')) }).run(&bob));
    // discussions merge without field conflicts
    try std.testing.expectError(error.NotFound, (domain.ResolveConflict{ .repo = "alice:open", .kind = .discuss, .thread_id = issue_hex }).run(&bob));
}
