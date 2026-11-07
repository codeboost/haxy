//! the undo routes of the JSON API: a server repo's undo history, and undoing
//! a transaction in it. every answer is read by the TUI's undo tab
//! (`ui.Repo.Undo.initWindow`), and every undo runs through the operation the
//! TUI's own undo runs (`ui.Repo.Undo.executeAsOwner`), so who sees the
//! history (`ui.Repo.hasSection(.undo, …)`: people who may write), who may
//! undo (its owners, `RepoHandle.canUndo`), what can be undone
//! (`Undo.undoable`) and what each record says are the TUI's.
//!
//! an undo names the history's newest transaction as the client read it
//! (`revision`), and is refused when the history has moved on, so a request
//! repeated after a lost answer never undoes twice. ownership is checked
//! again under the lock role changes take, so an owner demoted after loading
//! the page undoes nothing.
//!
//! local mode leaves undo to xit itself, so every route answers
//! `unsupported` there.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const api_account = @import("./account.zig");
const api_events = @import("./events.zig");
const api_path = @import("./path.zig");
const api_refs = @import("./refs.zig");
const api_repo = @import("./repo.zig");
const api_thread = @import("./thread.zig");
const evt = @import("../event.zig");
const query_params = @import("./query.zig");
const ui = @import("../ui.zig");

const Undo = ui.Repo.Undo;

// a page defaults to the TUI's window; clients may ask for up to this many
const max_page_size = 100;

pub const Route = struct {
    target: api_repo.Route.Target,
    // the transaction the window starts at, as its path segment wrote it;
    // null for the newest
    transaction: ?[]const u8,
};

/// the undo route `path` names, or null when it names none: `<repo>/undo` or
/// `<repo>/undo/<id>`, where `<repo>` is `/api/v1/repos/<owner>/<name>` on a
/// server and `/api/v1/repo` locally
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

// what follows a repo's path: "undo" or "undo/<id>"
fn tail(rest: []const u8) ?struct { transaction: ?[]const u8 } {
    if (std.mem.eql(u8, rest, "undo")) return .{ .transaction = null };
    const prefix = "undo/";
    if (!std.mem.startsWith(u8, rest, prefix)) return null;
    const id = rest[prefix.len..];
    if (id.len == 0 or std.mem.indexOfScalar(u8, id, '/') != null) return null;
    return .{ .transaction = id };
}

/// an undo's body: the transaction to undo (with every one after it), and
/// the history's newest transaction as the client read it, both ids
pub const Execution = struct {
    transaction: []const u8,
    revision: []const u8,
};

pub const ReadExecution = union(enum) {
    ok: struct { transaction: u64, revision: Undo.Revision },
    invalid: api.Error,
};

const check_fields = "Check the highlighted fields.";

fn fieldError(code: api.ErrorCode, comptime field: []const u8, comptime message: []const u8) api.Error {
    return .{ .code = code, .message = check_fields, .field_errors = &.{.{ .field = field, .message = message }} };
}

/// the ids an undo names, or why it is refused
pub fn readExecution(body: Execution) ReadExecution {
    const transaction = api_events.parseTransaction(body.transaction) orelse
        return .{ .invalid = fieldError(.validation, "transaction", "Name the transaction to undo by its id.") };
    var revision: Undo.Revision = undefined;
    const valid = body.revision.len == revision.len * 2 and
        if (std.fmt.hexToBytes(&revision, body.revision)) |_| true else |_| false;
    if (!valid) return .{ .invalid = fieldError(.validation, "revision", "Send the revision of the undo history as you loaded it.") };
    return .{ .ok = .{ .transaction = transaction, .revision = revision } };
}

pub const not_eligible: api.Error = .{ .code = .not_found, .message = "Only people who may write to this repository see its undo history." };
pub const not_owner: api.Error = .{ .code = .forbidden, .message = "Only the repository's owners can undo." };
pub const local_mode: api.Error = .{ .code = .unsupported, .message = "Undo is not available in local mode." };
const no_such_transaction: api.Error = .{ .code = .not_found, .message = "There is no transaction with this id in the undo history." };
const not_undoable: api.Error = .{ .code = .not_found, .message = "There is no transaction with this id that can be undone." };
const history_changed = fieldError(.conflict, "revision", "The undo history changed since you loaded it. Review it again before undoing.");
const changed_meanwhile: api.Error = .{ .code = .conflict, .message = "The repository changed while this was undone. Reload it and try again." };
const stale_cursor: api.Error = .{
    .code = .validation,
    .message = "Check the paging parameters.",
    .field_errors = &.{.{ .field = "cursor", .message = "This cursor isn't one Haxy gave out for this list; start from the first page." }},
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
    const execute = method == .POST and matched.transaction == null;
    // an unread body closes the connection
    if (method != .GET and method != .HEAD and !execute)
        return api.respondError(request, allocator, .{ .code = .unsupported, .message = "This route doesn't support this method." }, .{ .allow = if (matched.transaction == null) "GET, HEAD, POST" else "GET, HEAD", .keep_alive = false });
    if (host == .local) return api.respondError(request, allocator, local_mode, .{ .keep_alive = false });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // read before anything is answered, so every answer leaves no body unread
    const body: ?Execution = if (execute) (try api_account.readBody(Execution, request, allocator, &arena)) orelse return else null;

    // the server's admin repo must outlive the session, whose moment reads from it
    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    var opened = (try api_thread.openRepo(io, request, allocator, &arena, host, viewer, matched.target, &admin_repo_maybe)) orelse return;
    // the TUI's undo tab needs write access; checked before anything else, so
    // a viewer without it gets one answer whatever the request names
    if (!eligible(&opened)) return api.respondError(request, allocator, not_eligible, .{});

    if (body) |value| return undo(io, request, allocator, &arena, host, viewer, matched, &opened, value);

    const window = switch (try readWindow(arena.allocator(), query, matched.transaction)) {
        .ok => |window| window,
        .invalid => |err| return api.respondError(request, allocator, err, .{}),
    };
    const data = switch (try readHistory(io, allocator, &arena, &opened, window)) {
        .ok => |data| data,
        .invalid => |err| return api.respondError(request, allocator, err, .{}),
    };
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try writeHistory(arena.allocator(), &data, &out.writer);
    return api.respondJson(request, out.written(), .{});
}

fn eligible(opened: *const api_thread.Opened) bool {
    return ui.Repo.hasSection(.undo, opened.resolved.repo.event, opened.handle, opened.session.data.host_kind, opened.source.repo_kind);
}

const Window = struct {
    // the transaction the window starts at, or null for the newest
    start: ?u64,
    // what an unlisted start is: a stale cursor, or a missing transaction
    from_cursor: bool,
    page_size: usize,
};

// a window starts at the cursor (a transaction id Haxy gave out), else at
// the transaction the path names
fn readWindow(aa: std.mem.Allocator, query: []const u8, transaction: ?[]const u8) !union(enum) { ok: Window, invalid: api.Error } {
    const page_size = switch (try query_params.pageSize(aa, query, .{ .default = Undo.page_size, .max = max_page_size })) {
        .ok => |size| size,
        .invalid => |err| return .{ .invalid = err },
    };
    const cursor_text = query_params.param(aa, query, "cursor") catch |err| switch (err) {
        error.InvalidPercentEncoding => return .{ .invalid = stale_cursor },
        else => |e| return e,
    };
    if (cursor_text) |text| return .{ .ok = .{
        .start = api_events.parseTransaction(text) orelse return .{ .invalid = stale_cursor },
        .from_cursor = true,
        .page_size = page_size,
    } };
    const start: ?u64 = if (transaction) |text| api_events.parseTransaction(text) orelse return .{ .invalid = no_such_transaction } else null;
    return .{ .ok = .{ .start = start, .from_cursor = false, .page_size = page_size } };
}

// the window as the TUI's undo tab reads it, or why it can't be shown
fn readHistory(io: std.Io, allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, opened: *api_thread.Opened, window: Window) !union(enum) { ok: Undo, invalid: api.Error } {
    var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, opened.source.localInitOpts());
    defer any_repo.deinit(io, allocator);
    switch (any_repo) {
        inline else => |*repo| return .{
            .ok = Undo.initWindow(repo.self_repo_opts, arena, repo, opened.session.haxy_moment, opened.resolved.identity, window.start, opened.handle, window.page_size) catch |err| switch (err) {
                error.NotFound => return .{ .invalid = if (window.from_cursor) stale_cursor else no_such_transaction },
                else => |e| return e,
            },
        },
    }
}

fn writeHistory(aa: std.mem.Allocator, data: *const Undo, writer: *std.Io.Writer) !void {
    const items = try aa.alloc(Item, data.items.len);
    for (items, data.items) |*item, value| item.* = try .init(aa, data, value);
    const revision = std.fmt.bytesToHex(data.revision, .lower);
    try std.json.Stringify.value(.{
        .revision = &revision,
        .newest = try std.fmt.allocPrint(aa, "{d}", .{data.count - 1}),
        .items = items,
        .page = .{
            .has_more = data.next != null,
            .next_cursor = if (data.next) |next| try std.fmt.allocPrint(aa, "{d}", .{next}) else null,
            // every transaction from the floor up is listed
            .count = api.Count{ .exact = data.count - data.floor },
        },
    }, .{}, writer);
}

fn undo(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    host: api_repo.Host,
    viewer: ?[evt.event_id_size]u8,
    matched: Route,
    opened: *api_thread.Opened,
    body: Execution,
) !void {
    const aa = arena.allocator();
    if (!opened.handle.canUndo()) return api.respondError(request, allocator, not_owner, .{});
    const ids = switch (readExecution(body)) {
        .ok => |ids| ids,
        .invalid => |err| return api.respondError(request, allocator, err, .{}),
    };
    const resolved = opened.resolved;
    // an owner is signed in, on a server
    const actor_id = viewer orelse unreachable;
    const repo_id = resolved.repo_id orelse unreachable;
    const executed = Undo.executeAsOwner(io, allocator, opened.session.users_dir orelse unreachable, &resolved.owner_id, &repo_id, &actor_id, resolved.repo.event.name, ids.transaction, ids.revision, .{
        .arena = arena,
        .haxy_moment = opened.session.haxy_moment,
        .identity = resolved.identity,
        .handle = opened.handle,
    }) catch |err| switch (err) {
        error.HistoryChanged => return api.respondError(request, allocator, history_changed, .{}),
        error.InvalidHistoryIndex, error.TransactionNotFound => return api.respondError(request, allocator, not_undoable, .{}),
        // renamed or deleted meanwhile: nothing that took its name is undone
        error.NotFound => return api.respondError(request, allocator, api_repo.not_found_repo, .{}),
        error.NotOwner => return respondNotOwner(io, request, allocator, host, viewer, matched),
        else => |e| return e,
    };

    // the undo's own record, read under the lock it ran in (a clear landing
    // since could give its index to another transaction): its undo is the
    // action that restores what was undone
    const data = executed.record orelse unreachable;
    var out: std.Io.Writer.Allocating = .init(aa);
    const revision = std.fmt.bytesToHex(executed.revision, .lower);
    try std.json.Stringify.value(.{
        // the history right after this undo, which a later one (such as its
        // reversal) names; another change that landed since makes it stale,
        // as it should
        .revision = &revision,
        .record = try Item.init(aa, &data, data.items[0]),
    }, .{}, &out.writer);
    return api.respondJson(request, out.written(), .{ .status = .created });
}

// an undo found its actor no longer owns the repo: answer as their
// authorization now reads
fn respondNotOwner(io: std.Io, request: *std.http.Server.Request, allocator: std.mem.Allocator, host: api_repo.Host, viewer: ?[evt.event_id_size]u8, matched: Route) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    var opened = (try api_thread.openRepo(io, request, allocator, &arena, host, viewer, matched.target, &admin_repo_maybe)) orelse return;
    if (!eligible(&opened)) return api.respondError(request, allocator, not_eligible, .{});
    if (!opened.handle.canUndo()) return api.respondError(request, allocator, not_owner, .{});
    return api.respondError(request, allocator, changed_meanwhile, .{});
}

/// a transaction in the undo history, as the TUI's undo tab shows it
pub const Item = struct {
    transaction: []const u8,
    action: []const u8,
    description: []const u8,
    // null when the transaction has no undo record
    created_at: ?api.Instant,
    // a later undo discarded it
    undone: bool,
    // what the TUI shows in place of the description, each a label, a text
    // and what it opens
    details: []const Detail,
    actions: struct { undo: Action },

    fn init(aa: std.mem.Allocator, data: *const Undo, item: Undo.Item) !Item {
        const details = try aa.alloc(Detail, item.buttons.len);
        for (details, item.buttons) |*detail, button| detail.* = .{
            .label = std.mem.trim(u8, button.label, " "),
            .text = try api_path.display(aa, button.text),
            .target = if (button.target) |target| try Target.init(aa, target) else null,
        };
        return .{
            .transaction = try std.fmt.allocPrint(aa, "{d}", .{item.index}),
            .action = try api_path.display(aa, item.action),
            .description = try api_path.display(aa, item.description),
            .created_at = if (item.timestamp >= 0) .{ .seconds = @intCast(item.timestamp) } else null,
            .undone = item.undone,
            .details = details,
            .actions = .{ .undo = availability(data, item) },
        };
    }
};

// whether the viewer may undo `item`: its owners may undo anything above
// the history's floor, as in the TUI
fn availability(data: *const Undo, item: Undo.Item) Action {
    if (!data.handle.canUndo()) return .{ .available = false, .reason = .{ .code = not_owner.code, .message = not_owner.message } };
    if (!Undo.undoable(item.index, data.floor)) return .{ .available = false, .reason = .{
        .code = .unsupported,
        .message = if (item.index == 0) "The initial state can't be undone." else "The history this repository was copied with can't be undone.",
    } };
    return .{ .available = true, .reason = null };
}

const Action = struct {
    available: bool,
    reason: ?struct { code: api.ErrorCode, message: []const u8 },
};

pub const Detail = struct {
    label: []const u8,
    text: []const u8,
    target: ?Target,
};

/// what a detail opens, by structure rather than by a Haxy url:
/// `{"kind": "transaction", "transaction"}` (the history at a transaction),
/// `{"kind": "events", "transaction"}` (the events a transaction wrote),
/// `{"kind": "user", "name"}`, `{"kind": "commits", "tip", "base"}` (object
/// ids) or `{"kind": "branch" | "tag", "ref", "name"}` (a ref id, see Refs)
pub const Target = struct {
    target: Undo.Target,
    // a branch or tag's ref id and display name
    ref_id: []const u8 = "",
    ref_name: []const u8 = "",

    fn init(aa: std.mem.Allocator, target: Undo.Target) !Target {
        const ref = switch (target) {
            .ref => |ref| ref,
            else => return .{ .target = target },
        };
        const selection: api_refs.Selection = switch (ref.kind) {
            .branch => .{ .branch = ref.name },
            .tag => .{ .tag = ref.name },
        };
        return .{ .target = target, .ref_id = try selection.id(aa), .ref_name = try api_path.display(aa, ref.name) };
    }

    pub fn jsonStringify(self: Target, json: *std.json.Stringify) std.Io.Writer.Error!void {
        try json.beginObject();
        switch (self.target) {
            .transaction, .events => |index| {
                try json.objectField("kind");
                try json.write(@tagName(self.target));
                try json.objectField("transaction");
                var digits: [20]u8 = undefined;
                try json.write(std.fmt.bufPrint(&digits, "{d}", .{index}) catch unreachable);
            },
            .user => |name| {
                try json.objectField("kind");
                try json.write("user");
                try json.objectField("name");
                try json.write(name);
            },
            .commits => |commits| {
                try json.objectField("kind");
                try json.write("commits");
                try json.objectField("tip");
                try json.write(commits.tip);
                try json.objectField("base");
                try json.write(if (commits.base.len == 0) null else commits.base);
            },
            .ref => |ref| {
                try json.objectField("kind");
                try json.write(@tagName(ref.kind));
                try json.objectField("ref");
                try json.write(self.ref_id);
                try json.objectField("name");
                try json.write(self.ref_name);
            },
        }
        try json.endObject();
    }
};
