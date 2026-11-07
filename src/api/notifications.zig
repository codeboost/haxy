//! the notification routes of the JSON API, server mode only: the viewer's
//! inbox and its unread count, and on each thread the viewer's notification
//! state, subscribing or muting, and the acknowledgement a page sends once it
//! has shown the thread.
//!
//! - `GET /api/v1/notifications?cursor=&page_size=`: the inbox, newest first
//! - `GET /api/v1/notifications/count`: `{unread_count}`
//! - `GET …/<kind>/{id}/notifications`: the viewer's state on the thread
//! - `PUT …/<kind>/{id}/notifications` with `{mode}`: subscribe or mute
//! - `POST …/<kind>/{id}/notifications/read` with `{revision}`: the page
//!   showed the thread with the notification at `revision`, so it is read
//!
//! everything goes through notify.zig's operations, which the TUI's inbox and
//! thread tabs use too: the inbox through `notify.readWindow` (which lists and
//! counts only the notifs of threads the viewer may still read), subscribing
//! and muting through `notify.subscribe`/`mute`, whether the viewer is
//! notified through `notify.isNotified`, and the acknowledgement through
//! `notify.markViewed`. reads never change read state.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const api_account = @import("./account.zig");
const api_comments = @import("./comments.zig");
const api_repo = @import("./repo.zig");
const api_thread = @import("./thread.zig");
const evt = @import("../event.zig");
const notify = @import("../notify.zig");
const query_params = @import("./query.zig");
const ui = @import("../ui.zig");

pub const OrderKey = notify.OrderKey;

// a window defaults to the TUI's inbox page; clients may ask for up to this many
const max_page_size = 100;

pub const Route = enum {
    // the viewer's notifications
    inbox,
    // how many of them are unread
    count,
};

/// the inbox route `path` names, or null
pub fn route(path: []const u8) ?Route {
    if (std.mem.eql(u8, path, "/api/v1/notifications")) return .inbox;
    if (std.mem.eql(u8, path, "/api/v1/notifications/count")) return .count;
    return null;
}

pub const ThreadRoute = struct {
    // the thread's own route
    thread: api_thread.Route,
    resource: enum {
        // the viewer's state on the thread, and subscribing or muting
        state,
        // the acknowledgement that a page showed the thread
        read,
    },
};

const state_segment = "/notifications";
const read_segment = "/notifications/read";

/// the notification route under a thread of kind `segment` ("issues") that
/// `path` names: `<thread>/notifications` or `<thread>/notifications/read`
pub fn threadRoute(path: []const u8, comptime segment: []const u8) ?ThreadRoute {
    const thread_path, const resource: @FieldType(ThreadRoute, "resource") = if (std.mem.endsWith(u8, path, read_segment))
        .{ path[0 .. path.len - read_segment.len], .read }
    else if (std.mem.endsWith(u8, path, state_segment))
        .{ path[0 .. path.len - state_segment.len], .state }
    else
        return null;
    const thread = api_thread.route(thread_path, segment) orelse return null;
    if (thread.resource != .thread) return null;
    return .{ .thread = thread, .resource = resource };
}

/// a cursor's length: the hex of a notif's order key
pub const cursor_len = @sizeOf(OrderKey) * 2;

/// the cursor naming the window that starts at `key`
pub fn writeCursor(buffer: *[cursor_len]u8, key: OrderKey) []const u8 {
    buffer.* = std.fmt.bytesToHex(key, .lower);
    return buffer;
}

/// the order key a cursor Haxy gave out names, or null when `text` isn't one
pub fn parseCursor(text: []const u8) ?OrderKey {
    if (text.len != cursor_len) return null;
    for (text) |char| if (!std.ascii.isDigit(char) and !(char >= 'a' and char <= 'f')) return null;
    var key: OrderKey = undefined;
    _ = std.fmt.hexToBytes(&key, text) catch return null;
    return key;
}

/// the refusal of a subscriber past the cap of a thread of kind `noun` ("issue")
pub fn subscribersFull(comptime noun: []const u8) api.Error {
    return .{ .code = .conflict, .message = std.fmt.comptimePrint("This {s} already has {d} subscribers, the most Haxy allows.", .{ noun, notify.max_subscribed }) };
}

const local_mode: api.Error = .{ .code = .unsupported, .message = "Local mode has no accounts, so it has no notifications." };
const log_in: api.Error = .{ .code = .unauthenticated, .message = "Log in to see your notifications." };
const bad_cursor: api.Error = .{
    .code = .validation,
    .message = "Check the paging parameters.",
    .field_errors = &.{.{ .field = "cursor", .message = "This cursor isn't one Haxy gave out; start from the first page." }},
};

pub const Server = struct {
    admin_repo_path: []const u8,
    users_dir: []const u8,
};

// --- the inbox ---------------------------------------------------------------------

pub fn handle(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    // null in local mode
    server_maybe: ?Server,
    // the logged-in viewer, or null when anonymous
    viewer: ?[evt.event_id_size]u8,
    matched: Route,
    // the still-encoded query string
    query: []const u8,
) !void {
    const method = request.head.method;
    if (method != .GET and method != .HEAD) return unsupported(request, allocator, "GET, HEAD");
    const server = server_maybe orelse return api.respondError(request, allocator, local_mode, .{});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // the count reads every notif, so its window is empty
    var from: notify.From = .{ .index = 0 };
    var size: usize = 0;
    if (matched == .inbox) {
        size = switch (try query_params.pageSize(aa, query, .{ .default = ui.UserNotifications.page_size, .max = max_page_size })) {
            .ok => |value| value,
            .invalid => |err| return api.respondError(request, allocator, err, .{}),
        };
        const cursor = query_params.param(aa, query, "cursor") catch |err| switch (err) {
            error.InvalidPercentEncoding => return api.respondError(request, allocator, bad_cursor, .{}),
            else => |e| return e,
        };
        if (cursor) |text| from = .{ .key = parseCursor(text) orelse return api.respondError(request, allocator, bad_cursor, .{}) };
    }

    const user_id = viewer orelse return api.respondError(request, allocator, log_in, .{});
    var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
    defer admin_repo.deinit(io, allocator);
    const admin_moment = try evt.currentMoment(evt.admin_repo_opts, &admin_repo);
    // a deleted account's session is nobody's, as page loads have it
    if (try ui.activeUser(admin_moment, &arena, user_id) == null) return api.respondError(request, allocator, log_in, .{});

    var readable: notify.Readable = .{
        .io = io,
        .allocator = allocator,
        .arena = &arena,
        .users_dir = server.users_dir,
        .admin_moment = admin_moment,
        .viewer_id = user_id,
    };
    const window: notify.Window = blk: {
        const empty: notify.Window = .{ .items = &.{}, .next = null, .skipped = 0, .total = 0, .unread = 0 };
        var user_repo = (try evt.openUserRepo(io, allocator, server.users_dir, &user_id)) orelse break :blk empty;
        defer user_repo.deinit(io, allocator);
        const moment = (try notify.latestMoment(&user_repo)) orelse break :blk empty;
        break :blk try notify.readWindow(moment, &arena, &readable, from, size);
    };

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    switch (matched) {
        .count => try std.json.Stringify.value(.{ .unread_count = window.unread }, .{}, &body.writer),
        .inbox => {
            const items = try aa.alloc(Item, window.items.len);
            for (items, window.items) |*item, shown| item.* = try .init(aa, shown);
            var cursor_buffer: [cursor_len]u8 = undefined;
            try std.json.Stringify.value(.{
                .items = items,
                .page = .{
                    .has_more = window.next != null,
                    .next_cursor = if (window.next) |key| writeCursor(&cursor_buffer, key) else null,
                    .count = api.Count{ .exact = window.total },
                },
                .unread_count = window.unread,
            }, .{}, &body.writer);
        },
    }
    return api.respondJson(request, body.written(), .{});
}

/// one notification as the inbox lists it
const Item = struct {
    // the notification's own id
    id: []const u8,
    unread: bool,
    // the thread's title as of the notification's last bump
    title: []const u8,
    repo: struct { owner: []const u8, name: []const u8 },
    thread: struct { kind: []const u8, id: []const u8 },
    // when it was last bumped
    updated_at: api.Instant,

    fn init(aa: std.mem.Allocator, shown: notify.Shown) !Item {
        const notif = shown.item.notif;
        return .{
            .id = try aa.dupe(u8, &std.fmt.bytesToHex(notify.idOf(&notif.repo_id, &notif.thread_id), .lower)),
            .unread = shown.item.unread,
            .title = notif.title,
            .repo = .{ .owner = shown.place.owner_name, .name = shown.place.repo_name },
            .thread = .{ .kind = kindSegment(notif.thread_kind), .id = try aa.dupe(u8, &std.fmt.bytesToHex(notif.thread_id, .lower)) },
            .updated_at = .{ .seconds = notif.time },
        };
    }
};

// a thread kind as its routes name it
fn kindSegment(kind: evt.EventKind) []const u8 {
    return switch (kind) {
        .issue => "issues",
        .discuss => "discussions",
        .patch => "patches",
        else => @tagName(kind),
    };
}

// --- one thread --------------------------------------------------------------------

const ModeRequest = struct { mode: []const u8 };
const ReadRequest = struct { revision: []const u8 };

const Change = union(enum) {
    mode: evt.Notify.Mode,
    read: [evt.event_id_size]u8,
};

const bad_mode: api.Error = .{
    .code = .validation,
    .message = "Check the highlighted fields.",
    .field_errors = &.{.{ .field = "mode", .message = "Send \"subscribed\" or \"muted\"." }},
};
const bad_revision: api.Error = .{
    .code = .validation,
    .message = "Check the highlighted fields.",
    .field_errors = &.{.{ .field = "revision", .message = "This revision isn't one Haxy gave out." }},
};

pub fn handleThread(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    host: api_repo.Host,
    // the logged-in viewer, or null when anonymous (always in local mode)
    viewer: ?[evt.event_id_size]u8,
    matched: ThreadRoute,
    comptime thread: api_comments.Kind,
) !void {
    const method = request.head.method;
    const writes = switch (matched.resource) {
        .state => if (method == .GET or method == .HEAD) false else if (method == .PUT) true else return unsupported(request, allocator, "GET, HEAD, PUT"),
        .read => if (method == .POST) true else return unsupported(request, allocator, "POST"),
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // a write's body is read before anything answers, so no answer leaves it unread
    const change_text: ?[]const u8 = if (!writes) null else switch (matched.resource) {
        .state => ((try api_account.readBody(ModeRequest, request, allocator, &arena)) orelse return).mode,
        .read => ((try api_account.readBody(ReadRequest, request, allocator, &arena)) orelse return).revision,
    };

    const server = switch (host) {
        .local => return api.respondError(request, allocator, local_mode, .{}),
        .server => |server| server,
    };

    // the server's admin repo must outlive the session, whose moment reads from it
    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    var opened = (try api_thread.openRepo(io, request, allocator, &arena, host, viewer, matched.thread.target, &admin_repo_maybe)) orelse return;
    // a repo that doesn't use the kind has no tab for it, as in the TUI
    if (!ui.Repo.hasSection(thread.section, opened.resolved.repo.event, opened.handle, opened.session.data.host_kind, opened.source.repo_kind))
        return api.respondError(request, allocator, thread.off, .{});
    const thread_id = evt.parseEventId(std.Uri.percentDecodeInPlace(try aa.dupe(u8, matched.thread.resource.thread))) catch
        return api.respondError(request, allocator, thread.no_such_thread, .{});

    // who acts, checked against the admin db as it is now, as Haxy's own
    // subscribe and mute forms check it
    const unauthenticated: api.Error = .{ .code = .unauthenticated, .message = "Log in to get notifications about " ++ thread.plural ++ "." };
    const user_id = viewer orelse return api.respondError(request, allocator, unauthenticated, .{});
    const admin_moment = opened.session.haxy_moment orelse return api.respondError(request, allocator, unauthenticated, .{});
    const actor = switch (try ui.authorizeUser(io, admin_moment, &arena, server.users_dir, user_id, opened.resolved.identity, .read, null)) {
        .actor => |actor| actor,
        .login_required => return api.respondError(request, allocator, unauthenticated, .{}),
        // reading is the least role, so a viewer who holds none can't see the repo
        .repo_not_found, .forbidden => return api.respondError(request, allocator, api_repo.not_found_repo, .{}),
    };
    const location: evt.RepoLocation = .{
        // a server actor always has the owner's id, and a server repo its own
        .owner_id = actor.repo_user_id orelse unreachable,
        .repo_id = opened.resolved.repo_id orelse unreachable,
    };

    const change: ?Change = if (change_text) |text| switch (matched.resource) {
        .state => .{ .mode = blk: {
            const mode = std.meta.stringToEnum(evt.Notify.Mode, text) orelse return api.respondError(request, allocator, bad_mode, .{});
            if (mode != .subscribed and mode != .muted) return api.respondError(request, allocator, bad_mode, .{});
            break :blk mode;
        } },
        .read => .{ .read = (api_thread.parseNewId(text) orelse return api.respondError(request, allocator, bad_revision, .{})) orelse
            return api.respondError(request, allocator, bad_revision, .{}) },
    } else null;

    var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, opened.source.localInitOpts());
    defer any_repo.deinit(io, allocator);
    switch (any_repo) {
        inline else => |*repo| {
            const repo_opts = repo.self_repo_opts;
            // a repo without events yet holds no threads
            const moment = evt.currentMoment(repo_opts, repo) catch |err| switch (err) {
                error.NotFound => return api.respondError(request, allocator, thread.no_such_thread, .{}),
                else => |e| return e,
            };
            if (!try api_comments.threadLive(repo_opts.hash, &arena, moment, thread.kind, &thread_id))
                return api.respondError(request, allocator, thread.no_such_thread, .{});
            if (change) |value| switch (value) {
                .mode => |mode| switch (mode) {
                    .subscribed => switch (try notify.subscribe(io, allocator, server.users_dir, &user_id, location, &thread_id, actor.author)) {
                        .subscribed => {},
                        .full => return api.respondError(request, allocator, subscribersFull(thread.noun), .{}),
                    },
                    .muted => try notify.mute(io, allocator, server.users_dir, &user_id, location, &thread_id, actor.author),
                    else => unreachable,
                },
                .read => |*revision| try notify.markViewed(repo_opts, io, allocator, &arena, server.users_dir, &user_id, repo, &location.repo_id, &thread_id, revision),
            };
        },
    }

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    try writeState(io, allocator, &arena, server.users_dir, &location, &thread_id, &user_id, &body.writer);
    return api.respondJson(request, body.written(), .{});
}

// the viewer's state on a thread: whether a tier holds them (the TUI's
// subscribe or mute button decides by the same), and their notification on it
fn writeState(
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    users_dir: []const u8,
    location: *const evt.RepoLocation,
    thread_id: *const [evt.event_id_size]u8,
    user_id: *const [evt.event_id_size]u8,
    writer: *std.Io.Writer,
) !void {
    const aa = arena.allocator();
    const notif_id = notify.idOf(&location.repo_id, thread_id);
    const notified = blk: {
        var owner_repo = (try evt.openUserRepo(io, allocator, users_dir, &location.owner_id)) orelse break :blk false;
        defer owner_repo.deinit(io, allocator);
        const moment = (try notify.latestMoment(&owner_repo)) orelse break :blk false;
        break :blk try notify.isNotified(moment, &notif_id, user_id);
    };
    const item: ?notify.Item = blk: {
        var user_repo = (try evt.openUserRepo(io, allocator, users_dir, user_id)) orelse break :blk null;
        defer user_repo.deinit(io, allocator);
        const moment = (try notify.latestMoment(&user_repo)) orelse break :blk null;
        break :blk try notify.readItem(moment, arena, &notif_id);
    };
    const Notification = struct { id: []const u8, unread: bool, revision: []const u8 };
    try std.json.Stringify.value(.{
        .notified = notified,
        .notification = if (item) |value| Notification{
            .id = try aa.dupe(u8, &std.fmt.bytesToHex(notif_id, .lower)),
            .unread = value.unread,
            .revision = try aa.dupe(u8, &std.fmt.bytesToHex(value.notif.last_child_id, .lower)),
        } else null,
    }, .{}, writer);
}

fn unsupported(request: *std.http.Server.Request, allocator: std.mem.Allocator, comptime allow: []const u8) !void {
    // a write's body goes unread, so the connection closes
    return api.respondError(request, allocator, .{ .code = .unsupported, .message = "This route only supports " ++ allow ++ "." }, .{ .allow = allow, .keep_alive = false });
}
