const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const author: evt.CommitAuthor = .{ .name = "ada", .email = "ada@example.test" };
const local_issue: fixture.Id = @splat(0x11);
const local_issue_hex = "11111111111111111111111111111111";
const remote_issue: fixture.Id = @splat(0x22);
const remote_issue_hex = "22222222222222222222222222222222";

// the ids of the open issues of a local repo, brought up to its events branch
fn issueIds(arena: *std.heap.ArenaAllocator, local: anytype) ![]const []const u8 {
    var ctx = local.ctx(arena);
    try (domain.RefreshLocal{}).run(&ctx);
    const window = try (domain.ListIssues{ .repo = "" }).run(&ctx);
    const ids = try arena.allocator().alloc([]const u8, window.items.len);
    for (ids, window.items) |*id, item| id.* = item.id;
    return ids;
}

test "domain: Sync trades events with the repo's remote both ways" {
    const Local = fixture.Local(.git, .sha1);
    var remote = try Local.init();
    defer remote.deinit();
    var local = try Local.init();
    defer local.deinit();
    try local.setAuthor(author);
    try local.addRemote("origin", remote.path);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // the first sync starts the remote's events branch
    try local.addEvent(author, local_issue, .{ .issue = .{ .title = "local", .description = "", .labels = "" } });
    var ctx = local.ctx(&arena);
    const first = try (domain.Sync{}).run(&ctx);
    try std.testing.expectEqual(null, first.remote_failure);
    const pushed = try issueIds(&arena, &remote);
    try std.testing.expectEqual(1, pushed.len);
    try std.testing.expectEqualStrings(local_issue_hex, pushed[0]);

    // a later one brings the remote's own events back
    try remote.addEvent(author, remote_issue, .{ .issue = .{ .title = "remote", .description = "", .labels = "" } });
    _ = try (domain.Sync{}).run(&ctx);
    const merged = try issueIds(&arena, &local);
    try std.testing.expectEqual(2, merged.len);
    var seen_remote = false;
    for (merged) |id| seen_remote = seen_remote or std.mem.eql(u8, id, remote_issue_hex);
    try std.testing.expect(seen_remote);
}

test "domain: Sync needs a remote with a url" {
    const Local = fixture.Local(.git, .sha1);
    var local = try Local.init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    try std.testing.expectError(error.RemoteNotFound, (domain.Sync{}).run(&ctx));
    try local.setConfig("remote.origin.pushurl", "/nowhere");
    try std.testing.expectError(error.UrlNotFound, (domain.Sync{}).run(&ctx));
    for ([_]anyerror{ error.RemoteNotFound, error.UrlNotFound }) |err| {
        const failure = domain.classify(err);
        try std.testing.expectEqual(.not_found, failure.kind);
        try std.testing.expect(!failure.changed);
    }
}

test "domain: Sync is local only" {
    const server = try fixture.Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for ([_]?fixture.Id{ server.alice, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.UnavailableHere, (domain.Sync{}).run(&ctx));
    }
}

// a progress sink keeping the texts it hears
const Heard = struct {
    arena: *std.heap.ArenaAllocator,
    texts: std.ArrayList([]const u8) = .empty,

    fn text(context: *anyopaque, value: []const u8) void {
        const self: *Heard = @ptrCast(@alignCast(context));
        const copy = self.arena.allocator().dupe(u8, value) catch return;
        self.texts.append(self.arena.allocator(), copy) catch return;
    }

    fn sink(self: *Heard) domain.Sync.Progress {
        return .{ .context = self, .text = text };
    }
};

test "domain: a sync with a file remote syncs with a sink given, which hears no progress text" {
    const Local = fixture.Local(.xit, .sha1);
    var remote = try Local.init();
    defer remote.deinit();
    var local = try Local.init();
    defer local.deinit();
    try local.setAuthor(author);
    try local.addRemote("origin", remote.path);
    try local.addEvent(author, local_issue, .{ .issue = .{ .title = "local", .description = "", .labels = "" } });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    var heard: Heard = .{ .arena = &arena };
    const result = try (domain.Sync{}).runWithProgress(&ctx, heard.sink());
    try std.testing.expectEqual(null, result.remote_failure);
    try std.testing.expectEqual(1, (try issueIds(&arena, &remote)).len);
    // a file remote's transfers report no progress
    try std.testing.expectEqual(0, heard.texts.items.len);
}

// an ssh command standing in for a remote that answers with an ERR line, in a
// temp dir the caller cleans up. returns the script's path in `arena`.
fn refusingSsh(arena: *std.heap.ArenaAllocator, temp: *std.testing.TmpDir) ![]const u8 {
    const io = std.testing.io;
    const base = try temp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const script = try std.Io.Dir.path.join(arena.allocator(), &.{ base, "refuse.sh" });
    const file = try std.Io.Dir.cwd().createFile(io, script, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "#!/bin/sh\nprintf '0014ERR no such repo'\n");
    try file.setPermissions(io, @fromBackingInt(@intCast(0o755)));
    return script;
}

test "domain: a sync whose push the remote refuses says so after merging the fetched events" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    const Local = fixture.Local(.git, .sha1);
    var remote = try Local.init();
    defer remote.deinit();
    var local = try Local.init();
    defer local.deinit();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try local.setAuthor(author);
    // fetch from the file remote, push over an ssh that refuses
    try local.addRemote("origin", remote.path);
    try local.setConfig("remote.origin.pushurl", "ssh://localhost/nowhere");
    try local.setConfig("core.sshCommand", try refusingSsh(&arena, &temp));
    try local.addEvent(author, local_issue, .{ .issue = .{ .title = "local", .description = "", .labels = "" } });
    try remote.addEvent(author, remote_issue, .{ .issue = .{ .title = "remote", .description = "", .labels = "" } });
    var ctx = local.ctx(&arena);

    const result = try (domain.Sync{}).run(&ctx);
    try std.testing.expectEqualStrings("no such repo", result.remote_failure.?);
    try std.testing.expectEqual(.push, result.failed_stage.?);
    try std.testing.expect(result.merged);
    // the merge stays: the remote's issue is here, and the remote lacks ours
    try std.testing.expectEqual(2, (try issueIds(&arena, &local)).len);
    try std.testing.expectEqual(1, (try issueIds(&arena, &remote)).len);
}

test "domain: a sync whose fetch the remote refuses merges nothing" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    const Local = fixture.Local(.git, .sha1);
    var local = try Local.init();
    defer local.deinit();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try local.addRemote("origin", "ssh://localhost/nowhere");
    try local.setConfig("core.sshCommand", try refusingSsh(&arena, &temp));
    var ctx = local.ctx(&arena);

    const result = try (domain.Sync{}).run(&ctx);
    try std.testing.expectEqualStrings("no such repo", result.remote_failure.?);
    try std.testing.expectEqual(.fetch, result.failed_stage.?);
    try std.testing.expect(!result.merged);
}

test "domain: a sync whose push fails after the merge, not in the remote's words, is classified as changed" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    const Local = fixture.Local(.git, .sha1);
    var remote = try Local.init();
    defer remote.deinit();
    var local = try Local.init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try local.setAuthor(author);
    // an ssh that exits at once, saying nothing
    try local.addRemote("origin", remote.path);
    try local.setConfig("remote.origin.pushurl", "ssh://localhost/nowhere");
    try local.setConfig("core.sshCommand", "false");
    try remote.addEvent(author, remote_issue, .{ .issue = .{ .title = "remote", .description = "", .labels = "" } });
    var ctx = local.ctx(&arena);

    const result = blk: {
        const log_level = std.testing.log_level;
        std.testing.log_level = .err;
        defer std.testing.log_level = log_level;
        break :blk (domain.Sync{}).run(&ctx);
    };
    try std.testing.expectError(error.SyncMergedNotPushed, result);
    // the merge stays
    const ids = try issueIds(&arena, &local);
    try std.testing.expectEqual(1, ids.len);
    try std.testing.expectEqualStrings(remote_issue_hex, ids[0]);
    for ([_]anyerror{ error.SyncMergedNotPushed, error.SyncPushedNotRefetched }) |err| {
        const failure = domain.classify(err);
        try std.testing.expectEqual(.internal, failure.kind);
        try std.testing.expect(failure.changed);
        try std.testing.expect(!failure.retryable);
    }
}

test "domain: a sync's progress sink hears the remote's own words" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    const Local = fixture.Local(.git, .sha1);
    var local = try Local.init();
    defer local.deinit();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try local.addRemote("origin", "ssh://localhost/nowhere");
    try local.setConfig("core.sshCommand", try refusingSsh(&arena, &temp));
    var ctx = local.ctx(&arena);

    var heard: Heard = .{ .arena = &arena };
    _ = try (domain.Sync{}).runWithProgress(&ctx, heard.sink());
    try std.testing.expectEqual(1, heard.texts.items.len);
    try std.testing.expectEqualStrings("no such repo", heard.texts.items[0]);
}
