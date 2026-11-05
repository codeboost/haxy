const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../event.zig");
const diff3 = @import("../diff3.zig");
const srch_thrd = @import("../search_thread.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;

title: []const u8,
description: []const u8,
labels: []const u8, // space-separated
status: Status = .open,

// what the db stores: the event's data plus the commit-derived fields
pub const Record = struct {
    event: Self,
    removed: bool = false,
    author_email: ?[]const u8 = null,
    created_timestamp: u64 = 0,
    created_order: u64 = 0,
    updated_order: u64 = 0,
};

const Self = @This();

pub const Status = enum {
    open,
    closed,

    const longest_len = blk: {
        var len: usize = 0;
        for (@typeInfo(Status).@"enum".field_names) |name| len = @max(len, name.len);
        break :blk len;
    };
};

pub const label_max_len = 64;

// the moment keys `evt.merge` reads and writes for this kind
pub const merge_policy: evt.MergePolicy = .field_conflicts;
pub const record_map_key = "event-id->issue";
pub const all_id_set_key = "issue-id-set";
pub const conflicts_key = "conflicted-issue-id->conflict";
pub const id_to_field_to_oid_key = "issue-id->field->oid";
pub const status_to_id_set_key = "status->issue-id-set";
pub const label_status_to_id_set_key = "label+status->issue-id-set";

// a "label status" key names a label's per-status issue set (labels can't contain
// spaces, so the pair is unambiguous)
pub const LabelStatusKey = [label_max_len + 1 + Status.longest_len]u8;

pub fn labelStatusKey(buffer: *LabelStatusKey, label: []const u8, status: Status) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s} {s}", .{ label, @tagName(status) });
}

pub fn labelIterator(labels: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, labels, ' ');
}

// a title is required, and a too-long label would go unindexed once consumed
pub fn fieldsValid(title: []const u8, labels: []const u8) bool {
    if (!evt.titleValid(title)) return false;
    var label_iter = labelIterator(labels);
    while (label_iter.next()) |label| {
        if (label.len > label_max_len) return false;
    }
    return true;
}

pub fn consume(
    comptime DB: type,
    comptime hash_kind: hash.HashKind,
    haxy_moment: DB.HashMap(.read_write),
    event_id: *const [evt.event_id_size]u8,
    record_maybe: ?Record,
    arena: *std.heap.ArenaAllocator,
    // the commit this event came from, recorded against every field it
    // changes. null from `merge`, which sets oids and conflicts itself.
    event_oid: ?[]const u8,
) !void {
    const issue_key = hash.hashInt(hash_kind, event_id);

    const event_id_to_issue_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, record_map_key));
    const event_id_to_issue = try DB.HashMap(.read_write).init(event_id_to_issue_cursor);

    // the per-status sets the issues views list, ordered by creation,
    // keyed by status name
    const status_to_issues_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, status_to_id_set_key));
    const status_to_issues = try DB.SortedMap(.read_write).init(status_to_issues_cursor);

    // the per-label, per-status sets, keyed "label,status"
    const label_to_issues_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, label_status_to_id_set_key));
    const label_to_issues = try DB.SortedMap(.read_write).init(label_to_issues_cursor);

    const conflicts_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, conflicts_key));
    const conflicts = try DB.SortedMap(.read_write).init(conflicts_cursor);

    const issue_id_to_field_to_oid_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, id_to_field_to_oid_key));
    const issue_id_to_field_to_oid = try DB.HashMap(.read_write).init(issue_id_to_field_to_oid_cursor);

    var existing_record_maybe: ?Record = null;
    const existing_cursor_maybe = try event_id_to_issue.getCursor(issue_key);
    if (existing_cursor_maybe) |existing_cursor| {
        const existing_issue = try DB.HashMap(.read_only).init(existing_cursor);
        existing_record_maybe = try evt.read(Record, DB, hash_kind, arena, existing_issue);
    }

    var record_to_write = record_maybe orelse try evt.removedRecord(Record, DB, hash_kind, haxy_moment.readOnly(), existing_record_maybe);

    if (existing_record_maybe) |existing_record| {
        // updates preserve the original creation order and author
        record_to_write.created_order = existing_record.created_order;
        record_to_write.author_email = existing_record.author_email;
        record_to_write.created_timestamp = existing_record.created_timestamp;

        // drop the old status's and labels' entries; active values are re-added below
        const order_key = evt.orderKeyDesc(existing_record.created_order, event_id);
        if (!existing_record.removed) {
            const status_set = try statusSet(DB, status_to_issues, existing_record.event.status);
            _ = try status_set.remove(&order_key);
            try removeFromLabelSets(DB, label_to_issues, existing_record.event.labels, existing_record.event.status, &order_key);
        }

        // any event settles the conflict, since resolving in the ui may
        // keep our own values and so change nothing to detect
        if (event_oid != null or record_to_write.removed) _ = try conflicts.remove(&order_key);
    }

    try evt.writeOid(Self, DB, hash_kind, issue_id_to_field_to_oid, issue_key, if (existing_record_maybe) |existing| existing.event else null, record_to_write.event, event_oid);

    const issue_cursor = try event_id_to_issue.putCursor(issue_key);
    const issue = try DB.HashMap(.read_write).init(issue_cursor);
    try evt.upsert(Record, DB, hash_kind, issue, record_to_write);
    try evt.indexEvent(DB, hash_kind, haxy_moment, event_id, .issue, existing_record_maybe, record_to_write);

    const order_key = evt.orderKeyDesc(record_to_write.created_order, event_id);

    // the id set retains removed records so merges can carry removals
    if (existing_cursor_maybe == null) {
        const issue_id_set_cursor = try haxy_moment.putCursor(hash.hashInt(hash_kind, all_id_set_key));
        const issue_id_set = try DB.SortedSet(.read_write).init(issue_id_set_cursor);
        try issue_id_set.put(&order_key);
    }

    // the search index is keyed by the same order key as the sets above
    try srch_thrd.update(DB, hash_kind, .issue, haxy_moment, arena.child_allocator, &order_key, existing_record_maybe, record_to_write);

    if (!record_to_write.removed) {
        const status_set = try statusSet(DB, status_to_issues, record_to_write.event.status);
        try status_set.put(&order_key);

        var label_iter = labelIterator(record_to_write.event.labels);
        while (label_iter.next()) |label| {
            // an over-long label goes unindexed rather than failing the consume,
            // which would wedge the branch it arrived on
            if (label.len == 0 or label.len > label_max_len) continue;
            var key_buffer: LabelStatusKey = undefined;
            const label_set_cursor = try label_to_issues.putCursor(try labelStatusKey(&key_buffer, label, record_to_write.event.status));
            const label_set = try DB.SortedSet(.read_write).init(label_set_cursor);
            try label_set.put(&order_key);
        }
    }

    // the assignee sets hold the issue while it exists, whatever its status
    for (try evt.Assignment.load(hash_kind, arena, haxy_moment.readOnly(), event_id)) |email| {
        try evt.Assignment.indexIssue(DB, hash_kind, haxy_moment, email, &order_key, !record_to_write.removed);
    }
}

// `status`'s sorted set within `statuses`, keyed by status name
fn statusSet(
    comptime DB: type,
    statuses: DB.SortedMap(.read_write),
    status: Status,
) !DB.SortedSet(.read_write) {
    const cursor = try statuses.putCursor(@tagName(status));
    return DB.SortedSet(.read_write).init(cursor);
}

// the resolve form's inputs: null fields keep the live values, `hunks` holds
// the description conflict hunks' resolutions in chunk order (absent
// trailing ones keep our side)
pub const Resolve = struct {
    title: ?[]const u8 = null,
    labels: ?[]const u8 = null,
    hunks: []const []const u8 = &.{},
};

// what an update replaces on an issue: its status, its content, or — for a
// conflicted issue — the resolution of its conflict
pub const Update = union(enum) {
    status: Status,
    fields: struct { title: []const u8, labels: []const u8, description: []const u8 },
    resolve: Resolve,
};

// re-emit the issue `id_bytes` names with `change` applied, preserving the
// rest of its current state. error.NotFound when the id names no issue,
// error.InvalidFields when a resolve composes invalid fields. `repo` must be
// writable.
pub fn update(
    host: evt.Host,
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    id_bytes: *const [evt.event_id_size]u8,
    change: Update,
    author: evt.CommitAuthor,
) !void {
    return updateAt(host, repo_kind, repo_opts, io, allocator, repo, id_bytes, change, author, null);
}

pub const Revision = [16]u8;

// for tests only: run between `updateAt`'s read of an issue and its write,
// so a test can make something happen in that window
pub const testing = struct {
    pub var after_read: ?*const fn (std.Io) void = null;
};

// a version of what an edit replaces: a digest of the title, labels and
// description, so it moves whenever any of them changes, however the change
// arrived (an edit, a conflict resolution, a merge from another host), and
// stays when only the status does
pub fn contentRevision(issue: Self) Revision {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for ([_][]const u8{ issue.title, issue.labels, issue.description }) |field| {
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, &len, field.len, .little);
        hasher.update(&len);
        hasher.update(field);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest[0..@sizeOf(Revision)].*;
}

// `update`, only while the issue's fields are still at `revision`
// (`contentRevision`), else error.Stale; null applies it to whatever the
// issue is now. a xit repo checks again inside the write's transaction, so a
// change that lands meanwhile is never overwritten.
pub fn updateAt(
    host: evt.Host,
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    id_bytes: *const [evt.event_id_size]u8,
    change: Update,
    author: evt.CommitAuthor,
    revision: ?Revision,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const issue = (try readById(repo_kind, repo_opts, io, allocator, &arena, repo, id_bytes)) orelse return error.NotFound;
    if (issue.removed) return error.NotFound;
    if (revision) |expected| {
        if (!std.mem.eql(u8, &contentRevision(issue.event), &expected)) return error.Stale;
    }
    if (builtin.is_test) {
        if (testing.after_read) |hook| hook(io);
    }

    var updated = issue.event;
    switch (change) {
        .status => |status| {
            if (updated.status == status) return;
            updated.status = status;
        },
        .fields => |fields| {
            updated.title = fields.title;
            updated.labels = fields.labels;
            updated.description = fields.description;
        },
        .resolve => |resolve| {
            updated = try resolveFields(repo_kind, repo_opts, io, allocator, &arena, repo, id_bytes, issue, resolve);
            if (!fieldsValid(updated.title, updated.labels)) return error.InvalidFields;
        },
    }

    var events = [_]evt.EventWithId{.{
        .id = std.fmt.bytesToHex(id_bytes.*, .lower),
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author = author,
        .event = .{ .issue = updated },
    }};
    // a xit repo builds the event again inside the write's transaction, from
    // the issue as it is there: a change that landed since the read above
    // stands (a status change under an edit, an edit under a status change),
    // and the revision is checked against it. a git repo's events have no
    // transaction; its writers serialize the read and the write instead
    // (thread_write). a resolution's fields come from the conflict entry read
    // above, so it is written as built.
    if (repo_kind == .xit and change != .resolve) {
        return evt.consumeGuarded(host, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &events, Rebase(repo_opts.hash){
            .arena = &arena,
            .id = id_bytes,
            .change = change,
            .revision = revision,
            .event = &events[0],
        });
    }
    try evt.consume(host, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &events);
}

// the check `updateAt` runs inside a xit repo's write transaction: it
// rebuilds the event from the issue as the transaction sees it, refusing a
// removed issue, a stale revision, and a status the issue already has
// (which cancels the write)
fn Rebase(comptime hash_kind: hash.HashKind) type {
    return struct {
        // holds the rebuilt event's strings until the write is done
        arena: *std.heap.ArenaAllocator,
        id: *const [evt.event_id_size]u8,
        change: Update,
        revision: ?Revision,
        event: *evt.EventWithId,

        pub fn check(self: @This(), moment_maybe: ?evt.EventDB(hash_kind).HashMap(.read_only)) !void {
            const record = (try readFromMoment(hash_kind, self.arena, moment_maybe orelse return error.NotFound, self.id)) orelse return error.NotFound;
            if (record.removed) return error.NotFound;
            if (self.revision) |expected| {
                if (!std.mem.eql(u8, &contentRevision(record.event), &expected)) return error.Stale;
            }
            var updated = record.event;
            switch (self.change) {
                .status => |status| {
                    if (updated.status == status) return error.CancelTransaction;
                    updated.status = status;
                },
                .fields => |fields| {
                    updated.title = fields.title;
                    updated.labels = fields.labels;
                    updated.description = fields.description;
                },
                .resolve => unreachable,
            }
            self.event.event = .{ .issue = updated };
        }
    };
}

// the live fields with `resolve` applied: submitted title/labels stand in for the
// live ones, and a conflicted description is reassembled from the hunk
// resolutions against the conflict entry. the chunking is deterministic: the
// entry holds immutable slots and any event since would have removed it, so
// the hunks match what the resolve form was built from. a settled or
// unreadable entry keeps the live description.
fn resolveFields(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    id_bytes: *const [evt.event_id_size]u8,
    live: Record,
    resolve: Resolve,
) !Self {
    const DB = evt.EventDB(repo_opts.hash);
    const aa = arena.allocator();

    var updated = live.event;
    if (resolve.title) |title| updated.title = title;
    if (resolve.labels) |labels| updated.labels = labels;

    var event_db_maybe: ?evt.LocalEventDB(repo_opts.hash) = if (repo_kind == .git) try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, allocator, repo.core.repo_dir) else null;
    defer if (event_db_maybe) |*event_db| event_db.deinit(io, allocator);
    const moment = (if (event_db_maybe) |*event_db|
        evt.currentMomentFromDb(repo_opts.hash, event_db.db)
    else if (repo_kind == .git)
        return updated
    else
        evt.currentMoment(repo_opts, repo)) catch return updated;

    const conflicts_cursor = (try moment.getCursor(hash.hashInt(repo_opts.hash, conflicts_key))) orelse return updated;
    const conflicts = try DB.SortedMap(.read_only).init(conflicts_cursor);
    const order_key = evt.orderKeyDesc(live.created_order, id_bytes);
    const conflict_cursor = (try conflicts.getCursor(&order_key)) orelse return updated;
    const entry = try DB.HashMap(.read_only).init(conflict_cursor);

    const fields_cursor = (try entry.getCursor(hash.hashInt(repo_opts.hash, evt.conflicted_fields_key))) orelse return updated;
    const conflicted_fields = try fields_cursor.readBytesAlloc(aa, null);
    if (std.mem.indexOf(u8, conflicted_fields, "description") == null) return updated;

    const their_cursor = (try entry.getCursor(hash.hashInt(repo_opts.hash, evt.their_record_key))) orelse return updated;
    const theirs = try evt.read(Record, DB, repo_opts.hash, arena, try DB.HashMap(.read_only).init(their_cursor));

    // absent when both sides created the issue independently
    var base_description: []const u8 = "";
    if (try entry.getCursor(hash.hashInt(repo_opts.hash, evt.base_record_key))) |base_cursor| {
        const base = try evt.read(Record, DB, repo_opts.hash, arena, try DB.HashMap(.read_only).init(base_cursor));
        base_description = base.event.description;
    }

    const chunks = try diff3.chunks(allocator, arena, base_description, live.event.description, theirs.event.description);
    var resolutions: std.ArrayList([]const u8) = .empty;
    var hunk_index: usize = 0;
    for (chunks) |chunk| {
        if (chunk != .conflict) continue;
        try resolutions.append(aa, if (hunk_index < resolve.hunks.len) resolve.hunks[hunk_index] else (chunk.conflict.ours orelse ""));
        hunk_index += 1;
    }
    updated.description = try diff3.assemble(aa, chunks, resolutions.items);
    return updated;
}

// the issue `id_bytes` names in the repo's consumed event db (the repo's own
// db for xit; the side db next to a git repo), or null
fn readById(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    id_bytes: *const [evt.event_id_size]u8,
) !?Record {
    var event_db_maybe: ?evt.LocalEventDB(repo_opts.hash) = if (repo_kind == .git) try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, allocator, repo.core.repo_dir) else null;
    defer if (event_db_maybe) |*event_db| event_db.deinit(io, allocator);
    const moment = (if (event_db_maybe) |*event_db|
        evt.currentMomentFromDb(repo_opts.hash, event_db.db)
    else if (repo_kind == .git)
        return null
    else
        evt.currentMoment(repo_opts, repo)) catch return null;
    return readFromMoment(repo_opts.hash, arena, moment, id_bytes);
}

// the issue `id_bytes` names in a haxy moment, or null
fn readFromMoment(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    moment: evt.EventDB(hash_kind).HashMap(.read_only),
    id_bytes: *const [evt.event_id_size]u8,
) !?Record {
    const DB = evt.EventDB(hash_kind);
    const event_id_to_issue_cursor = (try moment.getCursor(hash.hashInt(hash_kind, record_map_key))) orelse return null;
    const event_id_to_issue = try DB.HashMap(.read_only).init(event_id_to_issue_cursor);
    const issue_cursor = (try event_id_to_issue.getCursor(hash.hashInt(hash_kind, id_bytes))) orelse return null;
    const issue_map = try DB.HashMap(.read_only).init(issue_cursor);
    return try evt.read(Record, DB, hash_kind, arena, issue_map);
}

// remove an issue's order key from its labels' `status` sets, pruning entries
// whose set becomes empty
fn removeFromLabelSets(
    comptime DB: type,
    label_to_issues: DB.SortedMap(.read_write),
    labels: []const u8,
    status: Status,
    order_key: []const u8,
) !void {
    var label_iter = labelIterator(labels);
    while (label_iter.next()) |label| {
        // skipped the same way consume skipped it, so it was never indexed
        if (label.len == 0 or label.len > label_max_len) continue;
        var key_buffer: LabelStatusKey = undefined;
        const key = try labelStatusKey(&key_buffer, label, status);
        const label_set_cursor = try label_to_issues.putCursor(key);
        const label_set = try DB.SortedSet(.read_write).init(label_set_cursor);
        _ = try label_set.remove(order_key);
        if (0 == try label_set.count()) _ = try label_to_issues.remove(key);
    }
}
