//! thread and comment operations: issues, patches and discussions.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("../event.zig");
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
    pub const tool_description = "Open a new issue or discussion in a repository.";
    pub const tool_schema_notes = .{
        .repo = repo_note,
        .kind = "issue or discuss; patch is not available yet.",
        .title = "A title that isn't blank.",
        .labels = "Space-separated labels, each at most 64 bytes.",
        .body = "The thread's text, in markdown.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    kind: ThreadKind,
    title: []const u8,
    // space-separated
    labels: []const u8 = "",
    body: []const u8 = "",

    pub const Result = struct { id: [evt.event_id_size * 2]u8 };

    pub fn run(self: CreateThread, ctx: *domain.Ctx) !Result {
        // patches need a source and target branch or a fork, which come later
        if (self.kind == .patch) return error.UnavailableHere;
        const actor = try authorizeThread(ctx, self.repo, self.kind);
        if (!evt.titleValid(self.title)) return error.InvalidTitle;
        const valid = switch (self.kind) {
            .issue => evt.Issue.fieldsValid(self.title, self.labels),
            .discuss => evt.Discussion.fieldsValid(self.title, self.labels),
            .patch => unreachable,
        };
        // the title is valid, so a label is too long
        if (!valid) return error.InvalidLabels;
        const resolved = (try domain.resolveRepo(ctx, self.repo)) orelse return error.NotFound;

        var id_bytes: [evt.event_id_size]u8 = undefined;
        ctx.io.random(&id_bytes);
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

// `text` as a hex event id, or null when it has the wrong length
fn eventIdHex(text: []const u8) ?[evt.event_id_size * 2]u8 {
    if (text.len != evt.event_id_size * 2) return null;
    return text[0 .. evt.event_id_size * 2].*;
}

// the actor for a write to a thread of `kind` in the repo `identity` names,
// which reading the tab allows
fn authorizeThread(ctx: *domain.Ctx, identity: []const u8, kind: ThreadKind) !domain.Actor {
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
