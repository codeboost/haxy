//! read operations, bridged over the per-tab loaders the pages use, so they
//! return the loaders' own data types. each has a `runOpen` taking a repo the
//! caller already opened, so a page can compose them over one open repo; `run`
//! resolves the repo, makes the read's checks that need no repo, opens it and
//! calls `runOpen`, which makes those checks again.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("../event.zig");
const domain = @import("../domain.zig");
const ui = @import("../ui.zig");

const Issues = ui.Repo.Issues;
const Discussions = ui.Repo.Discussions;
const Patches = ui.Repo.Patches;
const Events = ui.Repo.Events;

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
        return try runResolved(ListIssues, self, ctx);
    }

    // what needs no repo: a tab that is off doesn't exist
    fn check(_: ListIssues, resolved: domain.Resolved) !void {
        try requireTab(resolved, .issue);
    }

    pub fn runOpen(
        self: ListIssues,
        ctx: *domain.Ctx,
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        repo: *rp.Repo(repo_kind, repo_opts),
        resolved: domain.Resolved,
    ) !Issues.Window {
        try self.check(resolved);
        var window = try Issues.readWindow(repo_kind, repo_opts, ctx.arena, repo, ctx.io, ctx.moment, self.search, self.status, self.from, tabViewer(ctx, resolved, .issue));
        // a search can leave `from` out of the window it roots
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

    pub fn run(self: GetIssue, ctx: *domain.Ctx) !Issues.IssueWithId {
        return try runResolved(GetIssue, self, ctx);
    }

    // what needs no repo: a tab that is off doesn't exist
    fn check(_: GetIssue, resolved: domain.Resolved) !void {
        try requireTab(resolved, .issue);
    }

    pub fn runOpen(
        self: GetIssue,
        ctx: *domain.Ctx,
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        repo: *rp.Repo(repo_kind, repo_opts),
        resolved: domain.Resolved,
    ) !Issues.IssueWithId {
        try self.check(resolved);
        return try withNotifyAction(ctx, resolved, try Issues.readThread(repo_kind, repo_opts, ctx.arena, repo, ctx.io, ctx.moment, self.id, self.comments_from, tabViewer(ctx, resolved, .issue)));
    }
};

pub const ListDiscussions = struct {
    pub const tool_name = "list_discussions";
    pub const tool_description = "List a repository's discussions, most recently active first, a window at a time; the window's next_id is the `from` of the next one.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .search = "Words to find, with label:x filters.",
        .from = "The id of the first discussion of the window to list; \"\" or omitted lists the first window.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    // decoded; the ui search syntax (words, label:x)
    search: []const u8 = "",
    // the id of the window's first discussion; "" for the first window
    from: []const u8 = "",

    pub fn run(self: ListDiscussions, ctx: *domain.Ctx) !Discussions.Window {
        return try runResolved(ListDiscussions, self, ctx);
    }

    // what needs no repo: a tab that is off doesn't exist
    fn check(_: ListDiscussions, resolved: domain.Resolved) !void {
        try requireTab(resolved, .discuss);
    }

    pub fn runOpen(
        self: ListDiscussions,
        ctx: *domain.Ctx,
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        repo: *rp.Repo(repo_kind, repo_opts),
        resolved: domain.Resolved,
    ) !Discussions.Window {
        try self.check(resolved);
        var window = try Discussions.readWindow(repo_kind, repo_opts, ctx.arena, repo, ctx.io, ctx.moment, self.search, self.from, tabViewer(ctx, resolved, .discuss));
        // a search can leave `from` out of the window it roots
        if (self.from.len != 0 and (window.items.len == 0 or !std.mem.eql(u8, window.items[0].id, self.from))) return error.NotFound;
        try setNotifyActions(ctx, resolved, .{&window});
        return window;
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

    pub fn run(self: GetDiscussion, ctx: *domain.Ctx) !Discussions.DiscussionWithId {
        return try runResolved(GetDiscussion, self, ctx);
    }

    // what needs no repo: a tab that is off doesn't exist
    fn check(_: GetDiscussion, resolved: domain.Resolved) !void {
        try requireTab(resolved, .discuss);
    }

    pub fn runOpen(
        self: GetDiscussion,
        ctx: *domain.Ctx,
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        repo: *rp.Repo(repo_kind, repo_opts),
        resolved: domain.Resolved,
    ) !Discussions.DiscussionWithId {
        try self.check(resolved);
        return try withNotifyAction(ctx, resolved, try Discussions.readThread(repo_kind, repo_opts, ctx.arena, repo, ctx.io, ctx.moment, self.id, self.comments_from, tabViewer(ctx, resolved, .discuss)));
    }
};

pub const ListPatches = struct {
    pub const tool_name = "list_patches";
    pub const tool_description = "List a repository's patches by view, newest first: open, closed, merged, the acting user's drafts, or conflicted.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .view = "Which patches: open, closed, merged, drafts (the acting user's unpublished drafts, which take no search) or conflicts. Local repos have no drafts, so their drafts window is always empty.",
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
        return try runResolved(ListPatches, self, ctx);
    }

    // what needs no repo: a tab that is off doesn't exist, and the drafts
    // window has no search to narrow it
    fn check(self: ListPatches, resolved: domain.Resolved) !void {
        try requireTab(resolved, .patch);
        if (self.view == .drafts and self.search.len != 0) return error.InvalidReadArguments;
    }

    pub fn runOpen(
        self: ListPatches,
        ctx: *domain.Ctx,
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        repo: *rp.Repo(repo_kind, repo_opts),
        resolved: domain.Resolved,
    ) !Patches.Window {
        try self.check(resolved);
        const viewer = tabViewer(ctx, resolved, .patch);
        const drafts = try draftsArgs(ctx, resolved);
        const list: Patches.List = switch (self.view) {
            .open => .{ .status = .open },
            .closed => .{ .status = .closed },
            .merged => .{ .status = .merged },
            .conflicts => .conflicts,
            // local mode has no drafts, so its drafts window is empty
            .drafts => return try listDrafts(self, ctx, repo_kind, repo_opts, repo, drafts),
        };
        var window = try Patches.readWindow(repo_kind, repo_opts, ctx.arena, repo, ctx.io, ctx.moment, drafts.users_dir, self.search, list, self.from, viewer);
        // a search can leave `from` out of the window it roots
        if (self.from.len != 0 and (window.items.len == 0 or !std.mem.eql(u8, window.items[0].id, self.from))) return error.NotFound;
        try setNotifyActions(ctx, resolved, .{&window});
        return window;
    }

    // the acting user's drafts. a draft lives in its fork, so it has no
    // notify button, as on the page.
    fn listDrafts(
        self: ListPatches,
        ctx: *domain.Ctx,
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        repo: *rp.Repo(repo_kind, repo_opts),
        drafts: DraftsArgs,
    ) !Patches.Window {
        const window = try Patches.readDraftsWindow(repo_kind, repo_opts, ctx.arena, ctx.io, ctx.moment, drafts.users_dir, drafts.owner, drafts.repo_id, self.from, repo);
        // a `from` that names none of the drafts leaves the window at its start
        if (self.from.len != 0 and (window.items.len == 0 or !std.mem.eql(u8, window.items[0].id, self.from))) return error.NotFound;
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

    pub fn run(self: GetPatch, ctx: *domain.Ctx) !Patches.PatchWithId {
        return try runResolved(GetPatch, self, ctx);
    }

    // what needs no repo: a tab that is off doesn't exist
    fn check(_: GetPatch, resolved: domain.Resolved) !void {
        try requireTab(resolved, .patch);
    }

    pub fn runOpen(
        self: GetPatch,
        ctx: *domain.Ctx,
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        repo: *rp.Repo(repo_kind, repo_opts),
        resolved: domain.Resolved,
    ) !Patches.PatchWithId {
        try self.check(resolved);
        const drafts = try draftsArgs(ctx, resolved);
        const patch = try Patches.readThread(repo_kind, repo_opts, ctx.arena, repo, ctx.io, ctx.moment, drafts.users_dir, drafts.owner, drafts.repo_id, self.id, self.comments_from, tabViewer(ctx, resolved, .patch));
        // a draft lives in its fork, so it has no notify button, as on the page
        if (patch.draft) return patch;
        return try withNotifyAction(ctx, resolved, patch);
    }
};

pub const ListEvents = struct {
    pub const tool_name = "list_events";
    pub const tool_description = "List the events in a repository's history, active or removed, most recently changed first, 20 at a time; needs write access. To page, pass the window's next id and kind as `from` and `from_kind`.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .view = "Which events: active or removed; omitted lists the active ones.",
        .from = "The hex id of the first event of the window to list; \"\" or omitted lists the first window.",
        .from_kind = "The kind of the event `from` names, as the previous window's next reports it; required with `from`.",
        .moment = "The index of a transaction in the repo's history (xit repos only): lists only the events it wrote, as they were then.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    view: View = .active,
    // the hex id of the window's first event; "" for the first window
    from: []const u8 = "",
    // the kind of the event `from` names, which the loader checks
    from_kind: ?evt.EventKind = null,
    // a transaction's index in the repo history
    moment: ?u64 = null,

    pub const View = enum { active, removed };

    pub fn run(self: ListEvents, ctx: *domain.Ctx) !Events.Window {
        return try runResolved(ListEvents, self, ctx);
    }

    // what needs no repo: the event history needs write access, like
    // pushing, and the page is not found below it. a window start names its
    // event by id and kind together.
    fn check(self: ListEvents, resolved: domain.Resolved) !void {
        if (!resolved.hasEvents()) return error.NotFound;
        if ((self.from.len == 0) != (self.from_kind == null)) return error.InvalidReadArguments;
    }

    pub fn runOpen(
        self: ListEvents,
        ctx: *domain.Ctx,
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        repo: *rp.Repo(repo_kind, repo_opts),
        resolved: domain.Resolved,
    ) !Events.Window {
        try self.check(resolved);
        const view: ui.RoutablePage.EventsView = switch (self.view) {
            inline else => |view| @field(ui.RoutablePage.EventsView, @tagName(view)),
        };
        // a sync failure is the terminal session's, which a read has none of
        const events = try Events.initStrict(repo_kind, repo_opts, ctx.arena, repo, ctx.io, ctx.moment, self.repo, resolved.record.event, view, self.from_kind, self.from, self.moment, ctx.host == .local, null);
        const window = switch (self.view) {
            .active => events.active,
            .removed => events.removed,
        };
        // the loader roots the named event's own view, and a moment leaves
        // its windows empty when the event isn't one the transaction wrote
        if (self.from.len != 0 and (events.view != view or window.events.len == 0 or !std.mem.eql(u8, window.events[0].id, self.from))) return error.NotFound;
        return window;
    }
};

// open the repo `op.repo` names and run `op` on it. what `op` denies without
// the repo it denies before opening it, so a denial never depends on storage;
// runOpen checks again for callers that opened the repo themselves.
fn runResolved(comptime Op: type, op: Op, ctx: *domain.Ctx) !OpenResult(Op) {
    const resolved = (try domain.resolveRepo(ctx, op.repo)) orelse return error.NotFound;
    try op.check(resolved);
    return try domain.withRepo(ctx, resolved, Opened(Op){ .op = op, .resolved = resolved }, Opened(Op).body);
}

// a read and its resolved repo, as `withRepo` hands them to the read's runOpen
fn Opened(comptime Op: type) type {
    return struct {
        op: Op,
        resolved: domain.Resolved,

        fn body(
            comptime repo_kind: rp.RepoKind,
            comptime repo_opts: rp.RepoOpts(repo_kind),
            ctx: *domain.Ctx,
            repo: *rp.Repo(repo_kind, repo_opts),
            args: @This(),
        ) !OpenResult(Op) {
            return try args.op.runOpen(ctx, repo_kind, repo_opts, repo, args.resolved);
        }
    };
}

// what a read's runOpen returns on success
fn OpenResult(comptime Op: type) type {
    const Returned = @TypeOf(@as(Op, undefined).runOpen(@as(*domain.Ctx, undefined), .xit, rp.RepoOpts(.xit){}, @as(*rp.Repo(.xit, .{}), undefined), @as(domain.Resolved, undefined)));
    return @typeInfo(Returned).error_union.payload;
}

// a tab that is off doesn't exist
fn requireTab(resolved: domain.Resolved, kind: evt.EventKind) !void {
    if (!resolved.hasTab(kind)) return error.NotFound;
}

// where the acting user's drafts of the resolved repo live: server only
const DraftsArgs = struct {
    users_dir: ?[]const u8 = null,
    owner: ?Patches.DraftsOwner = null,
    repo_id: ?[evt.event_id_size]u8 = null,
};

fn draftsArgs(ctx: *domain.Ctx, resolved: domain.Resolved) !DraftsArgs {
    return switch (ctx.host) {
        .local => .{},
        .server => |server| .{
            .users_dir = server.users_dir,
            .owner = if (ctx.user) |user| .{ .user_id = ctx.user_id orelse unreachable, .name = user.event.name } else null,
            .repo_id = try evt.parseEventId(std.Io.Dir.path.basename(resolved.source.path)),
        },
    };
}

// the acting user's notify buttons on the threads of the resolved repo's
// `windows`, as the page sets them. local mode has none.
fn setNotifyActions(ctx: *domain.Ctx, resolved: domain.Resolved, windows: anytype) !void {
    if (ctx.host != .server) return;
    const owner_id = try evt.parseEventId(&resolved.record.event.user_id);
    const repo_id = try evt.parseEventId(std.Io.Dir.path.basename(resolved.source.path));
    try domain.setNotifyActions(ctx, &owner_id, &repo_id, windows);
}

// `entry` with the acting user's notify button, as the page sets it
fn withNotifyAction(ctx: *domain.Ctx, resolved: domain.Resolved, entry: anytype) !@TypeOf(entry) {
    const items = [_]@TypeOf(entry){entry};
    var window: struct { items: []const @TypeOf(entry) } = .{ .items = &items };
    try setNotifyActions(ctx, resolved, .{&window});
    return window.items[0];
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
