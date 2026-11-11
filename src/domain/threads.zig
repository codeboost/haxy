//! thread and comment operations: issues, patches and discussions.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("../event.zig");
const pch = @import("../patch.zig");
const fork = @import("../fork.zig");
const domain = @import("../domain.zig");

// the description of every operation's `repo` field
pub const repo_note = "The repository as \"owner:name\", or \"\" in local mode.";

// the event kinds that are threads
pub const ThreadKind = enum {
    issue,
    patch,
    discuss,

    // the thread kind an event kind is, or null for one that isn't a thread
    pub fn fromEventKind(kind: evt.EventKind) ?ThreadKind {
        return switch (kind) {
            .issue => .issue,
            .patch => .patch,
            .discuss => .discuss,
            else => null,
        };
    }

    pub fn eventKind(self: ThreadKind) evt.EventKind {
        return switch (self) {
            .issue => .issue,
            .patch => .patch,
            .discuss => .discuss,
        };
    }
};

pub const CreateThread = struct {
    pub const tool_name = "create_thread";
    pub const tool_description = "Open a new issue, patch or discussion in a repository.";
    pub const tool_schema_notes = .{
        .repo = repo_note,
        .kind = "The kind of thread to open.",
        .title = "A title that isn't blank.",
        .labels = "Space-separated labels, each at most 64 bytes.",
        .body = "The thread's text, in markdown.",
        .target_branch = "Patches only: the branch the patch merges into.",
        .source_branch = "Patches only: the branch the patch proposes; null or omitted starts a draft in a fork of the repository instead, which is server only.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    kind: ThreadKind,
    title: []const u8,
    // space-separated
    labels: []const u8 = "",
    body: []const u8 = "",
    // patches only
    target_branch: []const u8 = "",
    // patches only: null starts a fork-backed draft (server only)
    source_branch: ?[]const u8 = null,

    pub const Result = struct { id: [evt.event_id_size * 2]u8 };

    pub fn run(self: CreateThread, ctx: *domain.Ctx) !Result {
        const actor = try authorizeThread(ctx, self.repo, self.kind);
        try checkFields(self.kind, self.title, self.labels);
        const resolved = (try domain.resolveRepo(ctx, self.repo)) orelse return error.NotFound;

        var id_bytes: [evt.event_id_size]u8 = undefined;
        ctx.io.random(&id_bytes);
        if (self.kind == .patch) {
            const id = std.fmt.bytesToHex(id_bytes, .lower);
            const source_branch = self.source_branch orelse {
                try startDraft(ctx, resolved, actor, id, self);
                return .{ .id = id };
            };
            try domain.withRepo(ctx, resolved, BranchPatchArgs{
                .id = id,
                .patch = .{ .title = self.title, .description = self.body, .labels = self.labels, .target_branch = self.target_branch, .source_branch = source_branch },
                .author = actor.author,
            }, writeBranchPatch);
            return .{ .id = id };
        }
        const event = evt.EventWithId{
            .id = std.fmt.bytesToHex(id_bytes, .lower),
            .timestamp = @intCast(ctx.now),
            .author = actor.author,
            .event = switch (self.kind) {
                .issue => .{ .issue = .{ .title = self.title, .description = self.body, .labels = self.labels } },
                .discuss => .{ .discuss = .{ .title = self.title, .description = self.body, .labels = self.labels } },
                .patch => unreachable,
            },
        };
        try domain.withRepo(ctx, resolved, event, consumeEvent);
        return .{ .id = event.id };
    }
};

// start a draft patch in a fork of the resolved repo, in the actor's user
// dir, which only a server has
fn startDraft(ctx: *domain.Ctx, resolved: domain.Resolved, actor: domain.Actor, id: [evt.event_id_size * 2]u8, create: CreateThread) !void {
    const server = switch (ctx.host) {
        .server => |server| server,
        .local => return error.UnavailableHere,
    };
    if (!evt.Patch.branchValid(create.target_branch) or !try resolved.source.hasBranch(ctx.io, ctx.gpa, create.target_branch)) return error.InvalidTargetBranch;
    const fork_path = fork.create(.{}, ctx.io, ctx.gpa, server.users_dir, .{
        .id = id,
        // a server actor always has both ids
        .user_id = actor.user_id orelse unreachable,
        .repo_id = try repoId(resolved),
        .repo_user_id = actor.repo_user_id orelse unreachable,
        .repo_name = resolved.record.event.name,
        .title = create.title,
        .description = create.body,
        .labels = create.labels,
        .target_branch = create.target_branch,
        .author = actor.author,
        .timestamp = @intCast(ctx.now),
    }) catch |err| switch (err) {
        // the branch went away since the check above
        error.TargetNotFound => return error.InvalidTargetBranch,
        else => |e| return e,
    };
    ctx.gpa.free(fork_path);
}

const BranchPatchArgs = struct {
    id: [evt.event_id_size * 2]u8,
    patch: evt.Patch,
    author: evt.CommitAuthor,
};

// capture the patch's source branch as its revision, on any host
fn writeBranchPatch(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    args: BranchPatchArgs,
) !void {
    try pch.writeBranchPatch(ctx.host.event(), repo_kind, repo_opts, ctx.io, ctx.gpa, repo, args.id, args.patch, null, args.author);
}

pub const CreateComment = struct {
    pub const tool_name = "create_comment";
    pub const tool_description = "Reply to an issue, patch or discussion, or to one of its comments.";
    pub const tool_schema_notes = .{
        .repo = repo_note,
        .kind = "The kind of the thread replied to.",
        .thread_id = "The thread's hex event id.",
        .parent_id = "The hex event id of the comment replied to; \"\" or omitted replies to the thread.",
        .body = "The comment's text, in markdown.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    kind: ThreadKind,
    // the thread's hex event id
    thread_id: []const u8,
    // the hex id of the comment replied to; "" replies to the thread
    parent_id: []const u8 = "",
    body: []const u8,

    pub const Result = struct { id: [evt.event_id_size * 2]u8 };

    pub fn run(self: CreateComment, ctx: *domain.Ctx) !Result {
        const actor = try authorizeThread(ctx, self.repo, self.kind);
        if (!evt.Comment.fieldsValid(self.body)) return error.InvalidBody;
        const resolved = (try domain.resolveRepo(ctx, self.repo)) orelse return error.NotFound;
        const thread_id = eventIdHex(self.thread_id) orelse return error.NotFound;
        const parent_id = if (self.parent_id.len == 0) thread_id else eventIdHex(self.parent_id) orelse return error.NotFound;
        return .{ .id = try domain.withRepo(ctx, resolved, CommentArgs{
            .kind = self.kind.eventKind(),
            .thread_id = thread_id,
            .parent_id = parent_id,
            .body = self.body,
            .author = actor.author,
        }, createComment) };
    }
};

const CommentArgs = struct {
    kind: evt.EventKind,
    thread_id: [evt.event_id_size * 2]u8,
    parent_id: [evt.event_id_size * 2]u8,
    body: []const u8,
    author: evt.CommitAuthor,
};

fn createComment(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    args: CommentArgs,
) ![evt.event_id_size * 2]u8 {
    return try evt.Comment.create(ctx.host.event(), repo_kind, repo_opts, ctx.io, ctx.gpa, repo, args.kind, &args.thread_id, &args.parent_id, args.body, args.author);
}

pub const SetThreadStatus = struct {
    pub const tool_name = "set_thread_status";
    pub const tool_description = "Close or reopen an issue or patch.";
    pub const tool_schema_notes = .{
        .repo = repo_note,
        .kind = "issue or patch; discussions have no status.",
        .thread_id = "The thread's hex event id.",
        .status = "The status to set: open or closed.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    kind: ThreadKind,
    // the thread's hex event id
    thread_id: []const u8,
    status: Status,

    pub const Status = enum { open, closed };

    pub fn run(self: SetThreadStatus, ctx: *domain.Ctx) !void {
        const actor = try authorizeThread(ctx, self.repo, self.kind);
        const resolved = (try domain.resolveRepo(ctx, self.repo)) orelse return error.NotFound;
        const id = evt.parseEventId(self.thread_id) catch return error.NotFound;
        if (!try domain.canModify(ctx, resolved, actor, self.kind.eventKind(), &id)) return error.Forbidden;
        try domain.withRepo(ctx, resolved, StatusArgs{
            .kind = self.kind,
            .id = id,
            .status = self.status,
            .author = actor.author,
        }, updateStatus);
    }
};

const StatusArgs = struct {
    kind: ThreadKind,
    id: [evt.event_id_size]u8,
    status: SetThreadStatus.Status,
    author: evt.CommitAuthor,
};

fn updateStatus(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    args: StatusArgs,
) !void {
    const host = ctx.host.event();
    switch (args.kind) {
        .issue => try evt.Issue.update(host, repo_kind, repo_opts, ctx.io, ctx.gpa, repo, &args.id, .{ .status = switch (args.status) {
            .open => .open,
            .closed => .closed,
        } }, args.author),
        .patch => try evt.Patch.update(host, repo_kind, repo_opts, ctx.io, ctx.gpa, repo, &args.id, .{ .status = switch (args.status) {
            .open => .open,
            .closed => .closed,
        } }, args.author),
        // discussions have no status
        .discuss => return error.NotFound,
    }
}

pub const EditThread = struct {
    pub const tool_name = "edit_thread";
    pub const tool_description = "Replace the title, labels and text of an issue, patch or discussion.";
    pub const tool_schema_notes = .{
        .repo = repo_note,
        .kind = "The kind of the thread edited.",
        .thread_id = "The thread's hex event id.",
        .title = "A title that isn't blank.",
        .labels = "Space-separated labels, each at most 64 bytes.",
        .body = "The thread's text, in markdown.",
        .target_branch = "Patches only: the branch the patch merges into.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    kind: ThreadKind,
    // the thread's hex event id
    thread_id: []const u8,
    title: []const u8,
    // space-separated
    labels: []const u8 = "",
    body: []const u8 = "",
    // patches only
    target_branch: []const u8 = "",

    pub fn run(self: EditThread, ctx: *domain.Ctx) !void {
        const actor = try authorizeThread(ctx, self.repo, self.kind);
        try checkFields(self.kind, self.title, self.labels);
        const resolved = (try domain.resolveRepo(ctx, self.repo)) orelse return error.NotFound;
        const id = evt.parseEventId(self.thread_id) catch return error.NotFound;
        // a server patch may be a draft in its author's fork
        if (self.kind == .patch and ctx.host == .server) {
            if (!evt.Patch.branchValid(self.target_branch) or !try resolved.source.hasBranch(ctx.io, ctx.gpa, self.target_branch)) return error.InvalidTargetBranch;
            if (try self.editDraft(ctx, resolved, actor, id)) return;
        }
        // a draft is its author's alone, which its edit above checks
        if (!try domain.canModify(ctx, resolved, actor, self.kind.eventKind(), &id)) return error.Forbidden;
        try domain.withRepo(ctx, resolved, EditArgs{ .edit = self, .id = id, .author = actor.author }, editThread);
    }

    // edit the draft `id` names when it is the actor's, or return false when
    // it is no draft of theirs
    fn editDraft(self: EditThread, ctx: *domain.Ctx, resolved: domain.Resolved, actor: domain.Actor, id: [evt.event_id_size]u8) !bool {
        return try domain.withRepo(ctx, resolved, DraftArgs{
            .input = .{
                .id = std.fmt.bytesToHex(id, .lower),
                // a server actor always has a user id
                .user_id = actor.user_id orelse unreachable,
                .repo_id = try repoId(resolved),
                .title = self.title,
                .labels = self.labels,
                .description = self.body,
                .target_branch = self.target_branch,
                .author = actor.author,
                .timestamp = @intCast(ctx.now),
            },
        }, editForkDraft);
    }
};

const DraftArgs = struct { input: pch.EditDraftInput };

// the fork copies its target's db, so it takes the target's hash, which the
// open target repo carries
fn editForkDraft(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    _: *rp.Repo(repo_kind, repo_opts),
    args: DraftArgs,
) !bool {
    // server repos are xit
    if (comptime repo_kind != .xit) unreachable;
    const server = switch (ctx.host) {
        .server => |server| server,
        .local => unreachable,
    };
    return try pch.editDraft(repo_opts, ctx.io, ctx.gpa, server.users_dir, ctx.admin orelse unreachable, args.input);
}

// a server repo's id, which names its directory
pub fn repoId(resolved: domain.Resolved) ![evt.event_id_size]u8 {
    return try evt.parseEventId(std.Io.Dir.path.basename(resolved.source.path));
}

const EditArgs = struct {
    edit: EditThread,
    id: [evt.event_id_size]u8,
    author: evt.CommitAuthor,
};

fn editThread(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    args: EditArgs,
) !void {
    const host = ctx.host.event();
    const edit = args.edit;
    switch (edit.kind) {
        .issue => try evt.Issue.update(host, repo_kind, repo_opts, ctx.io, ctx.gpa, repo, &args.id, .{ .fields = .{
            .title = edit.title,
            .labels = edit.labels,
            .description = edit.body,
        } }, args.author),
        .patch => try evt.Patch.update(host, repo_kind, repo_opts, ctx.io, ctx.gpa, repo, &args.id, .{ .fields = .{
            .title = edit.title,
            .labels = edit.labels,
            .description = edit.body,
            .target_branch = edit.target_branch,
        } }, args.author),
        .discuss => try evt.Discussion.update(host, repo_kind, repo_opts, ctx.io, ctx.gpa, repo, &args.id, edit.title, edit.labels, edit.body, args.author),
    }
}

pub const ResolveConflict = struct {
    pub const tool_name = "resolve_conflict";
    pub const tool_description = "Settle an issue or patch whose fields two merged event histories set apart, keeping our side except where the inputs say otherwise.";
    pub const tool_schema_notes = .{
        .repo = repo_note,
        .kind = "issue or patch; discussions have no field conflicts.",
        .thread_id = "The thread's hex event id.",
        .title = "The resolved title; null or omitted keeps the current one.",
        .labels = "The resolved space-separated labels; null or omitted keeps the current ones.",
        .hunks = "The resolutions of the description's conflicting hunks, in order; missing trailing ones keep our side.",
        .theirs = "Patches only: comma-separated fields to take from their side, of status, revision and target_branch.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    kind: ThreadKind,
    // the thread's hex event id
    thread_id: []const u8,
    // null keeps the live value
    title: ?[]const u8 = null,
    labels: ?[]const u8 = null,
    // the description's conflict hunks' resolutions, in chunk order
    hunks: []const []const u8 = &.{},
    // patches only: the fields taken from their side, comma-separated
    theirs: []const u8 = "",

    // the core settles the conflict entry with any write to the thread, so
    // nothing is left to report once this returns
    pub fn run(self: ResolveConflict, ctx: *domain.Ctx) !void {
        const actor = switch (try ctx.authorize(self.repo, .write, self.kind.eventKind())) {
            .actor => |actor| actor,
            .login_required => return error.LoginRequired,
            .repo_not_found => return error.NotFound,
            .forbidden => return error.Forbidden,
        };
        // discussions merge without field conflicts
        if (self.kind == .discuss) return error.NotFound;
        const resolved = (try domain.resolveRepo(ctx, self.repo)) orelse return error.NotFound;
        const id = evt.parseEventId(self.thread_id) catch return error.NotFound;
        // the update finds the thread before it checks the resolved fields,
        // so a missing thread is not found whatever its fields
        domain.withRepo(ctx, resolved, ResolveArgs{ .resolve = self, .id = id, .author = actor.author }, resolveThread) catch |err| switch (err) {
            error.InvalidFields => {
                if (self.title) |title| if (!evt.titleValid(title)) return error.InvalidTitle;
                // the title is valid or kept, so the labels are not
                return error.InvalidLabels;
            },
            else => |e| return e,
        };
    }
};

const ResolveArgs = struct {
    resolve: ResolveConflict,
    id: [evt.event_id_size]u8,
    author: evt.CommitAuthor,
};

fn resolveThread(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    args: ResolveArgs,
) !void {
    const host = ctx.host.event();
    const resolve = args.resolve;
    switch (resolve.kind) {
        .issue => try evt.Issue.update(host, repo_kind, repo_opts, ctx.io, ctx.gpa, repo, &args.id, .{ .resolve = .{
            .title = resolve.title,
            .labels = resolve.labels,
            .hunks = resolve.hunks,
        } }, args.author),
        .patch => try evt.Patch.update(host, repo_kind, repo_opts, ctx.io, ctx.gpa, repo, &args.id, .{ .resolve = .{
            .title = resolve.title,
            .labels = resolve.labels,
            .hunks = resolve.hunks,
            .theirs = resolve.theirs,
        } }, args.author),
        .discuss => unreachable,
    }
}

pub const EditComment = struct {
    pub const tool_name = "edit_comment";
    pub const tool_description = "Replace the text of a comment on an issue, patch or discussion.";
    pub const tool_schema_notes = .{
        .repo = repo_note,
        .kind = "The kind of the thread the comment is on.",
        .thread_id = "The thread's hex event id.",
        .comment_id = "The comment's hex event id.",
        .body = "The comment's new text, in markdown.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    kind: ThreadKind,
    // the thread's hex event id
    thread_id: []const u8,
    // the comment's hex event id
    comment_id: []const u8,
    body: []const u8,

    pub fn run(self: EditComment, ctx: *domain.Ctx) !void {
        const actor = try authorizeThread(ctx, self.repo, self.kind);
        const resolved = (try domain.resolveRepo(ctx, self.repo)) orelse return error.NotFound;
        const thread_id = eventIdHex(self.thread_id) orelse return error.NotFound;
        const comment_id = evt.parseEventId(self.comment_id) catch return error.NotFound;
        if (!try domain.canModify(ctx, resolved, actor, .comment, &comment_id)) return error.Forbidden;
        if (!evt.Comment.fieldsValid(self.body)) return error.InvalidBody;
        try domain.withRepo(ctx, resolved, CommentEditArgs{
            .kind = self.kind.eventKind(),
            .thread_id = thread_id,
            .comment_id = comment_id,
            .body = self.body,
            .author = actor.author,
        }, updateComment);
    }
};

const CommentEditArgs = struct {
    kind: evt.EventKind,
    thread_id: [evt.event_id_size * 2]u8,
    comment_id: [evt.event_id_size]u8,
    body: []const u8,
    author: evt.CommitAuthor,
};

fn updateComment(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    args: CommentEditArgs,
) !void {
    try evt.Comment.update(ctx.host.event(), repo_kind, repo_opts, ctx.io, ctx.gpa, repo, args.kind, &args.thread_id, &args.comment_id, args.body, args.author);
}

pub const RemoveThread = struct {
    pub const tool_name = "remove_thread";
    pub const tool_description = "Remove an issue, patch or discussion.";
    pub const tool_schema_notes = .{
        .repo = repo_note,
        .kind = "The kind of the thread removed.",
        .thread_id = "The thread's hex event id.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    kind: ThreadKind,
    // the thread's hex event id
    thread_id: []const u8,

    // what was removed: a thread, or the acting user's unpublished draft
    // with its fork
    pub const Result = enum { thread, draft };

    pub fn run(self: RemoveThread, ctx: *domain.Ctx) !Result {
        const actor = try authorizeThread(ctx, self.repo, self.kind);
        const resolved = (try domain.resolveRepo(ctx, self.repo)) orelse return error.NotFound;
        if (self.kind == .patch) {
            const id = evt.parseEventId(self.thread_id) catch return error.NotFound;
            if (try removeDraft(ctx, resolved, actor, id)) return .draft;
        }
        try removeAs(ctx, resolved, actor, self.kind, self.thread_id, self.kind.eventKind(), self.thread_id);
        return .thread;
    }
};

// remove the draft `id` names with its fork when it is the actor's own
// unpublished draft of the resolved repo, or return false when it is no such
// draft. a server actor's drafts live in their user repo.
fn removeDraft(ctx: *domain.Ctx, resolved: domain.Resolved, actor: domain.Actor, id: [evt.event_id_size]u8) !bool {
    const server = switch (ctx.host) {
        .server => |server| server,
        .local => return false,
    };
    const user_id = actor.user_id orelse unreachable;
    const record = (try evt.readForkById(ctx.io, ctx.gpa, ctx.arena, server.users_dir, &user_id, &id)) orelse return false;
    if (record.removed or record.event.stage != .draft) return false;
    if (!std.mem.eql(u8, &record.event.repo_id, &std.fmt.bytesToHex(try repoId(resolved), .lower))) return false;
    try fork.remove(ctx.io, ctx.gpa, server.users_dir, &user_id, &std.fmt.bytesToHex(id, .lower), actor.author);
    return true;
}

pub const RemoveComment = struct {
    pub const tool_name = "remove_comment";
    pub const tool_description = "Remove a comment from an issue, patch or discussion.";
    pub const tool_schema_notes = .{
        .repo = repo_note,
        .kind = "The kind of the thread the comment is on.",
        .thread_id = "The thread's hex event id.",
        .comment_id = "The comment's hex event id.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    kind: ThreadKind,
    // the thread's hex event id
    thread_id: []const u8,
    // the comment's hex event id
    comment_id: []const u8,

    pub fn run(self: RemoveComment, ctx: *domain.Ctx) !void {
        try removeInThread(ctx, self.repo, self.kind, self.thread_id, .comment, self.comment_id);
    }
};

pub const RemoveAttachment = struct {
    pub const tool_name = "remove_attachment";
    pub const tool_description = "Remove a file attached to an issue, patch or discussion.";
    pub const tool_schema_notes = .{
        .repo = repo_note,
        .kind = "The kind of the thread the file is attached to.",
        .thread_id = "The thread's hex event id.",
        .attachment_id = "The attachment's hex event id.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    kind: ThreadKind,
    // the thread's hex event id
    thread_id: []const u8,
    // the attachment's hex event id
    attachment_id: []const u8,

    pub fn run(self: RemoveAttachment, ctx: *domain.Ctx) !void {
        try removeInThread(ctx, self.repo, self.kind, self.thread_id, .attach, self.attachment_id);
    }
};

const RemoveArgs = struct {
    thread_kind: evt.EventKind,
    thread_id: [evt.event_id_size]u8,
    kind: evt.EventKind,
    id: [evt.event_id_size]u8,
    author: evt.CommitAuthor,
};

// remove the event `id` names, of `kind`, from the thread `thread_id` names:
// the thread itself, or a comment, attachment or assignment on it
fn removeInThread(ctx: *domain.Ctx, identity: []const u8, thread_kind: ThreadKind, thread_id: []const u8, kind: evt.EventKind, id: []const u8) !void {
    const actor = try authorizeThread(ctx, identity, thread_kind);
    const resolved = (try domain.resolveRepo(ctx, identity)) orelse return error.NotFound;
    try removeAs(ctx, resolved, actor, thread_kind, thread_id, kind, id);
}

// `removeInThread` for an actor already authorized in the resolved repo
fn removeAs(ctx: *domain.Ctx, resolved: domain.Resolved, actor: domain.Actor, thread_kind: ThreadKind, thread_id: []const u8, kind: evt.EventKind, id: []const u8) !void {
    const args = RemoveArgs{
        .thread_kind = thread_kind.eventKind(),
        .thread_id = evt.parseEventId(thread_id) catch return error.NotFound,
        .kind = kind,
        .id = evt.parseEventId(id) catch return error.NotFound,
        .author = actor.author,
    };
    if (!try domain.canModify(ctx, resolved, actor, kind, &args.id)) return error.Forbidden;
    try domain.withRepo(ctx, resolved, args, removeEvent);
}

fn removeEvent(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    args: RemoveArgs,
) !void {
    evt.removeInThread(ctx.host.event(), repo_kind, repo_opts, ctx.io, ctx.gpa, repo, args.thread_kind, &args.thread_id, args.kind, &args.id, args.author) catch |err| switch (err) {
        error.EventNotFound => return error.NotFound,
        else => |e| return e,
    };
}

pub const Attach = struct {
    // a reader can't come from json; the mcp adapter decodes the file into a
    // bounded buffer and calls this with a fixed reader instead
    pub const not_a_tool = true;

    // "owner:name"; "" in local mode
    repo: []const u8,
    kind: ThreadKind,
    // the thread's hex event id
    thread_id: []const u8,
    // the file's name, without a directory
    name: []const u8,
    // the file's declared size, which `reader` holds exactly
    size: u64,
    // the file's bytes, streamed into the repo without being buffered
    reader: *std.Io.Reader,

    pub const Result = struct { id: [evt.event_id_size * 2]u8 };

    pub fn run(self: Attach, ctx: *domain.Ctx) !Result {
        const actor = try authorizeThread(ctx, self.repo, self.kind);
        if (!evt.Attachment.nameValid(self.name)) return error.InvalidAttachmentName;
        if (self.size == 0) return error.AttachmentEmpty;
        if (self.size > evt.Attachment.max_size) return error.AttachmentTooLarge;
        const resolved = (try domain.resolveRepo(ctx, self.repo)) orelse return error.NotFound;
        const id = evt.parseEventId(self.thread_id) catch return error.NotFound;
        // an attachment changes the thread it hangs off
        if (!try domain.canModify(ctx, resolved, actor, self.kind.eventKind(), &id)) return error.Forbidden;
        return .{ .id = try domain.withRepo(ctx, resolved, AttachArgs{
            .kind = self.kind.eventKind(),
            .thread_id = std.fmt.bytesToHex(id, .lower),
            .blob = .{ .name = self.name, .size = self.size, .reader = self.reader },
            .author = actor.author,
        }, createAttachment) };
    }
};

const AttachArgs = struct {
    kind: evt.EventKind,
    thread_id: [evt.event_id_size * 2]u8,
    blob: evt.Blob,
    author: evt.CommitAuthor,
};

fn createAttachment(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    args: AttachArgs,
) ![evt.event_id_size * 2]u8 {
    return evt.Attachment.create(ctx.host.event(), repo_kind, repo_opts, ctx.io, ctx.gpa, repo, args.kind, &args.thread_id, args.blob, args.author) catch |err| switch (err) {
        error.TargetNotFound => return error.NotFound,
        else => |e| return e,
    };
}

pub const Assign = struct {
    pub const tool_name = "assign";
    pub const tool_description = "Assign someone to an issue, patch or discussion, by email or by user name.";
    pub const tool_schema_notes = .{
        .repo = repo_note,
        .kind = "The kind of the thread.",
        .thread_id = "The thread's hex event id.",
        .assignee = "An email, or on a server the name of a user.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    kind: ThreadKind,
    // the thread's hex event id
    thread_id: []const u8,
    // an email, or a user's name on a server
    assignee: []const u8,

    pub fn run(self: Assign, ctx: *domain.Ctx) !void {
        const actor = try authorizeThread(ctx, self.repo, self.kind);
        const resolved = (try domain.resolveRepo(ctx, self.repo)) orelse return error.NotFound;
        const id = evt.parseEventId(self.thread_id) catch return error.NotFound;
        if (!try domain.canModify(ctx, resolved, actor, self.kind.eventKind(), &id)) return error.Forbidden;
        const email = try domain.assigneeEmail(if (ctx.host == .local) null else ctx.moment, ctx.arena, self.assignee);
        try domain.withRepo(ctx, resolved, AssignArgs{
            .kind = self.kind.eventKind(),
            .thread_id = std.fmt.bytesToHex(id, .lower),
            .email = email,
            .author = actor.author,
        }, createAssignment);
    }
};

pub const Unassign = struct {
    pub const tool_name = "unassign";
    pub const tool_description = "Remove an assigned email from an issue, patch or discussion.";
    pub const tool_schema_notes = .{
        .repo = repo_note,
        .kind = "The kind of the thread.",
        .thread_id = "The thread's hex event id.",
        .email = "The assigned email to remove.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    kind: ThreadKind,
    // the thread's hex event id
    thread_id: []const u8,
    email: []const u8,

    pub fn run(self: Unassign, ctx: *domain.Ctx) !void {
        const actor = try authorizeThread(ctx, self.repo, self.kind);
        const resolved = (try domain.resolveRepo(ctx, self.repo)) orelse return error.NotFound;
        const id = evt.parseEventId(self.thread_id) catch return error.NotFound;
        // changing a thread's assignments is changing the thread
        if (!try domain.canModify(ctx, resolved, actor, self.kind.eventKind(), &id)) return error.Forbidden;
        try domain.withRepo(ctx, resolved, RemoveArgs{
            .thread_kind = self.kind.eventKind(),
            .thread_id = id,
            .kind = .assign,
            .id = evt.Assignment.idOf(&id, self.email),
            .author = actor.author,
        }, removeEvent);
    }
};

const AssignArgs = struct {
    kind: evt.EventKind,
    thread_id: [evt.event_id_size * 2]u8,
    email: []const u8,
    author: evt.CommitAuthor,
};

fn createAssignment(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    args: AssignArgs,
) !void {
    _ = evt.Assignment.create(ctx.host.event(), repo_kind, repo_opts, ctx.io, ctx.gpa, repo, args.kind, &args.thread_id, args.email, args.author) catch |err| switch (err) {
        // the email has whitespace in it or is too long
        error.InvalidFields => return error.NotAnEmail,
        else => |e| return e,
    };
}

// `text` as a hex event id, or null when it has the wrong length
fn eventIdHex(text: []const u8) ?[evt.event_id_size * 2]u8 {
    if (text.len != evt.event_id_size * 2) return null;
    return text[0 .. evt.event_id_size * 2].*;
}

// a thread's title isn't blank and each of its labels fits
fn checkFields(kind: ThreadKind, title: []const u8, labels: []const u8) !void {
    if (!evt.titleValid(title)) return error.InvalidTitle;
    const valid = switch (kind) {
        .issue => evt.Issue.fieldsValid(title, labels),
        .patch => evt.Patch.fieldsValid(title, labels),
        .discuss => evt.Discussion.fieldsValid(title, labels),
    };
    // the title is valid, so a label is too long
    if (!valid) return error.InvalidLabels;
}

// the actor for a write to a thread of `kind` in the repo `identity` names,
// which reading the tab allows
pub fn authorizeThread(ctx: *domain.Ctx, identity: []const u8, kind: ThreadKind) !domain.Actor {
    return switch (try ctx.authorize(identity, .read, kind.eventKind())) {
        .actor => |actor| actor,
        .login_required => error.LoginRequired,
        .repo_not_found => error.NotFound,
        .forbidden => error.Forbidden,
    };
}

fn consumeEvent(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    event: evt.EventWithId,
) !void {
    try evt.consume(ctx.host.event(), .repo, repo_kind, repo_opts, ctx.io, ctx.gpa, repo, evt.events_ref, &.{event});
}
