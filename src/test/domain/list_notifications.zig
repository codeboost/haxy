const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

const alices: fixture.Id = @splat(0xa1);
const alices_hex = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const bobs_comment: fixture.Id = @splat(0xb1);
const bobs_comment_hex = "b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1";

test "domain: ListNotifications lists the acting user's notifications" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    // alice is involved in her issue, so bob's comment notifies her. delivery
    // stamps the wall clock, so the row's time falls between these two reads.
    try server.addIssue(server.open, Server.alice_author, alices);
    const before: u64 = @intCast(std.Io.Timestamp.now(std.testing.io, .real).toSeconds());
    try server.addComment(server.open, Server.bob_author, bobs_comment, alices, "hi");
    const after: u64 = @intCast(std.Io.Timestamp.now(std.testing.io, .real).toSeconds());
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    const listed = try (domain.ListNotifications{}).run(&alice);
    try std.testing.expectEqual(1, listed.rows.len);
    const row = listed.rows[0];
    // the id is the thread's in its repo, from the fixture's own ids
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(hx.notify.idOf(&server.open.repo_id, &alices), .lower), &row.id);
    try std.testing.expect(before <= row.time and row.time <= after);
    try std.testing.expectEqualStrings("alice", row.owner_name);
    try std.testing.expectEqualStrings("open", row.repo_name);
    try std.testing.expectEqualStrings(alices_hex, &row.thread_id);
    try std.testing.expectEqual(.issue, row.thread_kind);
    try std.testing.expectEqualStrings("an issue", row.title);
    try std.testing.expectEqualStrings(bobs_comment_hex, &row.last_child_id);
    try std.testing.expect(row.unread);
    try std.testing.expectEqual(1, listed.unread_count);
    try std.testing.expect(!listed.more);

    // bob, who wrote the comment, hears nothing of it
    var bob = try server.ctx(&arena, server.bob);
    const bobs = try (domain.ListNotifications{}).run(&bob);
    try std.testing.expectEqual(0, bobs.rows.len);
    try std.testing.expectEqual(0, bobs.unread_count);
    try std.testing.expect(!bobs.more);
}

test "domain: ListNotifications needs a login" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // dave was removed, which drops him from the context
    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.ListNotifications{}).run(&ctx));
    }
}

fn expectListLocalUnavailable(comptime kind: hx.xit.repo.RepoKind) !void {
    var local = try fixture.Local(kind, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    try std.testing.expectError(error.UnavailableHere, (domain.ListNotifications{}).run(&ctx));
}

test "domain: ListNotifications is unavailable in local mode, which has no accounts" {
    try expectListLocalUnavailable(.git);
    try expectListLocalUnavailable(.xit);
}

// wait until the wall clock, which stamps deliveries, moves to its next second
fn waitForNextSecond() void {
    const io = std.testing.io;
    const start = std.Io.Timestamp.now(io, .real).toSeconds();
    while (std.Io.Timestamp.now(io, .real).toSeconds() == start) {}
}

test "domain: ListNotifications pages from start, a page at a time" {
    const server = try Server.init(.sha256);
    defer server.deinit();
    // one past a page of 20: bob comments on each of alice's issues, "issue 1"
    // first. notifications bumped in the same second sort by their hashed id,
    // so the oldest and the newest each get a second of their own.
    const count = 21;
    var title_buffer: [16]u8 = undefined;
    for (1..count + 1) |number| {
        if (number == 2 or number == count) waitForNextSecond();
        const issue: fixture.Id = @splat(@intCast(number));
        const comment: fixture.Id = @splat(@intCast(0x80 + number));
        const title = try std.fmt.bufPrint(&title_buffer, "issue {d}", .{number});
        try server.addEvent(server.open, Server.alice_author, issue, .{ .issue = .{ .title = title, .description = "", .labels = "" } });
        try server.addComment(server.open, Server.bob_author, comment, issue, "hi");
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    const first = try (domain.ListNotifications{}).run(&alice);
    try std.testing.expectEqual(20, first.rows.len);
    try std.testing.expect(first.more);
    try std.testing.expectEqual(21, first.unread_count);

    const second = try (domain.ListNotifications{ .start = 20 }).run(&alice);
    try std.testing.expectEqual(1, second.rows.len);
    try std.testing.expect(!second.more);
    try std.testing.expectEqual(21, second.unread_count);

    // newest first across the page boundary: the newest leads the first page,
    // the oldest is alone on the second, and the rest fill the first between
    try std.testing.expectEqualStrings("issue 21", first.rows[0].title);
    try std.testing.expectEqualStrings("issue 1", second.rows[0].title);
    const middle = [_][]const u8{
        "issue 2",  "issue 3",  "issue 4",  "issue 5",  "issue 6",  "issue 7",  "issue 8",
        "issue 9",  "issue 10", "issue 11", "issue 12", "issue 13", "issue 14", "issue 15",
        "issue 16", "issue 17", "issue 18", "issue 19", "issue 20",
    };
    for (middle) |title| {
        var found: usize = 0;
        for (first.rows[1..]) |row| {
            if (std.mem.eql(u8, title, row.title)) found += 1;
        }
        errdefer std.debug.print("{s} found {d} times\n", .{ title, found });
        try std.testing.expectEqual(1, found);
    }

    const past = try (domain.ListNotifications{ .start = 21 }).run(&alice);
    try std.testing.expectEqual(0, past.rows.len);
    try std.testing.expect(!past.more);
}

test "domain: MarkRead marks the acting user's notification read" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.notifyAlice(alices, bobs_comment);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    const row = (try (domain.ListNotifications{}).run(&alice)).rows[0];
    try (domain.MarkRead{ .notification_id = &row.id, .last_child_id = bobs_comment_hex }).run(&alice);
    const listed = try (domain.ListNotifications{}).run(&alice);
    try std.testing.expectEqual(1, listed.rows.len);
    try std.testing.expect(!listed.rows[0].unread);
    try std.testing.expectEqual(0, listed.unread_count);

    // marking it again changes nothing
    try (domain.MarkRead{ .notification_id = &row.id, .last_child_id = bobs_comment_hex }).run(&alice);
    try std.testing.expect(!(try (domain.ListNotifications{}).run(&alice)).rows[0].unread);
}

test "domain: MarkRead leaves a notification bumped since it was listed unread" {
    const server = try Server.init(.sha256);
    defer server.deinit();
    try server.notifyAlice(alices, bobs_comment);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    const seen = (try (domain.ListNotifications{}).run(&alice)).rows[0];
    // a newer comment bumps it after alice listed it
    try server.addComment(server.open, Server.bob_author, @splat(0xb2), alices, "again");
    try std.testing.expectError(error.NotificationOutOfDate, (domain.MarkRead{ .notification_id = &seen.id, .last_child_id = &seen.last_child_id }).run(&alice));

    const listed = try (domain.ListNotifications{}).run(&alice);
    try std.testing.expect(listed.rows[0].unread);
    try std.testing.expectEqualStrings("b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2", &listed.rows[0].last_child_id);
    try std.testing.expectEqual(1, listed.unread_count);
}

test "domain: MarkRead finds only the acting user's notifications" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.notifyAlice(alices, bobs_comment);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    const row = (try (domain.ListNotifications{}).run(&alice)).rows[0];

    // alice's notification isn't carol's or bob's
    for ([_]fixture.Id{ server.carol, server.bob }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.NotFound, (domain.MarkRead{ .notification_id = &row.id, .last_child_id = &row.last_child_id }).run(&ctx));
    }
    const cases = [_]struct { []const u8, []const u8 }{
        // an id she has no notification under
        .{ "22222222222222222222222222222222", bobs_comment_hex },
        .{ "not an id", bobs_comment_hex },
        .{ &row.id, "not an id" },
    };
    for (cases) |case| {
        try std.testing.expectError(error.NotFound, (domain.MarkRead{ .notification_id = case[0], .last_child_id = case[1] }).run(&alice));
    }
    try std.testing.expect((try (domain.ListNotifications{}).run(&alice)).rows[0].unread);
}

test "domain: MarkRead needs a login and a server" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.notifyAlice(alices, bobs_comment);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    const row = (try (domain.ListNotifications{}).run(&alice)).rows[0];

    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.MarkRead{ .notification_id = &row.id, .last_child_id = &row.last_child_id }).run(&ctx));
    }
    try std.testing.expect((try (domain.ListNotifications{}).run(&alice)).rows[0].unread);

    inline for ([_]hx.xit.repo.RepoKind{ .git, .xit }) |kind| {
        var local = try fixture.Local(kind, .sha1).init();
        defer local.deinit();
        var ctx = local.ctx(&arena);
        try std.testing.expectError(error.UnavailableHere, (domain.MarkRead{ .notification_id = &row.id, .last_child_id = &row.last_child_id }).run(&ctx));
    }
}

test "domain: Dismiss removes the acting user's notification until the thread's next bump" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.notifyAlice(alices, bobs_comment);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    const row = (try (domain.ListNotifications{}).run(&alice)).rows[0];

    try (domain.Dismiss{ .notification_id = &row.id }).run(&alice);
    const listed = try (domain.ListNotifications{}).run(&alice);
    try std.testing.expectEqual(0, listed.rows.len);
    try std.testing.expectEqual(0, listed.unread_count);

    // she is still involved, so the next comment brings it back
    try server.addComment(server.open, Server.bob_author, @splat(0xb2), alices, "again");
    const bumped = try (domain.ListNotifications{}).run(&alice);
    try std.testing.expectEqual(1, bumped.rows.len);
    try std.testing.expect(bumped.rows[0].unread);
}

test "domain: Dismiss finds only the acting user's notifications" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.notifyAlice(alices, bobs_comment);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    const row = (try (domain.ListNotifications{}).run(&alice)).rows[0];

    for ([_]fixture.Id{ server.carol, server.bob }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.NotFound, (domain.Dismiss{ .notification_id = &row.id }).run(&ctx));
    }
    for ([_][]const u8{ "22222222222222222222222222222222", "not an id" }) |id| {
        try std.testing.expectError(error.NotFound, (domain.Dismiss{ .notification_id = id }).run(&alice));
    }
    try std.testing.expectEqual(1, (try (domain.ListNotifications{}).run(&alice)).rows.len);

    // a dismissed notification is gone, so dismissing it again finds nothing
    try (domain.Dismiss{ .notification_id = &row.id }).run(&alice);
    try std.testing.expectError(error.NotFound, (domain.Dismiss{ .notification_id = &row.id }).run(&alice));
}

test "domain: Dismiss needs a login and a server" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.notifyAlice(alices, bobs_comment);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    const row = (try (domain.ListNotifications{}).run(&alice)).rows[0];

    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.Dismiss{ .notification_id = &row.id }).run(&ctx));
    }
    try std.testing.expectEqual(1, (try (domain.ListNotifications{}).run(&alice)).rows.len);

    inline for ([_]hx.xit.repo.RepoKind{ .git, .xit }) |kind| {
        var local = try fixture.Local(kind, .sha1).init();
        defer local.deinit();
        var ctx = local.ctx(&arena);
        try std.testing.expectError(error.UnavailableHere, (domain.Dismiss{ .notification_id = &row.id }).run(&ctx));
    }
}

test "domain: GetIssue leaves the issue's notification unread" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.notifyAlice(alices, bobs_comment);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    // only the page marks what it shows read
    _ = try (domain.GetIssue{ .repo = "alice:open", .id = alices_hex }).run(&alice);
    _ = try (domain.ListIssues{ .repo = "alice:open" }).run(&alice);
    const listed = try (domain.ListNotifications{}).run(&alice);
    try std.testing.expect(listed.rows[0].unread);
    try std.testing.expectEqual(1, listed.unread_count);
}

// the race between a list and a mark can't be forced through MarkRead, so the
// storage transaction's own answer is checked here
test "domain: notify.markRead and notify.dismiss report what their transaction saw" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.notifyAlice(alices, bobs_comment);
    const io = std.testing.io;
    const notify = hx.notify;
    const id = notify.idOf(&server.open.repo_id, &alices);
    const missing: fixture.Id = @splat(0x22);

    try std.testing.expectEqual(.missing, try notify.markRead(io, allocator, server.users_dir, &server.alice, &missing, &bobs_comment));
    // bob holds no notification under alice's id
    try std.testing.expectEqual(.missing, try notify.markRead(io, allocator, server.users_dir, &server.bob, &id, &bobs_comment));

    // a newer child since the one seen leaves it unread
    try server.addComment(server.open, Server.bob_author, @splat(0xb2), alices, "again");
    try std.testing.expectEqual(.out_of_date, try notify.markRead(io, allocator, server.users_dir, &server.alice, &id, &bobs_comment));
    try std.testing.expectEqual(.marked, try notify.markRead(io, allocator, server.users_dir, &server.alice, &id, &@as(fixture.Id, @splat(0xb2))));
    try std.testing.expectEqual(.already_read, try notify.markRead(io, allocator, server.users_dir, &server.alice, &id, &@as(fixture.Id, @splat(0xb2))));
    // a read one stays read whichever child the caller saw
    try std.testing.expectEqual(.already_read, try notify.markRead(io, allocator, server.users_dir, &server.alice, &id, &bobs_comment));

    try std.testing.expectEqual(.missing, try notify.dismiss(io, allocator, server.users_dir, &server.bob, &id));
    try std.testing.expectEqual(.dismissed, try notify.dismiss(io, allocator, server.users_dir, &server.alice, &id));
    try std.testing.expectEqual(.missing, try notify.dismiss(io, allocator, server.users_dir, &server.alice, &id));
}
