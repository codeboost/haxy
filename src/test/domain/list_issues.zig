const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

const first: fixture.Id = @splat(0x11);
const first_hex = "11111111111111111111111111111111";
const second: fixture.Id = @splat(0x22);
const second_hex = "22222222222222222222222222222222";

test "domain: ListIssues lists a repo's open issues, newest first" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addEvent(server.open, Server.alice_author, first, .{ .issue = .{ .title = "first", .description = "", .labels = "" } });
    try server.addEvent(server.open, Server.bob_author, second, .{ .issue = .{ .title = "second", .description = "", .labels = "" } });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = try server.ctx(&arena, server.carol);
    const window = try (domain.ListIssues{ .repo = "alice:open" }).run(&ctx);
    try std.testing.expectEqual(2, window.count);
    try std.testing.expectEqual(2, window.items.len);
    try std.testing.expectEqualStrings(second_hex, window.items[0].id);
    try std.testing.expectEqualStrings("second", window.items[0].record.event.title);
    try std.testing.expectEqualStrings(first_hex, window.items[1].id);
    try std.testing.expectEqualStrings("first", window.items[1].record.event.title);
}

test "domain: ListIssues tells the viewer which issues they may change" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addEvent(server.open, Server.alice_author, first, .{ .issue = .{ .title = "alice's", .description = "", .labels = "" } });
    try server.addEvent(server.open, Server.carol_author, second, .{ .issue = .{ .title = "carol's", .description = "", .labels = "" } });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // a writer may change any issue
    {
        var ctx = try server.ctx(&arena, server.bob);
        const window = try (domain.ListIssues{ .repo = "alice:open" }).run(&ctx);
        try std.testing.expect(window.items[0].can_modify);
        try std.testing.expect(window.items[1].can_modify);
    }
    // a reader only their own
    {
        var ctx = try server.ctx(&arena, server.carol);
        const window = try (domain.ListIssues{ .repo = "alice:open" }).run(&ctx);
        try std.testing.expectEqualStrings("carol's", window.items[0].record.event.title);
        try std.testing.expect(window.items[0].can_modify);
        try std.testing.expect(!window.items[1].can_modify);
    }
    // a logged-out viewer none
    {
        var ctx = try server.ctx(&arena, null);
        const window = try (domain.ListIssues{ .repo = "alice:open" }).run(&ctx);
        try std.testing.expect(!window.items[0].can_modify);
        try std.testing.expect(!window.items[1].can_modify);
    }
}

test "domain: ListIssues finds no repo the viewer can't see and no tab that is off" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.secret, Server.alice_author, first);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.carol, server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.NotFound, (domain.ListIssues{ .repo = "alice:secret" }).run(&ctx));
    }
    {
        var ctx = try server.ctx(&arena, server.alice);
        for ([_][]const u8{ "alice:missing", "alice", "" }) |identity| {
            try std.testing.expectError(error.NotFound, (domain.ListIssues{ .repo = identity }).run(&ctx));
        }
    }
    // with the issue tab off, the issues don't exist even to the owner
    try evt.updateRepo(std.testing.io, allocator, server.users_dir, &server.alice, Server.alice_author, "secret", "secret", "", .private, .read, null, null);
    var ctx = try server.ctx(&arena, server.alice);
    try std.testing.expectError(error.NotFound, (domain.ListIssues{ .repo = "alice:secret" }).run(&ctx));
}

test "domain: ListIssues searches with the decoded text as given" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    // "%41" would decode to "A", so a search for the first label must not be decoded again
    try server.addEvent(server.open, Server.alice_author, first, .{ .issue = .{ .title = "café ouvert", .description = "", .labels = "50%41off" } });
    try server.addEvent(server.open, Server.alice_author, second, .{ .issue = .{ .title = "cafe closed", .description = "", .labels = "50Aoff" } });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    {
        const window = try (domain.ListIssues{ .repo = "alice:open", .search = "label:50%41off" }).run(&ctx);
        try std.testing.expectEqual(1, window.count);
        try std.testing.expectEqualStrings(first_hex, window.items[0].id);
    }
    {
        const window = try (domain.ListIssues{ .repo = "alice:open", .search = "café" }).run(&ctx);
        try std.testing.expectEqual(1, window.count);
        try std.testing.expectEqualStrings(first_hex, window.items[0].id);
    }
}

test "domain: ListIssues lists one status from the named issue on" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    const third: fixture.Id = @splat(0x33);
    const closed: fixture.Id = @splat(0x44);
    try server.addEvent(server.open, Server.alice_author, first, .{ .issue = .{ .title = "first", .description = "", .labels = "" } });
    try server.addEvent(server.open, Server.alice_author, second, .{ .issue = .{ .title = "second", .description = "", .labels = "" } });
    try server.addEvent(server.open, Server.alice_author, third, .{ .issue = .{ .title = "third", .description = "", .labels = "" } });
    try server.addEvent(server.open, Server.alice_author, closed, .{ .issue = .{ .title = "closed", .description = "", .labels = "", .status = .closed } });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    {
        const window = try (domain.ListIssues{ .repo = "alice:open", .from = second_hex }).run(&ctx);
        try std.testing.expectEqual(3, window.count);
        try std.testing.expectEqual(2, window.items.len);
        try std.testing.expectEqualStrings(second_hex, window.items[0].id);
        try std.testing.expectEqualStrings(first_hex, window.items[1].id);
        // the previous window is the first, which "" names
        try std.testing.expectEqualStrings("", window.prev_id.?);
    }
    {
        const window = try (domain.ListIssues{ .repo = "alice:open", .status = .closed }).run(&ctx);
        try std.testing.expectEqual(1, window.count);
        try std.testing.expectEqualStrings("closed", window.items[0].record.event.title);
    }
    // the named issue must be in the listed status and exist
    for ([_][]const u8{ "44444444444444444444444444444444", "55555555555555555555555555555555", "not an id" }) |from| {
        try std.testing.expectError(error.NotFound, (domain.ListIssues{ .repo = "alice:open", .from = from }).run(&ctx));
    }
}

fn expectLocalList(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    try local.addEvent(Server.alice_author, first, .{ .issue = .{ .title = "first", .description = "", .labels = "" } });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = local.ctx(&arena);
    const window = try (domain.ListIssues{ .repo = "" }).run(&ctx);
    try std.testing.expectEqual(1, window.count);
    try std.testing.expectEqualStrings(first_hex, window.items[0].id);
    // local mode owns everything
    try std.testing.expect(window.items[0].can_modify);
    // its one repo has no name
    try std.testing.expectError(error.NotFound, (domain.ListIssues{ .repo = "alice:open" }).run(&ctx));
}

test "domain: ListIssues lists a local git or xit repo's issues" {
    try expectLocalList(.git, .sha1);
    try expectLocalList(.git, .sha256);
    try expectLocalList(.xit, .sha1);
    try expectLocalList(.xit, .sha256);
}
