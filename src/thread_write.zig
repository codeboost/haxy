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
//! - what a thread's fields must be is the kind's own `fieldsValid`.
//!
//! patches have drafts, branches and forks of their own, which their callers
//! handle before (or instead of) these.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const evt = @import("./event.zig");
const ui = @import("./ui.zig");

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

fn kindOf(comptime hash_kind: hash.HashKind, moment: evt.EventDB(hash_kind).HashMap(.read_only), id: *const [evt.event_id_size]u8) !?evt.EventKind {
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
/// already has changes nothing.
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
                inline else => |*repo| try Event.update(host, repo_kind, repo.self_repo_opts, io, allocator, repo, id, .{ .status = status }, actor.author),
            }
        },
    }
}

/// replaces the fields of the issue `id` names, keeping its status, as
/// `actor`; with a `revision`, only while the issue is still at it
/// (error.Stale otherwise). error.Forbidden when the actor may not change
/// it, error.NotFound when there is no such issue. the caller has checked
/// the fields (`checkFields`).
pub fn editIssue(
    host: evt.Host,
    io: std.Io,
    allocator: std.mem.Allocator,
    source: ui.RepoSource,
    actor: ui.Actor,
    id: *const [evt.event_id_size]u8,
    fields: Fields,
    revision: ?evt.Issue.Revision,
) !void {
    const locked = try lockEvents(io, source);
    defer unlockEvents(io, locked);
    try catchUp(host, io, allocator, source);
    if (!try source.canModify(io, allocator, actor, .issue, id)) return error.Forbidden;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| try evt.Issue.updateAt(host, repo_kind, repo.self_repo_opts, io, allocator, repo, id, .{ .fields = .{
                    .title = fields.title,
                    .labels = fields.labels,
                    .description = fields.description,
                } }, actor.author, revision),
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
    if (!try source.canModify(io, allocator, actor, kind, id)) return error.Forbidden;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| {
                    // a thread removed already stays removed
                    if (kind == thread_kind and !try threadLive(repo_kind, repo.self_repo_opts, io, allocator, repo, kind, id)) return error.NotFound;
                    evt.removeInThread(host, repo_kind, repo.self_repo_opts, io, allocator, repo, thread_kind, thread_id, kind, id, actor.author) catch |err| switch (err) {
                        error.EventNotFound => return error.NotFound,
                        else => |e| return e,
                    };
                },
            }
        },
    }
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
    const Removed = struct { removed: bool };
    const DB = evt.EventDB(repo_opts.hash);
    const record = switch (kind) {
        .issue => try evt.readRecordSubset(evt.Issue, Removed, DB, repo_opts.hash, moment, &arena, id),
        .discuss => try evt.readRecordSubset(evt.Discussion, Removed, DB, repo_opts.hash, moment, &arena, id),
        .patch => try evt.readRecordSubset(evt.Patch, Removed, DB, repo_opts.hash, moment, &arena, id),
        else => unreachable,
    } orelse return false;
    return !record.removed;
}

fn eventKind(comptime Event: type) evt.EventKind {
    return switch (Event) {
        evt.Issue => .issue,
        evt.Patch => .patch,
        evt.Discussion => .discuss,
        else => @compileError("not a thread's event"),
    };
}
