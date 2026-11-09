const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const io = std.testing.io;
const allocator = std.testing.allocator;
const Server = fixture.Server;

const issue: fixture.Id = @splat(0x11);
const issue_hex = "11111111111111111111111111111111";

test "domain: CreateComment replies to an issue and to a comment" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, issue);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);

    const reply = try (domain.CreateComment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .body = "me too" }).run(&carol);
    var bob = try server.ctx(&arena, server.bob);
    const nested = try (domain.CreateComment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .parent_id = &reply.id, .body = "which version?" }).run(&bob);

    const entry = try (domain.GetIssue{ .repo = "alice:open", .id = issue_hex }).run(&carol);
    try std.testing.expectEqual(2, entry.comments.count);
    const comments = entry.comments.comments;
    try std.testing.expectEqualStrings(&reply.id, &comments[0].id);
    try std.testing.expectEqualStrings("me too", comments[0].comment.event.body);
    try std.testing.expectEqualStrings(issue_hex, &comments[0].comment.event.parent_id);
    try std.testing.expectEqualStrings("carol@example.test", comments[0].comment.author_email.?);
    try std.testing.expectEqualStrings(&nested.id, &comments[1].id);
    try std.testing.expectEqualStrings("which version?", comments[1].comment.event.body);
    try std.testing.expectEqualStrings(&reply.id, &comments[1].comment.event.parent_id);
}

test "domain: CreateComment refuses an empty body" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, issue);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);

    try std.testing.expectError(error.InvalidBody, (domain.CreateComment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .body = "" }).run(&carol));
    try std.testing.expectEqual(0, (try (domain.GetIssue{ .repo = "alice:open", .id = issue_hex }).run(&carol)).comments.count);
}

test "domain: CreateComment finds no unknown thread or parent" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, issue);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);

    const missing = "22222222222222222222222222222222";
    for ([_][]const u8{ missing, "not an id", "", "1111111111111111111111111111111z" }) |thread_id| {
        try std.testing.expectError(error.NotFound, (domain.CreateComment{ .repo = "alice:open", .kind = .issue, .thread_id = thread_id, .body = "b" }).run(&carol));
    }
    for ([_][]const u8{ missing, "not an id" }) |parent_id| {
        try std.testing.expectError(error.NotFound, (domain.CreateComment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .parent_id = parent_id, .body = "b" }).run(&carol));
    }
    // the thread is an issue, not a discussion
    try std.testing.expectError(error.NotFound, (domain.CreateComment{ .repo = "alice:open", .kind = .discuss, .thread_id = issue_hex, .body = "b" }).run(&carol));
    try std.testing.expectEqual(0, (try (domain.GetIssue{ .repo = "alice:open", .id = issue_hex }).run(&carol)).comments.count);
}

test "domain: CreateComment needs a login, the tab's role and a repo the user can see" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, issue);
    try server.addIssue(server.secret, Server.alice_author, issue);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.CreateComment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .body = "b" }).run(&ctx));
    }
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectError(error.NotFound, (domain.CreateComment{ .repo = "alice:secret", .kind = .issue, .thread_id = issue_hex, .body = "b" }).run(&carol));
    // only writers may write to the public repo's issues
    try evt.updateRepo(io, allocator, server.users_dir, &server.alice, Server.alice_author, "open", "open", "", .public, .read, .write, null);
    try std.testing.expectError(error.Forbidden, (domain.CreateComment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .body = "b" }).run(&carol));
    var bob = try server.ctx(&arena, server.bob);
    _ = try (domain.CreateComment{ .repo = "alice:secret", .kind = .issue, .thread_id = issue_hex, .body = "b" }).run(&bob);
    try std.testing.expectEqual(1, (try (domain.GetIssue{ .repo = "alice:secret", .id = issue_hex }).run(&bob)).comments.count);
}

test "domain: CreateThread opens a discussion that takes comments" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);

    const created = try (domain.CreateThread{ .repo = "alice:open", .kind = .discuss, .title = "ideas" }).run(&carol);
    // a comment's thread must exist as a discussion, which reads it back
    _ = try (domain.CreateComment{ .repo = "alice:open", .kind = .discuss, .thread_id = &created.id, .body = "one" }).run(&carol);
    try std.testing.expectError(error.NotFound, (domain.CreateComment{ .repo = "alice:open", .kind = .issue, .thread_id = &created.id, .body = "one" }).run(&carol));
    // and it is no issue
    try std.testing.expectEqual(0, (try (domain.ListIssues{ .repo = "alice:open" }).run(&carol)).count);
}

fn expectLocalComment(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    const created = try (domain.CreateThread{ .repo = "", .kind = .issue, .title = "local" }).run(&ctx);
    const comment = try (domain.CreateComment{ .repo = "", .kind = .issue, .thread_id = &created.id, .body = "local reply" }).run(&ctx);
    const entry = try (domain.GetIssue{ .repo = "", .id = &created.id }).run(&ctx);
    try std.testing.expectEqual(1, entry.comments.count);
    try std.testing.expectEqualStrings(&comment.id, &entry.comments.comments[0].id);
    try std.testing.expectEqualStrings("local reply", entry.comments.comments[0].comment.event.body);
}

test "domain: CreateComment replies in a local git or xit repo" {
    try expectLocalComment(.git, .sha1);
    try expectLocalComment(.git, .sha256);
    try expectLocalComment(.xit, .sha1);
    try expectLocalComment(.xit, .sha256);
}
