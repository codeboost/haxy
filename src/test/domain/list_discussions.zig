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

fn discussion(title: []const u8, labels: []const u8) evt.Event {
    return .{ .discuss = .{ .title = title, .description = "", .labels = labels } };
}

test "domain: lists: ListDiscussions lists a repo's discussions, newest first" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addEvent(server.open, Server.alice_author, first, discussion("first", ""));
    try server.addEvent(server.open, Server.bob_author, second, discussion("second", ""));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = try server.ctx(&arena, server.carol);
    const window = try (domain.ListDiscussions{ .repo = "alice:open" }).run(&ctx);
    try std.testing.expectEqual(2, window.count);
    try std.testing.expectEqual(2, window.items.len);
    try std.testing.expectEqualStrings(second_hex, window.items[0].id);
    try std.testing.expectEqualStrings("second", window.items[0].record.event.title);
    try std.testing.expectEqualStrings(first_hex, window.items[1].id);
    try std.testing.expectEqualStrings("first", window.items[1].record.event.title);
}

test "domain: lists: ListDiscussions searches with the decoded text as given" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    // "%41" would decode to "A", so a search for the first label must not be decoded again
    try server.addEvent(server.open, Server.alice_author, first, discussion("café ouvert", "50%41off"));
    try server.addEvent(server.open, Server.alice_author, second, discussion("cafe closed", "50Aoff"));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    for ([_][]const u8{ "label:50%41off", "café" }) |search| {
        const window = try (domain.ListDiscussions{ .repo = "alice:open", .search = search }).run(&ctx);
        try std.testing.expectEqual(1, window.count);
        try std.testing.expectEqualStrings(first_hex, window.items[0].id);
    }
    {
        const window = try (domain.ListDiscussions{ .repo = "alice:open", .search = "label:50Aoff" }).run(&ctx);
        try std.testing.expectEqual(1, window.count);
        try std.testing.expectEqualStrings(second_hex, window.items[0].id);
    }
    // the named discussion must match the search
    try std.testing.expectError(error.NotFound, (domain.ListDiscussions{ .repo = "alice:open", .search = "café", .from = second_hex }).run(&ctx));
}

test "domain: lists: ListDiscussions pages across a window boundary" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    // 21 discussions, one more than a window holds, made oldest first
    var i: u8 = 1;
    while (i <= 21) : (i += 1) {
        const id: fixture.Id = @splat(i);
        try server.addEvent(server.open, Server.alice_author, id, discussion("a talk", ""));
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, null);

    const window = try (domain.ListDiscussions{ .repo = "alice:open" }).run(&ctx);
    try std.testing.expectEqual(21, window.count);
    try std.testing.expectEqual(20, window.items.len);
    try std.testing.expectEqualStrings("15151515151515151515151515151515", window.items[0].id);
    try std.testing.expectEqualStrings("02020202020202020202020202020202", window.items[19].id);
    try std.testing.expectEqual(null, window.prev_id);
    try std.testing.expectEqualStrings("01010101010101010101010101010101", window.next_id.?);

    const next = try (domain.ListDiscussions{ .repo = "alice:open", .from = window.next_id.? }).run(&ctx);
    try std.testing.expectEqual(21, next.count);
    try std.testing.expectEqual(1, next.items.len);
    try std.testing.expectEqualStrings("01010101010101010101010101010101", next.items[0].id);
    try std.testing.expectEqual(null, next.next_id);
    // the previous window is the first, which "" names
    try std.testing.expectEqualStrings("", next.prev_id.?);

    // a from that names no discussion
    for ([_][]const u8{ "16161616161616161616161616161616", "not an id", "%" }) |from| {
        try std.testing.expectError(error.NotFound, (domain.ListDiscussions{ .repo = "alice:open", .from = from }).run(&ctx));
    }
}

test "domain: lists: ListDiscussions finds no repo the viewer can't see and no tab that is off" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addEvent(server.secret, Server.alice_author, first, discussion("secret talk", ""));
    try server.addEvent(server.open, Server.alice_author, second, discussion("open talk", ""));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.carol, server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.NotFound, (domain.ListDiscussions{ .repo = "alice:secret" }).run(&ctx));
        // the public repo reads for anyone
        const window = try (domain.ListDiscussions{ .repo = "alice:open" }).run(&ctx);
        try std.testing.expectEqualStrings("open talk", window.items[0].record.event.title);
    }
    {
        var ctx = try server.ctx(&arena, server.bob);
        const window = try (domain.ListDiscussions{ .repo = "alice:secret" }).run(&ctx);
        try std.testing.expectEqualStrings("secret talk", window.items[0].record.event.title);
        for ([_][]const u8{ "alice:missing", "alice", "" }) |identity| {
            try std.testing.expectError(error.NotFound, (domain.ListDiscussions{ .repo = identity }).run(&ctx));
        }
    }
    // with the discussion tab off, the discussions don't exist even to the owner
    try server.setTabs(server.secret, null, .read, null);
    var ctx = try server.ctx(&arena, server.alice);
    try std.testing.expectError(error.NotFound, (domain.ListDiscussions{ .repo = "alice:secret" }).run(&ctx));
}

fn expectServerList(comptime hash_kind: hx.xit.hash.HashKind) !void {
    const server = try Server.init(hash_kind);
    defer server.deinit();
    try server.addEvent(server.open, Server.alice_author, first, discussion("first", ""));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.bob);
    const window = try (domain.ListDiscussions{ .repo = "alice:open" }).run(&ctx);
    try std.testing.expectEqual(1, window.count);
    try std.testing.expectEqualStrings(first_hex, window.items[0].id);
    // a writer may change it and sees its notify button
    try std.testing.expect(window.items[0].can_modify);
    try std.testing.expect(window.items[0].notify_action != null);
}

test "domain: lists: ListDiscussions lists a server repo of either hash kind" {
    try expectServerList(.sha1);
    try expectServerList(.sha256);
}

fn expectLocalList(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    try local.addEvent(Server.alice_author, first, discussion("first", ""));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = local.ctx(&arena);
    const window = try (domain.ListDiscussions{ .repo = "" }).run(&ctx);
    try std.testing.expectEqual(1, window.count);
    try std.testing.expectEqualStrings(first_hex, window.items[0].id);
    // local mode owns everything and has no notify buttons
    try std.testing.expect(window.items[0].can_modify);
    try std.testing.expectEqual(null, window.items[0].notify_action);
    // its one repo has no name
    try std.testing.expectError(error.NotFound, (domain.ListDiscussions{ .repo = "alice:open" }).run(&ctx));
}

test "domain: lists: ListDiscussions lists a local git or xit repo's discussions" {
    try expectLocalList(.git, .sha1);
    try expectLocalList(.git, .sha256);
    try expectLocalList(.xit, .sha1);
    try expectLocalList(.xit, .sha256);
}
