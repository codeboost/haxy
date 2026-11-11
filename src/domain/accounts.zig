//! read operations on accounts: the users list, a user's repos and forks, and
//! the fork resolver the fork page and the fork-addressed reads share. accounts
//! only exist on a server.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const evt = @import("../event.zig");
const domain = @import("../domain.zig");
const ui = @import("../ui.zig");
const fork = @import("../fork.zig");

const Id = [evt.event_id_size]u8;

pub const ListUsers = struct {
    pub const tool_name = "list_users";
    pub const hosts = domain.server_only;
    pub const tool_description = "List the server's accounts by name, 20 at a time; while next_start is set, it is the start of the next window. Server only.";
    pub const tool_schema_notes = .{
        .search = "A prefix the names must start with.",
        .start = "The index of the window's first account, a previous result's next_start; 0 or omitted lists the first window.",
    };

    // decoded; a name prefix
    search: []const u8 = "",
    start: usize = 0,

    pub const Result = ui.Home.Users;

    pub fn run(self: ListUsers, ctx: *domain.Ctx) !Result {
        const moment = try serverMoment(ctx);
        const users = try ui.Home.Users.load(ctx.arena, moment, self.start, self.search);
        // every account is listed, so an empty window off the first is past the end
        if (self.start != 0 and users.users.len == 0) return error.NotFound;
        return users;
    }
};

pub const ListRepos = struct {
    pub const tool_name = "list_repos";
    pub const hosts = domain.server_only;
    pub const tool_description = "List a user's repositories the acting user may read, 20 at a time: most recently active first, or by name when searching. A window may hold fewer when some are private; while next_start is set, it is the start of the next window. Server only.";
    pub const tool_schema_notes = .{
        .user = "The user's name.",
        .search = "A prefix the repository names must start with.",
        .start = "The index of the window's first repository, a previous result's next_start; 0 or omitted lists the first window.",
    };

    // the user's name
    user: []const u8,
    // decoded; a name prefix
    search: []const u8 = "",
    start: usize = 0,

    pub const Result = ui.User.ReposWindow;

    pub fn run(self: ListRepos, ctx: *domain.Ctx) !Result {
        const users_dir = (try serverHost(ctx)).users_dir;
        const user_id = try activeUserId(ctx, self.user);
        var user_repo_maybe = try evt.openUserRepo(ctx.io, ctx.gpa, users_dir, &user_id);
        defer if (user_repo_maybe) |*user_repo| user_repo.deinit(ctx.io, ctx.gpa);
        const search: ?[]const u8 = if (self.search.len == 0) null else try ctx.arena.allocator().dupe(u8, self.search);
        const repos = try ui.User.loadRepos(ctx.arena, if (user_repo_maybe) |*user_repo| user_repo else null, ctx.user_id, self.start, search);
        if (self.start != 0 and repos.past_end) return error.NotFound;
        return repos;
    }
};

pub const ListForks = struct {
    pub const tool_name = "list_forks";
    pub const hosts = domain.server_only;
    pub const tool_description = "List the forks a user made for their draft and published patches, 20 at a time, with each one's patch title and its target's access (null once the target is deleted). A window may hold fewer when the acting user can't read some targets; while next_start is set, it is the start of the next window. Server only.";
    pub const tool_schema_notes = .{
        .user = "The forker's name.",
        .start = "The index of the window's first fork, a previous result's next_start; 0 or omitted lists the first window.",
    };

    // the forker's name
    user: []const u8,
    start: usize = 0,

    pub const Result = ui.User.ForksWindow;

    pub fn run(self: ListForks, ctx: *domain.Ctx) !Result {
        const users_dir = (try serverHost(ctx)).users_dir;
        const user_id = try activeUserId(ctx, self.user);
        var user_repo_maybe = try evt.openUserRepo(ctx.io, ctx.gpa, users_dir, &user_id);
        defer if (user_repo_maybe) |*user_repo| user_repo.deinit(ctx.io, ctx.gpa);
        const forks = try ui.User.loadForks(ctx.arena, ctx.io, users_dir, &user_id, if (user_repo_maybe) |*user_repo| user_repo else null, ctx.user_id, self.start);
        if (self.start != 0 and forks.past_end) return error.NotFound;
        return forks;
    }
};

// a fork as a viewer may see it, found without opening it
pub const ResolvedFork = struct {
    // its id, which is its patch's
    id: Id,
    forker_id: Id,
    // whether the viewer made it, who alone may delete it
    forker: bool,
    record: evt.Fork.Record,
    // the repo it targets, null once that repo or its owner is deleted
    target: ?evt.Repo.RepoWithRole,
    target_id: Id,
    // the target's owner, whose record outlives a deleted target
    owner_id: Id,
    owner: evt.User.Record,
    // what the fork is read with: the viewer's role in the target, or read
    // for the forker of a deleted target
    role: evt.Repo.Role,
    // where it lives on disk
    path: []const u8,
};

// the fork `forker_name` made, with the id `id`, of the repo it named
// `repo_name` when it was made, as `viewer_id` may see it: null when there is
// none, when it is deleted, or when the viewer may not read it. a fork is as
// readable as its target and goes with the target's patch tab; a deleted
// target leaves it to its forker. the fork page and the fork-addressed reads
// share this, with explicit arguments because the page has a session where
// the reads have a `Ctx`.
pub fn resolveForkWith(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    moment: evt.AdminDB.HashMap(.read_only),
    users_dir: []const u8,
    viewer_id: ?Id,
    forker_name: []const u8,
    repo_name: []const u8,
    id: Id,
) !?ResolvedFork {
    const forker_id = (try evt.User.readIdByName(evt.AdminDB, evt.admin_repo_opts.hash, moment, forker_name)) orelse return null;
    const record = (try evt.readForkById(io, gpa, arena, users_dir, &forker_id, &id)) orelse return null;
    if (record.removed) return null;
    const forker = if (viewer_id) |viewer| std.mem.eql(u8, &viewer, &forker_id) else false;
    const target_id = try evt.parseEventId(&record.event.repo_id);
    const owner_id = try evt.parseEventId(&record.event.repo_user_id);

    // a deleted target, or one whose owner was deleted, leaves the fork to its forker
    const target = try evt.readRepoById(io, gpa, arena, users_dir, &owner_id, &target_id, viewer_id);
    // a draft is as readable as the repo it targets
    const role: evt.Repo.Role = if (target) |found| role: {
        // patches that are off take their drafts with them
        if (found.repo.event.patch_role == null) return null;
        break :role found.role orelse return null;
    } else if (forker) .read else return null;
    // the url keeps the name the fork was made under, even after a rename
    if (!std.mem.eql(u8, record.event.repo_name, repo_name)) return null;
    const owner = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, arena, &owner_id)) orelse return null;
    return .{
        .id = id,
        .forker_id = forker_id,
        .forker = forker,
        .record = record,
        .target = target,
        .target_id = target_id,
        .owner_id = owner_id,
        .owner = owner,
        .role = role,
        .path = try fork.forkPath(arena.allocator(), users_dir, &forker_id, &id),
    };
}

// the fork `identity` ("forker:name", the name it was made under) and the hex
// `fork_id` name, as the context's actor may see it, or null. forks live in
// user dirs, which only a server has.
pub fn resolveFork(ctx: *domain.Ctx, identity: []const u8, fork_id: []const u8) !?ResolvedFork {
    const users_dir = (try serverHost(ctx)).users_dir;
    const parsed = evt.parseOwnerRepoPath(identity) orelse return null;
    const id = evt.parseEventId(fork_id) catch return null;
    return try resolveForkWith(ctx.io, ctx.gpa, ctx.arena, ctx.moment orelse unreachable, users_dir, ctx.user_id, parsed.owner, parsed.name, id);
}

// where an open fork stands: its patch, its head and the base its newest
// revision was made against
pub fn ForkTip(comptime hash_kind: hash.HashKind) type {
    return struct {
        patch: evt.Patch.Record,
        // the fork's patch branch
        head: [hash.hexLen(hash_kind)]u8,
        // the newest revision's base, or the head before the first push
        base: [hash.hexLen(hash_kind)]u8,
        // the newest revision's, 0 before the first push
        commit_count: ?u64,
    };
}

// the tip of the fork `id` in its open repo, or null when the repo lacks its
// patch or its patch branch
pub fn readForkTip(
    comptime repo_opts: rp.RepoOpts(.xit),
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    fork_repo: *rp.Repo(.xit, repo_opts),
    id: *const Id,
) !?ForkTip(repo_opts.hash) {
    const fork_moment = try evt.currentMoment(repo_opts, fork_repo);
    const patch = (try evt.Patch.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_moment, arena, id)) orelse return null;
    const head = (try fork_repo.readRef(io, fork.ref)) orelse return null;
    const newest_revision = try evt.PatchRev.readNewest(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_moment, arena);
    var base = head;
    if (newest_revision) |revision| {
        if (revision.record.event.base_oid.len != base.len) return null;
        @memcpy(&base, revision.record.event.base_oid);
    }
    return .{
        .patch = patch,
        .head = head,
        .base = base,
        .commit_count = if (newest_revision) |revision| revision.record.commit_count else 0,
    };
}

// run a read addressed to a fork: resolve the fork `op.repo` ("forker:name")
// and `op.fork_id` name, open it and call the read's `runOpenFork`, which
// takes the open fork as `runOpen` takes an open repo
pub fn runFork(comptime Op: type, op: Op, ctx: *domain.Ctx) !Op.Result {
    const resolved = (try resolveFork(ctx, op.repo, op.fork_id)) orelse return error.NotFound;
    // a fork shares its target's hash kind
    var any_fork = try rp.AnyRepo(.xit, .{}).open(ctx.io, ctx.gpa, .{ .path = resolved.path, .require_repo_root = true });
    defer any_fork.deinit(ctx.io, ctx.gpa);
    switch (any_fork) {
        inline else => |*fork_repo| {
            const tip = (try readForkTip(fork_repo.self_repo_opts, ctx.io, ctx.arena, fork_repo, &resolved.id)) orelse return error.NotFound;
            return try op.runOpenFork(ctx, fork_repo.self_repo_opts, fork_repo, resolved, tip);
        },
    }
}

// the handle a fork's page is built with: its links rooted at the fork
// `identity` names, viewed with the role the fork is read with
pub fn forkHandle(ctx: *domain.Ctx, resolved: ResolvedFork, identity: []const u8) !ui.RepoHandle {
    const aa = ctx.arena.allocator();
    return .{
        .location = .{ .fork = .{ .identity = try aa.dupe(u8, identity), .id = try aa.dupe(u8, &std.fmt.bytesToHex(resolved.id, .lower)) } },
        .viewer = if (ctx.user) |user| .{ .role = resolved.role, .email = user.event.email } else null,
    };
}

// the id of the account `name` names, NotFound when there is none or it was removed
fn activeUserId(ctx: *domain.Ctx, name: []const u8) ![evt.event_id_size]u8 {
    const moment = try serverMoment(ctx);
    const user_id = (try evt.User.readIdByName(evt.AdminDB, evt.admin_repo_opts.hash, moment, name)) orelse return error.NotFound;
    _ = (try domain.activeUser(moment, ctx.arena, user_id)) orelse return error.NotFound;
    return user_id;
}

// where a server context keeps its users; accounts live only there
fn serverHost(ctx: *domain.Ctx) !domain.Host.Server {
    return switch (ctx.host) {
        .local => error.UnavailableHere,
        .server => |server| server,
    };
}

// the admin moment of a server context; accounts live only there
fn serverMoment(ctx: *domain.Ctx) !evt.AdminDB.HashMap(.read_only) {
    return switch (ctx.host) {
        .local => error.UnavailableHere,
        .server => ctx.moment orelse unreachable,
    };
}
