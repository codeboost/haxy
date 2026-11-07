//! repository administration in the JSON API: a server repo's settings,
//! members and branches under `/api/v1/repos/{owner}/{name}/settings…`, and
//! deleting the repo with `DELETE /api/v1/repos/{owner}/{name}`. only the
//! repo's owners reach them, and only its main owner (its creator) deletes it.
//!
//! every write goes through the operation the TUI's settings tabs and Haxy's
//! web forms use (`ui.Repo.Settings.update`, `ui.Repo.Members.perform`,
//! `ui.Repo.Branches.perform`, `ui.Delete.perform`), so their rules live in
//! one place. those check, in the transaction that lands the change, that the
//! actor still owns the repo and that the role or settings they read are
//! still there (evt.changeRole, evt.writeRepoChange): a write that raced
//! another one, or by an owner who lost the role meanwhile, changes nothing.
//!
//! a local host has no accounts or members, so every route answers
//! `unsupported` there.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const api_account = @import("./account.zig");
const api_path = @import("./path.zig");
const api_refs = @import("./refs.zig");
const query_params = @import("./query.zig");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const web = @import("../web.zig");

const Settings = ui.Repo.Settings;
const Members = ui.Repo.Members;
const Branches = ui.Repo.Branches;

pub const Resource = union(enum) {
    // DELETE the repo itself (its other methods are the overview's)
    repo,
    // GET the settings; PUT changes them
    settings,
    // GET a page of the members; POST adds one
    members,
    // GET reads this member's role; PUT changes it; DELETE revokes it. still encoded.
    member: []const u8,
    // GET the default and protected branches
    branches,
    // PUT the default branch
    default_branch,
    // POST protects a branch; DELETE (with `?ref=`) unprotects one
    protected,

    fn allow(self: Resource) []const u8 {
        return switch (self) {
            .repo => "DELETE",
            .settings => "GET, HEAD, PUT",
            .members => "GET, HEAD, POST",
            .member => "GET, HEAD, PUT, DELETE",
            .branches => "GET, HEAD",
            .default_branch => "PUT",
            .protected => "POST, DELETE",
        };
    }

    fn allows(self: Resource, method: std.http.Method) bool {
        return switch (self) {
            .repo => method == .DELETE,
            .settings => method == .GET or method == .HEAD or method == .PUT,
            .members => method == .GET or method == .HEAD or method == .POST,
            .member => method == .GET or method == .HEAD or method == .PUT or method == .DELETE,
            .branches => method == .GET or method == .HEAD,
            .default_branch => method == .PUT,
            .protected => method == .POST or method == .DELETE,
        };
    }
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
};

/// the administration route `path` names for `method`, or null when it names
/// none. the repo's own path is one only for DELETE; its reads are the
/// overview's (api/repo.zig).
pub fn route(path: []const u8, method: std.http.Method) ?Route {
    const local_prefix = "/api/v1/repo";
    if (std.mem.eql(u8, path, local_prefix))
        return if (method == .DELETE) .{ .target = .local, .resource = .repo } else null;
    if (std.mem.startsWith(u8, path, local_prefix ++ "/"))
        return .{ .target = .local, .resource = settingsResource(path[local_prefix.len + 1 ..]) orelse return null };

    const prefix = "/api/v1/repos/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const owner_end = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const owner = rest[0..owner_end];
    const after_owner = rest[owner_end + 1 ..];
    const name_end = std.mem.indexOfScalar(u8, after_owner, '/') orelse after_owner.len;
    const name = after_owner[0..name_end];
    if (owner.len == 0 or name.len == 0) return null;
    const target: Route.Target = .{ .server = .{ .owner = owner, .name = name } };
    if (name_end == after_owner.len)
        return if (method == .DELETE) .{ .target = target, .resource = .repo } else null;
    return .{ .target = target, .resource = settingsResource(after_owner[name_end + 1 ..]) orelse return null };
}

// the resource a repo's path names after its own, from `settings` on
fn settingsResource(rest: []const u8) ?Resource {
    if (std.mem.eql(u8, rest, "settings")) return .settings;
    if (std.mem.eql(u8, rest, "settings/members")) return .members;
    if (std.mem.eql(u8, rest, "settings/branches")) return .branches;
    if (std.mem.eql(u8, rest, "settings/branches/default")) return .default_branch;
    if (std.mem.eql(u8, rest, "settings/branches/protected")) return .protected;
    const member_prefix = "settings/members/";
    if (std.mem.startsWith(u8, rest, member_prefix)) {
        const name = rest[member_prefix.len..];
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return null;
        return .{ .member = name };
    }
    return null;
}

// --- request bodies ---------------------------------------------------------

/// a settings change: the settings form's fields, each a string. the name
/// isn't one: renaming moves the repo, which the API doesn't offer.
pub const SettingsRequest = struct {
    // the settings' `revision` as the change's maker read them, in hex
    revision: []const u8,
    description: []const u8,
    // "public" or "private"
    access: []const u8,
    // who may start each kind of thread: "nobody", "members" or "anybody"
    discuss_role: []const u8,
    issue_role: []const u8,
    patch_role: []const u8,
};

pub const SettingsFields = struct {
    revision: evt.Repo.Revision,
    description: []const u8,
    access: evt.Repo.Access,
    discuss_role: ?evt.Repo.Role,
    issue_role: ?evt.Repo.Role,
    patch_role: ?evt.Repo.Role,
};

pub const ReadSettings = union(enum) { ok: SettingsFields, invalid: api.Error };

const check_fields = "Check the highlighted fields.";

fn fieldError(code: api.ErrorCode, comptime field: []const u8, comptime message: []const u8) api.Error {
    return .{ .code = code, .message = check_fields, .field_errors = &.{.{ .field = field, .message = message }} };
}

/// the settings a change names, or why it is refused: the revision it was
/// made from must be one Haxy gave out, and the visibility and every role
/// among the settings form's choices
pub fn readSettings(request: SettingsRequest) ReadSettings {
    var revision: evt.Repo.Revision = undefined;
    const valid_revision = request.revision.len == revision.len * 2 and
        if (std.fmt.hexToBytes(&revision, request.revision)) |_| true else |_| false;
    if (!valid_revision) return .{ .invalid = fieldError(.validation, "revision", "Send the revision of the settings as you loaded them.") };
    const access = ui.NewRepo.parseAccess(request.access) orelse
        return .{ .invalid = fieldError(.validation, "access", "Choose public or private.") };
    const role_message = "Choose nobody, members or anybody.";
    return .{ .ok = .{
        .revision = revision,
        .description = request.description,
        .access = access,
        .discuss_role = Settings.labelRole(request.discuss_role) catch return .{ .invalid = fieldError(.validation, "discuss_role", role_message) },
        .issue_role = Settings.labelRole(request.issue_role) catch return .{ .invalid = fieldError(.validation, "issue_role", role_message) },
        .patch_role = Settings.labelRole(request.patch_role) catch return .{ .invalid = fieldError(.validation, "patch_role", role_message) },
    } };
}

pub const MemberAddition = struct { name: []const u8 };
pub const RoleChange = struct { role: []const u8 };
pub const BranchChoice = struct { ref: []const u8 };
pub const Deletion = api_account.Deletion;

/// a member's role by the name the API gives it; owners rank above members
pub fn parseMemberRole(name: []const u8) ?evt.Repo.Role {
    if (std.mem.eql(u8, name, "owner")) return .owner;
    if (std.mem.eql(u8, name, "member")) return .write;
    return null;
}

pub fn memberRoleName(role: evt.Repo.Role) []const u8 {
    return switch (role) {
        .owner => "owner",
        // members' list holds no readers
        .write, .read => "member",
    };
}

/// the branch a ref id (`branch:<encoded name>`) names, decoded exactly once
/// into `arena`, or why it names none
pub fn parseBranchId(arena: std.mem.Allocator, id: []const u8) !BranchParam {
    // a query parameter's decoding, so a body's id reads as a `ref=` one does
    const decoded = query_params.param(arena, try std.fmt.allocPrint(arena, "ref={s}", .{id}), "ref") catch |err| switch (err) {
        error.InvalidPercentEncoding => return .{ .invalid = fieldError(.validation, "ref", "The ref isn't validly encoded.") },
        else => |e| return e,
    } orelse unreachable;
    return branchOf(decoded);
}

pub const BranchParam = union(enum) { branch: []const u8, invalid: api.Error };

// the branch a decoded ref id names
fn branchOf(decoded: []const u8) BranchParam {
    const selection = api_refs.Selection.parse(decoded) orelse return .{ .invalid = invalid_branch };
    return switch (selection) {
        .branch => |name| .{ .branch = name },
        else => .{ .invalid = invalid_branch },
    };
}

const invalid_branch = fieldError(.validation, "ref", "Name a branch as branch: and its name.");

// --- errors -----------------------------------------------------------------

/// why the shared members rules (ui.Repo.Members.perform) added nobody,
/// beside the name field
pub fn membersError(arena: std.mem.Allocator, failure: ui.Session.FormFeedback.MembersFailure, name: []const u8) !api.Error {
    const field: api.FieldError = switch (failure) {
        .not_found => .{ .field = "name", .message = "No user has that name." },
        .already_added => .{ .field = "name", .message = try std.fmt.allocPrint(arena, "{s} is already a member or an owner.", .{name}) },
    };
    return .{
        .code = if (failure == .not_found) .not_found else .conflict,
        .message = check_fields,
        .field_errors = try arena.dupe(api.FieldError, &.{field}),
    };
}

/// why the shared branches rules (ui.Repo.Branches.perform) wrote nothing,
/// beside the ref field
pub fn branchesError(failure: ui.Session.FormFeedback.BranchesFailure) api.Error {
    return switch (failure) {
        .not_found => fieldError(.not_found, "ref", "There is no branch by that name."),
        .already_added => fieldError(.conflict, "ref", "This branch is already protected."),
        .too_many => fieldError(.validation, "ref", std.fmt.comptimePrint("A repository can protect at most {d} branches. Unprotect one first.", .{evt.Repo.protected_branch_max_count})),
        .too_long => fieldError(.validation, "ref", "This branch name is too long to protect."),
    };
}

const not_found_repo: api.Error = .{ .code = .not_found, .message = "There is no repository with this name." };
const not_owner: api.Error = .{ .code = .forbidden, .message = "Only the repository's owners can manage it." };
const stale_settings = fieldError(.conflict, "revision", "Another owner changed these settings meanwhile. Load them again, then make your change.");
const changed_meanwhile: api.Error = .{ .code = .conflict, .message = "The repository changed while this was saved. Reload it and try again." };

// --- the routes -------------------------------------------------------------

/// what a server host provides these routes
pub const Server = struct {
    admin_repo_path: []const u8,
    users_dir: []const u8,
    session_store: web.SessionStore,
};

// members pages: the TUI's window by default, at most this many
const max_page_size = 100;

pub fn handle(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    // null on a local host
    server_maybe: ?Server,
    matched: Route,
    // the still-encoded query string
    query: []const u8,
) !void {
    const method = request.head.method;
    // an unread body closes the connection
    if (!matched.resource.allows(method))
        return api.respondError(request, allocator, .{ .code = .unsupported, .message = "This route doesn't support this method." }, .{ .allow = matched.resource.allow(), .keep_alive = false });
    const server = server_maybe orelse
        return api.respondError(request, allocator, .{ .code = .unsupported, .message = "Local mode has no accounts or members, so a repository has no settings to manage here." }, .{ .keep_alive = false });
    const names = switch (matched.target) {
        .server => |names| names,
        .local => return api.respondError(request, allocator, .{ .code = .unsupported, .message = "A server hosts many repositories; name one by its owner and name." }, .{ .keep_alive = false }),
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var admin_repo = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = server.admin_repo_path });
    defer admin_repo.deinit(io, allocator);

    const repo: Repo = .{
        .owner = std.Uri.percentDecodeInPlace(try aa.dupe(u8, names.owner)),
        .name = std.Uri.percentDecodeInPlace(try aa.dupe(u8, names.name)),
    };
    var ctx: Context = .{
        .io = io,
        .request = request,
        .allocator = allocator,
        .arena = &arena,
        .server = server,
        .admin_repo = &admin_repo,
        .repo = repo,
        .identity = try std.fmt.allocPrint(aa, "{s}:{s}", .{ repo.owner, repo.name }),
        .user_id = web.requestUserId(request, server.session_store),
    };
    const target = (try ctx.authorize()) orelse return;
    const actor = target.actor;
    // every read and write of this request is of the repo authorized, by id
    ctx.repo_id = target.repo_id;
    // only the main owner deletes the repo; a granted owner may do the rest
    if (matched.resource == .repo and !std.mem.eql(u8, &(actor.user_id orelse unreachable), &(actor.repo_user_id orelse unreachable))) {
        const message = try std.fmt.allocPrint(aa, "Only the main owner, {s}, can delete this repository.", .{repo.owner});
        return api.respondError(request, allocator, .{ .code = .forbidden, .message = message }, .{ .keep_alive = false });
    }

    switch (matched.resource) {
        .repo => try ctx.deleteRepo(actor),
        .settings => if (method == .PUT) try ctx.changeSettings(actor) else try ctx.respondSettings(actor, .ok),
        .members => if (method == .POST) try ctx.addMember(actor) else try ctx.listMembers(actor, query),
        .member => |encoded| {
            const name = std.Uri.percentDecodeInPlace(try aa.dupe(u8, encoded));
            if (method == .GET or method == .HEAD) try ctx.readMember(actor, name) else try ctx.changeMember(actor, name, method == .DELETE);
        },
        .branches => try ctx.respondBranches(actor, .ok),
        .default_branch => try ctx.changeBranch(actor, .default, null),
        .protected => try ctx.changeBranch(actor, if (method == .POST) .protect else .unprotect, if (method == .DELETE) query else null),
    }
}

const Repo = struct { owner: []const u8, name: []const u8 };

/// an authorized request's actor, and the repo it was authorized for
pub const Authorized = struct {
    actor: ui.Actor,
    repo_id: [evt.event_id_size]u8,
};

pub const Resolution = union(enum) { ok: Authorized, refused: api.Error };

/// the repo `owner`/`name` and `user_id` (null when anonymous) as one of its
/// owners, from one read of the repo: its record is the one authorized, and
/// its id is what the request then reads and writes, so a repo that takes the
/// name meanwhile is never served under another's authorization. a repo the
/// viewer can't read is not found, as a missing one; a reader who isn't an
/// owner is forbidden, or asked to log in when anonymous (or deleted).
pub fn resolveTarget(
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    moment: evt.AdminDB.HashMap(.read_only),
    users_dir: []const u8,
    owner: []const u8,
    name: []const u8,
    user_id: ?[evt.event_id_size]u8,
) !Resolution {
    const user = if (user_id) |id| try ui.activeUser(moment, arena, id) else null;
    const viewer: ?[evt.event_id_size]u8 = if (user != null) user_id else null;
    const found = (try evt.readRepoByOwnerAndName(io, allocator, arena, moment, users_dir, owner, name, viewer)) orelse return .{ .refused = not_found_repo };
    const role = found.role orelse return .{ .refused = not_found_repo };
    const active = user orelse return .{ .refused = .{ .code = .unauthenticated, .message = "Log in to manage this repository." } };
    if (!role.atLeast(.owner)) return .{ .refused = not_owner };
    return .{ .ok = .{
        .actor = .{
            .author = .{ .name = active.event.name, .email = active.event.email },
            .user_id = viewer,
            .role = role,
            .repo_user_id = try evt.parseEventId(&found.repo.event.user_id),
        },
        .repo_id = found.event_id,
    } };
}

const Context = struct {
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    server: Server,
    admin_repo: *rp.Repo(.xit, evt.admin_repo_opts),
    repo: Repo,
    // "owner:name"
    identity: []const u8,
    // the session's user, or null when anonymous
    user_id: ?[evt.event_id_size]u8,
    // the repo authorized, once it is
    repo_id: [evt.event_id_size]u8 = undefined,

    fn respond(self: Context, err: api.Error) !void {
        // a refusal may come before the body is read
        try api.respondError(self.request, self.allocator, err, .{ .keep_alive = false });
    }

    // the viewer as an owner of the repo, and the repo, read afresh, or null
    // once refused (see resolveTarget)
    fn authorize(self: Context) !?Authorized {
        // a fresh server has no moment, and so no users or repos, until its first event
        const moment = evt.currentMoment(evt.admin_repo_opts, self.admin_repo) catch |err| switch (err) {
            error.NotFound => {
                try self.respond(not_found_repo);
                return null;
            },
            else => |e| return e,
        };
        switch (try resolveTarget(self.io, self.allocator, self.arena, moment, self.server.users_dir, self.repo.owner, self.repo.name, self.user_id)) {
            .ok => |target| return target,
            .refused => |err| {
                try self.respond(err);
                return null;
            },
        }
    }

    // a write found the actor no longer owns the repo: answer as their
    // authorization now does
    fn respondNotOwner(self: Context) !void {
        if (try self.authorize() != null) try self.respond(changed_meanwhile);
    }

    fn currentMoment(self: Context) !evt.AdminDB.HashMap(.read_only) {
        return evt.currentMoment(evt.admin_repo_opts, self.admin_repo);
    }

    // the authorized repo's record as its owner's user repo holds it now;
    // null once it is gone or renamed (never another repo that took its name)
    fn readRepo(self: Context, actor: ui.Actor) !?evt.Repo.RepoWithId {
        return evt.readNamedRepo(self.io, self.allocator, self.arena, self.server.users_dir, &(actor.repo_user_id orelse unreachable), &self.repo_id, self.repo.name);
    }

    fn openRepo(self: Context, actor: ui.Actor, repo_id: *const [evt.event_id_size]u8) !rp.AnyRepo(.xit, .{}) {
        const path = try evt.repoPath(self.arena.allocator(), self.server.users_dir, &(actor.repo_user_id orelse unreachable), repo_id);
        return try rp.AnyRepo(.xit, .{}).open(self.io, self.allocator, .{ .path = path });
    }

    fn respondBody(self: Context, value: anytype, status: std.http.Status) !void {
        var out: std.Io.Writer.Allocating = .init(self.arena.allocator());
        try std.json.Stringify.value(value, .{}, &out.writer);
        try api.respondJson(self.request, out.written(), .{ .status = status });
    }

    // --- settings -----------------------------------------------------------

    fn respondSettings(self: Context, actor: ui.Actor, status: std.http.Status) !void {
        const found = (try self.readRepo(actor)) orelse return self.respond(not_found_repo);
        const event = found.repo.event;
        var any_repo = try self.openRepo(actor, &found.event_id);
        defer any_repo.deinit(self.io, self.allocator);
        const hash_kind = switch (any_repo) {
            inline else => |*opened| opened.self_repo_opts.hash,
        };
        const main_owner = std.mem.eql(u8, &(actor.user_id orelse unreachable), &(actor.repo_user_id orelse unreachable));
        const delete_reason: ?api.Error = if (main_owner) null else .{
            .code = .forbidden,
            .message = try std.fmt.allocPrint(self.arena.allocator(), "Only the main owner, {s}, can delete this repository.", .{self.repo.owner}),
        };
        // what a change of these settings names (see SettingsRequest)
        const revision = std.fmt.bytesToHex(event.settingsRevision(), .lower);
        try self.respondBody(.{
            .owner = self.repo.owner,
            .name = event.name,
            .revision = &revision,
            .description = event.description,
            .access = event.read_access,
            .discuss_role = Settings.roleLabel(event.discuss_role),
            .issue_role = Settings.roleLabel(event.issue_role),
            .patch_role = Settings.roleLabel(event.patch_role),
            .hash = @tagName(hash_kind),
            .main_owner = self.repo.owner,
            .actions = .{ .delete = Action{ .available = main_owner, .reason = if (delete_reason) |reason| .{ .code = reason.code, .message = reason.message } else null } },
        }, status);
    }

    fn changeSettings(self: Context, actor: ui.Actor) !void {
        const body = (try api_account.readBody(SettingsRequest, self.request, self.allocator, self.arena)) orelse return;
        const fields = switch (readSettings(body)) {
            .ok => |fields| fields,
            .invalid => |err| return api.respondError(self.request, self.allocator, err, .{}),
        };
        _ = Settings.update(self.io, self.allocator, self.server.users_dir, actor, self.identity, self.repo.name, fields.description, fields.access, fields.discuss_role, fields.issue_role, fields.patch_role, fields.revision, &self.repo_id) catch |err| switch (err) {
            error.NotFound => return self.respond(not_found_repo),
            error.Stale => return api.respondError(self.request, self.allocator, stale_settings, .{}),
            error.NotOwner => return self.respondNotOwner(),
            error.RepoChanged => return self.respond(changed_meanwhile),
            else => |e| return e,
        };
        try self.respondSettings(actor, .ok);
    }

    // --- members ------------------------------------------------------------

    fn listMembers(self: Context, actor: ui.Actor, query: []const u8) !void {
        const page = switch (try query_params.Page.parse(self.arena.allocator(), query, .{ .default = Members.page_size, .max = max_page_size })) {
            .ok => |page| page,
            .invalid => |err| return self.respond(err),
        };
        const found = (try self.readRepo(actor)) orelse return self.respond(not_found_repo);
        const window = try Members.readWindow(self.io, self.allocator, self.arena, try self.currentMoment(), self.server.users_dir, &(actor.repo_user_id orelse unreachable), &found.event_id, page.start, page.limit);
        const items = try self.arena.allocator().alloc(Member, window.rows.len);
        for (window.rows, items) |row, *item| item.* = .{ .name = row.name, .role = memberRoleName(row.role) };
        const next_cursor = try query_params.Page.nextCursor(self.arena.allocator(), window.next_start);
        try self.respondBody(.{
            // the creator, who owns the repo without a grant and isn't listed
            .main_owner = self.repo.owner,
            .items = items,
            // the TUI doesn't count members
            .page = .{ .has_more = next_cursor != null, .next_cursor = next_cursor, .count = api.Count{ .unknown = {} } },
        }, .ok);
    }

    // one member's role as the list holds it, or null for anyone it doesn't
    // list (the main owner, who owns the repo without a grant, is an owner),
    // so a client settles a member write in one read however long the list
    fn readMember(self: Context, actor: ui.Actor, name: []const u8) !void {
        const role = Members.readRole(self.io, self.allocator, self.arena, try self.currentMoment(), self.server.users_dir, &(actor.repo_user_id orelse unreachable), &self.repo_id, self.repo.name, name) catch |err| switch (err) {
            error.NotFound => return self.respond(not_found_repo),
            else => |e| return e,
        };
        // a name is bytes like any path segment: shown with U+FFFD where it isn't UTF-8
        try self.respondBody(.{ .name = try api_path.display(self.arena.allocator(), name), .role = if (role) |value| memberRoleName(value) else null }, .ok);
    }

    fn addMember(self: Context, actor: ui.Actor) !void {
        const body = (try api_account.readBody(MemberAddition, self.request, self.allocator, self.arena)) orelse return;
        const name = std.mem.trim(u8, body.name, " \t\r\n");
        if (name.len == 0) return api.respondError(self.request, self.allocator, fieldError(.validation, "name", "Enter a username."), .{});
        try self.performMember(actor, .grant, name, .created);
    }

    fn changeMember(self: Context, actor: ui.Actor, name: []const u8, revoke: bool) !void {
        const action: Members.Action = if (revoke) .revoke else blk: {
            const body = (try api_account.readBody(RoleChange, self.request, self.allocator, self.arena)) orelse return;
            const role = parseMemberRole(body.role) orelse
                return api.respondError(self.request, self.allocator, fieldError(.validation, "role", "Choose owner or member."), .{});
            break :blk if (role == .owner) .promote else .demote;
        };
        try self.performMember(actor, action, name, .ok);
    }

    fn performMember(self: Context, actor: ui.Actor, action: Members.Action, name: []const u8, status: std.http.Status) !void {
        const aa = self.arena.allocator();
        const failure = Members.perform(self.io, self.allocator, try self.currentMoment(), self.server.users_dir, actor, self.identity, &self.repo_id, action, name) catch |err| switch (err) {
            error.NotFound => return self.respond(not_found_repo),
            error.NotOwner => return self.respondNotOwner(),
            error.EventNotFound => return self.respond(.{ .code = .not_found, .message = try std.fmt.allocPrint(aa, "{s} isn't a member of this repository.", .{name}) }),
            error.MainOwner => return self.respond(.{ .code = .forbidden, .message = try std.fmt.allocPrint(aa, "{s} is the main owner, who always owns this repository.", .{name}) }),
            error.RoleChanged => return self.respond(.{ .code = .conflict, .message = try std.fmt.allocPrint(aa, "{s}'s role changed meanwhile. Reload the members and try again.", .{name}) }),
            else => |e| return e,
        };
        if (failure) |value| return api.respondError(self.request, self.allocator, try membersError(aa, value, name), .{});
        const role: ?evt.Repo.Role = switch (action) {
            .grant, .demote => .write,
            .promote => .owner,
            .revoke => null,
        };
        try self.respondBody(.{ .name = name, .role = if (role) |value| memberRoleName(value) else null }, status);
    }

    // --- branches -----------------------------------------------------------

    fn respondBranches(self: Context, actor: ui.Actor, status: std.http.Status) !void {
        const aa = self.arena.allocator();
        const found = (try self.readRepo(actor)) orelse return self.respond(not_found_repo);
        var any_repo = try self.openRepo(actor, &found.event_id);
        defer any_repo.deinit(self.io, self.allocator);
        var head_buffer: [xit.ref.MAX_REF_CONTENT_SIZE]u8 = undefined;
        const head_name: ?[]const u8 = switch (any_repo) {
            inline else => |*opened| if (opened.head(self.io, &head_buffer)) |head| switch (head) {
                .ref => |ref| try aa.dupe(u8, ref.name),
                .oid => null,
            } else |_| null,
        };
        const names = try found.repo.event.protectedBranchNames(aa);
        const protected = try aa.alloc(Branch, names.len);
        for (names, protected) |name, *branch| branch.* = try .init(aa, name);
        try self.respondBody(.{
            // the branch HEAD names, even before it has a commit; null when detached
            .default_branch = if (head_name) |name| try Branch.init(aa, name) else null,
            .protected = protected,
            .max_protected = evt.Repo.protected_branch_max_count,
        }, status);
    }

    // `query` holds the unprotected branch's `ref`; the other changes name it
    // in their body
    fn changeBranch(self: Context, actor: ui.Actor, action: Branches.Action, query: ?[]const u8) !void {
        const aa = self.arena.allocator();
        const choice = if (query) |text| branchOf((query_params.param(aa, text, "ref") catch |err| switch (err) {
            error.InvalidPercentEncoding => return self.respond(fieldError(.validation, "ref", "The ref isn't validly encoded.")),
            else => |e| return e,
        }) orelse "") else try parseBranchId(aa, (try api_account.readBody(BranchChoice, self.request, self.allocator, self.arena) orelse return).ref);
        const branch = switch (choice) {
            .branch => |name| name,
            .invalid => |err| return self.respond(err),
        };
        const failure = Branches.perform(self.io, self.allocator, self.server.users_dir, actor, self.identity, &self.repo_id, action, branch) catch |err| switch (err) {
            error.NotFound => return self.respond(not_found_repo),
            error.NotOwner => return self.respondNotOwner(),
            error.RepoChanged => return self.respond(changed_meanwhile),
            else => |e| return e,
        };
        if (failure) |value| return api.respondError(self.request, self.allocator, branchesError(value), .{});
        try self.respondBranches(actor, if (action == .protect) .created else .ok);
    }

    // --- deletion -----------------------------------------------------------

    fn deleteRepo(self: Context, actor: ui.Actor) !void {
        const body = (try api_account.readBody(Deletion, self.request, self.allocator, self.arena)) orelse return;
        const target: ui.Delete.Target = .{ .repo = self.identity };
        const failure = ui.Delete.perform(self.io, self.allocator, self.server.users_dir, self.admin_repo, actor.user_id orelse unreachable, target, body.confirm, body.password, &self.repo_id) catch |err| switch (err) {
            // the authorized repo was deleted or renamed meanwhile: nothing
            // else that took its name is deleted in its place
            error.NotFound => return self.respond(not_found_repo),
            else => |e| return e,
        };
        if (failure) |value| return api.respondError(self.request, self.allocator, try api_account.deletionError(self.arena.allocator(), value, target.confirmText()), .{});
        try self.respondBody(.{ .owner = self.repo.owner, .name = self.repo.name }, .ok);
    }
};

const Action = struct {
    available: bool,
    reason: ?struct { code: api.ErrorCode, message: []const u8 },
};

const Member = struct {
    name: []const u8,
    // "owner" or "member"
    role: []const u8,
};

const Branch = struct {
    // for display, U+FFFD-replaced
    name: []const u8,
    // `branch:<encoded name>`, to send back unchanged
    id: []const u8,

    fn init(arena: std.mem.Allocator, name: []const u8) !Branch {
        return .{ .name = try api_path.display(arena, name), .id = try (api_refs.Selection{ .branch = name }).id(arena) };
    }
};
