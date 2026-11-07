//! local mode's event sync as the TUI and the JSON API share it: what a sync
//! reports when it fails, what it leaves behind, and how the events branch
//! compares with the remote's.

const std = @import("std");
const evt = @import("../event.zig");
const api_sync = @import("../api/sync.zig");
const api_thread = @import("../api/thread.zig");
const Events = @import("../ui/Repo/Events.zig");
const ui = @import("../ui.zig");
const xit = @import("xit");

const Repo = xit.repo.Repo(.git, .{});

const Fixture = struct {
    temp: std.testing.TmpDir,
    temp_path: [:0]u8,
    local_path: []u8,
    remote_path: []u8,

    // a git repo with one commit on master and `origin` at `remote_path`,
    // which is removed again unless `remote_exists`
    fn init(remote_exists: bool) !Fixture {
        const io = std.testing.io;
        const allocator = std.testing.allocator;
        var temp = std.testing.tmpDir(.{});
        errdefer temp.cleanup();
        const temp_path = try temp.dir.realPathFileAlloc(io, ".", allocator);
        errdefer allocator.free(temp_path);
        const local_path = try std.Io.Dir.path.join(allocator, &.{ temp_path, "local" });
        errdefer allocator.free(local_path);
        const remote_path = try std.Io.Dir.path.join(allocator, &.{ temp_path, "remote" });
        errdefer allocator.free(remote_path);

        {
            var remote = try Repo.init(io, allocator, .{ .path = remote_path });
            remote.deinit(io, allocator);
        }
        var local = try Repo.init(io, allocator, .{ .path = local_path });
        defer local.deinit(io, allocator);
        try local.addConfig(io, allocator, .{ .name = "user.name", .value = "user" });
        try local.addConfig(io, allocator, .{ .name = "user.email", .value = "user@haxy" });
        {
            const file = try local.core.work_dir.createFile(io, "keep.txt", .{});
            defer file.close(io);
            try file.writeStreamingAll(io, "keep");
        }
        try local.add(io, allocator, &.{"keep.txt"});
        _ = try local.commit(io, allocator, .{ .message = "master" });
        try local.addRemote(io, allocator, .{ .name = "origin", .value = remote_path });
        if (!remote_exists) try temp.dir.deleteTree(io, "remote");
        return .{ .temp = temp, .temp_path = temp_path, .local_path = local_path, .remote_path = remote_path };
    }

    fn deinit(self: *Fixture) void {
        const allocator = std.testing.allocator;
        allocator.free(self.remote_path);
        allocator.free(self.local_path);
        allocator.free(self.temp_path);
        self.temp.cleanup();
    }

    fn source(self: *const Fixture) ui.RepoSource {
        return .{ .path = self.local_path, .repo_kind = .git };
    }

    // writes an issue event to the local repo's events branch
    fn addIssue(self: *const Fixture, byte: u8, title: []const u8) !void {
        const io = std.testing.io;
        const allocator = std.testing.allocator;
        var local = try Repo.open(io, allocator, .{ .path = self.local_path });
        defer local.deinit(io, allocator);
        const id: [evt.event_id_size]u8 = @splat(byte);
        try evt.consume(.local, .repo, .git, .{}, io, allocator, &local, evt.events_ref, &.{.{
            .id = std.fmt.bytesToHex(id, .lower),
            .author = .{ .name = "haxy", .email = "user@haxy" },
            .event = .{ .issue = .{ .title = title, .description = "", .labels = "" } },
        }});
    }

    fn localTip(self: *const Fixture) !?[40]u8 {
        const io = std.testing.io;
        const allocator = std.testing.allocator;
        var local = try Repo.open(io, allocator, .{ .path = self.local_path });
        defer local.deinit(io, allocator);
        return try local.readRef(io, evt.events_ref);
    }

    // commits something that is no event on top of the remote's events branch
    fn addUnreadableRemoteCommit(self: *const Fixture) !void {
        const io = std.testing.io;
        const allocator = std.testing.allocator;
        var remote = try Repo.open(io, allocator, .{ .path = self.remote_path });
        defer remote.deinit(io, allocator);
        _ = try remote.commitAtRef(io, allocator, .{ .message = "not an event", .author = "someone <someone@haxy> 1700000000 +0000", .committer = "someone <someone@haxy> 1700000000 +0000" }, null, evt.events_ref);
    }

    fn remoteTip(self: *const Fixture) !?[40]u8 {
        const io = std.testing.io;
        const allocator = std.testing.allocator;
        var remote = try Repo.open(io, allocator, .{ .path = self.remote_path });
        defer remote.deinit(io, allocator);
        return try remote.readRef(io, evt.events_ref);
    }

    // how many issues are open, as the TUI's issues tab reads them after
    // bringing the event db up to date with the events branch
    fn openIssueCount(self: *const Fixture, arena: *std.heap.ArenaAllocator) !usize {
        const io = std.testing.io;
        const allocator = std.testing.allocator;
        var local = try Repo.open(io, allocator, .{ .path = self.local_path });
        defer local.deinit(io, allocator);
        try evt.consume(.local, .repo, .git, .{}, io, allocator, &local, evt.events_ref, &.{});
        const issues = try ui.Repo.Issues.init(.git, .{}, arena, &local, io, null, "", "", "", "", 0, "", .open, null, .{});
        return issues.open.count;
    }

    fn status(self: *const Fixture, arena: std.mem.Allocator) !Events.SyncStatus {
        const io = std.testing.io;
        var local = try Repo.open(io, std.testing.allocator, .{ .path = self.local_path });
        defer local.deinit(io, std.testing.allocator);
        return Events.syncStatus(.git, .{}, &local, io, arena);
    }
};

test "a sync that can't reach its remote fails at the fetch and keeps the local events" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    try fixture.addIssue(1, "offline");
    const before = (try fixture.localTip()) orelse return error.TestExpectedEqual;

    var result = try Events.runSync(std.testing.io, allocator, fixture.source(), null);
    defer result.deinit(allocator);
    const failure = switch (result) {
        .synced => return error.TestExpectedEqual,
        .failed => |failure| failure,
    };
    try std.testing.expectEqual(Events.SyncStage.fetch, failure.stage);
    const after = (try fixture.localTip()) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(&before, &after);

    // the last sync says so too
    var last_buffer: Events.LastSync = undefined;
    const last = Events.lastSync(std.testing.io, &last_buffer) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(Events.SyncStage.fetch, last.failure.?.stage);
    try std.testing.expect(!Events.syncRunning(std.testing.io));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const status = try fixture.status(arena.allocator());
    try std.testing.expectEqualStrings("origin", status.remote.?);
    try std.testing.expectEqual(Events.SyncState.not_fetched, status.state);
}

test "a repo without a remote fails before fetching anything" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    {
        var local = try Repo.open(io, allocator, .{ .path = fixture.local_path });
        defer local.deinit(io, allocator);
        try local.removeRemote(io, allocator, .{ .name = "origin" });
    }
    var result = try Events.runSync(io, allocator, fixture.source(), null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(Events.SyncStage.remote, result.failed.stage);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const status = try fixture.status(arena.allocator());
    try std.testing.expectEqual(null, status.remote);
    try std.testing.expectEqual(Events.SyncState.no_remote, status.state);
}

test "the sync status follows the events branch against the remote's, as last fetched" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    try fixture.addIssue(1, "first");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expectEqual(Events.SyncState.not_fetched, (try fixture.status(arena.allocator())).state);

    var result = try Events.runSync(io, allocator, fixture.source(), null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(.synced, std.meta.activeTag(result));
    try std.testing.expectEqual(Events.SyncState.in_sync, (try fixture.status(arena.allocator())).state);
    var last_buffer: Events.LastSync = undefined;
    const last = Events.lastSync(io, &last_buffer) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(null, last.failure);

    try fixture.addIssue(2, "second");
    try std.testing.expectEqual(Events.SyncState.sync_needed, (try fixture.status(arena.allocator())).state);

    // the remote holds what was pushed
    var remote = try Repo.open(io, allocator, .{ .path = fixture.remote_path });
    defer remote.deinit(io, allocator);
    try std.testing.expect(try remote.readRef(io, evt.events_ref) != null);
}

test "each sync gets an id of its own" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var first = try Events.runSync(io, allocator, fixture.source(), null);
    defer first.deinit(allocator);
    var first_buffer: Events.LastSync = undefined;
    const first_id = (Events.lastSync(io, &first_buffer) orelse return error.TestExpectedEqual).id;
    var second = try Events.runSync(io, allocator, fixture.source(), null);
    defer second.deinit(allocator);
    var second_buffer: Events.LastSync = undefined;
    const second_id = (Events.lastSync(io, &second_buffer) orelse return error.TestExpectedEqual).id;
    try std.testing.expect(first_id != second_id);
}

test "the sync route is local mode's alone" {
    try std.testing.expect(api_sync.route("/api/v1/repo/sync"));
    for ([_][]const u8{
        "/api/v1/repo/sync/",
        "/api/v1/repo/syncs",
        "/api/v1/repo",
        "/api/v1/repos/alice/shared/sync",
        "/api/v1/sync",
    }) |path| {
        try std.testing.expect(!api_sync.route(path));
    }
}

test "a first sync merges event histories that share no ancestor, keeping both sides' issues" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    try fixture.addIssue(1, "local");
    {
        // the remote's events began on their own
        var remote = try Repo.open(io, allocator, .{ .path = fixture.remote_path });
        defer remote.deinit(io, allocator);
        const id: [evt.event_id_size]u8 = @splat(2);
        try evt.consume(.local, .repo, .git, .{}, io, allocator, &remote, evt.events_ref, &.{.{
            .id = std.fmt.bytesToHex(id, .lower),
            .author = .{ .name = "haxy", .email = "user@haxy" },
            .event = .{ .issue = .{ .title = "remote", .description = "", .labels = "" } },
        }});
    }

    var result = try Events.runSync(io, allocator, fixture.source(), null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(.synced, std.meta.activeTag(result));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var local = try Repo.open(io, allocator, .{ .path = fixture.local_path });
    defer local.deinit(io, allocator);
    const issues = try ui.Repo.Issues.init(.git, .{}, &arena, &local, io, null, "", "", "", "", 0, "", .open, null, .{});
    try std.testing.expectEqual(2, issues.open.count);
    try std.testing.expectEqual(0, issues.conflicts.count);
    try std.testing.expectEqual(Events.SyncState.in_sync, (try fixture.status(arena.allocator())).state);
}

// what `/api/v1/repo/sync` answers for `source`, built as the handler does
fn statusJson(arena: *std.heap.ArenaAllocator, source: ui.RepoSource, record: ?*const Events.LastSync) !std.json.Value {
    const io = std.testing.io;
    const aa = arena.allocator();
    var session: ui.Session = .{ .data = .{ .host_kind = .local }, .arena = arena, .page_arena = arena, .local = source };
    session.io = io;
    const resolved = (try ui.Repo.resolve(arena, &session, .{ .identity = "", .owner = "", .name = "" })) orelse return error.NotFound;
    var opened: api_thread.Opened = .{ .session = session, .resolved = resolved, .handle = try resolved.handle(arena, &session), .source = source };
    var body: std.Io.Writer.Allocating = .init(aa);
    try api_sync.writeStatus(arena, io, &opened, .{ .running = false, .last = record }, &body.writer);
    return try std.json.parseFromSliceLeaky(std.json.Value, aa, body.written(), .{});
}

test "a first sync whose fetched events can't be read reports its merge failure and leaves no events here" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    // the remote's events branch holds a commit that is no event
    try fixture.addUnreadableRemoteCommit();

    var record: Events.LastSync = undefined;
    var result = try Events.runSync(io, allocator, fixture.source(), &record);
    defer result.deinit(allocator);
    try std.testing.expectEqual(Events.SyncStage.merge, result.failed.stage);
    try std.testing.expectEqual(null, try fixture.localTip());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const status = try statusJson(&arena, fixture.source(), &record);
    try std.testing.expectEqualStrings("merge", status.object.get("last").?.object.get("failure").?.object.get("stage").?.string);
    // what was fetched isn't read in place of events this repo lacks: the
    // remote's ref is back where it was (never fetched), and the conflicts read
    try std.testing.expectEqualStrings("not_fetched", status.object.get("state").?.string);
    try std.testing.expect(status.object.get("conflicts").? != .null);
    try std.testing.expectEqual(0, try fixture.openIssueCount(&arena));
}

test "the status still answers, with null conflicts, for an events branch that was already unreadable" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    {
        var local = try Repo.open(io, allocator, .{ .path = fixture.local_path });
        defer local.deinit(io, allocator);
        _ = try local.commitAtRef(io, allocator, .{ .message = "not an event", .author = "someone <someone@haxy> 1700000000 +0000", .committer = "someone <someone@haxy> 1700000000 +0000" }, null, evt.events_ref);
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const status = try statusJson(&arena, fixture.source(), null);
    try std.testing.expectEqual(std.json.Value.null, status.object.get("conflicts").?);
    try std.testing.expectEqualStrings("not_fetched", status.object.get("state").?.string);
}

test "the status of a xit repo answers while a sync holds its database" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const XitRepo = xit.repo.Repo(.xit, .{});
    var repo = try XitRepo.init(io, allocator, .{ .path = path });
    defer repo.deinit(io, allocator);
    try repo.addConfig(io, allocator, .{ .name = "user.name", .value = "user" });
    try repo.addConfig(io, allocator, .{ .name = "user.email", .value = "user@haxy" });
    const id: [evt.event_id_size]u8 = @splat(1);
    try evt.consume(.local, .repo, .xit, .{}, io, allocator, &repo, evt.events_ref, &.{.{
        .id = std.fmt.bytesToHex(id, .lower),
        .author = .{ .name = "haxy", .email = "user@haxy" },
        .event = .{ .issue = .{ .title = "existing", .description = "", .labels = "" } },
    }});

    // as a sync's fetch does for its whole network exchange
    var holder = try XitRepo.open(io, allocator, .{ .path = path });
    defer holder.deinit(io, allocator);
    try holder.core.db_file.lock(io, .exclusive);
    defer holder.core.db_file.unlock(io);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const status = try statusJson(&arena, .{ .path = path, .repo_kind = .xit }, null);
    try std.testing.expectEqualStrings("no_remote", status.object.get("state").?.string);
}

test "a sync's running flag and its last record are read together" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    var result = try Events.runSync(io, allocator, fixture.source(), null);
    defer result.deinit(allocator);
    var buffer: Events.LastSync = undefined;
    const snapshot = Events.syncSnapshot(io, &buffer);
    try std.testing.expect(!snapshot.running);
    try std.testing.expectEqual(Events.SyncStage.fetch, snapshot.last.?.failure.?.stage);
}

test "a remote whose name isn't utf-8 is named for display, with U+FFFD" {
    // xit's config reader refuses a config that isn't utf-8 when it opens the
    // repo, so no remote name read today can hold such bytes; the answer still
    // names a remote only through the display rule
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("caf\u{FFFD}", (try api_sync.remoteDisplay(arena.allocator(), "caf\xe9")).?);
    try std.testing.expectEqualStrings("origin", (try api_sync.remoteDisplay(arena.allocator(), "origin")).?);
    try std.testing.expectEqual(null, try api_sync.remoteDisplay(arena.allocator(), null));
}

test "a sync whose fetched events can't be read leaves the events branch, keeps local changes and pushes nothing" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    try fixture.addIssue(1, "synced");
    {
        var first = try Events.runSync(io, allocator, fixture.source(), null);
        defer first.deinit(allocator);
        try std.testing.expectEqual(.synced, std.meta.activeTag(first));
    }
    try fixture.addUnreadableRemoteCommit();
    try fixture.addIssue(2, "local since");
    const local_before = (try fixture.localTip()) orelse return error.TestExpectedEqual;
    const remote_before = (try fixture.remoteTip()) orelse return error.TestExpectedEqual;

    var record: Events.LastSync = undefined;
    var result = try Events.runSync(io, allocator, fixture.source(), &record);
    defer result.deinit(allocator);
    try std.testing.expectEqual(Events.SyncStage.merge, result.failed.stage);

    // the events branch stayed where it was, and reads of it still work
    try std.testing.expectEqualStrings(&local_before, &((try fixture.localTip()) orelse return error.TestExpectedEqual));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expectEqual(2, try fixture.openIssueCount(&arena));
    // nothing was pushed
    try std.testing.expectEqualStrings(&remote_before, &((try fixture.remoteTip()) orelse return error.TestExpectedEqual));

    // the status still answers, conflicts included, and the local change still
    // needs a sync
    const status = try statusJson(&arena, fixture.source(), &record);
    try std.testing.expectEqualStrings("merge", status.object.get("last").?.object.get("failure").?.object.get("stage").?.string);
    try std.testing.expect(status.object.get("conflicts").? != .null);
    try std.testing.expectEqualStrings("sync_needed", status.object.get("state").?.string);

    // a second sync fails the same way, and still pushes nothing
    var again = try Events.runSync(io, allocator, fixture.source(), null);
    defer again.deinit(allocator);
    try std.testing.expectEqual(Events.SyncStage.merge, again.failed.stage);
    try std.testing.expectEqualStrings(&local_before, &((try fixture.localTip()) orelse return error.TestExpectedEqual));
    try std.testing.expectEqualStrings(&remote_before, &((try fixture.remoteTip()) orelse return error.TestExpectedEqual));
    try std.testing.expectEqual(2, try fixture.openIssueCount(&arena));
}

test "a xit repo's sync leaves its events branch and event db alone when the fetched events can't be read" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    const XitRepo = xit.repo.Repo(.xit, .{});
    const path = try std.Io.Dir.path.join(allocator, &.{ fixture.temp_path, "xit" });
    defer allocator.free(path);
    const source: ui.RepoSource = .{ .path = path, .repo_kind = .xit };
    {
        var repo = try XitRepo.init(io, allocator, .{ .path = path });
        defer repo.deinit(io, allocator);
        try repo.addConfig(io, allocator, .{ .name = "user.name", .value = "user" });
        try repo.addConfig(io, allocator, .{ .name = "user.email", .value = "user@haxy" });
        try repo.addRemote(io, allocator, .{ .name = "origin", .value = fixture.remote_path });
    }
    const addIssue = struct {
        fn run(repo_path: []const u8, byte: u8) !void {
            var repo = try XitRepo.open(std.testing.io, std.testing.allocator, .{ .path = repo_path });
            defer repo.deinit(std.testing.io, std.testing.allocator);
            const id: [evt.event_id_size]u8 = @splat(byte);
            try evt.consume(.local, .repo, .xit, .{}, std.testing.io, std.testing.allocator, &repo, evt.events_ref, &.{.{
                .id = std.fmt.bytesToHex(id, .lower),
                .author = .{ .name = "haxy", .email = "user@haxy" },
                .event = .{ .issue = .{ .title = "issue", .description = "", .labels = "" } },
            }});
        }
    }.run;
    const tip = struct {
        fn run(repo_path: []const u8) !?[40]u8 {
            var repo = try XitRepo.open(std.testing.io, std.testing.allocator, .{ .path = repo_path });
            defer repo.deinit(std.testing.io, std.testing.allocator);
            return try repo.readRef(std.testing.io, evt.events_ref);
        }
    }.run;
    const openIssues = struct {
        fn run(arena: *std.heap.ArenaAllocator, repo_path: []const u8) !usize {
            var repo = try XitRepo.open(std.testing.io, std.testing.allocator, .{ .path = repo_path });
            defer repo.deinit(std.testing.io, std.testing.allocator);
            try evt.consume(.local, .repo, .xit, .{}, std.testing.io, std.testing.allocator, &repo, evt.events_ref, &.{});
            return (try ui.Repo.Issues.init(.xit, .{}, arena, &repo, std.testing.io, null, "", "", "", "", 0, "", .open, null, .{})).open.count;
        }
    }.run;

    try addIssue(path, 1);
    {
        var first = try Events.runSync(io, allocator, source, null);
        defer first.deinit(allocator);
        try std.testing.expectEqual(.synced, std.meta.activeTag(first));
    }
    try fixture.addUnreadableRemoteCommit();
    try addIssue(path, 2);
    const local_before = (try tip(path)) orelse return error.TestExpectedEqual;
    const remote_before = (try fixture.remoteTip()) orelse return error.TestExpectedEqual;

    var result = try Events.runSync(io, allocator, source, null);
    defer result.deinit(allocator);
    try std.testing.expectEqual(Events.SyncStage.merge, result.failed.stage);
    try std.testing.expectEqualStrings(&local_before, &((try tip(path)) orelse return error.TestExpectedEqual));
    try std.testing.expectEqualStrings(&remote_before, &((try fixture.remoteTip()) orelse return error.TestExpectedEqual));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expectEqual(2, try openIssues(&arena, path));
}
