const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const api_diff = @import("../api/diff.zig");
const api_patches = @import("../api/patches.zig");
const evt = @import("../event.zig");
const pch = @import("../patch.zig");
const ui = @import("../ui.zig");

const Patches = ui.Repo.Patches;
const author = evt.CommitAuthor{ .name = "alice", .email = "alice@example.test" };

test "patch routes name a status's list, the labels, one patch or its comments, and a revision's diff" {
    const id = "0123456789abcdef0123456789abcdef";
    const list = api_patches.route("/api/v1/repos/bobby/linux/patches").?.thread;
    try std.testing.expectEqualStrings("bobby", list.target.server.owner);
    try std.testing.expectEqual(.list, std.meta.activeTag(list.resource));
    try std.testing.expectEqual(.labels, std.meta.activeTag(api_patches.route("/api/v1/repo/patches/labels").?.thread.resource));
    try std.testing.expectEqualStrings(id, api_patches.route("/api/v1/repo/patches/" ++ id).?.thread.resource.thread);
    try std.testing.expectEqualStrings(id, api_patches.route("/api/v1/repos/bobby/linux/patches/" ++ id ++ "/comments").?.thread.resource.comments);

    const server = api_patches.route("/api/v1/repos/bobby/linux/revisions/" ++ id ++ "/diff").?.revision_diff;
    try std.testing.expectEqualStrings("linux", server.target.server.name);
    try std.testing.expectEqualStrings(id, server.id);
    const local = api_patches.route("/api/v1/repo/revisions/" ++ id ++ "/diff").?.revision_diff;
    try std.testing.expectEqual(.local, std.meta.activeTag(local.target));
    try std.testing.expectEqualStrings(id, local.id);

    for ([_][]const u8{
        "/api/v1/repos/bobby/linux/issues",
        "/api/v1/repos/bobby/linux/revisions/" ++ id,
        "/api/v1/repos/bobby/linux/revisions/" ++ id ++ "/diff/",
        "/api/v1/repos/bobby/linux/revisions//diff",
        "/api/v1/repos/bobby/linux/revisions/a/b/diff",
        "/api/v1/repo/revisions/" ++ id ++ "/files",
        "/api/v1/repo/revisions",
    }) |path| {
        try std.testing.expectEqual(null, api_patches.route(path));
    }
}

test "a patch's revision diff and detail leave out what its target already had" {
    try testBaseBounded(.git);
    try testBaseBounded(.xit);
}

fn testBaseBounded(comptime kind: rp.RepoKind) !void {
    var t: TestRepo(kind) = undefined;
    try t.init();
    defer t.deinit();
    const base = try t.commit(&.{.{ "shared.txt", "shared\n" }});
    try t.repo.addBranch(std.testing.io, .{ .name = "feature" });
    _ = try t.commitOn("feature", &.{.{ "a.txt", "a\n" }});
    const tip = try t.commitOn("feature", &.{.{ "b.txt", "b\n" }});
    // the target moves on after the feature branched off it
    _ = try t.commit(&.{.{ "main.txt", "target only\n" }});
    const id = try t.branchPatch(1, "feature");

    const patch = try t.detail(&id, null);
    try std.testing.expectEqualStrings("open", field(patch, "status").string);
    const source = field(patch, "source").object;
    try std.testing.expectEqualStrings("branch", field(source, "kind").string);
    try std.testing.expectEqualStrings("feature", field(source, "name").string);
    try std.testing.expectEqualStrings("branch:feature", field(source, "id").string);
    try std.testing.expectEqualStrings("branch:master", field(field(patch, "target").object, "id").string);
    const revision = field(patch, "revision").object;
    try std.testing.expectEqualStrings(&tip, field(revision, "source_commit").string);
    try std.testing.expectEqualStrings(&base, field(revision, "base_commit").string);
    try std.testing.expectEqual(false, field(patch, "no_changes").bool);
    try std.testing.expectEqual(.null, std.meta.activeTag(field(patch, "merged")));
    // local mode merges with git, as the TUI offers no merge there
    const mergeability = field(patch, "mergeability").object;
    try std.testing.expectEqual(false, field(mergeability, "available").bool);
    try std.testing.expectEqualStrings("unsupported", field(field(mergeability, "reason").object, "code").string);
    // its files, commits and diff are the revision's
    const review = field(patch, "review").object;
    try std.testing.expectEqual(true, field(review, "available").bool);
    const revision_id = field(revision, "id").string;
    try std.testing.expectEqualStrings(revision_id, field(review, "revision").string);
    try std.testing.expectEqualStrings(revision_id, field(review, "diff").string);

    // the diff holds the feature's two files, not the target's own
    const diff = try (try t.revisionDiff(revision_id, "")).ok();
    try std.testing.expectEqualStrings(revision_id, field(diff, "revision").string);
    try std.testing.expectEqualStrings(&base, field(diff, "base").string);
    try std.testing.expectEqualStrings(&tip, field(diff, "head").string);
    try std.testing.expectEqualDeep(&[_][]const u8{ "a.txt", "b.txt" }, try paths(t.arena.allocator(), diff));
    try std.testing.expectEqualDeep(&[_][]const u8{"b.txt"}, try paths(t.arena.allocator(), try (try t.revisionDiff(revision_id, "path=b.txt")).ok()));
    try std.testing.expectEqualDeep(&[_][]const u8{"b.txt"}, try paths(t.arena.allocator(), try (try t.revisionDiff(revision_id, "cursor=1")).ok()));

    // an id that names no revision
    try std.testing.expectEqual(.not_found, (try (try t.revisionDiff("0123456789abcdef0123456789abcdef", "")).failure()).code);
    try std.testing.expectEqual(.not_found, (try (try t.revisionDiff("tip", "")).failure()).code);
    try std.testing.expectEqual(.validation, (try (try t.revisionDiff(revision_id, "page_size=0")).failure()).code);
}

test "a patch whose source is its target's tip changes nothing" {
    try testNoChanges(.git);
    try testNoChanges(.xit);
}

fn testNoChanges(comptime kind: rp.RepoKind) !void {
    var t: TestRepo(kind) = undefined;
    try t.init();
    defer t.deinit();
    _ = try t.commit(&.{.{ "shared.txt", "shared\n" }});
    try t.repo.addBranch(std.testing.io, .{ .name = "same" });
    const id = try t.branchPatch(2, "same");

    const patch = try t.detail(&id, null);
    try std.testing.expectEqual(true, field(patch, "no_changes").bool);
    const revision_id = field(field(patch, "revision").object, "id").string;
    try std.testing.expectEqual(0, field(try (try t.revisionDiff(revision_id, "")).ok(), "items").array.items.len);
}

test "a patch is read from one snapshot of the repo, even when its branch moves meanwhile" {
    var t: TestRepo(.xit) = undefined;
    try t.init();
    defer t.deinit();
    _ = try t.commit(&.{.{ "shared.txt", "shared\n" }});
    try t.repo.addBranch(std.testing.io, .{ .name = "feature" });
    const old_tip = try t.commitOn("feature", &.{.{ "a.txt", "a\n" }});
    const id = try t.branchPatch(3, "feature");
    const snapshot = try t.repo.core.latestMoment();

    // a push lands: the branch moves, and its patch gets a new revision
    const new_tip = try t.commitOn("feature", &.{.{ "b.txt", "b\n" }});
    try pch.refreshBranches(.local, .xit, TestRepo(.xit).opts, std.testing.io, std.testing.allocator, &t.repo, null);

    const old = field(try t.detail(&id, snapshot), "revision").object;
    try std.testing.expectEqualStrings(&old_tip, field(old, "source_commit").string);
    const fresh = field(try t.detail(&id, null), "revision").object;
    try std.testing.expectEqualStrings(&new_tip, field(fresh, "source_commit").string);

    // the old revision's diff, read in the snapshot, is still the old one
    var out: std.Io.Writer.Allocating = .init(t.arena.allocator());
    var moment = snapshot;
    try std.testing.expectEqual(null, try api_diff.writeRevisionDiffAt(.xit, TestRepo(.xit).opts, &t.arena, &t.repo, std.testing.io, std.testing.allocator, &moment, field(old, "id").string, "", &out.writer));
    const old_diff = (try std.json.parseFromSliceLeaky(std.json.Value, t.arena.allocator(), out.written(), .{})).object;
    try std.testing.expectEqualDeep(&[_][]const u8{"a.txt"}, try paths(t.arena.allocator(), old_diff));
}

test "merging is offered for an open patch with a revision, on a server, as the TUI offers it" {
    const open: Patches.Entry = .{ .id = "", .record = .{ .event = .{
        .title = "t",
        .description = "",
        .labels = "",
        .source_branch = "feature",
        .target_branch = "master",
        .revision = .{ .id = @splat('a'), .squash_oid = "", .source_oid = "" },
    } } };
    try std.testing.expectEqual(null, Patches.mergeBlock(open, .server));
    try std.testing.expectEqual(Patches.MergeBlock.local, Patches.mergeBlock(open, .local).?);

    var closed = open;
    closed.record.event.status = .closed;
    try std.testing.expectEqual(Patches.MergeBlock.not_open, Patches.mergeBlock(closed, .server).?);
    var conflicted = open;
    conflicted.conflicted = true;
    try std.testing.expectEqual(Patches.MergeBlock.conflicted, Patches.mergeBlock(conflicted, .server).?);
    try std.testing.expectEqual(.conflict, api_patches.mergeUnavailable(.conflicted).code);
    var unpushed = open;
    unpushed.record.event.revision = null;
    try std.testing.expectEqual(Patches.MergeBlock.no_revision, Patches.mergeBlock(unpushed, .server).?);
    // a fork-backed patch whose fork is gone
    var forkless = open;
    forkless.record.event.source_branch = null;
    try std.testing.expectEqual(Patches.MergeBlock.no_source, Patches.mergeBlock(forkless, .server).?);
    var forked = forkless;
    forked.fork_exists = true;
    try std.testing.expectEqual(null, Patches.mergeBlock(forked, .server));
}

test "a patch is reviewed at its revision, a merged one's diff at what landed, a forked one in its fork" {
    const branch: Patches.Entry = .{ .id = "", .record = .{ .event = .{
        .title = "t",
        .description = "",
        .labels = "",
        .source_branch = "feature",
        .target_branch = "master",
        .revision = .{ .id = @splat('a'), .squash_oid = "", .source_oid = "" },
    } } };
    const at = Patches.review(&branch).revision;
    try std.testing.expectEqualStrings(&branch.record.event.revision.?.id, at.id);
    try std.testing.expectEqualStrings(at.id, at.diff_id);

    var merged = branch;
    merged.record.event.status = .{ .merged = .{ .revision = .squash, .patchrev_id = @splat('b') } };
    const landed = Patches.review(&merged).revision;
    try std.testing.expectEqualStrings(&merged.record.event.revision.?.id, landed.id);
    try std.testing.expectEqualStrings(&merged.record.event.status.merged.patchrev_id, landed.diff_id);

    var forked = branch;
    forked.record.event.source_branch = null;
    try std.testing.expectEqual(.none, std.meta.activeTag(Patches.review(&forked)));
    forked.fork_exists = true;
    try std.testing.expectEqual(.fork, std.meta.activeTag(Patches.review(&forked)));
    var unpushed = branch;
    unpushed.record.event.revision = null;
    try std.testing.expectEqual(.none, std.meta.activeTag(Patches.review(&unpushed)));
}

fn field(object: std.json.ObjectMap, name: []const u8) std.json.Value {
    return object.get(name) orelse std.debug.panic("missing field {s}", .{name});
}

// the paths of a diff's entries, each once, in order
fn paths(aa: std.mem.Allocator, diff: std.json.ObjectMap) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (field(diff, "items").array.items) |item| {
        const path = field(item.object, "path").string;
        if (out.items.len == 0 or !std.mem.eql(u8, out.items[out.items.len - 1], path)) try out.append(aa, path);
    }
    return out.items;
}

// a temporary repo whose branches a test commits to and makes patches of
fn TestRepo(comptime kind: rp.RepoKind) type {
    return struct {
        const opts: rp.RepoOpts(kind) = .{ .is_test = true };
        const Repo = rp.Repo(kind, opts);
        const Oid = [xit.hash.hexLen(opts.hash)]u8;

        temp: std.testing.TmpDir,
        path: [:0]const u8,
        repo: Repo,
        arena: std.heap.ArenaAllocator,

        const Self = @This();

        fn init(self: *Self) !void {
            const io = std.testing.io;
            self.temp = std.testing.tmpDir(.{});
            self.path = try self.temp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
            self.repo = try Repo.init(io, std.testing.allocator, .{ .path = self.path });
            self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        }

        fn deinit(self: *Self) void {
            self.arena.deinit();
            self.repo.deinit(std.testing.io, std.testing.allocator);
            std.testing.allocator.free(self.path);
            self.temp.cleanup();
        }

        // writes `files` (name, content) and commits them to the checked-out branch
        fn commit(self: *Self, files: []const [2][]const u8) !Oid {
            const io = std.testing.io;
            var names: std.ArrayList([]const u8) = .empty;
            defer names.deinit(std.testing.allocator);
            for (files) |file| {
                const handle = try self.repo.core.work_dir.createFile(io, file[0], .{});
                defer handle.close(io);
                try handle.writeStreamingAll(io, file[1]);
                try names.append(std.testing.allocator, file[0]);
            }
            try self.repo.add(io, std.testing.allocator, names.items);
            return self.repo.commit(io, std.testing.allocator, .{ .message = "change" });
        }

        // commits `files` to `branch`, then checks the default branch out again
        fn commitOn(self: *Self, branch: []const u8, files: []const [2][]const u8) !Oid {
            const io = std.testing.io;
            var selected = try self.repo.switchDir(io, std.testing.allocator, .{ .target = .{ .ref = .{ .kind = .head, .name = branch } } });
            defer selected.deinit();
            const oid = try self.commit(files);
            var restored = try self.repo.switchDir(io, std.testing.allocator, .{ .target = .{ .ref = .{ .kind = .head, .name = "master" } } });
            defer restored.deinit();
            return oid;
        }

        // a patch from `source` into master, through haxy's own operation
        fn branchPatch(self: *Self, byte: u8, source: []const u8) ![evt.event_id_size * 2]u8 {
            const id: [evt.event_id_size]u8 = @splat(byte);
            const id_hex = std.fmt.bytesToHex(id, .lower);
            try pch.writeBranchPatch(.local, kind, opts, std.testing.io, std.testing.allocator, &self.repo, id_hex, .{
                .title = "a patch",
                .description = "",
                .labels = "",
                .source_branch = source,
                .target_branch = "master",
            }, null, author);
            return id_hex;
        }

        // the patch's json as its route answers it in local mode, read in
        // `snapshot` (the latest when null)
        fn detail(self: *Self, id: []const u8, snapshot: ?Patches.Moment(kind, opts)) !std.json.ObjectMap {
            var session = ui.Session{ .arena = &self.arena, .page_arena = &self.arena, .io = std.testing.io, .data = .{ .host_kind = .local } };
            const data = try Patches.init(kind, opts, &self.arena, &self.repo, std.testing.io, null, &session, null, "", "", "", id, "", 0, "", .description, null, .{ .shown = 1, .others = 0, .drafts = false, .snapshot = snapshot });
            const entry = data.selectedThread() orelse return error.NotFound;
            var out: std.Io.Writer.Allocating = .init(self.arena.allocator());
            try std.json.Stringify.value(try api_patches.detail(self.arena.allocator(), entry, .local, .{ .signed_in = true }), .{}, &out.writer);
            return (try std.json.parseFromSliceLeaky(std.json.Value, self.arena.allocator(), out.written(), .{})).object;
        }

        fn revisionDiff(self: *Self, id: []const u8, query: []const u8) !Answer {
            var out: std.Io.Writer.Allocating = .init(self.arena.allocator());
            if (try api_diff.writeRevisionDiff(kind, opts, &self.arena, &self.repo, std.testing.io, std.testing.allocator, id, query, &out.writer)) |err| return .{ .err = err };
            return .{ .json = try std.json.parseFromSliceLeaky(std.json.Value, self.arena.allocator(), out.written(), .{}) };
        }
    };
}

const Answer = union(enum) {
    json: std.json.Value,
    err: api.Error,

    fn ok(self: Answer) !std.json.ObjectMap {
        return switch (self) {
            .json => |value| value.object,
            .err => |err| {
                std.debug.print("unexpected error: {s} {s}\n", .{ @tagName(err.code), err.message });
                return error.UnexpectedError;
            },
        };
    }

    fn failure(self: Answer) !api.Error {
        return switch (self) {
            .err => |err| err,
            .json => error.ExpectedError,
        };
    }
};

test "a patch's branches are sent as the ref ids answers name them, percent-encoded byte for byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    try std.testing.expectEqualStrings("main", (try api_patches.branchName(aa, "branch:main")).?);
    try std.testing.expectEqualStrings("feature/caf\xe9 x", (try api_patches.branchName(aa, "branch:feature/caf%E9%20x")).?);
    try std.testing.expectEqualStrings("a%2Fb", (try api_patches.branchName(aa, "branch:a%252Fb")).?);
    // a plus is itself, not a space
    try std.testing.expectEqualStrings("a+b", (try api_patches.branchName(aa, "branch:a+b")).?);
    for ([_][]const u8{ "", "main", "branch:", "tag:v1", "commit:abc", "revision:0123", "branch:a%2", "branch:a%zz", "Branch:main" }) |id| {
        try std.testing.expectEqual(null, try api_patches.branchName(aa, id));
    }
}

test "a patch's answer carries the revision an edit replaces, and what the viewer may do to it" {
    var t: TestRepo(.xit) = undefined;
    try t.init();
    defer t.deinit();
    _ = try t.commit(&.{.{ "shared.txt", "shared\n" }});
    try t.repo.addBranch(std.testing.io, .{ .name = "feature" });
    _ = try t.commitOn("feature", &.{.{ "a.txt", "a\n" }});
    const id = try t.branchPatch(3, "feature");

    const patch = try t.detail(&id, null);
    const record = (try evt.readFromRepo(evt.Patch, .xit, @TypeOf(t).opts, std.testing.io, std.testing.allocator, &t.arena, &t.repo, &try evt.parseEventId(&id))).?;
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(evt.Patch.contentRevision(record.event), .lower), field(patch, "edit_revision").string);
    // `revision` stays the patch revision it proposes
    try std.testing.expectEqualStrings(&record.event.revision.?.id, field(field(patch, "revision").object, "id").string);
    const actions = field(patch, "actions").object;
    for ([_][]const u8{ "edit", "set_status", "remove", "attach" }) |name| try std.testing.expect(actions.contains(name));
}

test "a merged patch stays merged: its status isn't the viewer's to change, whoever they are" {
    var entry: Patches.Entry = .{
        .id = "",
        .record = .{ .event = .{ .title = "t", .description = "", .labels = "", .target_branch = "master", .status = .{ .merged = .{ .revision = .source, .patchrev_id = @splat('0') } } } },
        .can_modify = true,
    };
    const merged = api_patches.actions(&entry, true);
    try std.testing.expect(merged.edit == .available);
    try std.testing.expect(merged.remove == .available);
    try std.testing.expectEqual(.unsupported, merged.set_status.unavailable.code);
    entry.record.event.status = .closed;
    try std.testing.expect(api_patches.actions(&entry, true).set_status == .available);
    entry.can_modify = false;
    try std.testing.expectEqual(.forbidden, api_patches.actions(&entry, true).set_status.unavailable.code);
    try std.testing.expectEqual(.unauthenticated, api_patches.actions(&entry, false).edit.unavailable.code);
}

test "a status change that raced another change answers conflict, never internal" {
    const raced = try api_patches.statusWriteError(error.Stale);
    try std.testing.expectEqual(.conflict, raced.code);
    // a status change sends no revision to name
    try std.testing.expectEqual(0, raced.field_errors.len);
    try std.testing.expectEqual(.conflict, (try api_patches.statusWriteError(error.PatchAlreadyMerged)).code);
    try std.testing.expectEqualStrings("source", (try api_patches.statusWriteError(error.InvalidSourceBranch)).field_errors[0].field);
    try std.testing.expectEqual(.forbidden, (try api_patches.statusWriteError(error.Forbidden)).code);
}
