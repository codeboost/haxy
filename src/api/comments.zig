//! the comment routes every thread kind shares (issues now; discussions and
//! patches reuse them): a thread's comments, one comment with its replies,
//! and the writes that post, edit and remove one. a kind's own module hooks
//! them in with its `Kind`.
//!
//! reads go through the TUI's own comment reader (`ui.Repo.Comment`), so the
//! windows (chronological, ten comments by default), the reply context and
//! who may change a comment are the TUI's; writes go through
//! `thread_write.comment`, `editComment` and `remove`, which the TUI's
//! comment forms and Haxy's HTML forms use too.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const api = @import("../api.zig");
const api_md = @import("./markdown.zig");
const api_repo = @import("./repo.zig");
const api_thread = @import("./thread.zig");
const api_account = @import("./account.zig");
const evt = @import("../event.zig");
const md = @import("../markdown.zig");
const notify = @import("../notify.zig");
const query_params = @import("./query.zig");
const thread_write = @import("../thread_write.zig");
const ui = @import("../ui.zig");

const Comment = ui.Repo.Comment;

// a window defaults to the TUI's; clients may ask for up to this many
const max_page_size = 100;

/// what a thread kind's comment routes need to know about it
pub const Kind = struct {
    kind: evt.EventKind,
    section: ui.Repo.Section,
    // its singular noun, as messages name it ("issue")
    noun: []const u8,
    // its plural noun ("issues")
    plural: []const u8,
    // the answer when the repo doesn't use the kind
    off: api.Error,
    // the answer for a thread the id doesn't name (or a removed one)
    no_such_thread: api.Error,
};

const no_such_comment: api.Error = .{ .code = .not_found, .message = "There is no comment with this id in this thread." };
const removed_comment: api.Error = .{ .code = .conflict, .message = "This comment has been removed." };
const change_forbidden: api.Error = .{ .code = .forbidden, .message = "Only the comment's author and the repository's writers can change it." };
const check_fields = "Check the highlighted fields.";
const stale_revision: api.Error = .{
    .code = .conflict,
    .message = "This comment changed since you loaded it.",
    .field_errors = &.{.{ .field = "revision", .message = "Someone else changed this comment meanwhile. Load it again, then make your change." }},
};
const id_taken: api.Error = .{
    .code = .conflict,
    .message = check_fields,
    .field_errors = &.{.{ .field = "id", .message = "An event in this repository already has this id." }},
};
const body_required: api.Error = .{
    .code = .validation,
    .message = check_fields,
    .field_errors = &.{.{ .field = "body", .message = "Write a comment." }},
};

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
    comptime thread: Kind,
) !void {
    const method = request.head.method;
    const read_methods = method == .GET or method == .HEAD;
    const encoded_thread, const encoded_comment = switch (matched.resource) {
        .comments => |id| .{ id, null },
        .comment => |ids| .{ ids.thread, ids.comment },
        else => unreachable,
    };
    const change: ?Change = if (encoded_comment == null)
        (if (read_methods) null else if (method == .POST) .create else return unsupported(request, allocator, "GET, HEAD, POST"))
    else
        (if (read_methods) null else if (method == .PATCH) .edit else if (method == .DELETE) .remove else return unsupported(request, allocator, "GET, HEAD, PATCH, DELETE"));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // a write's body is read before anything answers, so no answer leaves it unread
    const body: ?Write = if (change) |value| switch (value) {
        .create => .{ .create = (try api_account.readBody(CreateRequest, request, allocator, &arena)) orelse return },
        .edit => .{ .edit = (try api_account.readBody(EditRequest, request, allocator, &arena)) orelse return },
        .remove => .remove,
    } else null;

    // the server's admin repo must outlive the session, whose moment reads from it
    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    var opened = (try api_thread.openRepo(io, request, allocator, &arena, host, viewer, matched.target, &admin_repo_maybe)) orelse return;
    // a repo that doesn't use the kind has no tab for it, as in the TUI
    if (!ui.Repo.hasSection(thread.section, opened.resolved.repo.event, opened.handle, opened.session.data.host_kind, opened.source.repo_kind))
        return api.respondError(request, allocator, thread.off, .{});

    const thread_id = evt.parseEventId(std.Uri.percentDecodeInPlace(try aa.dupe(u8, encoded_thread))) catch
        return api.respondError(request, allocator, thread.no_such_thread, .{});
    const comment_id: ?[evt.event_id_size]u8 = if (encoded_comment) |encoded|
        evt.parseEventId(std.Uri.percentDecodeInPlace(try aa.dupe(u8, encoded))) catch return api.respondError(request, allocator, no_such_comment, .{})
    else
        null;

    const page = switch (try query_params.Page.parse(aa, query, .{ .default = Comment.page_size, .max = max_page_size })) {
        .ok => |page| page,
        .invalid => |err| return api.respondError(request, allocator, err, .{}),
    };

    const write = body orelse {
        const read: Read = if (comment_id) |*id| .{ .comment = id } else .thread;
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        if (try readAnswer(thread, &arena, io, &opened, &thread_id, read, page, &out.writer)) |err| return api.respondError(request, allocator, err, .{});
        return api.respondJson(request, out.written(), .{});
    };
    return handleWrite(thread, io, request, allocator, &arena, host, viewer, &opened, &thread_id, comment_id, write);
}

// --- reads ---------------------------------------------------------------------

const Read = union(enum) {
    // the thread's comments, oldest first
    thread,
    // one comment and its immediate replies
    comment: *const [evt.event_id_size]u8,
};

/// what the viewer may do to one comment
const CommentActions = struct {
    reply: api_thread.Availability,
    edit: api_thread.Availability,
    remove: api_thread.Availability,
};

/// who views the comments: whether they may write in the kind's tab (the
/// TUI's tab viewer) and whether anyone is signed in
const Rights = struct { may_comment: bool, signed_in: bool };

fn commentAvailability(comptime thread: Kind, rights: Rights) api_thread.Availability {
    if (rights.may_comment) return .available;
    if (!rights.signed_in) return .{ .unavailable = .{ .code = .unauthenticated, .message = "Log in to comment on this " ++ thread.noun ++ "." } };
    return .{ .unavailable = .{ .code = .forbidden, .message = "Your role in this repository doesn't allow commenting on " ++ thread.plural ++ "." } };
}

fn commentActions(comptime thread: Kind, entry: Comment.CommentWithId, rights: Rights) CommentActions {
    const change: api_thread.Availability = if (entry.comment.removed)
        .{ .unavailable = .{ .code = .conflict, .message = removed_comment.message } }
    else if (entry.can_modify)
        .available
    else if (!rights.signed_in)
        .{ .unavailable = .{ .code = .unauthenticated, .message = "Log in to change this comment." } }
    else
        .{ .unavailable = .{ .code = .forbidden, .message = change_forbidden.message } };
    return .{ .reply = commentAvailability(thread, rights), .edit = change, .remove = change };
}

/// one comment, as every comment route writes it
const CommentJson = struct {
    entry: Comment.CommentWithId,
    // the body parsed as the TUI renders it; nothing once removed
    body: []const md.Block,
    actions: CommentActions,

    pub fn jsonStringify(self: CommentJson, json: *std.json.Stringify) std.Io.Writer.Error!void {
        const event = self.entry.comment.event;
        const removed = self.entry.comment.removed;
        try json.beginObject();
        try json.objectField("id");
        try json.write(&self.entry.id);
        // a reply names its parent comment; a comment on the thread names none
        try json.objectField("parent_id");
        if (std.mem.eql(u8, &event.parent_id, &event.thread_id)) try json.write(null) else try json.write(&event.parent_id);
        try json.objectField("author");
        try json.write(api_thread.Author{ .author = self.entry.author });
        try json.objectField("parent_author");
        if (self.entry.parent_author) |author| try json.write(api_thread.Author{ .author = author }) else try json.write(null);
        try json.objectField("created_at");
        try json.write(api.Instant{ .seconds = self.entry.comment.created_timestamp });
        try json.objectField("removed");
        try json.write(removed);
        try json.objectField("body");
        try json.write(api_md.Blocks{ .blocks = self.body });
        try json.objectField("body_text");
        try json.write(if (removed) "" else event.body);
        try json.objectField("revision");
        try json.write(&std.fmt.bytesToHex(evt.Comment.contentRevision(event), .lower));
        try json.objectField("actions");
        try json.write(self.actions);
        try json.endObject();
    }
};

fn commentJson(comptime thread: Kind, aa: std.mem.Allocator, entry: Comment.CommentWithId, rights: Rights) !CommentJson {
    return .{
        .entry = entry,
        .body = if (entry.comment.removed) &.{} else (try md.parseText(aa, entry.comment.event.body)).blocks,
        .actions = commentActions(thread, entry, rights),
    };
}

/// a window of comments: the page, and the cursor of the window before it
/// (null on the first)
const WindowJson = struct {
    items: []const CommentJson,
    page: struct { has_more: bool, next_cursor: ?[]const u8, count: api.Count },
    previous_cursor: ?[]const u8,
};

fn windowJson(comptime thread: Kind, aa: std.mem.Allocator, window: Comment.Window, size: usize, rights: Rights) !WindowJson {
    const items = try aa.alloc(CommentJson, window.comments.len);
    for (items, window.comments) |*item, entry| item.* = try commentJson(thread, aa, entry, rights);
    const next = if (window.start + size < window.count) window.start + size else null;
    // the first window's cursor is its offset like any other's
    const previous = if (window.start > 0) window.start -| size else null;
    const next_cursor = try query_params.Page.nextCursor(aa, next);
    return .{
        .items = items,
        .page = .{ .has_more = next_cursor != null, .next_cursor = next_cursor, .count = .{ .exact = window.count } },
        .previous_cursor = try query_params.Page.nextCursor(aa, previous),
    };
}

// reads what `read` names and writes its answer, or returns the error to
// answer with: a thread the id doesn't name (or a removed one), or a comment
// that isn't in it
fn readAnswer(
    comptime thread: Kind,
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    opened: *api_thread.Opened,
    thread_id: *const [evt.event_id_size]u8,
    read: Read,
    page: query_params.Page,
    writer: *std.Io.Writer,
) !?api.Error {
    const source = opened.source;
    const gpa = arena.child_allocator;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, gpa, source.localInitOpts());
            defer any_repo.deinit(io, gpa);
            switch (any_repo) {
                inline else => |*repo| {
                    const repo_opts = repo.self_repo_opts;
                    // local mode: bring the event db up to date with the events
                    // branch, as each TUI page build does
                    if (opened.session.local != null)
                        try evt.consume(.local, .repo, repo_kind, repo_opts, io, gpa, repo, evt.events_ref, &.{});
                    // everything below reads this one moment
                    var event_db_maybe: ?evt.LocalEventDB(repo_opts.hash) = if (repo_kind == .git) try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, gpa, repo.core.repo_dir) else null;
                    defer if (event_db_maybe) |*event_db| event_db.deinit(io, gpa);
                    const moment = (if (event_db_maybe) |*event_db|
                        evt.currentMomentFromDb(repo_opts.hash, event_db.db)
                    else if (repo_kind == .git)
                        return thread.no_such_thread
                    else
                        evt.currentMoment(repo_opts, repo)) catch return thread.no_such_thread;
                    return writeAnswer(thread, repo_opts.hash, arena, opened, moment, thread_id, read, page, writer);
                },
            }
        },
    }
}

fn writeAnswer(
    comptime thread: Kind,
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    opened: *api_thread.Opened,
    moment: evt.EventDB(hash_kind).HashMap(.read_only),
    thread_id: *const [evt.event_id_size]u8,
    read: Read,
    page: query_params.Page,
    writer: *std.Io.Writer,
) !?api.Error {
    const aa = arena.allocator();
    if (!try threadLive(hash_kind, arena, moment, thread.kind, thread_id)) return thread.no_such_thread;
    const viewer = ui.Repo.tabViewer(opened.handle, opened.resolved.repo, thread.kind);
    const rights: Rights = .{ .may_comment = viewer != null, .signed_in = opened.handle.viewer != null };
    const admin_moment = opened.session.haxy_moment;
    switch (read) {
        .thread => {
            const window = try Comment.loadWindowSized(hash_kind, arena, admin_moment, moment, evt.Comment.thread_id_to_comment_id_set_key, thread_id, page.start, page.limit, viewer);
            const answer = try windowJson(thread, aa, window, page.limit, rights);
            try std.json.Stringify.value(.{
                .items = answer.items,
                .page = answer.page,
                .previous_cursor = answer.previous_cursor,
                .actions = .{ .create = commentAvailability(thread, rights) },
            }, .{}, writer);
        },
        .comment => |comment_id| {
            const thread_hex = std.fmt.bytesToHex(thread_id.*, .lower);
            const permalink = Comment.initSized(hash_kind, arena, admin_moment, moment, &thread_hex, &std.fmt.bytesToHex(comment_id.*, .lower), page.start, page.limit, viewer) catch |err| switch (err) {
                error.NotFound => return no_such_comment,
                else => |e| return e,
            };
            // the thread's window (at its default size) that shows the comment
            const position = try Comment.threadPosition(hash_kind, moment, permalink.selected);
            const window_start = position - position % Comment.page_size;
            try std.json.Stringify.value(.{
                .comment = try commentJson(thread, aa, permalink.selected, rights),
                .thread_cursor = try query_params.Page.nextCursor(aa, if (window_start == 0) null else window_start),
                .replies = try windowJson(thread, aa, permalink.replies, page.limit, rights),
            }, .{}, writer);
        },
    }
    return null;
}

// whether `id` names a thread of `kind` that isn't removed (notify's rule, which the inbox shares)
pub fn threadLive(comptime hash_kind: hash.HashKind, arena: *std.heap.ArenaAllocator, moment: evt.EventDB(hash_kind).HashMap(.read_only), kind: evt.EventKind, id: *const [evt.event_id_size]u8) !bool {
    return notify.threadLive(hash_kind, arena, moment, kind, id);
}

// --- writes ----------------------------------------------------------------------
//
// every write resolves the repo as the viewer (one they can't read is not
// found), checks the thread and the comment exist, then authorizes the viewer
// afresh, as the TUI and the web forms do (`ui.authorizeUser`: their role in
// the repo, then the kind's tab role), and writes through thread_write, which
// checks who may change an existing comment. local mode has no accounts and
// writes as its repo's owner.

const Change = enum { create, edit, remove };

/// `POST …/<id>/comments`: a comment on the thread, or (with `parent_id`) a
/// reply to one of its comments. `id` is optional: a client that chooses one
/// (32 lowercase hex digits) can retry without posting twice.
pub const CreateRequest = struct {
    id: []const u8,
    parent_id: []const u8,
    body: []const u8,
};

/// `PATCH …/<id>/comments/<comment id>`: the body, replaced as of `revision`
pub const EditRequest = struct {
    revision: []const u8,
    body: []const u8,
};

const Write = union(Change) {
    create: CreateRequest,
    edit: EditRequest,
    remove,
};

fn handleWrite(
    comptime thread: Kind,
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    host: api_repo.Host,
    viewer: ?[evt.event_id_size]u8,
    opened: *api_thread.Opened,
    thread_id: *const [evt.event_id_size]u8,
    comment_id: ?[evt.event_id_size]u8,
    body: Write,
) !void {
    const aa = arena.allocator();
    // the thread and the comment must exist before anything else is said
    {
        const read: Read = if (comment_id) |*id| .{ .comment = id } else .thread;
        var discard: std.Io.Writer.Allocating = .init(aa);
        if (try readAnswer(thread, arena, io, opened, thread_id, read, .{ .start = 0, .limit = 1 }, &discard.writer)) |err| return api.respondError(request, allocator, err, .{});
    }

    const actor = switch (try authorize(thread, io, allocator, arena, host, viewer, opened)) {
        .actor => |actor| actor,
        .refused => |err| return api.respondError(request, allocator, err, .{}),
    };
    const event_host: evt.Host = switch (host) {
        .local => .local,
        .server => |server| .{ .server = .{ .users_dir = server.users_dir, .admin_repo_path = server.admin_repo_path } },
    };
    const source = opened.source;

    const failure: api.Error = switch (body) {
        .create => |fields| blk: {
            const chosen = api_thread.parseNewId(fields.id) orelse break :blk invalidField("id", "Leave the id out, or send 32 lowercase hex digits.");
            const parent = api_thread.parseNewId(fields.parent_id) orelse break :blk invalidField("parent_id", "Leave the parent out to comment on the thread, or send a comment's id.");
            const text = try thread_write.plainNewlines(aa, fields.body);
            if (!evt.Comment.fieldsValid(text)) break :blk body_required;
            const id = chosen orelse random: {
                var bytes: [evt.event_id_size]u8 = undefined;
                io.random(&bytes);
                break :random bytes;
            };
            thread_write.comment(event_host, io, allocator, source, thread.kind, thread_id, if (parent) |*p| p else null, &id, text, actor.author) catch |err| switch (err) {
                error.IdTaken => break :blk id_taken,
                // the thread was checked above, so the parent is no comment in it
                error.NotFound => break :blk .{ .code = .not_found, .message = "There is no comment with this id in this thread to reply to." },
                else => |e| return e,
            };
            return respondComment(thread, request, allocator, arena, io, opened, thread_id, &id, .created);
        },
        .edit => |fields| blk: {
            const revision = api_thread.parseRevision(fields.revision) orelse break :blk invalidField("revision", "Send the revision of the comment as you loaded it.");
            const text = try thread_write.plainNewlines(aa, fields.body);
            if (!evt.Comment.fieldsValid(text)) break :blk body_required;
            thread_write.editComment(event_host, io, allocator, source, actor, thread.kind, thread_id, &comment_id.?, text, revision) catch |err| break :blk try writeError(err);
            return respondComment(thread, request, allocator, arena, io, opened, thread_id, &comment_id.?, .ok);
        },
        .remove => blk: {
            thread_write.remove(event_host, io, allocator, source, actor, thread.kind, thread_id, .comment, &comment_id.?) catch |err| break :blk try writeError(err);
            return respondComment(thread, request, allocator, arena, io, opened, thread_id, &comment_id.?, .ok);
        },
    };
    return api.respondError(request, allocator, failure, .{});
}

// a thread_write refusal, as the API answers it
fn writeError(err: anyerror) !api.Error {
    return switch (err) {
        error.Forbidden => change_forbidden,
        error.NotFound => no_such_comment,
        error.Removed => removed_comment,
        error.Stale => stale_revision,
        error.InvalidFields => body_required,
        else => return err,
    };
}

// the comment as its own route answers it, after a write
fn respondComment(comptime thread: Kind, request: *std.http.Server.Request, allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, io: std.Io, opened: *api_thread.Opened, thread_id: *const [evt.event_id_size]u8, id: *const [evt.event_id_size]u8, status: std.http.Status) !void {
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    const page: query_params.Page = .{ .start = 0, .limit = Comment.page_size };
    // the write landed; only a removal of the thread racing it leaves nothing to show
    if (try readAnswer(thread, arena, io, opened, thread_id, .{ .comment = id }, page, &out.writer)) |err| return api.respondError(request, allocator, err, .{});
    return api.respondJson(request, out.written(), .{ .status = status });
}

const Authorized = union(enum) { actor: ui.Actor, refused: api.Error };

// who the write acts as, checked against the admin db as it is now: a role
// revoked since the viewer's page loaded refuses the write
fn authorize(
    comptime thread: Kind,
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    host: api_repo.Host,
    viewer: ?[evt.event_id_size]u8,
    opened: *api_thread.Opened,
) !Authorized {
    const refused = commentAvailability(thread, .{ .may_comment = false, .signed_in = true }).unavailable;
    switch (host) {
        .local => |source| return .{ .actor = .{ .author = try ui.localAuthor(source, io, allocator, arena), .role = .owner } },
        .server => |server| {
            const unauthenticated: api.Error = .{ .code = .unauthenticated, .message = "Log in to comment on " ++ thread.plural ++ "." };
            const user_id = viewer orelse return .{ .refused = unauthenticated };
            const moment = opened.session.haxy_moment orelse return .{ .refused = unauthenticated };
            return switch (try ui.authorizeUser(io, moment, arena, server.users_dir, user_id, opened.resolved.identity, .read, thread.kind)) {
                .actor => |actor| .{ .actor = actor },
                .login_required => .{ .refused = unauthenticated },
                .repo_not_found => .{ .refused = api_repo.not_found_repo },
                .forbidden => .{ .refused = .{ .code = .forbidden, .message = refused.message } },
            };
        },
    }
}

fn invalidField(comptime field: []const u8, comptime message: []const u8) api.Error {
    return .{
        .code = .validation,
        .message = check_fields,
        .field_errors = &.{.{ .field = field, .message = message }},
    };
}

fn unsupported(request: *std.http.Server.Request, allocator: std.mem.Allocator, comptime allow: []const u8) !void {
    // a write's body goes unread, so the connection closes
    return api.respondError(request, allocator, .{ .code = .unsupported, .message = "This route only supports " ++ allow ++ "." }, .{ .allow = allow, .keep_alive = false });
}
