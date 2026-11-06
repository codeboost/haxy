const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("../event.zig");
const pch = @import("../patch.zig");
const patch_merge = @import("../patch_merge.zig");
const thread_write = @import("../thread_write.zig");
const ui = @import("../ui.zig");

const opts: rp.RepoOpts(.xit) = .{};
const author: evt.CommitAuthor = .{ .name = "wren", .email = "wren@example.test" };
const master: xit.ref.Ref = .{ .kind = .head, .name = "master" };

/// a server repository whose `feature` branch is one commit ahead of
/// `master`, with a patch from one into the other
const Fixture = struct {
    temp: std.testing.TmpDir,
    path: [:0]const u8,
    repo: rp.Repo(.xit, opts),
    arena: std.heap.ArenaAllocator,
    id: [evt.event_id_size]u8 = @splat(60),

    fn init(self: *Fixture) !void {
        const io = std.testing.io;
        const allocator = std.testing.allocator;
        self.temp = std.testing.tmpDir(.{});
        self.path = try self.temp.dir.realPathFileAlloc(io, ".", allocator);
        self.repo = try rp.Repo(.xit, opts).init(io, allocator, .{ .path = self.path });
        self.arena = std.heap.ArenaAllocator.init(allocator);
        self.id = @splat(60);
        errdefer self.deinit();
        try self.repo.addConfig(io, allocator, .{ .name = "user.name", .value = "fixture" });
        try self.repo.addConfig(io, allocator, .{ .name = "user.email", .value = "fixture@example.test" });
        try self.writeFile("base.txt", "base\n");
        _ = try self.repo.commit(io, allocator, .{ .message = "base" });
        try self.repo.addBranch(io, .{ .name = "feature" });
        _ = try self.repo.commitAtRef(io, allocator, .{ .message = "feature" }, null, .{ .kind = .head, .name = "feature" });
        try thread_write.createBranchPatch(self.host(), io, allocator, self.source(), &self.id, .{
            .title = "Proposal",
            .labels = "",
            .description = "",
            .target_branch = "master",
        }, "feature", author);
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.repo.deinit(std.testing.io, std.testing.allocator);
        std.testing.allocator.free(self.path);
        self.temp.cleanup();
    }

    fn writeFile(self: *Fixture, name: []const u8, content: []const u8) !void {
        const io = std.testing.io;
        const file = try self.repo.core.work_dir.createFile(io, name, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, content);
        try self.repo.add(io, std.testing.allocator, &.{name});
    }

    fn host(self: *const Fixture) evt.Host {
        return .{ .server = self.server() };
    }

    fn server(self: *const Fixture) evt.Host.Server {
        return .{ .users_dir = self.path };
    }

    fn source(self: *const Fixture) ui.RepoSource {
        return .{ .path = self.path, .repo_kind = .xit };
    }

    fn patch(self: *Fixture) !evt.Patch.Record {
        return (try evt.readFromRepo(evt.Patch, .xit, opts, std.testing.io, std.testing.allocator, &self.arena, &self.repo, &self.id)) orelse error.NotFound;
    }

    fn tip(self: *Fixture) ![]const u8 {
        const oid = (try self.repo.readRef(std.testing.io, master)) orelse return error.NotFound;
        return self.arena.allocator().dupe(u8, &oid);
    }

    /// what a client shows: the patch's revision and the target's tip, as read now
    fn review(self: *Fixture) !patch_merge.Reviewed {
        const revision = (try self.patch()).event.revision orelse return error.NotFound;
        return .{ .revision = try self.arena.allocator().dupe(u8, &revision.id), .target_commit = try self.tip() };
    }

    fn merge(self: *Fixture, method: evt.Patch.MergeRevision, reviewed: patch_merge.Reviewed) !?patch_merge.Refusal {
        return patch_merge.merge(self.server(), std.testing.io, std.testing.allocator, self.source(), author, &self.id, method, reviewed);
    }

    /// a commit on master, its mergeability checked again as a push's would be
    fn advanceTarget(self: *Fixture, refresh: bool) !void {
        try self.writeFile("target.txt", "target only\n");
        _ = try self.repo.commit(std.testing.io, std.testing.allocator, .{ .message = "advance target" });
        if (refresh) pch.refreshMergeability(opts, std.testing.io, std.testing.allocator, &self.repo, self.path, self.id);
    }

    fn expectUnmerged(self: *Fixture, target: []const u8) !void {
        try std.testing.expectEqual(.open, (try self.patch()).event.status.kind());
        try std.testing.expectEqualStrings(target, try self.tip());
    }
};

test "a squash merge reviewed before its target moved is refused, and lands once reviewed again" {
    var t: Fixture = undefined;
    try t.init();
    defer t.deinit();
    const loaded = try t.review();

    // the target moves, and its mergeability is checked again, after the page loaded
    try t.advanceTarget(true);
    const moved = try t.tip();
    try std.testing.expectEqual(.target_moved, (try t.merge(.squash, loaded)).?);
    try t.expectUnmerged(moved);

    // reviewed against the new tip, it lands
    try std.testing.expectEqual(null, try t.merge(.squash, try t.review()));
    const merged = (try t.patch()).event.status;
    try std.testing.expectEqual(.squash, merged.merged.revision);
    try std.testing.expect(!std.mem.eql(u8, moved, try t.tip()));
}

test "a merge of a revision other than the patch's own is refused as stale" {
    var t: Fixture = undefined;
    try t.init();
    defer t.deinit();
    var reviewed = try t.review();
    const before = try t.tip();
    reviewed.revision = "0123456789abcdef0123456789abcdef";
    try std.testing.expectEqual(.stale_revision, (try t.merge(.source, reviewed)).?);
    try t.expectUnmerged(before);
}

test "a merge whose check against the target's tip hasn't run is refused, never reported as done" {
    var t: Fixture = undefined;
    try t.init();
    defer t.deinit();
    try t.advanceTarget(false);
    const moved = try t.tip();
    try std.testing.expectEqual(.unchecked, (try t.merge(.squash, try t.review())).?);
    try t.expectUnmerged(moved);
}

test "a merge of a closed or already merged patch is refused as no longer open" {
    var t: Fixture = undefined;
    try t.init();
    defer t.deinit();
    const reviewed = try t.review();
    try std.testing.expectEqual(null, try t.merge(.source, reviewed));
    try std.testing.expectEqual(.not_open, (try t.merge(.squash, reviewed)).?);
}
