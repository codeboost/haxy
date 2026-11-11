//! the thread and event reads at the edges the split loaders made matter:
//! storage that isn't there, storage that fails, comment windows, conflicts
//! beyond the first window and drafts

const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const io = std.testing.io;
const allocator = std.testing.allocator;
const Server = fixture.Server;

const thread: fixture.Id = @splat(0x11);
const thread_hex = "11111111111111111111111111111111";
const draft: fixture.Id = @splat(0x22);
const draft_hex = "22222222222222222222222222222222";
const other_draft: fixture.Id = @splat(0x23);
const other_draft_hex = "23232323232323232323232323232323";
const tester: evt.CommitAuthor = .{ .name = "tester", .email = "tester@example.test" };

test "domain: threads: a local repo with no events lists nothing and finds nothing" {
    // a git repo has no db next to it yet; a xit repo's db has no events
    try expectNoEvents(.git);
    try expectNoEvents(.xit);
}

fn expectNoEvents(comptime kind: hx.xit.repo.RepoKind) !void {
    var local = try fixture.Local(kind, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    // no event has been written: an empty listing, by design, and nothing to
    // find by id
    try std.testing.expectEqual(0, (try (domain.ListIssues{ .repo = "" }).run(&ctx)).count);
    try std.testing.expectEqual(0, (try (domain.ListDiscussions{ .repo = "" }).run(&ctx)).count);
    try std.testing.expectEqual(0, (try (domain.ListPatches{ .repo = "" }).run(&ctx)).count);
    try std.testing.expectEqual(0, (try (domain.ListEvents{ .repo = "" }).run(&ctx)).count);
    try std.testing.expectError(error.NotFound, (domain.ListIssues{ .repo = "", .from = thread_hex }).run(&ctx));
    try std.testing.expectError(error.NotFound, (domain.GetIssue{ .repo = "", .id = thread_hex }).run(&ctx));
    try std.testing.expectError(error.NotFound, (domain.GetDiscussion{ .repo = "", .id = thread_hex }).run(&ctx));
    try std.testing.expectError(error.NotFound, (domain.GetPatch{ .repo = "", .id = thread_hex }).run(&ctx));
}

test "domain: threads: a local git repo whose event db is damaged fails the reads as storage" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    try local.addEvent(tester, thread, .{ .issue = .{ .title = "an issue", .description = "", .labels = "" } });
    try scrambleDb(local.path, ".git/haxy");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    try expectFailedRead((domain.ListIssues{ .repo = "" }).run(&ctx));
    try expectFailedRead((domain.GetIssue{ .repo = "", .id = thread_hex }).run(&ctx));
    try expectFailedRead((domain.ListDiscussions{ .repo = "" }).run(&ctx));
    try expectFailedRead((domain.GetDiscussion{ .repo = "", .id = thread_hex }).run(&ctx));
    try expectFailedRead((domain.ListPatches{ .repo = "" }).run(&ctx));
    try expectFailedRead((domain.GetPatch{ .repo = "", .id = thread_hex }).run(&ctx));
    try expectFailedRead((domain.ListEvents{ .repo = "" }).run(&ctx));
}

test "domain: threads: a draft whose fork is gone is no draft" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.addDraft(server.open, server.bob, Server.bob_author, draft);
    try std.Io.Dir.cwd().deleteTree(io, try hx.fork.forkPath(server.arena.allocator(), server.users_dir, &server.bob, &draft));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    const drafts = try (domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&bob);
    try std.testing.expectEqual(0, drafts.items.len);
    try std.testing.expectError(error.NotFound, (domain.GetPatch{ .repo = "alice:open", .id = draft_hex }).run(&bob));
}

test "domain: threads: a draft whose fork can't be read fails the reads as storage" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.addDraft(server.open, server.bob, Server.bob_author, draft);
    try server.addDraft(server.open, server.bob, Server.bob_author, other_draft);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);
    const aa = server.arena.allocator();

    // a fork that won't open
    try replaceFile(try hx.fork.forkPath(aa, server.users_dir, &server.bob, &draft), ".xit/db", "not a database");
    try expectFailedRead((domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&bob));
    try expectFailedRead((domain.GetPatch{ .repo = "alice:open", .id = draft_hex }).run(&bob));
    // a fork that opens but whose data can't be read
    try scrambleDb(try hx.fork.forkPath(aa, server.users_dir, &server.bob, &other_draft), ".xit/db");
    try expectFailedRead((domain.GetPatch{ .repo = "alice:open", .id = other_draft_hex }).run(&bob));
}

test "domain: threads: a logged-out viewer has no drafts" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.addDraft(server.open, server.bob, Server.bob_author, draft);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var nobody = try server.ctx(&arena, null);

    const drafts = try (domain.ListPatches{ .repo = "alice:open", .view = .drafts }).run(&nobody);
    try std.testing.expectEqual(0, drafts.count);
    try std.testing.expectEqual(0, drafts.items.len);
    try std.testing.expectError(error.NotFound, (domain.ListPatches{ .repo = "alice:open", .view = .drafts, .from = draft_hex }).run(&nobody));
    try std.testing.expectError(error.NotFound, (domain.GetPatch{ .repo = "alice:open", .id = draft_hex }).run(&nobody));
}

test "domain: threads: a thread's comments page past the first window and end past the last" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    const kinds = [_]evt.EventKind{ .issue, .discuss, .patch };
    for (kinds, 0..) |kind, k| {
        const id: fixture.Id = @splat(@intCast(0x11 * (k + 1)));
        const event: evt.Event = switch (kind) {
            .issue => .{ .issue = .{ .title = "a thread", .description = "", .labels = "" } },
            .discuss => .{ .discuss = .{ .title = "a thread", .description = "", .labels = "" } },
            .patch => .{ .patch = .{ .title = "a thread", .description = "", .labels = "", .target_branch = "master" } },
            else => unreachable,
        };
        try server.addEvent(server.open, Server.alice_author, id, event);
        // twelve comments, more than one window of ten
        for (0..12) |i| {
            try server.addEvent(server.open, Server.bob_author, @splat(@intCast(0x40 + 0x10 * k + i)), .{ .comment = .{ .thread_id = std.fmt.bytesToHex(id, .lower), .parent_id = std.fmt.bytesToHex(id, .lower), .body = "a comment" } });
        }
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);

    for (kinds, 0..) |kind, k| {
        const id = std.fmt.bytesToHex(@as(fixture.Id, @splat(@intCast(0x11 * (k + 1)))), .lower);
        // the second window holds the last two
        const second = try commentsAt(&carol, kind, &id, 10);
        try std.testing.expectEqual(12, second.count);
        try std.testing.expectEqual(10, second.start);
        try std.testing.expectEqual(2, second.comments.len);
        // one past the last comment is an empty window, not an error
        const past = try commentsAt(&carol, kind, &id, 12);
        try std.testing.expectEqual(12, past.count);
        try std.testing.expectEqual(12, past.start);
        try std.testing.expectEqual(0, past.comments.len);
    }
}

test "domain: threads: a conflicted issue beyond the first conflicts window reads as conflicted" {
    var local = try fixture.Local(.xit, .sha1).init();
    defer local.deinit();
    // one more than a window of twenty; the first made lists last
    for (0..21) |i| {
        try local.conflictIssueLabels(@splat(@intCast(0x30 + i)), "ours", "theirs");
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    const oldest = std.fmt.bytesToHex(@as(fixture.Id, @splat(0x30)), .lower);
    const entry = try (domain.GetIssue{ .repo = "", .id = &oldest }).run(&ctx);
    try std.testing.expectEqualStrings(&oldest, entry.id);
    try std.testing.expect(entry.conflicted);
    const newest = std.fmt.bytesToHex(@as(fixture.Id, @splat(0x30 + 20)), .lower);
    try std.testing.expect((try (domain.GetIssue{ .repo = "", .id = &newest }).run(&ctx)).conflicted);
}

// the comment window of the thread `id` of `kind`, starting at `from`
fn commentsAt(ctx: *domain.Ctx, kind: evt.EventKind, id: []const u8, from: usize) !hx.ui.Repo.Comment.Window {
    return switch (kind) {
        .issue => (try (domain.GetIssue{ .repo = "alice:open", .id = id, .comments_from = from }).run(ctx)).comments,
        .discuss => (try (domain.GetDiscussion{ .repo = "alice:open", .id = id, .comments_from = from }).run(ctx)).comments,
        .patch => (try (domain.GetPatch{ .repo = "alice:open", .id = id, .comments_from = from }).run(ctx)).comments,
        else => unreachable,
    };
}

// overwrite the xitdb file `sub_path` under `dir_path` between its headers
// and its last commit's trailer with bytes no slot can hold, so it opens but
// reading what it stores fails
fn scrambleDb(dir_path: []const u8, sub_path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    const bytes = try dir.readFileAlloc(io, sub_path, allocator, .unlimited);
    defer allocator.free(bytes);
    // the file and root headers, and the trailer the root header points at
    const head = 64;
    const trailer = 25;
    if (bytes.len <= head + trailer) return error.TestExpectedData;
    // 0x7f is no slot tag
    @memset(bytes[head .. bytes.len - trailer], 0x7f);
    const file = try dir.createFile(io, sub_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

// replace the file `sub_path` under `dir_path` with `contents`
fn replaceFile(dir_path: []const u8, sub_path: []const u8, contents: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    const file = try dir.createFile(io, sub_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

// a read that failed, and not because what it names is missing
fn expectFailedRead(result: anytype) !void {
    if (result) |_| return error.TestUnexpectedSuccess else |err| {
        errdefer std.debug.print("failed with {s}\n", .{@errorName(err)});
        try std.testing.expect(err != error.NotFound);
        try std.testing.expectEqual(.internal, domain.classify(err).kind);
    }
}
