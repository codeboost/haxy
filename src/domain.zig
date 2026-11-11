//! transport-neutral operations the TUI, the web UI and the MCP server share:
//! the context a call runs in, repo resolution, authorization and failure
//! classification.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("./event.zig");

const reads = @import("./domain/reads.zig");
pub const ListIssues = reads.ListIssues;
pub const GetIssue = reads.GetIssue;
pub const GetDiscussion = reads.GetDiscussion;
pub const ListPatches = reads.ListPatches;
pub const GetPatch = reads.GetPatch;
const repos = @import("./domain/repos.zig");
pub const RefreshLocal = repos.RefreshLocal;
pub const CreateRepo = repos.CreateRepo;
pub const UpdateRepoSettings = repos.UpdateRepoSettings;
pub const DeleteRepo = repos.DeleteRepo;
pub const Grant = repos.Grant;
pub const Revoke = repos.Revoke;
pub const Promote = repos.Promote;
pub const Demote = repos.Demote;
pub const ProtectBranch = repos.ProtectBranch;
pub const UnprotectBranch = repos.UnprotectBranch;
pub const SetDefaultBranch = repos.SetDefaultBranch;
pub const Undo = repos.Undo;
pub const Sync = repos.Sync;
pub const branch_encoded_max_len = repos.branch_encoded_max_len;
pub const isUnreservedRefByte = repos.isUnreservedRefByte;
pub const eventsRemoteName = repos.eventsRemoteName;
const notifications = @import("./domain/notifications.zig");
pub const Subscribe = notifications.Subscribe;
pub const Mute = notifications.Mute;
pub const ListNotifications = notifications.ListNotifications;
pub const MarkRead = notifications.MarkRead;
pub const Dismiss = notifications.Dismiss;
pub const setNotifyActions = notifications.setNotifyActions;
const users = @import("./domain/users.zig");
pub const RegisterUser = users.RegisterUser;
pub const UpdateUserSettings = users.UpdateUserSettings;
pub const AddKey = users.AddKey;
pub const RemoveKey = users.RemoveKey;
pub const DeleteUser = users.DeleteUser;
const threads = @import("./domain/threads.zig");
pub const ThreadKind = threads.ThreadKind;
pub const repo_note = threads.repo_note;
pub const CreateThread = threads.CreateThread;
pub const CreateComment = threads.CreateComment;
pub const SetThreadStatus = threads.SetThreadStatus;
pub const EditThread = threads.EditThread;
pub const ResolveConflict = threads.ResolveConflict;
pub const EditComment = threads.EditComment;
pub const RemoveThread = threads.RemoveThread;
pub const RemoveComment = threads.RemoveComment;
pub const RemoveAttachment = threads.RemoveAttachment;
pub const Attach = threads.Attach;
pub const Assign = threads.Assign;
pub const Unassign = threads.Unassign;
const patches = @import("./domain/patches.zig");
pub const PublishPatch = patches.PublishPatch;
pub const MergePatch = patches.MergePatch;
pub const DeleteFork = patches.DeleteFork;

// the host kinds an operation runs on, which one that runs on only one
// declares as `pub const hosts`, so an adapter can refuse it before preparing
// anything. the operation's own UnavailableHere check stays the rule.
pub const Hosts = []const evt.HostKind;
pub const server_only: Hosts = &.{.server};
pub const local_only: Hosts = &.{.local};

// where a context's repos live
pub const Host = union(evt.HostKind) {
    // the single repo `haxy` was started in
    local: RepoSource,
    server: Server,

    pub const Server = struct {
        admin_repo_path: []const u8,
        users_dir: []const u8,
    };

    // where this host's event writes go
    pub fn event(self: Host) evt.Host {
        return switch (self) {
            .local => .local,
            .server => |server| .{ .server = .{ .users_dir = server.users_dir, .admin_repo_path = server.admin_repo_path } },
        };
    }
};

// where an on-disk repo lives, for a page or an operation to open
pub const RepoSource = struct {
    path: []const u8,
    repo_kind: rp.RepoKind,
    // the user's global git config, so local mode picks up their identity and
    // their signing and ssh settings. null on the server paths, which must not
    // read whoever runs the server.
    global_config_path: ?[]const u8 = null,

    // snapshots can be read from any website, so they must not reveal where repos live on disk
    pub fn jsonStringify(self: RepoSource, jw: anytype) !void {
        try jw.write(.{ .path = "", .repo_kind = self.repo_kind });
    }

    pub fn localInitOpts(self: RepoSource) rp.InitOpts {
        return .{ .path = self.path, .global_config_path = self.global_config_path };
    }

    pub fn hasBranch(self: RepoSource, io: std.Io, allocator: std.mem.Allocator, branch: []const u8) !bool {
        if (!xit.ref.validateName(branch)) return false;
        return switch (self.repo_kind) {
            inline else => |repo_kind| blk: {
                var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, self.localInitOpts());
                defer any_repo.deinit(io, allocator);
                break :blk switch (any_repo) {
                    inline else => |*repo| (try repo.readRef(io, .{ .kind = .head, .name = branch })) != null,
                };
            },
        };
    }

    // whether the actor may change the event `id` names
    pub fn canModify(
        self: RepoSource,
        io: std.Io,
        allocator: std.mem.Allocator,
        actor: Actor,
        kind: evt.EventKind,
        id: *const [evt.event_id_size]u8,
    ) !bool {
        // a role that may change an event with no author needs no read
        if (actor.role.canModify(actor.author.email, null)) return true;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        return switch (self.repo_kind) {
            inline else => |repo_kind| blk: {
                var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, self.localInitOpts());
                defer any_repo.deinit(io, allocator);
                break :blk switch (any_repo) {
                    inline else => |*repo| actor.role.canModify(actor.author.email, try evt.readAuthorEmail(repo_kind, repo.self_repo_opts, io, allocator, &arena, repo, kind, id)),
                };
            },
        };
    }
};

// what an operation runs with. the caller owns the admin repo and the arena
// and keeps both alive for as long as the context.
pub const Ctx = struct {
    io: std.Io,
    // scratch; operations free what they take
    gpa: std.mem.Allocator,
    // results; owned by the caller, never reset by an operation
    arena: *std.heap.ArenaAllocator,
    host: Host,
    admin: ?*rp.Repo(.xit, evt.admin_repo_opts),
    // cursors into `admin`; null in local mode
    moment: ?evt.AdminDB.HashMap(.read_only),
    // the acting account, already checked active; null = logged out
    user_id: ?[evt.event_id_size]u8,
    // its record, loaded with the check, in `arena`
    user: ?evt.User.Record = null,
    now: i64,

    // a server context acting as `user_id`, which is dropped once its account
    // is removed
    pub fn initServer(
        io: std.Io,
        gpa: std.mem.Allocator,
        arena: *std.heap.ArenaAllocator,
        admin: *rp.Repo(.xit, evt.admin_repo_opts),
        users_dir: []const u8,
        user_id: ?[evt.event_id_size]u8,
        now: i64,
    ) !Ctx {
        const moment = try evt.currentMoment(evt.admin_repo_opts, admin);
        const user = if (user_id) |id| try activeUser(moment, arena, id) else null;
        return .{
            .io = io,
            .gpa = gpa,
            .arena = arena,
            .host = .{ .server = .{ .admin_repo_path = admin.core.work_path, .users_dir = users_dir } },
            .admin = admin,
            .moment = moment,
            .user_id = if (user != null) user_id else null,
            .user = user,
            .now = now,
        };
    }

    // a local context over the repo `src` names, which has no accounts
    pub fn initLocal(
        io: std.Io,
        gpa: std.mem.Allocator,
        arena: *std.heap.ArenaAllocator,
        src: RepoSource,
        now: i64,
    ) Ctx {
        return .{
            .io = io,
            .gpa = gpa,
            .arena = arena,
            .host = .{ .local = src },
            .admin = null,
            .moment = null,
            .user_id = null,
            .now = now,
        };
    }

    // the actor for a write to the repo `identity` names with at least
    // `min_role`, and in the `thread_kind` tab when there is one
    pub fn authorize(self: *Ctx, identity: []const u8, min_role: evt.Repo.Role, thread_kind: ?evt.EventKind) !Authorization {
        switch (self.host) {
            // local mode has no accounts, so whoever runs it owns the repo
            .local => |src| return .{ .actor = .{ .author = try localAuthor(src, self.io, self.gpa, self.arena), .role = .owner } },
            .server => |server| {
                const user_id = self.user_id orelse return .login_required;
                const user = self.user orelse unreachable;
                const moment = self.moment orelse unreachable;
                return try authorizeActive(self.io, self.gpa, moment, self.arena, server.users_dir, user_id, user, identity, min_role, thread_kind);
            },
        }
    }
};

// who a write acts as and the role they hold in its repo
pub const Actor = struct {
    author: evt.CommitAuthor,
    // local mode has no accounts, so it has no user id
    user_id: ?[evt.event_id_size]u8 = null,
    role: evt.Repo.Role,
    // the repo owner's id, which local mode lacks
    repo_user_id: ?[evt.event_id_size]u8 = null,
};

pub const Authorization = union(enum) {
    actor: Actor,
    login_required,
    repo_not_found,
    forbidden,
};

// the account `user_id` names, or null once it has been removed. a user id is
// checked here wherever one enters, so the role lookups can trust theirs.
pub fn activeUser(
    moment: evt.AdminDB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    user_id: [evt.event_id_size]u8,
) !?evt.User.Record {
    const user = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, arena, &user_id)) orelse return null;
    return if (user.removed) null else user;
}

// the acting account as the admin repo holds it now, not as the context saw it
// when it was built: a check of its password must see a change made since.
// one removed in between is logged out.
pub fn currentUser(ctx: *Ctx) !evt.User.Record {
    const user_id = ctx.user_id orelse return error.LoginRequired;
    const admin = ctx.admin orelse return error.LoginRequired;
    const moment = try evt.currentMoment(evt.admin_repo_opts, admin);
    return (try activeUser(moment, ctx.arena, user_id)) orelse error.LoginRequired;
}

// events created in local mode have no account behind them, so the commit
// author comes from the repo's config, which the global config feeds into.
pub const local_author_fallback = evt.CommitAuthor{ .name = "haxy", .email = "user@haxy" };

pub fn localAuthor(
    src: RepoSource,
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
) !evt.CommitAuthor {
    switch (src.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = rp.AnyRepo(repo_kind, .{}).open(io, allocator, src.localInitOpts()) catch return local_author_fallback;
            defer any_repo.deinit(io, allocator);

            switch (any_repo) {
                inline else => |*repo| {
                    var config = try repo.listConfig(io, allocator);
                    defer config.deinit();

                    const user = config.sections.get("user") orelse return local_author_fallback;
                    const name = user.get("name") orelse return local_author_fallback;
                    const email = user.get("email") orelse return local_author_fallback;
                    return .{
                        .name = try arena.allocator().dupe(u8, name),
                        .email = try arena.allocator().dupe(u8, email),
                    };
                },
            }
        },
    }
}

// a repo as the context's viewer may see it
pub const Resolved = struct {
    record: evt.Repo.Record,
    // the role the viewer holds in it. local mode owns its repo.
    role: evt.Repo.Role,
    // where it lives on disk
    source: RepoSource,

    // the event history needs write access, like pushing
    pub fn hasEvents(self: Resolved) bool {
        return self.role.atLeast(.write);
    }

    // whether the tab of a thread kind is on. a tab that is off doesn't exist.
    pub fn hasTab(self: Resolved, kind: evt.EventKind) bool {
        return self.record.event.threadRole(kind) != null;
    }
};

// the repo `identity` ("owner:name") names, or null when it doesn't exist or
// the viewer can't read it. local mode has one repo, named by "".
pub fn resolveRepo(ctx: *Ctx, identity: []const u8) !?Resolved {
    const aa = ctx.arena.allocator();
    switch (ctx.host) {
        .local => |src| {
            if (identity.len != 0) return null;
            return .{
                .record = .{
                    .event = .{
                        .user_id = @splat('0'),
                        .name = try aa.dupe(u8, std.Io.Dir.path.basename(src.path)),
                        .description = "",
                        // local mode shows every tab
                        .discuss_role = .read,
                        .issue_role = .read,
                        .patch_role = .read,
                    },
                },
                .role = .owner,
                // the caller may free its copy of the paths
                .source = .{
                    .path = try aa.dupe(u8, src.path),
                    .repo_kind = src.repo_kind,
                    .global_config_path = if (src.global_config_path) |config_path| try aa.dupe(u8, config_path) else null,
                },
            };
        },
        .server => |server| {
            const moment = ctx.moment orelse unreachable;
            const owner_repo = evt.parseOwnerRepoPath(identity) orelse return null;
            const found = (try evt.readRepoByOwnerAndName(ctx.io, ctx.gpa, ctx.arena, moment, server.users_dir, owner_repo.owner, owner_repo.name, ctx.user_id)) orelse return null;
            // a repo the viewer can't read doesn't exist to them
            const role = found.role orelse return null;
            const owner_id = try evt.parseEventId(&found.repo.event.user_id);
            return .{
                .record = found.repo,
                .role = role,
                .source = .{ .path = try evt.repoPath(aa, server.users_dir, &owner_id, &found.event_id), .repo_kind = .xit },
            };
        },
    }
}

// whether the user may write to the repo `identity` names with at least
// `min_role`, and to the `thread_kind` tab when there is one. kept for
// `Session.authorize`; a `Ctx` has its user loaded already.
pub fn authorizeUser(
    io: std.Io,
    moment: evt.AdminDB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    users_dir: []const u8,
    user_id: [evt.event_id_size]u8,
    identity: []const u8,
    min_role: evt.Repo.Role,
    thread_kind: ?evt.EventKind,
) !Authorization {
    const user = (try activeUser(moment, arena, user_id)) orelse return .login_required;
    return try authorizeActive(io, arena.child_allocator, moment, arena, users_dir, user_id, user, identity, min_role, thread_kind);
}

// `authorizeUser` for a user already checked active, whose record is `user`.
// `gpa` is scratch; the actor lands in `arena`.
fn authorizeActive(
    io: std.Io,
    gpa: std.mem.Allocator,
    moment: evt.AdminDB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    users_dir: []const u8,
    user_id: [evt.event_id_size]u8,
    user: evt.User.Record,
    identity: []const u8,
    min_role: evt.Repo.Role,
    thread_kind: ?evt.EventKind,
) !Authorization {
    const owner_repo = evt.parseOwnerRepoPath(identity) orelse return .repo_not_found;
    const repo = (try evt.readRepoByOwnerAndName(io, gpa, arena, moment, users_dir, owner_repo.owner, owner_repo.name, user_id)) orelse return .repo_not_found;
    // a repo the user can't read doesn't exist to them
    const role = repo.role orelse return .repo_not_found;
    if (!role.atLeast(min_role)) return .forbidden;
    if (thread_kind) |kind| {
        // a tab that is off doesn't exist
        const tab_role = repo.repo.event.threadRole(kind) orelse return .repo_not_found;
        if (!role.atLeast(tab_role)) return .forbidden;
    }
    return .{ .actor = .{
        .author = .{ .name = user.event.name, .email = user.event.email },
        .user_id = user_id,
        .role = role,
        .repo_user_id = try evt.parseEventId(&repo.repo.event.user_id),
    } };
}

// the email `text` assigns: itself when it holds an @, else the email of the
// active user it names. a null moment is local mode, which has no users to
// look up.
pub fn assigneeEmail(moment_maybe: ?evt.AdminDB.HashMap(.read_only), arena: *std.heap.ArenaAllocator, text: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.indexOfScalar(u8, trimmed, '@') != null) return trimmed;
    const moment = moment_maybe orelse return error.NotAnEmail;
    const user_id = (try evt.User.readIdByName(evt.AdminDB, evt.admin_repo_opts.hash, moment, trimmed)) orelse return error.UnknownAssignee;
    const user = (try activeUser(moment, arena, user_id)) orelse return error.UnknownAssignee;
    return user.event.email;
}

// whether the actor may change the event `id` names in the resolved repo: any
// event with the write role, otherwise only one they authored
pub fn canModify(ctx: *Ctx, resolved: Resolved, actor: Actor, kind: evt.EventKind, id: *const [evt.event_id_size]u8) !bool {
    return try resolved.source.canModify(ctx.io, ctx.gpa, actor, kind, id);
}

// the failures operations expect, which `classify` recognises. operations
// return inferred error sets (`!Result`), not `Error!Result`: those also carry
// the host's infrastructure errors (io, db, allocation), which are impractical
// to enumerate and which `classify` reports as `internal`.
pub const Error = error{
    // thread and comment fields
    InvalidTitle,
    InvalidLabels,
    InvalidBody,
    // patch branches
    InvalidTargetBranch,
    InvalidSourceBranch,
    SameBranch,
    UnrelatedBranches,
    // merges: the patch conflicts with its target, or changed since its check
    MergeConflict,
    PatchOutOfDate,
    // merges and publishing: the patch's state doesn't allow it
    PatchClosed,
    PatchAlreadyMerged,
    PatchNotPushed,
    // merges: the cached check or the fork's data isn't there to merge from
    MergeCheckUnavailable,
    PatchDataUnavailable,
    // repo and user names, emails and passwords
    NameEmpty,
    NameTooShort,
    NameTooLong,
    InvalidName,
    NameTaken,
    InvalidCopySource,
    EmailEmpty,
    EmailTaken,
    PasswordEmpty,
    PasswordMismatch,
    WrongPassword,
    // a delete's typed confirmation doesn't match what it deletes
    WrongConfirm,
    // protected branches
    BranchProtected,
    TooManyProtectedBranches,
    // branches settings: a branch the repo lacks
    UnknownBranch,
    BranchNameTooLong,
    // repo settings: a tab role no form offers
    InvalidTabRole,
    // ssh keys
    InvalidKey,
    UnsupportedKey,
    KeyAdded,
    TooManyKeys,
    // attachments
    InvalidAttachmentName,
    AttachmentEmpty,
    AttachmentTooLarge,
    // assignments
    UnknownAssignee,
    NotAnEmail,
    AlreadyAssigned,
    // repo members
    UnknownUser,
    AlreadyMember,
    // a row action on a user who holds no grant
    NotAMember,
    // undo: an index naming no transaction the repo may undo, under the
    // names xit gives them
    InvalidHistoryIndex,
    TransactionNotFound,
    // sync: the local repo has no remote, or one with no url
    RemoteNotFound,
    UrlNotFound,
    // authorization and capability
    NotFound,
    LoginRequired,
    Forbidden,
    UnavailableHere,
    // the write committed, but what follows it failed
    CommittedUnconsumed,
    MergedForkKept,
    PublishedForkKept,
    ForkRemovedDirKept,
    // a repo or account deletion whose record is gone but whose directory stays
    RepoRemovedDirKept,
    UserRemovedDirKept,
    // a sync that merged the remote's events locally, then failed before
    // its push went through, or after it
    SyncMergedNotPushed,
    SyncPushedNotRefetched,
    MutedNotDismissed,
    // a notification gained a newer child since the caller saw it
    NotificationOutOfDate,
};

// what kind of failure an error is, for an adapter to word or map
pub const Failure = struct {
    kind: Kind,
    // whether the same call may pass when tried again unchanged. no failure
    // is yet: creates, merges and sync are never retried automatically.
    retryable: bool = false,
    // whether the failure came after the repo was written
    changed: bool = false,

    pub const Kind = enum {
        invalid_input,
        // the input clashes with something that exists
        conflict,
        limit_reached,
        not_found,
        login_required,
        forbidden,
        // the operation exists, but not on this host
        unavailable_here,
        internal,
    };
};

// the failure kind of any error an operation returns: a member of `Error` maps
// to its kind, and every other error is the host failing, `internal`. nothing
// is retried automatically, so no failure is retryable yet.
pub fn classify(err: anyerror) Failure {
    const expected = asExpected(err) orelse return .{ .kind = .internal };
    const changed = switch (expected) {
        error.CommittedUnconsumed, error.MergedForkKept, error.PublishedForkKept, error.ForkRemovedDirKept, error.MutedNotDismissed => true,
        error.RepoRemovedDirKept, error.UserRemovedDirKept => true,
        error.SyncMergedNotPushed, error.SyncPushedNotRefetched => true,
        else => false,
    };
    return .{ .changed = changed, .kind = switch (expected) {
        error.InvalidTitle,
        error.InvalidLabels,
        error.InvalidBody,
        error.InvalidTargetBranch,
        error.InvalidSourceBranch,
        error.SameBranch,
        error.UnrelatedBranches,
        error.NameEmpty,
        error.NameTooShort,
        error.NameTooLong,
        error.InvalidName,
        error.InvalidCopySource,
        error.EmailEmpty,
        error.PasswordEmpty,
        error.PasswordMismatch,
        error.WrongConfirm,
        error.InvalidKey,
        error.UnsupportedKey,
        error.UnknownAssignee,
        error.NotAnEmail,
        error.InvalidAttachmentName,
        error.AttachmentEmpty,
        => .invalid_input,
        error.NameTaken, error.EmailTaken, error.BranchProtected, error.KeyAdded, error.AlreadyAssigned => .conflict,
        // the patch's code clashes with its target, or the patch moved under
        // the merge: both are the repo's state, which a person resolves
        error.MergeConflict, error.PatchOutOfDate => .conflict,
        // activity the caller hasn't seen keeps it unread, as on the page
        error.NotificationOutOfDate => .conflict,
        // a member action naming nobody
        error.UnknownUser => .invalid_input,
        // granting membership to someone who holds it
        error.AlreadyMember => .conflict,
        error.NotAMember => .not_found,
        // the input names no branch of the repo
        error.UnknownBranch => .invalid_input,
        // a branch name past the length a page can link to
        error.BranchNameTooLong => .invalid_input,
        error.InvalidTabRole => .invalid_input,
        // the history has no such transaction, or none an owner may undo:
        // like a missing thread, nothing the index names is there
        error.InvalidHistoryIndex, error.TransactionNotFound => .not_found,
        // the repo's config names no remote to sync with
        error.RemoteNotFound, error.UrlNotFound => .not_found,
        // the patch is closed, merged already or has no revision yet: its
        // state, not the input, stands in the way
        error.PatchClosed, error.PatchAlreadyMerged, error.PatchNotPushed => .conflict,
        // the server lacks what it needs to merge (a stale mergeability check,
        // a missing fork): nothing the caller's input can fix
        error.MergeCheckUnavailable, error.PatchDataUnavailable => .internal,
        error.TooManyProtectedBranches, error.TooManyKeys, error.AttachmentTooLarge => .limit_reached,
        error.NotFound => .not_found,
        error.LoginRequired => .login_required,
        error.Forbidden, error.WrongPassword => .forbidden,
        error.UnavailableHere => .unavailable_here,
        // a local git write whose event db failed after the commit, and a
        // merge whose fork removal failed after the merge committed
        error.CommittedUnconsumed,
        error.MergedForkKept,
        error.PublishedForkKept,
        error.ForkRemovedDirKept,
        error.MutedNotDismissed,
        => .internal,
        // a repo or account deletion that tombstoned the record but kept its directory
        error.RepoRemovedDirKept, error.UserRemovedDirKept => .internal,
        // a sync that failed, but not in the remote's words, after merging
        error.SyncMergedNotPushed, error.SyncPushedNotRefetched => .internal,
    } };
}

// `err` narrowed to `Error`, or null when it isn't one
fn asExpected(err: anyerror) ?Error {
    inline for (@typeInfo(Error).error_set.error_names.?) |name| {
        const expected = @field(Error, name);
        if (err == expected) return expected;
    }
    return null;
}

// open the resolved repo and call `body` with it, as
// `body(comptime repo_kind, comptime repo_opts, ctx, repo, args)`, where
// `args` has the type of body's last parameter (an anonymous literal won't
// coerce through `anytype`). the repo
// is closed when `body` returns, so its result must live in `ctx.arena`.
// operations that already hold an open repo call their body directly.
pub fn withRepo(ctx: *Ctx, resolved: Resolved, args: anytype, comptime body: anytype) !BodyResult(body, @TypeOf(args)) {
    const src = resolved.source;
    switch (src.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(ctx.io, ctx.gpa, src.localInitOpts());
            defer any_repo.deinit(ctx.io, ctx.gpa);
            switch (any_repo) {
                inline else => |*repo| return try body(repo_kind, repo.self_repo_opts, ctx, repo, args),
            }
        },
    }
}

// what `body` returns on success, which must not depend on the repo kind
fn BodyResult(comptime body: anytype, comptime Args: type) type {
    const Returned = @TypeOf(body(.xit, rp.RepoOpts(.xit){}, @as(*Ctx, undefined), @as(*rp.Repo(.xit, .{}), undefined), @as(Args, undefined)));
    return switch (@typeInfo(Returned)) {
        .error_union => |error_union| error_union.payload,
        else => Returned,
    };
}
