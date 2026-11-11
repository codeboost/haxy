//! read operations, bridged over the per-tab loaders the pages use, so they
//! return the loaders' own data types.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("../event.zig");
const domain = @import("../domain.zig");
const ui = @import("../ui.zig");

const Issues = ui.Repo.Issues;

pub const ListIssues = struct {
    pub const tool_name = "list_issues";
    pub const tool_description = "List a repository's issues by status, newest first.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
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
        const window = issues.window(self.status).*;
        // the loader roots the named issue's own status, so a `from` in
        // another status leaves this window at its start
        if (self.from.len != 0 and (window.items.len == 0 or !std.mem.eql(u8, window.items[0].id, self.from))) return error.NotFound;
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
        const issues = try domain.withRepo(ctx, resolved, LoadArgs{
            .resolved = resolved,
            .identity = self.repo,
            .search = "",
            .selected_id = self.id,
            .comments_start = self.comments_from,
            .view = .open,
        }, loadIssues);
        return (issues.selectedThread() orelse return error.NotFound).*;
    }
};

// the repo `identity` names when the viewer may see it and its `kind` tab is
// on. a tab that is off doesn't exist.
fn resolveTab(ctx: *domain.Ctx, identity: []const u8, kind: evt.EventKind) !domain.Resolved {
    const resolved = (try domain.resolveRepo(ctx, identity)) orelse return error.NotFound;
    if (!resolved.hasTab(kind)) return error.NotFound;
    return resolved;
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
