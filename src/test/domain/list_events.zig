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

fn issue(title: []const u8) evt.Event {
    return .{ .issue = .{ .title = title, .description = "", .labels = "" } };
}

fn discussion(title: []const u8) evt.Event {
    return .{ .discuss = .{ .title = title, .description = "", .labels = "" } };
}

fn expectServerEvents(comptime hash_kind: hx.xit.hash.HashKind) !void {
    const server = try Server.init(hash_kind);
    defer server.deinit();
    try server.addEvent(server.open, Server.alice_author, first, issue("first"));
    try server.addEvent(server.open, Server.bob_author, second, discussion("second"));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = try server.ctx(&arena, server.bob);
    const window = try (domain.ListEvents{ .repo = "alice:open" }).run(&ctx);
    try std.testing.expectEqual(2, window.count);
    try std.testing.expectEqual(2, window.events.len);
    try std.testing.expectEqualStrings(second_hex, window.events[0].id);
    try std.testing.expectEqual(.discuss, window.events[0].kind);
    try std.testing.expectEqualStrings(first_hex, window.events[1].id);
    try std.testing.expectEqual(.issue, window.events[1].kind);
    try std.testing.expectEqual(null, window.next);
}

test "domain: lists: ListEvents lists a server repo's events, newest first, in either hash kind" {
    try expectServerEvents(.sha1);
    try expectServerEvents(.sha256);
}

test "domain: lists: ListEvents is not found below write access" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addEvent(server.open, Server.alice_author, first, issue("open"));
    try server.addEvent(server.secret, Server.alice_author, second, issue("secret"));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // a reader of the public repo, a removed member and a logged-out viewer
    for ([_]?fixture.Id{ server.carol, server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.NotFound, (domain.ListEvents{ .repo = "alice:open" }).run(&ctx));
        try std.testing.expectError(error.NotFound, (domain.ListEvents{ .repo = "alice:secret" }).run(&ctx));
    }
    // the owner and a writer see the private repo's history
    for ([_]fixture.Id{ server.alice, server.bob }) |user| {
        var ctx = try server.ctx(&arena, user);
        const window = try (domain.ListEvents{ .repo = "alice:secret" }).run(&ctx);
        try std.testing.expectEqual(1, window.count);
        try std.testing.expectEqualStrings(second_hex, window.events[0].id);
    }
    var ctx = try server.ctx(&arena, server.alice);
    for ([_][]const u8{ "alice:missing", "alice", "" }) |identity| {
        try std.testing.expectError(error.NotFound, (domain.ListEvents{ .repo = identity }).run(&ctx));
    }
}

test "domain: lists: ListEvents lists removed events apart" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addEvent(server.open, Server.alice_author, first, issue("first"));
    try server.addEvent(server.open, Server.alice_author, second, issue("second"));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.alice);
    _ = try (domain.RemoveThread{ .repo = "alice:open", .kind = .issue, .thread_id = first_hex }).run(&ctx);

    {
        const window = try (domain.ListEvents{ .repo = "alice:open" }).run(&ctx);
        try std.testing.expectEqual(1, window.count);
        try std.testing.expectEqualStrings(second_hex, window.events[0].id);
    }
    {
        const window = try (domain.ListEvents{ .repo = "alice:open", .view = .removed }).run(&ctx);
        try std.testing.expectEqual(1, window.count);
        try std.testing.expectEqualStrings(first_hex, window.events[0].id);
        try std.testing.expectEqual(.issue, window.events[0].kind);
    }
    // a removed event roots no active window, and an active one no removed window
    try std.testing.expectError(error.NotFound, (domain.ListEvents{ .repo = "alice:open", .from = first_hex, .from_kind = .issue }).run(&ctx));
    try std.testing.expectError(error.NotFound, (domain.ListEvents{ .repo = "alice:open", .view = .removed, .from = second_hex, .from_kind = .issue }).run(&ctx));
}

test "domain: lists: ListEvents pages across a window boundary" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    // 21 issues, one more than a window holds, made oldest first
    var i: u8 = 1;
    while (i <= 21) : (i += 1) {
        const id: fixture.Id = @splat(i);
        try server.addEvent(server.open, Server.alice_author, id, issue("an issue"));
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.bob);

    const window = try (domain.ListEvents{ .repo = "alice:open" }).run(&ctx);
    try std.testing.expectEqual(21, window.count);
    try std.testing.expectEqual(20, window.events.len);
    try std.testing.expectEqualStrings("15151515151515151515151515151515", window.events[0].id);
    try std.testing.expectEqualStrings("02020202020202020202020202020202", window.events[19].id);
    const next = window.next.?;
    try std.testing.expectEqualStrings("01010101010101010101010101010101", next.id);
    try std.testing.expectEqual(.issue, next.kind);

    const second_window = try (domain.ListEvents{ .repo = "alice:open", .from = next.id, .from_kind = next.kind }).run(&ctx);
    try std.testing.expectEqual(21, second_window.count);
    try std.testing.expectEqual(1, second_window.events.len);
    try std.testing.expectEqualStrings("01010101010101010101010101010101", second_window.events[0].id);
    try std.testing.expectEqual(null, second_window.next);

    // a from that names no event, or names it with the wrong kind
    const cases = [_]struct { from: []const u8, kind: ?evt.EventKind }{
        .{ .from = "16161616161616161616161616161616", .kind = .issue },
        .{ .from = "01010101010101010101010101010101", .kind = .discuss },
        .{ .from = "not an id", .kind = .issue },
        .{ .from = "%", .kind = .issue },
        // an id names its event in lowercase hex only
        .{ .from = "0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A0A", .kind = .issue },
    };
    for (cases) |case| {
        errdefer std.debug.print("from {s}\n", .{case.from});
        try std.testing.expectError(error.NotFound, (domain.ListEvents{ .repo = "alice:open", .from = case.from, .from_kind = case.kind }).run(&ctx));
    }
    // a from without its kind, or a kind without a from, is incomplete
    try std.testing.expectError(error.InvalidReadArguments, (domain.ListEvents{ .repo = "alice:open", .from = "01010101010101010101010101010101" }).run(&ctx));
    try std.testing.expectError(error.InvalidReadArguments, (domain.ListEvents{ .repo = "alice:open", .from_kind = .issue }).run(&ctx));
}

test "domain: lists: ListEvents lists the events one transaction wrote" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addEvent(server.open, Server.alice_author, first, issue("first"));
    try server.addEvent(server.open, Server.alice_author, second, issue("second"));
    // the transaction that wrote the second issue is the last one
    const moment = try server.historyCount(server.open) - 1;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.bob);

    {
        const window = try (domain.ListEvents{ .repo = "alice:open", .moment = moment }).run(&ctx);
        try std.testing.expectEqual(1, window.count);
        try std.testing.expectEqualStrings(second_hex, window.events[0].id);
    }
    {
        const window = try (domain.ListEvents{ .repo = "alice:open", .moment = moment, .from = second_hex, .from_kind = .issue }).run(&ctx);
        try std.testing.expectEqualStrings(second_hex, window.events[0].id);
    }
    // an event that transaction didn't write, and a transaction that isn't there
    try std.testing.expectError(error.NotFound, (domain.ListEvents{ .repo = "alice:open", .moment = moment, .from = first_hex, .from_kind = .issue }).run(&ctx));
    try std.testing.expectError(error.NotFound, (domain.ListEvents{ .repo = "alice:open", .moment = moment + 100 }).run(&ctx));
}

fn expectLocalEvents(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    try local.addEvent(Server.alice_author, first, issue("first"));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = local.ctx(&arena);
    const window = try (domain.ListEvents{ .repo = "" }).run(&ctx);
    try std.testing.expectEqual(1, window.count);
    try std.testing.expectEqualStrings(first_hex, window.events[0].id);
    try std.testing.expectEqual(.issue, window.events[0].kind);
    // its one repo has no name
    try std.testing.expectError(error.NotFound, (domain.ListEvents{ .repo = "alice:open" }).run(&ctx));
    // a git repo has no transactions to look back at
    if (kind == .git) try std.testing.expectError(error.NotFound, (domain.ListEvents{ .repo = "", .moment = 0 }).run(&ctx));
}

test "domain: lists: ListEvents lists a local git or xit repo's events" {
    try expectLocalEvents(.git, .sha1);
    try expectLocalEvents(.git, .sha256);
    try expectLocalEvents(.xit, .sha1);
    try expectLocalEvents(.xit, .sha256);
}
