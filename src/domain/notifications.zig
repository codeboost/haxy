//! notification operations: which threads notify the acting user.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("../event.zig");
const notify = @import("../notify.zig");
const domain = @import("../domain.zig");

pub const Subscribe = struct {
    pub const tool_name = "subscribe";
    pub const hosts = domain.server_only;
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
    pub const hosts = domain.server_only;
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

pub const ListNotifications = struct {
    pub const tool_name = "list_notifications";
    pub const hosts = domain.server_only;
    pub const tool_description = "List the acting user's notifications, newest first, with how many are unread. Server only.";
    pub const tool_schema_notes = .{
        .start = "The index of the first notification to list; 0 or omitted lists the first page.",
    };

    // the index of the page's first notification
    start: u64 = 0,

    // how many notifications one page holds, as the notifications tab shows them
    pub const page_size = 20;

    pub const Row = struct {
        // the notification's hex id, for marking it read or dismissing it
        id: [evt.event_id_size * 2]u8,
        owner_name: []const u8,
        repo_name: []const u8,
        thread_id: [evt.event_id_size * 2]u8,
        thread_kind: evt.EventKind,
        // the thread's title as of the notification's last bump
        title: []const u8,
        unread: bool,
        // the hex id of the comment or assignment that last bumped it, which
        // marking it read takes
        last_child_id: [evt.event_id_size * 2]u8,
        // when it was last bumped, in seconds
        time: u64,
    };

    pub const Result = struct {
        rows: []const Row,
        unread_count: u64,
        // whether notifications follow this page
        more: bool,
    };

    pub fn run(self: ListNotifications, ctx: *domain.Ctx) !Result {
        const server = try inboxServer(ctx);
        const user_id = ctx.user_id orelse return error.LoginRequired;
        const empty: Result = .{ .rows = &.{}, .unread_count = 0, .more = false };

        var user_repo = (try evt.openUserRepo(ctx.io, ctx.gpa, server.users_dir, &user_id)) orelse return empty;
        defer user_repo.deinit(ctx.io, ctx.gpa);
        const moment = (try notify.latestMoment(&user_repo)) orelse return empty;

        // one past the page tells whether more follow
        const items = try notify.readRecent(moment, ctx.arena, self.start, page_size + 1);
        const rows = try ctx.arena.allocator().alloc(Row, @min(items.len, page_size));
        for (rows, items[0..rows.len]) |*row, item| {
            const notif = item.notif;
            row.* = .{
                .id = std.fmt.bytesToHex(notify.idOf(&notif.repo_id, &notif.thread_id), .lower),
                .owner_name = notif.owner_name,
                .repo_name = notif.repo_name,
                .thread_id = std.fmt.bytesToHex(notif.thread_id, .lower),
                .thread_kind = notif.thread_kind,
                .title = notif.title,
                .unread = item.unread,
                .last_child_id = std.fmt.bytesToHex(notif.last_child_id, .lower),
                .time = notif.time,
            };
        }
        return .{ .rows = rows, .unread_count = try notify.unreadCount(moment), .more = items.len > page_size };
    }
};

pub const MarkRead = struct {
    pub const tool_name = "mark_notification_read";
    pub const hosts = domain.server_only;
    pub const tool_description = "Mark one of the acting user's notifications read, as of the comment or assignment last seen on it. Server only.";
    pub const tool_schema_notes = .{
        .notification_id = "The notification's hex id, from list_notifications.",
        .last_child_id = "The last_child_id list_notifications gave for it; newer activity since keeps it unread.",
    };

    // the notification's hex id
    notification_id: []const u8,
    // the hex id of the child the caller saw last bump it
    last_child_id: []const u8,

    pub fn run(self: MarkRead, ctx: *domain.Ctx) !void {
        const server = try inboxServer(ctx);
        const user_id = ctx.user_id orelse return error.LoginRequired;
        const notif_id = evt.parseEventId(self.notification_id) catch return error.NotFound;
        const last_child_id = evt.parseEventId(self.last_child_id) catch return error.NotFound;
        switch (try notify.markRead(ctx.io, ctx.gpa, server.users_dir, &user_id, &notif_id, &last_child_id)) {
            .marked, .already_read => {},
            // a newer child bumped it since the caller saw it, so it stays unread
            .out_of_date => return error.NotificationOutOfDate,
            // ids are per user, so another user's notification isn't there
            .missing => return error.NotFound,
        }
    }
};

pub const Dismiss = struct {
    pub const tool_name = "dismiss_notification";
    pub const hosts = domain.server_only;
    pub const tool_description = "Remove one of the acting user's notifications; the thread's next activity brings it back. Server only.";
    pub const tool_schema_notes = .{
        .notification_id = "The notification's hex id, from list_notifications.",
    };

    // the notification's hex id
    notification_id: []const u8,

    pub fn run(self: Dismiss, ctx: *domain.Ctx) !void {
        const server = try inboxServer(ctx);
        const user_id = ctx.user_id orelse return error.LoginRequired;
        const notif_id = evt.parseEventId(self.notification_id) catch return error.NotFound;
        switch (try notify.dismiss(ctx.io, ctx.gpa, server.users_dir, &user_id, &notif_id)) {
            .dismissed => {},
            // another user's, an unknown or an already dismissed id
            .missing => return error.NotFound,
        }
    }
};

// set the acting user's notify button on every thread of `windows`, a tuple of
// pointers to listing windows of the repo `repo_id` owned by `owner_id`: mute
// when a tier holds them, else subscribe. logged out and local mode, which
// have nobody to notify, leave it null.
pub fn setNotifyActions(ctx: *domain.Ctx, owner_id: *const [evt.event_id_size]u8, repo_id: *const [evt.event_id_size]u8, windows: anytype) !void {
    const server = switch (ctx.host) {
        .server => |server| server,
        .local => return,
    };
    const user_id = ctx.user_id orelse return;
    // the owner's plain data, which holds the tier index
    var owner_repo = (try evt.openUserRepo(ctx.io, ctx.gpa, server.users_dir, owner_id)) orelse return error.NotFound;
    defer owner_repo.deinit(ctx.io, ctx.gpa);
    const owner_moment = try notify.latestMoment(&owner_repo);

    inline for (windows) |window| {
        const items = try ctx.arena.allocator().dupe(std.meta.Elem(@TypeOf(window.items)), window.items);
        for (items) |*entry| {
            const notif_id = notify.idOf(repo_id, &try evt.parseEventId(entry.id));
            // muting drops the user from every tier, so membership alone decides
            const notified = if (owner_moment) |moment| try notify.isNotified(moment, &notif_id, &user_id) else false;
            entry.notify_action = if (notified) .mute else .subscribe;
        }
        window.items = items;
    }
}

// the server whose user repos hold the inboxes. local mode has no accounts.
fn inboxServer(ctx: *domain.Ctx) !domain.Host.Server {
    return switch (ctx.host) {
        .server => |server| server,
        .local => error.UnavailableHere,
    };
}

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
