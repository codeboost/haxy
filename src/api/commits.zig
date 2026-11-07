//! commit history in the JSON API: a ref's history, a page at a time, its
//! indexed commit search, and one commit with its whole message. every
//! answer is read by the TUI's commits tab (`ui.Repo.Commits`): its log
//! window (first-parent, keyed by commit), its rows, its message limits, its
//! statistics and its search index, so nothing here decides what a log
//! holds.
//!
//! a server names repos by owner and name; a local host serves only the repo
//! it opened, under /api/v1/repo/commits.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const obj = xit.object;
const api = @import("../api.zig");
const api_diff = @import("./diff.zig");
const api_path = @import("./path.zig");
const api_refs = @import("./refs.zig");
const api_repo = @import("./repo.zig");
const api_thread = @import("./thread.zig");
const evt = @import("../event.zig");
const query_params = @import("./query.zig");
const ui = @import("../ui.zig");

const Commits = ui.Repo.Commits;

// a page defaults to the commits tab's own; clients may ask for up to this many
const max_page_size = 100;

pub const Route = struct {
    target: api_repo.Route.Target,
    resource: Resource,

    pub const Resource = union(enum) {
        // a ref's history, `?ref=&search=&cursor=&page_size=`
        list,
        // one commit by its object id, still encoded
        commit: []const u8,
        // a commit's diff, `?path=&cursor=&page_size=` (api/diff.zig)
        diff: []const u8,
    };
};

/// the commit route `path` names, or null when it names none
pub fn route(path: []const u8) ?Route {
    const local_prefix = "/api/v1/repo/commits";
    if (std.mem.startsWith(u8, path, local_prefix))
        return .{ .target = .local, .resource = resourceOf(path[local_prefix.len..]) orelse return null };

    const prefix = "/api/v1/repos/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    var segments = std.mem.splitScalar(u8, path[prefix.len..], '/');
    const owner = segments.next() orelse return null;
    const name = segments.next() orelse return null;
    if (owner.len == 0 or name.len == 0) return null;
    if (!std.mem.eql(u8, segments.next() orelse return null, "commits")) return null;
    const rest = segments.rest();
    const tail = if (rest.len == 0 and path[path.len - 1] != '/') "" else path[path.len - rest.len - 1 ..];
    return .{
        .target = .{ .server = .{ .owner = owner, .name = name } },
        .resource = resourceOf(tail) orelse return null,
    };
}

// what follows "commits": nothing, "/<oid>" or "/<oid>/diff"
fn resourceOf(tail: []const u8) ?Route.Resource {
    if (tail.len == 0) return .list;
    if (tail[0] != '/') return null;
    var segment = tail[1..];
    const diff_suffix = "/diff";
    const diff = std.mem.endsWith(u8, segment, diff_suffix);
    if (diff) segment = segment[0 .. segment.len - diff_suffix.len];
    if (segment.len == 0 or std.mem.indexOfScalar(u8, segment, '/') != null) return null;
    return if (diff) .{ .diff = segment } else .{ .commit = segment };
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
    if (method != .GET and method != .HEAD)
        return api.respondError(request, allocator, .{ .code = .unsupported, .message = "This route only supports GET and HEAD." }, .{ .allow = "GET, HEAD" });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // the server's admin repo must outlive the session, whose moment reads from it
    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    const opened = (try api_thread.openRepo(io, request, allocator, &arena, host, viewer, matched.target, &admin_repo_maybe)) orelse return;
    const context: Context = .{
        .admin_moment = opened.session.haxy_moment,
        .handle = opened.handle,
        .host_kind = opened.session.data.host_kind,
    };

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    const source = opened.source;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| {
                    const failure = switch (matched.resource) {
                        .list => try writeList(repo_kind, repo.self_repo_opts, &arena, repo, io, allocator, context, query, &body.writer),
                        .commit => |oid| try writeCommit(repo_kind, repo.self_repo_opts, &arena, repo, io, allocator, context, oid, &body.writer),
                        .diff => |oid| try api_diff.writeDiff(repo_kind, repo.self_repo_opts, &arena, repo, io, allocator, oid, query, &body.writer),
                    };
                    if (failure) |err| return api.respondError(request, allocator, err, .{});
                },
            }
        },
    }
    return api.respondJson(request, body.written(), .{});
}

/// what a read needs of the repo besides the repo itself
pub const Context = struct {
    // the admin db's moment, to resolve authors' emails to account names
    // (null in local mode, which has no accounts)
    admin_moment: ?evt.AdminDB.HashMap(.read_only) = null,
    handle: ui.RepoHandle,
    host_kind: evt.HostKind,
    // where a branch's, tag's or commit's history stops (a fork's base), ""
    // for its root
    base_oid: []const u8 = "",
};

/// a commit as the history lists it
const Summary = struct {
    id: []const u8,
    // the first parent, which its diff is against; null for a root commit
    parent: ?[]const u8,
    // the message's first line, for display
    summary: []const u8,
    author: api_thread.Author,
    // null when the committer is the author
    committer: ?api_thread.Author,
    committed_at: api.Instant,
    merge: bool,
    // null where haxy computes none (a git repo): unavailable, not zero
    stats: ?xit.patch.CommitStats,
};

/// one commit with its whole message
const Detail = struct {
    summary: Summary,
    // whole, up to the commits tab's limit, for display
    message: []const u8,
    // the message is longer than the limit, and `message` its start
    message_truncated: bool,

    pub fn jsonStringify(self: Detail, json: *std.json.Stringify) std.Io.Writer.Error!void {
        try json.beginObject();
        inline for (@typeInfo(Summary).@"struct".field_names) |name| {
            try json.objectField(name);
            try json.write(@field(self.summary, name));
        }
        try json.objectField("message");
        try json.write(self.message);
        try json.objectField("message_truncated");
        try json.write(self.message_truncated);
        try json.endObject();
    }
};

fn summary(aa: std.mem.Allocator, commit: Commits.Commit) !Summary {
    return .{
        .id = commit.oid,
        .parent = if (std.mem.allEqual(u8, commit.parent_oid, '0')) null else commit.parent_oid,
        // messages are bytes, like paths
        .summary = try api_path.display(aa, Commits.firstLine(commit.message)),
        .author = .{ .author = try displayAuthor(aa, commit.author) },
        .committer = if (commit.committer == .unknown) null else .{ .author = try displayAuthor(aa, commit.committer) },
        .committed_at = .{ .seconds = std.math.cast(u64, commit.timestamp) orelse 0 },
        .merge = commit.merge,
        .stats = commit.stats,
    };
}

// an email from a commit is bytes; an account name is utf-8 already
fn displayAuthor(aa: std.mem.Allocator, author: ui.Author) !ui.Author {
    return switch (author) {
        .email => |email| .{ .email = try api_path.display(aa, email) },
        else => author,
    };
}

/// whether something is available, or why not (the shape of action
/// availability in the conventions)
const Availability = struct {
    available: bool,
    reason: ?struct { code: []const u8, message: []const u8 } = null,
};

/// where the list's search runs, or why it can't
const Search = struct {
    available: bool,
    // the ref to search: the listed one, or for a commit or patch revision
    // the default branch
    ref: ?[]const u8 = null,
    reason: ?struct { code: []const u8, message: []const u8 } = null,
};

const local_search: Search = .{ .available = false, .reason = .{ .code = "unsupported", .message = "Commit search needs a Haxy server; local mode doesn't index commits." } };
const unindexed_search: Search = .{ .available = false, .reason = .{ .code = "unsupported", .message = "Haxy has no commit index for this ref, so its history can't be searched." } };

/// writes a page of the history at the `ref` parameter's ref (the default
/// branch when absent), from the `cursor` parameter's commit, or of the
/// commits matching the `search` parameter
pub fn writeList(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    context: Context,
    query: []const u8,
    writer: *std.Io.Writer,
) !?api.Error {
    return writeListAt(repo_kind, repo_opts, arena, repo, io, gpa, context, try repo.core.latestMoment(), query, writer);
}

/// `writeList` read in one snapshot of the repo, `moment`: the ref, its
/// commits, their statistics and count, and the search index all come from
/// it, so a push landing meanwhile can't mix two states into one answer
pub fn writeListAt(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    context: Context,
    snapshot: Commits.Moment(repo_kind, repo_opts),
    query: []const u8,
    writer: *std.Io.Writer,
) !?api.Error {
    const aa = arena.allocator();
    const hex_len = ui.ResolvedRefOrOid(repo_kind, repo_opts).hex_len;
    const limit = switch (try query_params.pageSize(aa, query, .{ .default = Commits.page_size, .max = max_page_size })) {
        .ok => |limit| limit,
        .invalid => |err| return err,
    };
    const selection = switch (try api_refs.selectionParam(aa, query)) {
        .ok => |selection| selection,
        .invalid => |err| return err,
    };
    const text = (query_params.param(aa, query, "search") catch |err| switch (err) {
        error.InvalidPercentEncoding => return invalidField("search", "The search isn't validly encoded."),
        else => |e| return e,
    }) orelse "";
    const cursor = (query_params.param(aa, query, "cursor") catch |err| switch (err) {
        error.InvalidPercentEncoding => return invalid_cursor,
        else => |e| return e,
    }) orelse "";

    var moment = snapshot;
    const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };

    // a cursor names the commit its page starts at, as the commits tab's
    // pages do
    if (cursor.len != 0) {
        if (!isOid(cursor, hex_len)) return invalid_cursor;
        var start = obj.Object(repo_kind, repo_opts).init(state, io, gpa, cursor[0..hex_len]) catch |err| switch (err) {
            error.ObjectNotFound => return invalid_cursor,
            else => |e| return e,
        };
        defer start.deinit();
        if (start.content != .commit) return invalid_cursor;
    }

    // what the log walks: the commit the ref resolved to, once, so the page
    // and its `ref` agree even when a push moves the ref meanwhile; for a
    // patch revision, its commits back to its base, as the patch's commits
    // link lists them
    const ref: api_refs.Ref, const walk_kind: ui.RoutablePage.RefOrOid, const walk_value: []const u8, const base_oid: []const u8 = switch (selection) {
        .revision => |id| blk: {
            const record = (try api_refs.readPatchRevAt(repo_kind, repo_opts, arena, repo, io, gpa, &moment, id)) orelse return no_such_ref;
            const source_oid = record.event.source_oid;
            if (!isOid(source_oid, hex_len) or !isOid(record.event.base_oid, hex_len)) return no_such_ref;
            break :blk .{
                .{ .kind = .revision, .name = null, .id = try selection.id(aa), .commit = source_oid },
                .object,
                source_oid,
                record.event.base_oid,
            };
        },
        else => blk: {
            const resolved = (try api_refs.resolveAt(repo_kind, repo_opts, arena, repo, io, gpa, &moment, selection)) orelse
                return if (selection == .default) no_commits else no_such_ref;
            break :blk .{
                resolved.ref,
                switch (selection) {
                    .default, .branch => .branch,
                    .tag => .tag,
                    .commit => .object,
                    .revision => unreachable,
                },
                switch (selection) {
                    .default => "",
                    .branch, .tag => |name| try ui.urlEncodeRef(aa, name),
                    .commit => resolved.ref.commit,
                    .revision => unreachable,
                },
                context.base_oid,
            };
        },
    };

    // a revision's source commit may not be in the repository: a squash
    // merge of a fork keeps the revision but brings in only the squash
    // commit. its history is then unavailable, which the answer says rather
    // than listing nothing
    const history: Availability = if (try hasCommit(repo_kind, repo_opts, state, io, gpa, ref.commit[0..hex_len])) .{ .available = true } else .{
        .available = false,
        .reason = .{ .code = "unsupported", .message = "This revision's commits aren't in this repository: its fork was squash-merged, which brought in only the squashed commit." },
    };

    // search as the commits tab offers it: on a server, where the ref's tip
    // has an index, or for a commit or revision at the default branch
    const search: Search = if (context.host_kind == .local) local_search else scope: {
        const scope = (try Commits.searchScope(repo_kind, repo_opts, aa, repo, io, moment, context.handle, walk_kind, ref.commit[0..hex_len], base_oid)) orelse break :scope unindexed_search;
        break :scope switch (scope) {
            .own => .{ .available = true, .ref = ref.id },
            .default_branch => |branch| .{ .available = true, .ref = try (api_refs.Selection{ .branch = std.Uri.percentDecodeInPlace(try aa.dupe(u8, branch)) }).id(aa) },
        };
    };
    if (text.len != 0) {
        if (!search.available) return .{ .code = .unsupported, .message = search.reason.?.message };
        if (!std.mem.eql(u8, search.ref.?, ref.id)) return .{ .code = .unsupported, .message = "Search a branch or tag; a commit's history is searched on the default branch." };
    }

    const data = if (!history.available) try Commits.emptyResult(aa, context.handle, walk_kind, walk_value, base_oid) else Commits.initWindow(repo_kind, repo_opts, arena, repo, io, gpa, context.admin_moment, context.handle, null, "", false, base_oid, try encodeQuery(aa, text), cursor, limit, .{
        .ref_or_oid = walk_kind,
        .value = walk_value,
        .oid = ref.commit,
        .moment = moment,
    }) catch |err| switch (err) {
        error.NotFound => return no_such_ref,
        else => |e| return e,
    };

    const items = try aa.alloc(Summary, data.commits.len);
    for (data.commits, items) |commit, *item| item.* = try summary(aa, commit);
    const count: api.Count = if (text.len != 0) .unknown else if (data.commit_count) |n| .{ .exact = n } else .unknown;
    try std.json.Stringify.value(.{
        .ref = ref,
        .history = history,
        .search = search,
        .query = if (text.len == 0) null else try api_path.display(aa, text),
        .items = items,
        .page = .{
            .has_more = data.next_start != null,
            .next_cursor = data.next_start,
            .count = count,
        },
    }, .{}, writer);
    return null;
}

/// writes the commit `encoded_oid` (a route segment) names, with its whole
/// message up to the commits tab's limit
pub fn writeCommit(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    context: Context,
    encoded_oid: []const u8,
    writer: *std.Io.Writer,
) !?api.Error {
    const aa = arena.allocator();
    const hex_len = ui.ResolvedRefOrOid(repo_kind, repo_opts).hex_len;
    if (!isOid(encoded_oid, hex_len)) return no_such_commit;
    var moment = try repo.core.latestMoment();
    const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
    // an object id names a commit only when it is one; a tag isn't read through
    var object = obj.Object(repo_kind, repo_opts).init(state, io, gpa, encoded_oid[0..hex_len]) catch |err| switch (err) {
        error.ObjectNotFound => return no_such_commit,
        else => |e| return e,
    };
    defer object.deinit();
    if (object.content != .commit) return no_such_commit;

    const commit = try Commits.commitEntry(repo_kind, repo_opts, arena, &moment, context.admin_moment, &object, true);
    try std.json.Stringify.value(Detail{
        .summary = try summary(aa, commit),
        .message = try api_path.display(aa, commit.message),
        .message_truncated = commit.message_truncated,
    }, .{}, writer);
    return null;
}

// whether the repository holds commit `oid`
fn hasCommit(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    state: rp.Repo(repo_kind, repo_opts).State(.read_only),
    io: std.Io,
    gpa: std.mem.Allocator,
    oid: *const [ui.ResolvedRefOrOid(repo_kind, repo_opts).hex_len]u8,
) !bool {
    var object = obj.Object(repo_kind, repo_opts).init(state, io, gpa, oid) catch |err| switch (err) {
        error.ObjectNotFound => return false,
        else => |e| return e,
    };
    defer object.deinit();
    return object.content == .commit;
}

// a search as the commits route holds it, url-encoded
fn encodeQuery(aa: std.mem.Allocator, text: []const u8) ![]const u8 {
    return ui.urlEncodeRef(aa, text);
}

// a full object id in lowercase hex, as haxy writes them
fn isOid(text: []const u8, hex_len: usize) bool {
    if (text.len != hex_len) return false;
    for (text) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    return true;
}

const invalid_cursor: api.Error = .{
    .code = .validation,
    .message = "Check the paging parameters.",
    .field_errors = &.{.{ .field = "cursor", .message = "This cursor isn't one Haxy gave out; start from the first page." }},
};
const no_commits: api.Error = .{ .code = .not_found, .message = "This repository has no commits yet." };
const no_such_ref: api.Error = .{ .code = .not_found, .message = "This repository has no such branch, tag, commit or revision." };
const no_such_commit: api.Error = .{ .code = .not_found, .message = "This repository has no commit with this id." };

fn invalidField(comptime name: []const u8, comptime message: []const u8) api.Error {
    return .{
        .code = .validation,
        .message = "Check the request's parameters.",
        .field_errors = &.{.{ .field = name, .message = message }},
    };
}
