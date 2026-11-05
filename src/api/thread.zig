//! what the JSON API's thread routes share: issues today, discussions and
//! patches in later slices. a kind's routes are a list, its labels and one
//! thread; they read the repo as the viewer through the TUI's own
//! `ui.Repo.resolve`, and a thread is written from the entries the TUI's
//! thread tabs list (`ui.widget.thread`), so lists, counts, windows and search
//! filters are the TUI's.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const api_md = @import("./markdown.zig");
const api_repo = @import("./repo.zig");
const evt = @import("../event.zig");
const md = @import("../markdown.zig");
const srch_thrd = @import("../search_thread.zig");
const thread_write = @import("../thread_write.zig");
const ui = @import("../ui.zig");

pub const Route = struct {
    target: api_repo.Route.Target,
    resource: Resource,

    pub const Resource = union(enum) {
        // one status's window, `?status=&search=&cursor=&page_size=`
        list,
        // every label the kind's threads use, `?search=&cursor=&page_size=`
        labels,
        // one thread by its hex event id, still encoded
        thread: []const u8,
        // one thread's status, `<id>/status`, its id still encoded
        status: []const u8,
    };
};

/// the route of thread kind `segment` ("issues") that `path` names, or null.
/// a server names the repo by owner and name; a local host serves its own
/// repo under /api/v1/repo.
pub fn route(path: []const u8, comptime segment: []const u8) ?Route {
    const local_prefix = "/api/v1/repo/" ++ segment;
    if (std.mem.startsWith(u8, path, local_prefix))
        return .{ .target = .local, .resource = resourceOf(path[local_prefix.len..]) orelse return null };

    const prefix = "/api/v1/repos/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const owner_end = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const owner = rest[0..owner_end];
    const after_owner = rest[owner_end + 1 ..];
    const name_end = std.mem.indexOfScalar(u8, after_owner, '/') orelse return null;
    const name = after_owner[0..name_end];
    if (owner.len == 0 or name.len == 0) return null;
    const kind_path = after_owner[name_end..];
    if (!std.mem.startsWith(u8, kind_path, "/" ++ segment)) return null;
    return .{
        .target = .{ .server = .{ .owner = owner, .name = name } },
        .resource = resourceOf(kind_path[1 + segment.len ..]) orelse return null,
    };
}

// what follows a kind's segment: nothing, "/labels", "/<id>" or "/<id>/status"
fn resourceOf(tail: []const u8) ?Route.Resource {
    if (tail.len == 0) return .list;
    if (tail[0] != '/') return null;
    const rest = tail[1..];
    const status_suffix = "/status";
    if (std.mem.endsWith(u8, rest, status_suffix)) {
        const id = rest[0 .. rest.len - status_suffix.len];
        if (id.len == 0 or std.mem.indexOfScalar(u8, id, '/') != null or std.mem.eql(u8, id, "labels")) return null;
        return .{ .status = id };
    }
    if (rest.len == 0 or std.mem.indexOfScalar(u8, rest, '/') != null) return null;
    if (std.mem.eql(u8, rest, "labels")) return .labels;
    return .{ .thread = rest };
}

/// a repo the viewer may read, opened for a thread route
pub const Opened = struct {
    session: ui.Session,
    resolved: ui.Repo.Resolved,
    handle: ui.RepoHandle,
    source: ui.RepoSource,
};

/// resolves the repo `target` names for `viewer`, as page loads do, or answers
/// with the error envelope and returns null: a repo the viewer can't read is
/// not found exactly like a missing one, and each host answers the other's
/// routes with `unsupported`. `admin_repo` must outlive the session.
pub fn openRepo(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    host: api_repo.Host,
    // the logged-in viewer, or null when anonymous (always in local mode)
    viewer: ?[evt.event_id_size]u8,
    target: api_repo.Route.Target,
    admin_repo: *?rp.Repo(.xit, evt.admin_repo_opts),
) !?Opened {
    const aa = arena.allocator();
    var session: ui.Session, const repo_identity: ui.RoutablePage.RepoIdentity = switch (host) {
        .local => |source| blk: {
            if (target != .local) {
                try api.respondError(request, allocator, .{ .code = .unsupported, .message = "Local mode serves only the repository it opened." }, .{});
                return null;
            }
            break :blk .{
                .{ .data = .{ .host_kind = .local }, .arena = arena, .page_arena = arena, .local = source },
                .{ .identity = "", .owner = "", .name = "" },
            };
        },
        .server => |server| blk: {
            const names = switch (target) {
                .server => |names| names,
                .local => {
                    try api.respondError(request, allocator, .{ .code = .unsupported, .message = "A server hosts many repositories; name one by its owner and name." }, .{});
                    return null;
                },
            };
            admin_repo.* = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
            // the session drops a viewer whose account is gone, as page loads do
            var session = try ui.Session.init(arena, &admin_repo.*.?, .{ .user_id = if (viewer) |*id| try aa.dupe(u8, id) else null });
            session.users_dir = server.users_dir;
            const owner = try decodeSegment(aa, names.owner);
            const name = try decodeSegment(aa, names.name);
            break :blk .{ session, .{ .identity = try std.fmt.allocPrint(aa, "{s}:{s}", .{ owner, name }), .owner = owner, .name = name } };
        },
    };
    session.io = io;

    const resolved = (try ui.Repo.resolve(arena, &session, repo_identity)) orelse {
        try api.respondError(request, allocator, api_repo.not_found_repo, .{});
        return null;
    };
    return .{
        .session = session,
        .resolved = resolved,
        .handle = try resolved.handle(arena, &session),
        // a server always resolves a repo's source; only wasm has none
        .source = resolved.source orelse return error.NoRepoSource,
    };
}

// a path segment, percent-decoded. a malformed escape stays as written, which
// matches no repo.
fn decodeSegment(arena: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    return std.Uri.percentDecodeInPlace(try arena.dupe(u8, encoded));
}

/// a thread listing's count: exact, unless a search stopped counting at its
/// cap (the TUI's "(1000+)")
pub fn count(window: anytype) api.Count {
    return if (window.more) .{ .at_least = window.count } else .{ .exact = window.count };
}

/// a label or assignee, with the search listing the threads that carry it:
/// the current search with its own filter of that kind replaced, as the
/// TUI's label and assignee links build it
pub const Link = struct {
    name: []const u8,
    search: []const u8,
};

/// the space-separated `labels` as links extending `search`
pub fn labelLinks(aa: std.mem.Allocator, labels: []const u8, search: []const u8) ![]const Link {
    var links: std.ArrayList(Link) = .empty;
    var iter = std.mem.tokenizeScalar(u8, labels, ' ');
    while (iter.next()) |label| try links.append(aa, .{
        .name = label,
        .search = try srch_thrd.withFilter(aa, search, srch_thrd.label_prefix, label),
    });
    return links.items;
}

/// an assignee: by account name when one holds the email, otherwise by the
/// email alone (which then is all there is to show)
pub const Assignee = struct {
    name: ?[]const u8,
    email: ?[]const u8,
    search: []const u8,
};

pub fn assigneeLinks(aa: std.mem.Allocator, assignees: []const ui.Assignee, search: []const u8) ![]const Assignee {
    const links = try aa.alloc(Assignee, assignees.len);
    for (links, assignees) |*link, assignee| link.* = .{
        .name = assignee.name,
        .email = if (assignee.name == null) assignee.email else null,
        .search = try srch_thrd.withFilter(aa, search, srch_thrd.assignee_prefix, assignee.display()),
    };
    return links;
}

/// a search as haxy's parser splits it
pub const Filters = struct {
    labels: []const []const u8,
    assignees: []const []const u8,
    // the remaining words, joined by single spaces
    words: []const u8,
    // an assignee filter names no account, so the lists are empty
    assignee_not_found: bool,

    pub fn init(aa: std.mem.Allocator, search: []const u8, assignee_not_found: bool) !Filters {
        const filters = try srch_thrd.parseFilters(aa, search);
        return .{ .labels = filters.labels, .assignees = filters.assignees, .words = filters.words, .assignee_not_found = assignee_not_found };
    }
};

/// who opened a thread: an account, an email no account holds, or nobody known
pub const Author = struct {
    author: ui.Author,

    pub fn jsonStringify(self: Author, json: *std.json.Stringify) std.Io.Writer.Error!void {
        try json.beginObject();
        try json.objectField("kind");
        switch (self.author) {
            .user_name => |name| {
                try json.write("user");
                try json.objectField("name");
                try json.write(name);
            },
            .email => |email| {
                try json.write("email");
                try json.objectField("email");
                try json.write(email);
            },
            .unknown => try json.write("unknown"),
        }
        try json.endObject();
    }
};

/// a listed thread. `entry` is a thread tab's entry (`ui.Repo.Issues.Entry`);
/// its label and assignee links extend `search`.
pub fn Summary(comptime Status: type) type {
    return struct {
        id: []const u8,
        title: []const u8,
        status: Status,
        labels: []const Link,
        author: Author,
        assignees: []const Assignee,
        created_at: api.Instant,
        comment_count: usize,
        // concurrent edits left a field conflict to resolve
        conflicted: bool,
    };
}

pub fn summary(aa: std.mem.Allocator, entry: anytype, search: []const u8) !Summary(@TypeOf(entry.record.event.status)) {
    return .{
        .id = entry.id,
        .title = entry.record.event.title,
        .status = entry.record.event.status,
        .labels = try labelLinks(aa, entry.record.event.labels, search),
        .author = .{ .author = entry.author },
        .assignees = try assigneeLinks(aa, entry.assignees, search),
        .created_at = .{ .seconds = entry.record.created_timestamp },
        .comment_count = entry.comments.count,
        .conflicted = entry.conflicted,
    };
}

/// a thread's page: its summary and its whole description, parsed by haxy's
/// markdown reader as the TUI renders it, with what an edit starts from (the
/// description as written, and the revision the edit is made against) and
/// what the viewer may do to it
pub fn Detail(comptime Status: type) type {
    return struct {
        summary: Summary(Status),
        description: []const md.Block,
        description_text: []const u8,
        // what an edit replaces, as `contentRevision` digests it; written as
        // an opaque string
        revision: evt.Issue.Revision,
        actions: ThreadActions,

        pub fn jsonStringify(self: @This(), json: *std.json.Stringify) std.Io.Writer.Error!void {
            try json.beginObject();
            inline for (@typeInfo(Summary(Status)).@"struct".field_names) |name| {
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
}

pub fn detail(aa: std.mem.Allocator, entry: anytype, comptime kind: evt.EventKind, viewer: ViewerRights) !Detail(@TypeOf(entry.record.event.status)) {
    return .{
        // a thread's own page extends no list's search
        .summary = try summary(aa, entry, ""),
        .description = (try md.parseText(aa, entry.record.event.description)).blocks,
        .description_text = entry.record.event.description,
        .revision = @TypeOf(entry.record.event).contentRevision(entry.record.event),
        .actions = threadActions(kind, .{ .may_write = entry.can_modify, .signed_in = viewer.signed_in }),
    };
}

// --- writes ------------------------------------------------------------------

/// whether the viewer may take an action, as the conventions' "Capabilities
/// and action availability" write it: `{"available": true}`, or false with
/// the reason. the backend checks again when the action runs.
pub const Availability = union(enum) {
    available,
    unavailable: struct { code: Reason, message: []const u8 },

    pub const Reason = enum { unauthenticated, forbidden, unsupported, disabled, conflict };

    pub fn jsonStringify(self: Availability, json: *std.json.Stringify) std.Io.Writer.Error!void {
        try json.beginObject();
        try json.objectField("available");
        switch (self) {
            .available => try json.write(true),
            .unavailable => |reason| {
                try json.write(false);
                try json.objectField("reason");
                try json.write(.{ .code = reason.code, .message = reason.message });
            },
        }
        try json.endObject();
    }
};

/// what a page shows its viewer may do, as the TUI decides it: `may_write`
/// is the TUI's (the tab viewer for a list, an entry's `can_modify` for a
/// thread); `signed_in` says whether anyone is (always, in local mode)
pub const Rights = struct { may_write: bool, signed_in: bool };

/// who views a thread page: whether anyone is signed in
pub const ViewerRights = struct { signed_in: bool };

pub const ListActions = struct { create: Availability };

pub const ThreadActions = struct {
    edit: Availability,
    set_status: Availability,
    remove: Availability,
};

// a kind's singular noun, as messages name it
fn noun(kind: evt.EventKind) []const u8 {
    return switch (kind) {
        .issue => "issue",
        .discuss => "discussion",
        .patch => "patch",
        else => unreachable,
    };
}

fn nounPlural(kind: evt.EventKind) []const u8 {
    return switch (kind) {
        .issue => "issues",
        .discuss => "discussions",
        .patch => "patches",
        else => unreachable,
    };
}

/// what the viewer may do to a kind's list: open a thread, when they may
/// write in its tab
pub fn listActions(comptime kind: evt.EventKind, rights: Rights) ListActions {
    if (rights.may_write) return .{ .create = .available };
    if (!rights.signed_in) return .{ .create = .{ .unavailable = .{ .code = .unauthenticated, .message = "Log in to open an " ++ comptime noun(kind) ++ "." } } };
    return .{ .create = .{ .unavailable = .{ .code = .forbidden, .message = "Your role in this repository doesn't allow opening " ++ comptime nounPlural(kind) ++ "." } } };
}

/// what the viewer may do to one thread: change it, when they wrote it or
/// may write in the repository
pub fn threadActions(comptime kind: evt.EventKind, rights: Rights) ThreadActions {
    const availability: Availability = if (rights.may_write)
        .available
    else if (!rights.signed_in)
        .{ .unavailable = .{ .code = .unauthenticated, .message = "Log in to change this " ++ comptime noun(kind) ++ "." } }
    else
        .{ .unavailable = .{ .code = .forbidden, .message = "Only the " ++ comptime noun(kind) ++ "'s author and the repository's writers can change it." } };
    return .{ .edit = availability, .set_status = availability, .remove = availability };
}

/// a client's id for a new thread: "" (haxy picks one), else 32 lowercase
/// hex digits, or null when it is neither
pub fn parseNewId(text: []const u8) ??[evt.event_id_size]u8 {
    if (text.len == 0) return @as(?[evt.event_id_size]u8, null);
    if (text.len != evt.event_id_size * 2) return null;
    for (text) |char| if (!std.ascii.isDigit(char) and !(char >= 'a' and char <= 'f')) return null;
    var id: [evt.event_id_size]u8 = undefined;
    _ = std.fmt.hexToBytes(&id, text) catch return null;
    return id;
}

/// a revision haxy gave out (32 lowercase hex digits, see
/// `evt.Issue.contentRevision`), or null
pub fn parseRevision(text: []const u8) ?evt.Issue.Revision {
    const id = (parseNewId(text) orelse return null) orelse return null;
    return id;
}

const check_fields = "Check the highlighted fields.";

/// the shared field rules' refusal (thread_write.checkFields), beside the field
pub fn fieldsError(failure: thread_write.FieldFailure) api.Error {
    return switch (failure) {
        .required_title => .{ .code = .validation, .message = check_fields, .field_errors = &.{.{ .field = "title", .message = "Enter a title." }} },
        .invalid_labels => .{ .code = .validation, .message = check_fields, .field_errors = &.{.{ .field = "labels", .message = std.fmt.comptimePrint("Separate labels with spaces; each can be up to {d} characters.", .{evt.Issue.label_max_len}) }} },
    };
}
