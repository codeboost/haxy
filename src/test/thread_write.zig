const std = @import("std");
const evt = @import("../event.zig");
const thread_write = @import("../thread_write.zig");
const ui = @import("../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const rf = xit.ref;
const hash = xit.hash;

const writer: ui.Actor = .{ .author = .{ .name = "wren", .email = "wren@example.test" }, .role = .write };
const reader: ui.Actor = .{ .author = .{ .name = "reed", .email = "reed@example.test" }, .role = .read };

// the issue `id` names, as the repo's views read it
fn readIssue(arena: *std.heap.ArenaAllocator, repo: *rp.Repo(.xit, .{}), id: *const [evt.event_id_size]u8) !?evt.Issue.Record {
    const opts: rp.RepoOpts(.xit) = .{};
    return evt.readRecordSubset(evt.Issue, evt.Issue.Record, evt.EventDB(opts.hash), opts.hash, try evt.currentMoment(opts, repo), arena, id);
}

test "a thread's fields need a title, and labels no longer than a label may be" {
    try std.testing.expectEqual(null, thread_write.checkFields(.issue, .{ .title = "Crash", .labels = "bug ui", .description = "" }));
    try std.testing.expectEqual(.required_title, thread_write.checkFields(.issue, .{ .title = "  ", .labels = "", .description = "text" }).?);
    const long: [evt.Issue.label_max_len + 1]u8 = @splat('l');
    try std.testing.expectEqual(.invalid_labels, thread_write.checkFields(.issue, .{ .title = "Crash", .labels = "bug " ++ &long, .description = "" }).?);
}

test "a thread opened under a chosen id can't be opened twice, nor take another event's id" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    var repo = try rp.Repo(.xit, .{}).init(io, allocator, .{ .path = path });
    defer repo.deinit(io, allocator);
    const source: ui.RepoSource = .{ .path = path, .repo_kind = .xit };

    const id: [evt.event_id_size]u8 = @splat(7);
    try thread_write.create(.local, io, allocator, source, .issue, &id, .{ .title = "First", .labels = "", .description = "" }, writer.author);
    // a retry of the same creation, or anything else under the id, is refused
    try std.testing.expectError(error.IdTaken, thread_write.create(.local, io, allocator, source, .issue, &id, .{ .title = "Second", .labels = "", .description = "" }, writer.author));
    try std.testing.expectError(error.IdTaken, thread_write.create(.local, io, allocator, source, .discuss, &id, .{ .title = "Third", .labels = "", .description = "" }, writer.author));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("First", (try readIssue(&arena, &repo, &id)).?.event.title);
}

test "an edit made against a stale revision changes nothing; only an author or a writer may change an issue" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    var repo = try rp.Repo(.xit, .{}).init(io, allocator, .{ .path = path });
    defer repo.deinit(io, allocator);
    const source: ui.RepoSource = .{ .path = path, .repo_kind = .xit };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const id: [evt.event_id_size]u8 = @splat(9);
    try thread_write.create(.local, io, allocator, source, .issue, &id, .{ .title = "Original", .labels = "bug", .description = "" }, writer.author);
    const loaded = evt.Issue.contentRevision((try readIssue(&arena, &repo, &id)).?.event);

    // someone retitles it after the form loaded: the edit based on the old
    // revision is refused, and their title stands
    try thread_write.editIssue(.local, io, allocator, source, writer, &id, .{ .title = "Retitled", .labels = "bug", .description = "" }, loaded);
    try std.testing.expectError(error.Stale, thread_write.editIssue(.local, io, allocator, source, writer, &id, .{ .title = "Overwritten", .labels = "", .description = "" }, loaded));
    try std.testing.expectEqualStrings("Retitled", (try readIssue(&arena, &repo, &id)).?.event.title);

    // a status change isn't an edit's to overwrite: the revision stays, and
    // the edit keeps the status
    const retitled = evt.Issue.contentRevision((try readIssue(&arena, &repo, &id)).?.event);
    try thread_write.setStatus(evt.Issue, .local, io, allocator, source, writer, &id, .closed);
    try std.testing.expectEqualSlices(u8, &retitled, &evt.Issue.contentRevision((try readIssue(&arena, &repo, &id)).?.event));
    try thread_write.editIssue(.local, io, allocator, source, writer, &id, .{ .title = "Edited", .labels = "ui", .description = "Now with text." }, retitled);
    const edited = (try readIssue(&arena, &repo, &id)).?;
    try std.testing.expectEqualStrings("Edited", edited.event.title);
    try std.testing.expectEqual(.closed, edited.event.status);

    // a reader who didn't open it may not change it in any way
    try std.testing.expectError(error.Forbidden, thread_write.editIssue(.local, io, allocator, source, reader, &id, .{ .title = "Mine now", .labels = "", .description = "" }, null));
    try std.testing.expectError(error.Forbidden, thread_write.setStatus(evt.Issue, .local, io, allocator, source, reader, &id, .open));
    try std.testing.expectError(error.Forbidden, thread_write.remove(.local, io, allocator, source, reader, .issue, &id, .issue, &id));

    // a reader's own issue is theirs to change
    const own: [evt.event_id_size]u8 = @splat(10);
    try thread_write.create(.local, io, allocator, source, .issue, &own, .{ .title = "Reader's", .labels = "", .description = "" }, reader.author);
    try thread_write.setStatus(evt.Issue, .local, io, allocator, source, reader, &own, .closed);
    try thread_write.remove(.local, io, allocator, source, reader, .issue, &own, .issue, &own);
    try std.testing.expect((try readIssue(&arena, &repo, &own)).?.removed);

    // a removed issue is gone for every write
    try thread_write.remove(.local, io, allocator, source, writer, .issue, &id, .issue, &id);
    try std.testing.expectError(error.NotFound, thread_write.editIssue(.local, io, allocator, source, writer, &id, .{ .title = "Back", .labels = "", .description = "" }, null));
    try std.testing.expectError(error.NotFound, thread_write.remove(.local, io, allocator, source, writer, .issue, &id, .issue, &id));
}

test "a merge that changes an issue's fields moves its revision, so an edit based on the fields before it is refused" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    var repo = try rp.Repo(.xit, .{}).init(io, allocator, .{ .path = path });
    defer repo.deinit(io, allocator);
    const source: ui.RepoSource = .{ .path = path, .repo_kind = .xit };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const other_events_ref: rf.Ref = .{ .kind = .head, .name = "haxy/other" };
    // the merge commit's author
    try repo.addConfig(io, allocator, .{ .name = "user.name", .value = "haxy" });
    try repo.addConfig(io, allocator, .{ .name = "user.email", .value = "user@haxy" });

    const id: [evt.event_id_size]u8 = @splat(11);
    try thread_write.create(.local, io, allocator, source, .issue, &id, .{ .title = "Original", .labels = "bug", .description = "Base words." }, writer.author);
    const base_oid = (try repo.readRef(io, evt.events_ref)).?;

    // here the issue is retitled, and a client loads it
    try thread_write.editIssue(.local, io, allocator, source, writer, &id, .{ .title = "Retitled", .labels = "bug", .description = "Base words." }, null);
    const loaded = evt.Issue.contentRevision((try readIssue(&arena, &repo, &id)).?.event);

    // another host rewrote its description from the same base
    {
        var json: std.Io.Writer.Allocating = .init(allocator);
        defer json.deinit();
        const event = evt.EventWithId{ .id = std.fmt.bytesToHex(id, .lower), .author = reader.author, .event = .{ .issue = .{
            .title = "Original",
            .description = "Their words.",
            .labels = "bug",
        } } };
        try std.json.Stringify.value(event, .{}, &json.writer);
        _ = try repo.commitAtRef(io, allocator, .{ .parent_oids = &.{base_oid}, .message = json.written() }, null, other_events_ref);
    }
    {
        var result = try repo.switchDir(io, allocator, .{ .target = .{ .ref = evt.events_ref } });
        defer result.deinit();
        var merge = try repo.merge(io, allocator, .{ .kind = .full, .action = .{ .new = .{ .source = &.{.{ .ref = other_events_ref }} } } }, null);
        defer merge.deinit();
        try std.testing.expect(.success == merge.result);
    }
    try evt.consume(.local, .repo, .xit, .{}, io, allocator, &repo, evt.events_ref, &.{});
    const merged = (try readIssue(&arena, &repo, &id)).?;
    try std.testing.expectEqualStrings("Retitled", merged.event.title);
    try std.testing.expectEqualStrings("Their words.", merged.event.description);

    // the client's edit, made from what it loaded, would drop their words
    try std.testing.expect(!std.mem.eql(u8, &loaded, &evt.Issue.contentRevision(merged.event)));
    try std.testing.expectError(error.Stale, thread_write.editIssue(.local, io, allocator, source, writer, &id, .{ .title = "Retitled again", .labels = "bug", .description = "Base words." }, loaded));
    try std.testing.expectEqualStrings("Their words.", (try readIssue(&arena, &repo, &id)).?.event.description);
}

test "in a git repository, writes read the events branch as it is, not an event db that hasn't caught up with it" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const opts: rp.RepoOpts(.git) = .{};
    {
        var repo = try rp.Repo(.git, opts).init(io, allocator, .{ .path = path });
        defer repo.deinit(io, allocator);
    }
    const source: ui.RepoSource = .{ .path = path, .repo_kind = .git };

    const id: [evt.event_id_size]u8 = @splat(12);
    try thread_write.create(.local, io, allocator, source, .issue, &id, .{ .title = "Cloned", .labels = "", .description = "From upstream." }, writer.author);

    // as in a fresh clone, nothing has read the events branch into the db yet
    const forget = struct {
        fn run(dir_path: []const u8) !void {
            var repo = try rp.Repo(.git, opts).open(std.testing.io, std.testing.allocator, .{ .path = dir_path });
            defer repo.deinit(std.testing.io, std.testing.allocator);
            try evt.LocalEventDB(opts.hash).delete(std.testing.io, repo.core.repo_dir);
        }
    }.run;

    try forget(path);
    try std.testing.expectError(error.IdTaken, thread_write.create(.local, io, allocator, source, .issue, &id, .{ .title = "Replacement", .labels = "", .description = "" }, writer.author));
    try forget(path);
    try thread_write.setStatus(evt.Issue, .local, io, allocator, source, writer, &id, .closed);
    try forget(path);
    try thread_write.editIssue(.local, io, allocator, source, writer, &id, .{ .title = "Cloned, edited", .labels = "", .description = "From upstream." }, evt.Issue.contentRevision(.{ .title = "Cloned", .labels = "", .description = "From upstream." }));
    try forget(path);
    try forget(path);
    try thread_write.remove(.local, io, allocator, source, writer, .issue, &id, .issue, &id);
}

test "a status change that lands between an edit's read and its write stands; the edit changes only the fields" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    var repo = try rp.Repo(.xit, .{}).init(io, allocator, .{ .path = path });
    defer repo.deinit(io, allocator);
    const source: ui.RepoSource = .{ .path = path, .repo_kind = .xit };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const id: [evt.event_id_size]u8 = @splat(13);
    try thread_write.create(.local, io, allocator, source, .issue, &id, .{ .title = "Open", .labels = "", .description = "" }, writer.author);
    const loaded = evt.Issue.contentRevision((try readIssue(&arena, &repo, &id)).?.event);

    const Interleave = struct {
        var path_seen: []const u8 = "";
        fn closeIt(_: std.Io) void {
            evt.Issue.testing.after_read = null;
            thread_write.setStatus(evt.Issue, .local, std.testing.io, std.testing.allocator, .{ .path = path_seen, .repo_kind = .xit }, writer, &@as([evt.event_id_size]u8, @splat(13)), .closed) catch @panic("closing failed");
        }
    };
    Interleave.path_seen = path;
    evt.Issue.testing.after_read = Interleave.closeIt;
    defer evt.Issue.testing.after_read = null;
    try thread_write.editIssue(.local, io, allocator, source, writer, &id, .{ .title = "Retitled", .labels = "", .description = "" }, loaded);

    const issue = (try readIssue(&arena, &repo, &id)).?;
    try std.testing.expectEqualStrings("Retitled", issue.event.title);
    try std.testing.expectEqual(.closed, issue.event.status);
}

test "two concurrent edits of a git repository's issue from the same revision: one lands, the other is stale" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    {
        var repo = try rp.Repo(.git, .{}).init(io, allocator, .{ .path = path });
        defer repo.deinit(io, allocator);
    }
    const source: ui.RepoSource = .{ .path = path, .repo_kind = .git };
    const id: [evt.event_id_size]u8 = @splat(14);
    const original: thread_write.Fields = .{ .title = "Shared", .labels = "", .description = "" };
    try thread_write.create(.local, io, allocator, source, .issue, &id, original, writer.author);

    // the first edit to read the issue waits (a while) for the other to read
    // it too, so without serialization both would check the same revision
    const Race = struct {
        var reads: std.atomic.Value(u32) = .init(0);
        fn waitForOther(race_io: std.Io) void {
            _ = reads.fetchAdd(1, .seq_cst);
            for (0..60) |_| {
                if (reads.load(.seq_cst) >= 2) return;
                std.Io.sleep(race_io, .fromMilliseconds(5), .awake) catch return;
            }
        }
        fn edit(edit_source: ui.RepoSource, title: []const u8, result: *anyerror!void) void {
            result.* = thread_write.editIssue(.local, std.testing.io, std.testing.allocator, edit_source, writer, &@as([evt.event_id_size]u8, @splat(14)), .{ .title = title, .labels = "", .description = "" }, evt.Issue.contentRevision(.{ .title = "Shared", .labels = "", .description = "" }));
        }
    };
    evt.Issue.testing.after_read = Race.waitForOther;
    defer evt.Issue.testing.after_read = null;

    var first: anyerror!void = {};
    var second: anyerror!void = {};
    const thread = try std.Thread.spawn(.{}, Race.edit, .{ source, "First", &first });
    Race.edit(source, "Second", &second);
    thread.join();

    const first_landed = if (first) |_| true else |err| blk: {
        try std.testing.expectEqual(error.Stale, err);
        break :blk false;
    };
    const second_landed = if (second) |_| true else |err| blk: {
        try std.testing.expectEqual(error.Stale, err);
        break :blk false;
    };
    // exactly one lands, and it is what the issue holds
    try std.testing.expect(first_landed != second_landed);
    var repo = try rp.Repo(.git, .{}).open(io, allocator, .{ .path = path });
    defer repo.deinit(io, allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const opts: rp.RepoOpts(.git) = .{};
    var event_db = (try evt.LocalEventDB(opts.hash).openReadOnly(io, allocator, repo.core.repo_dir)).?;
    defer event_db.deinit(io, allocator);
    const issue = (try evt.readRecordSubset(evt.Issue, evt.Issue.Record, evt.EventDB(opts.hash), opts.hash, try evt.currentMomentFromDb(opts.hash, event_db.db), &arena, &id)).?;
    try std.testing.expectEqualStrings(if (first_landed) "First" else "Second", issue.event.title);
}

// the emails assigned to the thread `id` names, oldest first
fn assignees(arena: *std.heap.ArenaAllocator, repo: *rp.Repo(.xit, .{}), id: *const [evt.event_id_size]u8) ![]const []const u8 {
    const opts: rp.RepoOpts(.xit) = .{};
    return evt.Assignment.load(opts.hash, arena, try evt.currentMoment(opts, repo), id);
}

test "assigning by email, and unassigning, follow the TUI's rules: once each, by the thread's author or a writer" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    var repo = try rp.Repo(.xit, .{}).init(io, allocator, .{ .path = path });
    defer repo.deinit(io, allocator);
    const source: ui.RepoSource = .{ .path = path, .repo_kind = .xit };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const id: [evt.event_id_size]u8 = @splat(15);
    try thread_write.create(.local, io, allocator, source, .issue, &id, .{ .title = "Assign me", .labels = "", .description = "" }, writer.author);

    // with no accounts to look names up in, only an email assigns
    const assigned = try thread_write.assign(.local, io, allocator, source, writer, null, .issue, &id, "  ada@example.test ");
    try std.testing.expectEqualSlices(u8, &evt.Assignment.idOf(&id, "ada@example.test"), &assigned.assigned);
    try std.testing.expectEqual(.not_an_email, (try thread_write.assign(.local, io, allocator, source, writer, null, .issue, &id, "ada")).refused);
    try std.testing.expectEqual(.already_assigned, (try thread_write.assign(.local, io, allocator, source, writer, null, .issue, &id, "ada@example.test")).refused);
    _ = try thread_write.assign(.local, io, allocator, source, writer, null, .issue, &id, "bo@example.test");
    try std.testing.expectEqual(2, (try assignees(&arena, &repo, &id)).len);

    // a reader who didn't open the thread may do neither
    try std.testing.expectError(error.Forbidden, thread_write.assign(.local, io, allocator, source, reader, null, .issue, &id, "reed@example.test"));
    try std.testing.expectError(error.Forbidden, thread_write.unassign(.local, io, allocator, source, reader, .issue, &id, &evt.Assignment.idOf(&id, "ada@example.test")));

    // unassigning someone not assigned changes nothing, and says so
    try thread_write.unassign(.local, io, allocator, source, writer, .issue, &id, &evt.Assignment.idOf(&id, "ada@example.test"));
    try std.testing.expectError(error.NotAssigned, thread_write.unassign(.local, io, allocator, source, writer, .issue, &id, &evt.Assignment.idOf(&id, "ada@example.test")));
    try std.testing.expectError(error.NotAssigned, thread_write.unassign(.local, io, allocator, source, writer, .issue, &id, &evt.Assignment.idOf(&id, "never@example.test")));
    const left = try assignees(&arena, &repo, &id);
    try std.testing.expectEqual(1, left.len);
    try std.testing.expectEqualStrings("bo@example.test", left[0]);

    // someone unassigned may be assigned again
    _ = (try thread_write.assign(.local, io, allocator, source, writer, null, .issue, &id, "ada@example.test")).assigned;

    // a thread that isn't one, or is gone, takes no assignment
    const missing: [evt.event_id_size]u8 = @splat(16);
    try std.testing.expectError(error.NotFound, thread_write.assign(.local, io, allocator, source, writer, null, .issue, &missing, "ada@example.test"));
    try std.testing.expectError(error.NotFound, thread_write.assign(.local, io, allocator, source, writer, null, .discuss, &id, "ada@example.test"));
    try thread_write.remove(.local, io, allocator, source, writer, .issue, &id, .issue, &id);
    try std.testing.expectError(error.NotFound, thread_write.assign(.local, io, allocator, source, writer, null, .issue, &id, "cy@example.test"));
    try std.testing.expectError(error.NotFound, thread_write.unassign(.local, io, allocator, source, writer, .issue, &id, &evt.Assignment.idOf(&id, "bo@example.test")));
}

test "in a git repository, assigning and unassigning check the events branch as it is" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);
    const opts: rp.RepoOpts(.git) = .{};
    {
        var repo = try rp.Repo(.git, opts).init(io, allocator, .{ .path = path });
        defer repo.deinit(io, allocator);
    }
    const source: ui.RepoSource = .{ .path = path, .repo_kind = .git };
    const forget = struct {
        fn run(dir_path: []const u8) !void {
            var repo = try rp.Repo(.git, opts).open(std.testing.io, std.testing.allocator, .{ .path = dir_path });
            defer repo.deinit(std.testing.io, std.testing.allocator);
            try evt.LocalEventDB(opts.hash).delete(std.testing.io, repo.core.repo_dir);
        }
    }.run;

    const id: [evt.event_id_size]u8 = @splat(17);
    try thread_write.create(.local, io, allocator, source, .issue, &id, .{ .title = "Cloned", .labels = "", .description = "" }, writer.author);
    _ = (try thread_write.assign(.local, io, allocator, source, writer, null, .issue, &id, "ada@example.test")).assigned;

    // as in a fresh clone, nothing has read the events branch into the db yet
    try forget(path);
    try std.testing.expectEqual(.already_assigned, (try thread_write.assign(.local, io, allocator, source, writer, null, .issue, &id, "ada@example.test")).refused);
    try forget(path);
    try thread_write.unassign(.local, io, allocator, source, writer, .issue, &id, &evt.Assignment.idOf(&id, "ada@example.test"));
    try forget(path);
    try std.testing.expectError(error.NotAssigned, thread_write.unassign(.local, io, allocator, source, writer, .issue, &id, &evt.Assignment.idOf(&id, "ada@example.test")));
}
