//! the repository routes of the JSON API: a repo's overview and its files at
//! the default branch. they resolve the repo with the TUI's own
//! `ui.Repo.resolve`, so a repo the viewer can't read is not found exactly
//! like a missing one, and read trees and files with the files tab's readers.
//!
//! a server names repos by owner and name; a local host serves only the repo
//! it opened, under /api/v1/repo.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const tr = xit.tree;
const api = @import("../api.zig");
const api_md = @import("./markdown.zig");
const api_path = @import("./path.zig");
const api_refs = @import("./refs.zig");
const api_find = @import("./find.zig");
const evt = @import("../event.zig");
const md = @import("../markdown.zig");
const ui = @import("../ui.zig");
const query_params = @import("./query.zig");

const Files = ui.Repo.Files;

// a directory page's default is the files tab's listing size; clients may ask
// for up to this many
const max_page_size = 100;

/// what a server host provides these routes
pub const Server = struct {
    admin_repo_path: []const u8,
    users_dir: []const u8,
    // the host's public transport urls, which clone commands name
    web_url: []const u8,
    ssh_url: ?[]const u8,
    git_ssh_prefix: []const u8,
};

pub const Host = union(evt.HostKind) {
    local: ui.RepoSource,
    server: Server,
};

pub const Route = struct {
    target: Target,
    resource: Resource,

    pub const Target = union(evt.HostKind) {
        // the repo a local host opened
        local,
        // still percent-encoded
        server: struct { owner: []const u8, name: []const u8 },
    };

    pub const Resource = enum { overview, files, branches, tags, find };
};

/// the repo route `path` names, or null when it names none
pub fn route(path: []const u8) ?Route {
    const local_prefix = "/api/v1/repo";
    if (std.mem.eql(u8, path, local_prefix)) return .{ .target = .local, .resource = .overview };
    if (std.mem.startsWith(u8, path, local_prefix ++ "/"))
        return .{ .target = .local, .resource = subResource(path[local_prefix.len + 1 ..]) orelse return null };

    const prefix = "/api/v1/repos/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    var segments = std.mem.splitScalar(u8, path[prefix.len..], '/');
    const owner = segments.next() orelse return null;
    const name = segments.next() orelse return null;
    if (owner.len == 0 or name.len == 0) return null;
    const resource: Route.Resource = if (segments.next()) |segment|
        subResource(segment) orelse return null
    else
        .overview;
    if (segments.next() != null) return null;
    return .{ .target = .{ .server = .{ .owner = owner, .name = name } }, .resource = resource };
}

// the resource a repo route's last segment names; the overview has none
fn subResource(segment: []const u8) ?Route.Resource {
    const resource = std.meta.stringToEnum(Route.Resource, segment) orelse return null;
    return if (resource == .overview) null else resource;
}

pub fn handle(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    host: Host,
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
    const aa = arena.allocator();

    // the server's admin repo must outlive the session, whose moment reads from it
    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);

    var session: ui.Session, const repo_identity: ui.RoutablePage.RepoIdentity = switch (host) {
        .local => |source| blk: {
            if (matched.target != .local)
                return api.respondError(request, allocator, .{ .code = .unsupported, .message = "Local mode serves only the repository it opened." }, .{});
            break :blk .{
                .{ .data = .{ .host_kind = .local }, .arena = &arena, .page_arena = &arena, .local = source },
                .{ .identity = "", .owner = "", .name = "" },
            };
        },
        .server => |server| blk: {
            const names = switch (matched.target) {
                .server => |names| names,
                .local => return api.respondError(request, allocator, .{ .code = .unsupported, .message = "A server hosts many repositories; name one by its owner and name." }, .{}),
            };
            admin_repo_maybe = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
            const admin_repo = if (admin_repo_maybe) |*admin_repo| admin_repo else unreachable;
            // the session drops a viewer whose account is gone, as page loads do
            var session = try ui.Session.init(&arena, admin_repo, .{ .user_id = if (viewer) |*id| try aa.dupe(u8, id) else null });
            session.users_dir = server.users_dir;
            session.data.git_http_url = server.web_url;
            session.data.git_ssh_url = server.ssh_url;
            session.data.git_ssh_prefix = server.git_ssh_prefix;
            const owner = try decodeSegment(aa, names.owner);
            const name = try decodeSegment(aa, names.name);
            break :blk .{ session, .{ .identity = try std.fmt.allocPrint(aa, "{s}:{s}", .{ owner, name }), .owner = owner, .name = name } };
        },
    };
    session.io = io;

    const resolved = (try ui.Repo.resolve(&arena, &session, repo_identity)) orelse
        return api.respondError(request, allocator, not_found_repo, .{});
    const repo_handle = try resolved.handle(&arena, &session);
    // a server always resolves a repo's source; only wasm has none
    const source = resolved.source orelse return error.NoRepoSource;

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*opened| {
                    const failure = switch (matched.resource) {
                        .overview => try writeOverview(repo_kind, opened.self_repo_opts, io, aa, opened, &session, resolved, repo_handle, &body.writer),
                        .files => try writeFiles(repo_kind, opened.self_repo_opts, io, allocator, &arena, opened, query, &body.writer),
                        .branches => try api_refs.writeList(repo_kind, opened.self_repo_opts, opened, io, allocator, aa, .branch, query, &body.writer),
                        .tags => try api_refs.writeList(repo_kind, opened.self_repo_opts, opened, io, allocator, aa, .tag, query, &body.writer),
                        .find => try api_find.write(repo_kind, opened.self_repo_opts, io, allocator, &arena, opened, query, &body.writer),
                    };
                    if (failure) |err| return api.respondError(request, allocator, err, .{});
                },
            }
        },
    }
    return api.respondJson(request, body.written(), .{});
}

// one message for missing and hidden repos alike
pub const not_found_repo: api.Error = .{ .code = .not_found, .message = "There is no repository with this name." };

const Overview = struct {
    // null in local mode, which has no accounts
    owner: ?[]const u8,
    name: []const u8,
    description: []const u8,
    // null in local mode, where nobody else reads the repo
    access: ?evt.Repo.Access,
    // the branch HEAD names, even before it has a commit; null when HEAD is
    // detached
    default_branch: ?[]const u8,
    // the default branch has no commit yet
    empty: bool,
    sections: []const ui.Repo.Section,
    clone: []const ui.widget.GitCommand,
    // how a viewer who may push fills an empty repo; null otherwise
    remote: ?ui.widget.GitCommand,
};

fn writeOverview(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    aa: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    session: *ui.Session,
    resolved: ui.Repo.Resolved,
    repo_handle: ui.RepoHandle,
    writer: *std.Io.Writer,
) !?api.Error {
    var head_buffer: [xit.ref.MAX_REF_CONTENT_SIZE]u8 = undefined;
    const default_branch: ?[]const u8 = if (repo.head(io, &head_buffer)) |head| switch (head) {
        // for display, like every name a response carries
        .ref => |ref| try api_path.display(aa, ref.name),
        .oid => null,
    } else |_| null;
    const empty = (try ui.ResolvedRefOrOid(repo_kind, repo_opts).init(repo, io, aa, null, "")) == null;

    var sections: std.ArrayList(ui.Repo.Section) = .empty;
    for (std.enums.values(ui.Repo.Section)) |section| {
        if (ui.Repo.hasSection(section, resolved.repo.event, repo_handle, session.data.host_kind, repo_kind)) try sections.append(aa, section);
    }

    const local = session.data.host_kind == .local;
    try std.json.Stringify.value(Overview{
        .owner = if (local) null else resolved.owner_name,
        // a local repo's name is its directory's, which needn't be utf-8
        .name = try api_path.display(aa, resolved.repo.event.name),
        .description = resolved.repo.event.description,
        .access = if (local) null else resolved.repo.event.read_access,
        .default_branch = default_branch,
        .empty = empty,
        .sections = sections.items,
        .clone = (try ui.widget.cloneCommands(aa, session.data, repo_handle)).list,
        .remote = if (empty) try ui.widget.remoteCommand(aa, session.data, repo_handle) else null,
    }, .{}, writer);
    return null;
}

fn writeFiles(
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
    const path = std.mem.trim(u8, (query_params.param(aa, query, "path") catch |err| switch (err) {
        error.InvalidPercentEncoding => return invalidField("path", "The path isn't validly encoded."),
        else => |e| return e,
    }) orelse "", "/");

    // the default branch unless `ref` names another ref, commit or revision
    const selection = switch (try api_refs.selectionParam(aa, query)) {
        .ok => |selection| selection,
        .invalid => |err| return err,
    };
    // one snapshot for resolving the ref and reading what it names
    var moment = try repo.core.latestMoment();
    const resolved = (try api_refs.resolveAt(repo_kind, repo_opts, arena, repo, io, gpa, &moment, selection)) orelse return if (selection == .default)
        .{ .code = .not_found, .message = "This repository has no commits yet." }
    else
        .{ .code = .not_found, .message = "This repository has no such branch, tag, commit or revision." };
    const ref = resolved.ref;

    const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
    var tree_dir = tr.TreeDir(repo_kind, repo_opts).init(state, io, gpa, &resolved.oid, path) catch |err| switch (err) {
        error.TreeEntryNotFound => return .{ .code = .not_found, .message = "There is no file or directory at this path." },
        else => |e| return e,
    };
    defer tree_dir.deinit();

    if (tree_dir.file_name) |file_name| {
        const entry = tree_dir.entries.get(file_name) orelse return error.TreeEntryNotFound;
        const line = switch (try lineParam(aa, query)) {
            .ok => |line| line,
            .invalid => |err| return err,
        };
        const content = try Files.readFileContent(repo_kind, repo_opts, state, io, gpa, aa, path, &entry.oid, entry.mode, line - 1);
        if (!content.is_binary and !content.is_empty and line > content.total_lines)
            return invalidField("line", "The file has fewer lines than this.");
        try writeFile(writer, ref, path, file_name, line, content, aa);
        return null;
    }

    const page = switch (try query_params.Page.parse(aa, query, .{ .default = Files.max_list_entries, .max = max_page_size })) {
        .ok => |page| page,
        .invalid => |err| return err,
    };
    const entries = tree_dir.entries.values();
    const names = tree_dir.entries.keys();
    const order = try Files.listOrder(aa, entries);
    var readme: ?api_path.Named = null;
    for (order) |index| {
        if (!entries[index].isTree() and Files.isReadme(names[index])) {
            readme = try .init(aa, try Files.childDir(aa, path, names[index]));
            break;
        }
    }
    const start = @min(page.start, order.len);
    const end = @min(start +| page.limit, order.len);
    const items = try aa.alloc(DirItem, end - start);
    for (order[start..end], items) |index, *item| {
        const named: api_path.Named = try .init(aa, try Files.childDir(aa, path, names[index]));
        item.* = .{
            .name = named.name,
            .path = named.path,
            .kind = if (entries[index].isTree()) .dir else .file,
        };
    }

    try std.json.Stringify.value(.{
        .ref = ref,
        .path = try api_path.encode(aa, path),
        .kind = "dir",
        .readme = readme,
        .items = items,
        .page = .{
            .has_more = end < order.len,
            .next_cursor = try query_params.Page.nextCursor(aa, if (end < order.len) end else null),
            .count = api.Count{ .exact = order.len },
        },
    }, .{}, writer);
    return null;
}

const DirItem = struct {
    // for display; see api/path.zig
    name: []const u8,
    // the entry's whole path, percent-encoded, to request it by
    path: []const u8,
    kind: enum { dir, file },
};

fn writeFile(writer: *std.Io.Writer, ref: api_refs.Ref, path: []const u8, name: []const u8, line: usize, content: Files.FileContent, aa: std.mem.Allocator) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("ref");
    try json.write(ref);
    const named: api_path.Named = try .init(aa, path);
    try json.objectField("path");
    try json.write(named.path);
    try json.objectField("name");
    try json.write(named.name);
    try json.objectField("kind");
    try json.write("file");
    try json.objectField("content");
    try json.beginObject();
    try json.objectField("kind");
    if (content.is_binary) {
        try json.write("binary");
    } else if (content.is_empty) {
        try json.write("empty");
    } else {
        try json.write("text");
        try json.objectField("start_line");
        try json.write(line);
        try json.objectField("lines");
        try json.write(content.lines);
        try json.objectField("total_lines");
        try json.write(content.total_lines);
        try json.objectField("has_more");
        try json.write(content.has_more);
        try json.objectField("next_line");
        try json.write(if (content.has_more) line + content.lines.len else null);
    }
    try json.endObject();
    // rendered as the files tab renders it: a markdown file one window holds
    // whole, parsed by haxy's reader
    try json.objectField("markdown");
    if (!content.is_binary and !content.is_empty and Files.showsMarkdown(name, line - 1, content.lines.len, content.has_more)) {
        const doc = try md.parse(aa, content.lines);
        try json.write(api_md.Blocks{ .blocks = doc.blocks });
    } else {
        try json.write(null);
    }
    try json.endObject();
}

// the 1-based first line of a file's window, from `line` (1 when absent)
fn lineParam(arena: std.mem.Allocator, query: []const u8) !union(enum) { ok: usize, invalid: api.Error } {
    const text = query_params.param(arena, query, "line") catch |err| switch (err) {
        error.InvalidPercentEncoding => return .{ .invalid = invalidField("line", "The line must be a positive whole number.") },
        else => |e| return e,
    } orelse return .{ .ok = 1 };
    const line = std.fmt.parseInt(u32, text, 10) catch 0;
    if (line == 0 or text[0] == '+') return .{ .invalid = invalidField("line", "The line must be a positive whole number.") };
    return .{ .ok = line };
}

fn invalidField(comptime field: []const u8, comptime message: []const u8) api.Error {
    return .{
        .code = .validation,
        .message = "Check the request's parameters.",
        .field_errors = &.{.{ .field = field, .message = message }},
    };
}

// a path segment, percent-decoded. a malformed escape stays as written, which
// matches no repo.
fn decodeSegment(arena: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    return std.Uri.percentDecodeInPlace(try arena.dupe(u8, encoded));
}
