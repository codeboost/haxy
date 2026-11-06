//! local mode's event sync in the JSON API: `/api/v1/repo/sync` reads how the
//! repo's events branch stands against its remote, and runs a sync. the sync
//! is the TUI's own (`ui.Repo.Events.runSync`): the same fetch, merge rules,
//! push and confirmation, moving only the events branch. a server's repos
//! take pushes instead, so a server answers the route with `unsupported`.
//!
//! a sync runs within its POST, which answers once it has finished, with an
//! explicit outcome: it synced, or it failed at a named step, which says what
//! it left behind. local events are never discarded.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const api_repo = @import("./repo.zig");
const api_thread = @import("./thread.zig");
const api_events = @import("./events.zig");
const api_path = @import("./path.zig");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");

const Events = ui.Repo.Events;

pub const path = "/api/v1/repo/sync";

// how many conflicted issues an answer names; the count covers them all
const conflicts_shown = Events.page_size;

/// whether `request_path` is the sync route
pub fn route(request_path: []const u8) bool {
    return std.mem.eql(u8, request_path, path);
}

pub const in_progress: api.Error = .{ .code = .conflict, .message = "A sync is already running. Wait for it to finish, then check the result." };

pub fn handle(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    host: api_repo.Host,
) !void {
    const method = request.head.method;
    if (method != .GET and method != .HEAD and method != .POST)
        return api.respondError(request, allocator, .{ .code = .unsupported, .message = "This route only supports GET, HEAD and POST." }, .{ .allow = "GET, HEAD, POST" });
    if (host == .server)
        return api.respondError(request, allocator, .{ .code = .unsupported, .message = "Only local mode syncs events with a remote; a server's repositories take pushes." }, .{});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    var opened = (try api_thread.openRepo(io, request, allocator, &arena, host, null, .local, &admin_repo_maybe)) orelse return;
    // syncing is the events tab's, which needs write access (always the
    // case locally, where the user is the repo's owner)
    if (!ui.Repo.hasSection(.events, opened.resolved.repo.event, opened.handle, opened.session.data.host_kind, opened.source.repo_kind))
        return api.respondError(request, allocator, api_events.not_eligible, .{});

    var record: Events.LastSync = undefined;
    var snapshot: Events.SyncSnapshot = undefined;
    if (method == .POST) {
        var result = Events.runSync(io, allocator, opened.source, &record) catch |err| switch (err) {
            error.SyncInProgress => return api.respondError(request, allocator, in_progress, .{}),
            else => |e| return e,
        };
        result.deinit(allocator);
        // this sync, and whether another started since
        snapshot = .{ .running = Events.syncRunning(io), .last = &record };
    } else {
        snapshot = Events.syncSnapshot(io, &record);
    }

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    try writeStatus(&arena, io, &opened, snapshot, &body.writer);
    return api.respondJson(request, body.written(), .{});
}

/// the status body: where the events branch stands, `snapshot`'s running
/// flag and last sync, and the unresolved conflicts
pub fn writeStatus(
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    opened: *api_thread.Opened,
    snapshot: Events.SyncSnapshot,
    writer: *std.Io.Writer,
) !void {
    const aa = arena.allocator();
    const gpa = arena.child_allocator;
    const source = opened.source;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, gpa, source.localInitOpts());
            defer any_repo.deinit(io, gpa);
            switch (any_repo) {
                inline else => |*repo| {
                    const repo_opts = repo.self_repo_opts;
                    // refs only, which no sync step holds
                    const status = try Events.syncStatus(repo_kind, repo_opts, repo, io, aa);
                    // the outcome is answered even when the conflicts can't be
                    // read (events that can't be consumed): they are null then
                    const conflicts = readConflicts(repo_kind, repo_opts, arena, repo, io, opened) catch |err| switch (err) {
                        error.OutOfMemory => |e| return e,
                        else => null,
                    };

                    try std.json.Stringify.value(.{
                        .remote = try remoteDisplay(aa, status.remote),
                        .state = status.state,
                        .running = snapshot.running,
                        .last = if (snapshot.last) |record| Last{ .record = record } else null,
                        .conflicts = conflicts,
                    }, .{}, writer);
                },
            }
        },
    }
}

/// a remote's name as an answer shows it: git allows any bytes, and those that
/// aren't utf-8 become U+FFFD, as for repository paths (sync takes no remote,
/// so nothing needs the name back)
pub fn remoteDisplay(aa: std.mem.Allocator, name: ?[]const u8) !?[]const u8 {
    return if (name) |bytes| try api_path.display(aa, bytes) else null;
}

const Conflicts = struct {
    issues: struct { count: api.Count, items: []const api_thread.Summary(evt.Issue.Status) },
    patches: struct { count: api.Count },
};

// the unresolved conflicts the TUI's issues and patches tabs list, after
// bringing the event db up to date with the events branch (as each TUI page
// build does) unless a sync holds the repo's database: a xit repo's fetch
// keeps it for the whole network exchange, and a status read mustn't wait on
// that, so it reads what is already committed instead
fn readConflicts(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    opened: *api_thread.Opened,
) !Conflicts {
    const aa = arena.allocator();
    const gpa = arena.child_allocator;
    switch (repo_kind) {
        .git => try evt.consume(.local, .repo, repo_kind, repo_opts, io, gpa, repo, evt.events_ref, &.{}),
        // held across the consume, which takes it again on this same open
        // file (and releases it), so no sync can start in between
        .xit => if (try repo.core.db_file.tryLock(io, .exclusive)) {
            defer repo.core.db_file.unlock(io);
            try evt.consume(.local, .repo, repo_kind, repo_opts, io, gpa, repo, evt.events_ref, &.{});
        },
    }

    const resolved = opened.resolved;
    const issues = try ui.Repo.Issues.init(repo_kind, repo_opts, arena, repo, io, null, resolved.identity, "", "", "", 0, "", .conflicts, ui.Repo.tabViewer(opened.handle, resolved.repo, .issue), .{ .shown = conflicts_shown, .others = 0 });
    const patches = try ui.Repo.Patches.init(repo_kind, repo_opts, arena, repo, io, null, &opened.session, resolved.repo_id, resolved.identity, "", "", "", "", 0, "", .conflicts, ui.Repo.tabViewer(opened.handle, resolved.repo, .patch));
    const items = try aa.alloc(api_thread.Summary(evt.Issue.Status), issues.conflicts.items.len);
    for (items, issues.conflicts.items) |*item, *entry| item.* = try api_thread.summary(aa, entry, "");
    return .{
        .issues = .{ .count = api_thread.count(issues.conflicts), .items = items },
        .patches = .{ .count = api_thread.count(patches.conflicts) },
    };
}

/// a finished sync: `{"id", "outcome", "finished_at", "failure"}`, where
/// `failure` is null when it synced and otherwise names the step it stopped
/// at, with Haxy's message and the remote's own when it gave one
const Last = struct {
    record: *const Events.LastSync,

    pub fn jsonStringify(self: Last, json: *std.json.Stringify) std.Io.Writer.Error!void {
        const record = self.record;
        try json.beginObject();
        try json.objectField("id");
        var id_buffer: [Events.LastSync.max_id_text]u8 = undefined;
        try json.write(record.idText(&id_buffer));
        try json.objectField("outcome");
        try json.write(if (record.failure == null) "synced" else "failed");
        try json.objectField("finished_at");
        try json.write(api.Instant{ .seconds = @intCast(@max(record.finished_at, 0)) });
        try json.objectField("failure");
        if (record.failure) |failure| {
            try json.beginObject();
            try json.objectField("stage");
            try json.write(@tagName(failure.stage));
            try json.objectField("message");
            var message_buffer: [512]u8 = undefined;
            try json.write(failureMessage(&message_buffer, failure.stage, failure.err));
            try json.objectField("remote_message");
            try json.write(failure.remote_message);
            try json.endObject();
        } else {
            try json.write(null);
        }
        try json.endObject();
    }
};

/// what a failed sync tells the user: what failed, why (Haxy's error name,
/// which holds no paths), and what it left behind
pub fn failureMessage(buffer: []u8, stage: Events.SyncStage, err: []const u8) []const u8 {
    const text = switch (stage) {
        .remote => if (std.mem.eql(u8, err, "UrlNotFound"))
            std.fmt.bufPrint(buffer, "The remote has no URL configured, so nothing was synced.", .{})
        else
            std.fmt.bufPrint(buffer, "This repository has no remote to sync with, so nothing was synced.", .{}),
        .fetch => std.fmt.bufPrint(buffer, "Couldn't fetch the remote's events ({s}). Nothing changed here, and your local changes are kept.", .{err}),
        .merge => std.fmt.bufPrint(buffer, "Fetched the remote's events but couldn't merge them ({s}). Nothing changed here and nothing was pushed; your local changes are kept. Haxy may be unable to read a commit on the remote's haxy/events branch (one not written by Haxy, or by a newer Haxy): fix the branch there, then sync again.", .{err}),
        .push => std.fmt.bufPrint(buffer, "Merged the remote's events here, but couldn't push yours ({s}). Your local changes are kept; sync again to send them.", .{err}),
        .confirm => std.fmt.bufPrint(buffer, "Pushed your events, but couldn't fetch the remote again to confirm ({s}), so the sync status may be out of date.", .{err}),
    };
    return text catch "The sync failed. Your local changes are kept.";
}
