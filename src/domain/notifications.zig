//! notification operations: which threads notify the acting user.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("../event.zig");
const notify = @import("../notify.zig");
const domain = @import("../domain.zig");

pub const Subscribe = struct {
    pub const tool_name = "subscribe";
    pub const tool_description = "Get notified of an issue, patch or discussion's activity. Server only.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .kind = "The kind of the thread.",
        .thread_id = "The thread's hex event id.",
    };

    // "owner:name"
    repo: []const u8,
    kind: domain.ThreadKind,
    // the thread's hex event id
    thread_id: []const u8,

    pub fn run(self: Subscribe, ctx: *domain.Ctx) !void {
        try change(ctx, self.repo, self.kind, self.thread_id, .subscribe);
    }
};

pub const Mute = struct {
    pub const tool_name = "mute";
    pub const tool_description = "Stop being notified of an issue, patch or discussion's activity. Server only.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .kind = "The kind of the thread.",
        .thread_id = "The thread's hex event id.",
    };

    // "owner:name"
    repo: []const u8,
    kind: domain.ThreadKind,
    // the thread's hex event id
    thread_id: []const u8,

    pub fn run(self: Mute, ctx: *domain.Ctx) !void {
        try change(ctx, self.repo, self.kind, self.thread_id, .mute);
    }
};

const Mode = enum { subscribe, mute };

// subscribe the acting user to the thread or mute it. reading the repo is
// enough, as for the thread's notify button.
fn change(ctx: *domain.Ctx, identity: []const u8, kind: domain.ThreadKind, thread_id: []const u8, mode: Mode) !void {
    const server = switch (ctx.host) {
        .server => |server| server,
        // local mode has no accounts to notify
        .local => return error.UnavailableHere,
    };
    const actor = switch (try ctx.authorize(identity, .read, null)) {
        .actor => |actor| actor,
        .login_required => return error.LoginRequired,
        .repo_not_found => return error.NotFound,
        .forbidden => return error.Forbidden,
    };
    const resolved = (try domain.resolveRepo(ctx, identity)) orelse return error.NotFound;
    // a tab that is off doesn't exist
    if (!resolved.hasTab(kind.eventKind())) return error.NotFound;
    const id = evt.parseEventId(thread_id) catch return error.NotFound;
    // the notify index takes any id, so check the thread is there
    if (!try domain.withRepo(ctx, resolved, ThreadArgs{ .kind = kind.eventKind(), .id = id }, threadExists)) return error.NotFound;
    // a server actor always has both ids
    const user_id = actor.user_id orelse unreachable;
    const location: evt.RepoLocation = .{
        .owner_id = actor.repo_user_id orelse unreachable,
        .repo_id = try evt.parseEventId(std.Io.Dir.path.basename(resolved.source.path)),
    };
    switch (mode) {
        .subscribe => try notify.subscribe(ctx.io, ctx.gpa, server.users_dir, &user_id, location, &id, actor.author),
        .mute => try notify.mute(ctx.io, ctx.gpa, server.users_dir, &user_id, location, &id, actor.author),
    }
}

const ThreadArgs = struct {
    kind: evt.EventKind,
    id: [evt.event_id_size]u8,
};

fn threadExists(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    args: ThreadArgs,
) !bool {
    return try evt.threadHolds(repo_kind, repo_opts, ctx.io, ctx.gpa, repo, args.kind, &args.id, null);
}
