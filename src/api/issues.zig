//! the issue routes of the JSON API: one status's window of issues, the
//! labels they use, and one issue. every answer is read by the TUI's issues
//! tab (`ui.Repo.Issues.init`), so lists, counts, windows, search filters
//! and labels are exactly the TUI's; see api/thread.zig for the shapes.
//!
//! a server names repos by owner and name; a local host serves only the repo
//! it opened, under /api/v1/repo/issues.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const api_path = @import("./path.zig");
const api_repo = @import("./repo.zig");
const api_thread = @import("./thread.zig");
const evt = @import("../event.zig");
const query_params = @import("./query.zig");
const api_account = @import("./account.zig");
const api_comments = @import("./comments.zig");
const thread_write = @import("../thread_write.zig");
const srch_thrd = @import("../search_thread.zig");
const ui = @import("../ui.zig");

const Issues = ui.Repo.Issues;

// a list page defaults to the TUI's window; clients may ask for up to this many
const max_page_size = 100;

/// the issue route `path` names, or null when it names none
pub fn route(path: []const u8) ?api_thread.Route {
    return api_thread.route(path, "issues");
}

pub fn handle(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    host: api_repo.Host,
    // the logged-in viewer, or null when anonymous (always in local mode)
    viewer: ?[evt.event_id_size]u8,
    matched: api_thread.Route,
    // the still-encoded query string
    query: []const u8,
) !void {
    switch (matched.resource) {
        .comments, .comment => return api_comments.handle(io, request, allocator, host, viewer, matched, query, comment_kind),
        else => {},
    }
    const method = request.head.method;
    const read_methods = method == .GET or method == .HEAD;
    const change: ?Change = switch (matched.resource) {
        .list => if (read_methods) null else if (method == .POST) .create else return api_thread.unsupported(request, allocator, "GET, HEAD, POST"),
        .labels => if (read_methods) null else return api_thread.unsupported(request, allocator, "GET, HEAD"),
        .thread => if (read_methods) null else if (method == .PATCH) .edit else if (method == .DELETE) .remove else return api_thread.unsupported(request, allocator, "GET, HEAD, PATCH, DELETE"),
        .status => if (method == .PUT) .set_status else return api_thread.unsupported(request, allocator, "PUT"),
        .comments, .comment => unreachable,
    };
    if (change) |value| return handleWrite(io, request, allocator, host, viewer, matched, value);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // the server's admin repo must outlive the session, whose moment reads from it
    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    var opened = (try api_thread.openRepo(io, request, allocator, &arena, host, viewer, matched.target, &admin_repo_maybe)) orelse return;
    const repo_event = opened.resolved.repo.event;
    // a repo whose issues are off has no issues tab, as in the TUI
    if (!ui.Repo.hasSection(.issues, repo_event, opened.handle, opened.session.data.host_kind, opened.source.repo_kind))
        return api.respondError(request, allocator, issues_off, .{});

    const read = switch (try readRequest(aa, matched.resource, query)) {
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
                    const failure = try write(repo_kind, repo.self_repo_opts, &arena, repo, io, &opened, read, &body.writer);
                    if (failure) |err| return api.respondError(request, allocator, err, .{});
                },
            }
        },
    }
    return api.respondJson(request, body.written(), .{});
}

pub const issues_off: api.Error = .{ .code = .not_found, .message = "This repository doesn't use issues." };
pub const no_such_issue: api.Error = .{ .code = .not_found, .message = "There is no issue with this id." };

// an issue's comments, as the shared comment routes serve them
const comment_kind: api_comments.Kind = .{ .kind = .issue, .section = .issues, .noun = "issue", .plural = "issues", .off = issues_off, .no_such_thread = no_such_issue };

// what one request reads, with its parameters checked
const Read = union(enum) {
    list: struct {
        status: evt.Issue.Status,
        // decoded
        search: []const u8,
        // the hex id the window starts at, "" for the first window
        cursor: []const u8,
        page_size: usize,
    },
    labels: struct { search: []const u8, page: query_params.Page },
    issue: []const u8,
};

fn readRequest(aa: std.mem.Allocator, resource: api_thread.Route.Resource, query: []const u8) !union(enum) { ok: Read, invalid: api.Error } {
    switch (resource) {
        .list => {
            const status_text = (query_params.param(aa, query, "status") catch |err| switch (err) {
                error.InvalidPercentEncoding => "",
                else => |e| return e,
            }) orelse "open";
            const status = std.meta.stringToEnum(evt.Issue.Status, status_text) orelse
                return .{ .invalid = api_thread.invalidField("status", "The status must be open or closed.") };
            const search = switch (try api_thread.searchParam(aa, query)) {
                .ok => |search| search,
                .invalid => |err| return .{ .invalid = err },
            };
            const cursor = (query_params.param(aa, query, "cursor") catch |err| switch (err) {
                error.InvalidPercentEncoding => return .{ .invalid = api_thread.stale_cursor },
                else => |e| return e,
            }) orelse "";
            const page_size = switch (try query_params.pageSize(aa, query, .{ .default = Issues.page_size, .max = max_page_size })) {
                .ok => |size| size,
                .invalid => |err| return .{ .invalid = err },
            };
            return .{ .ok = .{ .list = .{ .status = status, .search = search, .cursor = cursor, .page_size = page_size } } };
        },
        .labels => {
            const search = switch (try api_thread.searchParam(aa, query)) {
                .ok => |search| search,
                .invalid => |err| return .{ .invalid = err },
            };
            // every label in one page by default, as the TUI's labels view
            const page = switch (try query_params.Page.parse(aa, query, .{ .default = Issues.max_labels, .max = max_page_size })) {
                .ok => |page| page,
                .invalid => |err| return .{ .invalid = err },
            };
            return .{ .ok = .{ .labels = .{ .search = search, .page = page } } };
        },
        .thread => |encoded| return .{ .ok = .{ .issue = std.Uri.percentDecodeInPlace(try aa.dupe(u8, encoded)) } },
        // a write route, or the comments'; handle sends them elsewhere
        .status, .comments, .comment => unreachable,
    }
}

fn write(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    opened: *api_thread.Opened,
    read: Read,
    writer: *std.Io.Writer,
) !?api.Error {
    const aa = arena.allocator();
    const viewer = ui.Repo.tabViewer(opened.handle, opened.resolved.repo, .issue);
    const admin_moment = opened.session.haxy_moment;
    switch (read) {
        .list => |list| {
            const view: ui.RoutablePage.IssuesView = switch (list.status) {
                .open => .open,
                .closed => .closed,
            };
            // the other status's window is read only for its count
            const data = Issues.init(repo_kind, repo_opts, arena, repo, io, admin_moment, opened.resolved.identity, try routeSearch(aa, list.search), list.cursor, "", 0, "", view, viewer, .{ .shown = list.page_size, .others = 0 }) catch |err| switch (err) {
                // a cursor naming no issue the filters list
                error.NotFound => return api_thread.stale_cursor,
                else => |e| return e,
            };
            // a cursor roots its own issue's status, which must be this list's
            if (list.cursor.len != 0) {
                const rooted = data.selectedThread() orelse return api_thread.stale_cursor;
                if (rooted.record.event.status != list.status) return api_thread.stale_cursor;
            }
            const window = data.window(list.status);
            const items = try aa.alloc(api_thread.Summary(evt.Issue.Status), window.items.len);
            for (items, window.items) |*item, *entry| item.* = try api_thread.summary(aa, entry, list.search);
            try std.json.Stringify.value(.{
                .status = list.status,
                .actions = api_thread.listActions(.issue, .{ .may_write = viewer != null, .signed_in = opened.handle.viewer != null }),
                .filters = try api_thread.Filters.init(aa, list.search, data.assignee_unknown),
                .counts = .{ .open = api_thread.count(data.open), .closed = api_thread.count(data.closed) },
                .items = items,
                .page = .{
                    .has_more = window.next_id != null,
                    .next_cursor = window.next_id,
                    .count = api_thread.count(window.*),
                },
            }, .{}, writer);
        },
        .labels => |labels| {
            const data = try Issues.init(repo_kind, repo_opts, arena, repo, io, admin_moment, opened.resolved.identity, "", "", "", 0, "", .labels, viewer, .{ .shown = 0, .others = 0 });
            const all = data.labels;
            const start = @min(labels.page.start, all.len);
            const end = @min(start +| labels.page.limit, all.len);
            const items = try aa.alloc(api_thread.Link, end - start);
            for (items, all[start..end]) |*item, label| item.* = .{
                .name = label,
                .search = try srch_thrd.withFilter(aa, labels.search, srch_thrd.label_prefix, label),
            };
            try api.writePage(writer, items, .{
                .next_cursor = try query_params.Page.nextCursor(aa, if (end < all.len) end else null),
                // the labels view stops at its cap
                .count = if (all.len >= Issues.max_labels) .{ .at_least = all.len } else .{ .exact = all.len },
            });
        },
        .issue => |id| {
            // the issue's own status window, rooted at it; a removed or
            // unknown issue is in no window
            const data = Issues.init(repo_kind, repo_opts, arena, repo, io, admin_moment, opened.resolved.identity, "", id, "", 0, "", .description, viewer, .{ .shown = 1, .others = 0 }) catch |err| switch (err) {
                error.NotFound => return no_such_issue,
                else => |e| return e,
            };
            const entry = data.selectedThread() orelse return no_such_issue;
            try std.json.Stringify.value(try api_thread.detail(aa, entry, .issue, .{ .signed_in = opened.handle.viewer != null }), .{}, writer);
        },
    }
    return null;
}

// a search as the TUI's routes carry it, percent-encoded (Issues.init decodes it)
fn routeSearch(aa: std.mem.Allocator, search: []const u8) ![]const u8 {
    return api_path.encode(aa, search);
}

// --- writes -------------------------------------------------------------------
//
// every write resolves the repo as the viewer (one they can't read is not
// found), then authorizes them afresh, as the TUI and the web forms do
// (`ui.authorizeUser`: their role in the repo, then the issues tab's role),
// and writes through thread_write, which checks who may change an existing
// issue. local mode has no accounts and writes as its repo's owner.

const Change = enum { create, edit, set_status, remove };

/// `POST …/issues`: a new issue. `id` is optional: a client that chooses one
/// (32 lowercase hex digits) can retry without opening a second issue.
pub const CreateRequest = struct {
    id: []const u8,
    title: []const u8,
    labels: []const u8,
    description: []const u8,
};

/// `PATCH …/issues/{id}`: the issue's fields, replaced as of `revision`
pub const EditRequest = struct {
    revision: []const u8,
    title: []const u8,
    labels: []const u8,
    description: []const u8,
};

/// `PUT …/issues/{id}/status`
pub const StatusRequest = struct {
    status: []const u8,
};

pub const change_forbidden: api.Error = .{ .code = .forbidden, .message = "Only the issue's author and the repository's writers can change it." };
const stale_revision: api.Error = .{
    .code = .conflict,
    .message = "This issue changed since you loaded it.",
    .field_errors = &.{.{ .field = "revision", .message = "Someone else changed this issue meanwhile. Load it again, then make your change." }},
};
// what one write asks for, its body read
const Write = union(Change) {
    create: CreateRequest,
    edit: EditRequest,
    set_status: StatusRequest,
    remove,
};

fn handleWrite(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    host: api_repo.Host,
    viewer: ?[evt.event_id_size]u8,
    matched: api_thread.Route,
    change: Change,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // the body is read before anything answers, so no answer leaves it unread
    const body: Write = switch (change) {
        .create => .{ .create = (try api_account.readBody(CreateRequest, request, allocator, &arena)) orelse return },
        .edit => .{ .edit = (try api_account.readBody(EditRequest, request, allocator, &arena)) orelse return },
        .set_status => .{ .set_status = (try api_account.readBody(StatusRequest, request, allocator, &arena)) orelse return },
        .remove => .remove,
    };

    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    var opened = (try api_thread.openRepo(io, request, allocator, &arena, host, viewer, matched.target, &admin_repo_maybe)) orelse return;
    if (!ui.Repo.hasSection(.issues, opened.resolved.repo.event, opened.handle, opened.session.data.host_kind, opened.source.repo_kind))
        return api.respondError(request, allocator, issues_off, .{});

    // the issue a thread route names: an id that isn't one names none
    const thread_id: ?[evt.event_id_size]u8 = switch (matched.resource) {
        .thread, .status => |encoded| evt.parseEventId(std.Uri.percentDecodeInPlace(try aa.dupe(u8, encoded))) catch return api.respondError(request, allocator, no_such_issue, .{}),
        .list, .labels => null,
        .comments, .comment => unreachable,
    };
    if (thread_id) |*id| {
        if (try readDetail(&arena, io, &opened, id) == null) return api.respondError(request, allocator, no_such_issue, .{});
    }

    const actor = switch (try authorize(io, allocator, &arena, host, viewer, &opened)) {
        .actor => |actor| actor,
        .refused => |err| return api.respondError(request, allocator, err, .{}),
    };
    const event_host: evt.Host = switch (host) {
        .local => .local,
        .server => |server| .{ .server = .{ .users_dir = server.users_dir, .admin_repo_path = server.admin_repo_path } },
    };

    const failure: ?api.Error = switch (body) {
        .create => |fields| blk: {
            const chosen = api_thread.parseNewId(fields.id) orelse break :blk api_thread.invalidField("id", "Leave the id out, or send 32 lowercase hex digits.");
            const new_fields = try api_thread.bodyFields(aa, fields);
            if (thread_write.checkFields(.issue, new_fields)) |field_failure| break :blk api_thread.fieldsError(field_failure);
            const id = chosen orelse random: {
                var bytes: [evt.event_id_size]u8 = undefined;
                io.random(&bytes);
                break :random bytes;
            };
            thread_write.create(event_host, io, allocator, opened.source, .issue, &id, new_fields, actor.author) catch |err| switch (err) {
                error.IdTaken => break :blk api_thread.id_taken,
                else => |e| return e,
            };
            return respondDetail(request, allocator, &arena, io, &opened, &id, .created);
        },
        .edit => |fields| blk: {
            const revision = api_thread.parseRevision(fields.revision) orelse break :blk api_thread.invalidField("revision", "Send the revision of the issue as you loaded it.");
            const new_fields = try api_thread.bodyFields(aa, fields);
            if (thread_write.checkFields(.issue, new_fields)) |field_failure| break :blk api_thread.fieldsError(field_failure);
            thread_write.edit(event_host, io, allocator, opened.source, actor, .issue, &thread_id.?, new_fields, revision) catch |err| break :blk try writeError(err);
            break :blk null;
        },
        .set_status => |fields| blk: {
            const status = std.meta.stringToEnum(evt.Issue.Status, fields.status) orelse break :blk api_thread.invalidField("status", "The status must be open or closed.");
            thread_write.setStatus(evt.Issue, event_host, io, allocator, opened.source, actor, &thread_id.?, status) catch |err| break :blk try writeError(err);
            break :blk null;
        },
        .remove => blk: {
            thread_write.remove(event_host, io, allocator, opened.source, actor, .issue, &thread_id.?, .issue, &thread_id.?) catch |err| break :blk try writeError(err);
            var out: std.Io.Writer.Allocating = .init(aa);
            try std.json.Stringify.value(.{ .id = std.fmt.bytesToHex(thread_id.?, .lower) }, .{}, &out.writer);
            return api.respondJson(request, out.written(), .{});
        },
    };
    if (failure) |err| return api.respondError(request, allocator, err, .{});
    return respondDetail(request, allocator, &arena, io, &opened, &thread_id.?, .ok);
}

// a thread_write refusal, as the API answers it
fn writeError(err: anyerror) !api.Error {
    return switch (err) {
        error.Forbidden => change_forbidden,
        error.NotFound => no_such_issue,
        error.Stale => stale_revision,
        else => return err,
    };
}

pub const Authorized = api_thread.Authorized;

// who the write acts as (see `api_thread.authorize`)
pub fn authorize(
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    host: api_repo.Host,
    viewer: ?[evt.event_id_size]u8,
    opened: *api_thread.Opened,
) !Authorized {
    return api_thread.authorize(.issue, io, allocator, arena, host, viewer, opened);
}

// the issue `id` names as its own route answers it, or null when there is none
pub fn readDetail(arena: *std.heap.ArenaAllocator, io: std.Io, opened: *api_thread.Opened, id: *const [evt.event_id_size]u8) !?[]const u8 {
    const aa = arena.allocator();
    var body: std.Io.Writer.Allocating = .init(aa);
    const hex = try aa.dupe(u8, &std.fmt.bytesToHex(id.*, .lower));
    const source = opened.source;
    const gpa = arena.child_allocator;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, gpa, source.localInitOpts());
            defer any_repo.deinit(io, gpa);
            switch (any_repo) {
                inline else => |*repo| {
                    if (opened.session.local != null)
                        try evt.consume(.local, .repo, repo_kind, repo.self_repo_opts, io, gpa, repo, evt.events_ref, &.{});
                    if (try write(repo_kind, repo.self_repo_opts, arena, repo, io, opened, .{ .issue = hex }, &body.writer)) |_| return null;
                },
            }
        },
    }
    return body.written();
}

pub fn respondDetail(request: *std.http.Server.Request, allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, io: std.Io, opened: *api_thread.Opened, id: *const [evt.event_id_size]u8, status: std.http.Status) !void {
    // the write landed; only a removal racing it leaves nothing to show
    const detail = (try readDetail(arena, io, opened, id)) orelse return api.respondError(request, allocator, no_such_issue, .{});
    return api.respondJson(request, detail, .{ .status = status });
}
