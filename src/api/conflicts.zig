//! the metadata conflict routes of the JSON API, for issues and patches: the
//! conflicted threads of a kind, one thread's conflict with both sides and
//! their authors per field and description chunk, and its resolution. the
//! list and the conflict are read by the TUI's thread tabs
//! (`ui.Repo.Issues.init`/`ui.Repo.Patches.init`, conflicts and resolve
//! views), and a resolution is written by `thread_write.resolve`, which the
//! TUI's resolve form and Haxy's HTML form use too: one event carrying the
//! resolved fields, consumed as any other.
//!
//! - `GET …/issues/conflicts?cursor=&page_size=`: `{"items", "page"}`
//! - `GET …/issues/{id}/conflict`: `{"thread", "conflict", "actions"}`
//! - `POST …/issues/{id}/conflict` (see `shapes.Request`): the thread as
//!   its own route reads it
//!
//! and the same under `…/patches`. these are metadata conflicts only: a
//! patch's code mergeability is its own route's `mergeability`.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const api_issues = @import("./issues.zig");
const api_patches = @import("./patches.zig");
const api_repo = @import("./repo.zig");
const api_thread = @import("./thread.zig");
const evt = @import("../event.zig");
const query_params = @import("./query.zig");
const thread_write = @import("../thread_write.zig");
const ui = @import("../ui.zig");
const shapes = @import("./conflict_shapes.zig");

const max_page_size = 100;
const max_body_size = 64 * 1024;

pub const Kind = enum { issues, patches };

pub const Route = struct {
    kind: Kind,
    target: api_repo.Route.Target,
    // one thread's hex id, still encoded; null for the kind's conflicted threads
    thread: ?[]const u8,
};

const conflict_suffix = "/conflict";
const list_segment = "conflicts";

/// the conflict route `path` names: `<kind>/conflicts`, or
/// `<thread>/conflict` where `<thread>` is an issue's or a patch's own route
pub fn route(path: []const u8) ?Route {
    inline for (@typeInfo(Kind).@"enum".field_names) |name| {
        if (match(path, @field(Kind, name))) |matched| return matched;
    }
    return null;
}

fn match(path: []const u8, comptime kind: Kind) ?Route {
    const one = std.mem.endsWith(u8, path, conflict_suffix);
    const thread_path = if (one) path[0 .. path.len - conflict_suffix.len] else path;
    const matched = api_thread.route(thread_path, @tagName(kind)) orelse return null;
    const id = switch (matched.resource) {
        .thread => |id| id,
        else => return null,
    };
    const listing = std.mem.eql(u8, id, list_segment);
    if (one == listing) return null;
    return .{ .kind = kind, .target = matched.target, .thread = if (one) id else null };
}

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
    const reading = method == .GET or method == .HEAD;
    if (matched.thread == null and !reading) return api_thread.unsupported(request, allocator, "GET, HEAD");
    if (!reading and method != .POST) return api_thread.unsupported(request, allocator, "GET, HEAD, POST");
    return switch (matched.kind) {
        inline else => |kind| Handler(kind).handle(io, request, allocator, host, viewer, matched, query),
    };
}

fn Handler(comptime kind: Kind) type {
    return struct {
        const Thread = Of(kind);

        fn handle(io: std.Io, request: *std.http.Server.Request, allocator: std.mem.Allocator, host: api_repo.Host, viewer: ?[evt.event_id_size]u8, matched: Route, query: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const posted: ?[]const u8 = if (request.head.method == .POST) (try readBody(request, allocator, &arena)) orelse return else null;

            var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
            defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
            var opened = (try api_thread.openRepo(io, request, allocator, &arena, host, viewer, matched.target, &admin_repo_maybe)) orelse return;
            if (!ui.Repo.hasSection(Thread.section, opened.resolved.repo.event, opened.handle, opened.session.data.host_kind, opened.source.repo_kind))
                return api.respondError(request, allocator, Thread.off, .{});

            const encoded = matched.thread orelse return respondList(io, request, allocator, &arena, &opened, query);
            const id = evt.parseEventId(std.Uri.percentDecodeInPlace(try arena.allocator().dupe(u8, encoded))) catch
                return api.respondError(request, allocator, Thread.no_such, .{});
            if (posted) |body| return resolve(io, request, allocator, &arena, host, viewer, &opened, &id, body);
            const answer = (try readConflict(io, &arena, &opened, &id)) orelse return api.respondError(request, allocator, Thread.no_such, .{});
            return respondValue(request, &arena, answer);
        }

        fn respondList(io: std.Io, request: *std.http.Server.Request, allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, opened: *api_thread.Opened, query: []const u8) !void {
            const aa = arena.allocator();
            const cursor = (query_params.param(aa, query, "cursor") catch |err| switch (err) {
                error.InvalidPercentEncoding => return api.respondError(request, allocator, api_thread.stale_cursor, .{}),
                else => |e| return e,
            }) orelse "";
            const page_size = switch (try query_params.pageSize(aa, query, .{ .default = Thread.Data.page_size, .max = max_page_size })) {
                .ok => |size| size,
                .invalid => |err| return api.respondError(request, allocator, err, .{}),
            };
            var body: std.Io.Writer.Allocating = .init(aa);
            const found = try withRepo(io, arena, opened, ListRead{ .cursor = cursor, .page_size = page_size, .writer = &body.writer });
            if (!found) return api.respondError(request, allocator, api_thread.stale_cursor, .{});
            return api.respondJson(request, body.written(), .{});
        }

        // one window of the kind's conflicted threads, newest first, as the
        // TUI's conflicts tab lists them; false when the cursor names none
        const ListRead = struct {
            cursor: []const u8,
            page_size: usize,
            writer: *std.Io.Writer,

            fn run(self: ListRead, comptime repo_kind: rp.RepoKind, comptime repo_opts: rp.RepoOpts(repo_kind), arena: *std.heap.ArenaAllocator, repo: *rp.Repo(repo_kind, repo_opts), io: std.Io, opened: *api_thread.Opened) !bool {
                const aa = arena.allocator();
                const data = Thread.init(repo_kind, repo_opts, arena, repo, io, opened, self.cursor, .conflicts, .{ .shown = self.page_size, .others = 0 }) catch |err| switch (err) {
                    error.NotFound => return false,
                    else => |e| return e,
                };
                const window = data.conflicts;
                // a cursor roots the window at its own thread, which must still be conflicted
                if (self.cursor.len != 0 and (window.items.len == 0 or !std.mem.eql(u8, window.items[0].id, self.cursor))) return false;
                const items = try aa.alloc(api_thread.Summary(Thread.Status), window.items.len);
                for (items, window.items) |*item, *entry| item.* = try Thread.summary(aa, entry);
                try api.writePage(self.writer, items, .{ .next_cursor = window.next_id, .count = api_thread.count(window) });
                return true;
            }
        };

        const Answer = struct {
            thread: api_thread.Summary(Thread.Status),
            conflict: ?shapes.Conflict,
            actions: struct { resolve: api_thread.Availability },
        };

        // the thread `id` names with its conflict, or null when there is no such thread
        fn readConflict(io: std.Io, arena: *std.heap.ArenaAllocator, opened: *api_thread.Opened, id: *const [evt.event_id_size]u8) !?Answer {
            var answer: ?Answer = null;
            _ = try withRepo(io, arena, opened, ConflictRead{ .id = id, .answer = &answer });
            return answer;
        }

        const ConflictRead = struct {
            id: *const [evt.event_id_size]u8,
            answer: *?Answer,

            fn run(self: ConflictRead, comptime repo_kind: rp.RepoKind, comptime repo_opts: rp.RepoOpts(repo_kind), arena: *std.heap.ArenaAllocator, repo: *rp.Repo(repo_kind, repo_opts), io: std.Io, opened: *api_thread.Opened) !bool {
                const aa = arena.allocator();
                const hex = try aa.dupe(u8, &std.fmt.bytesToHex(self.id.*, .lower));
                // the resolve view shows no list, so the thread's own status window is one of the others
                const data = Thread.init(repo_kind, repo_opts, arena, repo, io, opened, hex, .resolve, .{ .shown = 1, .others = 1 }) catch |err| switch (err) {
                    error.NotFound => return false,
                    else => |e| return e,
                };
                const entry = data.selectedThread() orelse return false;
                const read: ?shapes.Conflict = if (data.conflict) |conflict| try shapes.fromRead(aa, conflict) else null;
                self.answer.* = .{
                    .thread = try Thread.summary(aa, entry),
                    .conflict = read,
                    .actions = .{ .resolve = resolveAvailability(opened, read != null) },
                };
                return true;
            }
        };

        fn resolveAvailability(opened: *api_thread.Opened, conflicted: bool) api_thread.Availability {
            if (!conflicted) return .{ .unavailable = .{ .code = .conflict, .message = "This " ++ Thread.noun ++ " has no conflict to resolve." } };
            if (opened.handle.viewer == null) return .{ .unavailable = .{ .code = .unauthenticated, .message = unauthenticated.message } };
            const tab = ui.Repo.tabViewer(opened.handle, opened.resolved.repo, Thread.event_kind) orelse return .{ .unavailable = .{ .code = .forbidden, .message = forbidden.message } };
            if (!tab.role.atLeast(.write)) return .{ .unavailable = .{ .code = .forbidden, .message = forbidden.message } };
            return .available;
        }

        fn resolve(io: std.Io, request: *std.http.Server.Request, allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, host: api_repo.Host, viewer: ?[evt.event_id_size]u8, opened: *api_thread.Opened, id: *const [evt.event_id_size]u8, body: []const u8) !void {
            const aa = arena.allocator();
            const current = (try readConflict(io, arena, opened, id)) orelse return api.respondError(request, allocator, Thread.no_such, .{});
            const actor = switch (try authorize(io, arena, host, viewer, opened)) {
                .actor => |actor| actor,
                .refused => |err| return api.respondError(request, allocator, err, .{}),
            };
            const resolution = switch (try resolutionOf(aa, current, body)) {
                .ok => |resolution| resolution,
                .invalid => |err| return api.respondError(request, allocator, err, .{}),
            };
            thread_write.resolve(Thread.Event, eventHost(host), io, allocator, opened.source, actor, id, resolution) catch |err| {
                return api.respondError(request, allocator, try writeError(err), .{});
            };
            const detail = (try Thread.readDetail(arena, io, opened, id)) orelse return api.respondError(request, allocator, Thread.no_such, .{});
            return api.respondJson(request, detail, .{});
        }

        // the request's resolution of the conflict as it is now, or why it can't be one
        fn resolutionOf(aa: std.mem.Allocator, current: Answer, body: []const u8) !union(enum) { ok: Thread.Event.Resolve, invalid: api.Error } {
            const request = switch (try shapes.parseRequest(aa, body)) {
                .ok => |request| request,
                .invalid => |err| return .{ .invalid = err },
            };
            const revision = api_thread.parseRevision(request.revision) orelse return .{ .invalid = api_thread.invalidField("revision", "Send the revision of the conflict as you loaded it.") };
            const conflict = current.conflict orelse return .{ .invalid = stale };
            if (!std.mem.eql(u8, conflict.revision, &std.fmt.bytesToHex(revision, .lower))) return .{ .invalid = stale };
            const checked = switch (try shapes.check(aa, Thread.event_kind, try shapes.offered(aa, conflict), request)) {
                .ok => |checked| checked,
                .invalid => |err| return .{ .invalid = err },
            };
            var resolution: Thread.Event.Resolve = .{ .title = checked.title, .labels = checked.labels, .hunks = checked.hunks, .revision = revision };
            if (comptime @hasField(Thread.Event.Resolve, "theirs")) resolution.theirs = checked.theirs;
            return .{ .ok = resolution };
        }

        fn writeError(err: anyerror) !api.Error {
            return switch (err) {
                error.Stale => stale,
                error.Forbidden => forbidden,
                error.NotFound => Thread.no_such,
                error.InvalidFields => api_thread.fieldsError(.required_title),
                // taking their target captures the source's revision against it, as a retarget does
                else => api_patches.branchesError(err) orelse return err,
            };
        }

        // runs `read.run` on the repo, brought up to date first in local mode
        fn withRepo(io: std.Io, arena: *std.heap.ArenaAllocator, opened: *api_thread.Opened, read: anytype) !bool {
            const source = opened.source;
            const gpa = arena.child_allocator;
            switch (source.repo_kind) {
                inline else => |repo_kind| {
                    var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, gpa, source.localInitOpts());
                    defer any_repo.deinit(io, gpa);
                    switch (any_repo) {
                        inline else => |*repo| {
                            if (opened.session.local != null) try Thread.catchUp(repo_kind, repo.self_repo_opts, io, gpa, source, repo);
                            return read.run(repo_kind, repo.self_repo_opts, arena, repo, io, opened);
                        },
                    }
                },
            }
        }

        const unauthenticated: api.Error = .{ .code = .unauthenticated, .message = "Log in to resolve conflicts." };
        const forbidden: api.Error = .{ .code = .forbidden, .message = "Only the repository's writers can resolve conflicts." };
        const stale: api.Error = .{
            .code = .conflict,
            .message = "This conflict changed since you loaded it.",
            .field_errors = &.{.{ .field = "revision", .message = "Someone resolved or changed this conflict meanwhile. Load it again, then choose again." }},
        };

        // who resolves: someone with the write role in the repo who may write
        // in the kind's tab, as the TUI's resolve form asks
        fn authorize(io: std.Io, arena: *std.heap.ArenaAllocator, host: api_repo.Host, viewer: ?[evt.event_id_size]u8, opened: *api_thread.Opened) !api_thread.Authorized {
            switch (host) {
                .local => |source| return .{ .actor = .{ .author = try ui.localAuthor(source, io, arena.child_allocator, arena), .role = .owner } },
                .server => |server| {
                    const user_id = viewer orelse return .{ .refused = unauthenticated };
                    const moment = opened.session.haxy_moment orelse return .{ .refused = unauthenticated };
                    return switch (try ui.authorizeUser(io, moment, arena, server.users_dir, user_id, opened.resolved.identity, .write, Thread.event_kind)) {
                        .actor => |actor| .{ .actor = actor },
                        .login_required => .{ .refused = unauthenticated },
                        .repo_not_found => .{ .refused = api_repo.not_found_repo },
                        .forbidden => .{ .refused = forbidden },
                    };
                },
            }
        }
    };
}

// how many threads a read loads into the window its view shows, and into each other one
const Sizes = struct { shown: usize, others: usize };

// what differs between the kinds: their tab, their event, and how their
// routes read and answer them
fn Of(comptime kind: Kind) type {
    return switch (kind) {
        .issues => struct {
            const Data = ui.Repo.Issues;
            const Event = evt.Issue;
            const Status = evt.Issue.Status;
            const event_kind: evt.EventKind = .issue;
            const section: ui.Repo.Section = .issues;
            const noun = "issue";
            const off = api_issues.issues_off;
            const no_such = api_issues.no_such_issue;
            const readDetail = api_issues.readDetail;

            fn init(comptime repo_kind: rp.RepoKind, comptime repo_opts: rp.RepoOpts(repo_kind), arena: *std.heap.ArenaAllocator, repo: *rp.Repo(repo_kind, repo_opts), io: std.Io, opened: *api_thread.Opened, selected: []const u8, view: ui.RoutablePage.IssuesView, sizes: Sizes) !Data {
                const viewer = ui.Repo.tabViewer(opened.handle, opened.resolved.repo, .issue);
                return Data.init(repo_kind, repo_opts, arena, repo, io, opened.session.haxy_moment, opened.resolved.identity, "", selected, "", 0, "", view, viewer, .{ .shown = sizes.shown, .others = sizes.others });
            }

            fn summary(aa: std.mem.Allocator, entry: *const Data.Entry) !api_thread.Summary(Status) {
                return api_thread.summary(aa, entry, "");
            }

            fn catchUp(comptime repo_kind: rp.RepoKind, comptime repo_opts: rp.RepoOpts(repo_kind), io: std.Io, gpa: std.mem.Allocator, _: ui.RepoSource, repo: *rp.Repo(repo_kind, repo_opts)) !void {
                try evt.consume(.local, .repo, repo_kind, repo_opts, io, gpa, repo, evt.events_ref, &.{});
            }
        },
        .patches => struct {
            const Data = ui.Repo.Patches;
            const Event = evt.Patch;
            const Status = evt.Patch.StatusKind;
            const event_kind: evt.EventKind = .patch;
            const section: ui.Repo.Section = .patches;
            const noun = "patch";
            const off = api_patches.patches_off;
            const no_such = api_patches.no_such_patch;
            const readDetail = api_patches.readDetail;
            const catchUp = api_patches.catchUp;

            fn init(comptime repo_kind: rp.RepoKind, comptime repo_opts: rp.RepoOpts(repo_kind), arena: *std.heap.ArenaAllocator, repo: *rp.Repo(repo_kind, repo_opts), io: std.Io, opened: *api_thread.Opened, selected: []const u8, view: ui.RoutablePage.PatchesView, sizes: Sizes) !Data {
                const viewer = ui.Repo.tabViewer(opened.handle, opened.resolved.repo, .patch);
                return Data.init(repo_kind, repo_opts, arena, repo, io, opened.session.haxy_moment, &opened.session, opened.resolved.repo_id, opened.resolved.identity, "", "", selected, "", 0, "", view, viewer, .{ .shown = sizes.shown, .others = sizes.others, .drafts = false });
            }

            fn summary(aa: std.mem.Allocator, entry: *const Data.Entry) !api_thread.Summary(Status) {
                return api_patches.summary(aa, entry, "");
            }
        },
    };
}

fn eventHost(host: api_repo.Host) evt.Host {
    return switch (host) {
        .local => .local,
        .server => |server| .{ .server = .{ .users_dir = server.users_dir, .admin_repo_path = server.admin_repo_path } },
    };
}

fn respondValue(request: *std.http.Server.Request, arena: *std.heap.ArenaAllocator, value: anytype) !void {
    var body: std.Io.Writer.Allocating = .init(arena.allocator());
    try std.json.Stringify.value(value, .{}, &body.writer);
    return api.respondJson(request, body.written(), .{});
}

// the request's body, or null once its refusal is answered
fn readBody(request: *std.http.Server.Request, allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator) !?[]const u8 {
    const content_type = if (request.head.content_type) |value| try arena.allocator().dupe(u8, value) else null;
    var buffer: [256]u8 = undefined;
    const reader = try request.readerExpectContinue(&buffer);
    const body = reader.allocRemaining(arena.allocator(), .limited(max_body_size)) catch |err| switch (err) {
        error.StreamTooLong => {
            try api.respondError(request, allocator, .{ .code = .validation, .message = "The request is too large." }, .{ .keep_alive = false });
            return null;
        },
        else => |e| return e,
    };
    if (!isJson(content_type)) {
        try api.respondError(request, allocator, .{ .code = .validation, .message = "Send the resolution as JSON." }, .{});
        return null;
    }
    return body;
}

fn isJson(content_type: ?[]const u8) bool {
    return @import("./session.zig").isJson(content_type orelse return false);
}
