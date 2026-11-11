const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

const issue: fixture.Id = @splat(0x11);
const issue_hex = "11111111111111111111111111111111";
const alices: fixture.Id = @splat(0xa1);
const alices_hex = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const carols: fixture.Id = @splat(0xc1);
const carols_hex = "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1";

test "domain: RemoveThread removes an issue from its list" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    try server.addIssue(server.open, Server.alice_author, issue);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    try std.testing.expectEqual(.thread, try (domain.RemoveThread{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex }).run(&bob));
    const open = try (domain.ListIssues{ .repo = "alice:open" }).run(&bob);
    try std.testing.expectEqual(1, open.count);
    try std.testing.expectEqualStrings(issue_hex, open.items[0].id);
    try std.testing.expectError(error.NotFound, (domain.GetIssue{ .repo = "alice:open", .id = alices_hex }).run(&bob));
}

test "domain: RemoveThread lets a writer remove any thread and a reader only their own" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    try server.addIssue(server.open, Server.carol_author, carols);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);

    try std.testing.expectError(error.Forbidden, (domain.RemoveThread{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex }).run(&carol));
    try std.testing.expectEqual(.thread, try (domain.RemoveThread{ .repo = "alice:open", .kind = .issue, .thread_id = carols_hex }).run(&carol));
    const open = try (domain.ListIssues{ .repo = "alice:open" }).run(&carol);
    try std.testing.expectEqual(1, open.count);
    try std.testing.expectEqualStrings(alices_hex, open.items[0].id);
}

test "domain: RemoveComment leaves a removed comment in its thread's window" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, issue);
    try server.addComment(server.open, Server.alice_author, alices, issue, "alice says");
    try server.addComment(server.open, Server.carol_author, carols, issue, "carol says");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);

    try std.testing.expectError(error.Forbidden, (domain.RemoveComment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .comment_id = alices_hex }).run(&carol));
    try (domain.RemoveComment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .comment_id = carols_hex }).run(&carol);
    var bob = try server.ctx(&arena, server.bob);
    try (domain.RemoveComment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .comment_id = alices_hex }).run(&bob);

    const entry = try (domain.GetIssue{ .repo = "alice:open", .id = issue_hex }).run(&bob);
    try std.testing.expectEqual(2, entry.comments.count);
    for (entry.comments.comments, [_][]const u8{ alices_hex, carols_hex }) |comment, id| {
        try std.testing.expectEqualStrings(id, &comment.id);
        try std.testing.expect(comment.comment.removed);
    }
}

test "domain: RemoveAttachment removes a file from its thread" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, issue);
    const alices_file = try server.addAttachment(server.open, Server.alice_author, .issue, issue);
    const carols_file = try server.addAttachment(server.open, Server.carol_author, .issue, issue);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);

    try std.testing.expectError(error.Forbidden, (domain.RemoveAttachment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .attachment_id = &alices_file }).run(&carol));
    try (domain.RemoveAttachment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .attachment_id = &carols_file }).run(&carol);
    {
        const attachments = (try (domain.GetIssue{ .repo = "alice:open", .id = issue_hex }).run(&carol)).attachments;
        try std.testing.expectEqual(1, attachments.len);
        try std.testing.expectEqualStrings(&alices_file, &attachments[0].id);
    }
    var bob = try server.ctx(&arena, server.bob);
    try (domain.RemoveAttachment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .attachment_id = &alices_file }).run(&bob);
    try std.testing.expectEqual(0, (try (domain.GetIssue{ .repo = "alice:open", .id = issue_hex }).run(&bob)).attachments.len);
}

test "domain: removals need a login, the tab's role, a repo the user can see and an event in the thread" {
    const server = try Server.init(.sha256);
    defer server.deinit();
    const other: fixture.Id = @splat(0x22);
    const other_hex = "22222222222222222222222222222222";
    try server.addIssue(server.open, Server.carol_author, issue);
    try server.addIssue(server.open, Server.alice_author, other);
    try server.addComment(server.open, Server.carol_author, carols, issue, "carol says");
    const file = try server.addAttachment(server.open, Server.carol_author, .issue, issue);
    try server.addIssue(server.secret, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.RemoveThread{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex }).run(&ctx));
        try std.testing.expectError(error.LoginRequired, (domain.RemoveComment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .comment_id = carols_hex }).run(&ctx));
        try std.testing.expectError(error.LoginRequired, (domain.RemoveAttachment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .attachment_id = &file }).run(&ctx));
    }
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectError(error.NotFound, (domain.RemoveThread{ .repo = "alice:secret", .kind = .issue, .thread_id = alices_hex }).run(&carol));

    // a writer finds no unknown event, none on another thread and none of another kind
    var bob = try server.ctx(&arena, server.bob);
    try std.testing.expectError(error.NotFound, (domain.RemoveThread{ .repo = "alice:open", .kind = .issue, .thread_id = carols_hex }).run(&bob));
    try std.testing.expectError(error.NotFound, (domain.RemoveThread{ .repo = "alice:open", .kind = .discuss, .thread_id = issue_hex }).run(&bob));
    try std.testing.expectError(error.NotFound, (domain.RemoveThread{ .repo = "alice:open", .kind = .issue, .thread_id = "not an id" }).run(&bob));
    try std.testing.expectError(error.NotFound, (domain.RemoveComment{ .repo = "alice:open", .kind = .issue, .thread_id = other_hex, .comment_id = carols_hex }).run(&bob));
    try std.testing.expectError(error.NotFound, (domain.RemoveComment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .comment_id = &file }).run(&bob));
    try std.testing.expectError(error.NotFound, (domain.RemoveAttachment{ .repo = "alice:open", .kind = .issue, .thread_id = other_hex, .attachment_id = &file }).run(&bob));
    try std.testing.expectError(error.NotFound, (domain.RemoveAttachment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .attachment_id = carols_hex }).run(&bob));
    {
        const entry = try (domain.GetIssue{ .repo = "alice:open", .id = issue_hex }).run(&bob);
        try std.testing.expect(!entry.comments.comments[0].comment.removed);
        try std.testing.expectEqual(1, entry.attachments.len);
    }

    // only writers may write to the public repo's issues, even their own
    try server.setTabs(server.open, .read, .write, null);
    try std.testing.expectError(error.Forbidden, (domain.RemoveThread{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex }).run(&carol));
    try std.testing.expectError(error.Forbidden, (domain.RemoveComment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .comment_id = carols_hex }).run(&carol));
    try std.testing.expectError(error.Forbidden, (domain.RemoveAttachment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .attachment_id = &file }).run(&carol));
}

fn expectLocalRemove(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    // written by someone else, which the local owner may still remove
    try local.addEvent(Server.alice_author, issue, .{ .issue = .{ .title = "fetched", .description = "", .labels = "" } });
    try local.addEvent(Server.alice_author, alices, .{ .comment = .{ .thread_id = issue_hex.*, .parent_id = issue_hex.*, .body = "fetched" } });
    try (domain.RemoveComment{ .repo = "", .kind = .issue, .thread_id = issue_hex, .comment_id = alices_hex }).run(&ctx);
    try std.testing.expect((try (domain.GetIssue{ .repo = "", .id = issue_hex }).run(&ctx)).comments.comments[0].comment.removed);
    var reader = std.Io.Reader.fixed("hello\n");
    const attached = try (domain.Attach{ .repo = "", .kind = .issue, .thread_id = issue_hex, .name = "notes.txt", .size = 6, .reader = &reader }).run(&ctx);
    try (domain.RemoveAttachment{ .repo = "", .kind = .issue, .thread_id = issue_hex, .attachment_id = &attached.id }).run(&ctx);
    try std.testing.expectEqual(0, (try (domain.GetIssue{ .repo = "", .id = issue_hex }).run(&ctx)).attachments.len);
    try std.testing.expectEqual(.thread, try (domain.RemoveThread{ .repo = "", .kind = .issue, .thread_id = issue_hex }).run(&ctx));
    try std.testing.expectEqual(0, (try (domain.ListIssues{ .repo = "" }).run(&ctx)).count);
}

test "domain: removals work in a local git or xit repo" {
    try expectLocalRemove(.git, .sha1);
    try expectLocalRemove(.git, .sha256);
    try expectLocalRemove(.xit, .sha1);
    try expectLocalRemove(.xit, .sha256);
}
