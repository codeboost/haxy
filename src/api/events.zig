//! the event routes of the JSON API: a repo's active or removed events, and
//! the events one transaction wrote. every answer is read by the TUI's events
//! tab (`ui.Repo.Events.init`), so the two lists, their order, counts,
//! windows, detail targets and who may see them are exactly the TUI's.
//!
//! a server names repos by owner and name; a local host serves only the repo
//! it opened, under /api/v1/repo/events.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const api_repo = @import("./repo.zig");
const api_thread = @import("./thread.zig");
const evt = @import("../event.zig");
const query_params = @import("./query.zig");
const ui = @import("../ui.zig");

const Events = ui.Repo.Events;

// a list page defaults to the TUI's window; clients may ask for up to this many
const max_page_size = 100;

pub const Route = struct {
    target: api_repo.Route.Target,
    // the transaction whose events are listed, as its path segment wrote it;
    // null for the repo's own lists
    transaction: ?[]const u8,
};

/// the event route `path` names, or null when it names none:
/// `<repo>/events` or `<repo>/transactions/<id>/events`, where `<repo>` is
/// `/api/v1/repos/<owner>/<name>` on a server and `/api/v1/repo` locally
pub fn route(path: []const u8) ?Route {
    const local_prefix = "/api/v1/repo/";
    if (std.mem.startsWith(u8, path, local_prefix))
        return .{ .target = .local, .transaction = (tail(path[local_prefix.len..]) orelse return null).transaction };

    const prefix = "/api/v1/repos/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    var segments = std.mem.splitScalar(u8, path[prefix.len..], '/');
    const owner = segments.next() orelse return null;
    const name = segments.next() orelse return null;
    if (owner.len == 0 or name.len == 0) return null;
    const parsed = tail(segments.rest()) orelse return null;
    return .{ .target = .{ .server = .{ .owner = owner, .name = name } }, .transaction = parsed.transaction };
}

// what follows a repo's path: "events" or "transactions/<id>/events"
fn tail(rest: []const u8) ?struct { transaction: ?[]const u8 } {
    if (std.mem.eql(u8, rest, "events")) return .{ .transaction = null };
    const prefix = "transactions/";
    const suffix = "/events";
    if (!std.mem.startsWith(u8, rest, prefix) or !std.mem.endsWith(u8, rest, suffix)) return null;
    if (rest.len <= prefix.len + suffix.len) return null;
    const id = rest[prefix.len .. rest.len - suffix.len];
    if (std.mem.indexOfScalar(u8, id, '/') != null) return null;
    return .{ .transaction = id };
}

/// a transaction's id: its index in the repo's history, in canonical decimal
/// (no sign, no leading zeros). null for anything else, which names no
/// transaction.
pub fn parseTransaction(text: []const u8) ?u64 {
    if (text.len == 0 or (text.len > 1 and text[0] == '0')) return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// where a window starts: the event a previous page's cursor names. the
/// cursor is `<kind>:<hex id>`, as the TUI's "next" row names its event;
/// clients treat it as opaque.
pub const Cursor = struct {
    kind: evt.EventKind,
    id: []const u8,

    pub fn parse(text: []const u8) ?Cursor {
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
        const kind = std.meta.stringToEnum(evt.EventKind, text[0..colon]) orelse return null;
        const id = text[colon + 1 ..];
        if (id.len == 0) return null;
        return .{ .kind = kind, .id = id };
    }

    pub fn format(aa: std.mem.Allocator, ref: Events.EventRef) ![]const u8 {
        return std.fmt.allocPrint(aa, "{s}:{s}", .{ @tagName(ref.kind), ref.id });
    }
};

pub fn handle(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    host: api_repo.Host,
    // the logged-in viewer, or null when anonymous (always in local mode)
    viewer: ?[evt.event_id_size]u8,
    matched: Route,
    // the still-encoded query string
    query: []const u8,
) !void {
    const method = request.head.method;
    if (method != .GET and method != .HEAD)
        return api.respondError(request, allocator, .{ .code = .unsupported, .message = "This route only supports GET and HEAD." }, .{ .allow = "GET, HEAD" });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // the server's admin repo must outlive the session, whose moment reads from it
    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    var opened = (try api_thread.openRepo(io, request, allocator, &arena, host, viewer, matched.target, &admin_repo_maybe)) orelse return;
    // the TUI's events tab needs write access; checked before anything else,
    // so a viewer without it gets one answer whatever the request names
    if (!ui.Repo.hasSection(.events, opened.resolved.repo.event, opened.handle, opened.session.data.host_kind, opened.source.repo_kind))
        return api.respondError(request, allocator, not_eligible, .{});
    const transaction: ?u64 = if (matched.transaction) |text|
        parseTransaction(text) orelse return api.respondError(request, allocator, no_such_transaction, .{})
    else
        null;

    const read = switch (try readRequest(aa, query)) {
        .ok => |read| read,
        .invalid => |err| return api.respondError(request, allocator, err, .{}),
    };

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    const source = opened.source;
    const gpa = allocator;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, gpa, source.localInitOpts());
            defer any_repo.deinit(io, gpa);
            switch (any_repo) {
                inline else => |*repo| {
                    // local mode: bring the event db up to date with the events
                    // branch, as each TUI page build does
                    if (opened.session.local != null)
                        try evt.consume(.local, .repo, repo_kind, repo.self_repo_opts, io, gpa, repo, evt.events_ref, &.{});
                    const failure = try write(repo_kind, repo.self_repo_opts, &arena, repo, io, &opened, transaction, read, &body.writer);
                    if (failure) |err| return api.respondError(request, allocator, err, .{});
                },
            }
        },
    }
    return api.respondJson(request, body.written(), .{});
}

pub const not_eligible: api.Error = .{ .code = .not_found, .message = "Only people who may write to this repository see its events." };
pub const no_such_transaction: api.Error = .{ .code = .not_found, .message = "There is no transaction with this id whose events can be shown." };
const stale_cursor: api.Error = .{
    .code = .validation,
    .message = "Check the paging parameters.",
    .field_errors = &.{.{ .field = "cursor", .message = "This cursor isn't one Haxy gave out for this list; start from the first page." }},
};

const Read = struct {
    view: ui.RoutablePage.EventsView,
    cursor: ?Cursor,
    page_size: usize,
};

fn readRequest(aa: std.mem.Allocator, query: []const u8) !union(enum) { ok: Read, invalid: api.Error } {
    const view_text = (query_params.param(aa, query, "view") catch |err| switch (err) {
        error.InvalidPercentEncoding => "",
        else => |e| return e,
    }) orelse "active";
    const view = std.meta.stringToEnum(ui.RoutablePage.EventsView, view_text) orelse return .{ .invalid = .{
        .code = .validation,
        .message = "Check the request's parameters.",
        .field_errors = &.{.{ .field = "view", .message = "The view must be active or removed." }},
    } };
    const cursor_text = query_params.param(aa, query, "cursor") catch |err| switch (err) {
        error.InvalidPercentEncoding => return .{ .invalid = stale_cursor },
        else => |e| return e,
    };
    const cursor: ?Cursor = if (cursor_text) |text| Cursor.parse(text) orelse return .{ .invalid = stale_cursor } else null;
    const page_size = switch (try query_params.pageSize(aa, query, .{ .default = Events.page_size, .max = max_page_size })) {
        .ok => |size| size,
        .invalid => |err| return .{ .invalid = err },
    };
    return .{ .ok = .{ .view = view, .cursor = cursor, .page_size = page_size } };
}

fn write(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    opened: *api_thread.Opened,
    transaction: ?u64,
    read: Read,
    writer: *std.Io.Writer,
) !?api.Error {
    const aa = arena.allocator();
    const admin_moment = opened.session.haxy_moment;
    const identity = opened.resolved.identity;
    const repo_event = opened.resolved.repo.event;
    const cursor_kind: ?evt.EventKind = if (read.cursor) |cursor| cursor.kind else null;
    const cursor_id = if (read.cursor) |cursor| cursor.id else "";
    // the other view's window is read only for its count. local and failure
    // only shape the TUI's sync header, which the API doesn't show
    const data = Events.init(repo_kind, repo_opts, arena, repo, io, admin_moment, identity, repo_event, read.view, cursor_kind, cursor_id, transaction, false, null, .{ .shown = read.page_size, .others = 0 }) catch |err| switch (err) {
        error.NotFound => {
            if (transaction == null) return stale_cursor;
            if (read.cursor == null) return no_such_transaction;
            // a transaction page that fails with a cursor: which one is wrong
            _ = Events.init(repo_kind, repo_opts, arena, repo, io, admin_moment, identity, repo_event, read.view, null, "", transaction, false, null, .{ .shown = 0, .others = 0 }) catch |retry_err| switch (retry_err) {
                error.NotFound => return no_such_transaction,
                else => |e| return e,
            };
            return stale_cursor;
        },
        else => |e| return e,
    };
    const window = switch (read.view) {
        .active => &data.active,
        .removed => &data.removed,
    };
    // a cursor roots its own event's view, which must be this list's; a
    // transaction's window that never reached the cursor's event is empty
    if (read.cursor != null and (data.view != read.view or window.events.len == 0)) return stale_cursor;

    const items = try aa.alloc(Event, window.events.len);
    for (items, window.events) |*item, event| item.* = .{
        .id = event.id,
        .kind = event.kind,
        .author = .{ .author = event.author },
        .created_at = if (event.created_timestamp) |seconds| .{ .seconds = seconds } else null,
        .target = if (event.target) |target| .{ .target = target } else null,
    };
    const counts = .{ .active = api.Count{ .exact = data.active.count }, .removed = api.Count{ .exact = data.removed.count } };
    const page = .{
        .has_more = window.next != null,
        .next_cursor = if (window.next) |next| try Cursor.format(aa, next) else null,
        .count = api.Count{ .exact = window.count },
    };
    if (transaction) |index| {
        try std.json.Stringify.value(.{
            .transaction = try std.fmt.allocPrint(aa, "{d}", .{index}),
            .view = read.view,
            .counts = counts,
            .items = items,
            .page = page,
        }, .{}, writer);
    } else {
        try std.json.Stringify.value(.{ .view = read.view, .counts = counts, .items = items, .page = page }, .{}, writer);
    }
    return null;
}

/// a listed event: its kind and author, when it was created (for kinds whose
/// records keep it), and the thread or comment its detail opens
pub const Event = struct {
    id: []const u8,
    kind: evt.EventKind,
    author: api_thread.Author,
    created_at: ?api.Instant,
    target: ?Target,
};

/// `{"kind": "thread", "thread_kind", "thread"}` or `{"kind": "comment",
/// "thread_kind", "thread", "comment"}`: what Hub opens for an event, by
/// structure rather than by a Haxy url
pub const Target = struct {
    target: Events.Target,

    pub fn jsonStringify(self: Target, json: *std.json.Stringify) std.Io.Writer.Error!void {
        try json.beginObject();
        try json.objectField("kind");
        try json.write(@tagName(self.target));
        switch (self.target) {
            .thread => |thread| {
                try json.objectField("thread_kind");
                try json.write(thread.thread_kind);
                try json.objectField("thread");
                try json.write(thread.thread);
            },
            .comment => |comment| {
                try json.objectField("thread_kind");
                try json.write(comment.thread_kind);
                try json.objectField("thread");
                try json.write(comment.thread);
                try json.objectField("comment");
                try json.write(comment.comment);
            },
        }
        try json.endObject();
    }
};
