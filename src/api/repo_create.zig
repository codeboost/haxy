//! repository creation in the JSON API: `POST /api/v1/repos` creates a repo
//! for the session's viewer, empty or as a copy of a repo the viewer can
//! read. it creates repos with `ui.NewRepo.create`, as the TUI's new-repo tab
//! and the web form (`POST …/repo/new`) do, so the name rules, the hash
//! formats and which repos may be copied live in one place. a repo the viewer
//! can't read is not found as a copy source exactly like a missing one. a
//! local host serves one repo and has no accounts, so it creates none.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const api = @import("../api.zig");
const api_account = @import("./account.zig");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const web = @import("../web.zig");

const RepoFailure = ui.Session.FormFeedback.RepoFailure;

pub const path = "/api/v1/repos";

/// whether `request_path` names the repo creation route
pub fn route(request_path: []const u8) bool {
    return std.mem.eql(u8, request_path, path);
}

/// a creation request's body: a JSON object of strings, each missing one
/// read as empty
pub const Request = struct {
    name: []const u8,
    description: []const u8,
    // "public" or "private"
    access: []const u8,
    // a hash format's name, "sha1" or "sha256"; empty for a copy, which keeps
    // its source's
    hash: []const u8,
    // the `owner:name` of the repo to copy, empty for an empty repo
    copy: []const u8,
};

pub const ReadFields = union(enum) { ok: ui.NewRepo.Fields, invalid: api.Error };

const check_fields = "Check the highlighted fields.";

fn fieldError(code: api.ErrorCode, comptime field: []const u8, comptime message: []const u8) api.Error {
    return .{ .code = code, .message = check_fields, .field_errors = &.{.{ .field = field, .message = message }} };
}

// "a, b or c"
fn listOf(comptime names: []const []const u8) []const u8 {
    comptime var text: []const u8 = names[0];
    inline for (names[1..], 1..) |name, index| text = text ++ (if (index == names.len - 1) " or " else ", ") ++ name;
    return text;
}

/// the new-repo form's fields a request names, or why it is refused: the
/// visibility and hash format must be among the form's choices, and a copy
/// names its source as `owner:name` and no hash format of its own (it keeps
/// its source's). the name and the copy source are checked when the repo is
/// created, by the shared rules.
pub fn readFields(request: Request) ReadFields {
    const access = ui.NewRepo.parseAccess(request.access) orelse
        return .{ .invalid = fieldError(.validation, "access", "Choose " ++ comptime listOf(ui.NewRepo.access_names) ++ ".") };
    var fields: ui.NewRepo.Fields = .{ .name = request.name, .description = request.description, .access = access, .copy = request.copy };
    if (request.copy.len > 0) {
        if (request.hash.len > 0)
            return .{ .invalid = fieldError(.validation, "hash", "A copy keeps the hash format of the repository it copies, so leave this out.") };
        if (evt.parseOwnerRepoPath(request.copy) == null)
            return .{ .invalid = fieldError(.validation, "copy", "Name the repository to copy as owner:name.") };
    } else {
        fields.hash = ui.NewRepo.parseHash(request.hash) orelse
            return .{ .invalid = fieldError(.validation, "hash", "Choose " ++ comptime listOf(ui.NewRepo.hash_names) ++ ".") };
    }
    return .{ .ok = fields };
}

/// why the shared rules (ui.NewRepo.create) refused to create a repo, beside
/// the field they rejected. a taken name is a conflict; a copy source the
/// viewer can't read is not found, in the same words as a missing one.
pub fn createError(failure: RepoFailure) api.Error {
    return switch (failure) {
        .required_name => fieldError(.validation, "name", "Choose a name."),
        .invalid_name => fieldError(.validation, "name", std.fmt.comptimePrint("Use up to {d} letters, digits, hyphens, underscores and dots (not . or ..).", .{evt.Repo.name_max_len})),
        .name_taken => fieldError(.conflict, "name", "You already have a repository with that name."),
        .invalid_copy => fieldError(.not_found, "copy", "There is no repository by that name that you can see."),
    };
}

// --- the route --------------------------------------------------------------

/// what a server host provides this route
pub const Server = struct {
    admin_repo_path: []const u8,
    users_dir: []const u8,
    session_store: web.SessionStore,
};

/// the created repo's identity, where the overview reads it
pub const Created = struct {
    owner: []const u8,
    name: []const u8,
};

pub fn handle(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    // null on a local host
    server_maybe: ?Server,
) !void {
    // the body goes unread, so the connection closes
    if (request.head.method != .POST)
        return api.respondError(request, allocator, .{ .code = .unsupported, .message = "This route only supports POST." }, .{ .allow = "POST", .keep_alive = false });
    const server = server_maybe orelse
        return api.respondError(request, allocator, .{ .code = .unsupported, .message = "Local mode serves a single repository and can't create others." }, .{ .keep_alive = false });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const unauthenticated: api.Error = .{ .code = .unauthenticated, .message = "Log in to create a repository." };

    const user_id = web.requestUserId(request, server.session_store) orelse
        return api.respondError(request, allocator, unauthenticated, .{ .keep_alive = false });
    var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
    defer admin_repo.deinit(io, allocator);
    // a fresh server has no moment, and so no users, until its first event
    const moment = evt.currentMoment(evt.admin_repo_opts, &admin_repo) catch |err| switch (err) {
        error.NotFound => return api.respondError(request, allocator, unauthenticated, .{ .keep_alive = false }),
        else => |e| return e,
    };
    const user = (try ui.activeUser(moment, &arena, user_id)) orelse
        return api.respondError(request, allocator, unauthenticated, .{ .keep_alive = false });

    // the optional X-Haxy-Viewer header is checked by guardWrite (api/session.zig)
    const body = (try api_account.readBody(Request, request, allocator, &arena)) orelse return;
    const fields = switch (readFields(body)) {
        .ok => |fields| fields,
        .invalid => |err| return api.respondError(request, allocator, err, .{}),
    };
    if (try ui.NewRepo.create(io, allocator, server.users_dir, moment, user_id, user, fields)) |failure|
        return api.respondError(request, allocator, createError(failure), .{});

    var out: std.Io.Writer.Allocating = .init(aa);
    try std.json.Stringify.value(Created{ .owner = user.event.name, .name = fields.name }, .{}, &out.writer);
    try api.respondJson(request, out.written(), .{ .status = .created });
}
