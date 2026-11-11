const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const io = std.testing.io;
const allocator = std.testing.allocator;
const Server = fixture.Server;

test "domain: CreateThread opens an issue a reader can read back" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var carol = try server.ctx(&arena, server.carol);
    const created = try (domain.CreateThread{ .repo = "alice:open", .kind = .issue, .title = "it breaks", .labels = "bug ui", .body = "steps\nto reproduce" }).run(&carol);

    var alice = try server.ctx(&arena, server.alice);
    const entry = try (domain.GetIssue{ .repo = "alice:open", .id = &created.id }).run(&alice);
    try std.testing.expectEqualStrings("it breaks", entry.record.event.title);
    try std.testing.expectEqualStrings("bug ui", entry.record.event.labels);
    try std.testing.expectEqualStrings("steps\nto reproduce", entry.record.event.description);
    try std.testing.expectEqual(.open, entry.record.event.status);
    try std.testing.expectEqualStrings("carol@example.test", entry.record.author_email.?);
}

test "domain: CreateThread refuses a blank title and an overlong label" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    for ([_]domain.ThreadKind{ .issue, .discuss }) |kind| {
        for ([_][]const u8{ "", "  \t\r\n" }) |title| {
            try std.testing.expectError(error.InvalidTitle, (domain.CreateThread{ .repo = "alice:open", .kind = kind, .title = title }).run(&bob));
        }
        // 65 bytes, one more than a label may hold
        const long_label = "ok " ++ @as([65]u8, @splat('x'));
        try std.testing.expectError(error.InvalidLabels, (domain.CreateThread{ .repo = "alice:open", .kind = kind, .title = "a title", .labels = long_label }).run(&bob));
    }
    // nothing was written
    try std.testing.expectEqual(0, (try (domain.ListIssues{ .repo = "alice:open" }).run(&bob)).count);
}

test "domain: CreateThread needs a login, the tab's role and a repo the user can see" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.CreateThread{ .repo = "alice:open", .kind = .issue, .title = "t" }).run(&ctx));
    }
    var carol = try server.ctx(&arena, server.carol);
    for ([_][]const u8{ "alice:secret", "alice:missing", "alice" }) |identity| {
        try std.testing.expectError(error.NotFound, (domain.CreateThread{ .repo = identity, .kind = .issue, .title = "t" }).run(&carol));
    }
    // only writers may open issues on the public repo; bob is one
    try evt.updateRepo(io, allocator, server.users_dir, &server.alice, Server.alice_author, "open", "open", "", .public, .read, .write, null);
    try std.testing.expectError(error.Forbidden, (domain.CreateThread{ .repo = "alice:open", .kind = .issue, .title = "t" }).run(&carol));
    // discussions still take readers
    _ = try (domain.CreateThread{ .repo = "alice:open", .kind = .discuss, .title = "t" }).run(&carol);
    var bob = try server.ctx(&arena, server.bob);
    _ = try (domain.CreateThread{ .repo = "alice:open", .kind = .issue, .title = "t" }).run(&bob);
    try std.testing.expectEqual(1, (try (domain.ListIssues{ .repo = "alice:open" }).run(&bob)).count);
}

test "domain: CreateThread leaves patches for later" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    try std.testing.expectError(error.UnavailableHere, (domain.CreateThread{ .repo = "", .kind = .patch, .title = "a patch" }).run(&ctx));
}

fn expectLocalCreate(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    try local.setAuthor(.{ .name = "Ada", .email = "ada@example.test" });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    const created = try (domain.CreateThread{ .repo = "", .kind = .issue, .title = "local issue", .labels = "x" }).run(&ctx);
    const entry = try (domain.GetIssue{ .repo = "", .id = &created.id }).run(&ctx);
    try std.testing.expectEqualStrings("local issue", entry.record.event.title);
    try std.testing.expectEqualStrings("x", entry.record.event.labels);
    // authored from the repo's config
    try std.testing.expectEqualStrings("ada@example.test", entry.record.author_email.?);
}

test "domain: CreateThread opens an issue in a local git or xit repo" {
    try expectLocalCreate(.git, .sha1);
    try expectLocalCreate(.git, .sha256);
    try expectLocalCreate(.xit, .sha1);
    try expectLocalCreate(.xit, .sha256);
}

test "domain: a local git write committed but not consumed is classified as changed" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    // a directory where the event db would go, so consuming fails after the commit
    try local.temp.dir.createDirPath(io, ".git/haxy");
    const result = blk: {
        // the expected failure logs a warning
        const log_level = std.testing.log_level;
        std.testing.log_level = .err;
        defer std.testing.log_level = log_level;
        break :blk (domain.CreateThread{ .repo = "", .kind = .issue, .title = "committed" }).run(&ctx);
    };
    try std.testing.expectError(error.CommittedUnconsumed, result);
    const failure = domain.classify(error.CommittedUnconsumed);
    try std.testing.expectEqual(.internal, failure.kind);
    try std.testing.expect(failure.changed);
    try std.testing.expect(!failure.retryable);

    // the issue was written: once the db can be created, a refresh reads it
    try local.temp.dir.deleteDir(io, ".git/haxy");
    try (domain.RefreshLocal{}).run(&ctx);
    const window = try (domain.ListIssues{ .repo = "" }).run(&ctx);
    try std.testing.expectEqual(1, window.count);
    try std.testing.expectEqualStrings("committed", window.items[0].record.event.title);
}
