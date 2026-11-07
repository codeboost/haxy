//! a commit's diff in the JSON API, against its first parent (nothing for a
//! root commit), a window at a time, optionally narrowed to one file's path.
//! every window is the TUI's diff pane's (`ui.Repo.Diff.renderAt`): which
//! entries it holds and how many, the path filter, and which changes are
//! placeholders (binary files, changes past xit's limits) are decided there,
//! so nothing here decides what a diff holds.
//!
//! the route hangs off a commit's, `…/commits/{id}/diff` (see
//! `api/commits.zig`, which resolves the repository and dispatches here). a
//! patch revision's diff, `…/revisions/{id}/diff`, is read the same way
//! (`api/patches.zig` dispatches it).

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const obj = xit.object;
const api = @import("../api.zig");
const api_path = @import("./path.zig");
const evt = @import("../event.zig");
const query_params = @import("./query.zig");
const ui = @import("../ui.zig");

const Diff = ui.Repo.Diff;

// a window defaults to the diff pane's own; clients may ask for up to this many
const max_page_size = 100;

/// one entry of a window
const Item = struct {
    // percent-encoded bytes, see api/path.zig
    path: []const u8,
    // the last segment, for display
    name: []const u8,
    status: Diff.Status,
    kind: Diff.Kind,
    lines: []const Line,
};

const Line = struct {
    kind: enum { context, added, removed },
    old_number: ?usize,
    new_number: ?usize,
    text: []const u8,
};

/// writes the window of commit `encoded_oid`'s diff (a route segment) that
/// the `cursor`, `page_size` and `path` parameters name. the commit, its
/// parent and every file come from one snapshot of the repo.
pub fn writeDiff(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    encoded_oid: []const u8,
    query: []const u8,
    writer: *std.Io.Writer,
) !?api.Error {
    const aa = arena.allocator();
    const hex_len = comptime xit.hash.hexLen(repo_opts.hash);
    if (!isOid(encoded_oid, hex_len)) return no_such_commit;
    const window_query = switch (try WindowQuery.parse(aa, query)) {
        .ok => |window_query| window_query,
        .invalid => |err| return err,
    };

    var moment = try repo.core.latestMoment();
    const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
    // an object id names a commit only when it is one; a tag isn't read through
    var object = obj.Object(repo_kind, repo_opts).init(state, io, gpa, encoded_oid[0..hex_len]) catch |err| switch (err) {
        error.ObjectNotFound => return no_such_commit,
        else => |e| return e,
    };
    defer object.deinit();
    if (object.content != .commit) return no_such_commit;
    // what the commits tab diffs a commit against: its first parent
    const parent: ?[hex_len]u8 = if (object.content.commit.metadata.parent_oids) |parents|
        (if (parents.len == 0) null else parents[0])
    else
        null;

    const window = try Diff.renderAt(repo_kind, repo_opts, io, gpa, aa, state, if (parent) |*p| p else null, encoded_oid[0..hex_len].*, window_query.options());

    try std.json.Stringify.value(.{
        .commit = encoded_oid[0..hex_len],
        .parent = if (parent) |*p| @as(?[]const u8, p) else null,
        .path = try window_query.echoedPath(aa),
        .items = try listItems(aa, window),
        .truncated = window.truncated,
        .page = try windowPage(aa, window),
    }, .{}, writer);
    return null;
}

/// writes the window of patch revision `encoded_id`'s diff (a route segment)
/// that the `cursor`, `page_size` and `path` parameters name: the tree of the
/// commit the revision was based on against its source commit's
/// (`Diff.renderRevisionAt`, as the TUI's patch diff), so what the target
/// already had is left out. the revision and every file come from one
/// snapshot of the repo.
pub fn writeRevisionDiff(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    encoded_id: []const u8,
    query: []const u8,
    writer: *std.Io.Writer,
) !?api.Error {
    var moment = try repo.core.latestMoment();
    return writeRevisionDiffAt(repo_kind, repo_opts, arena, repo, io, gpa, &moment, encoded_id, query, writer);
}

/// `writeRevisionDiff` read in the snapshot `moment`
pub fn writeRevisionDiffAt(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    moment: anytype,
    encoded_id: []const u8,
    query: []const u8,
    writer: *std.Io.Writer,
) !?api.Error {
    const aa = arena.allocator();
    // an event id is 32 lowercase hex digits, as haxy writes them
    if (!isOid(encoded_id, evt.event_id_size * 2)) return no_such_revision;
    const window_query = switch (try WindowQuery.parse(aa, query)) {
        .ok => |window_query| window_query,
        .invalid => |err| return err,
    };
    const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = moment } };
    const revision = (try Diff.renderRevisionAt(repo_kind, repo_opts, arena, repo, io, gpa, state, encoded_id, window_query.options())) orelse return no_such_revision;
    const base = revision.record.event.base_oid;
    try std.json.Stringify.value(.{
        .revision = encoded_id,
        // a revision into a branch that had no commits has no base
        .base = if (std.mem.allEqual(u8, base, '0')) null else base,
        .head = revision.record.event.source_oid,
        .path = try window_query.echoedPath(aa),
        .items = try listItems(aa, revision.window),
        .truncated = revision.window.truncated,
        .page = try windowPage(aa, revision.window),
    }, .{}, writer);
    return null;
}

/// writes the window of the diff from `base` (null for none) to `head` that
/// the `cursor`, `page_size` and `path` parameters name, as the TUI's fork diff
/// tab renders a fork's whole diff
pub fn writeRangeDiff(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    base: ?*const [xit.hash.hexLen(repo_opts.hash)]u8,
    head: [xit.hash.hexLen(repo_opts.hash)]u8,
    query: []const u8,
    writer: *std.Io.Writer,
) !?api.Error {
    const aa = arena.allocator();
    const window_query = switch (try WindowQuery.parse(aa, query)) {
        .ok => |window_query| window_query,
        .invalid => |err| return err,
    };
    var moment = try repo.core.latestMoment();
    const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
    const window = try Diff.renderAt(repo_kind, repo_opts, io, gpa, aa, state, base, head, window_query.options());
    try std.json.Stringify.value(.{
        .base = if (base) |oid| @as(?[]const u8, oid) else null,
        .head = &head,
        .path = try window_query.echoedPath(aa),
        .items = try listItems(aa, window),
        .truncated = window.truncated,
        .page = try windowPage(aa, window),
    }, .{}, writer);
    return null;
}

// the window a diff request names: its page and its path filter
const WindowQuery = struct {
    page: query_params.Page,
    // decoded, "" for every file
    path: []const u8,

    fn parse(aa: std.mem.Allocator, query: []const u8) !union(enum) { ok: WindowQuery, invalid: api.Error } {
        const window_page = switch (try query_params.Page.parse(aa, query, .{ .default = Diff.page_size, .max = max_page_size })) {
            .ok => |window_page| window_page,
            .invalid => |err| return .{ .invalid = err },
        };
        // a path is sent back as a response encoded it, and decoded here once,
        // as the files view reads its own
        const path = std.mem.trim(u8, (query_params.param(aa, query, "path") catch |err| switch (err) {
            error.InvalidPercentEncoding => return .{ .invalid = .{
                .code = .validation,
                .message = "Check the request's parameters.",
                .field_errors = &.{.{ .field = "path", .message = "The path isn't validly encoded." }},
            } },
            else => |e| return e,
        }) orelse "", "/");
        return .{ .ok = .{ .page = window_page, .path = path } };
    }

    fn options(self: WindowQuery) Diff.Options {
        return .{ .start = self.page.start, .path = self.path, .limit = self.page.limit };
    }

    // the filter as the answer echoes it, null for every file
    fn echoedPath(self: WindowQuery, aa: std.mem.Allocator) !?[]const u8 {
        return if (self.path.len == 0) null else try api_path.encode(aa, self.path);
    }
};

fn listItems(aa: std.mem.Allocator, window: Diff.Window) ![]const Item {
    const listed = try aa.alloc(Item, window.hunks.len);
    // a hunk that continues the file before it carries no path
    var current: []const u8 = "";
    for (window.hunks, listed) |hunk, *item| {
        if (hunk.path) |hunk_path| current = hunk_path;
        const named: api_path.Named = try .init(aa, current);
        const lines = try aa.alloc(Line, hunk.lines.len);
        for (hunk.lines, lines) |line, *out| out.* = .{
            .kind = switch (line.prefix) {
                '+' => .added,
                '-' => .removed,
                else => .context,
            },
            .old_number = line.old,
            .new_number = line.new,
            // xit diffs only valid utf-8, but text is bytes, like paths
            .text = try api_path.display(aa, line.text),
        };
        item.* = .{ .path = named.path, .name = named.name, .status = hunk.status, .kind = hunk.kind, .lines = lines };
    }
    return listed;
}

const WindowPage = struct { has_more: bool, next_cursor: ?[]const u8, count: api.Count };

fn windowPage(aa: std.mem.Allocator, window: Diff.Window) !WindowPage {
    return .{
        .has_more = window.has_more,
        .next_cursor = try query_params.Page.nextCursor(aa, if (window.has_more) window.start + window.hunks.len else null),
        // the diff pane doesn't count a diff's entries
        .count = .unknown,
    };
}

// a full object id in lowercase hex, as haxy writes them
fn isOid(text: []const u8, hex_len: usize) bool {
    if (text.len != hex_len) return false;
    for (text) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    return true;
}

const no_such_commit: api.Error = .{ .code = .not_found, .message = "This repository has no commit with this id." };
const no_such_revision: api.Error = .{ .code = .not_found, .message = "This repository has no patch revision with this id." };
