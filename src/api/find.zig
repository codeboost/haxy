//! the indexed file finder of the JSON API: the files whose names start with a
//! search, read from the file index the files tab's finder searches
//! (`Files.fileIndex`, `Files.findFiles`), so availability, matching, order
//! and the result cap are the TUI's.
//!
//! haxy indexes only an xit repo's branch tips, so a view at a tag, commit or
//! patch revision, or of a git repo, is `unsupported`, and a branch whose tip
//! no index covers is `no_index`; neither is an empty result.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const api_path = @import("./path.zig");
const api_refs = @import("./refs.zig");
const query_params = @import("./query.zig");
const ui = @import("../ui.zig");
const fnd = @import("../find.zig");

const Files = ui.Repo.Files;

// clients may ask for up to this many results a page; the default is the
// TUI's whole result list
const max_page_size = 100;

/// a found file: its name for display, and its whole path, percent-encoded
const Item = api_path.Named;

/// writes the `ref` view's files whose names start with `search`, a page from
/// `cursor`, or why the view has no index
pub fn write(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    query: []const u8,
    writer: *std.Io.Writer,
) !?api.Error {
    const aa = arena.allocator();
    const search = (query_params.param(aa, query, "search") catch |err| switch (err) {
        error.InvalidPercentEncoding => return .{ .code = .validation, .message = "Check the search.", .field_errors = &.{.{ .field = "search", .message = "The search isn't validly encoded." }} },
        else => |e| return e,
    }) orelse "";
    const page = switch (try query_params.Page.parse(aa, query, .{ .default = Files.max_list_entries, .max = max_page_size })) {
        .ok => |page| page,
        .invalid => |err| return err,
    };

    // the default branch unless `ref` names another ref, commit or revision
    const selection = switch (try api_refs.selectionParam(aa, query)) {
        .ok => |selection| selection,
        .invalid => |err| return err,
    };
    const resolved = (try api_refs.resolve(repo_kind, repo_opts, arena, repo, io, gpa, selection)) orelse return if (selection == .default)
        .{ .code = .not_found, .message = "This repository has no commits yet." }
    else
        .{ .code = .not_found, .message = "This repository has no such branch, tag, commit or revision." };
    const ref = resolved.ref;

    // the id names the view's own ref, the default branch's included
    const read = api_refs.Selection.parse(std.Uri.percentDecodeInPlace(try aa.dupe(u8, ref.id))) orelse return error.InvalidRefId;
    const ref_or_oid: ui.RoutablePage.RefOrOid = switch (read) {
        .branch => .branch,
        .tag => .tag,
        .default, .commit, .revision => .object,
    };
    const branch = if (read == .branch) read.branch else "";

    const moment = try repo.core.latestMoment();
    const file_index = try Files.fileIndex(repo_kind, repo_opts, moment, ref_or_oid, branch, &resolved.oid);
    if (comptime repo_kind == .xit) if (file_index == .indexed) {
        // an empty search matches nothing: it only asks whether the view is
        // indexed, as the TUI's search box shows only where it is
        const results: fnd.Results(repo_opts.hash) = if (search.len == 0) .{ .matches = &.{} } else try Files.findFiles(repo_opts, file_index.indexed, aa, search);
        const matches = results.matches;
        const start = @min(page.start, matches.len);
        const end = @min(start +| page.limit, matches.len);
        const items = try aa.alloc(Item, end - start);
        for (matches[start..end], items) |match, *item| item.* = try .init(aa, match.path);
        try std.json.Stringify.value(.{
            .ref = ref,
            .kind = "indexed",
            .items = items,
            .page = .{
                .has_more = end < matches.len,
                .next_cursor = try query_params.Page.nextCursor(aa, if (end < matches.len) end else null),
                // past the TUI's cap the search stops counting
                .count = if (results.capped) api.Count{ .at_least = matches.len } else api.Count{ .exact = matches.len },
            },
        }, .{}, writer);
        return null;
    };
    try std.json.Stringify.value(switch (file_index) {
        .indexed => unreachable,
        .missing => Unindexed{ .ref = ref, .kind = .no_index, .reason = null },
        .unsupported => |reason| Unindexed{ .ref = ref, .kind = .unsupported, .reason = reason },
    }, .{}, writer);
    return null;
}

const Unindexed = struct {
    ref: api_refs.Ref,
    kind: enum { no_index, unsupported },
    // why an unsupported view has no index; null for no_index
    reason: ?Files.Unindexed,
};
