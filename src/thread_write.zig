//! the writes a repo's threads take: opening one, editing its fields,
//! closing or reopening it, and removing it (or a comment, attachment or
//! assignment under it). the TUI's thread tabs, Haxy's HTML forms and the
//! JSON API all write through these, so what a thread must hold and who may
//! change one live in one place:
//!
//! - who may write in a kind's tab at all is `ui.authorizeUser` (the repo
//!   role, then the kind's thread-creation role); local mode writes as its
//!   repo's owner, with the git config's author (`ui.localAuthor`);
//! - who may change an existing event is `ui.RepoSource.canModify`: anyone
//!   with the write role, otherwise only its author;
//! - what a thread's fields must be is the kind's own `fieldsValid`, and a
//!   comment's `evt.Comment.fieldsValid`;
//! - a reply's parent is the thread itself or a comment in it, and a comment
//!   is changed only through its own thread (`evt.threadHolds`);
//! - who is assigned is `ui.assigneeEmail` (an email, or an account's name
//!   on a server), and who may assign or unassign is `canModify` on the
//!   thread.
//!
//! patches have drafts, branches and forks of their own, which their callers
//! handle before (or instead of) these.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const evt = @import("./event.zig");
const ui = @import("./ui.zig");
const pch = @import("./patch.zig");

// serializes the writes to git repositories' events in this process. a git
// repo's events have no transaction, so each write here reads what it checks
// (whether an id is free, who wrote an event, an issue's revision) and
// writes while holding this, and no other write here can land in between.
// a git repo is only ever served by local mode, a single process serving
// one repo, so one lock is as fine-grained as it needs to be. xit repos
// check inside their write's transaction instead.
var git_events_mutex: std.Io.Mutex = .init;

// takes the git events lock for `source`'s writes, when it is a git repo;
// release with `unlockEvents` and the same answer
pub fn lockEvents(io: std.Io, source: ui.RepoSource) !bool {
    if (source.repo_kind != .git) return false;
    try git_events_mutex.lock(io);
    return true;
}

pub fn unlockEvents(io: std.Io, locked: bool) void {
    if (locked) git_events_mutex.unlock(io);
}

/// a thread's editable fields
pub const Fields = struct {
    title: []const u8,
    // space-separated
    labels: []const u8,
    description: []const u8,
    // a patch's target branch (patches only)
    target_branch: []const u8 = "",
};

/// `text` with the CRLF line breaks a form submission makes turned into plain
/// newlines, so a description reads the same on every host
pub fn plainNewlines(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, text, "\r\n", "\n");
}

/// why a thread's fields are refused
pub const FieldFailure = enum {
    // the title is empty or blank
    required_title,
    // a label is longer than a label may be
    invalid_labels,
};

/// what is wrong with `fields` for a thread of `kind`, or null when nothing is
pub fn checkFields(kind: evt.EventKind, fields: Fields) ?FieldFailure {
    const valid = switch (kind) {
        .issue => evt.Issue.fieldsValid(fields.title, fields.labels),
        .discuss => evt.Discussion.fieldsValid(fields.title, fields.labels),
        .patch => evt.Patch.fieldsValid(fields.title, fields.labels),
        else => unreachable,
    };
    if (valid) return null;
    return if (evt.titleValid(fields.title)) .invalid_labels else .required_title;
}

/// opens a thread of `kind` (an issue or a discussion) under `id`, written by
/// `author`. the caller has checked the fields (`checkFields`) and the
/// author's right to write in the kind's tab. a new id is random; one a
/// caller chose (so a retry can't open a second thread) fails with
/// error.IdTaken when any event already has it.
pub fn create(
    host: evt.Host,
    io: std.Io,
    allocator: std.mem.Allocator,
    source: ui.RepoSource,
    kind: evt.EventKind,
    id: *const [evt.event_id_size]u8,
    fields: Fields,
    author: evt.CommitAuthor,
) !void {
    const event = evt.EventWithId{
        .id = std.fmt.bytesToHex(id.*, .lower),
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author = author,
        .event = switch (kind) {
            .issue => .{ .issue = .{ .title = fields.title, .description = fields.description, .labels = fields.labels } },
            .discuss => .{ .discuss = .{ .title = fields.title, .description = fields.description, .labels = fields.labels } },
            else => unreachable,
        },
    };
    const locked = try lockEvents(io, source);
    defer unlockEvents(io, locked);
    try catchUp(host, io, allocator, source);
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| {
                    const repo_opts = repo.self_repo_opts;
                    if (repo_kind == .xit) {
                        // checked in the write's own transaction
                        try evt.consumeGuarded(host, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{event}, IdFree(repo_opts.hash){ .id = id });
                    } else {
                        // a git repo's events have no transaction to check in
                        if (try idUsed(repo_kind, repo_opts, io, allocator, repo, id)) return error.IdTaken;
                        try evt.consume(host, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{event});
                    }
                },
            }
        },
    }
}

/// opens a branch-backed patch under `id`, proposing what `source_branch`
/// has that `fields.target_branch` lacks, written by `author`: both must be
/// existing, distinct branches with a common ancestor (error.InvalidSourceBranch,
/// error.InvalidTargetBranch, error.SameBranch, error.UnrelatedBranches),
/// and the patch captures the source's revision as it is now. the caller
/// has checked the fields (`checkFields`) and the author's right to write in
/// the patches tab. error.IdTaken when any event already has the id, so a
/// retry can't open a second patch. a patch from a new fork is
/// `ui.Repo.Patches.create`'s.
pub fn createBranchPatch(
    host: evt.Host,
    io: std.Io,
    allocator: std.mem.Allocator,
    source: ui.RepoSource,
    id: *const [evt.event_id_size]u8,
    fields: Fields,
    source_branch: []const u8,
    author: evt.CommitAuthor,
) !void {
    const locked = try lockEvents(io, source);
    defer unlockEvents(io, locked);
    try catchUp(host, io, allocator, source);
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| {
                    const repo_opts = repo.self_repo_opts;
                    // a xit repo checks the id in the write's own transaction
                    if (repo_kind != .xit and try idUsed(repo_kind, repo_opts, io, allocator, repo, id)) return error.IdTaken;
                    try pch.writeBranchPatch(host, repo_kind, repo_opts, io, allocator, repo, std.fmt.bytesToHex(id.*, .lower), .{
                        .title = fields.title,
                        .labels = fields.labels,
                        .description = fields.description,
                        .source_branch = source_branch,
                        .target_branch = fields.target_branch,
                    }, null, author);
                },
            }
        },
    }
}

// brings a local repo's event db up to date with its events branch, as each
// TUI page build and API read there does: a branch fetched, cloned or synced
// since anything last read it would otherwise go unseen by the checks a
// write makes (whether an id is free, who wrote an event, what an issue
// holds). a server's repos consume every event, pushed ones included, in
// the transaction that writes it.
fn catchUp(host: evt.Host, io: std.Io, allocator: std.mem.Allocator, source: ui.RepoSource) !void {
    if (host != .local) return;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| try evt.consume(.local, .repo, repo_kind, repo.self_repo_opts, io, allocator, repo, evt.events_ref, &.{}),
            }
        },
    }
}

// fails with error.IdTaken when the moment already holds an event with the id
fn IdFree(comptime hash_kind: hash.HashKind) type {
    return struct {
        id: *const [evt.event_id_size]u8,

        pub fn check(self: @This(), moment_maybe: ?evt.EventDB(hash_kind).HashMap(.read_only)) !void {
            if (try kindOf(hash_kind, moment_maybe orelse return, self.id) != null) return error.IdTaken;
        }
    };
}

/// the kind of the event `id` names in `moment`, or null when none has it
pub fn kindOf(comptime hash_kind: hash.HashKind, moment: evt.EventDB(hash_kind).HashMap(.read_only), id: *const [evt.event_id_size]u8) !?evt.EventKind {
    const DB = evt.EventDB(hash_kind);
    const kinds_cursor = try moment.getCursor(hash.hashInt(hash_kind, evt.event_index_key)) orelse return null;
    return evt.readEventKind(hash_kind, try DB.HashMap(.read_only).init(kinds_cursor), id);
}

// whether any event in the repo's consumed events has `id`
fn idUsed(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    id: *const [evt.event_id_size]u8,
) !bool {
    var event_db_maybe: ?evt.LocalEventDB(repo_opts.hash) = if (repo_kind == .git) try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, allocator, repo.core.repo_dir) else null;
    defer if (event_db_maybe) |*event_db| event_db.deinit(io, allocator);
    const moment = (if (event_db_maybe) |*event_db|
        evt.currentMomentFromDb(repo_opts.hash, event_db.db)
    else if (repo_kind == .git)
        return false
    else
        evt.currentMoment(repo_opts, repo)) catch return false;
    return try kindOf(repo_opts.hash, moment, id) != null;
}

/// sets the status of the thread `id` names (an issue or a patch, as
/// `Event` says), as `actor`. error.Forbidden when the actor may not change
/// it, error.NotFound when there is no such thread. setting the status it
/// already has changes nothing. reopening a branch patch captures its source
/// branch's revision again (its branch errors, as `createBranchPatch`'s),
/// and is error.Stale when the patch changed meanwhile.
pub fn setStatus(
    comptime Event: type,
    host: evt.Host,
    io: std.Io,
    allocator: std.mem.Allocator,
    source: ui.RepoSource,
    actor: ui.Actor,
    id: *const [evt.event_id_size]u8,
    status: @FieldType(Event.Update, "status"),
) !void {
    const locked = try lockEvents(io, source);
    defer unlockEvents(io, locked);
    try catchUp(host, io, allocator, source);
    if (!try source.canModify(io, allocator, actor, eventKind(Event), id)) return error.Forbidden;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                // reopening a branch patch captures its source, written only
                // while the patch is still as read
                inline else => |*repo| Event.update(host, repo_kind, repo.self_repo_opts, io, allocator, repo, id, .{ .status = status }, actor.author) catch |err| switch (err) {
                    error.PatchOutOfDate => return error.Stale,
                    else => |e| return e,
                },
            }
        },
    }
}

/// replaces the fields of the thread of `kind` (an issue, a discussion or a
/// patch) that `id` names, keeping its status, as `actor`; with a `revision`
/// (the kind's `contentRevision`), only while the thread is still at it
/// (error.Stale otherwise). error.Forbidden when the actor may not change
/// it, error.NotFound when there is no such thread of that kind. the caller
/// has checked the fields (`checkFields`). a patch's fields include its
/// target branch: another existing branch than its source, sharing history
/// with it (error.InvalidTargetBranch, error.SameBranch,
/// error.UnrelatedBranches); a new one captures a fresh revision, and a
/// merged patch's target stays (error.PatchAlreadyMerged).
pub fn edit(
    host: evt.Host,
    io: std.Io,
    allocator: std.mem.Allocator,
    source: ui.RepoSource,
    actor: ui.Actor,
    kind: evt.EventKind,
    id: *const [evt.event_id_size]u8,
    fields: Fields,
    revision: ?evt.Issue.Revision,
) !void {
    const locked = try lockEvents(io, source);
    defer unlockEvents(io, locked);
    try catchUp(host, io, allocator, source);
    if (!try source.canModify(io, allocator, actor, kind, id)) return error.Forbidden;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| switch (kind) {
                    .issue => try evt.Issue.updateAt(host, repo_kind, repo.self_repo_opts, io, allocator, repo, id, .{ .fields = .{
                        .title = fields.title,
                        .labels = fields.labels,
                        .description = fields.description,
                    } }, actor.author, revision),
                    .discuss => try evt.Discussion.updateAt(host, repo_kind, repo.self_repo_opts, io, allocator, repo, id, .{
                        .title = fields.title,
                        .labels = fields.labels,
                        .description = fields.description,
                    }, actor.author, revision),
                    // a new target captures a fresh revision of a branch
                    // patch, written only while the patch is as it was read
                    .patch => evt.Patch.updateAt(host, repo_kind, repo.self_repo_opts, io, allocator, repo, id, .{ .fields = .{
                        .title = fields.title,
                        .labels = fields.labels,
                        .description = fields.description,
                        .target_branch = fields.target_branch,
                    } }, actor.author, revision) catch |err| switch (err) {
                        error.PatchOutOfDate => return error.Stale,
                        else => |e| return e,
                    },
                    else => unreachable,
                },
            }
        },
    }
}

/// removes the event `id` names, of `kind`: the thread `thread_id` itself
/// (when `kind` is `thread_kind`), or a comment, attachment or assignment that
/// belongs to it, as `actor`. error.Forbidden when the actor may not change
/// it, error.NotFound when there is no such event in that thread.
pub fn remove(
    host: evt.Host,
    io: std.Io,
    allocator: std.mem.Allocator,
    source: ui.RepoSource,
    actor: ui.Actor,
    thread_kind: evt.EventKind,
    thread_id: *const [evt.event_id_size]u8,
    kind: evt.EventKind,
    id: *const [evt.event_id_size]u8,
) !void {
    const locked = try lockEvents(io, source);
    defer unlockEvents(io, locked);
    try catchUp(host, io, allocator, source);
    // an attachment that isn't live on this thread is gone for everyone,
    // whoever asks, before their rights to it are checked: a removed one
    // isn't listed anywhere
    if (kind == .attach) switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| {
                    if (!try evt.threadHolds(repo_kind, repo.self_repo_opts, io, allocator, repo, thread_kind, thread_id, .{ .attach = id })) return error.NotFound;
                    if (try attachmentRemoved(repo_kind, repo.self_repo_opts, io, allocator, repo, id)) return error.NotFound;
                },
            }
        },
    };
    if (!try source.canModify(io, allocator, actor, kind, id)) return error.Forbidden;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| {
                    // a thread removed already stays removed
                    if (kind == thread_kind and !try threadLive(repo_kind, repo.self_repo_opts, io, allocator, repo, kind, id)) return error.NotFound;
                    // a removed comment stays in its thread; removing it again
                    // changes nothing, so writes nothing
                    if (kind == .comment and try commentRemoved(repo_kind, repo.self_repo_opts, io, allocator, repo, id)) {
                        if (!try evt.threadHolds(repo_kind, repo.self_repo_opts, io, allocator, repo, thread_kind, thread_id, .{ .comment = id })) return error.NotFound;
                        return;
                    }
                    evt.removeInThread(host, repo_kind, repo.self_repo_opts, io, allocator, repo, thread_kind, thread_id, kind, id, actor.author) catch |err| switch (err) {
                        error.EventNotFound => return error.NotFound,
                        else => |e| return e,
                    };
                },
            }
        },
    }
}

// whether the comment `id` names exists and has been removed
fn commentRemoved(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    id: *const [evt.event_id_size]u8,
) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const record = (try evt.readFromRepo(evt.Comment, repo_kind, repo_opts, io, allocator, &arena, repo, id)) orelse return false;
    return record.removed;
}

// whether the attachment `id` names exists and has been removed
fn attachmentRemoved(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    id: *const [evt.event_id_size]u8,
) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const record = (try evt.readFromRepo(evt.Attachment, repo_kind, repo_opts, io, allocator, &arena, repo, id)) orelse return false;
    return record.removed;
}

// whether the thread `id` names exists and isn't removed
fn threadLive(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    kind: evt.EventKind,
    id: *const [evt.event_id_size]u8,
) !bool {
    var event_db_maybe: ?evt.LocalEventDB(repo_opts.hash) = if (repo_kind == .git) try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, allocator, repo.core.repo_dir) else null;
    defer if (event_db_maybe) |*event_db| event_db.deinit(io, allocator);
    const moment = (if (event_db_maybe) |*event_db|
        evt.currentMomentFromDb(repo_opts.hash, event_db.db)
    else if (repo_kind == .git)
        return false
    else
        evt.currentMoment(repo_opts, repo)) catch return false;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return threadLiveAt(repo_opts.hash, &arena, moment, kind, id);
}

// whether `moment` holds a thread of `kind` under `id` that isn't removed
pub fn threadLiveAt(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    moment: evt.EventDB(hash_kind).HashMap(.read_only),
    kind: evt.EventKind,
    id: *const [evt.event_id_size]u8,
) !bool {
    if (try kindOf(hash_kind, moment, id) != kind) return false;
    const Removed = struct { removed: bool };
    const DB = evt.EventDB(hash_kind);
    const record = switch (kind) {
        .issue => try evt.readRecordSubset(evt.Issue, Removed, DB, hash_kind, moment, arena, id),
        .discuss => try evt.readRecordSubset(evt.Discussion, Removed, DB, hash_kind, moment, arena, id),
        .patch => try evt.readRecordSubset(evt.Patch, Removed, DB, hash_kind, moment, arena, id),
        else => return false,
    } orelse return false;
    return !record.removed;
}

// --- assignees -----------------------------------------------------------------

/// what assigning someone came to: the assignment's event id, or the TUI's
/// reason for refusing it (a name no account holds, text that is no email,
/// someone already assigned)
pub const Assigned = union(enum) {
    assigned: [evt.event_id_size]u8,
    refused: ui.Session.FormFeedback.AssignmentFailure,
};

/// assigns `text` to the thread of `thread_kind` that `thread_id` names, as
/// `actor`: an email as itself, otherwise the email of the account `text`
/// names in `admin_moment` (null in local mode, which has no accounts and
/// so assigns by email only; `ui.assigneeEmail`). error.Forbidden when the
/// actor may not change the thread (`ui.RepoSource.canModify`: its author or
/// a writer), error.NotFound when there is no such live thread. the thread
/// and whether the email is assigned already are checked where the write
/// lands: in a xit repo's transaction, under the git events lock otherwise.
pub fn assign(
    host: evt.Host,
    io: std.Io,
    allocator: std.mem.Allocator,
    source: ui.RepoSource,
    actor: ui.Actor,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    thread_kind: evt.EventKind,
    thread_id: *const [evt.event_id_size]u8,
    text: []const u8,
) !Assigned {
    const locked = try lockEvents(io, source);
    defer unlockEvents(io, locked);
    try catchUp(host, io, allocator, source);
    if (!try source.canModify(io, allocator, actor, thread_kind, thread_id)) return error.Forbidden;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const email = switch (try ui.assigneeEmail(admin_moment, &arena, text)) {
        .email => |email| email,
        .failure => |failure| return .{ .refused = failure },
    };
    if (!evt.Assignment.emailValid(email)) return .{ .refused = .not_an_email };

    const id = evt.Assignment.idOf(thread_id, email);
    const event = evt.EventWithId{
        .id = std.fmt.bytesToHex(id, .lower),
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author = actor.author,
        .event = .{ .assign = .{ .thread_id = std.fmt.bytesToHex(thread_id.*, .lower), .email = email } },
    };
    writeAssignment(host, io, allocator, source, event, .{ .thread_kind = thread_kind, .thread_id = thread_id, .id = &id, .want = .unassigned }) catch |err| switch (err) {
        error.AlreadyAssigned => return .{ .refused = .already_assigned },
        else => |e| return e,
    };
    return .{ .assigned = id };
}

/// unassigns the assignment `id` names (`evt.Assignment.idOf` the thread and
/// the email) from the thread of `thread_kind` that `thread_id` names, as
/// `actor`. error.Forbidden and error.NotFound as for `assign`;
/// error.NotAssigned when the thread has no such assignment now (never made,
/// or already undone), which changes nothing.
pub fn unassign(
    host: evt.Host,
    io: std.Io,
    allocator: std.mem.Allocator,
    source: ui.RepoSource,
    actor: ui.Actor,
    thread_kind: evt.EventKind,
    thread_id: *const [evt.event_id_size]u8,
    id: *const [evt.event_id_size]u8,
) !void {
    const locked = try lockEvents(io, source);
    defer unlockEvents(io, locked);
    try catchUp(host, io, allocator, source);
    if (!try source.canModify(io, allocator, actor, thread_kind, thread_id)) return error.Forbidden;

    const event = evt.EventWithId{
        .id = std.fmt.bytesToHex(id.*, .lower),
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author = actor.author,
        .event = .{ .assign = null },
    };
    try writeAssignment(host, io, allocator, source, event, .{ .thread_kind = thread_kind, .thread_id = thread_id, .id = id, .want = .assigned });
}

// what an assignment write requires of the state it lands on: a live thread,
// and the assignment `id` in the state the write changes
const AssignmentCheck = struct {
    thread_kind: evt.EventKind,
    thread_id: *const [evt.event_id_size]u8,
    id: *const [evt.event_id_size]u8,
    want: enum { assigned, unassigned },

    fn run(self: AssignmentCheck, comptime hash_kind: hash.HashKind, allocator: std.mem.Allocator, moment_maybe: ?evt.EventDB(hash_kind).HashMap(.read_only)) !void {
        const moment = moment_maybe orelse return error.NotFound;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        if (!try threadLiveAt(hash_kind, &arena, moment, self.thread_kind, self.thread_id)) return error.NotFound;
        const Stored = struct { removed: bool, event: struct { thread_id: [evt.event_id_size * 2]u8 } };
        const record = try evt.readRecordSubset(evt.Assignment, Stored, evt.EventDB(hash_kind), hash_kind, moment, &arena, self.id);
        const active = if (record) |assignment|
            !assignment.removed and std.mem.eql(u8, &assignment.event.thread_id, &std.fmt.bytesToHex(self.thread_id.*, .lower))
        else
            false;
        switch (self.want) {
            .assigned => if (!active) return error.NotAssigned,
            .unassigned => if (active) return error.AlreadyAssigned,
        }
    }
};

// `check`, as consumeGuarded runs it inside a xit repo's transaction
fn AssignmentGuard(comptime hash_kind: hash.HashKind) type {
    return struct {
        allocator: std.mem.Allocator,
        rules: AssignmentCheck,

        pub fn check(self: @This(), moment_maybe: ?evt.EventDB(hash_kind).HashMap(.read_only)) !void {
            return self.rules.run(hash_kind, self.allocator, moment_maybe);
        }
    };
}

// writes an assignment `event` once `check` holds where it lands. the caller
// holds the git events lock, when there is one.
fn writeAssignment(host: evt.Host, io: std.Io, allocator: std.mem.Allocator, source: ui.RepoSource, event: evt.EventWithId, check: AssignmentCheck) !void {
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| {
                    const repo_opts = repo.self_repo_opts;
                    if (repo_kind == .xit) {
                        return evt.consumeGuarded(host, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{event}, AssignmentGuard(repo_opts.hash){ .allocator = allocator, .rules = check });
                    }
                    {
                        var event_db_maybe = try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, allocator, repo.core.repo_dir);
                        defer if (event_db_maybe) |*event_db| event_db.deinit(io, allocator);
                        const moment = if (event_db_maybe) |*event_db| evt.currentMomentFromDb(repo_opts.hash, event_db.db) catch null else null;
                        try check.run(repo_opts.hash, allocator, moment);
                    }
                    try evt.consume(host, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{event});
                },
            }
        },
    }
}

/// posts a comment on the thread `thread_id` names, of `thread_kind`: a reply
/// to its comment `parent_id`, or to the thread itself when that is null,
/// under `id`, written by `author`. the caller has checked the author's right
/// to write in the kind's tab. error.InvalidFields for a body
/// `evt.Comment.fieldsValid` refuses; error.NotFound when the thread isn't
/// one of that kind or the parent isn't a comment in it; error.IdTaken when
/// any event already has the id, so a retried post can't post twice.
pub fn comment(
    host: evt.Host,
    io: std.Io,
    allocator: std.mem.Allocator,
    source: ui.RepoSource,
    thread_kind: evt.EventKind,
    thread_id: *const [evt.event_id_size]u8,
    parent_id: ?*const [evt.event_id_size]u8,
    id: *const [evt.event_id_size]u8,
    body: []const u8,
    author: evt.CommitAuthor,
) !void {
    if (!evt.Comment.fieldsValid(body)) return error.InvalidFields;
    // the thread itself is no comment, so naming it as the parent is no reply
    const parent: ?*const [evt.event_id_size]u8 = if (parent_id) |p| (if (std.mem.eql(u8, p, thread_id)) null else p) else null;
    const event = evt.EventWithId{
        .id = std.fmt.bytesToHex(id.*, .lower),
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author = author,
        .event = .{ .comment = .{
            .thread_id = std.fmt.bytesToHex(thread_id.*, .lower),
            .parent_id = std.fmt.bytesToHex((parent orelse thread_id).*, .lower),
            .body = body,
        } },
    };
    const locked = try lockEvents(io, source);
    defer unlockEvents(io, locked);
    try catchUp(host, io, allocator, source);
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| {
                    const repo_opts = repo.self_repo_opts;
                    const child: ?evt.ThreadChild = if (parent) |p| .{ .comment = p } else null;
                    if (!try evt.threadHolds(repo_kind, repo_opts, io, allocator, repo, thread_kind, thread_id, child)) return error.NotFound;
                    if (repo_kind == .xit) {
                        try evt.consumeGuarded(host, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{event}, IdFree(repo_opts.hash){ .id = id });
                    } else {
                        if (try idUsed(repo_kind, repo_opts, io, allocator, repo, id)) return error.IdTaken;
                        try evt.consume(host, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{event});
                    }
                },
            }
        },
    }
}

/// replaces the body of the comment `id` names, in the thread `thread_id`
/// names, as `actor`; with a `revision` (`evt.Comment.contentRevision`), only
/// while its body is still at it (error.Stale otherwise). error.InvalidFields
/// for a body `evt.Comment.fieldsValid` refuses, error.NotFound when the
/// comment isn't in that thread, error.Forbidden when the actor may not
/// change it, error.Removed once it has been removed.
pub fn editComment(
    host: evt.Host,
    io: std.Io,
    allocator: std.mem.Allocator,
    source: ui.RepoSource,
    actor: ui.Actor,
    thread_kind: evt.EventKind,
    thread_id: *const [evt.event_id_size]u8,
    id: *const [evt.event_id_size]u8,
    body: []const u8,
    revision: ?evt.Comment.Revision,
) !void {
    if (!evt.Comment.fieldsValid(body)) return error.InvalidFields;
    const locked = try lockEvents(io, source);
    defer unlockEvents(io, locked);
    try catchUp(host, io, allocator, source);
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| if (!try evt.threadHolds(repo_kind, repo.self_repo_opts, io, allocator, repo, thread_kind, thread_id, .{ .comment = id })) return error.NotFound,
            }
        },
    }
    if (!try source.canModify(io, allocator, actor, .comment, id)) return error.Forbidden;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| {
                    const repo_opts = repo.self_repo_opts;
                    var arena = std.heap.ArenaAllocator.init(allocator);
                    defer arena.deinit();
                    const record = (try evt.readFromRepo(evt.Comment, repo_kind, repo_opts, io, allocator, &arena, repo, id)) orelse return error.NotFound;
                    var events = [_]evt.EventWithId{.{
                        .id = std.fmt.bytesToHex(id.*, .lower),
                        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
                        .author = actor.author,
                        .event = .{ .comment = undefined },
                    }};
                    const rebase = CommentRebase(repo_opts.hash){ .arena = &arena, .id = id, .body = body, .revision = revision, .event = &events[0] };
                    if (repo_kind == .xit) {
                        // checked again in the write's own transaction, from
                        // the comment as it is there
                        try evt.consumeGuarded(host, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &events, rebase);
                    } else {
                        // a git repo's events have no transaction; the lock
                        // holds the read and the write together
                        try rebase.apply(record);
                        try evt.consume(host, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &events);
                    }
                },
            }
        },
    }
}

// builds a comment edit's event from the comment as it is, refusing a
// removed comment and a stale revision; a xit repo runs it inside the
// write's transaction
fn CommentRebase(comptime hash_kind: hash.HashKind) type {
    return struct {
        // holds the read record's strings until the write is done
        arena: *std.heap.ArenaAllocator,
        id: *const [evt.event_id_size]u8,
        body: []const u8,
        revision: ?evt.Comment.Revision,
        event: *evt.EventWithId,

        pub fn check(self: @This(), moment_maybe: ?evt.EventDB(hash_kind).HashMap(.read_only)) !void {
            const DB = evt.EventDB(hash_kind);
            const record = (try evt.Comment.readById(DB, hash_kind, moment_maybe orelse return error.NotFound, self.arena, self.id)) orelse return error.NotFound;
            try self.apply(record);
        }

        fn apply(self: @This(), record: evt.Comment.Record) !void {
            if (record.removed) return error.Removed;
            if (self.revision) |expected| {
                if (!std.mem.eql(u8, &evt.Comment.contentRevision(record.event), &expected)) return error.Stale;
            }
            var updated = record.event;
            updated.body = self.body;
            self.event.event = .{ .comment = updated };
        }
    };
}

fn eventKind(comptime Event: type) evt.EventKind {
    return switch (Event) {
        evt.Issue => .issue,
        evt.Patch => .patch,
        evt.Discussion => .discuss,
        else => @compileError("not a thread's event"),
    };
}

// --- attachments -----------------------------------------------------------------

/// attaches `blob` (one file, streamed from its reader into the object store)
/// to the thread of `thread_kind` that `thread_id` names, under `id`, as
/// `actor`. the caller has checked the upload (`attachment.checkUpload`) and
/// the actor's right to write in the kind's tab. error.Forbidden when the
/// actor may not change the thread (`ui.RepoSource.canModify`: its author or
/// a writer, as Haxy's upload form has always required), error.NotFound when
/// there is no such live thread, error.IdTaken when any event already has
/// the id, so a retried upload can't attach twice. the thread and the id are
/// checked where the write lands: in a xit repo's transaction, under the git
/// events lock otherwise.
pub fn attach(
    host: evt.Host,
    io: std.Io,
    allocator: std.mem.Allocator,
    source: ui.RepoSource,
    actor: ui.Actor,
    thread_kind: evt.EventKind,
    thread_id: *const [evt.event_id_size]u8,
    id: *const [evt.event_id_size]u8,
    blob: evt.Blob,
) !void {
    if (!evt.Attachment.nameValid(blob.name) or blob.size == 0 or blob.size > evt.Attachment.max_size) return error.InvalidFields;
    const locked = try lockEvents(io, source);
    defer unlockEvents(io, locked);
    try catchUp(host, io, allocator, source);
    if (!try source.canModify(io, allocator, actor, thread_kind, thread_id)) return error.Forbidden;

    const event = evt.EventWithId{
        .id = std.fmt.bytesToHex(id.*, .lower),
        .timestamp = @intCast(std.Io.Timestamp.now(io, .real).toSeconds()),
        .author = actor.author,
        .tree_entries = &.{.{ .blob = blob }},
        .event = .{ .attach = .{ .target_id = std.fmt.bytesToHex(thread_id.*, .lower) } },
    };
    const check: AttachCheck = .{ .thread_kind = thread_kind, .thread_id = thread_id, .id = id };
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| {
                    const repo_opts = repo.self_repo_opts;
                    if (repo_kind == .xit) {
                        return evt.consumeGuarded(host, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{event}, AttachGuard(repo_opts.hash){ .allocator = allocator, .rules = check });
                    }
                    {
                        var event_db_maybe = try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, allocator, repo.core.repo_dir);
                        defer if (event_db_maybe) |*event_db| event_db.deinit(io, allocator);
                        const moment = if (event_db_maybe) |*event_db| evt.currentMomentFromDb(repo_opts.hash, event_db.db) catch null else null;
                        try check.run(repo_opts.hash, allocator, moment);
                    }
                    try evt.consume(host, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{event});
                },
            }
        },
    }
}

// what an attachment requires of the state it lands on: a live thread, and
// its id free
const AttachCheck = struct {
    thread_kind: evt.EventKind,
    thread_id: *const [evt.event_id_size]u8,
    id: *const [evt.event_id_size]u8,

    fn run(self: AttachCheck, comptime hash_kind: hash.HashKind, allocator: std.mem.Allocator, moment_maybe: ?evt.EventDB(hash_kind).HashMap(.read_only)) !void {
        const moment = moment_maybe orelse return error.NotFound;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        if (!try threadLiveAt(hash_kind, &arena, moment, self.thread_kind, self.thread_id)) return error.NotFound;
        if (try kindOf(hash_kind, moment, self.id) != null) return error.IdTaken;
    }
};

// `check`, as consumeGuarded runs it inside a xit repo's transaction
fn AttachGuard(comptime hash_kind: hash.HashKind) type {
    return struct {
        allocator: std.mem.Allocator,
        rules: AttachCheck,

        pub fn check(self: @This(), moment_maybe: ?evt.EventDB(hash_kind).HashMap(.read_only)) !void {
            return self.rules.run(hash_kind, self.allocator, moment_maybe);
        }
    };
}
