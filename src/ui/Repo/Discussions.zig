const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const Comment = @import("Comment.zig");
const Attachment = @import("Attachment.zig");
const thread = ui.widget.thread;
const srch_thrd = @import("../../search_thread.zig");

const wasm = builtin.target.cpu.arch == .wasm32;

// how many discussions one window shows before a "next" link appears.
pub const page_size = 20;

// how many labels the labels view shows at most.
pub const max_labels = 1000;

// one discussion from the repo's consumed event database, with its hex event id
// (the id lives in the event envelope, not the payload).
pub const DiscussionWithId = struct {
    id: []const u8,
    record: evt.Discussion.Record,
    author: ui.Author = .unknown,
    comments: Comment.Window = .empty,
    attachments: []const Attachment.WithId = &.{},
    assignees: []const ui.Assignee = &.{},
    // whether the viewer may change the thread, computed here so the web ui has it
    can_modify: bool = false,
    // the viewer's notify button, null when hidden
    notify_action: ?ui.NotifyAction = null,
};

pub const Entry = DiscussionWithId;

pub const Window = struct {
    items: []const DiscussionWithId,
    prev_id: ?[]const u8,
    next_id: ?[]const u8,
    count: usize,
    // whether a search stopped counting at its cap, so `count` is a floor.
    more: bool = false,

    pub const empty: Window = .{ .items = &.{}, .prev_id = null, .next_id = null, .count = 0 };
};

identity: []const u8,
// the decoded query the list is filtered to, or null when unfiltered.
search: ?[]const u8 = null,
selected_id: []const u8,
comment_id: []const u8,
comments_start: usize,
comment_page: ?Comment.Permalink = null,
// who the page is built for, null when logged out
viewer: ?ui.Viewer = null,
recent: Window,
view: ui.RoutablePage.DiscussionsView,
description_page: bool = false,
labels: []const []const u8,
repo_source: ?ui.RepoSource = null,

const Self = @This();

pub const Event = evt.Discussion;
pub const Status = enum { recent };
pub const ViewKind = ui.RoutablePage.DiscussionsView;
pub const thread_name = "discussion";
pub const header_widget_name = "repo_discussions_header";

pub fn listRoute(identity: []const u8, _: Status, selected: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoDiscussionsRoute(identity, selected);
}

pub fn selectedThread(self: *const Self) ?*const DiscussionWithId {
    if (self.selected_id.len == 0) return null;
    for (self.recent.items) |*entry| {
        if (std.mem.eql(u8, entry.id, self.selected_id)) return entry;
    }
    return null;
}

pub fn window(self: *const Self, _: Status) *const Window {
    return &self.recent;
}

// an empty listing, for the wasm / no-repo paths. `search` is decoded.
pub fn emptyResult(
    aa: std.mem.Allocator,
    identity: []const u8,
    search: []const u8,
    selected_id: []const u8,
    comment_id: []const u8,
    comments_start: usize,
    view: ui.RoutablePage.DiscussionsView,
) !Self {
    return .{
        .identity = try aa.dupe(u8, identity),
        .search = if (search.len == 0) null else try aa.dupe(u8, search),
        .selected_id = try aa.dupe(u8, selected_id),
        .comment_id = try aa.dupe(u8, comment_id),
        .comments_start = comments_start,
        .recent = .empty,
        .view = if (view == .description) .recent else view,
        .description_page = view == .description,
        .labels = &.{},
    };
}

pub fn init(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    identity: []const u8,
    search: []const u8,
    selected_id: []const u8,
    comment_id: []const u8,
    comments_start: usize,
    view: ui.RoutablePage.DiscussionsView,
    viewer: ?ui.Viewer,
) !Self {
    var empty = try emptyResult(arena.allocator(), identity, search, selected_id, comment_id, comments_start, view);
    // the early returns below still let the viewer write
    empty.viewer = viewer;
    const rooted = empty.selected_id.len != 0;

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

    const terms = try readSearch(repo_opts.hash, arena, haxy_moment, empty.search orelse "");

    const tables = (try thread.Tables(Self, repo_opts.hash).read(haxy_moment)) orelse {
        if (rooted) return error.NotFound;
        return empty;
    };

    const discussion_comments_start = if (empty.comment_id.len == 0) comments_start else 0;
    const selected: ?Selected = if (rooted) try loadThread(repo_opts.hash, arena, admin_moment, tables, terms, empty.selected_id, discussion_comments_start, viewer) else null;
    const loaded_window = try loadWindow(
        repo_opts.hash,
        arena,
        admin_moment,
        tables,
        terms,
        if (selected) |thread_selected| thread_selected.order_key else null,
        if (selected) |*thread_selected| &thread_selected.entry else null,
        viewer,
    );
    const comment_page = if (empty.comment_id.len == 0)
        null
    else
        try Comment.init(repo_opts.hash, arena, admin_moment, haxy_moment, empty.selected_id, empty.comment_id, comments_start, viewer);

    return .{
        .identity = empty.identity,
        .search = empty.search,
        .selected_id = empty.selected_id,
        .comment_id = empty.comment_id,
        .comments_start = comments_start,
        .comment_page = comment_page,
        .viewer = viewer,
        .recent = loaded_window,
        .view = empty.view,
        .description_page = empty.description_page,
        .labels = try loadLabels(repo_opts.hash, arena, haxy_moment),
    };
}

// a search's terms, as the listing applies them
pub fn Search(comptime hash_kind: hash.HashKind) type {
    return struct {
        // the words the listing is narrowed to, "" for none
        words: []const u8,
        // the sets the listing intersects
        sets: []const evt.EventDB(hash_kind).SortedSet(.read_only),
    };
}

// the decoded `search`'s terms, resolved against the repo
pub fn readSearch(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
    search: []const u8,
) !Search(hash_kind) {
    const aa = arena.allocator();
    const DB = evt.EventDB(hash_kind);
    // the listing intersects every label's set, or is the active set without
    // labels, since each label's set lies within it. discussions have no
    // assignees, so an assignee term lists nothing.
    const filters = try srch_thrd.parseFilters(aa, search);
    const sets: []const DB.SortedSet(.read_only) = blk: {
        if (filters.assignees.len != 0) break :blk &.{};
        var list: std.ArrayList(DB.SortedSet(.read_only)) = .empty;
        if (filters.labels.len == 0) {
            const active_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, evt.Discussion.active_id_set_key)) orelse break :blk &.{};
            try list.append(aa, try DB.SortedSet(.read_only).init(active_cursor));
        } else {
            const labels_cursor = try haxy_moment.getCursor(hash.hashInt(hash_kind, evt.Discussion.label_to_id_set_key)) orelse break :blk &.{};
            const label_sets = try DB.SortedMap(.read_only).init(labels_cursor);
            for (filters.labels) |label| {
                const cursor = try label_sets.getCursor(label) orelse break :blk &.{};
                try list.append(aa, try DB.SortedSet(.read_only).init(cursor));
            }
        }
        break :blk list.items;
    };
    return .{ .words = filters.words, .sets = sets };
}

// one window of the discussions the search matches, most recently active
// first, starting at `root_key` (null for the first window). `selected`, read
// with its comment window, stands in for its own entry.
pub fn loadWindow(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    tables: thread.Tables(Self, hash_kind),
    terms: Search(hash_kind),
    root_key: ?[]const u8,
    selected: ?*const DiscussionWithId,
    viewer: ?ui.Viewer,
) !Window {
    return try thread.loadWindow(Self, .discuss, hash_kind, arena, admin_moment, tables, terms.sets, root_key, selected, terms.words, viewer);
}

// the discussion a url selects, read for its detail pane
pub const Selected = struct {
    entry: DiscussionWithId,
    // the key the window holding it is rooted at
    order_key: []const u8,
};

// the discussion `id` names, with the window of its comments starting at
// `comments_start`. not found when it names no discussion, a removed one, or
// one the search's sets leave out.
pub fn loadThread(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    tables: thread.Tables(Self, hash_kind),
    terms: Search(hash_kind),
    id: []const u8,
    comments_start: usize,
    viewer: ?ui.Viewer,
) !Selected {
    const DB = evt.EventDB(hash_kind);
    const id_bytes = evt.parseEventId(id) catch return error.NotFound;
    const record_cursor = try tables.records.getCursor(hash.hashInt(hash_kind, &id_bytes)) orelse return error.NotFound;
    const record = try evt.read(evt.Discussion.Record, DB, hash_kind, arena, try DB.HashMap(.read_only).init(record_cursor));
    if (record.removed) return error.NotFound;
    const activity_order = try evt.Discussion.activityOrder(DB, hash_kind, tables.moment, &id_bytes);
    const order_key = evt.orderKeyDesc(activity_order, &id_bytes);
    if (!try thread.inEverySet(DB, terms.sets, &order_key)) return error.NotFound;
    return .{
        .entry = (try thread.loadEntry(Self, hash_kind, arena, admin_moment, tables, &order_key, comments_start, viewer)) orelse return error.NotFound,
        .order_key = try arena.allocator().dupe(u8, &order_key),
    };
}

// every discussion label, in sorted order
pub fn loadLabels(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
) ![]const []const u8 {
    const aa = arena.allocator();
    const DB = evt.EventDB(hash_kind);
    var label_names: std.ArrayList([]const u8) = .empty;
    if (try haxy_moment.getCursor(hash.hashInt(hash_kind, evt.Discussion.label_to_id_set_key))) |labels_cursor| {
        const label_sets = try DB.SortedMap(.read_only).init(labels_cursor);
        var label_iter = try label_sets.iterator();
        while (try label_iter.next()) |entry_cursor| {
            if (label_names.items.len == max_labels) break;
            var entry = entry_cursor;
            const pair = try entry.readKeyValuePair();
            try label_names.append(aa, try pair.key_cursor.readBytesAlloc(aa, null));
        }
    }
    return label_names.items;
}

// one window of the discussions the decoded `search` matches, starting at the
// discussion `from` names ("" = the first window). not found when `from`
// names none the search leaves in.
pub fn readWindow(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    search: []const u8,
    from: []const u8,
    viewer: ?ui.Viewer,
) !Window {
    const rooted = from.len != 0;
    const gpa = arena.child_allocator;
    var event_db = try thread.EventDb(repo_kind, repo_opts).open(io, gpa, repo);
    defer event_db.deinit(io, gpa);
    const haxy_moment = switch (try event_db.momentStrict(repo)) {
        .none, .no_events => return if (rooted) error.NotFound else .empty,
        .ok => |moment| moment,
    };
    const terms = try readSearch(repo_opts.hash, arena, haxy_moment, search);
    const tables = (try thread.Tables(Self, repo_opts.hash).read(haxy_moment)) orelse return if (rooted) error.NotFound else .empty;
    const selected: ?Selected = if (rooted) try loadThread(repo_opts.hash, arena, admin_moment, tables, terms, from, 0, viewer) else null;
    return try loadWindow(
        repo_opts.hash,
        arena,
        admin_moment,
        tables,
        terms,
        if (selected) |thread_selected| thread_selected.order_key else null,
        if (selected) |*thread_selected| &thread_selected.entry else null,
        viewer,
    );
}

// the discussion `id` names, with the window of its comments starting at
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
) !DiscussionWithId {
    const gpa = arena.child_allocator;
    var event_db = try thread.EventDb(repo_kind, repo_opts).open(io, gpa, repo);
    defer event_db.deinit(io, gpa);
    const haxy_moment = switch (try event_db.momentStrict(repo)) {
        .none, .no_events => return error.NotFound,
        .ok => |moment| moment,
    };
    const terms = try readSearch(repo_opts.hash, arena, haxy_moment, "");
    const tables = (try thread.Tables(Self, repo_opts.hash).read(haxy_moment)) orelse return error.NotFound;
    return (try loadThread(repo_opts.hash, arena, admin_moment, tables, terms, id, comments_start, viewer)).entry;
}

pub const View = thread.View(.discuss, Self);
pub const Detail = thread.Detail(.discuss, Self);
pub const detail_widget_name = "repo_discussion_detail";

pub const Header = thread.Header;

const recent_tab_label = "recent";
const labels_tab_label = "labels";
const edit_tab_label = "edit";
const reply_tab_label = "reply";
const remove_tab_label = "remove";
const new_tab_label = "new";

// tabs switching between the discussions page's views
pub fn initHeader(allocator: std.mem.Allocator, session: *ui.Session, data: *const Self) !Header {
    const selected_index = View.viewIndex(data.view);
    const action = View.searchListRoute(data.identity, selected_index) orelse return error.RouteTooLong;
    var header = try Header.init(allocator, session, data.search, " search ", action);
    errdefer header.deinit(allocator);
    const page_selected = std.meta.activeTag(session.data.current_page) == .repo_discussions;

    // recent discussions
    {
        const route = try thread.searchRoute(ui.RoutablePage.repoDiscussionsRoute(data.identity, ""), data.search);
        const link = try ui.inPageTabLink(session, route, page_selected and selected_index == 0);
        try header.addTab(allocator, recent_tab_label, try thread.countLabel(session, data.recent), link, 0);
    }

    // labels tab
    {
        const labels_route = try thread.searchRoute(ui.RoutablePage.repoThreadLabelsRoute(.discuss, data.identity), data.search);
        const labels_link = try ui.inPageTabLink(session, labels_route, page_selected and selected_index == View.viewIndex(.labels));
        try header.addTab(allocator, labels_tab_label, "", labels_link, View.viewIndex(.labels));
    }

    // new-discussion tab; an edit or comment url shows its tab in this place
    {
        const route = switch (data.view) {
            .edit => ui.RoutablePage.repoThreadEditRoute(.discuss, data.identity, data.selected_id) orelse return error.RouteTooLong,
            .new_comment => ui.RoutablePage.repoThreadCommentNewRoute(.discuss, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
            .edit_comment => ui.RoutablePage.repoThreadCommentEditRoute(.discuss, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
            .remove => ui.RoutablePage.repoThreadRemoveRoute(.discuss, data.identity, data.selected_id, data.comment_id, "") orelse return error.RouteTooLong,
            else => ui.RoutablePage.repoThreadNewRoute(.discuss, data.identity) orelse return error.RouteTooLong,
        };
        const link = try ui.inPageTabLink(session, route, page_selected and selected_index == View.viewIndex(.new));
        const label: []const u8 = switch (data.view) {
            .edit => edit_tab_label,
            .new_comment => reply_tab_label,
            .edit_comment => edit_tab_label,
            .remove => remove_tab_label,
            else => new_tab_label,
        };
        try header.addTab(allocator, label, "", link, View.viewIndex(.new));
    }

    header.select(View.viewIndex(data.view));
    return header;
}
