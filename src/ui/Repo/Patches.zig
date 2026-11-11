const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;
const diff3 = @import("../../diff3.zig");
const Comment = @import("Comment.zig");
const Attachment = @import("Attachment.zig");
const thread = ui.widget.thread;
const srch_thrd = @import("../../search_thread.zig");
const fork = @import("../../fork.zig");
const pch = @import("../../patch.zig");

const wasm = builtin.target.cpu.arch == .wasm32;

pub const Source = struct {
    box: wgt.Box(ui.Widget),
    session: *ui.Session,
    selectors: std.enums.EnumMap(Kind, usize),

    pub const Kind = enum { fork, branch };

    pub fn init(allocator: std.mem.Allocator, session: *ui.Session, initial: []const u8, initial_kind: Kind) !Source {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .horiz });
        errdefer box.deinit(allocator);
        const selected: Kind = if (session.data.host_kind == .local) .branch else initial_kind;
        var selectors: std.enums.EnumMap(Kind, usize) = .{};
        if (session.data.host_kind != .local) {
            for (std.enums.values(Kind)) |kind| {
                const label = switch (kind) {
                    .fork => "from a new fork",
                    .branch => "from an existing branch",
                };
                var selector = try wgt.TextBox.init(allocator, label, .{ .border = .single, .round_corners = true, .wrap_kind = .none });
                errdefer selector.deinit(allocator);
                selector.getFocus().mode = .all;
                try box.children.put(allocator, selector.getFocus().id, .{ .widget = .{ .text_box = selector }, .rect = null, .min_size = .{ .width = label.len + 2, .height = 3 } });
                selectors.put(kind, selector.getFocus().id);
            }
        }
        var input_box = try wgt.TextInput.init(allocator, .{ .top_label = .{ .text = " source branch " }, .name = "source_branch", .round_corners = true, .visible_width = null, .render_content = session.is_terminal });
        errdefer input_box.deinit(allocator);
        input_box.getFocus().mode = .all;
        try input_box.setContent(allocator, initial);
        try box.children.put(allocator, input_box.getFocus().id, .{ .widget = .{ .text_input = input_box }, .rect = null, .min_size = .{ .width = 15, .height = 3 } });
        box.getFocus().child_id = selectors.get(selected) orelse input_box.getFocus().id;
        return .{ .box = box, .session = session, .selectors = selectors };
    }

    pub fn field(self: *Source) *wgt.TextInput {
        for (self.box.children.values()) |*child| switch (child.widget) {
            .text_input => |*text_input| return text_input,
            else => {},
        };
        unreachable;
    }

    // the selection is whichever selector focus last landed on, like every
    // other selection in the ui, so a click (which only moves focus on the
    // web) selects. the branch text input is only reachable while branch is
    // selected, so focus on it means branch too.
    pub fn selectedKind(self: *Source) Kind {
        const current = self.box.getFocus().child_id orelse return .branch;
        var iter = self.selectors.iterator();
        while (iter.next()) |selector| {
            if (selector.value.* == current) return selector.key;
        }
        return .branch;
    }

    pub fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn clearGrid(self: *Source) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: Source) ?xitui.grid.Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *Source) *xitui.focus.Focus {
        return self.box.getFocus();
    }

    pub fn build(self: *Source, allocator: std.mem.Allocator, constraint: xitui.layout.Constraint, root_focus: *xitui.focus.Focus) !void {
        self.clearGrid();
        const selected = self.selectedKind();
        for (self.box.children.keys(), self.box.children.values()) |id, *child| switch (child.widget) {
            .text_input => child.hidden = selected == .fork,
            .text_box => |*selector| selector.options.border = if (id == self.selectors.get(selected)) .single else .hidden,
            else => {},
        };
        try self.box.build(allocator, constraint, root_focus);
        if (!self.session.is_terminal) {
            try self.session.text_inputs.put(self.session.arena.allocator(), self.field().getFocus().id, self.field());
        }
    }

    pub fn input(self: *Source, allocator: std.mem.Allocator, key: xitui.input.Key, root_focus: *xitui.focus.Focus) !void {
        const current = self.box.getFocus().child_id orelse return;
        const text_input = self.field();
        if (current == text_input.getFocus().id) {
            if (key == .arrow_left) {
                if (self.selectors.get(.branch)) |id| {
                    root_focus.setFocus(id);
                    return;
                }
            }
            return text_input.input(allocator, key, root_focus);
        }

        var iter = self.selectors.iterator();
        var previous: ?Kind = null;
        while (iter.next()) |selector| {
            if (selector.value.* == current) break;
            previous = selector.key;
        } else return;
        switch (key) {
            .arrow_left => if (previous) |kind| root_focus.setFocus(self.selectors.get(kind) orelse return),
            // past the last selector (branch) lies its text input
            .arrow_right => if (iter.next()) |next| root_focus.setFocus(next.value.*) else root_focus.setFocus(text_input.getFocus().id),
            .enter => if (self.selectedKind() == .branch) root_focus.setFocus(text_input.getFocus().id),
            else => {},
        }
    }
};

// how many patches one window shows before a "next" link appears.
pub const page_size = 20;

// how many labels the labels view shows at most.
pub const max_labels = 1000;

// one patch from the repo's consumed event database, with its hex event id
// (the id lives in the event envelope, not the payload).
pub const PatchWithId = struct {
    id: []const u8,
    record: evt.Patch.Record,
    // the creation commit's author
    author: ui.Author = .unknown,
    // whether the patch has an unresolved merge conflict
    conflicted: bool = false,
    comments: Comment.Window = .empty,
    attachments: []const Attachment.WithId = &.{},
    assignees: []const ui.Assignee = &.{},
    // whether the viewer may change the thread, computed here so the web ui has it
    can_modify: bool = false,
    // the viewer's notify button, null when hidden
    notify_action: ?ui.NotifyAction = null,
    draft: bool = false,
    revision_oid: []const u8 = "",
    base_oid: []const u8 = "",
    commit_count: ?u64 = null,
    no_changes: bool = false,
    fork_exists: bool = false,
    // the url identity of the fork backing the patch: its forker and the repo name it was forked under
    fork_identity: []const u8 = "",
    // whether the fork's target is gone, which leaves the fork fetchable but not pushable
    target_deleted: bool = false,
    mergeability: pch.Mergeability = .{},
};

pub const Entry = PatchWithId;

// one side of a conflicted field: its value and who set it
pub const Side = struct {
    text: []const u8,
    author: ui.Author = .unknown,
};

pub const FieldConflict = struct {
    ours: Side,
    theirs: Side,
};

// the selected patch's conflict, read for the resolve view. ours is the live
// record; the chunks split the description against the merge base.
pub const Conflict = struct {
    title: ?FieldConflict = null,
    labels: ?FieldConflict = null,
    status: ?FieldConflict = null,
    revision: ?FieldConflict = null,
    target_branch: ?FieldConflict = null,
    description: ?struct {
        chunks: []const diff3.Chunk,
        ours_author: ui.Author = .unknown,
        theirs_author: ui.Author = .unknown,
    } = null,
};

// one status's windowed listing.
pub const Window = struct {
    items: []const PatchWithId,
    // the id of the previous window's first patch, or null when this window
    // is already the first.
    prev_id: ?[]const u8,
    // the id of the next window's first patch, or null when this is the last
    // window.
    next_id: ?[]const u8,
    // how many patches the listing holds across all windows.
    count: usize,
    // whether a search stopped counting at its cap, so `count` is a floor.
    more: bool = false,

    pub const empty: Window = .{ .items = &.{}, .prev_id = null, .next_id = null, .count = 0 };
};

// "owner:name", so the view can build /owner:name/patches/... links.
identity: []const u8,
default_target_branch: []const u8 = "",
// the decoded query the lists are filtered to, or null when unfiltered.
search: ?[]const u8 = null,
// the hex event id of the patch its status's window is rooted at ("" = the
// first window), mirrored into the url.
selected_id: []const u8,
// the comment shown in the selected patch's detail pane.
comment_id: []const u8,
// the selected patch's comment window (0 = the first window).
comments_start: usize,
// the selected comment and its immediate replies.
comment_page: ?Comment.Permalink = null,
// who the page is built for, null when logged out
viewer: ?ui.Viewer = null,
open: Window,
closed: Window,
merged: Window,
drafts: Window,
// the conflicted patches' listing; its count also gates the conflicts tab.
conflicts: Window,
// the selected patch's conflict, set when the page shows the resolve view.
conflict: ?Conflict = null,
// the resolve view's comma-separated fields prefilled from their side,
// mirrored from the url.
theirs_picks: []const u8 = "",
// the view the page shows initially (a selected patch's status overrides the route's)
view: ui.RoutablePage.PatchesView,
// the /description page: the detail pane shows the selected patch's whole
// description behind a back link.
description_page: bool = false,
// every label in the repo, in sorted order, for the labels view.
labels: []const []const u8,
// the on-disk repo this page was read from, for the terminal submit path
// (the web posts the new-patch form to the patch route instead).
repo_source: ?ui.RepoSource = null,
repo_id: ?[evt.event_id_size]u8 = null,

const Self = @This();

pub const Event = evt.Patch;
pub const Status = evt.Patch.StatusKind;
pub const ViewKind = ui.RoutablePage.PatchesView;
pub const thread_name = "patch";
pub const header_widget_name = "repo_patches_header";

pub fn statusKind(event: Event) Status {
    return event.status.kind();
}

pub fn listRoute(identity: []const u8, status: Status, selected: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoPatchesRoute(identity, status, selected);
}

pub fn commitsRoute(identity: []const u8, entry: PatchWithId) !?ui.RoutablePage {
    if (entry.fork_exists and entry.record.event.status.kind() != .merged)
        return ui.RoutablePage.forkCommitsRoute(entry.fork_identity, entry.id, "") orelse error.RouteTooLong;
    if (entry.revision_oid.len == 0 or entry.base_oid.len == 0) return null;
    return ui.RoutablePage.repoCommitsRoute(identity, .object, entry.revision_oid, entry.base_oid) orelse error.RouteTooLong;
}

pub fn diffRoute(identity: []const u8, entry: PatchWithId) !?ui.RoutablePage {
    const patch = entry.record.event;
    const revision_id = switch (patch.status) {
        // merged patches show what actually landed, including conflict resolutions
        .merged => |merged| merged.patchrev_id,
        .open, .closed => blk: {
            if (entry.fork_exists) return ui.RoutablePage.forkDiffRoute(entry.fork_identity, entry.id, "", "", 0, "") orelse error.RouteTooLong;
            if (patch.source_branch == null) return null;
            break :blk (patch.revision orelse return null).id;
        },
    };
    return ui.RoutablePage.repoPatchRevDiffRoute(identity, &revision_id, 0, "") orelse error.RouteTooLong;
}

pub fn draftsRoute(identity: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoPatchesDraftsRoute(identity);
}

pub fn conflictsRoute(identity: []const u8, selected: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoPatchesConflictsRoute(identity, selected);
}

pub fn resolveRoute(identity: []const u8, selected: []const u8, picks: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoPatchesResolveRoute(identity, selected, picks);
}

pub fn publishRoute(identity: []const u8, selected: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoPatchPublishRoute(identity, selected);
}

pub fn mergeRoute(identity: []const u8, selected: []const u8) ?ui.RoutablePage {
    return ui.RoutablePage.repoPatchMergeRoute(identity, selected);
}

pub fn canMerge(entry: Entry, session: *const ui.Session) bool {
    return !entry.draft and
        (entry.fork_exists or entry.record.event.source_branch != null) and
        !entry.conflicted and
        entry.record.event.revision != null and
        entry.record.event.status.kind() == .open and
        session.data.host_kind == .server;
}

// `status`'s windowed listing.
pub fn window(self: *const Self, status: Status) *const Window {
    return switch (status) {
        .open => &self.open,
        .closed => &self.closed,
        .merged => &self.merged,
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

// the patch `selected_id` names, in whichever window holds it.
pub fn selectedThread(self: *const Self) ?*const PatchWithId {
    if (self.selected_id.len == 0) return null;
    for ([_]*const Window{ &self.open, &self.closed, &self.merged, &self.drafts }) |win| {
        for (win.items) |*entry| {
            if (std.mem.eql(u8, entry.id, self.selected_id)) return entry;
        }
    }
    return null;
}

// the user whose drafts a listing shows
pub const DraftsOwner = struct {
    user_id: [evt.event_id_size]u8,
    name: []const u8,

    // the logged-in user, or null when logged out
    pub fn of(user_id: ?[evt.event_id_size]u8, name: ?[]const u8) ?DraftsOwner {
        return .{ .user_id = user_id orelse return null, .name = name orelse return null };
    }
};

// an empty listing, for the wasm / no-repo paths. `search` is decoded.
pub fn emptyResult(aa: std.mem.Allocator, identity: []const u8, search: []const u8, selected_id: []const u8, comment_id: []const u8, comments_start: usize, theirs_picks: []const u8, view: ui.RoutablePage.PatchesView) !Self {
    return .{
        .identity = try aa.dupe(u8, identity),
        .default_target_branch = "",
        .search = if (search.len == 0) null else try aa.dupe(u8, search),
        .selected_id = try aa.dupe(u8, selected_id),
        .comment_id = try aa.dupe(u8, comment_id),
        .comments_start = comments_start,
        .open = .empty,
        .closed = .empty,
        .merged = .empty,
        .drafts = .empty,
        .conflicts = .empty,
        .theirs_picks = try aa.dupe(u8, theirs_picks),
        // a description url shows a status list, the patch's own status
        // picking it once the patch is read; conflicts and resolve urls also
        // start there, upgraded by init when the conflict data exists.
        .view = switch (view) {
            .description, .conflicts, .resolve => .open,
            else => view,
        },
        .description_page = view == .description,
        .labels = &.{},
    };
}

pub fn detailResult(aa: std.mem.Allocator, identity: []const u8, entry: PatchWithId) !Self {
    var result = try emptyResult(aa, identity, "", entry.id, "", 0, "", .open);
    const items = try aa.dupe(PatchWithId, &.{entry});
    const detail_window = Window{ .items = items, .prev_id = null, .next_id = null, .count = 1 };
    if (entry.draft) {
        result.drafts = detail_window;
        result.view = .drafts;
    } else switch (entry.record.event.status) {
        .open => result.open = detail_window,
        .closed => {
            result.closed = detail_window;
            result.view = .closed;
        },
        .merged => {
            result.merged = detail_window;
            result.view = .merged;
        },
    }
    return result;
}

// read one window per status of an opened repo's patches (filtered to the
// search when set), ordered by creation (newest first). the window of the patch
// `selected_id` names starts at it ("" = the beginning). a git repo reads the
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
    // where server users live; null in local mode, which has no forks
    users_dir: ?[]const u8,
    // whose drafts the listing shows: the logged-in server user's
    drafts_owner: ?DraftsOwner,
    repo_id_maybe: ?[evt.event_id_size]u8,
    identity: []const u8,
    target_branch: []const u8,
    search: []const u8,
    selected_id: []const u8,
    comment_id: []const u8,
    comments_start: usize,
    theirs_picks: []const u8,
    view: ui.RoutablePage.PatchesView,
    viewer: ?ui.Viewer,
) !Self {
    const allowed_view: ui.RoutablePage.PatchesView = if (users_dir == null and view == .drafts) .open else view;
    var empty = try emptyResult(arena.allocator(), identity, search, selected_id, comment_id, comments_start, theirs_picks, allowed_view);
    empty.default_target_branch = try arena.allocator().dupe(u8, target_branch);
    // the early returns below still let the viewer write
    empty.viewer = viewer;

    const rooted = empty.selected_id.len != 0;
    const drafts_window = try loadDraftsWindow(repo_kind, repo_opts, arena, io, admin_moment, users_dir, drafts_owner, repo_id_maybe, empty.selected_id, repo);
    var draft_selected = false;
    if (rooted) for (drafts_window.items) |item| {
        if (std.mem.eql(u8, item.id, empty.selected_id)) {
            draft_selected = true;
            break;
        }
    };
    empty.drafts = drafts_window;
    if (draft_selected and view != .edit and view != .publish and view != .remove) empty.view = .drafts;

    // an explicitly named published patch that doesn't exist is a bad url
    // (NotFound -> 404); drafts, labels, and bare routes can use the empty fallback.
    const strict = rooted and !draft_selected;

    // a repo with no consumed events has no moment yet.
    const gpa = arena.child_allocator;
    var event_db = try thread.EventDb(repo_kind, repo_opts).open(io, gpa, repo);
    defer event_db.deinit(io, gpa);
    const haxy_moment = switch (event_db.moment(repo)) {
        .none => return empty,
        .no_events => {
            if (strict) return error.NotFound;
            return empty;
        },
        .ok => |moment| moment,
    };

    const terms = try readSearch(repo_opts.hash, arena, empty.search orelse "");

    const tables = (try thread.Tables(Self, repo_opts.hash).read(haxy_moment)) orelse {
        if (strict) return error.NotFound;
        return empty;
    };

    // a named patch roots its own status's window at itself (the conflicts
    // view's window instead); the other windows start at the beginning.
    var resolved_view = empty.view;
    var open_root: ?[]const u8 = null;
    var closed_root: ?[]const u8 = null;
    var merged_root: ?[]const u8 = null;
    var conflicts_root: ?[]const u8 = null;
    var conflict_data: ?Conflict = null;
    const thread_comments_start = if (empty.comment_id.len == 0) comments_start else 0;
    const selected: ?Selected = if (strict) try loadThread(repo_kind, repo_opts, arena, repo, io, admin_moment, tables, terms, empty.selected_id, view, thread_comments_start, viewer) else null;
    if (selected) |thread_selected| {
        const status = thread_selected.entry.record.event.status;
        if (view == .conflicts) {
            conflicts_root = thread_selected.order_key;
        } else {
            switch (status) {
                .open => open_root = thread_selected.order_key,
                .closed => closed_root = thread_selected.order_key,
                .merged => merged_root = thread_selected.order_key,
            }
            // form urls keep their view; otherwise the patch's status picks it.
            if (view != .edit and view != .merge and view != .new_comment and view != .edit_comment and view != .remove) resolved_view = switch (status) {
                .open => .open,
                .closed => .closed,
                .merged => .merged,
            };
            // a resolve url shows the resolve view only while the patch still
            // has a conflict entry; otherwise the status list stands.
            conflict_data = thread_selected.conflict;
            if (conflict_data != null) resolved_view = .resolve;
        }
    }

    const selected_entry: ?*const PatchWithId = if (selected) |*thread_selected| &thread_selected.entry else null;
    const open_window = try loadWindow(false, repo_kind, repo_opts, arena, repo, io, admin_moment, users_dir, tables, terms, .{ .status = .open }, open_root, selected_entry, viewer);
    const closed_window = try loadWindow(false, repo_kind, repo_opts, arena, repo, io, admin_moment, users_dir, tables, terms, .{ .status = .closed }, closed_root, selected_entry, viewer);
    const merged_window = try loadWindow(false, repo_kind, repo_opts, arena, repo, io, admin_moment, users_dir, tables, terms, .{ .status = .merged }, merged_root, selected_entry, viewer);
    const conflicts_window = try loadWindow(false, repo_kind, repo_opts, arena, repo, io, admin_moment, users_dir, tables, terms, .conflicts, conflicts_root, selected_entry, viewer);
    if (view == .conflicts and conflicts_window.count > 0) resolved_view = .conflicts;

    const comment_page = if (empty.comment_id.len == 0)
        null
    else
        try Comment.init(repo_opts.hash, arena, admin_moment, haxy_moment, empty.selected_id, empty.comment_id, comments_start, viewer);

    const labels = try thread.loadLabels(Self, repo_opts.hash, arena, haxy_moment);

    return .{
        .identity = empty.identity,
        .default_target_branch = empty.default_target_branch,
        .search = empty.search,
        .selected_id = empty.selected_id,
        .comment_id = empty.comment_id,
        .comments_start = comments_start,
        .comment_page = comment_page,
        .viewer = viewer,
        .open = open_window,
        .closed = closed_window,
        .merged = merged_window,
        .drafts = drafts_window,
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
        // patches have no assignees, so an assignee term lists nothing (null)
        extra_sets: ?[]const evt.EventDB(hash_kind).SortedSet(.read_only),

        // the sets `status`'s listing intersects: every label's set
        pub fn statusSets(
            self: @This(),
            aa: std.mem.Allocator,
            haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
            status: Status,
        ) ![]const evt.EventDB(hash_kind).SortedSet(.read_only) {
            return try thread.statusSets(Self, hash_kind, aa, haxy_moment, self.labels, self.extra_sets, status);
        }
    };
}

// the decoded `search`'s terms
pub fn readSearch(comptime hash_kind: hash.HashKind, arena: *std.heap.ArenaAllocator, search: []const u8) !Search(hash_kind) {
    const filters = try srch_thrd.parseFilters(arena.allocator(), search);
    return .{
        .words = filters.words,
        .labels = filters.labels,
        .extra_sets = if (filters.assignees.len == 0) &.{} else null,
    };
}

// the published listing a window shows: a status's patches, or the
// conflicted ones
pub const List = union(enum) {
    status: Status,
    conflicts,
};

// one window of `list`'s patches that the search matches (the conflicts list
// ignores it), starting at `root_key` (null for the first window), with each
// patch's fork, revision and mergeability. `selected`, read with its comment
// window, stands in for its own entry. a page shows mergeability or a commit
// count it can't read as unknown; a `strict` window fails instead.
pub fn loadWindow(
    comptime strict: bool,
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    // where server users live, for fork-backed patches; null in local mode
    users_dir: ?[]const u8,
    tables: thread.Tables(Self, repo_opts.hash),
    terms: Search(repo_opts.hash),
    list: List,
    root_key: ?[]const u8,
    selected: ?*const PatchWithId,
    viewer: ?ui.Viewer,
) !Window {
    var loaded = switch (list) {
        .status => |status| try thread.loadWindow(Self, .patch, repo_opts.hash, arena, admin_moment, tables, try terms.statusSets(arena.allocator(), tables.moment, status), root_key, selected, terms.words, viewer),
        .conflicts => try thread.loadWindow(Self, .patch, repo_opts.hash, arena, admin_moment, tables, if (tables.conflict_set) |*set| set[0..1] else &.{}, root_key, selected, "", viewer),
    };
    try setPatchDetails(strict, repo_kind, repo_opts, io, arena, admin_moment, users_dir, tables.moment, repo, &loaded);
    return loaded;
}

// the published patch a url selects, read for its detail pane
pub const Selected = struct {
    // without its fork, revision and mergeability, which its window adds
    entry: PatchWithId,
    // the key the window holding it is rooted at
    order_key: []const u8,
    // its conflict, read for the resolve view while it has one
    conflict: ?Conflict = null,
};

// the published patch `id` names, with the window of its comments starting
// at `comments_start`. not found when it names no patch, one the search leaves
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
    view: ui.RoutablePage.PatchesView,
    comments_start: usize,
    viewer: ?ui.Viewer,
) !Selected {
    const aa = arena.allocator();
    const DB = evt.EventDB(repo_opts.hash);
    const id_bytes = evt.parseEventId(id) catch return error.NotFound;
    const patch_cursor = try tables.records.getCursor(hash.hashInt(repo_opts.hash, &id_bytes)) orelse return error.NotFound;
    const patch_map = try DB.HashMap(.read_only).init(patch_cursor);
    const patch_event = try evt.read(evt.Patch.Record, DB, repo_opts.hash, arena, patch_map);
    const order_key = evt.orderKeyDesc(patch_event.created_order, &id_bytes);

    var conflict: ?Conflict = null;
    if (view == .conflicts) {
        // the id roots the conflicts window, so it must be conflicted
        const set = tables.conflict_set orelse return error.NotFound;
        if (!try set.contains(&order_key)) return error.NotFound;
    } else {
        // the named patch must be in every set its window intersects (a
        // filtered url can name a patch the filters leave out).
        const sets = try terms.statusSets(aa, tables.moment, patch_event.event.status.kind());
        if (!try thread.inEverySet(DB, sets, &order_key)) return error.NotFound;

        // the wasm client renders from the snapshot, so the diff machinery
        // this pulls in is gated out of its build.
        if (comptime !wasm) {
            if (view == .resolve) {
                if (tables.conflicts_map) |map| {
                    if (try map.getCursor(&order_key)) |conflict_cursor| {
                        const conflict_entry = try DB.HashMap(.read_only).init(conflict_cursor);
                        conflict = try thread.readConflict(Self, repo_kind, repo_opts, arena, repo, io, admin_moment, tables.moment, &id_bytes, patch_event, conflict_entry);
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

// one window of the published `list`'s patches that the decoded `search`
// matches, starting at the patch `from` names ("" = the first window). not
// found when `from` names no patch of the list the search leaves in.
pub fn readWindow(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    users_dir: ?[]const u8,
    search: []const u8,
    list: List,
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
    const terms = try readSearch(repo_opts.hash, arena, search);
    const tables = (try thread.Tables(Self, repo_opts.hash).read(haxy_moment)) orelse return if (rooted) error.NotFound else .empty;
    const view: ui.RoutablePage.PatchesView = switch (list) {
        .status => |status| switch (status) {
            .open => .open,
            .closed => .closed,
            .merged => .merged,
        },
        .conflicts => .conflicts,
    };
    const selected: ?Selected = if (rooted) try loadThread(repo_kind, repo_opts, arena, repo, io, admin_moment, tables, terms, from, view, 0, viewer) else null;
    if (selected) |thread_selected| switch (list) {
        .status => |status| if (thread_selected.entry.record.event.status.kind() != status) return error.NotFound,
        .conflicts => {},
    };
    return try loadWindow(
        true,
        repo_kind,
        repo_opts,
        arena,
        repo,
        io,
        admin_moment,
        users_dir,
        tables,
        terms,
        list,
        if (selected) |thread_selected| thread_selected.order_key else null,
        if (selected) |*thread_selected| &thread_selected.entry else null,
        viewer,
    );
}

// the patch `id` names, one of the drafts owner's drafts of the repo or a
// published one, with the window of its comments starting at `comments_start`
pub fn readThread(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    users_dir: ?[]const u8,
    drafts_owner: ?DraftsOwner,
    repo_id_maybe: ?[evt.event_id_size]u8,
    id: []const u8,
    comments_start: usize,
    viewer: ?ui.Viewer,
) !PatchWithId {
    // a draft lives in its fork, so it is looked up first
    if (admin_moment) |admin| if (repo_id_maybe) |repo_id| if (drafts_owner) |owner| if (users_dir) |dir| {
        if (try loadDraft(repo_kind, repo_opts, arena, io, dir, owner, admin, &repo_id, id, repo)) |entry| return entry;
    };

    const gpa = arena.child_allocator;
    var event_db = try thread.EventDb(repo_kind, repo_opts).open(io, gpa, repo);
    defer event_db.deinit(io, gpa);
    const haxy_moment = switch (try event_db.momentStrict(repo)) {
        .none, .no_events => return error.NotFound,
        .ok => |moment| moment,
    };
    const terms = try readSearch(repo_opts.hash, arena, "");
    const tables = (try thread.Tables(Self, repo_opts.hash).read(haxy_moment)) orelse return error.NotFound;
    const selected = try loadThread(repo_kind, repo_opts, arena, repo, io, admin_moment, tables, terms, id, .open, comments_start, viewer);
    const items = [_]PatchWithId{selected.entry};
    var detail: Window = .{ .items = &items, .prev_id = null, .next_id = null, .count = 1 };
    try setPatchDetails(true, repo_kind, repo_opts, io, arena, admin_moment, users_dir, haxy_moment, repo, &detail);
    return detail.items[0];
}

fn setPatchDetails(
    comptime strict: bool,
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    users_dir: ?[]const u8,
    haxy_moment: evt.EventDB(repo_opts.hash).HashMap(.read_only),
    repo: *rp.Repo(repo_kind, repo_opts),
    target: *Window,
) !void {
    if (target.items.len == 0) return;
    var config = try repo.listConfig(io, arena.child_allocator);
    defer config.deinit();
    const items = try arena.allocator().dupe(PatchWithId, target.items);
    for (items) |*item| {
        const id = try evt.parseEventId(item.id);
        const status = item.record.event.status.kind();
        // a fork-backed patch's fork lives in its forker's user repo
        if (admin_moment) |moment| if (users_dir) |dir| if (item.record.event.source_branch == null) {
            if (try fork.readForkerId(&config.sections, &id)) |forker_id| {
                if (try evt.readForkById(io, arena.child_allocator, arena, dir, &forker_id, &id)) |record| if (!record.removed) {
                    if (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, arena, &forker_id)) |forker| {
                        item.fork_exists = true;
                        item.fork_identity = try arena.allocator().print("{s}:{s}", .{ forker.event.name, record.event.repo_name });
                    }
                };
            }
        };
        const target_branch = item.record.event.target_branch;
        const revision = item.record.event.revision orelse continue;
        item.commit_count = revision.commit_count;
        const merge_revision: evt.Patch.MergeRevision = switch (item.record.event.status) {
            .merged => |merged| merged.revision,
            else => .source,
        };
        item.revision_oid = switch (merge_revision) {
            .source => revision.source_oid,
            .squash => revision.squash_oid,
        };
        if (!item.fork_exists or status == .merged) {
            const revision_id = try evt.parseEventId(&revision.id);
            if (try evt.PatchRev.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, haxy_moment, arena, &revision_id)) |record| {
                item.base_oid = record.event.base_oid;
            }
        }
        if (status == .merged) {
            if (merge_revision == .squash) item.commit_count = 1;
            continue;
        }
        if (comptime repo_kind == .xit) {
            var moment = try repo.core.latestMoment();
            const state = rp.Repo(.xit, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
            // readMergeability already reads a missing check as unknown, so
            // what it fails with is storage
            item.mergeability = pch.readMergeability(repo_opts, state, io, arena, &id, item.record.event) catch |err| if (strict) return err else .{};
        }
        const target_oid = try repo.readRef(io, .{ .kind = .head, .name = target_branch });
        item.no_changes = if (target_oid) |oid| std.mem.eql(u8, &oid, revision.source_oid) else false;
    }
    target.items = items;
}

// one window of the drafts owner's drafts of the repo, starting at the draft
// `selected_id` names ("" or none of theirs = the first window). empty
// without a logged-in server user. the page leaves out a draft whose fork it
// can't read; `readDraftsWindow` is the same window for a read, which fails
// instead.
pub fn loadDraftsWindow(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    users_dir: ?[]const u8,
    drafts_owner: ?DraftsOwner,
    repo_id_maybe: ?[evt.event_id_size]u8,
    selected_id: []const u8,
    target_repo: *rp.Repo(repo_kind, repo_opts),
) !Window {
    return try draftsWindow(false, repo_kind, repo_opts, arena, io, admin_moment, users_dir, drafts_owner, repo_id_maybe, selected_id, target_repo);
}

// `loadDraftsWindow`, leaving out only a draft whose fork is gone
pub fn readDraftsWindow(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    users_dir: ?[]const u8,
    drafts_owner: ?DraftsOwner,
    repo_id_maybe: ?[evt.event_id_size]u8,
    selected_id: []const u8,
    target_repo: *rp.Repo(repo_kind, repo_opts),
) !Window {
    return try draftsWindow(true, repo_kind, repo_opts, arena, io, admin_moment, users_dir, drafts_owner, repo_id_maybe, selected_id, target_repo);
}

// the window `loadDraftsWindow` and `readDraftsWindow` share
fn draftsWindow(
    comptime strict: bool,
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    users_dir: ?[]const u8,
    drafts_owner: ?DraftsOwner,
    repo_id_maybe: ?[evt.event_id_size]u8,
    selected_id: []const u8,
    target_repo: *rp.Repo(repo_kind, repo_opts),
) !Window {
    const admin = admin_moment orelse return .empty;
    const repo_id = repo_id_maybe orelse return .empty;
    const owner = drafts_owner orelse return .empty;
    const dir = users_dir orelse return .empty;
    return try loadDraftWindow(strict, repo_kind, repo_opts, arena, io, dir, owner, admin, &repo_id, selected_id, target_repo);
}

// whether opening a fork failed because it is gone
fn isMissingFork(err: anyerror) bool {
    return err == error.RepoNotFound or err == error.FileNotFound;
}

// the owner's draft of the repo `id` names, or null when it names none of
// theirs or its fork is gone. not found when `id` is no id, or names a draft
// of theirs of another repo. a fork that can't be read is the read's error.
fn loadDraft(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    users_dir: []const u8,
    owner: DraftsOwner,
    admin_moment: evt.AdminDB.HashMap(.read_only),
    repo_id: *const [evt.event_id_size]u8,
    id: []const u8,
    target_repo: *rp.Repo(repo_kind, repo_opts),
) !?PatchWithId {
    // the owner's drafts live in their user repo
    var user_repo = (try evt.openUserRepo(io, arena.child_allocator, users_dir, &owner.user_id)) orelse return null;
    defer user_repo.deinit(io, arena.child_allocator);
    const user_moment = (try evt.userMoment(&user_repo)) orelse return null;
    const drafts_cursor = try user_moment.getCursor(hash.hashInt(evt.user_repo_opts.hash, evt.Fork.repo_to_draft_id_set_key)) orelse return null;
    const drafts = try evt.UserDB.HashMap(.read_only).init(drafts_cursor);
    const set_cursor = try drafts.getCursor(hash.hashInt(evt.user_repo_opts.hash, repo_id)) orelse return null;
    const set = try evt.UserDB.SortedSet(.read_only).init(set_cursor);
    const aa = arena.allocator();

    const id_bytes = evt.parseEventId(id) catch return error.NotFound;
    const record = (try evt.Fork.readById(evt.UserDB, evt.user_repo_opts.hash, user_moment, arena, &id_bytes)) orelse return null;
    if (record.removed or record.event.stage != .draft) return null;
    if (!try set.contains(&evt.orderKeyDesc(record.created_order, &id_bytes))) return error.NotFound;

    const path = try fork.forkPath(aa, users_dir, &owner.user_id, &id_bytes);
    // a fork shares its target's hash kind
    var fork_repo = rp.Repo(.xit, .{ .hash = repo_opts.hash }).open(io, arena.child_allocator, .{ .path = path, .require_repo_root = true }) catch |err| {
        if (isMissingFork(err)) return null;
        return err;
    };
    defer fork_repo.deinit(io, arena.child_allocator);
    const fork_identity = try aa.print("{s}:{s}", .{ owner.name, record.event.repo_name });
    return try draftEntry(true, repo_kind, repo_opts, arena, io, admin_moment, &fork_repo, target_repo, id_bytes, fork_identity);
}

fn loadDraftWindow(
    comptime strict: bool,
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    users_dir: []const u8,
    owner: DraftsOwner,
    admin_moment: evt.AdminDB.HashMap(.read_only),
    repo_id: *const [evt.event_id_size]u8,
    selected_id: []const u8,
    target_repo: *rp.Repo(repo_kind, repo_opts),
) !Window {
    const user_id = owner.user_id;
    const user_name = owner.name;

    // the viewer's drafts live in their user repo
    var user_repo = (try evt.openUserRepo(io, arena.child_allocator, users_dir, &user_id)) orelse return .empty;
    defer user_repo.deinit(io, arena.child_allocator);
    const user_moment = (try evt.userMoment(&user_repo)) orelse return .empty;
    const drafts_cursor = try user_moment.getCursor(hash.hashInt(evt.user_repo_opts.hash, evt.Fork.repo_to_draft_id_set_key)) orelse return .empty;
    const drafts = try evt.UserDB.HashMap(.read_only).init(drafts_cursor);
    const set_cursor = try drafts.getCursor(hash.hashInt(evt.user_repo_opts.hash, repo_id)) orelse return .empty;
    const set = try evt.UserDB.SortedSet(.read_only).init(set_cursor);
    const aa = arena.allocator();

    var root_key: ?[]const u8 = null;
    if (selected_id.len != 0) {
        const id = evt.parseEventId(selected_id) catch return error.NotFound;
        if (try evt.Fork.readById(evt.UserDB, evt.user_repo_opts.hash, user_moment, arena, &id)) |record| {
            if (!record.removed and record.event.stage == .draft) {
                const order_key = try aa.dupe(u8, &evt.orderKeyDesc(record.created_order, &id));
                if (!try set.contains(order_key)) return error.NotFound;
                root_key = order_key;
            }
        }
    }

    var prev_id: ?[]const u8 = null;
    var iter = if (root_key) |root| blk: {
        const rank = try set.rank(root);
        if (rank > 0 and rank <= page_size) {
            prev_id = "";
        } else if (rank > page_size) {
            const pair = try set.getIndexKeyValuePair(@intCast(rank - page_size)) orelse return error.NotFound;
            var previous: [@sizeOf(u64) + evt.event_id_size]u8 = undefined;
            _ = try pair.key_cursor.readBytes(&previous);
            const hex = std.fmt.bytesToHex(previous[@sizeOf(u64)..].*, .lower);
            prev_id = try aa.dupe(u8, &hex);
        }
        break :blk try set.iteratorFrom(root);
    } else try set.iteratorFromIndex(0);

    var items: std.ArrayList(PatchWithId) = .empty;
    var next_id: ?[]const u8 = null;
    while (try iter.next()) |cursor| {
        const id = try evt.readOrderKeyId(evt.UserDB, cursor);
        const id_hex = std.fmt.bytesToHex(id, .lower);
        if (items.items.len == page_size) {
            next_id = try aa.dupe(u8, &id_hex);
            break;
        }
        const path = try fork.forkPath(aa, users_dir, &user_id, &id);
        // a fork shares its target's hash kind
        var fork_repo = rp.Repo(.xit, .{ .hash = repo_opts.hash }).open(io, arena.child_allocator, .{ .path = path, .require_repo_root = true }) catch |err| {
            if (strict and !isMissingFork(err)) return err;
            continue;
        };
        defer fork_repo.deinit(io, arena.child_allocator);
        const record = (try evt.Fork.readById(evt.UserDB, evt.user_repo_opts.hash, user_moment, arena, &id)) orelse continue;
        const fork_identity = try aa.print("{s}:{s}", .{ user_name, record.event.repo_name });
        const entry = (try draftEntry(strict, repo_kind, repo_opts, arena, io, admin_moment, &fork_repo, target_repo, id, fork_identity)) orelse continue;
        try items.append(aa, entry);
    }
    return .{
        .items = items.items,
        .prev_id = prev_id,
        .next_id = next_id,
        .count = @intCast(try set.count()),
    };
}

// the draft `id` in its opened fork, or null when the fork holds no such
// patch. the page shows a fork it can't read as no draft, and an unreadable
// newest revision as an unknown commit count.
pub fn loadDraftEntry(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    fork_repo: *rp.Repo(.xit, .{ .hash = repo_opts.hash }),
    target_repo: *rp.Repo(repo_kind, repo_opts),
    id: [evt.event_id_size]u8,
    fork_identity: []const u8,
) !?PatchWithId {
    return try draftEntry(false, repo_kind, repo_opts, arena, io, admin_moment, fork_repo, target_repo, id, fork_identity);
}

// the entry `loadDraftEntry` reads; a `strict` one fails where the page
// falls back
fn draftEntry(
    comptime strict: bool,
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    fork_repo: *rp.Repo(.xit, .{ .hash = repo_opts.hash }),
    target_repo: *rp.Repo(repo_kind, repo_opts),
    id: [evt.event_id_size]u8,
    fork_identity: []const u8,
) !?PatchWithId {
    const aa = arena.allocator();
    const id_hex = std.fmt.bytesToHex(id, .lower);
    const fork_oid = (try fork_repo.readRef(io, fork.ref)) orelse return null;
    // a fork with no events holds no draft
    const moment = evt.currentMoment(.{ .hash = repo_opts.hash }, fork_repo) catch |err| {
        if (strict and !thread.isNoEvents(err)) return err;
        return null;
    };
    const patch = (try evt.Patch.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, moment, arena, &id)) orelse return null;
    const target_branch = patch.event.target_branch;
    const target_oid = try target_repo.readRef(io, .{ .kind = .head, .name = target_branch });
    const commit_count: ?u64 = blk: {
        // a draft with no revision yet reads as null, so what this fails
        // with is storage
        const newest = evt.PatchRev.readNewest(evt.EventDB(repo_opts.hash), repo_opts.hash, moment, arena) catch |err| {
            if (strict) return err;
            break :blk null;
        };
        break :blk if (newest) |revision| revision.record.commit_count else 0;
    };
    return .{
        .id = try aa.dupe(u8, &id_hex),
        .record = patch,
        .author = try ui.Author.initFromEmail(admin_moment, arena, patch.author_email),
        .draft = true,
        .revision_oid = try aa.dupe(u8, &fork_oid),
        .commit_count = commit_count,
        .no_changes = if (target_oid) |oid| std.mem.eql(u8, &oid, &fork_oid) else false,
        .fork_exists = true,
        .fork_identity = try aa.dupe(u8, fork_identity),
    };
}

pub const View = thread.View(.patch, Self);
pub const Detail = thread.Detail(.patch, Self);
pub const detail_widget_name = "repo_patch_detail";

pub const Header = thread.Header;

const open_tab_label = "open";
const closed_tab_label = "closed";
const merged_tab_label = "merged";
const labels_tab_label = "labels";
const edit_tab_label = "edit";
const publish_tab_label = "publish";
const merge_tab_label = "merge";
const reply_tab_label = "reply";
const remove_tab_label = "remove";
const resolve_tab_label = "resolve";
const new_tab_label = "new";
const drafts_tab_label = "drafts";
const conflicts_tab_label = "conflicts";

pub fn appendDetails(_: *const Self, allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), session: *ui.Session, entry: Entry) !void {
    const aa = session.page_arena.allocator();
    const status_kind = entry.record.event.status.kind();
    const target_branch = entry.record.event.target_branch;

    if (status_kind != .merged and entry.fork_exists) if (session.data.git_ssh_url) |ssh_url| {
        const url = try aa.print("{s}/{s}+{s}", .{ ssh_url, entry.fork_identity, entry.id });
        const push_command = try aa.print("git push {s} HEAD:patch", .{url});
        const clone_command = try aa.print("git clone {s}", .{url});
        const merge_command = try aa.print("git fetch '{s}' refs/heads/patch && git merge FETCH_HEAD", .{url});
        const choices = [_]ui.widget.CopyableText.Choice{
            .{
                .selector = "push",
                .text = push_command,
                .copyable_text = try aa.print("{s}{s}", .{ session.data.git_ssh_prefix, push_command }),
                .label = " push to this patch from existing repo ",
            },
            .{
                .selector = "clone",
                .text = clone_command,
                .copyable_text = try aa.print("{s}{s}", .{ session.data.git_ssh_prefix, clone_command }),
                .label = " clone this patch ",
            },
            .{
                .selector = "merge",
                .text = merge_command,
                .copyable_text = try aa.print("{s}{s}", .{ session.data.git_ssh_prefix, merge_command }),
                .label = " merge this patch locally ",
            },
        };
        var copyable_text = try ui.widget.CopyableText.init(allocator, session, if (entry.target_deleted) choices[1..] else &choices, 0);
        errdefer copyable_text.deinit(allocator);
        try box.children.put(allocator, copyable_text.getFocus().id, .{ .widget = .{ .copyable_text = copyable_text }, .rect = null, .min_size = null });
    };
    if (entry.record.event.source_branch) |branch| {
        var source = try wgt.TextBox.init(allocator, branch, .{ .top_label = .{ .text = " source branch " }, .border = .single, .round_corners = true, .wrap_kind = .none });
        errdefer source.deinit(allocator);
        source.getFocus().mode = .all;
        try box.children.put(allocator, source.getFocus().id, .{ .widget = .{ .text_box = source }, .rect = null, .min_size = null });
    }
    const fields = [_]ui.widget.CopyableText.Choice{
        .{
            .selector = "from",
            .text = entry.revision_oid,
            .label = if (entry.no_changes) " object id of this patch (no changes) " else " object id of this patch ",
        },
        .{
            .selector = "to",
            .text = target_branch,
            .label = if (status_kind == .merged) " target branch this patch was merged into " else " target branch this patch will go to ",
        },
    };
    var copyable_text = try ui.widget.CopyableText.init(allocator, session, fields[@intFromBool(entry.revision_oid.len == 0)..], 0);
    errdefer copyable_text.deinit(allocator);
    try box.children.put(allocator, copyable_text.getFocus().id, .{ .widget = .{ .copyable_text = copyable_text }, .rect = null, .min_size = null });
}

// tabs switching between the patches page's views
pub fn initHeader(allocator: std.mem.Allocator, session: *ui.Session, data: *const Self) !Header {
    const selected_index = View.viewIndex(data.view);
    const action = View.searchListRoute(data.identity, selected_index) orelse return error.RouteTooLong;
    var header = try Header.init(allocator, session, data.search, " search ", action);
    errdefer header.deinit(allocator);
    const page_selected = std.meta.activeTag(session.data.current_page) == .repo_patches;

    // a list tab per status, labeled with its listing's patch count
    const status_labels = [_][]const u8{ open_tab_label, closed_tab_label, merged_tab_label };
    for ([_]Status{ .open, .closed, .merged }, status_labels, 0..) |status, status_label, index| {
        const route = try thread.searchRoute(ui.RoutablePage.repoPatchesRoute(data.identity, status, ""), data.search);
        const link = try ui.inPageTabLink(session, route, page_selected and selected_index == index);
        try header.addTab(allocator, status_label, try thread.countLabel(session, data.window(status).*), link, index);
    }

    // labels tab
    {
        const labels_route = try thread.searchRoute(ui.RoutablePage.repoThreadLabelsRoute(.patch, data.identity), data.search);
        const labels_link = try ui.inPageTabLink(session, labels_route, page_selected and selected_index == View.viewIndex(.labels));
        try header.addTab(allocator, labels_tab_label, "", labels_link, View.viewIndex(.labels));
    }

    // new-patch tab; an edit or resolve url shows its tab in this place
    {
        const route = switch (data.view) {
            .edit => ui.RoutablePage.repoThreadEditRoute(.patch, data.identity, data.selected_id) orelse return error.RouteTooLong,
            .publish => ui.RoutablePage.repoPatchPublishRoute(data.identity, data.selected_id) orelse return error.RouteTooLong,
            .merge => ui.RoutablePage.repoPatchMergeRoute(data.identity, data.selected_id) orelse return error.RouteTooLong,
            .new_comment => ui.RoutablePage.repoThreadCommentNewRoute(.patch, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
            .edit_comment => ui.RoutablePage.repoThreadCommentEditRoute(.patch, data.identity, data.selected_id, data.comment_id) orelse return error.RouteTooLong,
            .remove => ui.RoutablePage.repoThreadRemoveRoute(.patch, data.identity, data.selected_id, data.comment_id, "") orelse return error.RouteTooLong,
            .resolve => ui.RoutablePage.repoPatchesResolveRoute(data.identity, data.selected_id, data.theirs_picks) orelse return error.RouteTooLong,
            else => ui.RoutablePage.repoThreadNewRoute(.patch, data.identity) orelse return error.RouteTooLong,
        };
        const link = try ui.inPageTabLink(session, route, page_selected and selected_index == View.viewIndex(.new));
        const label: []const u8 = switch (data.view) {
            .edit => edit_tab_label,
            .publish => publish_tab_label,
            .merge => merge_tab_label,
            .new_comment => reply_tab_label,
            .edit_comment => edit_tab_label,
            .remove => remove_tab_label,
            .resolve => resolve_tab_label,
            else => new_tab_label,
        };
        try header.addTab(allocator, label, "", link, View.viewIndex(.new));
    }

    // drafts belong to the logged-in user and are not available locally
    if (session.data.host_kind != .local) {
        const route = ui.RoutablePage.repoPatchesDraftsRoute(data.identity) orelse return error.RouteTooLong;
        const link = try ui.inPageTabLink(session, route, page_selected and selected_index == View.viewIndex(.drafts));
        try header.addTab(allocator, drafts_tab_label, try session.page_arena.allocator().print("({d})", .{data.drafts.count}), link, View.viewIndex(.drafts));
    }

    // conflicts tab, labeled with the conflict count
    if (data.conflicts.count > 0) {
        const route = ui.RoutablePage.repoPatchesConflictsRoute(data.identity, "") orelse return error.RouteTooLong;
        const link = try ui.inPageTabLink(session, route, page_selected and selected_index == View.viewIndex(.conflicts));
        try header.addTab(allocator, conflicts_tab_label, try session.page_arena.allocator().print("({d})", .{data.conflicts.count}), link, View.viewIndex(.conflicts));
    }

    header.select(View.viewIndex(data.view));
    return header;
}
