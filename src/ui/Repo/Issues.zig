const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const diff3 = @import("../../diff3.zig");
const Comment = @import("Comment.zig");
const Attachment = @import("Attachment.zig");
const thread = ui.widget.thread;
const srch_thrd = @import("../../search_thread.zig");

const wasm = builtin.target.cpu.arch == .wasm32;

// how many issues one window shows before a "next" link appears.
pub const page_size = 20;

// how many labels the labels view shows at most.
pub const max_labels = 1000;

// one issue from the repo's consumed event database, with its hex event id
// (the id lives in the event envelope, not the payload).
pub const IssueWithId = struct {
    id: []const u8,
    record: evt.Issue.Record,
    // the creation commit's author
    author: ui.Author = .unknown,
    // whether the issue has an unresolved merge conflict
    conflicted: bool = false,
    comments: Comment.Window = .empty,
    attachments: []const Attachment.WithId = &.{},
    assignees: []const ui.Assignee = &.{},
    // whether the viewer may change the thread, computed here so the web ui has it
    can_modify: bool = false,
    // the viewer's notify button, null when hidden
    notify_action: ?ui.NotifyAction = null,
};

pub const Entry = IssueWithId;

// one side of a conflicted field: its value and who set it
pub const Side = struct {
    text: []const u8,
    author: ui.Author = .unknown,
};

pub const FieldConflict = struct {
    ours: Side,
    theirs: Side,
};

// the selected issue's conflict, read for the resolve view. ours is the live
// record; the chunks split the description against the merge base.
pub const Conflict = struct {
    title: ?FieldConflict = null,
    labels: ?FieldConflict = null,
    description: ?struct {
        chunks: []const diff3.Chunk,
        ours_author: ui.Author = .unknown,
        theirs_author: ui.Author = .unknown,
    } = null,
};

// one status's windowed listing.
pub const Window = struct {
    items: []const IssueWithId,
    // the id of the previous window's first issue, or null when this window
    // is already the first.
    prev_id: ?[]const u8,
    // the id of the next window's first issue, or null when this is the last
    // window.
    next_id: ?[]const u8,
    // how many issues the listing holds across all windows.
    count: usize,
    // whether a search stopped counting at its cap, so `count` is a floor.
    more: bool = false,

    pub const empty: Window = .{ .items = &.{}, .prev_id = null, .next_id = null, .count = 0 };
};

// "owner:name", so the view can build /owner:name/issues/... links.
identity: []const u8,
// the decoded query the lists are filtered to, or null when unfiltered.
search: ?[]const u8 = null,
// whether an assignee term names no user, which lists nothing
assignee_unknown: bool = false,
// the hex event id of the issue its status's window is rooted at ("" = the
// first window), mirrored into the url.
selected_id: []const u8,
// the comment shown in the selected issue's detail pane.
comment_id: []const u8,
// the selected issue's comment window (0 = the first window).
comments_start: usize,
// the selected comment and its immediate replies.
comment_page: ?Comment.Permalink = null,
// who the page is built for, null when logged out
viewer: ?ui.Viewer = null,
open: Window,
closed: Window,
// the conflicted issues' listing; its count also gates the conflicts tab.
conflicts: Window,
// the selected issue's conflict, set when the page shows the resolve view.
conflict: ?Conflict = null,
// the resolve view's comma-separated fields prefilled from their side,
// mirrored from the url.
theirs_picks: []const u8 = "",
// the view the page shows initially (a selected issue's status overrides the route's)
view: ui.RoutablePage.IssuesView,
// the /description page: the detail pane shows the selected issue's whole
// description behind a back link.
description_page: bool = false,
// every label in the repo, in sorted order, for the labels view.
labels: []const []const u8,
// the on-disk repo this page was read from, for the terminal submit path
// (the web posts the new-issue form to the issue route instead).
repo_source: ?ui.RepoSource = null,

const Self = @This();

pub const Event = evt.Issue;
pub const Status = evt.Issue.Status;
pub const ViewKind = ui.RoutablePage.IssuesView;
pub const thread_name = "issue";
pub const header_widget_name = "repo_issues_header";

pub fn statusKind(event: Event) Status {
    return event.status;
}

pub fn listRoute(identity: []const u8, status: Status, selected: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoIssuesRoute(identity, status, selected);
}

pub fn conflictsRoute(identity: []const u8, selected: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoIssuesConflictsRoute(identity, selected);
}

pub fn resolveRoute(identity: []const u8, selected: []const u8, picks: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoIssuesResolveRoute(identity, selected, picks);
}

// `status`'s windowed listing.
pub fn window(self: *const Self, status: evt.Issue.Status) *const Window {
    return switch (status) {
        .open => &self.open,
        .closed => &self.closed,
    };
}

// whether `field` (a field name or "d<n>" hunk name) is listed in the url's
// theirs: picks.
pub fn theirsPicked(self: *const Self, field: []const u8) bool {
    var it = std.mem.splitScalar(u8, self.theirs_picks, ',');
    while (it.next()) |pick| {
        if (std.mem.eql(u8, pick, field)) return true;
    }
    return false;
}

// the issue `selected_id` names, in whichever window holds it.
pub fn selectedThread(self: *const Self) ?*const IssueWithId {
    if (self.selected_id.len == 0) return null;
    for ([_]*const Window{ &self.open, &self.closed }) |win| {
        for (win.items) |*entry| {
            if (std.mem.eql(u8, entry.id, self.selected_id)) return entry;
        }
    }
    return null;
}

// an empty listing, for the wasm / no-repo paths. `search` is decoded.
pub fn emptyResult(aa: std.mem.Allocator, identity: []const u8, search: []const u8, selected_id: []const u8, comment_id: []const u8, comments_start: usize, theirs_picks: []const u8, view: ui.RoutablePage.IssuesView) !Self {
    return .{
        .identity = try aa.dupe(u8, identity),
        .search = if (search.len == 0) null else try aa.dupe(u8, search),
        .selected_id = try aa.dupe(u8, selected_id),
        .comment_id = try aa.dupe(u8, comment_id),
        .comments_start = comments_start,
        .open = .empty,
        .closed = .empty,
        .conflicts = .empty,
        .theirs_picks = try aa.dupe(u8, theirs_picks),
        // a description url shows a status list, the issue's own status
        // picking it once the issue is read; conflicts and resolve urls also
        // start there, upgraded by init when the conflict data exists.
        .view = switch (view) {
            .description, .conflicts, .resolve => .open,
            else => view,
        },
        .description_page = view == .description,
        .labels = &.{},
    };
}

// read one window per status of an opened repo's issues (filtered to the
// search when set), ordered by creation (newest first). the window of
// the issue `selected_id` names starts at it ("" = the beginning). a git repo reads the
// event db next to it (synced from the events branch on each page build); a
// xit repo reads its own db.
pub fn init(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    // the admin db's moment, for resolving author emails to user names (null
    // in local mode, which has no users)
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    identity: []const u8,
    search: []const u8,
    selected_id: []const u8,
    comment_id: []const u8,
    comments_start: usize,
    theirs_picks: []const u8,
    view: ui.RoutablePage.IssuesView,
    viewer: ?ui.Viewer,
) !Self {
    var empty = try emptyResult(arena.allocator(), identity, search, selected_id, comment_id, comments_start, theirs_picks, view);
    // the early returns below still let the viewer write
    empty.viewer = viewer;

    // an explicitly named issue that doesn't exist is a bad url (NotFound ->
    // 404); the bare route falls through to an empty listing.
    const rooted = empty.selected_id.len != 0;

    // a repo with no consumed events has no moment yet.
    const gpa = arena.child_allocator;
    var event_db = try thread.EventDb(repo_kind, repo_opts).open(io, gpa, repo);
    defer event_db.deinit(io, gpa);
    const haxy_moment = switch (event_db.moment(repo)) {
        .none => return empty,
        .no_events => {
            if (rooted) return error.NotFound;
            return empty;
        },
        .ok => |moment| moment,
    };

    const terms = try readSearch(repo_opts.hash, arena, admin_moment, haxy_moment, empty.search orelse "");
    empty.assignee_unknown = terms.assignee_unknown;

    const tables = (try thread.Tables(Self, repo_opts.hash).read(haxy_moment)) orelse {
        if (rooted) return error.NotFound;
        return empty;
    };

    // a named issue roots its own status's window at itself (the conflicts
    // view's window instead); the other windows start at the beginning.
    var resolved_view = empty.view;
    var open_root: ?[]const u8 = null;
    var closed_root: ?[]const u8 = null;
    var conflicts_root: ?[]const u8 = null;
    var conflict_data: ?Conflict = null;
    const thread_comments_start = if (empty.comment_id.len == 0) comments_start else 0;
    const selected: ?Selected = if (rooted) try loadThread(repo_kind, repo_opts, arena, repo, io, admin_moment, tables, terms, empty.selected_id, view, thread_comments_start, viewer) else null;
    if (selected) |thread_selected| {
        const status = thread_selected.entry.record.event.status;
        if (view == .conflicts) {
            conflicts_root = thread_selected.order_key;
        } else {
            switch (status) {
                .open => open_root = thread_selected.order_key,
                .closed => closed_root = thread_selected.order_key,
            }
            // form urls keep their view; otherwise the issue's status picks it.
            if (view != .edit and view != .new_comment and view != .edit_comment and view != .remove) resolved_view = switch (status) {
                .open => .open,
                .closed => .closed,
            };
            // a resolve url shows the resolve view only while the issue still
            // has a conflict entry; otherwise the status list stands.
            conflict_data = thread_selected.conflict;
            if (conflict_data != null) resolved_view = .resolve;
        }
    }

    const selected_entry: ?*const IssueWithId = if (selected) |*thread_selected| &thread_selected.entry else null;
    const open_window = try loadWindow(repo_opts.hash, arena, admin_moment, tables, terms, .{ .status = .open }, open_root, selected_entry, viewer);
    const closed_window = try loadWindow(repo_opts.hash, arena, admin_moment, tables, terms, .{ .status = .closed }, closed_root, selected_entry, viewer);
    const conflicts_window = try loadWindow(repo_opts.hash, arena, admin_moment, tables, terms, .conflicts, conflicts_root, selected_entry, viewer);
    if (view == .conflicts and conflicts_window.count > 0) resolved_view = .conflicts;

    const comment_page = if (empty.comment_id.len == 0)
        null
    else
        try Comment.init(repo_opts.hash, arena, admin_moment, haxy_moment, empty.selected_id, empty.comment_id, comments_start, viewer);

    const labels = try thread.loadLabels(Self, repo_opts.hash, arena, haxy_moment);

    return .{
        .identity = empty.identity,
        .search = empty.search,
        .assignee_unknown = empty.assignee_unknown,
        .selected_id = empty.selected_id,
        .comment_id = empty.comment_id,
        .comments_start = comments_start,
        .comment_page = comment_page,
        .viewer = viewer,
        .open = open_window,
        .closed = closed_window,
        .conflicts = conflicts_window,
        .conflict = conflict_data,
        .theirs_picks = empty.theirs_picks,
        .view = resolved_view,
        .description_page = empty.description_page,
        .labels = labels,
    };
}

// a search's terms, as the listings apply them
pub fn Search(comptime hash_kind: hash.HashKind) type {
    return struct {
        // the words the listings are narrowed to, "" for none
        words: []const u8,
        labels: []const []const u8,
        // the issue set of each assignee term, null when one of them lists
        // nothing
        assignee_sets: ?[]const evt.EventDB(hash_kind).SortedSet(.read_only),
        // whether an assignee term names no user, which lists nothing
        assignee_unknown: bool = false,

        // the sets `status`'s listing intersects
        pub fn statusSets(
            self: @This(),
            aa: std.mem.Allocator,
            haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
            status: Status,
        ) ![]const evt.EventDB(hash_kind).SortedSet(.read_only) {
            return try thread.statusSets(Self, hash_kind, aa, haxy_moment, self.labels, self.assignee_sets, status);
        }
    };
}

// the decoded `search`'s terms, resolved against the repo
pub fn readSearch(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
    search: []const u8,
) !Search(hash_kind) {
    const aa = arena.allocator();
    const DB = evt.EventDB(hash_kind);
    const filters = try srch_thrd.parseFilters(aa, search);
    var terms: Search(hash_kind) = .{ .words = filters.words, .labels = filters.labels, .assignee_sets = &.{} };

    // a name resolves to its user's email. an unknown name or an email no
    // issue carries lists nothing.
    if (filters.assignees.len != 0) {
        const by_assignee: ?DB.HashMap(.read_only) = if (try haxy_moment.getCursor(hash.hashInt(hash_kind, evt.Assignment.assignee_to_issue_id_set_key))) |cursor| try DB.HashMap(.read_only).init(cursor) else null;
        var sets: std.ArrayList(DB.SortedSet(.read_only)) = .empty;
        for (filters.assignees) |assignee| {
            const email = switch (try ui.assigneeEmail(admin_moment, arena, assignee)) {
                .email => |email| email,
                .failure => {
                    terms.assignee_unknown = true;
                    continue;
                },
            };
            const set_cursor = (if (by_assignee) |map| try map.getCursor(hash.hashInt(hash_kind, email)) else null) orelse continue;
            try sets.append(aa, try DB.SortedSet(.read_only).init(set_cursor));
        }
        terms.assignee_sets = if (sets.items.len == filters.assignees.len) sets.items else null;
    }
    return terms;
}

// the listing a window shows: a status's issues, or the conflicted ones
pub const List = union(enum) {
    status: Status,
    conflicts,
};

// one window of `list`'s issues that the search matches (the conflicts list
// ignores it), starting at `root_key` (null for the first window). `selected`,
// read with its comment window, stands in for its own entry.
pub fn loadWindow(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    tables: thread.Tables(Self, hash_kind),
    terms: Search(hash_kind),
    list: List,
    root_key: ?[]const u8,
    selected: ?*const IssueWithId,
    viewer: ?ui.Viewer,
) !Window {
    return switch (list) {
        .status => |status| try thread.loadWindow(Self, .issue, hash_kind, arena, admin_moment, tables, try terms.statusSets(arena.allocator(), tables.moment, status), root_key, selected, terms.words, viewer),
        .conflicts => try thread.loadWindow(Self, .issue, hash_kind, arena, admin_moment, tables, if (tables.conflict_set) |*set| set[0..1] else &.{}, root_key, selected, "", viewer),
    };
}

// the issue a url selects, read for its detail pane
pub const Selected = struct {
    entry: IssueWithId,
    // the key the window holding it is rooted at
    order_key: []const u8,
    // its conflict, read for the resolve view while it has one
    conflict: ?Conflict = null,
};

// the issue `id` names, with the window of its comments starting at
// `comments_start`. not found when it names no issue, one the search leaves
// out of its status's list, or for the conflicts view one without a conflict.
pub fn loadThread(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    tables: thread.Tables(Self, repo_opts.hash),
    terms: Search(repo_opts.hash),
    id: []const u8,
    view: ui.RoutablePage.IssuesView,
    comments_start: usize,
    viewer: ?ui.Viewer,
) !Selected {
    const aa = arena.allocator();
    const DB = evt.EventDB(repo_opts.hash);
    const id_bytes = evt.parseEventId(id) catch return error.NotFound;
    const issue_cursor = try tables.records.getCursor(hash.hashInt(repo_opts.hash, &id_bytes)) orelse return error.NotFound;
    const issue_map = try DB.HashMap(.read_only).init(issue_cursor);
    const issue_event = try evt.read(evt.Issue.Record, DB, repo_opts.hash, arena, issue_map);
    const order_key = evt.orderKeyDesc(issue_event.created_order, &id_bytes);

    var conflict: ?Conflict = null;
    if (view == .conflicts) {
        // the id roots the conflicts window, so it must be conflicted
        const set = tables.conflict_set orelse return error.NotFound;
        if (!try set.contains(&order_key)) return error.NotFound;
    } else {
        // the named issue must be in every set its window intersects (a
        // filtered url can name an issue the filters leave out).
        const sets = try terms.statusSets(aa, tables.moment, issue_event.event.status);
        if (!try thread.inEverySet(DB, sets, &order_key)) return error.NotFound;

        // the wasm client renders from the snapshot, so the diff machinery
        // this pulls in is gated out of its build.
        if (comptime !wasm) {
            if (view == .resolve) {
                if (tables.conflicts_map) |map| {
                    if (try map.getCursor(&order_key)) |conflict_cursor| {
                        const conflict_entry = try DB.HashMap(.read_only).init(conflict_cursor);
                        conflict = try thread.readConflict(Self, repo_kind, repo_opts, arena, repo, io, admin_moment, tables.moment, &id_bytes, issue_event, conflict_entry);
                    }
                }
            }
        }
    }

    return .{
        .entry = (try thread.loadEntry(Self, repo_opts.hash, arena, admin_moment, tables, &order_key, comments_start, viewer)) orelse return error.NotFound,
        .order_key = try aa.dupe(u8, &order_key),
        .conflict = conflict,
    };
}

// one window of `status`'s issues that the decoded `search` matches, starting
// at the issue `from` names ("" = the first window). not found when `from`
// names no issue of the status the search leaves in.
pub fn readWindow(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    search: []const u8,
    status: Status,
    from: []const u8,
    viewer: ?ui.Viewer,
) !Window {
    const rooted = from.len != 0;
    const gpa = arena.child_allocator;
    var event_db = try thread.EventDb(repo_kind, repo_opts).open(io, gpa, repo);
    defer event_db.deinit(io, gpa);
    const haxy_moment = switch (try event_db.momentStrict(repo)) {
        .none => return if (rooted) error.NotFound else .empty,
        .no_events => return if (rooted) error.NotFound else .empty,
        .ok => |moment| moment,
    };
    const terms = try readSearch(repo_opts.hash, arena, admin_moment, haxy_moment, search);
    const tables = (try thread.Tables(Self, repo_opts.hash).read(haxy_moment)) orelse return if (rooted) error.NotFound else .empty;
    const view: ui.RoutablePage.IssuesView = switch (status) {
        .open => .open,
        .closed => .closed,
    };
    const selected: ?Selected = if (rooted) try loadThread(repo_kind, repo_opts, arena, repo, io, admin_moment, tables, terms, from, view, 0, viewer) else null;
    if (selected) |thread_selected| if (thread_selected.entry.record.event.status != status) return error.NotFound;
    return try loadWindow(repo_opts.hash, arena, admin_moment, tables, terms, .{ .status = status }, if (selected) |thread_selected| thread_selected.order_key else null, if (selected) |*thread_selected| &thread_selected.entry else null, viewer);
}

// the issue `id` names, with the window of its comments starting at
// `comments_start`
pub fn readThread(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    id: []const u8,
    comments_start: usize,
    viewer: ?ui.Viewer,
) !IssueWithId {
    const gpa = arena.child_allocator;
    var event_db = try thread.EventDb(repo_kind, repo_opts).open(io, gpa, repo);
    defer event_db.deinit(io, gpa);
    const haxy_moment = switch (try event_db.momentStrict(repo)) {
        .none, .no_events => return error.NotFound,
        .ok => |moment| moment,
    };
    const terms = try readSearch(repo_opts.hash, arena, admin_moment, haxy_moment, "");
    const tables = (try thread.Tables(Self, repo_opts.hash).read(haxy_moment)) orelse return error.NotFound;
    return (try loadThread(repo_kind, repo_opts, arena, repo, io, admin_moment, tables, terms, id, .open, comments_start, viewer)).entry;
}

pub const View = thread.View(.issue, Self);
pub const Detail = thread.Detail(.issue, Self);
pub const detail_widget_name = "repo_issue_detail";

pub const Header = thread.Header;

const open_tab_label = "open";
const closed_tab_label = "closed";
const labels_tab_label = "labels";
const edit_tab_label = "edit";
const reply_tab_label = "reply";
const remove_tab_label = "remove";
const resolve_tab_label = "resolve";
const new_tab_label = "new";
const conflicts_tab_label = "conflicts";

// tabs switching between the issues page's views
pub fn initHeader(allocator: std.mem.Allocator, session: *ui.Session, data: *const Self) !Header {
    const selected_index = View.viewIndex(data.view);
    const action = View.searchListRoute(data.identity, selected_index) orelse return error.RouteTooLong;
    var header = try Header.init(allocator, session, data.search, if (data.assignee_unknown) " search (assignee not found) " else " search ", action);
    errdefer header.deinit(allocator);
    const page_selected = std.meta.activeTag(session.data.current_page) == .repo_issues;

    // a list tab per status, labeled with its listing's issue count
    const status_labels = [_][]const u8{ open_tab_label, closed_tab_label };
    for ([_]evt.Issue.Status{ .open, .closed }, status_labels, 0..) |status, status_label, index| {
        const route = try thread.searchRoute(ui.RoutablePage.repoIssuesRoute(data.identity, status, ""), data.search);
        const link = try ui.inPageTabLink(session, route, page_selected and selected_index == index);
        try header.addTab(allocator, status_label, try thread.countLabel(session, data.window(status).*), link, index);
    }

    // labels tab
    {
        const labels_route = try thread.searchRoute(ui.RoutablePage.repoThreadLabelsRoute(.issue, data.identity), data.search);
        const labels_link = try ui.inPageTabLink(session, labels_route, page_selected and selected_index == View.viewIndex(.labels));
        try header.addTab(allocator, labels_tab_label, "", labels_link, View.viewIndex(.labels));
    }

    // new-issue tab; an edit or resolve url shows its tab in this place
    {
        const route = switch (data.view) {
            .edit => ui.RoutablePage.repoThreadEditRoute(.issue, data.identity, data.selected_id) orelse return error.RouteTooLong,
            .new_comment => ui.RoutablePage.repoThreadCommentNewRoute(.issue, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
            .edit_comment => ui.RoutablePage.repoThreadCommentEditRoute(.issue, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
            .remove => ui.RoutablePage.repoThreadRemoveRoute(.issue, data.identity, data.selected_id, data.comment_id, "") orelse return error.RouteTooLong,
            .resolve => ui.RoutablePage.repoIssuesResolveRoute(data.identity, data.selected_id, data.theirs_picks) orelse return error.RouteTooLong,
            else => ui.RoutablePage.repoThreadNewRoute(.issue, data.identity) orelse return error.RouteTooLong,
        };
        const link = try ui.inPageTabLink(session, route, page_selected and selected_index == View.viewIndex(.new));
        const label: []const u8 = switch (data.view) {
            .edit => edit_tab_label,
            .new_comment => reply_tab_label,
            .edit_comment => edit_tab_label,
            .remove => remove_tab_label,
            .resolve => resolve_tab_label,
            else => new_tab_label,
        };
        try header.addTab(allocator, label, "", link, View.viewIndex(.new));
    }

    // conflicts tab, labeled with the conflict count
    if (data.conflicts.count > 0) {
        const route = ui.RoutablePage.repoIssuesConflictsRoute(data.identity, "") orelse return error.RouteTooLong;
        const link = try ui.inPageTabLink(session, route, page_selected and selected_index == View.viewIndex(.conflicts));
        try header.addTab(allocator, conflicts_tab_label, try session.page_arena.allocator().print("({d})", .{data.conflicts.count}), link, View.viewIndex(.conflicts));
    }

    header.select(View.viewIndex(data.view));
    return header;
}
