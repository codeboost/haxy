//! the discovery routes of the JSON API: the about page, the user directory
//! and a user's repos. they read through the same page data builders as the
//! TUI's home and user pages, so visibility and search rules stay in one
//! place. a local host has no accounts, so these answer `unsupported` there.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const api_md = @import("./markdown.zig");
const evt = @import("../event.zig");
const md = @import("../markdown.zig");
const ui = @import("../ui.zig");
const query_params = @import("./query.zig");

// the TUI's window is the default page; clients may ask for up to this many
const max_page_size = 100;

/// what a server host provides these routes
pub const Server = struct {
    admin_repo_path: []const u8,
    users_dir: []const u8,
};

pub const Route = union(enum) {
    about,
    users,
    // the user name, still percent-encoded
    user: []const u8,
    user_repos: []const u8,
    user_forks: []const u8,
};

/// the discovery route `path` names, or null when it names none
pub fn route(path: []const u8) ?Route {
    const prefix = "/api/v1/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    if (std.mem.eql(u8, rest, "about")) return .about;
    if (std.mem.eql(u8, rest, "users")) return .users;
    if (std.mem.startsWith(u8, rest, "users/")) {
        const tail = rest["users/".len..];
        const slash = std.mem.indexOfScalar(u8, tail, '/') orelse return if (tail.len > 0) .{ .user = tail } else null;
        if (slash == 0) return null;
        if (std.mem.eql(u8, tail[slash..], "/repos")) return .{ .user_repos = tail[0..slash] };
        if (std.mem.eql(u8, tail[slash..], "/forks")) return .{ .user_forks = tail[0..slash] };
        return null;
    }
    return null;
}

pub fn handle(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    // null on a local host
    server_maybe: ?Server,
    // the logged-in viewer, or null when anonymous
    viewer: ?[evt.event_id_size]u8,
    matched: Route,
    // the still-encoded query string
    query: []const u8,
) !void {
    const method = request.head.method;
    if (method != .GET and method != .HEAD)
        return api.respondError(request, allocator, .{ .code = .unsupported, .message = "This route only supports GET and HEAD." }, .{ .allow = "GET, HEAD" });
    const server = server_maybe orelse
        return api.respondError(request, allocator, .{ .code = .unsupported, .message = "Users and their repositories aren't available in local mode." }, .{});

    var repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
    defer repo.deinit(io, allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // the session drops a viewer whose account is gone, as page loads do
    var session = try ui.Session.init(&arena, &repo, .{ .user_id = if (viewer) |*id| id else null });
    session.io = io;
    session.users_dir = server.users_dir;

    const aa = arena.allocator();
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    switch (matched) {
        .about => {
            const about = try ui.Home.About.init(&arena, &session);
            const doc = try md.parseText(arena.allocator(), about.text);
            try std.json.Stringify.value(.{ .title = about.title, .blocks = api_md.Blocks{ .blocks = doc.blocks } }, .{}, &body.writer);
        },
        .users => {
            const page = switch (try query_params.Page.parse(aa, query, .{ .default = ui.Home.Users.page_size, .max = max_page_size })) {
                .ok => |page| page,
                .invalid => |err| return api.respondError(request, allocator, err, .{}),
            };
            const search = (try searchParam(request, allocator, aa, query)) orelse return;
            const haxy_moment = session.haxy_moment orelse return error.NoMoment;
            const found = try ui.Home.Users.window(&arena, haxy_moment, search, page.start, page.limit);
            try api.writePage(&body.writer, found.users, .{ .next_cursor = try query_params.Page.nextCursor(aa, found.next_start), .count = .unknown });
        },
        .user => |encoded_name| {
            const haxy_moment = session.haxy_moment orelse return error.NoMoment;
            _, const user = (try ui.User.readUser(&arena, haxy_moment, try decodeSegment(aa, encoded_name))) orelse
                return respondUserNotFound(request, allocator);
            try std.json.Stringify.value(evt.project(evt.User.Public, user.event), .{}, &body.writer);
        },
        .user_repos => |encoded_name| {
            const haxy_moment = session.haxy_moment orelse return error.NoMoment;
            const user_id, _ = (try ui.User.readUser(&arena, haxy_moment, try decodeSegment(aa, encoded_name))) orelse
                return respondUserNotFound(request, allocator);
            const page = switch (try query_params.Page.parse(aa, query, .{ .default = ui.User.page_size, .max = max_page_size })) {
                .ok => |page| page,
                .invalid => |err| return api.respondError(request, allocator, err, .{}),
            };
            const search = (try searchParam(request, allocator, aa, query)) orelse return;

            // a user with no user repo has no repos
            var user_repo_maybe = try evt.openUserRepo(io, allocator, server.users_dir, &user_id);
            defer if (user_repo_maybe) |*user_repo| user_repo.deinit(io, allocator);
            const found = if (user_repo_maybe) |*user_repo|
                try ui.User.readRepos(&arena, user_repo, session.userId(), if (search.len == 0) null else search, page.start, page.limit, .readable)
            else
                ui.User.ReposWindow.empty;

            const items = try aa.alloc(RepoItem, found.repos.len);
            for (found.repos, items) |record, *item| item.* = .{
                .name = record.event.name,
                .description = record.event.description,
                .access = record.event.read_access,
            };
            // no count: counting would reveal repos the viewer can't read
            try api.writePage(&body.writer, items, .{ .next_cursor = try query_params.Page.nextCursor(aa, found.next_start), .count = .unknown });
        },
        .user_forks => |encoded_name| {
            const haxy_moment = session.haxy_moment orelse return error.NoMoment;
            const user_id, _ = (try ui.User.readUser(&arena, haxy_moment, try decodeSegment(aa, encoded_name))) orelse
                return respondUserNotFound(request, allocator);
            const page = switch (try query_params.Page.parse(aa, query, .{ .default = ui.User.page_size, .max = max_page_size })) {
                .ok => |page| page,
                .invalid => |err| return api.respondError(request, allocator, err, .{}),
            };
            // a user with no user repo has no forks
            var user_repo_maybe = try evt.openUserRepo(io, allocator, server.users_dir, &user_id);
            defer if (user_repo_maybe) |*user_repo| user_repo.deinit(io, allocator);
            const moment = if (user_repo_maybe) |*user_repo| try evt.userMoment(user_repo) else null;
            const found = if (moment) |value|
                try ui.User.readForks(&arena, io, server.users_dir, user_id, value, session.userId(), page.start, page.limit, .readable)
            else
                ui.User.ForksWindow.empty;
            const items = try aa.alloc(ForkItem, found.forks.len);
            for (found.forks, items) |fork_item, *item| item.* = .{
                .id = fork_item.id,
                .name = fork_item.repo_name,
                .title = fork_item.title,
                .access = fork_item.access,
                .target_deleted = fork_item.access == null,
            };
            // no count: counting would reveal forks the viewer can't see
            try api.writePage(&body.writer, items, .{ .next_cursor = try query_params.Page.nextCursor(aa, found.next_start), .count = .unknown });
        },
    }
    return api.respondJson(request, body.written(), .{});
}

// a fork as a user's fork list shows it
const ForkItem = struct {
    id: []const u8,
    // the name of the repo it was made from
    name: []const u8,
    title: []const u8,
    // its target's, which it shares; null once the target is gone
    access: ?evt.Repo.Access,
    target_deleted: bool,
};

// the decoded `search` parameter ("" when absent), or null after answering
// with a validation error
fn searchParam(request: *std.http.Server.Request, allocator: std.mem.Allocator, arena: std.mem.Allocator, query: []const u8) !?[]const u8 {
    const search = query_params.param(arena, query, "search") catch |err| switch (err) {
        error.InvalidPercentEncoding => {
            try api.respondError(request, allocator, .{
                .code = .validation,
                .message = "Check the search.",
                .field_errors = &.{.{ .field = "search", .message = "The search isn't validly encoded." }},
            }, .{});
            return null;
        },
        else => |e| return e,
    };
    return search orelse "";
}

// a repo as a user's repo list shows it
const RepoItem = struct {
    name: []const u8,
    description: []const u8,
    access: evt.Repo.Access,
};

fn respondUserNotFound(request: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
    return api.respondError(request, allocator, .{ .code = .not_found, .message = "There is no user with this name." }, .{});
}

// a path segment, percent-decoded. a malformed escape stays as written, which
// matches no user.
fn decodeSegment(arena: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    return std.Uri.percentDecodeInPlace(try arena.dupe(u8, encoded));
}
