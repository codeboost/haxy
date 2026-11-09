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

// the body of the issue's only comment
fn commentBody(ctx: *domain.Ctx, index: usize) ![]const u8 {
    const entry = try (domain.GetIssue{ .repo = "alice:open", .id = issue_hex }).run(ctx);
    return entry.comments.comments[index].comment.event.body;
}

test "domain: EditComment replaces a comment's body" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, issue);
    try server.addComment(server.open, Server.alice_author, alices, issue, "first");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    try (domain.EditComment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .comment_id = alices_hex, .body = "second" }).run(&bob);
    try std.testing.expectEqualStrings("second", try commentBody(&bob, 0));
}

test "domain: EditComment lets a writer edit any comment and a reader only their own" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, issue);
    try server.addComment(server.open, Server.alice_author, alices, issue, "alice says");
    try server.addComment(server.open, Server.carol_author, carols, issue, "carol says");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);

    // a comment the reader may not edit is refused before its new body is checked
    for ([_][]const u8{ "carol was here", "" }) |body| {
        try std.testing.expectError(error.Forbidden, (domain.EditComment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .comment_id = alices_hex, .body = body }).run(&carol));
    }
    try std.testing.expectEqualStrings("alice says", try commentBody(&carol, 0));
    try (domain.EditComment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .comment_id = carols_hex, .body = "carol said" }).run(&carol);
    try std.testing.expectEqualStrings("carol said", try commentBody(&carol, 1));
}

test "domain: EditComment refuses an empty body" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, issue);
    try server.addComment(server.open, Server.carol_author, carols, issue, "carol says");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);

    try std.testing.expectError(error.InvalidBody, (domain.EditComment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .comment_id = carols_hex, .body = "" }).run(&carol));
    try std.testing.expectEqualStrings("carol says", try commentBody(&carol, 0));
}

test "domain: EditComment needs a login, the tab's role, a repo the user can see and a comment on the thread" {
    const server = try Server.init(.sha256);
    defer server.deinit();
    const other: fixture.Id = @splat(0x22);
    const other_hex = "22222222222222222222222222222222";
    try server.addIssue(server.open, Server.alice_author, issue);
    try server.addIssue(server.open, Server.alice_author, other);
    try server.addComment(server.open, Server.carol_author, carols, issue, "carol says");
    try server.addIssue(server.secret, Server.alice_author, issue);
    try server.addComment(server.secret, Server.alice_author, alices, issue, "secret");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.EditComment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .comment_id = carols_hex, .body = "b" }).run(&ctx));
    }
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectError(error.NotFound, (domain.EditComment{ .repo = "alice:secret", .kind = .issue, .thread_id = issue_hex, .comment_id = alices_hex, .body = "b" }).run(&carol));

    // a writer finds no unknown comment, none on another thread and none on a thread of another kind
    var bob = try server.ctx(&arena, server.bob);
    const cases = [_]struct { domain.ThreadKind, []const u8, []const u8 }{
        .{ .issue, issue_hex, alices_hex },
        .{ .issue, issue_hex, "not an id" },
        .{ .issue, other_hex, carols_hex },
        .{ .issue, "not an id", carols_hex },
        .{ .discuss, issue_hex, carols_hex },
    };
    for (cases) |case| {
        try std.testing.expectError(error.NotFound, (domain.EditComment{ .repo = "alice:open", .kind = case[0], .thread_id = case[1], .comment_id = case[2], .body = "b" }).run(&bob));
    }
    try std.testing.expectEqualStrings("carol says", try commentBody(&bob, 0));

    // only writers may write to the public repo's issues, even their own
    try server.setTabs(server.open, .read, .write, null);
    try std.testing.expectError(error.Forbidden, (domain.EditComment{ .repo = "alice:open", .kind = .issue, .thread_id = issue_hex, .comment_id = carols_hex, .body = "b" }).run(&carol));
}

fn expectLocalCommentEdit(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    try local.addEvent(Server.alice_author, issue, .{ .issue = .{ .title = "fetched", .description = "", .labels = "" } });
    try local.addEvent(Server.alice_author, alices, .{ .comment = .{ .thread_id = issue_hex.*, .parent_id = issue_hex.*, .body = "fetched" } });
    try (domain.EditComment{ .repo = "", .kind = .issue, .thread_id = issue_hex, .comment_id = alices_hex, .body = "edited here" }).run(&ctx);
    const entry = try (domain.GetIssue{ .repo = "", .id = issue_hex }).run(&ctx);
    try std.testing.expectEqualStrings("edited here", entry.comments.comments[0].comment.event.body);
}

test "domain: EditComment edits a comment in a local git or xit repo" {
    try expectLocalCommentEdit(.git, .sha1);
    try expectLocalCommentEdit(.git, .sha256);
    try expectLocalCommentEdit(.xit, .sha1);
    try expectLocalCommentEdit(.xit, .sha256);
}
