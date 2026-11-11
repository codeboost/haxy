//! repo-level operations.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("../event.zig");
const pch = @import("../patch.zig");
const copy = @import("../copy.zig");
const domain = @import("../domain.zig");
const threads = @import("threads.zig");

pub const RefreshLocal = struct {
    pub const tool_name = "refresh_local";
    pub const hosts = domain.local_only;
    pub const tool_description = "Bring the local repository's issues, patches and discussions up to date with its events branch.";
    pub const tool_schema_notes = .{
        .repo = "\"\" or omitted; local mode has one repository.",
    };

    // "" in local mode, which has one repo
    repo: []const u8 = "",

    // consume the events branch into the event db and refresh the patch
    // branches, as a local page build does before it reads
    pub fn run(self: RefreshLocal, ctx: *domain.Ctx) !void {
        // a server consumes every write in its own transaction
        if (ctx.host != .local) return error.UnavailableHere;
        const resolved = (try domain.resolveRepo(ctx, self.repo)) orelse return error.NotFound;
        try domain.withRepo(ctx, resolved, {}, refresh);
    }
};

pub const CreateRepo = struct {
    pub const tool_name = "create_repo";
    pub const hosts = domain.server_only;
    pub const tool_description = "Create a repository owned by the acting user, empty or as a copy of one they can read. Server only.";
    pub const tool_schema_notes = .{
        .name = "The new repository's name.",
        .description = "A short description.",
        .access = "Who may read it: private (members only) or public (anybody).",
        .hash = "The hash an empty repository uses; a copy keeps its source's.",
        .copy = "A repository to copy as \"owner:name\", or \"\" for an empty one.",
    };

    name: []const u8,
    description: []const u8 = "",
    access: evt.Repo.Access = .private,
    hash: xit.hash.HashKind = .sha1,
    // "owner:name" of a repo to copy, or "" for none
    copy: []const u8 = "",

    pub const Result = struct {
        // "owner:name"
        identity: []const u8,
    };

    pub fn run(self: CreateRepo, ctx: *domain.Ctx) !Result {
        const server = switch (ctx.host) {
            .server => |server| server,
            // local mode has its one repo
            .local => return error.UnavailableHere,
        };
        const user_id = ctx.user_id orelse return error.LoginRequired;
        const user = ctx.user orelse unreachable;
        // allocated before the write, so a failure after it can't hide that the repo exists
        const identity = try ctx.arena.allocator().print("{s}:{s}", .{ user.event.name, self.name });
        _ = try evt.createRepo(ctx.io, ctx.gpa, server.users_dir, &user_id, .{ .name = user.event.name, .email = user.event.email }, self.name, self.description, self.access, self.hash, if (self.copy.len == 0) null else .{ .admin_moment = ctx.moment orelse unreachable, .path = self.copy });
        return .{ .identity = identity };
    }
};

pub const UpdateRepoSettings = struct {
    pub const tool_name = "update_repo_settings";
    pub const hosts = domain.server_only;
    pub const tool_description = "Rename a repository and change its description, read access and who may open discussions, issues and patches. Needs the owner role. Server only.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .name = "The repository's name, new or unchanged.",
        .description = "The description, new or unchanged; \"\" clears it.",
        .access = "Who may read it: private (members only) or public (anybody).",
        .discuss_role = "Who may open discussions: read (anybody), write (members), or null to turn the tab off.",
        .issue_role = "Who may open issues: read (anybody), write (members), or null to turn the tab off.",
        .patch_role = "Who may open patches: read (anybody), write (members), or null to turn the tab off.",
    };
    // the tab roles a tool offers: run refuses owner, which no page shows
    pub const tool_schema_enums = .{
        .discuss_role = [_]evt.Repo.Role{ .read, .write },
        .issue_role = [_]evt.Repo.Role{ .read, .write },
        .patch_role = [_]evt.Repo.Role{ .read, .write },
    };

    // "owner:name"
    repo: []const u8,
    name: []const u8,
    // required: the settings are replaced whole, so an omitted one would clear it
    description: []const u8,
    access: evt.Repo.Access,
    // read or write; a null role turns its tab off. no form offers owner.
    discuss_role: ?evt.Repo.Role,
    issue_role: ?evt.Repo.Role,
    patch_role: ?evt.Repo.Role,

    pub const Result = struct {
        // "owner:name" under the new name
        identity: []const u8,
    };

    pub fn run(self: UpdateRepoSettings, ctx: *domain.Ctx) !Result {
        const server = switch (ctx.host) {
            .server => |server| server,
            // a local repo's name is its directory's
            .local => return error.UnavailableHere,
        };
        const actor = try authorizeOwner(ctx, self.repo);
        const parsed = evt.parseOwnerRepoPath(self.repo) orelse return error.NotFound;
        // an owners-only tab is nothing the pages can show or set
        for ([_]?evt.Repo.Role{ self.discuss_role, self.issue_role, self.patch_role }) |role| {
            if (role == .owner) return error.InvalidTabRole;
        }
        // a server actor always has the repo's owner id
        const owner_id = actor.repo_user_id orelse unreachable;
        // allocated before the write, so a failure after it can't hide the change
        const identity = try ctx.arena.allocator().print("{s}:{s}", .{ parsed.owner, self.name });
        try evt.updateRepo(ctx.io, ctx.gpa, server.users_dir, &owner_id, actor.author, parsed.name, self.name, self.description, self.access, self.discuss_role, self.issue_role, self.patch_role);
        return .{ .identity = identity };
    }
};

pub const DeleteRepo = struct {
    pub const tool_name = "delete_repo";
    pub const hosts = domain.server_only;
    pub const tool_description = "Permanently delete a repository the acting user created, with its history. Server only.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .confirm = "The repository's \"owner:name\" again, to confirm.",
        .password = "The acting user's password.",
    };

    // "owner:name"
    repo: []const u8,
    // the text typed to confirm, which must be `repo`
    confirm: []const u8,
    password: []const u8,

    pub fn run(self: DeleteRepo, ctx: *domain.Ctx) !void {
        const server = switch (ctx.host) {
            .server => |server| server,
            // local mode has its one repo, which it doesn't delete
            .local => return error.UnavailableHere,
        };
        const user_id = ctx.user_id orelse return error.LoginRequired;
        // the password as it is now, which may have changed since the context was built
        const user = try domain.currentUser(ctx);
        // the typed text is checked before the slow password check
        if (!std.mem.eql(u8, self.confirm, self.repo)) return error.WrongConfirm;
        if (!evt.User.verifyPassword(user.event.password_hash, self.password)) return error.WrongPassword;
        const parsed = evt.parseOwnerRepoPath(self.repo) orelse return error.NotFound;
        // anyone but the creator, a granted owner too, finds nothing to delete
        if (!std.mem.eql(u8, parsed.owner, user.event.name)) return error.NotFound;
        var arena = std.heap.ArenaAllocator.init(ctx.gpa);
        defer arena.deinit();
        const repo_id = blk: {
            var user_repo = (try evt.openUserRepo(ctx.io, ctx.gpa, server.users_dir, &user_id)) orelse return error.NotFound;
            defer user_repo.deinit(ctx.io, ctx.gpa);
            const moment = (try evt.userMoment(&user_repo)) orelse return error.NotFound;
            const found = (try evt.Repo.readByName(evt.UserDB, evt.user_repo_opts.hash, moment, &arena, parsed.name)) orelse return error.NotFound;
            break :blk found.event_id;
        };
        try evt.deleteRepo(ctx.io, ctx.gpa, server.users_dir, &user_id, &repo_id, .{ .name = user.event.name, .email = user.event.email });
    }
};

const member_notes = .{
    .repo = domain.repo_note,
    .user = "The user's name.",
};

pub const Grant = struct {
    pub const tool_name = "grant";
    pub const hosts = domain.server_only;
    pub const tool_description = "Make a user a member of a repository, who may push to it. Needs the owner role. Server only.";
    pub const tool_schema_notes = member_notes;

    // "owner:name"
    repo: []const u8,
    // the user's name
    user: []const u8,

    pub fn run(self: Grant, ctx: *domain.Ctx) !void {
        try changeMember(ctx, self.repo, self.user, .grant);
    }
};

pub const Revoke = struct {
    pub const tool_name = "revoke";
    pub const hosts = domain.server_only;
    pub const tool_description = "Take a member's or owner's role in a repository away. Needs the owner role. Server only.";
    pub const tool_schema_notes = member_notes;

    // "owner:name"
    repo: []const u8,
    // the user's name
    user: []const u8,

    pub fn run(self: Revoke, ctx: *domain.Ctx) !void {
        try changeMember(ctx, self.repo, self.user, .revoke);
    }
};

pub const Promote = struct {
    pub const tool_name = "promote";
    pub const hosts = domain.server_only;
    pub const tool_description = "Make a member of a repository one of its owners, who may manage it. Needs the owner role. Server only.";
    pub const tool_schema_notes = member_notes;

    // "owner:name"
    repo: []const u8,
    // the user's name
    user: []const u8,

    pub fn run(self: Promote, ctx: *domain.Ctx) !void {
        try changeMember(ctx, self.repo, self.user, .promote);
    }
};

pub const Demote = struct {
    pub const tool_name = "demote";
    pub const hosts = domain.server_only;
    pub const tool_description = "Make an owner of a repository a plain member again. Needs the owner role. Server only.";
    pub const tool_schema_notes = member_notes;

    // "owner:name"
    repo: []const u8,
    // the user's name
    user: []const u8,

    pub fn run(self: Demote, ctx: *domain.Ctx) !void {
        try changeMember(ctx, self.repo, self.user, .demote);
    }
};

const MemberAction = enum { grant, revoke, promote, demote };

// change the role the user `name` holds in the repo `identity` names, as one of its owners
fn changeMember(ctx: *domain.Ctx, identity: []const u8, name: []const u8, action: MemberAction) !void {
    const server = switch (ctx.host) {
        .server => |server| server,
        // local mode has no accounts to grant
        .local => return error.UnavailableHere,
    };
    const actor = try authorizeOwner(ctx, identity);
    const resolved = (try domain.resolveRepo(ctx, identity)) orelse return error.NotFound;
    const owner_id = actor.repo_user_id orelse unreachable;
    const repo_id = try threads.repoId(resolved);
    // the name as the admin repo holds it now: the context's moment predates
    // the body a web form names the user in
    const moment = try evt.currentMoment(evt.admin_repo_opts, ctx.admin orelse unreachable);
    const user_id = (try evt.User.readIdByName(evt.AdminDB, evt.admin_repo_opts.hash, moment, name)) orelse
        // an add names someone; the other actions name a listed member
        return if (action == .grant) error.UnknownUser else error.NotAMember;
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const role = blk: {
        var user_repo = (try evt.openUserRepo(ctx.io, ctx.gpa, server.users_dir, &owner_id)) orelse return error.NotFound;
        defer user_repo.deinit(ctx.io, ctx.gpa);
        const user_moment = (try evt.userMoment(&user_repo)) orelse return error.NotFound;
        break :blk try evt.Grant.readRole(evt.UserDB, evt.user_repo_opts.hash, user_moment, &arena, &repo_id, &user_id);
    };
    switch (action) {
        .grant => {
            // a reader becomes a member; anyone else with a role, and the
            // creator, who holds no grant, is already added
            const already = if (role) |held| held != .read else std.mem.eql(u8, &user_id, &owner_id);
            if (already) return error.AlreadyMember;
            try evt.grantRole(ctx.io, ctx.gpa, server.users_dir, &owner_id, &repo_id, &user_id, .write, actor.author);
        },
        .revoke => evt.revokeRole(ctx.io, ctx.gpa, server.users_dir, &owner_id, &repo_id, &user_id, actor.author) catch |err| switch (err) {
            error.EventNotFound => return error.NotAMember,
            else => |e| return e,
        },
        // only a listed grant changes role
        .promote, .demote => if (role == null) return error.NotAMember else try evt.grantRole(ctx.io, ctx.gpa, server.users_dir, &owner_id, &repo_id, &user_id, if (action == .promote) .owner else .write, actor.author),
    }
}

const branch_notes = .{
    .repo = domain.repo_note,
    .branch = "The branch's name, as git names it (it may contain \"/\").",
};

pub const ProtectBranch = struct {
    pub const tool_name = "protect_branch";
    pub const hosts = domain.server_only;
    pub const tool_description = "Protect an existing branch of a repository from deletion and force pushes; only owners may push to it directly. Needs the owner role. Server only.";
    pub const tool_schema_notes = branch_notes;

    // "owner:name"
    repo: []const u8,
    branch: []const u8,

    pub fn run(self: ProtectBranch, ctx: *domain.Ctx) !void {
        try changeBranch(ctx, self.repo, self.branch, .protect);
    }
};

pub const UnprotectBranch = struct {
    pub const tool_name = "unprotect_branch";
    pub const hosts = domain.server_only;
    pub const tool_description = "Take a branch of a repository out of its protected branches. A branch that isn't protected is left as it is. Needs the owner role. Server only.";
    pub const tool_schema_notes = branch_notes;

    // "owner:name"
    repo: []const u8,
    branch: []const u8,

    pub fn run(self: UnprotectBranch, ctx: *domain.Ctx) !void {
        try changeBranch(ctx, self.repo, self.branch, .unprotect);
    }
};

pub const SetDefaultBranch = struct {
    pub const tool_name = "set_default_branch";
    pub const hosts = domain.server_only;
    pub const tool_description = "Make an existing branch a repository's default, which its page shows and clones check out. Needs the owner role. Server only.";
    pub const tool_schema_notes = branch_notes;

    // "owner:name"
    repo: []const u8,
    branch: []const u8,

    pub fn run(self: SetDefaultBranch, ctx: *domain.Ctx) !void {
        try changeBranch(ctx, self.repo, self.branch, .default);
    }
};

const BranchAction = enum { default, protect, unprotect };

// the most bytes a branch that may be protected or made the default takes
// url-encoded: the pages link to it in a route of this size
// (`ui.RoutablePage.ref_route_max_len`, which the branches page checks against this)
pub const branch_encoded_max_len = 512;

// whether url-encoding a ref name keeps the byte `c` as it is. any other byte
// becomes "%XX". the ui encodes route values with this set.
pub fn isUnreservedRefByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

// how many bytes `name` takes url-encoded
fn encodedLen(name: []const u8) usize {
    var len: usize = 0;
    for (name) |c| len += if (isUnreservedRefByte(c)) 1 else 3;
    return len;
}

// make `branch` the default, or protect or unprotect it, in the repo
// `identity` names, as one of its owners
fn changeBranch(ctx: *domain.Ctx, identity: []const u8, branch: []const u8, action: BranchAction) !void {
    const server = switch (ctx.host) {
        .server => |server| server,
        // a local repo's branches are the user's own git
        .local => return error.UnavailableHere,
    };
    const actor = try authorizeOwner(ctx, identity);
    const resolved = (try domain.resolveRepo(ctx, identity)) orelse return error.NotFound;
    const owner_id = actor.repo_user_id orelse unreachable;
    const repo_id = try threads.repoId(resolved);
    // only an existing branch can be the default or protected, and the pages
    // link to it, so its name must fit their routes
    if (action != .unprotect) {
        if (encodedLen(branch) > branch_encoded_max_len) return error.BranchNameTooLong;
        if (!try resolved.source.hasBranch(ctx.io, ctx.gpa, branch)) return error.UnknownBranch;
    }
    // the default branch is HEAD, which moves without an event
    if (action == .default) return try domain.withRepo(ctx, resolved, branch, pointHead);
    try evt.protectBranch(ctx.io, ctx.gpa, server.users_dir, &owner_id, &repo_id, branch, action == .protect, actor.author);
}

pub const Undo = struct {
    pub const tool_name = "undo";
    pub const hosts = domain.server_only;
    pub const tool_description = "Restore a repository to how it was before one of its transactions, undoing that transaction and every later one. Needs the owner role. Server only.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .index = "The index of the oldest transaction to undo, as the repository's undo history lists it.",
    };

    // "owner:name"
    repo: []const u8,
    // the oldest transaction to undo
    index: u64,

    pub fn run(self: Undo, ctx: *domain.Ctx) !void {
        // local git has no undo history, and local xit leaves undo to xit itself
        if (ctx.host != .server) return error.UnavailableHere;
        _ = try authorizeOwner(ctx, self.repo);
        const resolved = (try domain.resolveRepo(ctx, self.repo)) orelse return error.NotFound;
        try domain.withRepo(ctx, resolved, self.index, undo);
    }
};

// undo the open repo's history from the transaction `index` up
fn undo(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    index: u64,
) !void {
    // server repos are xit
    if (comptime repo_kind != .xit) unreachable;
    // a copy's history beneath its floor belongs to the repo it copied
    if (try copy.undoFloor(repo_opts, &repo.core)) |floor| if (index <= floor) return error.InvalidHistoryIndex;
    try repo.undo(ctx.io, index);
}

// point the open repo's HEAD at `branch`
fn pointHead(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    branch: []const u8,
) !void {
    try repo.resetAdd(ctx.io, .{ .ref = .{ .kind = .head, .name = branch } });
}

// the actor for a change to the repo `identity` names, which needs its owner role
fn authorizeOwner(ctx: *domain.Ctx, identity: []const u8) !domain.Actor {
    return switch (try ctx.authorize(identity, .owner, null)) {
        .actor => |actor| actor,
        .login_required => error.LoginRequired,
        .repo_not_found => error.NotFound,
        .forbidden => error.Forbidden,
    };
}

fn refresh(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    _: void,
) !void {
    try evt.consume(.local, .repo, repo_kind, repo_opts, ctx.io, ctx.gpa, repo, evt.events_ref, &.{});
    try pch.refreshBranches(.local, repo_kind, repo_opts, ctx.io, ctx.gpa, repo, null);
}

pub const Sync = struct {
    pub const tool_name = "sync";
    pub const hosts = domain.local_only;
    pub const tool_description = "Trade issues, patches and discussions with the local repository's remote: fetch and merge its events branch, then push the merged one back. Local only.";
    pub const tool_schema_notes = .{};

    pub const Result = struct {
        // the failure the remote itself reported, in its own words, or null
        // once synced. the sync stops there; what came before it stays.
        remote_failure: ?[]const u8 = null,
        // the stage that refused, with `remote_failure`
        failed_stage: ?Stage = null,
        // whether the remote's events were merged into the local repo and
        // consumed: a refused push or second fetch leaves that merge in place
        merged: bool,

        // fetch: fetching and merging the remote's events branch. push:
        // pushing the merged branch back. refetch: fetching it again after.
        pub const Stage = enum { fetch, push, refetch };

        // a sync that went through reports only that it did; the stage and
        // the merge say something only about a refused one
        pub fn jsonStringify(self: Result, jw: anytype) !void {
            if (self.remote_failure == null) return try jw.write(.{ .remote_failure = @as(?[]const u8, null) });
            try jw.write(.{ .remote_failure = self.remote_failure, .failed_stage = self.failed_stage, .merged = self.merged });
        }
    };

    // where a sync reports its progress text as the transfers go
    pub const Progress = struct {
        context: *anyopaque,
        text: *const fn (context: *anyopaque, text: []const u8) void,
    };

    pub fn run(self: Sync, ctx: *domain.Ctx) !Result {
        return try self.runWithProgress(ctx, null);
    }

    // `run`, reporting the transfers' progress text to `progress`
    pub fn runWithProgress(_: Sync, ctx: *domain.Ctx, progress: ?Progress) !Result {
        const src = switch (ctx.host) {
            .local => |src| src,
            // a server's repos are pushed to, not synced
            .server => return error.UnavailableHere,
        };
        var message: std.Io.Writer.Allocating = .init(ctx.gpa);
        defer message.deinit();
        const refused = switch (src.repo_kind) {
            inline else => |repo_kind| blk: {
                var any_repo = try rp.AnyRepo(repo_kind, .{ .ProgressCtx = SyncProgress }).open(ctx.io, ctx.gpa, src.localInitOpts());
                defer any_repo.deinit(ctx.io, ctx.gpa);
                break :blk switch (any_repo) {
                    inline else => |*repo| try sync(repo_kind, repo.self_repo_opts, ctx, repo, .{ .message = &message, .sink = progress }),
                };
            },
        };
        const stage = refused orelse return .{ .merged = true };
        return .{
            .remote_failure = try ctx.arena.allocator().dupe(u8, message.written()),
            .failed_stage = stage,
            // only the fetch comes before the merge
            .merged = stage != .fetch,
        };
    }
};

// the progress context xit calls during a sync's transfers. it keeps the
// latest text, which is the remote's own failure when one stops the transfer.
const SyncProgress = struct {
    message: *std.Io.Writer.Allocating,
    sink: ?Sync.Progress,

    pub fn run(self: SyncProgress, _: std.Io, event: rp.ProgressEvent) !void {
        switch (event) {
            .text => |value| {
                self.message.clearRetainingCapacity();
                try self.message.writer.writeAll(value);
                if (self.sink) |sink| sink.text(sink.context, value);
            },
            else => {},
        }
    }
};

// fetch and merge the remote's events branch into the open repo, consume it,
// push it back and fetch again. returns the stage the remote refused, whose
// text the progress context holds, or null once synced. any other failure
// after the merge is `SyncMergedNotPushed` or, once pushed,
// `SyncPushedNotRefetched`, since the repos changed.
fn sync(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    progress: SyncProgress,
) !?Sync.Result.Stage {
    const io = ctx.io;
    const allocator = ctx.gpa;
    const remote_name = (try eventsRemoteName(repo_kind, repo_opts, repo, io, allocator)) orelse return error.RemoteNotFound;
    defer allocator.free(remote_name);

    var config = try repo.listConfig(io, allocator);
    defer config.deinit();
    const configured_ssh = if (config.sections.get("core")) |core| core.get("sshcommand") else null;
    const ssh = if (configured_ssh) |command| if (command.len > 0) command else "ssh" else "ssh";
    const remote_section = try allocator.print("remote.{s}", .{remote_name});
    defer allocator.free(remote_section);
    const remote_config = config.sections.get(remote_section) orelse return error.RemoteNotFound;
    const fetch_url = remote_config.get("url") orelse return error.UrlNotFound;
    const push_url = remote_config.get("pushurl") orelse fetch_url;
    const loopback_opts = " -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null";
    const fetch_ssh_command = try allocator.print("{s}{s} -o BatchMode=yes -o LogLevel=QUIET", .{ ssh, if (isLoopbackSshUrl(fetch_url)) loopback_opts else "" });
    defer allocator.free(fetch_ssh_command);
    const push_ssh_command = try allocator.print("{s}{s} -o BatchMode=yes -o LogLevel=QUIET", .{ ssh, if (isLoopbackSshUrl(push_url)) loopback_opts else "" });
    defer allocator.free(push_ssh_command);
    const fetch_transport_opts: xit.net.Opts(repo_opts.ProgressCtx) = .{ .progress_ctx = progress, .wire = .{ .ssh = .{ .command = fetch_ssh_command } } };
    const push_transport_opts: xit.net.Opts(repo_opts.ProgressCtx) = .{ .progress_ctx = progress, .wire = .{ .ssh = .{ .command = push_ssh_command } } };

    const remote_ref: xit.ref.Ref = .{ .kind = .{ .remote = remote_name }, .name = evt.events_ref.name };
    const fetch_refspec = try allocator.print("+refs/heads/{s}:refs/remotes/{s}/{s}", .{ evt.events_ref.name, remote_name, evt.events_ref.name });
    defer allocator.free(fetch_refspec);
    var fetch_opts = fetch_transport_opts;
    fetch_opts.refspecs = &.{fetch_refspec};
    const message = progress.message;
    message.clearRetainingCapacity();
    evt.mergeEvents(repo_kind, repo_opts, io, allocator, repo, remote_ref, fetch_opts) catch |err| {
        if (err == error.ServerReportedError and message.written().len != 0) return .fetch;
        return err;
    };

    // the local repo holds the merge from here on
    var pushed = false;
    return pushAndRefetch(repo_kind, repo_opts, io, allocator, repo, remote_name, remote_ref, push_transport_opts, fetch_opts, message, &pushed) catch |err| {
        std.log.warn("sync failed after merging the remote's events: {t}", .{err});
        return if (pushed) error.SyncPushedNotRefetched else error.SyncMergedNotPushed;
    };
}

// the stages of a sync after its merge: consume it, push it back and fetch
// again. `pushed` is set once the push went through.
fn pushAndRefetch(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    remote_name: []const u8,
    remote_ref: xit.ref.Ref,
    push_transport_opts: xit.net.Opts(repo_opts.ProgressCtx),
    fetch_opts: xit.net.Opts(repo_opts.ProgressCtx),
    message: *std.Io.Writer.Allocating,
    pushed: *bool,
) !?Sync.Result.Stage {
    const local_oid = try repo.readRef(io, evt.events_ref);
    const remote_oid = try repo.readRef(io, remote_ref);
    try evt.consume(.local, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{});
    // neither side has events yet, so there is nothing to push
    if (local_oid == null and remote_oid == null) return null;

    const push_refspec = try allocator.print("refs/heads/{s}:refs/heads/{s}", .{ evt.events_ref.name, evt.events_ref.name });
    defer allocator.free(push_refspec);
    message.clearRetainingCapacity();
    repo.push(io, allocator, remote_name, push_refspec, false, push_transport_opts) catch |err| {
        if (err == error.ServerReportedError and message.written().len != 0) return .push;
        return err;
    };
    pushed.* = true;
    message.clearRetainingCapacity();
    repo.fetch(io, allocator, remote_name, fetch_opts) catch |err| {
        if (err == error.ServerReportedError and message.written().len != 0) return .refetch;
        return err;
    };
    return null;
}

// the remote a local repo syncs its events with: the first that has fetched
// the events branch, else the first configured, or null when it has none
pub fn eventsRemoteName(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    allocator: std.mem.Allocator,
) !?[]u8 {
    var remotes = try repo.listRemotes(io, allocator);
    defer remotes.deinit();
    const names = remotes.sections.keys();
    if (names.len == 0) return null;
    for (names) |name| {
        const remote_ref: xit.ref.Ref = .{ .kind = .{ .remote = name }, .name = evt.events_ref.name };
        if (try repo.readRef(io, remote_ref) != null) return try allocator.dupe(u8, name);
    }
    return try allocator.dupe(u8, names[0]);
}

// whether an ssh url names this machine, whose host key needn't be checked
fn isLoopbackSshUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    const host = switch (uri.host orelse return false) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "[::1]");
}
