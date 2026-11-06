//! the discussion routes of the JSON API: the recent discussions (the TUI's
//! only list of them), the labels they use, one discussion, and the writes
//! that open, edit and remove one; their comments are the shared comment
//! routes (api/comments.zig). every read goes through the TUI's discussions
//! tab (`ui.Repo.Discussions.init`), so the list, its order (most recently
//! active first), counts, windows, search filters and labels are the TUI's;
//! every write goes through thread_write, as the TUI's and the HTML forms do.
//!
//! a discussion has what the TUI shows of it: a title, labels, a
//! description, its author and its comments. it has no status, assignees or
//! field conflicts (a merge keeps the target's version), so its shapes leave
//! those out.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const api_md = @import("./markdown.zig");
const api_path = @import("./path.zig");
const api_repo = @import("./repo.zig");
const api_thread = @import("./thread.zig");
const api_account = @import("./account.zig");
const api_comments = @import("./comments.zig");
const evt = @import("../event.zig");
const md = @import("../markdown.zig");
const query_params = @import("./query.zig");
const thread_write = @import("../thread_write.zig");
const srch_thrd = @import("../search_thread.zig");
const ui = @import("../ui.zig");

const Discussions = ui.Repo.Discussions;

// a list page defaults to the TUI's window; clients may ask for up to this many
const max_page_size = 100;

/// the discussion route `path` names, or null when it names none
pub fn route(path: []const u8) ?api_thread.Route {
    return api_thread.route(path, "discussions");
}

pub const discussions_off: api.Error = .{ .code = .not_found, .message = "This repository doesn't use discussions." };
pub const no_such_discussion: api.Error = .{ .code = .not_found, .message = "There is no discussion with this id." };
const no_route: api.Error = .{ .code = .not_found, .message = "No API route matches this path." };
const change_forbidden: api.Error = .{ .code = .forbidden, .message = "Only the discussion's author and the repository's writers can change it." };
const stale_revision: api.Error = .{
    .code = .conflict,
    .message = "This discussion changed since you loaded it.",
    .field_errors = &.{.{ .field = "revision", .message = "Someone else changed this discussion meanwhile. Load it again, then make your change." }},
};

// a discussion's comments, as the shared comment routes serve them
const comment_kind: api_comments.Kind = .{ .kind = .discuss, .section = .discussions, .noun = "discussion", .plural = "discussions", .off = discussions_off, .no_such_thread = no_such_discussion };

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
    const read_methods = method == .GET or method == .HEAD;
    const change: ?Change = switch (matched.resource) {
        .comments, .comment => return api_comments.handle(io, request, allocator, host, viewer, matched, query, comment_kind),
        // a discussion has no status; its attachments are wired after the merge
        .status, .attachments, .attachment => return api.respondError(request, allocator, no_route, .{ .keep_alive = read_methods }),
        .list => if (read_methods) null else if (method == .POST) .create else return api_thread.unsupported(request, allocator, "GET, HEAD, POST"),
        .labels => if (read_methods) null else return api_thread.unsupported(request, allocator, "GET, HEAD"),
        .thread => if (read_methods) null else if (method == .PATCH) .edit else if (method == .DELETE) .remove else return api_thread.unsupported(request, allocator, "GET, HEAD, PATCH, DELETE"),
    };
    if (change) |value| return handleWrite(io, request, allocator, host, viewer, matched, value);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // the server's admin repo must outlive the session, whose moment reads from it
    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    var opened = (try api_thread.openRepo(io, request, allocator, &arena, host, viewer, matched.target, &admin_repo_maybe)) orelse return;
    if (!uses(&opened)) return api.respondError(request, allocator, discussions_off, .{});

    const read = switch (try readRequest(aa, matched.resource, query)) {
        .ok => |read| read,
        .invalid => |err| return api.respondError(request, allocator, err, .{}),
    };
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    if (try readAnswer(&arena, io, &opened, read, &body.writer)) |err| return api.respondError(request, allocator, err, .{});
    return api.respondJson(request, body.written(), .{});
}

// whether the repo uses discussions: one that doesn't has no discussions tab,
// as in the TUI
fn uses(opened: *api_thread.Opened) bool {
    return ui.Repo.hasSection(.discussions, opened.resolved.repo.event, opened.handle, opened.session.data.host_kind, opened.source.repo_kind);
}

// --- shapes ----------------------------------------------------------------------

/// a listed discussion
pub const Summary = struct {
    id: []const u8,
    title: []const u8,
    labels: []const api_thread.Link,
    author: api_thread.Author,
    created_at: api.Instant,
    comment_count: usize,
};

fn summary(aa: std.mem.Allocator, entry: *const Discussions.Entry, search: []const u8) !Summary {
    return .{
        .id = entry.id,
        .title = entry.record.event.title,
        .labels = try api_thread.labelLinks(aa, entry.record.event.labels, search),
        .author = .{ .author = entry.author },
        .created_at = .{ .seconds = entry.record.created_timestamp },
        .comment_count = entry.comments.count,
    };
}

/// what the viewer may do to one discussion
pub const Actions = struct {
    edit: api_thread.Availability,
    remove: api_thread.Availability,
};

/// a discussion's page: its summary and whole description, parsed by haxy's
/// markdown reader, with what an edit starts from and what the viewer may do
const Detail = struct {
    summary: Summary,
    description: []const md.Block,
    description_text: []const u8,
    revision: evt.Discussion.Revision,
    actions: Actions,

    pub fn jsonStringify(self: Detail, json: *std.json.Stringify) std.Io.Writer.Error!void {
        try json.beginObject();
        inline for (@typeInfo(Summary).@"struct".field_names) |name| {
            try json.objectField(name);
            try json.write(@field(self.summary, name));
        }
        try json.objectField("description");
        try json.write(api_md.Blocks{ .blocks = self.description });
        try json.objectField("description_text");
        try json.write(self.description_text);
        try json.objectField("revision");
        try json.write(&std.fmt.bytesToHex(self.revision, .lower));
        try json.objectField("actions");
        try json.write(self.actions);
        try json.endObject();
    }
};

fn detail(aa: std.mem.Allocator, entry: *const Discussions.Entry, signed_in: bool) !Detail {
    const actions = api_thread.threadActions(.discuss, .{ .may_write = entry.can_modify, .signed_in = signed_in });
    return .{
        // a discussion's own page extends no list's search
        .summary = try summary(aa, entry, ""),
        .description = (try md.parseText(aa, entry.record.event.description)).blocks,
        .description_text = entry.record.event.description,
        .revision = evt.Discussion.contentRevision(entry.record.event),
        .actions = .{ .edit = actions.edit, .remove = actions.remove },
    };
}

// --- reads -----------------------------------------------------------------------

const Read = union(enum) {
    list: struct {
        // decoded
        search: []const u8,
        // the hex id the window starts at, "" for the first window
        cursor: []const u8,
        page_size: usize,
    },
    labels: struct { search: []const u8, page: query_params.Page },
    // a discussion by its decoded hex id
    discussion: []const u8,
};

fn readRequest(aa: std.mem.Allocator, resource: api_thread.Route.Resource, query: []const u8) !union(enum) { ok: Read, invalid: api.Error } {
    switch (resource) {
        .list => {
            const search = switch (try api_thread.searchParam(aa, query)) {
                .ok => |search| search,
                .invalid => |err| return .{ .invalid = err },
            };
            const cursor = (query_params.param(aa, query, "cursor") catch |err| switch (err) {
                error.InvalidPercentEncoding => return .{ .invalid = api_thread.stale_cursor },
                else => |e| return e,
            }) orelse "";
            const page_size = switch (try query_params.pageSize(aa, query, .{ .default = Discussions.page_size, .max = max_page_size })) {
                .ok => |size| size,
                .invalid => |err| return .{ .invalid = err },
            };
            return .{ .ok = .{ .list = .{ .search = search, .cursor = cursor, .page_size = page_size } } };
        },
        .labels => {
            const search = switch (try api_thread.searchParam(aa, query)) {
                .ok => |search| search,
                .invalid => |err| return .{ .invalid = err },
            };
            // every label in one page by default, as the TUI's labels view
            const page = switch (try query_params.Page.parse(aa, query, .{ .default = Discussions.max_labels, .max = max_page_size })) {
                .ok => |page| page,
                .invalid => |err| return .{ .invalid = err },
            };
            return .{ .ok = .{ .labels = .{ .search = search, .page = page } } };
        },
        .thread => |encoded| return .{ .ok = .{ .discussion = std.Uri.percentDecodeInPlace(try aa.dupe(u8, encoded)) } },
        .status, .comments, .comment, .attachments, .attachment => unreachable,
    }
}

// reads what `read` names, as the TUI's discussions tab does, and writes its
// answer, or returns the error to answer with
fn readAnswer(arena: *std.heap.ArenaAllocator, io: std.Io, opened: *api_thread.Opened, read: Read, writer: *std.Io.Writer) !?api.Error {
    const source = opened.source;
    const gpa = arena.child_allocator;
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
                    return write(repo_kind, repo.self_repo_opts, arena, repo, io, opened, read, writer);
                },
            }
        },
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
    const viewer = ui.Repo.tabViewer(opened.handle, opened.resolved.repo, .discuss);
    const admin_moment = opened.session.haxy_moment;
    const identity = opened.resolved.identity;
    switch (read) {
        .list => |list| {
            const data = Discussions.init(repo_kind, repo_opts, arena, repo, io, admin_moment, identity, try api_path.encode(aa, list.search), list.cursor, "", 0, .recent, viewer, list.page_size) catch |err| switch (err) {
                // a cursor naming no discussion the filters list
                error.NotFound => return api_thread.stale_cursor,
                else => |e| return e,
            };
            // a cursor roots the window at its own discussion, which the
            // search's words must still match (`Discussions.init` checks only
            // the label sets); otherwise the window would start further on
            if (list.cursor.len != 0 and data.selectedThread() == null) return api_thread.stale_cursor;
            const window = data.recent;
            const items = try aa.alloc(Summary, window.items.len);
            for (items, window.items) |*item, *entry| item.* = try summary(aa, entry, list.search);
            try std.json.Stringify.value(.{
                .actions = api_thread.listActions(.discuss, .{ .may_write = viewer != null, .signed_in = opened.handle.viewer != null }),
                // discussions have no assignees, so an assignee term lists nothing
                .filters = try api_thread.Filters.init(aa, list.search, false),
                .items = items,
                .page = .{
                    .has_more = window.next_id != null,
                    .next_cursor = window.next_id,
                    .count = api_thread.count(window),
                },
            }, .{}, writer);
        },
        .labels => |labels| {
            const data = try Discussions.init(repo_kind, repo_opts, arena, repo, io, admin_moment, identity, "", "", "", 0, .labels, viewer, 0);
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
                .count = if (all.len >= Discussions.max_labels) .{ .at_least = all.len } else .{ .exact = all.len },
            });
        },
        .discussion => |id| {
            // the window rooted at the discussion; a removed or unknown one is in none
            const data = Discussions.init(repo_kind, repo_opts, arena, repo, io, admin_moment, identity, "", id, "", 0, .description, viewer, 1) catch |err| switch (err) {
                error.NotFound => return no_such_discussion,
                else => |e| return e,
            };
            const entry = data.selectedThread() orelse return no_such_discussion;
            try std.json.Stringify.value(try detail(aa, entry, opened.handle.viewer != null), .{}, writer);
        },
    }
    return null;
}

// --- writes ----------------------------------------------------------------------
//
// every write resolves the repo as the viewer (one they can't read is not
// found), then authorizes them afresh, as the TUI and the web forms do
// (`api_thread.authorize`: their role in the repo, then the discussions tab's
// role), and writes through thread_write, which checks who may change an
// existing discussion. local mode has no accounts and writes as its repo's
// owner.

const Change = enum { create, edit, remove };

/// `POST …/discussions`: a new discussion. `id` is optional: a client that
/// chooses one (32 lowercase hex digits) can retry without opening a second.
pub const CreateRequest = struct {
    id: []const u8,
    title: []const u8,
    labels: []const u8,
    description: []const u8,
};

/// `PATCH …/discussions/{id}`: the fields, replaced as of `revision`
pub const EditRequest = struct {
    revision: []const u8,
    title: []const u8,
    labels: []const u8,
    description: []const u8,
};

const Write = union(Change) {
    create: CreateRequest,
    edit: EditRequest,
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
        .remove => .remove,
    };

    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    var opened = (try api_thread.openRepo(io, request, allocator, &arena, host, viewer, matched.target, &admin_repo_maybe)) orelse return;
    if (!uses(&opened)) return api.respondError(request, allocator, discussions_off, .{});

    // the discussion a thread route names: an id that isn't one names none
    const thread_id: ?[evt.event_id_size]u8 = switch (matched.resource) {
        .thread => |encoded| evt.parseEventId(std.Uri.percentDecodeInPlace(try aa.dupe(u8, encoded))) catch return api.respondError(request, allocator, no_such_discussion, .{}),
        else => null,
    };
    if (thread_id) |*id| {
        if (try readDetail(&arena, io, &opened, id) == null) return api.respondError(request, allocator, no_such_discussion, .{});
    }

    const actor = switch (try api_thread.authorize(.discuss, io, allocator, &arena, host, viewer, &opened)) {
        .actor => |actor| actor,
        .refused => |err| return api.respondError(request, allocator, err, .{}),
    };
    const event_host: evt.Host = switch (host) {
        .local => .local,
        .server => |server| .{ .server = .{ .users_dir = server.users_dir, .admin_repo_path = server.admin_repo_path } },
    };

    const failure: api.Error = switch (body) {
        .create => |fields| blk: {
            const chosen = api_thread.parseNewId(fields.id) orelse break :blk api_thread.invalidField("id", "Leave the id out, or send 32 lowercase hex digits.");
            const new_fields = try api_thread.bodyFields(aa, fields);
            if (thread_write.checkFields(.discuss, new_fields)) |field_failure| break :blk api_thread.fieldsError(field_failure);
            const id = chosen orelse random: {
                var bytes: [evt.event_id_size]u8 = undefined;
                io.random(&bytes);
                break :random bytes;
            };
            thread_write.create(event_host, io, allocator, opened.source, .discuss, &id, new_fields, actor.author) catch |err| switch (err) {
                error.IdTaken => break :blk api_thread.id_taken,
                else => |e| return e,
            };
            return respondDetail(request, allocator, &arena, io, &opened, &id, .created);
        },
        .edit => |fields| blk: {
            const revision = api_thread.parseRevision(fields.revision) orelse break :blk api_thread.invalidField("revision", "Send the revision of the discussion as you loaded it.");
            const new_fields = try api_thread.bodyFields(aa, fields);
            if (thread_write.checkFields(.discuss, new_fields)) |field_failure| break :blk api_thread.fieldsError(field_failure);
            thread_write.edit(event_host, io, allocator, opened.source, actor, .discuss, &thread_id.?, new_fields, revision) catch |err| break :blk try writeError(err);
            return respondDetail(request, allocator, &arena, io, &opened, &thread_id.?, .ok);
        },
        .remove => blk: {
            thread_write.remove(event_host, io, allocator, opened.source, actor, .discuss, &thread_id.?, .discuss, &thread_id.?) catch |err| break :blk try writeError(err);
            var out: std.Io.Writer.Allocating = .init(aa);
            try std.json.Stringify.value(.{ .id = std.fmt.bytesToHex(thread_id.?, .lower) }, .{}, &out.writer);
            return api.respondJson(request, out.written(), .{});
        },
    };
    return api.respondError(request, allocator, failure, .{});
}

// a thread_write refusal, as the API answers it
fn writeError(err: anyerror) !api.Error {
    return switch (err) {
        error.Forbidden => change_forbidden,
        error.NotFound => no_such_discussion,
        error.Stale => stale_revision,
        else => return err,
    };
}

// the discussion `id` names as its own route answers it, or null when there is none
fn readDetail(arena: *std.heap.ArenaAllocator, io: std.Io, opened: *api_thread.Opened, id: *const [evt.event_id_size]u8) !?[]const u8 {
    const aa = arena.allocator();
    var body: std.Io.Writer.Allocating = .init(aa);
    const hex = try aa.dupe(u8, &std.fmt.bytesToHex(id.*, .lower));
    if (try readAnswer(arena, io, opened, .{ .discussion = hex }, &body.writer)) |_| return null;
    return body.written();
}

fn respondDetail(request: *std.http.Server.Request, allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, io: std.Io, opened: *api_thread.Opened, id: *const [evt.event_id_size]u8, status: std.http.Status) !void {
    // the write landed; only a removal racing it leaves nothing to show
    const answer = (try readDetail(arena, io, opened, id)) orelse return api.respondError(request, allocator, no_such_discussion, .{});
    return api.respondJson(request, answer, .{ .status = status });
}
