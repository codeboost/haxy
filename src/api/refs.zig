//! refs in the JSON API: the branch and tag lists, and the ref a files view
//! is read at. lists page through the refs tab's own window read
//! (`ui.Repo.Refs.readWindow`), and a selection resolves as the files tab
//! resolves its route's ref (`ui.ResolvedRefOrOid`, `Files.readPatchRev`).
//!
//! ref names are bytes, like paths: a response sends each one percent-encoded
//! inside an `id` (see haxy-hub's docs/api-conventions.md, "Refs"), which a
//! client sends back unchanged as the `ref` parameter, and a `name` for
//! display.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const obj = xit.object;
const api = @import("../api.zig");
const api_path = @import("./path.zig");
const query_params = @import("./query.zig");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");

const Files = ui.Repo.Files;
const Refs = ui.Repo.Refs;

// the refs tab's window is the default page; clients may ask for up to this
// many
const max_page_size = 100;

/// what a files view is read at: the default branch, or the ref a `ref`
/// parameter names. names and ids are raw (decoded) bytes.
pub const Selection = union(enum) {
    default,
    branch: []const u8,
    tag: []const u8,
    commit: []const u8,
    revision: []const u8,

    pub const Kind = std.meta.Tag(Selection);

    /// `<kind>:<value>`, the decoded `ref` parameter; null when it names no
    /// kind or no value
    pub fn parse(text: []const u8) ?Selection {
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
        const value = text[colon + 1 ..];
        if (value.len == 0) return null;
        const kind = std.meta.stringToEnum(Kind, text[0..colon]) orelse return null;
        return switch (kind) {
            .default => null,
            inline else => |tag| @unionInit(Selection, @tagName(tag), value),
        };
    }

    /// the selection as a `ref` parameter names it: its kind, a colon and
    /// its value percent-encoded byte for byte as paths are
    pub fn id(self: Selection, arena: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .default => unreachable,
            inline else => |value, tag| std.fmt.allocPrint(arena, "{s}:{s}", .{ @tagName(tag), try api_path.encode(arena, value) }),
        };
    }
};

/// the `ref` parameter's selection (the default branch when absent)
pub fn selectionParam(arena: std.mem.Allocator, query: []const u8) !union(enum) { ok: Selection, invalid: api.Error } {
    const text = query_params.param(arena, query, "ref") catch |err| switch (err) {
        error.InvalidPercentEncoding => return .{ .invalid = invalidRef("The ref isn't validly encoded.") },
        else => |e| return e,
    } orelse return .{ .ok = .default };
    return .{ .ok = Selection.parse(text) orelse return .{ .invalid = invalidRef("Name a ref as branch:, tag:, commit: or revision: and its name.") } };
}

fn invalidRef(comptime message: []const u8) api.Error {
    return .{
        .code = .validation,
        .message = "Check the request's parameters.",
        .field_errors = &.{.{ .field = "ref", .message = message }},
    };
}

/// the ref a files response was read at
pub const Ref = struct {
    kind: enum { branch, tag, commit, revision },
    // the branch or tag name for display; null for a commit or revision
    name: ?[]const u8,
    // the selection as the `ref` parameter names it, to send back unchanged
    id: []const u8,
    // the commit it shows: a tag's target, a revision's source commit
    commit: []const u8,
};

pub fn Resolved(comptime repo_kind: rp.RepoKind, comptime repo_opts: rp.RepoOpts(repo_kind)) type {
    return struct {
        ref: Ref,
        // the commit or tree whose files the view lists
        oid: [ui.ResolvedRefOrOid(repo_kind, repo_opts).hex_len]u8,
    };
}

/// `selection` resolved in `repo`, or null when it names nothing there (an
/// unknown branch, tag, commit or revision, or a repo without commits)
pub fn resolve(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    selection: Selection,
) !?Resolved(repo_kind, repo_opts) {
    var moment = try repo.core.latestMoment();
    return resolveAt(repo_kind, repo_opts, arena, repo, io, gpa, &moment, selection);
}

/// `resolve` read at one snapshot of the repo (`moment`), so a caller can
/// read what the ref names in that same snapshot
pub fn resolveAt(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    moment: anytype,
    selection: Selection,
) !?Resolved(repo_kind, repo_opts) {
    const aa = arena.allocator();
    const ResolvedRef = ui.ResolvedRefOrOid(repo_kind, repo_opts);
    const hex_len = ResolvedRef.hex_len;
    const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = moment } };

    if (selection == .revision) {
        // the files tab shows a revision's head tree, its source commit's
        const record = (try readPatchRevAt(repo_kind, repo_opts, arena, repo, io, gpa, moment, selection.revision)) orelse return null;
        if (record.head_tree_oid.len != hex_len) return null;
        return .{
            .ref = .{ .kind = .revision, .name = null, .id = try selection.id(aa), .commit = record.event.source_oid },
            .oid = record.head_tree_oid[0..hex_len].*,
        };
    }

    // the files tab's own resolution, which takes ref names url-encoded
    const resolved = switch (selection) {
        .default => try ResolvedRef.initAt(state, io, aa, null, ""),
        .branch => |name| try ResolvedRef.initAt(state, io, aa, .branch, try ui.urlEncodeRef(aa, name)),
        .tag => |name| try ResolvedRef.initAt(state, io, aa, .tag, try ui.urlEncodeRef(aa, name)),
        .commit => |oid| if (isOid(oid, hex_len)) try ResolvedRef.initAt(state, io, aa, .object, oid) else null,
        .revision => unreachable,
    } orelse return null;

    // a tag may name an annotated tag, which the view reads through to its
    // commit; a commit id must name a commit itself
    var commit = (if (selection == .commit)
        obj.Object(repo_kind, repo_opts).init(state, io, gpa, &resolved.oid)
    else
        obj.Object(repo_kind, repo_opts).initCommit(state, io, gpa, &resolved.oid)) catch |err| switch (err) {
        error.ObjectNotFound, error.CommitNotFound => return null,
        else => |e| return e,
    };
    defer commit.deinit();
    if (commit.content != .commit) return null;

    const raw_name = std.Uri.percentDecodeInPlace(try aa.dupe(u8, resolved.value));
    const actual: Selection = switch (resolved.ref_or_oid) {
        .branch => .{ .branch = raw_name },
        .tag => .{ .tag = raw_name },
        .object => .{ .commit = raw_name },
    };
    return .{
        .ref = .{
            .kind = switch (resolved.ref_or_oid) {
                .branch => .branch,
                .tag => .tag,
                .object => .commit,
            },
            // for display, like every name a response carries
            .name = if (resolved.ref_or_oid == .object) null else try api_path.display(aa, raw_name),
            .id = try actual.id(aa),
            .commit = try aa.dupe(u8, &commit.oid),
        },
        .oid = resolved.oid,
    };
}

/// the patch revision `id_hex` names, as `Files.readPatchRev` reads it, but
/// in an xit repo's snapshot `moment` (a git repo's events have no snapshots)
pub const readPatchRevAt = Files.readPatchRevAt;

// a full object id in lowercase hex, as haxy writes them
fn isOid(text: []const u8, hex_len: usize) bool {
    if (text.len != hex_len) return false;
    for (text) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    return true;
}

/// a ref in a branch or tag list
const Item = struct {
    // for display
    name: []const u8,
    // to send back as the `ref` parameter
    id: []const u8,
};

/// writes a page of `kind`'s refs whose names start with the `search`
/// parameter, in name order, from the `cursor` parameter
pub fn writeList(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    kind: ui.RoutablePage.RefKind,
    query: []const u8,
    writer: *std.Io.Writer,
) !?api.Error {
    const limit = switch (try query_params.pageSize(aa, query, .{ .default = Refs.page_size, .max = max_page_size })) {
        .ok => |limit| limit,
        .invalid => |err| return err,
    };
    const cursor = (query_params.param(aa, query, "cursor") catch |err| switch (err) {
        error.InvalidPercentEncoding => return invalidPage("cursor", "This cursor isn't one Haxy gave out; start from the first page."),
        else => |e| return e,
    }) orelse "";
    const from = (try cursorName(aa, cursor)) orelse
        return invalidPage("cursor", "This cursor isn't one Haxy gave out; start from the first page.");
    const search = (query_params.param(aa, query, "search") catch |err| switch (err) {
        error.InvalidPercentEncoding => return .{ .code = .validation, .message = "Check the search.", .field_errors = &.{.{ .field = "search", .message = "The search isn't validly encoded." }} },
        else => |e| return e,
    }) orelse "";

    const found = try Refs.readWindow(repo_kind, repo_opts, repo, io, gpa, aa, kind, search, from, limit);
    const items = try aa.alloc(Item, found.names.len);
    for (found.names, items) |name, *item| {
        const selection: Selection = switch (kind) {
            .branch => .{ .branch = name },
            .tag => .{ .tag = name },
        };
        item.* = .{ .name = try api_path.display(aa, name), .id = try selection.id(aa) };
    }
    // like the refs tab, the list isn't counted
    try api.writePage(writer, items, .{
        .next_cursor = if (found.next) |next| try nameCursor(aa, next) else null,
        .count = .unknown,
    });
    return null;
}

// a list's cursor is the name its page starts from (as the refs tab windows
// from a name), in hex so that it is the same text however a client escapes it
fn nameCursor(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, name.len * 2);
    for (name, 0..) |byte, i| _ = std.fmt.bufPrint(out[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
    return out;
}

// the name a cursor starts from ("" for none), or null when it isn't one
fn cursorName(arena: std.mem.Allocator, cursor: []const u8) !?[]const u8 {
    if (cursor.len % 2 != 0) return null;
    const name = try arena.alloc(u8, cursor.len / 2);
    return std.fmt.hexToBytes(name, cursor) catch null;
}

fn invalidPage(comptime field: []const u8, comptime message: []const u8) api.Error {
    return .{
        .code = .validation,
        .message = "Check the paging parameters.",
        .field_errors = &.{.{ .field = field, .message = message }},
    };
}
