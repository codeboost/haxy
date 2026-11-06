//! the attachment routes every thread kind shares (issues, discussions and
//! patches each hook this module in with their own `Kind`): uploading a
//! file to a thread, downloading one, and removing one. a thread's answer
//! lists its attachments (`item`) and the upload limits (`limits`).
//!
//! - `POST <thread>/attachments?name=&id=`: the file is the whole request
//!   body, streamed into the object store; 201 with the thread
//! - `GET`/`HEAD <thread>/attachments/{id}`: the file's bytes
//! - `DELETE <thread>/attachments/{id}`: the thread, without it
//!
//! the rules are the TUI's and Haxy's HTML routes': the upload limits, the
//! content handling and the read check are `attachment.zig`'s, and the writes
//! go through `thread_write.attach` and `thread_write.remove`.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const api_comments = @import("./comments.zig");
const api_path = @import("./path.zig");
const api_repo = @import("./repo.zig");
const api_thread = @import("./thread.zig");
const attachment = @import("../attachment.zig");
const evt = @import("../event.zig");
const query_params = @import("./query.zig");
const thread_write = @import("../thread_write.zig");
const ui = @import("../ui.zig");

/// what a thread kind's attachment routes need to know about it: what its
/// comment routes know, and how to read one thread as its own route answers it.
/// who may write in the kind's tab is `api_thread.authorize` with the kind.
pub const Kind = struct {
    thread: api_comments.Kind,
    // the thread `id` names as its own route answers it, or null when there is none
    readDetail: *const fn (arena: *std.heap.ArenaAllocator, io: std.Io, opened: *api_thread.Opened, id: *const [evt.event_id_size]u8) anyerror!?[]const u8,
};

/// what a thread's answer says about uploads, so a client can refuse a file
/// before sending it. Haxy checks again when the upload arrives.
pub const Limits = struct {
    max_bytes: u64,
    max_name_bytes: usize,
};

pub const limits: Limits = .{ .max_bytes = attachment.max_size, .max_name_bytes = attachment.name_max_len };

/// who views an attachment: the TUI's tab viewer (null when they may not
/// write in the kind's tab), and whether anyone is signed in
pub const Rights = struct { viewer: ?ui.Viewer, signed_in: bool };

/// one attachment, as a thread's answer lists it
pub const Item = struct {
    id: [evt.event_id_size * 2]u8,
    // for display: bytes that aren't utf-8 are replaced
    name: []const u8,
    content_type: []const u8,
    // whether a browser shows it in place rather than downloading it
    @"inline": bool,
    actions: struct { remove: api_thread.Availability },
};

const remove_forbidden: api.Error = .{ .code = .forbidden, .message = "Only the attachment's author and the repository's writers can remove it." };

pub fn item(aa: std.mem.Allocator, entry: ui.Repo.Attachment.WithId, rights: Rights) !Item {
    const how = attachment.handling(entry.name);
    const removal: api_thread.Availability = if (rights.viewer) |viewer|
        (if (viewer.role.canModify(viewer.email, entry.author_email)) .available else .{ .unavailable = .{ .code = .forbidden, .message = remove_forbidden.message } })
    else if (!rights.signed_in)
        .{ .unavailable = .{ .code = .unauthenticated, .message = "Log in to remove attachments." } }
    else
        .{ .unavailable = .{ .code = .forbidden, .message = remove_forbidden.message } };
    return .{
        .id = entry.id,
        .name = try api_path.display(aa, entry.name),
        .content_type = how.content_type,
        .@"inline" = how.inline_,
        .actions = .{ .remove = removal },
    };
}

pub fn items(aa: std.mem.Allocator, entries: []const ui.Repo.Attachment.WithId, rights: Rights) ![]const Item {
    const out = try aa.alloc(Item, entries.len);
    for (out, entries) |*one, entry| one.* = try item(aa, entry, rights);
    return out;
}

const no_such_attachment_message = "There is no attachment with this id on this ";
const check_fields = "Check the highlighted fields.";
const id_taken: api.Error = .{
    .code = .conflict,
    .message = check_fields,
    .field_errors = &.{.{ .field = "id", .message = "An event in this repository already has this id." }},
};

// an upload refused before it is stored, beside the field it is about
fn uploadError(failure: attachment.UploadFailure) api.Error {
    return switch (failure) {
        .name_required => .{ .code = .validation, .message = check_fields, .field_errors = &.{.{ .field = "name", .message = "Name the file." }} },
        .invalid_name => .{ .code = .validation, .message = check_fields, .field_errors = &.{.{ .field = "name", .message = std.fmt.comptimePrint("A file name can be up to {d} bytes, without slashes or control characters, and not . or ..", .{attachment.name_max_len}) }} },
        .length_required => .{ .code = .validation, .message = check_fields, .field_errors = &.{.{ .field = "file", .message = "Send the file with its length (Content-Length)." }} },
        .empty => .{ .code = .validation, .message = check_fields, .field_errors = &.{.{ .field = "file", .message = "The file is empty." }} },
        .too_large => .{ .code = .validation, .message = check_fields, .field_errors = &.{.{ .field = "file", .message = std.fmt.comptimePrint("Files can be up to {d} MB.", .{attachment.max_size / (1024 * 1024)}) }} },
    };
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
    comptime kind: Kind,
) !void {
    const method = request.head.method;
    switch (matched.resource) {
        .attachments => |encoded_thread| {
            if (method != .POST) return refuseUpload(request, allocator, null, .{ .code = .unsupported, .message = "This route only supports POST." }, .{ .allow = "POST" });
            return upload(io, request, allocator, host, viewer, matched.target, encoded_thread, query, kind);
        },
        .attachment => |ids| {
            if (method == .GET or method == .HEAD) return download(io, request, allocator, host, viewer, matched.target, ids.thread, ids.attachment, kind);
            if (method == .DELETE) return remove(io, request, allocator, host, viewer, matched.target, ids.thread, ids.attachment, kind);
            return api.respondError(request, allocator, .{ .code = .unsupported, .message = "This route only supports GET, HEAD and DELETE." }, .{ .allow = "GET, HEAD, DELETE", .keep_alive = false });
        },
        else => unreachable,
    }
}

// a request body Haxy reads to the end before answering, so the client
// sees the answer rather than a connection closed under its upload. bigger
// ones close the connection instead.
pub const max_drain: u64 = 4 * attachment.max_size;

/// whether a refused upload's body is read to the end before the answer:
/// only a body whose declared length is at most `max_drain`, from a client
/// not waiting on `Expect: 100-continue` (which hasn't sent it). a chunked
/// body could be any size, whatever length it also declares (the body
/// reader follows the chunks), so its connection closes.
pub fn drainable(content_length: ?u64, transfer_encoding: std.http.TransferEncoding, expects_continue: bool) bool {
    if (transfer_encoding != .none) return false;
    const length = content_length orelse return false;
    return !expects_continue and length <= max_drain;
}

// answers an upload that isn't stored. the body (whose reader is `body` once
// taken) is read and dropped when it is small enough, else the connection
// closes; a client waiting on `Expect: 100-continue` sent none of it.
fn refuseUpload(request: *std.http.Server.Request, allocator: std.mem.Allocator, body: ?*std.Io.Reader, err: api.Error, options: api.RespondOptions) !void {
    var keep_alive = drainable(request.head.content_length, request.head.transfer_encoding, request.head.expect != null);
    if (keep_alive) {
        // read here rather than by the server's own discard, which reads
        // through an empty buffer
        var buffer: [8192]u8 = undefined;
        const reader = body orelse request.readerExpectContinue(&buffer) catch null;
        if (reader) |r| _ = r.discardRemaining() catch {
            keep_alive = false;
        } else keep_alive = false;
    }
    var answered = options;
    answered.keep_alive = keep_alive;
    return api.respondError(request, allocator, err, answered);
}

// opens the repo and checks the thread for a request naming one: the repo the
// viewer may read, the kind's tab on, the thread live. null once it answered.
fn openThread(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    host: api_repo.Host,
    viewer: ?[evt.event_id_size]u8,
    target: api_repo.Route.Target,
    encoded_thread: []const u8,
    admin_repo: *?rp.Repo(.xit, evt.admin_repo_opts),
    comptime kind: Kind,
    // how a refusal answers: an upload's leaves its body to drop
    comptime refuse: fn (*std.http.Server.Request, std.mem.Allocator, api.Error) anyerror!void,
) !?struct { opened: api_thread.Opened, thread_id: [evt.event_id_size]u8 } {
    // openRepo answers its own refusals, so an upload's body is read first
    // only when it is small; uploads checked their size before this
    var opened = (try api_thread.openRepo(io, request, allocator, arena, host, viewer, target, admin_repo)) orelse return null;
    if (!ui.Repo.hasSection(kind.thread.section, opened.resolved.repo.event, opened.handle, opened.session.data.host_kind, opened.source.repo_kind)) {
        try refuse(request, allocator, kind.thread.off);
        return null;
    }
    const thread_id = evt.parseEventId(std.Uri.percentDecodeInPlace(try arena.allocator().dupe(u8, encoded_thread))) catch {
        try refuse(request, allocator, kind.thread.no_such_thread);
        return null;
    };
    if (try kind.readDetail(arena, io, &opened, &thread_id) == null) {
        try refuse(request, allocator, kind.thread.no_such_thread);
        return null;
    }
    return .{ .opened = opened, .thread_id = thread_id };
}

fn refusePlain(request: *std.http.Server.Request, allocator: std.mem.Allocator, err: api.Error) !void {
    return api.respondError(request, allocator, err, .{});
}

fn refuseUnread(request: *std.http.Server.Request, allocator: std.mem.Allocator, err: api.Error) !void {
    return refuseUpload(request, allocator, null, err, .{});
}

fn noSuchAttachment(comptime kind: Kind) api.Error {
    return .{ .code = .not_found, .message = no_such_attachment_message ++ kind.thread.noun ++ "." };
}

fn eventHost(host: api_repo.Host) evt.Host {
    return switch (host) {
        .local => .local,
        .server => |server| .{ .server = .{ .users_dir = server.users_dir, .admin_repo_path = server.admin_repo_path } },
    };
}

fn upload(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    host: api_repo.Host,
    viewer: ?[evt.event_id_size]u8,
    target: api_repo.Route.Target,
    encoded_thread: []const u8,
    query: []const u8,
    comptime kind: Kind,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // what the upload is, checked before any of it is read or the repo opened
    const name = query_params.param(aa, query, "name") catch |err| switch (err) {
        error.InvalidPercentEncoding => return refuseUpload(request, allocator, null, uploadError(.invalid_name), .{}),
        else => |e| return e,
    };
    const length = attachment.declaredLength(request.head.content_length, request.head.transfer_encoding);
    if (attachment.checkUpload(name, length)) |failure|
        return refuseUpload(request, allocator, null, uploadError(failure), .{ .status = if (failure == .too_large) .payload_too_large else null });
    const id_text = query_params.param(aa, query, "id") catch |err| switch (err) {
        // not an id haxy could have given out
        error.InvalidPercentEncoding => "?",
        else => |e| return e,
    };
    const chosen = api_thread.parseNewId(id_text orelse "") orelse
        return refuseUpload(request, allocator, null, .{ .code = .validation, .message = check_fields, .field_errors = &.{.{ .field = "id", .message = "Leave the id out, or send 32 lowercase hex digits." }} }, .{});

    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    var found = (try openThread(io, request, allocator, &arena, host, viewer, target, encoded_thread, &admin_repo_maybe, kind, refuseUnread)) orelse return;
    const actor = switch (try api_thread.authorize(kind.thread.kind, io, allocator, &arena, host, viewer, &found.opened)) {
        .actor => |actor| actor,
        .refused => |err| return refuseUpload(request, allocator, null, err, .{}),
    };

    const id = chosen orelse random: {
        var bytes: [evt.event_id_size]u8 = undefined;
        io.random(&bytes);
        break :random bytes;
    };
    var body_buf: [8192]u8 = undefined;
    const body = try request.readerExpectContinue(&body_buf);
    const blob: evt.Blob = .{ .name = name.?, .size = length.?, .reader = body };
    thread_write.attach(eventHost(host), io, allocator, found.opened.source, actor, kind.thread.kind, &found.thread_id, &id, blob) catch |err| {
        const refusal: api.Error = switch (err) {
            error.Forbidden => .{ .code = .forbidden, .message = "Only the " ++ kind.thread.noun ++ "'s author and the repository's writers can attach files to it." },
            error.NotFound => kind.thread.no_such_thread,
            error.IdTaken => id_taken,
            else => |e| return e,
        };
        return refuseUpload(request, allocator, body, refusal, .{});
    };
    return respondThread(request, allocator, &arena, io, &found.opened, &found.thread_id, kind, .created);
}

fn download(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    host: api_repo.Host,
    viewer: ?[evt.event_id_size]u8,
    target: api_repo.Route.Target,
    encoded_thread: []const u8,
    encoded_attachment: []const u8,
    comptime kind: Kind,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    const found = (try openThread(io, request, allocator, &arena, host, viewer, target, encoded_thread, &admin_repo_maybe, kind, refusePlain)) orelse return;
    const id = evt.parseEventId(std.Uri.percentDecodeInPlace(try arena.allocator().dupe(u8, encoded_attachment))) catch
        return api.respondError(request, allocator, noSuchAttachment(kind), .{});

    const source = found.opened.source;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| {
                    const thread: attachment.ThreadRef = .{ .kind = kind.thread.kind, .id = &found.thread_id };
                    if (!try attachment.send(repo_kind, repo.self_repo_opts, io, request, allocator, repo, &id, thread))
                        return api.respondError(request, allocator, noSuchAttachment(kind), .{});
                },
            }
        },
    }
}

fn remove(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    host: api_repo.Host,
    viewer: ?[evt.event_id_size]u8,
    target: api_repo.Route.Target,
    encoded_thread: []const u8,
    encoded_attachment: []const u8,
    comptime kind: Kind,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    var found = (try openThread(io, request, allocator, &arena, host, viewer, target, encoded_thread, &admin_repo_maybe, kind, refusePlain)) orelse return;
    const id = evt.parseEventId(std.Uri.percentDecodeInPlace(try arena.allocator().dupe(u8, encoded_attachment))) catch
        return api.respondError(request, allocator, noSuchAttachment(kind), .{});
    const actor = switch (try api_thread.authorize(kind.thread.kind, io, allocator, &arena, host, viewer, &found.opened)) {
        .actor => |actor| actor,
        .refused => |err| return api.respondError(request, allocator, err, .{}),
    };
    thread_write.remove(eventHost(host), io, allocator, found.opened.source, actor, kind.thread.kind, &found.thread_id, .attach, &id) catch |err| {
        const refusal: api.Error = switch (err) {
            error.Forbidden => remove_forbidden,
            error.NotFound => noSuchAttachment(kind),
            else => |e| return e,
        };
        return api.respondError(request, allocator, refusal, .{});
    };
    return respondThread(request, allocator, &arena, io, &found.opened, &found.thread_id, kind, .ok);
}

// the thread as its own route reads it, after a write
fn respondThread(request: *std.http.Server.Request, allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, io: std.Io, opened: *api_thread.Opened, id: *const [evt.event_id_size]u8, comptime kind: Kind, status: std.http.Status) !void {
    // the write landed; only a removal racing it leaves nothing to show
    const detail = (try kind.readDetail(arena, io, opened, id)) orelse return api.respondError(request, allocator, kind.thread.no_such_thread, .{});
    return api.respondJson(request, detail, .{ .status = status });
}
