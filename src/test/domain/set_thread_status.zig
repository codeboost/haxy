const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const io = std.testing.io;
const allocator = std.testing.allocator;
const Server = fixture.Server;

const alices: fixture.Id = @splat(0xa1);
const alices_hex = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const carols: fixture.Id = @splat(0xc1);
const carols_hex = "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1";

test "domain: SetThreadStatus closes and reopens an issue" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    try (domain.SetThreadStatus{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .status = .closed }).run(&bob);
    try std.testing.expectEqual(0, (try (domain.ListIssues{ .repo = "alice:open" }).run(&bob)).count);
    const closed = try (domain.ListIssues{ .repo = "alice:open", .status = .closed }).run(&bob);
    try std.testing.expectEqual(1, closed.count);
    try std.testing.expectEqualStrings(alices_hex, closed.items[0].id);

    try (domain.SetThreadStatus{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .status = .open }).run(&bob);
    try std.testing.expectEqual(.open, (try (domain.GetIssue{ .repo = "alice:open", .id = alices_hex }).run(&bob)).record.event.status);
}

test "domain: SetThreadStatus lets a writer change any issue and a reader only their own" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    try server.addIssue(server.open, Server.carol_author, carols);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectError(error.Forbidden, (domain.SetThreadStatus{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .status = .closed }).run(&carol));
    try (domain.SetThreadStatus{ .repo = "alice:open", .kind = .issue, .thread_id = carols_hex, .status = .closed }).run(&carol);
    {
        const closed = try (domain.ListIssues{ .repo = "alice:open", .status = .closed }).run(&carol);
        try std.testing.expectEqual(1, closed.count);
        try std.testing.expectEqualStrings(carols_hex, closed.items[0].id);
    }

    var bob = try server.ctx(&arena, server.bob);
    try (domain.SetThreadStatus{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .status = .closed }).run(&bob);
    try std.testing.expectEqual(2, (try (domain.ListIssues{ .repo = "alice:open", .status = .closed }).run(&bob)).count);
}

test "domain: SetThreadStatus needs a login, the tab's role, a repo the user can see and a thread with a status" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.carol_author, carols);
    try server.addIssue(server.secret, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.SetThreadStatus{ .repo = "alice:open", .kind = .issue, .thread_id = carols_hex, .status = .closed }).run(&ctx));
    }
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectError(error.NotFound, (domain.SetThreadStatus{ .repo = "alice:secret", .kind = .issue, .thread_id = alices_hex, .status = .closed }).run(&carol));

    // a writer finds no unknown issue; a reader may change no issue they didn't write
    var bob = try server.ctx(&arena, server.bob);
    for ([_][]const u8{ "22222222222222222222222222222222", "not an id" }) |id| {
        try std.testing.expectError(error.NotFound, (domain.SetThreadStatus{ .repo = "alice:secret", .kind = .issue, .thread_id = id, .status = .closed }).run(&bob));
    }
    try std.testing.expectError(error.Forbidden, (domain.SetThreadStatus{ .repo = "alice:open", .kind = .issue, .thread_id = "22222222222222222222222222222222", .status = .closed }).run(&carol));

    // discussions have no status, like the web's status route
    const discussion = try (domain.CreateThread{ .repo = "alice:secret", .kind = .discuss, .title = "talk" }).run(&bob);
    try std.testing.expectError(error.NotFound, (domain.SetThreadStatus{ .repo = "alice:secret", .kind = .discuss, .thread_id = &discussion.id, .status = .closed }).run(&bob));

    // only writers may write to the public repo's issues, even their own
    try evt.updateRepo(io, allocator, server.users_dir, &server.alice, Server.alice_author, "open", "open", "", .public, .read, .write, null);
    try std.testing.expectError(error.Forbidden, (domain.SetThreadStatus{ .repo = "alice:open", .kind = .issue, .thread_id = carols_hex, .status = .closed }).run(&carol));
    try std.testing.expectEqual(1, (try (domain.ListIssues{ .repo = "alice:open" }).run(&carol)).count);
}

fn expectLocalStatus(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    // written by someone else, which the local owner may still close
    try local.addEvent(Server.alice_author, alices, .{ .issue = .{ .title = "fetched", .description = "", .labels = "" } });
    try (domain.SetThreadStatus{ .repo = "", .kind = .issue, .thread_id = alices_hex, .status = .closed }).run(&ctx);
    try std.testing.expectEqual(.closed, (try (domain.GetIssue{ .repo = "", .id = alices_hex }).run(&ctx)).record.event.status);
}

test "domain: SetThreadStatus closes an issue in a local git or xit repo" {
    try expectLocalStatus(.git, .sha1);
    try expectLocalStatus(.git, .sha256);
    try expectLocalStatus(.xit, .sha1);
    try expectLocalStatus(.xit, .sha256);
}
