//! patch operations past a thread's own: publishing drafts, merging and
//! deleting forks.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("../event.zig");
const pch = @import("../patch.zig");
const fork = @import("../fork.zig");
const domain = @import("../domain.zig");
const threads = @import("threads.zig");

pub const PublishPatch = struct {
    pub const tool_name = "publish_patch";
    pub const hosts = domain.server_only;
    pub const tool_description = "Publish one of the acting user's draft patches to the repository it targets. Server only.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .patch_id = "The draft's hex event id.",
    };

    // "owner:name"
    repo: []const u8,
    // the draft's hex event id
    patch_id: []const u8,

    pub fn run(self: PublishPatch, ctx: *domain.Ctx) !void {
        // drafts live in forks, which only a server has
        if (ctx.host != .server) return error.UnavailableHere;
        const actor = try threads.authorizeThread(ctx, self.repo, .patch);
        const resolved = (try domain.resolveRepo(ctx, self.repo)) orelse return error.NotFound;
        const id = evt.parseEventId(self.patch_id) catch return error.NotFound;
        try domain.withRepo(ctx, resolved, PublishArgs{ .input = .{
            .id = std.fmt.bytesToHex(id, .lower),
            // a server actor always has a user id
            .user_id = actor.user_id orelse unreachable,
            .repo_id = try threads.repoId(resolved),
            .author = actor.author,
            .timestamp = @intCast(ctx.now),
        } }, publish);
    }
};

const PublishArgs = struct { input: pch.PublishInput };

// publish the draft from the actor's fork into the open target repo, which
// carries the hash the fork copied
fn publish(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    args: PublishArgs,
) !void {
    // server repos are xit
    if (comptime repo_kind != .xit) unreachable;
    pch.publish(repo_opts, ctx.io, ctx.gpa, ctx.host.event().server, ctx.admin orelse unreachable, repo, args.input) catch |err| switch (err) {
        // no draft of the actor's for this repo, or a published patch that
        // isn't theirs: to them there is nothing to publish
        error.InvalidPatchDraft, error.InvalidPatch => return error.NotFound,
        else => |e| return e,
    };
}

pub const MergePatch = struct {
    pub const tool_name = "merge_patch";
    pub const hosts = domain.server_only;
    pub const tool_description = "Merge an open patch into its target branch, as its commits or squashed into one. Server only.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .patch_id = "The patch's hex event id.",
        .mode = "source merges the patch's commits; squash merges them as one commit.",
    };

    // "owner:name"
    repo: []const u8,
    // the patch's hex event id
    patch_id: []const u8,
    mode: Mode = .source,

    pub const Mode = enum { source, squash };

    pub fn run(self: MergePatch, ctx: *domain.Ctx) !void {
        // a merge checks the cached mergeability a server keeps
        if (ctx.host != .server) return error.UnavailableHere;
        const actor = switch (try ctx.authorize(self.repo, .write, .patch)) {
            .actor => |actor| actor,
            .login_required => return error.LoginRequired,
            .repo_not_found => return error.NotFound,
            .forbidden => return error.Forbidden,
        };
        const resolved = (try domain.resolveRepo(ctx, self.repo)) orelse return error.NotFound;
        const id = evt.parseEventId(self.patch_id) catch return error.NotFound;
        try domain.withRepo(ctx, resolved, pch.MergeInput{
            .id = std.fmt.bytesToHex(id, .lower),
            .revision = switch (self.mode) {
                .source => .source,
                .squash => .squash,
            },
            .author = actor.author,
            .timestamp = @intCast(ctx.now),
        }, merge);
    }
};

// merge the patch into the open target repo and remove its fork
fn merge(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    input: pch.MergeInput,
) !void {
    // server repos are xit
    if (comptime repo_kind != .xit) unreachable;
    pch.mergeAndRemoveFork(repo_opts, ctx.io, ctx.gpa, ctx.host.event().server, repo, input) catch |err| switch (err) {
        // no patch, or a removed one
        error.InvalidPatch => return error.NotFound,
        else => |e| return e,
    };
}

pub const DeleteFork = struct {
    pub const tool_name = "delete_fork";
    pub const hosts = domain.server_only;
    pub const tool_description = "Permanently delete one of the acting user's forks with its draft or published patch's fork data. Server only.";
    pub const tool_schema_notes = .{
        .identity = "The fork as \"forker:name\", the acting user's name and the forked repository's name.",
        .fork_id = "The fork's hex id, which is its patch's id.",
        .confirm = "The fork's \"forker:name\" again, to confirm.",
        .password = "The acting user's password.",
    };

    // "forker:name", as the fork's header shows it
    identity: []const u8,
    // the fork's hex id, its patch's
    fork_id: []const u8,
    // the text typed to confirm, which must be `identity`
    confirm: []const u8,
    password: []const u8,

    pub fn run(self: DeleteFork, ctx: *domain.Ctx) !void {
        const server = switch (ctx.host) {
            .server => |server| server,
            // forks live in user dirs, which only a server has
            .local => return error.UnavailableHere,
        };
        const user_id = ctx.user_id orelse return error.LoginRequired;
        // the password as it is now, which may have changed since the context was built
        const user = try domain.currentUser(ctx);
        // the typed text is checked before the slow password check
        if (!std.mem.eql(u8, self.confirm, self.identity)) return error.WrongConfirm;
        if (!evt.User.verifyPassword(user.event.password_hash, self.password)) return error.WrongPassword;
        const parsed = evt.parseOwnerRepoPath(self.identity) orelse return error.NotFound;
        if (!std.mem.eql(u8, parsed.owner, user.event.name)) return error.Forbidden;
        const fork_id = evt.parseEventId(self.fork_id) catch return error.NotFound;
        // the fork is in the forker's user repo, so it is theirs when found there
        const record = (try evt.readForkById(ctx.io, ctx.gpa, ctx.arena, server.users_dir, &user_id, &fork_id)) orelse return error.NotFound;
        if (record.removed) return error.NotFound;
        // the confirmation names the fork by its repo, which the id must match
        if (!std.mem.eql(u8, record.event.repo_name, parsed.name)) return error.NotFound;
        try fork.remove(ctx.io, ctx.gpa, server.users_dir, &user_id, &std.fmt.bytesToHex(fork_id, .lower), .{ .name = user.event.name, .email = user.event.email });
    }
};
