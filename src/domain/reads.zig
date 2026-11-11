//! read operations, bridged over the per-tab loaders the pages use, so they
//! return the loaders' own data types.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("../event.zig");
const domain = @import("../domain.zig");
const ui = @import("../ui.zig");

const Issues = ui.Repo.Issues;
const Discussions = ui.Repo.Discussions;
const Patches = ui.Repo.Patches;

pub const ListIssues = struct {
    pub const tool_name = "list_issues";
    pub const tool_description = "List a repository's issues by status, newest first.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .status = "Which issues: open or closed; omitted lists the open ones.",
        .search = "Words to find, with label:x and assignee:y filters.",
        .from = "The id of the first issue of the window to list; \"\" or omitted lists the first window.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    status: evt.Issue.Status = .open,
    // decoded; the ui search syntax (words, label:x, assignee:y)
    search: []const u8 = "",
    // the id of the window's first issue; "" for the first window
    from: []const u8 = "",

    pub fn run(self: ListIssues, ctx: *domain.Ctx) !Issues.Window {
        const resolved = try resolveTab(ctx, self.repo, .issue);
        const issues = try domain.withRepo(ctx, resolved, LoadArgs{
            .resolved = resolved,
            .identity = self.repo,
            .search = try escapePercent(ctx.arena.allocator(), self.search),
            .selected_id = self.from,
            .comments_start = 0,
            .view = switch (self.status) {
                .open => .open,
                .closed => .closed,
            },
        }, loadIssues);
        var window = issues.window(self.status).*;
        // the loader roots the named issue's own status, so a `from` in
        // another status leaves this window at its start
        if (self.from.len != 0 and (window.items.len == 0 or !std.mem.eql(u8, window.items[0].id, self.from))) return error.NotFound;
        try setNotifyActions(ctx, resolved, .{&window});
        return window;
    }
};

pub const GetIssue = struct {
    pub const tool_name = "get_issue";
    pub const tool_description = "Read one issue of a repository with a window of its comments.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .id = "The issue's hex event id.",
        .comments_from = "The index of the first comment in the returned window of comments.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    // the issue's hex event id
    id: []const u8,
    // the index of the comment window's first comment
    comments_from: usize = 0,

    // the window rooted at the issue, with the issue selected
    pub fn run(self: GetIssue, ctx: *domain.Ctx) !Issues.IssueWithId {
        const resolved = try resolveTab(ctx, self.repo, .issue);
        var issues = try domain.withRepo(ctx, resolved, LoadArgs{
            .resolved = resolved,
            .identity = self.repo,
            .search = "",
            .selected_id = self.id,
            .comments_start = self.comments_from,
            .view = .open,
        }, loadIssues);
        // the windows the selected issue is looked up in
        try setNotifyActions(ctx, resolved, .{ &issues.open, &issues.closed });
        return (issues.selectedThread() orelse return error.NotFound).*;
    }
};

pub const GetDiscussion = struct {
    pub const tool_name = "get_discussion";
    pub const tool_description = "Read one discussion of a repository with a window of its comments.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .id = "The discussion's hex event id.",
        .comments_from = "The index of the first comment in the returned window of comments.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    // the discussion's hex event id
    id: []const u8,
    // the index of the comment window's first comment
    comments_from: usize = 0,

    // the window rooted at the discussion, with the discussion selected
    pub fn run(self: GetDiscussion, ctx: *domain.Ctx) !Discussions.DiscussionWithId {
        const resolved = try resolveTab(ctx, self.repo, .discuss);
        var discussions = try domain.withRepo(ctx, resolved, DiscussionArgs{
            .resolved = resolved,
            .identity = self.repo,
            .selected_id = self.id,
            .comments_start = self.comments_from,
        }, loadDiscussions);
        try setNotifyActions(ctx, resolved, .{&discussions.recent});
        return (discussions.selectedThread() orelse return error.NotFound).*;
    }
};

pub const ListPatches = struct {
    pub const tool_name = "list_patches";
    pub const tool_description = "List a repository's patches by view, newest first: open, closed, merged, the acting user's drafts, or conflicted.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .view = "Which patches: open, closed, merged, drafts (the acting user's unpublished drafts, server only) or conflicts.",
        .search = "Words to find, with label:x filters.",
        .from = "The id of the first patch of the window to list; \"\" or omitted lists the first window.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    view: View = .open,
    // decoded; the ui search syntax (words, label:x)
    search: []const u8 = "",
    // the id of the window's first patch; "" for the first window
    from: []const u8 = "",

    pub const View = enum { open, closed, merged, drafts, conflicts };

    pub fn run(self: ListPatches, ctx: *domain.Ctx) !Patches.Window {
        const resolved = try resolveTab(ctx, self.repo, .patch);
        const patches = try domain.withRepo(ctx, resolved, PatchArgs{
            .resolved = resolved,
            .identity = self.repo,
            .search = try escapePercent(ctx.arena.allocator(), self.search),
            .selected_id = self.from,
            .comments_start = 0,
            .view = switch (self.view) {
                inline else => |view| @field(ui.RoutablePage.PatchesView, @tagName(view)),
            },
        }, loadPatches);
        var window = switch (self.view) {
            .open => patches.open,
            .closed => patches.closed,
            .merged => patches.merged,
            .drafts => patches.drafts,
            .conflicts => patches.conflicts,
        };
        // the loader roots the named patch's own window, so a `from` in
        // another view leaves this window at its start
        if (self.from.len != 0 and (window.items.len == 0 or !std.mem.eql(u8, window.items[0].id, self.from))) return error.NotFound;
        // a draft lives in its fork, so it has no notify button, as on the page
        if (self.view != .drafts) try setNotifyActions(ctx, resolved, .{&window});
        return window;
    }
};

pub const GetPatch = struct {
    pub const tool_name = "get_patch";
    pub const tool_description = "Read one patch of a repository, or one of the acting user's drafts, with a window of its comments.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .id = "The patch's hex event id.",
        .comments_from = "The index of the first comment in the returned window of comments.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    // the patch's hex event id
    id: []const u8,
    // the index of the comment window's first comment
    comments_from: usize = 0,

    // the window rooted at the patch, with the patch selected
    pub fn run(self: GetPatch, ctx: *domain.Ctx) !Patches.PatchWithId {
        const resolved = try resolveTab(ctx, self.repo, .patch);
        var patches = try domain.withRepo(ctx, resolved, PatchArgs{
            .resolved = resolved,
            .identity = self.repo,
            .search = "",
            .selected_id = self.id,
            .comments_start = self.comments_from,
            .view = .open,
        }, loadPatches);
        // a draft lives in its fork, so it has no notify button, as on the page
        try setNotifyActions(ctx, resolved, .{ &patches.open, &patches.closed, &patches.merged });
        return (patches.selectedThread() orelse return error.NotFound).*;
    }
};

const PatchArgs = struct {
    resolved: domain.Resolved,
    identity: []const u8,
    search: []const u8,
    selected_id: []const u8,
    comments_start: usize,
    view: ui.RoutablePage.PatchesView,
};

// the patches page's data for the args, read the way the page reads it. a
// server viewer sees their own drafts too.
fn loadPatches(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    args: PatchArgs,
) !Patches {
    const users_dir: ?[]const u8, const owner: ?Patches.DraftsOwner, const repo_id: ?[evt.event_id_size]u8 = switch (ctx.host) {
        .local => .{ null, null, null },
        .server => |server| .{
            server.users_dir,
            if (ctx.user) |user| .{ .user_id = ctx.user_id orelse unreachable, .name = user.event.name } else null,
            try evt.parseEventId(std.Io.Dir.path.basename(args.resolved.source.path)),
        },
    };
    return try Patches.init(repo_kind, repo_opts, ctx.arena, repo, ctx.io, ctx.moment, users_dir, owner, repo_id, args.identity, "", args.search, args.selected_id, "", args.comments_start, "", args.view, tabViewer(ctx, args.resolved, .patch));
}

const DiscussionArgs = struct {
    resolved: domain.Resolved,
    identity: []const u8,
    selected_id: []const u8,
    comments_start: usize,
};

// the discussions page's data for the args, read the way the page reads it
fn loadDiscussions(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    args: DiscussionArgs,
) !Discussions {
    return try Discussions.init(repo_kind, repo_opts, ctx.arena, repo, ctx.io, ctx.moment, args.identity, "", args.selected_id, "", args.comments_start, .recent, tabViewer(ctx, args.resolved, .discuss));
}

// the repo `identity` names when the viewer may see it and its `kind` tab is
// on. a tab that is off doesn't exist.
fn resolveTab(ctx: *domain.Ctx, identity: []const u8, kind: evt.EventKind) !domain.Resolved {
    const resolved = (try domain.resolveRepo(ctx, identity)) orelse return error.NotFound;
    if (!resolved.hasTab(kind)) return error.NotFound;
    return resolved;
}

// the acting user's notify buttons on the threads of the resolved repo's
// `windows`, as the page sets them. local mode has none.
fn setNotifyActions(ctx: *domain.Ctx, resolved: domain.Resolved, windows: anytype) !void {
    if (ctx.host != .server) return;
    const owner_id = try evt.parseEventId(&resolved.record.event.user_id);
    const repo_id = try evt.parseEventId(std.Io.Dir.path.basename(resolved.source.path));
    try domain.setNotifyActions(ctx, &owner_id, &repo_id, windows);
}

// `text` with its `%` escaped, so the loaders' percent-decoding gives it back
// unchanged. operation inputs are already decoded.
fn escapePercent(aa: std.mem.Allocator, text: []const u8) ![]const u8 {
    return try std.mem.replaceOwned(u8, aa, text, "%", "%25");
}

const LoadArgs = struct {
    resolved: domain.Resolved,
    identity: []const u8,
    search: []const u8,
    selected_id: []const u8,
    comments_start: usize,
    view: ui.RoutablePage.IssuesView,
};

// the issues page's data for the args, read the way the page reads it
fn loadIssues(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *rp.Repo(repo_kind, repo_opts),
    args: LoadArgs,
) !Issues {
    return try Issues.init(repo_kind, repo_opts, ctx.arena, repo, ctx.io, ctx.moment, args.identity, args.search, args.selected_id, "", args.comments_start, "", args.view, tabViewer(ctx, args.resolved, .issue));
}

// who a thread tab's entries are read for, as `Repo.init` builds it: null when
// logged out or below the tab's role. local mode owns everything.
fn tabViewer(ctx: *domain.Ctx, resolved: domain.Resolved, kind: evt.EventKind) ?ui.Viewer {
    const viewer: ui.Viewer = switch (ctx.host) {
        .local => return .{ .role = .owner, .email = "" },
        .server => .{ .role = resolved.role, .email = (ctx.user orelse return null).event.email },
    };
    const tab_role = resolved.record.event.threadRole(kind) orelse return null;
    return if (viewer.role.atLeast(tab_role)) viewer else null;
}
