//! a fork in the JSON API: what it is and proposes, its files, commits and
//! diff, and its deletion. a fork is found and shown by the TUI's own fork
//! page readers (`ui.Fork.resolve`, `ui.Fork.readContents`), its views are
//! the repository routes' writers run on the fork, and its deletion is the
//! TUI's delete form's (`ui.Delete.perform`), so who may see or delete a fork
//! is decided in one place.
//!
//! forks are named by their forker, the name of the repo they were made from
//! and their id: /api/v1/forks/{forker}/{name}/{id}. a local host has none.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const api_account = @import("./account.zig");
const api_commits = @import("./commits.zig");
const api_diff = @import("./diff.zig");
const api_drafts = @import("./patch_drafts.zig");
const api_find = @import("./find.zig");
const api_refs = @import("./refs.zig");
const api_repo = @import("./repo.zig");
const evt = @import("../event.zig");
const fork = @import("../fork.zig");
const ui = @import("../ui.zig");

pub const Route = struct {
    // still percent-encoded
    forker: []const u8,
    name: []const u8,
    id: []const u8,
    resource: Resource,

    pub const Resource = union(enum) {
        fork,
        files,
        branches,
        tags,
        find,
        diff,
        commits: api_commits.Route.Resource,
    };
};

const prefix = "/api/v1/forks/";

/// the fork route `path` names, or null when it names none
pub fn route(path: []const u8) ?Route {
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    var segments = std.mem.splitScalar(u8, path[prefix.len..], '/');
    const forker = segments.next() orelse return null;
    const name = segments.next() orelse return null;
    const id = segments.next() orelse return null;
    if (forker.len == 0 or name.len == 0 or id.len == 0) return null;
    return .{ .forker = forker, .name = name, .id = id, .resource = resourceOf(segments.rest(), segments.index == null) orelse return null };
}

// what follows a fork's id: nothing, a view, or the commits' own routes
fn resourceOf(rest: []const u8, ended: bool) ?Route.Resource {
    if (ended) return .fork;
    var parts = std.mem.splitScalar(u8, rest, '/');
    const first = parts.next() orelse return null;
    if (std.mem.eql(u8, first, "commits")) {
        if (parts.index == null) return .{ .commits = .list };
        const oid = parts.next() orelse return null;
        if (oid.len == 0) return null;
        if (parts.index == null) return .{ .commits = .{ .commit = oid } };
        if (!std.mem.eql(u8, parts.rest(), "diff")) return null;
        return .{ .commits = .{ .diff = oid } };
    }
    if (parts.index != null) return null;
    const views = [_]struct { []const u8, Route.Resource }{ .{ "files", .files }, .{ "branches", .branches }, .{ "tags", .tags }, .{ "find", .find }, .{ "diff", .diff } };
    for (views) |view| if (std.mem.eql(u8, first, view[0])) return view[1];
    return null;
}

/// what a server host provides these routes
pub const Server = struct {
    admin_repo_path: []const u8,
    users_dir: []const u8,
    ssh_url: ?[]const u8,
    git_ssh_prefix: []const u8,
};

pub const not_found_fork: api.Error = .{ .code = .not_found, .message = "There is no fork with this name and id." };

pub fn handle(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    // null on a local host
    server_maybe: ?Server,
    viewer: ?[evt.event_id_size]u8,
    matched: Route,
    query: []const u8,
) !void {
    const method = request.head.method;
    const deletes = matched.resource == .fork and method == .DELETE;
    if (method != .GET and method != .HEAD and !deletes)
        return api.respondError(request, allocator, .{ .code = .unsupported, .message = "This method isn't supported here." }, .{ .allow = if (matched.resource == .fork) "GET, HEAD, DELETE" else "GET, HEAD" });
    const server = server_maybe orelse
        return api.respondError(request, allocator, .{ .code = .unsupported, .message = "Local mode has no forks." }, .{});

    var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
    defer admin_repo.deinit(io, allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    // the session drops a viewer whose account is gone, as page loads do
    var session = try ui.Session.init(&arena, &admin_repo, .{ .user_id = if (viewer) |*id| try aa.dupe(u8, id) else null });
    session.io = io;
    session.users_dir = server.users_dir;
    session.data.git_ssh_url = server.ssh_url;
    session.data.git_ssh_prefix = server.git_ssh_prefix;
    const haxy_moment = session.haxy_moment orelse return error.NoMoment;

    const forker_name = try decodeSegment(aa, matched.forker);
    const repo_name = try decodeSegment(aa, matched.name);
    const resolved = (try ui.Fork.resolve(&arena, io, server.users_dir, haxy_moment, session.userId(), forker_name, repo_name, matched.id)) orelse
        return api.respondError(request, allocator, not_found_fork, .{});
    const identity = try aa.print("{s}:{s}", .{ forker_name, repo_name });
    if (deletes) return remove(io, request, allocator, &arena, &admin_repo, &session, resolved, identity);

    const id_hex = std.fmt.bytesToHex(resolved.id, .lower);
    const repo_handle = ui.RepoHandle{
        .location = .{ .fork = .{ .identity = identity, .id = &id_hex } },
        .viewer = try ui.Viewer.init(&session, &arena, resolved.target_role),
    };
    const fork_path = try fork.forkPath(aa, server.users_dir, &resolved.forker_id, &resolved.id);
    var any_fork = try rp.AnyRepo(.xit, .{}).open(io, allocator, .{ .path = fork_path, .require_repo_root = true });
    defer any_fork.deinit(io, allocator);

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    switch (any_fork) {
        inline else => |*fork_repo| {
            const reader: Reader(fork_repo.self_repo_opts) = .{ .io = io, .gpa = allocator, .arena = &arena, .session = &session, .resolved = resolved, .identity = identity, .repo = fork_repo, .handle = repo_handle, .query = query, .writer = &body.writer };
            if (try reader.write(matched.resource)) |err| return api.respondError(request, allocator, err, .{});
        },
    }
    return api.respondJson(request, body.written(), .{});
}

// reads one resource of an opened fork
fn Reader(comptime repo_opts: rp.RepoOpts(.xit)) type {
    return struct {
        io: std.Io,
        gpa: std.mem.Allocator,
        arena: *std.heap.ArenaAllocator,
        session: *ui.Session,
        resolved: ui.Fork.Resolved,
        identity: []const u8,
        repo: *rp.Repo(.xit, repo_opts),
        handle: ui.RepoHandle,
        query: []const u8,
        writer: *std.Io.Writer,

        const Self = @This();

        fn write(self: Self, resource: Route.Resource) !?api.Error {
            const aa = self.arena.allocator();
            return switch (resource) {
                .fork => try self.writeFork(),
                .files => try api_repo.writeFiles(.xit, repo_opts, self.io, self.gpa, self.arena, self.repo, self.query, self.writer),
                .branches => try api_refs.writeList(.xit, repo_opts, self.repo, self.io, self.gpa, aa, .branch, self.query, self.writer),
                .tags => try api_refs.writeList(.xit, repo_opts, self.repo, self.io, self.gpa, aa, .tag, self.query, self.writer),
                .find => try api_find.write(.xit, repo_opts, self.io, self.gpa, self.arena, self.repo, self.query, self.writer),
                .diff => try self.writeDiff(),
                .commits => |commits| try self.writeCommits(commits),
            };
        }

        fn contents(self: Self) !ui.Fork.Contents(xit.hash.hexLen(repo_opts.hash)) {
            return ui.Fork.readContents(repo_opts, self.arena, self.io, self.session, self.resolved, self.identity, self.repo, self.handle.viewer);
        }

        fn writeCommits(self: Self, resource: api_commits.Route.Resource) !?api.Error {
            const read = try self.contents();
            const context: api_commits.Context = .{
                .admin_moment = self.session.haxy_moment,
                .handle = self.handle,
                .host_kind = .server,
                .base_oid = try self.arena.allocator().dupe(u8, &read.base),
            };
            return switch (resource) {
                .list => try api_commits.writeListAt(.xit, repo_opts, self.arena, self.repo, self.io, self.gpa, context, try self.repo.core.latestMoment(), self.query, self.writer),
                .commit => |oid| try api_commits.writeCommit(.xit, repo_opts, self.arena, self.repo, self.io, self.gpa, context, oid, self.writer),
                .diff => |oid| try api_diff.writeDiff(.xit, repo_opts, self.arena, self.repo, self.io, self.gpa, oid, self.query, self.writer),
            };
        }

        fn writeDiff(self: Self) !?api.Error {
            const read = try self.contents();
            const base: ?*const @TypeOf(read.base) = if (std.mem.allEqual(u8, &read.base, '0')) null else &read.base;
            return api_diff.writeRangeDiff(.xit, repo_opts, self.arena, self.repo, self.io, self.gpa, base, read.head, self.query, self.writer);
        }

        fn writeFork(self: Self) !?api.Error {
            const aa = self.arena.allocator();
            const read = try self.contents();
            const selected = read.patch.selectedThread() orelse return not_found_fork;
            try std.json.Stringify.value(Summary{
                .id = selected.id,
                .forker = self.identity[0 .. std.mem.indexOfScalar(u8, self.identity, ':') orelse return error.InvalidForkIdentity],
                .name = self.resolved.record.event.repo_name,
                .title = selected.record.event.title,
                .draft = self.resolved.record.event.stage == .draft,
                .target = try targetOf(self.resolved),
                .target_branch = try .init(aa, selected.record.event.target_branch),
                .patch = patchLink(self.resolved, read.patch, selected.id),
                .head = try aa.dupe(u8, &read.head),
                .base = if (std.mem.allEqual(u8, &read.base, '0')) null else try aa.dupe(u8, &read.base),
                .commit_count = read.commit_count,
                .commands = try api_drafts.commandsOf(aa, self.session.data, selected),
                .actions = .{ .delete = deleteAction(self.session, self.resolved) },
            }, .{}, self.writer);
            return null;
        }
    };
}

const Summary = struct {
    id: []const u8,
    forker: []const u8,
    // the name of the repo it was made from, which its url keeps
    name: []const u8,
    title: []const u8,
    draft: bool,
    // null once its target, or the target's owner, is gone
    target: ?struct { owner: []const u8, name: []const u8 },
    target_branch: BranchRef,
    // where its patch is read: the forker's draft, or the target's patch;
    // null when neither is there for this viewer
    patch: ?struct { kind: enum { draft, patch }, id: []const u8 },
    // the tip of its patch branch
    head: []const u8,
    // what its commits and diff start from
    base: ?[]const u8,
    commit_count: ?u64,
    commands: []const api_drafts.Command,
    actions: struct { delete: Availability },
};

const BranchRef = struct {
    name: []const u8,
    id: []const u8,

    fn init(aa: std.mem.Allocator, name: []const u8) !BranchRef {
        return .{ .name = name, .id = try (api_refs.Selection{ .branch = name }).id(aa) };
    }
};

const Availability = struct {
    available: bool,
    reason: ?struct { code: api.ErrorCode, message: []const u8 } = null,
};

fn targetOf(resolved: ui.Fork.Resolved) !@FieldType(Summary, "target") {
    const found = resolved.target orelse return null;
    const colon = std.mem.indexOfScalar(u8, resolved.target_identity, ':') orelse return error.InvalidForkIdentity;
    return .{ .owner = resolved.target_identity[0..colon], .name = found.repo.event.name };
}

// the patch the fork's page leads to: a draft is its forker's alone, and
// either must be readable in the target
fn patchLink(resolved: ui.Fork.Resolved, patch: ui.Repo.Patches, id: []const u8) @FieldType(Summary, "patch") {
    if (patch.repo_source == null) return null;
    return switch (resolved.record.event.stage) {
        .draft => if (resolved.forker) .{ .kind = .draft, .id = id } else null,
        .publish => .{ .kind = .patch, .id = id },
    };
}

fn deleteAction(session: *const ui.Session, resolved: ui.Fork.Resolved) Availability {
    if (resolved.forker) return .{ .available = true };
    if (session.userId() == null) return .{ .available = false, .reason = .{ .code = .unauthenticated, .message = log_in_to_delete } };
    return .{ .available = false, .reason = .{ .code = .forbidden, .message = forker_only } };
}

const log_in_to_delete = "Log in as the fork's owner to delete it.";
const forker_only = "Only the fork's owner can delete it.";

const Deletion = struct { confirm: []const u8 = "", password: []const u8 = "" };

// deletes the fork through the TUI's delete form, for its forker only
fn remove(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    admin_repo: *rp.Repo(.xit, evt.admin_repo_opts),
    session: *const ui.Session,
    resolved: ui.Fork.Resolved,
    identity: []const u8,
) !void {
    if (!resolved.forker) {
        const refusal = deleteAction(session, resolved).reason.?;
        return api.respondError(request, allocator, .{ .code = refusal.code, .message = refusal.message }, .{});
    }
    const body = (try api_account.readBody(Deletion, request, allocator, arena)) orelse return;
    const target: ui.Delete.Target = .{ .fork = .{ .identity = identity, .id = std.fmt.bytesToHex(resolved.id, .lower) } };
    const failure = ui.Delete.perform(io, allocator, session.users_dir.?, admin_repo, resolved.forker_id, target, body.confirm, body.password, null) catch |err| switch (err) {
        error.NotFound => return api.respondError(request, allocator, not_found_fork, .{}),
        else => |e| return e,
    };
    if (failure) |value| return api.respondError(request, allocator, try api_account.deletionError(arena.allocator(), value, target.confirmText()), .{});
    var body_out: std.Io.Writer.Allocating = .init(allocator);
    defer body_out.deinit();
    const colon = std.mem.indexOfScalar(u8, identity, ':') orelse return error.InvalidForkIdentity;
    try std.json.Stringify.value(.{ .forker = identity[0..colon], .name = identity[colon + 1 ..], .id = &target.fork.id }, .{}, &body_out.writer);
    return api.respondJson(request, body_out.written(), .{});
}

// a path segment, percent-decoded. a malformed escape stays as written, which
// matches no fork.
fn decodeSegment(arena: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    return std.Uri.percentDecodeInPlace(try arena.dupe(u8, encoded));
}
