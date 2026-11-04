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

const issues_off: api.Error = .{ .code = .not_found, .message = "This repository doesn't use issues." };
const no_such_issue: api.Error = .{ .code = .not_found, .message = "There is no issue with this id." };
const stale_cursor: api.Error = .{
    .code = .validation,
    .message = "Check the paging parameters.",
    .field_errors = &.{.{ .field = "cursor", .message = "This cursor isn't one Haxy gave out for this list; start from the first page." }},
};

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
                return .{ .invalid = invalidField("status", "The status must be open or closed.") };
            const search = switch (try searchParam(aa, query)) {
                .ok => |search| search,
                .invalid => |err| return .{ .invalid = err },
            };
            const cursor = (query_params.param(aa, query, "cursor") catch |err| switch (err) {
                error.InvalidPercentEncoding => return .{ .invalid = stale_cursor },
                else => |e| return e,
            }) orelse "";
            const page_size = switch (try query_params.pageSize(aa, query, .{ .default = Issues.page_size, .max = max_page_size })) {
                .ok => |size| size,
                .invalid => |err| return .{ .invalid = err },
            };
            return .{ .ok = .{ .list = .{ .status = status, .search = search, .cursor = cursor, .page_size = page_size } } };
        },
        .labels => {
            const search = switch (try searchParam(aa, query)) {
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
    }
}

// the decoded `search` parameter, "" when absent
fn searchParam(aa: std.mem.Allocator, query: []const u8) !union(enum) { ok: []const u8, invalid: api.Error } {
    const search = query_params.param(aa, query, "search") catch |err| switch (err) {
        error.InvalidPercentEncoding => return .{ .invalid = invalidField("search", "The search isn't validly encoded.") },
        else => |e| return e,
    };
    return .{ .ok = search orelse "" };
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
                error.NotFound => return stale_cursor,
                else => |e| return e,
            };
            // a cursor roots its own issue's status, which must be this list's
            if (list.cursor.len != 0) {
                const rooted = data.selectedThread() orelse return stale_cursor;
                if (rooted.record.event.status != list.status) return stale_cursor;
            }
            const window = data.window(list.status);
            const items = try aa.alloc(api_thread.Summary(evt.Issue.Status), window.items.len);
            for (items, window.items) |*item, *entry| item.* = try api_thread.summary(aa, entry, list.search);
            try std.json.Stringify.value(.{
                .status = list.status,
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
            try std.json.Stringify.value(try api_thread.detail(aa, entry), .{}, writer);
        },
    }
    return null;
}

// a search as the TUI's routes carry it, percent-encoded (Issues.init decodes it)
fn routeSearch(aa: std.mem.Allocator, search: []const u8) ![]const u8 {
    return api_path.encode(aa, search);
}

fn invalidField(comptime field: []const u8, comptime message: []const u8) api.Error {
    return .{
        .code = .validation,
        .message = "Check the request's parameters.",
        .field_errors = &.{.{ .field = field, .message = message }},
    };
}
