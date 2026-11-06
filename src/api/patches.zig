//! the patch routes of the JSON API: one status's window of patches (open,
//! closed or merged), the labels they use, one patch with what its
//! proposal is (source, target, current revision, commit count, whether it
//! changes anything, mergeability) and where to review it, its comments, and
//! a patch revision's diff. every list and patch is read by the TUI's patches
//! tab (`ui.Repo.Patches.init`), so lists, counts, windows, search filters,
//! labels, revisions and mergeability are exactly the TUI's; see
//! api/thread.zig for the shapes threads share.
//!
//! reads only: writing patches is not in the API yet, so the list says
//! opening one is unavailable and the writes answer `unsupported`. what
//! the TUI lets anyone write on a patch's page goes through the shared
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
const api_attachments = @import("./attachments.zig");
const api_comments = @import("./comments.zig");
const api_diff = @import("./diff.zig");
const api_md = @import("./markdown.zig");
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
};

/// the patch route `path` names, or null when it names none
pub fn route(path: []const u8) ?Route {
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
    };
    switch (thread_route.resource) {
        .comments, .comment => return api_comments.handle(io, request, allocator, host, viewer, thread_route, query, comment_kind),
        .attachments, .attachment => return api_attachments.handle(io, request, allocator, host, viewer, thread_route, query, attachment_kind),
        // a patch's status is not written through the API yet
        .status => return api.respondError(request, allocator, .{ .code = .not_found, .message = "No API route matches this path." }, .{ .keep_alive = request.head.method == .GET or request.head.method == .HEAD }),
        .list, .labels, .thread => {},
    }
    const method = request.head.method;
    if (method != .GET and method != .HEAD) return unsupported(request, allocator);

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
fn catchUp(
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
fn readDetail(arena: *std.heap.ArenaAllocator, io: std.Io, opened: *api_thread.Opened, id: *const [evt.event_id_size]u8) !?[]const u8 {
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
                .actions = list_actions,
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
            try std.json.Stringify.value(try detail(aa, entry, session.data.host_kind, .{ .signed_in = opened.handle.viewer != null, .tab = viewer }), .{}, writer);
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

// what the viewer may do to the list: patches are opened in the TUI and
// Haxy's web pages only, for now
const list_actions: api_thread.ListActions = .{ .create = .{ .unavailable = .{ .code = .unsupported, .message = "Patches can't be opened from Haxy Hub yet." } } };

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

/// what the viewer may do to one patch through the API: attach a file
/// (`thread_write.attach`); its other writes come with #18-#20
const Actions = struct { attach: Availability };

/// one patch: its summary, its whole description (parsed by haxy's markdown
/// reader, as the TUI renders it), what it proposes, its attachments, and what
/// the viewer may do
const Detail = struct {
    summary: api_thread.Summary(evt.Patch.StatusKind),
    description: []const md.Block,
    description_text: []const u8,
    source: Source,
    target: Branch,
    revision: ?Revision,
    merged: ?Merged,
    // the target branch is at the revision's source commit already
    no_changes: bool,
    mergeability: Mergeability,
    review: Review,
    // every live attachment, oldest first, as the TUI lists them
    attachments: []const api_attachments.Item,
    actions: Actions,

    pub fn jsonStringify(self: Detail, json: *std.json.Stringify) std.Io.Writer.Error!void {
        try json.beginObject();
        inline for (@typeInfo(api_thread.Summary(evt.Patch.StatusKind)).@"struct".field_names) |name| {
            try json.objectField(name);
            try json.write(@field(self.summary, name));
        }
        try json.objectField("description");
        try json.write(api_md.Blocks{ .blocks = self.description });
        inline for (.{ "description_text", "source", "target", "revision", "merged", "no_changes", "mergeability", "review", "attachments" }) |name| {
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
        .target = try .init(aa, patch.target_branch),
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
            .fork => .{ .unavailable = .{ .code = .unsupported, .message = "This patch's commits are in its fork, which Haxy Hub can't browse yet." } },
            .none => .{ .unavailable = .{ .code = .unsupported, .message = if (patch.revision == null)
                "Nothing has been pushed to this patch yet."
            else
                "This patch's fork is gone, so its commits can't be shown." } },
        },
        .attachments = try api_attachments.items(aa, entry.attachments, .{ .viewer = viewer.tab, .signed_in = viewer.signed_in }),
        .actions = .{ .attach = api_thread.threadActions(.patch, .{ .may_write = entry.can_modify, .signed_in = viewer.signed_in }).attach },
    };
}

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
