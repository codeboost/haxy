const std = @import("std");
const evt = @import("../event.zig");
const thread_write = @import("../thread_write.zig");
const ui = @import("../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const rf = xit.ref;

const writer: ui.Actor = .{ .author = .{ .name = "wren", .email = "wren@example.test" }, .role = .write };
const reader: ui.Actor = .{ .author = .{ .name = "reed", .email = "reed@example.test" }, .role = .read };
const other: evt.CommitAuthor = .{ .name = "otto", .email = "otto@example.test" };

const other_events_ref: rf.Ref = .{ .kind = .head, .name = "haxy/other" };
const base_fields: thread_write.Fields = .{ .title = "Original", .labels = "bug", .description = "Intro.\nBase words.\nOutro." };

const Fixture = struct {
    temp: std.testing.TmpDir,
    path: [:0]const u8,
    repo: rp.Repo(.xit, .{}),
    arena: std.heap.ArenaAllocator,

    fn source(self: *const Fixture) ui.RepoSource {
        return .{ .path = self.path, .repo_kind = .xit };
    }

    fn deinit(self: *Fixture) void {
        self.arena.deinit();
        self.repo.deinit(std.testing.io, std.testing.allocator);
        std.testing.allocator.free(self.path);
        self.temp.cleanup();
    }

    fn issue(self: *Fixture, id: *const [evt.event_id_size]u8) !evt.Issue.Record {
        const opts: rp.RepoOpts(.xit) = .{};
        return (try evt.readRecordSubset(evt.Issue, evt.Issue.Record, evt.EventDB(opts.hash), opts.hash, try evt.currentMoment(opts, &self.repo), &self.arena, id)).?;
    }

    fn conflictRevision(self: *Fixture, id: *const [evt.event_id_size]u8) !?evt.ConflictRevision {
        return evt.readConflictRevision(evt.Issue, .xit, .{}, std.testing.io, std.testing.allocator, &self.arena, &self.repo, id);
    }
};

fn init() !Fixture {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    errdefer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    errdefer allocator.free(path);
    var repo = try rp.Repo(.xit, .{}).init(io, allocator, .{ .path = path });
    errdefer repo.deinit(io, allocator);
    // the merge commit's author
    try repo.addConfig(io, allocator, .{ .name = "user.name", .value = "haxy" });
    try repo.addConfig(io, allocator, .{ .name = "user.email", .value = "user@haxy" });
    return .{ .temp = temp, .path = path, .repo = repo, .arena = .init(allocator) };
}

// opens an issue, edits it here to `ours`, has another host edit it to
// `theirs` from the same base, and merges their events in, as a sync does
fn divergeIssue(fixture: *Fixture, id: *const [evt.event_id_size]u8, ours: thread_write.Fields, theirs: thread_write.Fields) !void {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    try thread_write.create(.local, io, allocator, fixture.source(), .issue, id, base_fields, writer.author);
    const base_oid = (try fixture.repo.readRef(io, evt.events_ref)).?;
    try thread_write.edit(.local, io, allocator, fixture.source(), writer, .issue, id, ours, null);
    {
        var json: std.Io.Writer.Allocating = .init(allocator);
        defer json.deinit();
        const event = evt.EventWithId{ .id = std.fmt.bytesToHex(id.*, .lower), .author = other, .event = .{ .issue = .{
            .title = theirs.title,
            .description = theirs.description,
            .labels = theirs.labels,
        } } };
        try std.json.Stringify.value(event, .{}, &json.writer);
        _ = try fixture.repo.commitAtRef(io, allocator, .{ .parent_oids = &.{base_oid}, .message = json.written() }, null, other_events_ref);
    }
    var result = try fixture.repo.switchDir(io, allocator, .{ .target = .{ .ref = evt.events_ref } });
    defer result.deinit();
    var merge = try fixture.repo.merge(io, allocator, .{ .kind = .full, .action = .{ .new = .{ .source = &.{.{ .ref = other_events_ref }} } } }, null);
    defer merge.deinit();
    try std.testing.expect(.success == merge.result);
    try evt.consume(.local, .repo, .xit, .{}, io, allocator, &fixture.repo, evt.events_ref, &.{});
}

const ours_fields: thread_write.Fields = .{ .title = "Our title", .labels = "bug", .description = "Intro.\nOur words.\nOutro." };
const theirs_fields: thread_write.Fields = .{ .title = "Their title", .labels = "bug", .description = "Intro.\nTheir words.\nOutro." };

test "a resolution settles an issue's conflict with the chosen title and description chunks, as one event" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture = try init();
    defer fixture.deinit();
    const id: [evt.event_id_size]u8 = @splat(21);
    try divergeIssue(&fixture, &id, ours_fields, theirs_fields);
    const revision = (try fixture.conflictRevision(&id)).?;

    try thread_write.resolve(evt.Issue, .local, io, allocator, fixture.source(), writer, &id, .{ .title = "Merged title", .hunks = &.{"Merged words."}, .revision = revision });

    const resolved = try fixture.issue(&id);
    try std.testing.expectEqualStrings("Merged title", resolved.event.title);
    try std.testing.expectEqualStrings("Intro.\nMerged words.\nOutro.", resolved.event.description);
    try std.testing.expectEqual(null, try fixture.conflictRevision(&id));
}

test "a resolution based on a conflict that changed or was settled since is refused, and only a writer may resolve" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture = try init();
    defer fixture.deinit();
    const id: [evt.event_id_size]u8 = @splat(22);
    try divergeIssue(&fixture, &id, ours_fields, theirs_fields);
    const revision = (try fixture.conflictRevision(&id)).?;

    try std.testing.expectError(error.Forbidden, thread_write.resolve(evt.Issue, .local, io, allocator, fixture.source(), reader, &id, .{ .title = "Reader's", .revision = revision }));
    const unknown: evt.ConflictRevision = @splat(0);
    try std.testing.expectError(error.Stale, thread_write.resolve(evt.Issue, .local, io, allocator, fixture.source(), writer, &id, .{ .title = "Guessed", .revision = unknown }));
    try std.testing.expectEqualStrings("Our title", (try fixture.issue(&id)).event.title);

    // an edit settles the conflict meanwhile: the resolution made from it is refused
    try thread_write.edit(.local, io, allocator, fixture.source(), writer, .issue, &id, .{ .title = "Edited", .labels = "bug", .description = "Edited words." }, null);
    try std.testing.expectError(error.Stale, thread_write.resolve(evt.Issue, .local, io, allocator, fixture.source(), writer, &id, .{ .title = "Late", .revision = revision }));
    try std.testing.expectEqualStrings("Edited", (try fixture.issue(&id)).event.title);
}

test "a conflict settled between a resolution's read and its write refuses the resolution inside the write" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture = try init();
    defer fixture.deinit();
    const id: [evt.event_id_size]u8 = @splat(23);
    try divergeIssue(&fixture, &id, ours_fields, theirs_fields);
    const revision = (try fixture.conflictRevision(&id)).?;

    const Interleave = struct {
        var path_seen: []const u8 = "";
        fn editIt(_: std.Io) void {
            evt.Issue.testing.after_read = null;
            thread_write.edit(.local, std.testing.io, std.testing.allocator, .{ .path = path_seen, .repo_kind = .xit }, writer, .issue, &@as([evt.event_id_size]u8, @splat(23)), .{ .title = "Edited meanwhile", .labels = "bug", .description = "" }, null) catch @panic("editing failed");
        }
    };
    Interleave.path_seen = fixture.path;
    evt.Issue.testing.after_read = Interleave.editIt;
    defer evt.Issue.testing.after_read = null;
    try std.testing.expectError(error.Stale, thread_write.resolve(evt.Issue, .local, io, allocator, fixture.source(), writer, &id, .{ .title = "Resolved", .revision = revision }));
    try std.testing.expectEqualStrings("Edited meanwhile", (try fixture.issue(&id)).event.title);
}

test "without a revision, a resolution applies to the conflict as it is, as the TUI's form always has" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture = try init();
    defer fixture.deinit();
    const id: [evt.event_id_size]u8 = @splat(24);
    try divergeIssue(&fixture, &id, ours_fields, theirs_fields);

    // absent hunks keep this side's chunk
    try thread_write.resolve(evt.Issue, .local, io, allocator, fixture.source(), writer, &id, .{ .title = "Their title" });
    const resolved = try fixture.issue(&id);
    try std.testing.expectEqualStrings("Their title", resolved.event.title);
    try std.testing.expectEqualStrings(ours_fields.description, resolved.event.description);
    try std.testing.expectEqual(null, try fixture.conflictRevision(&id));
}

// --- patches -------------------------------------------------------------------

// a xit repo whose `feature` branch is one commit ahead of master, with
// `release-a` and `release-b` at master to retarget to
fn initPatchRepo() !Fixture {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture = try init();
    errdefer fixture.deinit();
    {
        const file = try fixture.repo.core.work_dir.createFile(io, "base.txt", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "base\n");
    }
    try fixture.repo.add(io, allocator, &.{"base.txt"});
    _ = try fixture.repo.commit(io, allocator, .{ .message = "base" });
    for ([_][]const u8{ "feature", "release-a", "release-b" }) |name| try fixture.repo.addBranch(io, .{ .name = name });
    _ = try fixture.repo.commitAtRef(io, allocator, .{ .message = "feature" }, null, .{ .kind = .head, .name = "feature" });
    return fixture;
}

fn readPatch(fixture: *Fixture, id: *const [evt.event_id_size]u8) !evt.Patch.Record {
    return (try evt.readFromRepo(evt.Patch, .xit, .{}, std.testing.io, std.testing.allocator, &fixture.arena, &fixture.repo, id)).?;
}

// opens a branch patch into master, retargets it here to release-a, has
// another host retarget it to release-b from the same base, and merges
// their events in: the targets conflict
fn divergePatch(fixture: *Fixture, id: *const [evt.event_id_size]u8) !void {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    try thread_write.createBranchPatch(.local, io, allocator, fixture.source(), id, .{ .title = "Proposal", .labels = "", .description = "", .target_branch = "master" }, "feature", writer.author);
    const base_oid = (try fixture.repo.readRef(io, evt.events_ref)).?;
    var theirs = (try readPatch(fixture, id)).event;
    try thread_write.edit(.local, io, allocator, fixture.source(), writer, .patch, id, .{ .title = "Proposal", .labels = "", .description = "", .target_branch = "release-a" }, null);
    theirs.target_branch = "release-b";
    {
        var json: std.Io.Writer.Allocating = .init(allocator);
        defer json.deinit();
        try std.json.Stringify.value(evt.EventWithId{ .id = std.fmt.bytesToHex(id.*, .lower), .author = other, .event = .{ .patch = theirs } }, .{}, &json.writer);
        _ = try fixture.repo.commitAtRef(io, allocator, .{ .parent_oids = &.{base_oid}, .message = json.written() }, null, other_events_ref);
    }
    var result = try fixture.repo.switchDir(io, allocator, .{ .target = .{ .ref = evt.events_ref } });
    defer result.deinit();
    var merge = try fixture.repo.merge(io, allocator, .{ .kind = .full, .action = .{ .new = .{ .source = &.{.{ .ref = other_events_ref }} } } }, null);
    defer merge.deinit();
    try std.testing.expect(.success == merge.result);
    try evt.consume(.local, .repo, .xit, .{}, io, allocator, &fixture.repo, evt.events_ref, &.{});
}

test "taking their target re-captures the patch's revision against it, and settles the conflict" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture = try initPatchRepo();
    defer fixture.deinit();
    const id: [evt.event_id_size]u8 = @splat(31);
    try divergePatch(&fixture, &id);
    const revision = (try evt.readConflictRevision(evt.Patch, .xit, .{}, io, allocator, &fixture.arena, &fixture.repo, &id)).?;

    try thread_write.resolve(evt.Patch, .local, io, allocator, fixture.source(), writer, &id, .{ .theirs = "target_branch", .revision = revision });
    const resolved = try readPatch(&fixture, &id);
    try std.testing.expectEqualStrings("release-b", resolved.event.target_branch);
    try std.testing.expect(resolved.event.revision != null);
    try std.testing.expectEqual(null, try evt.readConflictRevision(evt.Patch, .xit, .{}, io, allocator, &fixture.arena, &fixture.repo, &id));
}

test "a conflict settled by keeping this side, just before their target is taken, refuses the resolution inside its write" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var fixture = try initPatchRepo();
    defer fixture.deinit();
    const id: [evt.event_id_size]u8 = @splat(32);
    try divergePatch(&fixture, &id);
    const revision = (try evt.readConflictRevision(evt.Patch, .xit, .{}, io, allocator, &fixture.arena, &fixture.repo, &id)).?;

    // someone else resolves it keeping every value here, which leaves the
    // patch's own fields as they were
    const Interleave = struct {
        var path_seen: []const u8 = "";
        fn keepOurs(_: std.Io) void {
            evt.Patch.testing.before_write = null;
            thread_write.resolve(evt.Patch, .local, std.testing.io, std.testing.allocator, .{ .path = path_seen, .repo_kind = .xit }, writer, &@as([evt.event_id_size]u8, @splat(32)), .{}) catch @panic("resolving failed");
        }
    };
    Interleave.path_seen = fixture.path;
    evt.Patch.testing.before_write = Interleave.keepOurs;
    defer evt.Patch.testing.before_write = null;
    try std.testing.expectError(error.Stale, thread_write.resolve(evt.Patch, .local, io, allocator, fixture.source(), writer, &id, .{ .theirs = "target_branch", .revision = revision }));
    try std.testing.expectEqualStrings("release-a", (try readPatch(&fixture, &id)).event.target_branch);
}
