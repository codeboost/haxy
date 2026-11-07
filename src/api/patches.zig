//! the patch routes of the JSON API: one status's window of patches (open,
//! closed or merged), the labels they use, one patch with what its
//! proposal is (source, target, current revision, commit count, whether it
//! changes anything, mergeability) and where to review it, its comments, and
//! a patch revision's diff. every list and patch is read by the TUI's patches
//! tab (`ui.Repo.Patches.init`), so lists, counts, windows, search filters,
//! labels, revisions and mergeability are exactly the TUI's; see
//! api/thread.zig for the shapes threads share.
//!
//! writes (#18): opening a branch-backed patch (from one existing branch
//! into another), editing its fields and target, closing or reopening it,
//! and removing it, through the operations the TUI and Haxy's forms use
//! (`thread_write.createBranchPatch`, `edit`, `setStatus`, `remove`). drafts
//! and fork-backed patches are opened elsewhere, and merging is in
//! api/patch_merge.zig.
//! what the TUI lets anyone write on a patch's page goes through the shared
//! thread routes: its comments (api/comments.zig), its attachments
//! (api/attachments.zig) and the viewer's notification state
//! (api/notifications.zig).
//!
//! a server names repos by owner and name; a local host serves only the repo
//! it opened, under /api/v1/repo/patches and /api/v1/repo/revisions.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const api_account = @import("./account.zig");
const api_attachments = @import("./attachments.zig");
const api_comments = @import("./comments.zig");
const api_diff = @import("./diff.zig");
const api_drafts = @import("./patch_drafts.zig");
const api_md = @import("./markdown.zig");
const api_patch_merge = @import("./patch_merge.zig");
const api_path = @import("./path.zig");
const api_refs = @import("./refs.zig");
const api_repo = @import("./repo.zig");
const api_thread = @import("./thread.zig");
const evt = @import("../event.zig");
const md = @import("../markdown.zig");
const pch = @import("../patch.zig");
const query_params = @import("./query.zig");
const srch_thrd = @import("../search_thread.zig");
const thread_write = @import("../thread_write.zig");
const ui = @import("../ui.zig");

const Patches = ui.Repo.Patches;

// a list page defaults to the TUI's window; clients may ask for up to this many
const max_page_size = 100;

pub const Route = union(enum) {
    // the patches' thread routes: lists, labels, one patch, its comments
    thread: api_thread.Route,
    // a patch revision's diff, `…/revisions/{id}/diff?path=&cursor=&page_size=`
    revision_diff: struct { target: api_repo.Route.Target, id: []const u8 },
    // merging a patch, `…/patches/{id}/merge`
    merge: api_patch_merge.Route,
};

/// the patch route `path` names, or null when it names none
pub fn route(path: []const u8) ?Route {
    if (api_patch_merge.route(path)) |matched| return .{ .merge = matched };
    if (api_thread.route(path, "patches")) |matched| return .{ .thread = matched };
    const target: api_repo.Route.Target, const tail = target: {
        const local_prefix = "/api/v1/repo/revisions/";
        if (std.mem.startsWith(u8, path, local_prefix)) break :target .{ .local, path[local_prefix.len..] };
        const prefix = "/api/v1/repos/";
        if (!std.mem.startsWith(u8, path, prefix)) return null;
        var segments = std.mem.splitScalar(u8, path[prefix.len..], '/');
        const owner = segments.next() orelse return null;
        const name = segments.next() orelse return null;
        if (owner.len == 0 or name.len == 0) return null;
        if (!std.mem.eql(u8, segments.next() orelse return null, "revisions")) return null;
        break :target .{ .{ .server = .{ .owner = owner, .name = name } }, segments.rest() };
    };
    // "<id>/diff"
    const diff_suffix = "/diff";
    if (!std.mem.endsWith(u8, tail, diff_suffix)) return null;
    const id = tail[0 .. tail.len - diff_suffix.len];
    if (id.len == 0 or std.mem.indexOfScalar(u8, id, '/') != null) return null;
    return .{ .revision_diff = .{ .target = target, .id = id } };
}

pub fn handle(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    host: api_repo.Host,
    // the logged-in viewer, or null when anonymous (always in local mode)
    viewer: ?[evt.event_id_size]u8,
    matched: Route,
    // the still-encoded query string
    query: []const u8,
) !void {
    const thread_route = switch (matched) {
        .thread => |thread_route| thread_route,
        .revision_diff => |diff| return handleRevisionDiff(io, request, allocator, host, viewer, diff.target, diff.id, query),
        .merge => |merge| return api_patch_merge.handle(io, request, allocator, host, viewer, merge),
    };
    switch (thread_route.resource) {
        .comments, .comment => return api_comments.handle(io, request, allocator, host, viewer, thread_route, query, comment_kind),
        .attachments, .attachment => return api_attachments.handle(io, request, allocator, host, viewer, thread_route, query, attachment_kind),
        .list, .labels, .thread, .status => {},
    }
    const method = request.head.method;
    const read_methods = method == .GET or method == .HEAD;
    const change: ?Change = switch (thread_route.resource) {
        .list => if (read_methods) null else if (method == .POST) .create else return api_thread.unsupported(request, allocator, "GET, HEAD, POST"),
        .labels => if (read_methods) null else return api_thread.unsupported(request, allocator, "GET, HEAD"),
        .thread => if (read_methods) null else if (method == .PATCH) .edit else if (method == .DELETE) .remove else return api_thread.unsupported(request, allocator, "GET, HEAD, PATCH, DELETE"),
        .status => if (method == .PUT) .set_status else return api_thread.unsupported(request, allocator, "PUT"),
        .comments, .comment, .attachments, .attachment => unreachable,
    };
    if (change) |value| return handleWrite(io, request, allocator, host, viewer, thread_route, value);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // the server's admin repo must outlive the session, whose moment reads from it
    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    var opened = (try api_thread.openRepo(io, request, allocator, &arena, host, viewer, thread_route.target, &admin_repo_maybe)) orelse return;
    // a repo whose patches are off has no patches tab, as in the TUI
    if (!ui.Repo.hasSection(.patches, opened.resolved.repo.event, opened.handle, opened.session.data.host_kind, opened.source.repo_kind))
        return api.respondError(request, allocator, patches_off, .{});

    const read = switch (try readRequest(aa, thread_route.resource, query)) {
        .ok => |read| read,
        .invalid => |err| return api.respondError(request, allocator, err, .{}),
    };

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    const source = opened.source;
    const gpa = allocator;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, gpa, source.localInitOpts());
            defer any_repo.deinit(io, gpa);
            switch (any_repo) {
                inline else => |*repo| {
                    if (opened.session.local != null) try catchUp(repo_kind, repo.self_repo_opts, io, gpa, source, repo);
                    const failure = try write(repo_kind, repo.self_repo_opts, &arena, repo, io, &opened, read, &body.writer);
                    if (failure) |err| return api.respondError(request, allocator, err, .{});
                },
            }
        },
    }
    return api.respondJson(request, body.written(), .{});
}

// local mode: bring the event db up to date with the events branch, and the
// branch patches with their branches, as each TUI page build does. both
// write events, so a git repo takes the events lock the API's writes take.
pub fn catchUp(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    gpa: std.mem.Allocator,
    source: ui.RepoSource,
    repo: *rp.Repo(repo_kind, repo_opts),
) !void {
    const locked = try thread_write.lockEvents(io, source);
    defer thread_write.unlockEvents(io, locked);
    try evt.consume(.local, .repo, repo_kind, repo_opts, io, gpa, repo, evt.events_ref, &.{});
    try pch.refreshBranches(.local, repo_kind, repo_opts, io, gpa, repo, null);
}

pub const patches_off: api.Error = .{ .code = .not_found, .message = "This repository doesn't use patches." };
pub const no_such_patch: api.Error = .{ .code = .not_found, .message = "There is no patch with this id." };

// a patch's comments (and its notifications), as the shared thread routes serve them
pub const comment_kind: api_comments.Kind = .{ .kind = .patch, .section = .patches, .noun = "patch", .plural = "patches", .off = patches_off, .no_such_thread = no_such_patch };

// a patch's attachments, as the shared attachment routes serve them
const attachment_kind: api_attachments.Kind = .{ .thread = comment_kind, .readDetail = readDetail };

// the patch `id` names as its own route answers it, or null when there is none
// (unknown, removed, or a draft)
pub fn readDetail(arena: *std.heap.ArenaAllocator, io: std.Io, opened: *api_thread.Opened, id: *const [evt.event_id_size]u8) !?[]const u8 {
    const aa = arena.allocator();
    var body: std.Io.Writer.Allocating = .init(aa);
    const hex = try aa.dupe(u8, &std.fmt.bytesToHex(id.*, .lower));
    const source = opened.source;
    const gpa = arena.child_allocator;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, gpa, source.localInitOpts());
            defer any_repo.deinit(io, gpa);
            switch (any_repo) {
                inline else => |*repo| {
                    if (opened.session.local != null) try catchUp(repo_kind, repo.self_repo_opts, io, gpa, source, repo);
                    if (try write(repo_kind, repo.self_repo_opts, arena, repo, io, opened, .{ .patch = hex }, &body.writer)) |_| return null;
                },
            }
        },
    }
    return body.written();
}

const stale_cursor: api.Error = .{
    .code = .validation,
    .message = "Check the paging parameters.",
    .field_errors = &.{.{ .field = "cursor", .message = "This cursor isn't one Haxy gave out for this list; start from the first page." }},
};

// what one request reads, with its parameters checked
const Read = union(enum) {
    list: struct {
        status: evt.Patch.StatusKind,
        // decoded
        search: []const u8,
        // the hex id the window starts at, "" for the first window
        cursor: []const u8,
        page_size: usize,
    },
    labels: struct { search: []const u8, page: query_params.Page },
    patch: []const u8,
};

fn readRequest(aa: std.mem.Allocator, resource: api_thread.Route.Resource, query: []const u8) !union(enum) { ok: Read, invalid: api.Error } {
    switch (resource) {
        .list => {
            const status_text = (query_params.param(aa, query, "status") catch |err| switch (err) {
                error.InvalidPercentEncoding => "",
                else => |e| return e,
            }) orelse "open";
            const status = std.meta.stringToEnum(evt.Patch.StatusKind, status_text) orelse
                return .{ .invalid = invalidField("status", "The status must be open, closed or merged.") };
            const search = switch (try searchParam(aa, query)) {
                .ok => |search| search,
                .invalid => |err| return .{ .invalid = err },
            };
            const cursor = (query_params.param(aa, query, "cursor") catch |err| switch (err) {
                error.InvalidPercentEncoding => return .{ .invalid = stale_cursor },
                else => |e| return e,
            }) orelse "";
            const page_size = switch (try query_params.pageSize(aa, query, .{ .default = Patches.page_size, .max = max_page_size })) {
                .ok => |size| size,
                .invalid => |err| return .{ .invalid = err },
            };
            return .{ .ok = .{ .list = .{ .status = status, .search = search, .cursor = cursor, .page_size = page_size } } };
        },
        .labels => {
            const search = switch (try searchParam(aa, query)) {
                .ok => |search| search,
                .invalid => |err| return .{ .invalid = err },
            };
            // every label in one page by default, as the TUI's labels view
            const page = switch (try query_params.Page.parse(aa, query, .{ .default = Patches.max_labels, .max = max_page_size })) {
                .ok => |page| page,
                .invalid => |err| return .{ .invalid = err },
            };
            return .{ .ok = .{ .labels = .{ .search = search, .page = page } } };
        },
        .thread => |encoded| return .{ .ok = .{ .patch = std.Uri.percentDecodeInPlace(try aa.dupe(u8, encoded)) } },
        .status, .comments, .comment, .attachments, .attachment => unreachable,
    }
}

// the decoded `search` parameter, "" when absent
fn searchParam(aa: std.mem.Allocator, query: []const u8) !union(enum) { ok: []const u8, invalid: api.Error } {
    const search = query_params.param(aa, query, "search") catch |err| switch (err) {
        error.InvalidPercentEncoding => return .{ .invalid = invalidField("search", "The search isn't validly encoded.") },
        else => |e| return e,
    };
    return .{ .ok = search orelse "" };
}

fn write(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    opened: *api_thread.Opened,
    read: Read,
    writer: *std.Io.Writer,
) !?api.Error {
    const aa = arena.allocator();
    const viewer = ui.Repo.tabViewer(opened.handle, opened.resolved.repo, .patch);
    const admin_moment = opened.session.haxy_moment;
    const identity = opened.resolved.identity;
    const repo_id = opened.resolved.repo_id;
    const session = &opened.session;
    switch (read) {
        .list => |list| {
            const view: ui.RoutablePage.PatchesView = switch (list.status) {
                .open => .open,
                .closed => .closed,
                .merged => .merged,
            };
            // the other statuses' windows are read only for their counts;
            // drafts are their author's, and not in the API yet
            const data = Patches.init(repo_kind, repo_opts, arena, repo, io, admin_moment, session, repo_id, identity, "", try routeSearch(aa, list.search), list.cursor, "", 0, "", view, viewer, .{ .shown = list.page_size, .others = 0, .drafts = false }) catch |err| switch (err) {
                // a cursor naming no patch the filters list
                error.NotFound => return stale_cursor,
                else => |e| return e,
            };
            // a cursor roots its own patch's status, which must be this list's
            if (list.cursor.len != 0) {
                const rooted = data.selectedThread() orelse return stale_cursor;
                if (rooted.record.event.status.kind() != list.status) return stale_cursor;
            }
            const window = data.window(list.status);
            const items = try aa.alloc(api_thread.Summary(evt.Patch.StatusKind), window.items.len);
            for (items, window.items) |*item, *entry| item.* = try summary(aa, entry, list.search);
            try std.json.Stringify.value(.{
                .status = list.status,
                .actions = api_thread.listActions(.patch, .{ .may_write = viewer != null, .signed_in = opened.handle.viewer != null }),
                // patches have no assignees, so an assignee filter lists nothing
                .filters = try api_thread.Filters.init(aa, list.search, false),
                .counts = .{ .open = api_thread.count(data.open), .closed = api_thread.count(data.closed), .merged = api_thread.count(data.merged) },
                .items = items,
                .page = .{
                    .has_more = window.next_id != null,
                    .next_cursor = window.next_id,
                    .count = api_thread.count(window.*),
                },
            }, .{}, writer);
        },
        .labels => |labels| {
            const data = try Patches.init(repo_kind, repo_opts, arena, repo, io, admin_moment, session, repo_id, identity, "", "", "", "", 0, "", .labels, viewer, .{ .shown = 0, .others = 0, .drafts = false });
            const all = data.labels;
            const start = @min(labels.page.start, all.len);
            const end = @min(start +| labels.page.limit, all.len);
            const items = try aa.alloc(api_thread.Link, end - start);
            for (items, all[start..end]) |*item, label| item.* = .{
                .name = label,
                .search = try srch_thrd.withFilter(aa, labels.search, srch_thrd.label_prefix, label),
            };
            try api.writePage(writer, items, .{
                .next_cursor = try query_params.Page.nextCursor(aa, if (end < all.len) end else null),
                // the labels view stops at its cap
                .count = if (all.len >= Patches.max_labels) .{ .at_least = all.len } else .{ .exact = all.len },
            });
        },
        .patch => |id| {
            // the patch's own status window, rooted at it; a removed or
            // unknown patch is in no window
            const data = Patches.init(repo_kind, repo_opts, arena, repo, io, admin_moment, session, repo_id, identity, "", "", id, "", 0, "", .description, viewer, .{ .shown = 1, .others = 0, .drafts = false }) catch |err| switch (err) {
                error.NotFound => return no_such_patch,
                else => |e| return e,
            };
            const entry = data.selectedThread() orelse return no_such_patch;
            var answer = try detail(aa, entry, session.data.host_kind, .{ .signed_in = opened.handle.viewer != null, .tab = viewer });
            answer.commands = try api_drafts.commandsOf(aa, session.data, entry);
            try std.json.Stringify.value(answer, .{}, writer);
        },
    }
    return null;
}

// a search as the TUI's routes carry it, percent-encoded (Patches.init decodes it)
fn routeSearch(aa: std.mem.Allocator, search: []const u8) ![]const u8 {
    return api_path.encode(aa, search);
}

// --- shapes ------------------------------------------------------------------

const Availability = api_thread.Availability;

/// a listed patch, in the shape every thread kind's lists share; its status
/// is its kind (a merged patch's merge is in its own route)
pub fn summary(aa: std.mem.Allocator, entry: *const Patches.Entry, search: []const u8) !api_thread.Summary(evt.Patch.StatusKind) {
    return .{
        .id = entry.id,
        .title = entry.record.event.title,
        .status = entry.record.event.status.kind(),
        .labels = try api_thread.labelLinks(aa, entry.record.event.labels, search),
        .author = .{ .author = entry.author },
        // patches have no assignees in haxy
        .assignees = &.{},
        .created_at = .{ .seconds = entry.record.created_timestamp },
        .comment_count = entry.comments.count,
        .conflicted = entry.conflicted,
    };
}

/// a branch as a response names it: for display, and as a `ref` parameter
const Branch = struct {
    name: []const u8,
    id: []const u8,

    fn init(aa: std.mem.Allocator, name: []const u8) !Branch {
        return .{ .name = try api_path.display(aa, name), .id = try (api_refs.Selection{ .branch = name }).id(aa) };
    }
};

/// the branch a patch goes to, with its tip as the read saw it (null when
/// the branch has none, or the patch was merged), which a merge sends back
const Target = struct {
    name: []const u8,
    id: []const u8,
    commit: ?[]const u8,
};

/// where a patch's commits come from: a branch of the repository, or a fork
/// (by its owner and name, null once the fork is gone)
const Source = union(enum) {
    branch: Branch,
    fork: ?struct { owner: []const u8, name: []const u8 },

    pub fn jsonStringify(self: Source, json: *std.json.Stringify) std.Io.Writer.Error!void {
        try json.beginObject();
        try json.objectField("kind");
        try json.write(@tagName(self));
        switch (self) {
            .branch => |branch| {
                try json.objectField("name");
                try json.write(branch.name);
                try json.objectField("id");
                try json.write(branch.id);
            },
            .fork => |fork| {
                try json.objectField("fork");
                try json.write(fork);
            },
        }
        try json.endObject();
    }
};

/// the revision a patch proposes: the commit it was based on and its source
/// commit, with the squashed commit that stands for them all
const Revision = struct {
    id: []const u8,
    source_commit: []const u8,
    squash_commit: []const u8,
    // null where the revision isn't in this repository (an open fork-backed
    // patch's), or it was based on a branch without commits
    base_commit: ?[]const u8,
    // from the base to the source commit, first parents only; null where
    // haxy didn't count them (a git repository, a long history)
    commit_count: ?u64,
};

const Merged = struct {
    method: evt.Patch.MergeRevision,
    // the revision recording what landed: the target before the merge and after
    revision: []const u8,
};

/// whether haxy offers merging the patch, and if so how each way of merging
/// it would go (`unknown` until haxy has checked it against the target's tip)
const Mergeability = union(enum) {
    available: pch.Mergeability,
    unavailable: struct { code: Availability.Reason, message: []const u8 },

    pub fn jsonStringify(self: Mergeability, json: *std.json.Stringify) std.Io.Writer.Error!void {
        try json.beginObject();
        try json.objectField("available");
        switch (self) {
            .available => |result| {
                try json.write(true);
                try json.objectField("source");
                try json.write(result.source);
                try json.objectField("squash");
                try json.write(result.squash);
            },
            .unavailable => |reason| {
                try json.write(false);
                try json.objectField("reason");
                try json.write(.{ .code = reason.code, .message = reason.message });
            },
        }
        try json.endObject();
    }
};

/// where to review the patch's code: the revision whose files and commits
/// (back to its base) to read, and the revision whose diff to read; or why
/// there is none to read here
const Review = union(enum) {
    available: struct { revision: []const u8, diff: []const u8 },
    unavailable: struct { code: Availability.Reason, message: []const u8 },

    pub fn jsonStringify(self: Review, json: *std.json.Stringify) std.Io.Writer.Error!void {
        try json.beginObject();
        try json.objectField("available");
        switch (self) {
            .available => |links| {
                try json.write(true);
                try json.objectField("revision");
                try json.write(links.revision);
                try json.objectField("diff");
                try json.write(links.diff);
            },
            .unavailable => |reason| {
                try json.write(false);
                try json.objectField("reason");
                try json.write(.{ .code = reason.code, .message = reason.message });
            },
        }
        try json.endObject();
    }
};

/// what the viewer may do to one patch through the API: change its fields,
/// close or reopen it, remove it, attach a file to it, merge it
const Actions = struct { edit: Availability, set_status: Availability, remove: Availability, attach: Availability, merge: Availability };

/// one patch: its summary, its whole description (parsed by haxy's markdown
/// reader, as the TUI renders it), what it proposes, its attachments, and what
/// the viewer may do
const Detail = struct {
    summary: api_thread.Summary(evt.Patch.StatusKind),
    description: []const md.Block,
    description_text: []const u8,
    source: Source,
    target: Target,
    revision: ?Revision,
    merged: ?Merged,
    // the target branch is at the revision's source commit already
    no_changes: bool,
    mergeability: Mergeability,
    review: Review,
    // what an edit replaces (`evt.Patch.contentRevision`), as 32 hex digits;
    // `revision` is the patch revision it proposes
    edit_revision: []const u8,
    // every live attachment, oldest first, as the TUI lists them
    attachments: []const api_attachments.Item,
    actions: Actions,
    // the git commands for a fork-backed patch's fork
    commands: []const api_drafts.Command = &.{},

    pub fn jsonStringify(self: Detail, json: *std.json.Stringify) std.Io.Writer.Error!void {
        try json.beginObject();
        inline for (@typeInfo(api_thread.Summary(evt.Patch.StatusKind)).@"struct".field_names) |name| {
            try json.objectField(name);
            try json.write(@field(self.summary, name));
        }
        try json.objectField("description");
        try json.write(api_md.Blocks{ .blocks = self.description });
        inline for (.{ "description_text", "source", "target", "revision", "merged", "no_changes", "mergeability", "review", "edit_revision", "attachments", "commands" }) |name| {
            try json.objectField(name);
            try json.write(@field(self, name));
        }
        try json.objectField("attachment_limits");
        try json.write(api_attachments.limits);
        try json.objectField("actions");
        try json.write(self.actions);
        try json.endObject();
    }
};

pub fn detail(aa: std.mem.Allocator, entry: *const Patches.Entry, host_kind: evt.HostKind, viewer: api_thread.ViewerRights) !Detail {
    const patch = &entry.record.event;
    const source: Source = if (patch.source_branch) |branch|
        .{ .branch = try .init(aa, branch) }
    else if (entry.fork_exists) fork: {
        // "owner:name", as fork urls name it
        const colon = std.mem.indexOfScalar(u8, entry.fork_identity, ':') orelse break :fork .{ .fork = null };
        break :fork .{ .fork = .{ .owner = entry.fork_identity[0..colon], .name = entry.fork_identity[colon + 1 ..] } };
    } else .{ .fork = null };
    return .{
        // a patch's own page extends no list's search
        .summary = try summary(aa, entry, ""),
        .description = (try md.parseText(aa, patch.description)).blocks,
        .description_text = patch.description,
        .source = source,
        .target = target: {
            const branch: Branch = try .init(aa, patch.target_branch);
            break :target .{ .name = branch.name, .id = branch.id, .commit = if (entry.target_oid.len == 0 or patch.status.kind() == .merged) null else entry.target_oid };
        },
        .revision = if (patch.revision) |*revision| .{
            .id = &revision.id,
            .source_commit = revision.source_oid,
            .squash_commit = revision.squash_oid,
            .base_commit = if (entry.base_oid.len == 0 or std.mem.allEqual(u8, entry.base_oid, '0')) null else entry.base_oid,
            .commit_count = revision.commit_count,
        } else null,
        .merged = switch (patch.status) {
            .merged => |*merged| .{ .method = merged.revision, .revision = &merged.patchrev_id },
            .open, .closed => null,
        },
        .no_changes = entry.no_changes,
        .mergeability = if (Patches.mergeBlock(entry.*, host_kind)) |block| .{ .unavailable = mergeUnavailable(block) } else .{ .available = entry.mergeability },
        .review = switch (Patches.review(entry)) {
            .revision => |revision| .{ .available = .{ .revision = revision.id, .diff = revision.diff_id } },
            .fork => .{ .unavailable = .{ .code = .unsupported, .message = "This patch's commits are in its fork; review them there." } },
            .none => .{ .unavailable = .{ .code = .unsupported, .message = if (patch.revision == null)
                "Nothing has been pushed to this patch yet."
            else
                "This patch's fork is gone, so its commits can't be shown." } },
        },
        .edit_revision = try aa.dupe(u8, &std.fmt.bytesToHex(evt.Patch.contentRevision(patch.*), .lower)),
        .attachments = try api_attachments.items(aa, entry.attachments, .{ .viewer = viewer.tab, .signed_in = viewer.signed_in }),
        .actions = actions(entry, host_kind, viewer),
    };
}

/// what the viewer may do to a patch: what they may do to any thread they
/// wrote or may write to (`api_thread.threadActions`), except that a merged
/// patch stays merged
pub fn actions(entry: *const Patches.Entry, host_kind: evt.HostKind, viewer: api_thread.ViewerRights) Actions {
    const shared = api_thread.threadActions(.patch, .{ .may_write = entry.can_modify, .signed_in = viewer.signed_in });
    const merged = entry.record.event.status.kind() == .merged;
    return .{
        .edit = shared.edit,
        .set_status = if (merged and shared.set_status == .available) merged_status else shared.set_status,
        .remove = shared.remove,
        .attach = shared.attach,
        .merge = api_patch_merge.availability(entry, host_kind, viewer),
    };
}

const merged_status: Availability = .{ .unavailable = .{ .code = .unsupported, .message = "A merged patch stays merged; it can't be closed or reopened." } };

/// why haxy doesn't offer merging a patch, as the conventions' availability
/// reasons put it
pub fn mergeUnavailable(block: Patches.MergeBlock) @FieldType(Mergeability, "unavailable") {
    return switch (block) {
        .local => .{ .code = .unsupported, .message = "Local mode doesn't merge patches; merge the branches with Git." },
        .not_open => .{ .code = .unsupported, .message = "Only open patches are merged." },
        .draft => .{ .code = .unsupported, .message = "A draft is merged only once it is published." },
        .no_source => .{ .code = .unsupported, .message = "This patch's fork is gone, so there is nothing to merge." },
        .no_revision => .{ .code = .unsupported, .message = "Nothing has been pushed to this patch yet." },
        .conflicted => .{ .code = .conflict, .message = "Concurrent edits to this patch conflict; resolve them before merging." },
    };
}

// --- writes -------------------------------------------------------------------
//
// every write resolves the repo as the viewer (one they can't read is not
// found), then authorizes them afresh, as the TUI and the web forms do
// (`ui.authorizeUser`: their role in the repo, then the patches tab's role),
// and writes through thread_write, which checks who may change an existing
// patch. local mode has no accounts and writes as its repo's owner.

const Change = enum { create, edit, set_status, remove };

/// `POST …/patches`: a new branch-backed patch from `source` into `target`,
/// both branch ref ids (`branch:<percent-encoded name>`, as answers name
/// them). `id` is optional: a client that chooses one (32 lowercase hex
/// digits) can retry without opening a second patch.
pub const CreateRequest = struct {
    id: []const u8,
    title: []const u8,
    labels: []const u8,
    description: []const u8,
    source: []const u8,
    target: []const u8,
};

/// `PATCH …/patches/{id}`: the patch's fields and target, replaced as of
/// `revision` (its `edit_revision`)
pub const EditRequest = struct {
    revision: []const u8,
    title: []const u8,
    labels: []const u8,
    description: []const u8,
    target: []const u8,
};

/// `PUT …/patches/{id}/status`
pub const StatusRequest = struct {
    status: []const u8,
};

const Write = union(Change) {
    create: CreateRequest,
    edit: EditRequest,
    set_status: StatusRequest,
    remove,
};

pub const change_forbidden: api.Error = .{ .code = .forbidden, .message = "Only the patch's author and the repository's writers can change it." };
const stale_revision: api.Error = .{
    .code = .conflict,
    .message = "This patch changed since you loaded it.",
    .field_errors = &.{.{ .field = "revision", .message = "Someone else changed this patch meanwhile. Load it again, then make your change." }},
};
const already_merged: api.Error = .{ .code = .conflict, .message = "This patch has been merged; it can't be closed or reopened, nor retargeted." };

/// the branch a ref id names (`branch:` and its name percent-encoded byte
/// for byte, as answers' `id`s are), or null when it isn't one
pub fn branchName(aa: std.mem.Allocator, id: []const u8) !?[]const u8 {
    const prefix = "branch:";
    if (!std.mem.startsWith(u8, id, prefix) or id.len == prefix.len) return null;
    const encoded = id[prefix.len..];
    const out = try aa.alloc(u8, encoded.len);
    var len: usize = 0;
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        out[len] = if (encoded[i] == '%') byte: {
            if (i + 2 >= encoded.len) return null;
            const hi = std.fmt.charToDigit(encoded[i + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(encoded[i + 2], 16) catch return null;
            i += 2;
            break :byte hi * 16 + lo;
        } else encoded[i];
        len += 1;
    }
    return out[0..len];
}

const choose_branch = "Choose one of the repository's branches.";

// why a branch field is refused
fn branchError(comptime field: []const u8, comptime message: []const u8) api.Error {
    return .{ .code = .validation, .message = "Check the highlighted fields.", .field_errors = &.{.{ .field = field, .message = message }} };
}

/// a refusal of the branches a patch proposes from and into, as the API
/// answers it, or null when `err` is no such refusal
pub fn branchesError(err: anyerror) ?api.Error {
    return switch (err) {
        error.InvalidSourceBranch => branchError("source", "There is no such branch. " ++ choose_branch),
        error.InvalidTargetBranch => branchError("target", "There is no such branch. " ++ choose_branch),
        error.SameBranch => branchError("target", "Choose another branch than the source."),
        error.UnrelatedBranches => branchError("target", "This branch shares no history with the source, so there is nothing to compare."),
        else => null,
    };
}

fn handleWrite(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    host: api_repo.Host,
    viewer: ?[evt.event_id_size]u8,
    matched: api_thread.Route,
    change: Change,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // the body is read before anything answers, so no answer leaves it unread
    const body: Write = switch (change) {
        .create => .{ .create = (try api_account.readBody(CreateRequest, request, allocator, &arena)) orelse return },
        .edit => .{ .edit = (try api_account.readBody(EditRequest, request, allocator, &arena)) orelse return },
        .set_status => .{ .set_status = (try api_account.readBody(StatusRequest, request, allocator, &arena)) orelse return },
        .remove => .remove,
    };

    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    var opened = (try api_thread.openRepo(io, request, allocator, &arena, host, viewer, matched.target, &admin_repo_maybe)) orelse return;
    if (!ui.Repo.hasSection(.patches, opened.resolved.repo.event, opened.handle, opened.session.data.host_kind, opened.source.repo_kind))
        return api.respondError(request, allocator, patches_off, .{});

    // the patch a thread route names: an id that isn't one names none
    const thread_id: ?[evt.event_id_size]u8 = switch (matched.resource) {
        .thread, .status => |encoded| evt.parseEventId(std.Uri.percentDecodeInPlace(try aa.dupe(u8, encoded))) catch return api.respondError(request, allocator, no_such_patch, .{}),
        .list, .labels => null,
        .comments, .comment, .attachments, .attachment => unreachable,
    };
    if (thread_id) |*id| {
        if (try readDetail(&arena, io, &opened, id) == null) return api.respondError(request, allocator, no_such_patch, .{});
    }

    const actor = switch (try api_thread.authorize(.patch, io, allocator, &arena, host, viewer, &opened)) {
        .actor => |actor| actor,
        .refused => |err| return api.respondError(request, allocator, err, .{}),
    };
    const event_host: evt.Host = switch (host) {
        .local => .local,
        .server => |server| .{ .server = .{ .users_dir = server.users_dir, .admin_repo_path = server.admin_repo_path } },
    };

    const failure: ?api.Error = switch (body) {
        .create => |fields| blk: {
            const chosen = api_thread.parseNewId(fields.id) orelse break :blk api_thread.invalidField("id", "Leave the id out, or send 32 lowercase hex digits.");
            const source_branch = try branchName(aa, fields.source) orelse break :blk branchError("source", choose_branch);
            const target_branch = try branchName(aa, fields.target) orelse break :blk branchError("target", choose_branch);
            var new_fields = try api_thread.bodyFields(aa, fields);
            new_fields.target_branch = target_branch;
            if (thread_write.checkFields(.patch, new_fields)) |field_failure| break :blk api_thread.fieldsError(field_failure);
            const id = chosen orelse random: {
                var bytes: [evt.event_id_size]u8 = undefined;
                io.random(&bytes);
                break :random bytes;
            };
            thread_write.createBranchPatch(event_host, io, allocator, opened.source, &id, new_fields, source_branch, actor.author) catch |err| switch (err) {
                error.IdTaken => break :blk api_thread.id_taken,
                else => |e| break :blk branchesError(e) orelse return e,
            };
            return respondDetail(request, allocator, &arena, io, &opened, &id, .created);
        },
        .edit => |fields| blk: {
            const revision = api_thread.parseRevision(fields.revision) orelse break :blk api_thread.invalidField("revision", "Send the edit_revision of the patch as you loaded it.");
            const target_branch = try branchName(aa, fields.target) orelse break :blk branchError("target", choose_branch);
            var new_fields = try api_thread.bodyFields(aa, fields);
            new_fields.target_branch = target_branch;
            if (thread_write.checkFields(.patch, new_fields)) |field_failure| break :blk api_thread.fieldsError(field_failure);
            thread_write.edit(event_host, io, allocator, opened.source, actor, .patch, &thread_id.?, new_fields, revision) catch |err| break :blk try writeError(err);
            break :blk null;
        },
        .set_status => |fields| blk: {
            const status = std.meta.stringToEnum(enum { open, closed }, fields.status) orelse break :blk invalidField("status", "The status must be open or closed.");
            thread_write.setStatus(evt.Patch, event_host, io, allocator, opened.source, actor, &thread_id.?, switch (status) {
                .open => .open,
                .closed => .closed,
            }) catch |err| break :blk try statusWriteError(err);
            break :blk null;
        },
        .remove => blk: {
            thread_write.remove(event_host, io, allocator, opened.source, actor, .patch, &thread_id.?, .patch, &thread_id.?) catch |err| break :blk try writeError(err);
            var out: std.Io.Writer.Allocating = .init(aa);
            try std.json.Stringify.value(.{ .id = std.fmt.bytesToHex(thread_id.?, .lower) }, .{}, &out.writer);
            return api.respondJson(request, out.written(), .{});
        },
    };
    if (failure) |err| return api.respondError(request, allocator, err, .{});
    return respondDetail(request, allocator, &arena, io, &opened, &thread_id.?, .ok);
}

// a thread_write refusal, as the API answers it
fn writeError(err: anyerror) !api.Error {
    if (branchesError(err)) |refused| return refused;
    return switch (err) {
        error.Forbidden => change_forbidden,
        error.NotFound => no_such_patch,
        error.Stale => stale_revision,
        error.PatchAlreadyMerged => already_merged,
        else => return err,
    };
}

const status_raced: api.Error = .{ .code = .conflict, .message = "This patch changed while its status was being set; load it again, then try again." };

/// a status change's refusal, as the API answers it: as any write's, except
/// that reopening a branch patch that changed meanwhile (which captures its
/// source only while the patch is as read) names no revision, since a status
/// change sends none
pub fn statusWriteError(err: anyerror) !api.Error {
    if (err == error.Stale) return status_raced;
    return writeError(err);
}

pub fn respondDetail(request: *std.http.Server.Request, allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator, io: std.Io, opened: *api_thread.Opened, id: *const [evt.event_id_size]u8, status: std.http.Status) !void {
    // the write landed; only a removal racing it leaves nothing to show
    const answer = (try readDetail(arena, io, opened, id)) orelse return api.respondError(request, allocator, no_such_patch, .{});
    return api.respondJson(request, answer, .{ .status = status });
}

// --- a revision's diff -------------------------------------------------------

fn handleRevisionDiff(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    host: api_repo.Host,
    viewer: ?[evt.event_id_size]u8,
    target: api_repo.Route.Target,
    encoded_id: []const u8,
    query: []const u8,
) !void {
    const method = request.head.method;
    if (method != .GET and method != .HEAD) return unsupported(request, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    // a revision is read like the `revision:` refs of the files and commits
    // routes: by anyone who may read the repository
    const opened = (try api_thread.openRepo(io, request, allocator, &arena, host, viewer, target, &admin_repo_maybe)) orelse return;

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    const source = opened.source;
    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{}).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| {
                    if (opened.session.local != null) try catchUp(repo_kind, repo.self_repo_opts, io, allocator, source, repo);
                    if (try api_diff.writeRevisionDiff(repo_kind, repo.self_repo_opts, &arena, repo, io, allocator, encoded_id, query, &body.writer)) |err|
                        return api.respondError(request, allocator, err, .{});
                },
            }
        },
    }
    return api.respondJson(request, body.written(), .{});
}

fn invalidField(comptime field: []const u8, comptime message: []const u8) api.Error {
    return .{
        .code = .validation,
        .message = "Check the request's parameters.",
        .field_errors = &.{.{ .field = field, .message = message }},
    };
}

fn unsupported(request: *std.http.Server.Request, allocator: std.mem.Allocator) !void {
    // a write's body goes unread, so the connection closes
    return api.respondError(request, allocator, .{ .code = .unsupported, .message = "This route only supports GET and HEAD." }, .{ .allow = "GET, HEAD", .keep_alive = false });
}
