const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

const alices: fixture.Id = @splat(0xa1);
const alices_hex = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";

test "domain: Subscribe and Mute change who a thread notifies" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);

    try std.testing.expect(!try server.isNotified(server.open, alices, server.carol));
    try (domain.Subscribe{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex }).run(&carol);
    try std.testing.expect(try server.isNotified(server.open, alices, server.carol));
    try (domain.Mute{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex }).run(&carol);
    try std.testing.expect(!try server.isNotified(server.open, alices, server.carol));
    try (domain.Subscribe{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex }).run(&carol);
    try std.testing.expect(try server.isNotified(server.open, alices, server.carol));
    // the author, subscribed by writing it, is still notified
    try std.testing.expect(try server.isNotified(server.open, alices, server.alice));
}

test "domain: Subscribe and Mute need a login, a repo the user can see and a thread of the kind" {
    const server = try Server.init(.sha256);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    try server.addIssue(server.secret, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.Subscribe{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex }).run(&ctx));
        try std.testing.expectError(error.LoginRequired, (domain.Mute{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex }).run(&ctx));
    }
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectError(error.NotFound, (domain.Subscribe{ .repo = "alice:secret", .kind = .issue, .thread_id = alices_hex }).run(&carol));
    try std.testing.expect(!try server.isNotified(server.secret, alices, server.carol));

    const cases = [_]struct { domain.ThreadKind, []const u8 }{
        .{ .issue, "22222222222222222222222222222222" },
        .{ .issue, "not an id" },
        .{ .discuss, alices_hex },
    };
    for (cases) |case| {
        try std.testing.expectError(error.NotFound, (domain.Subscribe{ .repo = "alice:open", .kind = case[0], .thread_id = case[1] }).run(&carol));
        try std.testing.expectError(error.NotFound, (domain.Mute{ .repo = "alice:open", .kind = case[0], .thread_id = case[1] }).run(&carol));
    }
    try std.testing.expect(!try server.isNotified(server.open, @splat(0x22), server.carol));
}

fn expectLocalUnavailable(comptime kind: hx.xit.repo.RepoKind) !void {
    var local = try fixture.Local(kind, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    try local.addEvent(Server.alice_author, alices, .{ .issue = .{ .title = "fetched", .description = "", .labels = "" } });
    try std.testing.expectError(error.UnavailableHere, (domain.Subscribe{ .repo = "", .kind = .issue, .thread_id = alices_hex }).run(&ctx));
    try std.testing.expectError(error.UnavailableHere, (domain.Mute{ .repo = "", .kind = .issue, .thread_id = alices_hex }).run(&ctx));
}

test "domain: Subscribe and Mute are unavailable in local mode, which has no accounts" {
    try expectLocalUnavailable(.git);
    try expectLocalUnavailable(.xit);
}

test "domain: Subscribe needs only to read a thread, in a tab that is on" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);

    // a reader may follow issues only writers may change, as its button shows
    try server.setTabs(server.open, .read, .write, null);
    try (domain.Subscribe{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex }).run(&carol);
    try std.testing.expect(try server.isNotified(server.open, alices, server.carol));

    // a tab that is off doesn't exist
    try server.setTabs(server.open, .read, null, null);
    try std.testing.expectError(error.NotFound, (domain.Mute{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex }).run(&carol));
    try std.testing.expect(try server.isNotified(server.open, alices, server.carol));
}
