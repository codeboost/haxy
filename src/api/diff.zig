//! a commit's diff in the JSON API, against its first parent (nothing for a
//! root commit), a window at a time, optionally narrowed to one file's path.
//! every window is the TUI's diff pane's (`ui.Repo.Diff.renderAt`): which
//! entries it holds and how many, the path filter, and which changes are
//! placeholders (binary files, changes past xit's limits) are decided there,
//! so nothing here decides what a diff holds.
//!
//! the route hangs off a commit's, `…/commits/{id}/diff` (see
//! `api/commits.zig`, which resolves the repository and dispatches here).

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const obj = xit.object;
const api = @import("../api.zig");
const api_path = @import("./path.zig");
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
    const window_page = switch (try query_params.Page.parse(aa, query, .{ .default = Diff.page_size, .max = max_page_size })) {
        .ok => |window_page| window_page,
        .invalid => |err| return err,
    };
    // a path is sent back as a response encoded it, and decoded here once,
    // as the files view reads its own
    const path = std.mem.trim(u8, (query_params.param(aa, query, "path") catch |err| switch (err) {
        error.InvalidPercentEncoding => return .{
            .code = .validation,
            .message = "Check the request's parameters.",
            .field_errors = &.{.{ .field = "path", .message = "The path isn't validly encoded." }},
        },
        else => |e| return e,
    }) orelse "", "/");

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

    const window = try Diff.renderAt(repo_kind, repo_opts, io, gpa, aa, state, if (parent) |*p| p else null, encoded_oid[0..hex_len].*, .{
        .start = window_page.start,
        .path = path,
        .limit = window_page.limit,
    });

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

    try std.json.Stringify.value(.{
        .commit = encoded_oid[0..hex_len],
        .parent = if (parent) |*p| @as(?[]const u8, p) else null,
        .path = if (path.len == 0) null else try api_path.encode(aa, path),
        .items = listed,
        .truncated = window.truncated,
        .page = .{
            .has_more = window.has_more,
            .next_cursor = try query_params.Page.nextCursor(aa, if (window.has_more) window.start + window.hunks.len else null),
            // the diff pane doesn't count a diff's entries
            .count = @as(api.Count, .unknown),
        },
    }, .{}, writer);
    return null;
}

// a full object id in lowercase hex, as haxy writes them
fn isOid(text: []const u8, hex_len: usize) bool {
    if (text.len != hex_len) return false;
    for (text) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    return true;
}

const no_such_commit: api.Error = .{ .code = .not_found, .message = "This repository has no commit with this id." };
