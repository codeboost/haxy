const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../../event.zig");
const copy = @import("../../copy.zig");
const ui = @import("../../ui.zig");
const thread_write = @import("../../thread_write.zig");
const inp = @import("../input.zig");
const xit = @import("xit");
const rp = xit.repo;
const rf = xit.ref;
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const active_tab_label = "active";
const removed_tab_label = "removed";

pub const page_size = 20;

/// how many events each view's window holds: the shown view's and the
/// other's (which is read for its count alone when 0)
pub const WindowSizes = struct {
    shown: usize = page_size,
    others: usize = page_size,
};

/// the thread or comment an event opens. `thread_kind` is a thread kind
/// (discuss, issue or patch) the repo has turned on; ids are hex.
pub const Target = union(enum) {
    thread: struct { thread_kind: evt.EventKind, thread: []const u8 },
    comment: struct { thread_kind: evt.EventKind, thread: []const u8, comment: []const u8 },

    /// the TUI's url of the target, or null when no route can name it
    pub fn url(self: Target, arena: *std.heap.ArenaAllocator, identity: []const u8) !?[]const u8 {
        const route = switch (self) {
            .thread => |thread| ui.RoutablePage.repoThreadCommentsRoute(thread.thread_kind, identity, thread.thread, 0),
            .comment => |comment| ui.RoutablePage.repoThreadCommentRoute(comment.thread_kind, identity, comment.thread, comment.comment, 0),
        } orelse return null;
        return try route.toUrl(arena);
    }
};

pub const Item = struct {
    id: []const u8,
    kind: evt.EventKind,
    author: ui.Author,
    // when the event was created, for kinds whose records keep it
    created_timestamp: ?u64 = null,
    // what the event's detail opens; only active events have one
    target: ?Target = null,
    view_url: ?[]const u8 = null,
};

pub const EventRef = struct {
    id: []const u8,
    kind: evt.EventKind,
};

pub const Window = struct {
    count: usize = 0,
    events: []const Item = &.{},
    next: ?EventRef = null,

    // a window without events, which shows the empty message
    fn isEmpty(self: *const Window) bool {
        return self.events.len == 0;
    }
};

identity: []const u8,
view: ui.RoutablePage.EventsView,
selected: ?EventRef,
active: Window,
removed: Window,
header: Header,
// set when the list is limited to the events one transaction wrote
moment: ?u64 = null,

const Self = @This();

pub fn init(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    identity: []const u8,
    repo_event: evt.Repo,
    requested_view: ui.RoutablePage.EventsView,
    selected_kind: ?evt.EventKind,
    selected: []const u8,
    moment_index: ?u64,
    local: bool,
    failure: ?[]const u8,
    window_sizes: WindowSizes,
) !Self {
    const aa = arena.allocator();
    var result = try empty(aa, identity, requested_view, local, failure);
    result.moment = moment_index;
    if (local) result.header = try Header.local(repo_kind, repo_opts, aa, repo, io, failure);
    const require_selected_event = selected_kind != null or selected.len != 0;
    if ((selected_kind == null) != (selected.len == 0)) return error.NotFound;

    const DB = evt.EventDB(repo_opts.hash);
    const gpa = arena.child_allocator;
    var event_db_maybe: ?evt.LocalEventDB(repo_opts.hash) = if (repo_kind == .git) try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, gpa, repo.core.repo_dir) else null;
    defer if (event_db_maybe) |*event_db| event_db.deinit(io, gpa);
    const haxy_moment = (if (moment_index) |index|
        transactionMoment(repo_kind, repo_opts, repo, index)
    else if (event_db_maybe) |*event_db|
        evt.currentMomentFromDb(repo_opts.hash, event_db.db)
    else if (repo_kind == .git)
        return result
    else
        evt.currentMoment(repo_opts, repo)) catch {
        // a moment page names a transaction it can't show
        if (require_selected_event or moment_index != null) return error.NotFound;
        return result;
    };

    const kind_map_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.event_index_key)) orelse {
        if (require_selected_event) return error.NotFound;
        return result;
    };
    const kind_map = try DB.HashMap(.read_only).init(kind_map_cursor);

    const active_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.active_event_id_set_key));
    const removed_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.removed_event_id_set_key));

    var root_key: ?[@sizeOf(u64) + evt.event_id_size]u8 = null;
    if (selected.len != 0) {
        var id: [evt.event_id_size]u8 = undefined;
        _ = std.fmt.hexToBytes(&id, selected) catch return error.NotFound;
        if (!std.mem.eql(u8, selected, &std.fmt.bytesToHex(id, .lower))) return error.NotFound;
        const kind = selected_kind orelse return error.NotFound;
        const stored_kind = (try evt.readEventKind(repo_opts.hash, kind_map, &id)) orelse return error.NotFound;
        if (stored_kind != kind) return error.NotFound;
        result.selected = .{ .id = try aa.dupe(u8, selected), .kind = kind };
        const meta = try readMeta(repo_opts.hash, arena, haxy_moment, kind, &id);
        result.view = if (meta.removed) .removed else .active;
        root_key = evt.orderKeyDesc(meta.updated_order, &id);
    }

    if (moment_index != null) {
        try readMomentEvents(repo_kind, repo_opts, arena, &result, haxy_moment, kind_map, admin_moment, identity, repo_event, selected, window_sizes);
        return result;
    }

    for ([_]ui.RoutablePage.EventsView{ .active, .removed }) |view| {
        const id_set_cursor = switch (view) {
            .active => active_cursor,
            .removed => removed_cursor,
        };
        const event_window = switch (view) {
            .active => &result.active,
            .removed => &result.removed,
        };
        const id_set = try DB.SortedSet(.read_only).init(id_set_cursor orelse {
            if (require_selected_event and result.view == view) return error.NotFound;
            continue;
        });
        event_window.count = @intCast(try id_set.count());
        const selected_key = if (result.view == view) root_key else null;
        if (selected_key) |*key| if (!try id_set.contains(key)) return error.NotFound;

        const size = if (result.view == view) window_sizes.shown else window_sizes.others;
        var iter = if (selected_key) |*key| try id_set.iteratorFrom(key) else try id_set.iteratorFromIndex(0);
        var events: std.ArrayList(Item) = .empty;
        while (try iter.next()) |cursor_value| {
            const id = try evt.readOrderKeyId(DB, cursor_value);
            const kind = (try evt.readEventKind(repo_opts.hash, kind_map, &id)) orelse continue;
            if (events.items.len == size) {
                event_window.next = .{ .id = try formatId(aa, &id), .kind = kind };
                break;
            }
            const item = (try readItem(repo_opts.hash, arena, haxy_moment, kind_map, admin_moment, identity, repo_event, view == .active, kind, &id)) orelse continue;
            try events.append(aa, item);
        }
        event_window.events = events.items;
    }
    return result;
}

// the haxy state as of one transaction in the repo history. a moment page
// reads from it, so undoing or rebasing later transactions cannot change what
// it shows, and the events read as they were when the transaction ran
fn transactionMoment(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    repo: *rp.Repo(repo_kind, repo_opts),
    index: u64,
) !evt.EventDB(repo_opts.hash).HashMap(.read_only) {
    if (repo_kind == .git) return error.NotFound;
    if (try copy.undoFloor(repo_opts, &repo.core)) |floor| if (index < floor) return error.NotFound;
    return try evt.currentMomentFromRepoMoment(repo_opts.hash, try repo.core.momentAt(index));
}

// the moment's set is keyed on the event order, not the update order the
// active and removed sets use, so it gets its own walk. one transaction's
// events are few, so the whole set is scanned to count both views.
fn readMomentEvents(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    result: *Self,
    haxy_moment: evt.EventDB(repo_opts.hash).HashMap(.read_only),
    kind_map: evt.EventDB(repo_opts.hash).HashMap(.read_only),
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    identity: []const u8,
    repo_event: evt.Repo,
    selected: []const u8,
    window_sizes: WindowSizes,
) !void {
    const DB = evt.EventDB(repo_opts.hash);
    const aa = arena.allocator();
    // the moment names its own position, so the page needs no index from the
    // url. a transaction that consumed nothing has no set of its own, which
    // leaves the list empty rather than failing the page: the terminal hosts
    // build their pages inside the run loop, where an error ends the session
    const index_cursor = try haxy_moment.getCursor(hash.hashInt(repo_opts.hash, evt.moment_index_key)) orelse return;
    const ids = try evt.momentEventIds(DB, repo_opts.hash, haxy_moment, try index_cursor.readUint()) orelse return;

    var events: [2]std.ArrayList(Item) = .{ .empty, .empty };
    // the selected event's window starts at it, not at the top
    var awaiting_selected = selected.len != 0;

    var iter = try ids.iterator();
    while (try iter.next()) |cursor_value| {
        const id = try evt.readOrderKeyId(DB, cursor_value);
        const kind = (try evt.readEventKind(repo_opts.hash, kind_map, &id)) orelse continue;
        const meta = try readMeta(repo_opts.hash, arena, haxy_moment, kind, &id);
        const view: ui.RoutablePage.EventsView = if (meta.removed) .removed else .active;
        const event_window = switch (view) {
            .active => &result.active,
            .removed => &result.removed,
        };
        event_window.count += 1;
        if (awaiting_selected and view == result.view) {
            if (!std.mem.eql(u8, selected, &std.fmt.bytesToHex(id, .lower))) continue;
            awaiting_selected = false;
        }
        const window_events = &events[@backingInt(view)];
        const size = if (result.view == view) window_sizes.shown else window_sizes.others;
        if (window_events.items.len == size) {
            if (event_window.next == null) event_window.next = .{ .id = try formatId(aa, &id), .kind = kind };
            continue;
        }
        const item = (try readItem(repo_opts.hash, arena, haxy_moment, kind_map, admin_moment, identity, repo_event, view == .active, kind, &id)) orelse continue;
        try window_events.append(aa, item);
    }
    // the window start can name an event this batch no longer holds
    if (awaiting_selected) return;
    result.active.events = events[@backingInt(ui.RoutablePage.EventsView.active)].items;
    result.removed.events = events[@backingInt(ui.RoutablePage.EventsView.removed)].items;
}

pub fn empty(aa: std.mem.Allocator, identity: []const u8, view: ui.RoutablePage.EventsView, local: bool, failure: ?[]const u8) !Self {
    return .{
        .identity = try aa.dupe(u8, identity),
        .view = view,
        .selected = null,
        .active = .{},
        .removed = .{},
        .header = if (local) try Header.empty(aa, failure) else Header.remote(),
    };
}

fn window(self: *const Self, view: ui.RoutablePage.EventsView) *const Window {
    return switch (view) {
        .active => &self.active,
        .removed => &self.removed,
    };
}

fn formatId(aa: std.mem.Allocator, id: *const [evt.event_id_size]u8) ![]const u8 {
    const hex = std.fmt.bytesToHex(id.*, .lower);
    return try aa.dupe(u8, &hex);
}

const EventMeta = struct {
    updated_order: u64,
    removed: bool,
};

fn readMeta(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
    kind: evt.EventKind,
    id: *const [evt.event_id_size]u8,
) !EventMeta {
    return switch (kind) {
        inline else => |event_kind| blk: {
            const T = switch (event_kind) {
                .user => evt.User,
                .repo => evt.Repo,
                .fork => evt.Fork,
                .grant => evt.Grant,
                .notify => evt.Notify,
                .discuss => evt.Discussion,
                .issue => evt.Issue,
                .comment => evt.Comment,
                .attach => evt.Attachment,
                .assign => evt.Assignment,
                .patchrev => evt.PatchRev,
                .patch => evt.Patch,
            };
            break :blk (try evt.readRecordSubset(T, EventMeta, evt.EventDB(hash_kind), hash_kind, haxy_moment, arena, id)) orelse return error.NotFound;
        },
    };
}

fn readItem(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
    kind_map: evt.EventDB(hash_kind).HashMap(.read_only),
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    identity: []const u8,
    repo_event: evt.Repo,
    include_target: bool,
    kind: evt.EventKind,
    id: *const [evt.event_id_size]u8,
) !?Item {
    var item = (try readItemTarget(hash_kind, arena, haxy_moment, kind_map, admin_moment, repo_event, include_target, kind, id)) orelse return null;
    if (item.target) |target| item.view_url = try target.url(arena, identity);
    return item;
}

// an event's row: its author, when it was created, and (for `include_target`)
// the thread or comment it opens in a thread tab the repo has turned on
fn readItemTarget(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    haxy_moment: evt.EventDB(hash_kind).HashMap(.read_only),
    kind_map: evt.EventDB(hash_kind).HashMap(.read_only),
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    repo_event: evt.Repo,
    include_target: bool,
    kind: evt.EventKind,
    id: *const [evt.event_id_size]u8,
) !?Item {
    const DB = evt.EventDB(hash_kind);
    const aa = arena.allocator();
    // the parts of a record a row shows
    const Authored = struct { author_email: ?[]const u8 };
    const Created = struct { author_email: ?[]const u8, created_timestamp: u64 };
    const Owned = struct { event: struct { user_id: [evt.event_id_size * 2]u8 } };
    var item: Item = .{
        .id = try formatId(aa, id),
        .kind = kind,
        .author = .unknown,
    };
    switch (kind) {
        .user => {
            const record = (try evt.readRecordSubset(evt.User, struct { event: struct { email: []const u8 } }, DB, hash_kind, haxy_moment, arena, id)) orelse return null;
            item.author = try ui.Author.initFromEmail(admin_moment, arena, record.event.email);
        },
        .repo => {
            const record = (try evt.readRecordSubset(evt.Repo, Owned, DB, hash_kind, haxy_moment, arena, id)) orelse return null;
            if (admin_moment) |moment| {
                if (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, arena, &try evt.parseEventId(&record.event.user_id))) |user|
                    item.author = .{ .user_name = user.event.name };
            }
        },
        .fork => _ = (try evt.readRecordSubset(evt.Fork, struct { removed: bool }, DB, hash_kind, haxy_moment, arena, id)) orelse return null,
        .grant => _ = (try evt.readRecordSubset(evt.Grant, struct { removed: bool }, DB, hash_kind, haxy_moment, arena, id)) orelse return null,
        .notify => _ = (try evt.readRecordSubset(evt.Notify, struct { removed: bool }, DB, hash_kind, haxy_moment, arena, id)) orelse return null,
        inline .discuss, .issue, .patch => |thread_kind| {
            const T = switch (thread_kind) {
                .discuss => evt.Discussion,
                .issue => evt.Issue,
                .patch => evt.Patch,
                else => comptime unreachable,
            };
            const record = (try evt.readRecordSubset(T, Created, DB, hash_kind, haxy_moment, arena, id)) orelse return null;
            item.author = try ui.Author.initFromEmail(admin_moment, arena, record.author_email);
            item.created_timestamp = record.created_timestamp;
            if (include_target and repo_event.threadRole(thread_kind) != null)
                item.target = .{ .thread = .{ .thread_kind = thread_kind, .thread = item.id } };
        },
        .comment => {
            const record = (try evt.readRecordSubset(evt.Comment, struct { author_email: ?[]const u8, created_timestamp: u64, event: struct { thread_id: [evt.event_id_size * 2]u8 } }, DB, hash_kind, haxy_moment, arena, id)) orelse return null;
            item.author = try ui.Author.initFromEmail(admin_moment, arena, record.author_email);
            item.created_timestamp = record.created_timestamp;
            if (!include_target) return item;
            var thread_id: [evt.event_id_size]u8 = undefined;
            _ = std.fmt.hexToBytes(&thread_id, &record.event.thread_id) catch return error.InvalidEventId;
            const thread_kind = (try evt.readEventKind(hash_kind, kind_map, &thread_id)) orelse return item;
            if (repo_event.threadRole(thread_kind) == null) return item;
            item.target = .{ .comment = .{ .thread_kind = thread_kind, .thread = try aa.dupe(u8, &record.event.thread_id), .comment = item.id } };
        },
        .attach => {
            const record = (try evt.readRecordSubset(evt.Attachment, struct { author_email: ?[]const u8, event: struct { target_id: [evt.event_id_size * 2]u8 } }, DB, hash_kind, haxy_moment, arena, id)) orelse return null;
            item.author = try ui.Author.initFromEmail(admin_moment, arena, record.author_email);
            if (!include_target) return item;
            const target_id = try evt.parseEventId(&record.event.target_id);
            const target_kind = (try evt.readEventKind(hash_kind, kind_map, &target_id)) orelse return item;
            if (repo_event.threadRole(target_kind) == null) return item;
            item.target = .{ .thread = .{ .thread_kind = target_kind, .thread = try aa.dupe(u8, &record.event.target_id) } };
        },
        .assign => {
            const record = (try evt.readRecordSubset(evt.Assignment, Authored, DB, hash_kind, haxy_moment, arena, id)) orelse return null;
            item.author = try ui.Author.initFromEmail(admin_moment, arena, record.author_email);
        },
        .patchrev => {
            const record = (try evt.readRecordSubset(evt.PatchRev, Authored, DB, hash_kind, haxy_moment, arena, id)) orelse return null;
            item.author = try ui.Author.initFromEmail(admin_moment, arena, record.author_email);
        },
    }
    return item;
}

pub const View = struct {
    box: wgt.Box(ui.Widget),
    data: *const Self,
    session: *ui.Session,
    detailed_index: [2]?usize,

    const header_index = 0;
    const content_index = 1;
    const list_index = 0;
    const detail_index = 1;
    const list_max_width = 20;
    const detail_min_width = 40;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var outer = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer outer.deinit(allocator);

        var header_view = try Header.View.init(allocator, data, session);
        errdefer header_view.deinit(allocator);
        // a row taller than the header, leaving a blank line beneath it
        try outer.children.put(allocator, header_view.getFocus().id, .{ .widget = .{ .repo_events_header = header_view }, .rect = null, .min_size = .{ .width = null, .height = 4 } });

        var content_stack = try wgt.Stack(ui.Widget).init(allocator);
        errdefer content_stack.deinit(allocator);
        inline for ([_]ui.RoutablePage.EventsView{ .active, .removed }) |view| {
            var view_content = try initContent(allocator, data, session, view);
            errdefer view_content.deinit(allocator);
            try content_stack.children.put(allocator, view_content.getFocus().id, view_content);
        }
        content_stack.getFocus().child_id = content_stack.children.keys()[@backingInt(data.view)];
        try outer.children.put(allocator, content_stack.getFocus().id, .{ .widget = .{ .stack = content_stack }, .rect = null, .min_size = null });
        outer.getFocus().child_id = outer.children.keys()[content_index];
        return .{ .box = outer, .data = data, .session = session, .detailed_index = .{ null, null } };
    }

    // an empty window shows the empty message in place of the list and detail
    fn initContent(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session, view: ui.RoutablePage.EventsView) !ui.Widget {
        const event_window = data.window(view);
        if (event_window.isEmpty()) return .{ .center = try ui.widget.initEmpty(allocator) };

        var content_box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .horiz });
        errdefer content_box.deinit(allocator);

        var list_box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert, .stretch = true });
        errdefer list_box.deinit(allocator);
        for (event_window.events) |event| {
            const route = ui.RoutablePage.repoEventsRoute(data.identity, view, event.kind, event.id, data.moment) orelse return error.RouteTooLong;
            const link = try session.page_arena.allocator().print("ai:{s}", .{try route.toUrl(session.page_arena)});
            try addRow(allocator, &list_box, @tagName(event.kind), link);
        }
        if (event_window.next) |next| {
            const route = ui.RoutablePage.repoEventsRoute(data.identity, view, next.kind, next.id, data.moment) orelse return error.RouteTooLong;
            const link = try session.page_arena.allocator().print("a:{s}", .{try route.toUrl(session.page_arena)});
            try addRow(allocator, &list_box, "next →", link);
        }
        if (list_box.children.count() > 0) list_box.getFocus().child_id = list_box.children.keys()[0];
        var list_scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .box = list_box }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
        errdefer list_scroll.deinit(allocator);
        try content_box.children.put(allocator, list_scroll.getFocus().id, .{ .widget = .{ .scroll = list_scroll }, .rect = null, .min_size = .{ .width = list_max_width, .height = null }, .max_size = .{ .width = list_max_width, .height = null } });

        // the detail scroll, below the way back to a hidden list
        var frame = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer frame.deinit(allocator);
        try ui.widget.addListBack(allocator, &frame, "← back to event list");
        {
            var detail_box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
            errdefer detail_box.deinit(allocator);
            var detail_scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .box = detail_box }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true });
            errdefer detail_scroll.deinit(allocator);
            detail_scroll.getFocus().mode = .mouse;
            frame.getFocus().child_id = detail_scroll.getFocus().id;
            try frame.children.put(allocator, detail_scroll.getFocus().id, .{ .widget = .{ .scroll = detail_scroll }, .rect = null, .min_size = null });
        }
        try content_box.children.put(allocator, frame.getFocus().id, .{ .widget = .{ .box = frame }, .rect = null, .min_size = .{ .width = detail_min_width, .height = null } });

        content_box.getFocus().child_id = content_box.children.keys()[detail_index];
        return .{ .box = content_box };
    }

    fn addRow(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), text: []const u8, link: []const u8) !void {
        var row = try wgt.TextBox.init(allocator, text, .{ .border = .hidden, .round_corners = true, .wrap_kind = .none });
        errdefer row.deinit(allocator);
        row.getFocus().mode = .all;
        row.getFocus().kind = .{ .custom = link };
        try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .text_box = row }, .rect = null, .min_size = null });
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    fn header(self: *View) *Header.View {
        return &self.box.children.values()[header_index].widget.repo_events_header;
    }

    fn contentStack(self: *View) *wgt.Stack(ui.Widget) {
        return &self.box.children.values()[content_index].widget.stack;
    }

    fn selectedView(self: *View) ui.RoutablePage.EventsView {
        const stack = self.contentStack();
        const id = stack.getFocus().child_id orelse return .active;
        return @fromBackingInt(@intCast(stack.children.getIndex(id) orelse 0));
    }

    fn eventWindow(self: *View) *const Window {
        return self.data.window(self.selectedView());
    }

    fn content(self: *View) *wgt.Box(ui.Widget) {
        const stack = self.contentStack();
        return &stack.children.values()[@backingInt(self.selectedView())].box;
    }

    fn listScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.content().children.values()[list_index].widget.scroll;
    }

    fn listBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.listScroll().child.box;
    }

    fn detailFrame(self: *View) *wgt.Box(ui.Widget) {
        return &self.content().children.values()[detail_index].widget.box;
    }

    fn detailScroll(self: *View) *wgt.Scroll(ui.Widget) {
        return &self.detailFrame().children.values()[ui.widget.list_pane_index].widget.scroll;
    }

    fn detailBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.detailScroll().child.box;
    }

    fn detailActive(self: *View) bool {
        return self.content().getFocus().child_id == self.detailFrame().getFocus().id;
    }

    fn headerActive(self: *View) bool {
        return self.box.getFocus().child_id == self.header().getFocus().id;
    }

    fn selectedEventIndex(self: *View) ?usize {
        const id = self.listBox().getFocus().child_id orelse return null;
        const index = self.listBox().children.getIndex(id) orelse return null;
        return if (index < self.eventWindow().events.len) index else null;
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        if (self.header().getSelectedIndex()) |index|
            self.contentStack().getFocus().child_id = self.contentStack().children.keys()[index];
        if (self.eventWindow().isEmpty()) return self.box.build(allocator, constraint, root_focus);
        try self.refreshDetail(allocator);

        const list = self.listBox();
        for (list.children.keys(), list.children.values()) |id, *child| switch (child.widget) {
            .text_box => |*text_box| ui.widget.markSelected(text_box, list.getFocus().child_id == id),
            else => {},
        };

        const both_fit = if (constraint.max_size.width) |width| width >= list_max_width + detail_min_width else true;
        ui.widget.showListBack(self.detailFrame(), !both_fit);
        if (ui.widget.listBackId(self.detailFrame())) |id| self.session.list_back = id;
        self.content().children.values()[list_index].max_size = if (both_fit) .{ .width = list_max_width, .height = null } else null;
        const detail_width = if (constraint.max_size.width) |width| if (both_fit) width - list_max_width else width else detail_min_width;
        self.content().children.values()[detail_index].min_size = .{ .width = detail_width, .height = null };
        for (self.detailBox().children.values()) |*child| child.max_size = .{ .width = detail_width -| 2, .height = null };

        try self.box.build(allocator, constraint, root_focus);
    }

    fn refreshDetail(self: *View, allocator: std.mem.Allocator) !void {
        const index = self.selectedEventIndex() orelse return;
        const detailed_index = &self.detailed_index[@backingInt(self.selectedView())];
        if (detailed_index.*) |old| if (old == index) return;
        const box = self.detailBox();
        for (box.children.values()) |*child| child.widget.deinit(allocator);
        box.children.clearAndFree(allocator);
        box.getFocus().child_id = null;

        const item = self.eventWindow().events[index];
        if (item.view_url) |url| {
            var link = try wgt.TextBox.init(allocator, "view event", .{ .border = .single, .round_corners = true, .wrap_kind = .none });
            errdefer link.deinit(allocator);
            link.getFocus().mode = .all;
            link.getFocus().kind = .{ .custom = try self.session.page_arena.allocator().print("a:{s}", .{url}) };
            try box.children.put(allocator, link.getFocus().id, .{ .widget = .{ .text_box = link }, .rect = null, .min_size = null });
        }
        {
            var kind = try wgt.TextBox.init(allocator, @tagName(item.kind), .{ .border = .single, .round_corners = true, .wrap_kind = .word, .top_label = .{ .text = " kind " } });
            errdefer kind.deinit(allocator);
            kind.getFocus().mode = .all;
            try box.children.put(allocator, kind.getFocus().id, .{ .widget = .{ .text_box = kind }, .rect = null, .min_size = null });
        }
        {
            var author = try ui.authorBox(allocator, self.session.page_arena, item.author);
            errdefer author.deinit(allocator);
            try box.children.put(allocator, author.getFocus().id, .{ .widget = .{ .text_box = author }, .rect = null, .min_size = null });
        }

        if (box.children.count() > 0) box.getFocus().child_id = box.children.keys()[0];
        self.detailScroll().x = 0;
        self.detailScroll().y = 0;
        self.detailScroll().getFocus().version +%= 1;
        ui.widget.setListBackLink(self.detailFrame(), self.listBox().children.values()[index].widget.text_box.getFocus().kind.custom);
        detailed_index.* = index;
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        // scrolling crosses the sub header boundary the same way arrows do
        const direction = inp.vertDirection(key);
        if (self.headerActive()) {
            if (direction == .down) {
                // the empty message has nothing to focus
                if (!self.eventWindow().isEmpty()) root_focus.setFocus(self.content().getFocus().id);
            } else try self.header().input(allocator, key, root_focus);
            return;
        }
        // the way back to the list, by enter or a click
        if (self.detailActive()) if (ui.widget.listBackId(self.detailFrame())) |id| {
            if (inp.activated(root_focus, id, key)) return self.focusList(root_focus);
            if (root_focus.grandchild_id == id) return switch (direction) {
                .up => self.header().focusCurrent(root_focus),
                .down => root_focus.setFocus(self.detailScroll().getFocus().id),
                .none => if (key == .arrow_left) self.focusList(root_focus),
            };
            if (direction == .up and self.contentAtTop()) return root_focus.setFocus(id);
        };
        if (direction == .up and self.contentAtTop()) {
            self.header().focusCurrent(root_focus);
            return;
        }
        if (self.detailActive()) {
            if (key == .arrow_left) {
                self.focusList(root_focus);
            } else if (inp.rowDelta(key, @intCast(self.detailBox().children.count()))) |delta| {
                ui.widget.moveRowFocus(self.detailBox(), self.detailScroll(), root_focus, delta);
            }
        } else if (inp.rowDelta(key, @intCast(self.listBox().children.count()))) |delta| {
            ui.widget.moveRowFocus(self.listBox(), self.listScroll(), root_focus, delta);
        } else switch (key) {
            .arrow_right => if (self.detailBox().children.count() > 0) self.focusDetail(root_focus),
            .enter => if (self.selectedEventIndex() != null) self.focusDetail(root_focus),
            // when the window is too narrow to lay out the detail pane beside
            // the list, a click on a row opens it like enter. the row was just
            // selected, so the detail is swapped to it ahead of the build.
            .mouse => |mouse| if (self.selectedEventIndex() != null and self.content().children.values()[detail_index].rect == null and ui.widget.clickOnSelectedRow(self.listBox(), root_focus, mouse)) {
                try self.refreshDetail(allocator);
                self.focusDetail(root_focus);
            },
            else => {},
        }
    }

    // enter the detail pane, landing on the way back to the list when it shows
    fn focusDetail(self: *View, root_focus: *Focus) void {
        if (ui.widget.listBackId(self.detailFrame()) != null) return ui.widget.focusListBack(self.detailFrame(), root_focus);
        root_focus.setFocus(self.detailScroll().getFocus().id);
    }

    fn focusList(self: *View, root_focus: *Focus) void {
        root_focus.setFocus(self.listScroll().getFocus().id);
    }

    fn contentAtTop(self: *View) bool {
        const box = if (self.detailActive()) self.detailBox() else self.listBox();
        const scroll = if (self.detailActive()) self.detailScroll() else self.listScroll();
        const id = box.getFocus().child_id orelse return true;
        return box.children.getIndex(id) == 0 and scroll.y == 0;
    }

    pub fn atTop(self: *View) bool {
        return self.headerActive();
    }

    // arriving from the page's tabs lands on the sub header, not the content
    pub fn focusHeader(self: *View, root_focus: *Focus) bool {
        self.header().focusCurrent(root_focus);
        return true;
    }

    pub fn clearGrid(self: *View) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.box.getFocus();
    }
};

pub const Header = struct {
    sync_status: ?[]const u8,

    const nothing = "nothing to sync";
    const unsynced = "sync needed!";

    const Progress = struct {
        message: *std.Io.Writer.Allocating,

        pub fn run(self: @This(), _: std.Io, event: rp.ProgressEvent) !void {
            switch (event) {
                .text => |value| {
                    self.message.clearRetainingCapacity();
                    try self.message.writer.writeAll(value);
                },
                else => {},
            }
        }
    };

    pub fn local(
        comptime repo_kind: rp.RepoKind,
        comptime repo_opts: rp.RepoOpts(repo_kind),
        aa: std.mem.Allocator,
        repo: *rp.Repo(repo_kind, repo_opts),
        io: std.Io,
        failure: ?[]const u8,
    ) !Header {
        if (failure != null) return Header.empty(aa, failure);
        const status = try syncStatus(repo_kind, repo_opts, repo, io, aa);
        // only local events the remote lacks need a sync here
        return .{ .sync_status = if (status.state == .sync_needed and status.local_events) unsynced else nothing };
    }

    pub fn empty(aa: std.mem.Allocator, failure: ?[]const u8) !Header {
        return .{ .sync_status = if (failure) |name| try aa.print("error: {s}", .{name}) else nothing };
    }

    pub fn remote() Header {
        return .{ .sync_status = null };
    }

    pub const View = struct {
        scroll: ui.widget.HeaderScroll,
        session: *ui.Session,
        tab_ids: [2]usize,
        // the tab stays selected while the sync button has focus
        selected_tab: usize,
        button_id: ?usize,

        pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !Header.View {
            var scroll = try ui.widget.HeaderScroll.init(allocator, session);
            errdefer scroll.deinit(allocator);
            const box = scroll.row();
            var tab_ids: [2]usize = undefined;
            const view_labels = [_][]const u8{ active_tab_label, removed_tab_label };
            inline for ([_]ui.RoutablePage.EventsView{ .active, .removed }, view_labels, 0..) |view, view_label, i| {
                const route = ui.RoutablePage.repoEventsRoute(data.identity, view, null, "", data.moment) orelse return error.RouteTooLong;
                const count_label = try session.page_arena.allocator().print("({d})", .{data.window(view).count});
                var tab = try wgt.TextBox.init(allocator, view_label, .{ .border = .hidden, .round_corners = true, .wrap_kind = .none, .bottom_label = .{ .text = count_label } });
                errdefer tab.deinit(allocator);
                tab.getFocus().mode = .all;
                const selected = std.meta.activeTag(session.data.current_page) == .repo_events and data.view == view;
                tab.getFocus().kind = .{ .custom = try ui.inPageTabLink(session, route, selected) };
                tab_ids[i] = tab.getFocus().id;
                try box.children.put(allocator, tab.getFocus().id, .{ .widget = .{ .text_box = tab }, .rect = null, .min_size = .{ .width = @max(view_label.len, count_label.len) + 2, .height = null } });
            }

            // pushes the sync button and status to the right
            {
                var spacer = try ui.widget.Spacer.init(allocator);
                errdefer spacer.deinit(allocator);
                try box.children.put(allocator, spacer.getFocus().id, .{ .widget = .{ .spacer = spacer }, .rect = null, .min_size = null, .flex = .grow });
            }

            var button_id: ?usize = null;
            if (data.header.sync_status != null) {
                box.getFocus().kind = .{ .custom = "form:/sync" };
                var button = try wgt.TextBox.init(allocator, "sync", .{ .border = .single, .round_corners = true, .wrap_kind = .none });
                errdefer button.deinit(allocator);
                button.getFocus().mode = .all;
                button.getFocus().kind = .{ .custom = "submit" };
                button_id = button.getFocus().id;
                try box.children.put(allocator, button.getFocus().id, .{ .widget = .{ .text_box = button }, .rect = null, .min_size = .{ .width = "sync".len + 2, .height = null } });
            }

            if (data.header.sync_status) |status_text| {
                var status = try wgt.TextBox.init(allocator, status_text, .{ .border = .hidden, .wrap_kind = .none });
                errdefer status.deinit(allocator);
                try box.children.put(allocator, status.getFocus().id, .{ .widget = .{ .text_box = status }, .rect = null, .min_size = null, .flex = .shrink });
            }
            box.getFocus().child_id = tab_ids[@backingInt(data.view)];
            return .{ .scroll = scroll, .session = session, .tab_ids = tab_ids, .selected_tab = @backingInt(data.view), .button_id = button_id };
        }

        pub fn deinit(self: *Header.View, allocator: std.mem.Allocator) void {
            self.scroll.deinit(allocator);
        }

        pub fn build(self: *Header.View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
            self.clearGrid();
            if (self.getSelectedIndex()) |index| self.selected_tab = index;
            for (self.tab_ids, 0..) |id, index| {
                const child = self.scroll.row().children.getPtr(id) orelse continue;
                const tab = switch (child.widget) {
                    .text_box => |*text_box| text_box,
                    else => continue,
                };
                ui.widget.markSelected(tab, index == self.selected_tab);
            }
            try self.scroll.build(allocator, constraint, root_focus);
        }

        pub fn input(self: *Header.View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
            const selected = self.scroll.row().getFocus().child_id orelse return;
            const stops = [_]?usize{ self.tab_ids[0], self.tab_ids[1], self.button_id };
            const count = 2 + @as(usize, @intFromBool(self.button_id != null));
            const current = std.mem.indexOfScalar(?usize, stops[0..count], selected) orelse return;
            if (inp.moveTab(key, current, count)) |next| {
                root_focus.setFocus(stops[next] orelse unreachable);
                return;
            }
            switch (key) {
                .enter => if (self.syncFocused()) try self.requestSync(allocator),
                .mouse => |mouse| if (self.button_id) |id| if (inp.leftClickOn(root_focus, id, mouse)) try self.requestSync(allocator),
                else => {},
            }
        }

        fn requestSync(self: *Header.View, allocator: std.mem.Allocator) !void {
            if (!self.session.is_terminal) return;
            if (self.session.host_request != null) return;
            const button_id = self.button_id orelse return;
            const child = self.scroll.row().children.getPtr(button_id) orelse return;
            const button = switch (child.widget) {
                .text_box => |*button| button,
                else => return,
            };
            try button.setContent(allocator, "syncing...");
            self.session.host_request = .sync_events;
        }

        fn syncFocused(self: *Header.View) bool {
            const button_id = self.button_id orelse return false;
            return self.scroll.row().getFocus().child_id == button_id;
        }

        pub fn getSelectedIndex(self: *Header.View) ?usize {
            const id = self.scroll.row().getFocus().child_id orelse return null;
            return std.mem.indexOfScalar(usize, &self.tab_ids, id);
        }

        pub fn focusCurrent(self: *Header.View, root_focus: *Focus) void {
            root_focus.setFocus(self.scroll.row().getFocus().child_id orelse self.tab_ids[0]);
        }

        pub fn clearGrid(self: *Header.View) void {
            self.scroll.clearGrid();
        }

        pub fn getGrid(self: Header.View) ?Grid {
            return self.scroll.getGrid();
        }

        pub fn getFocus(self: *Header.View) *Focus {
            return self.scroll.getFocus();
        }
    };
};

pub fn performSync(allocator: std.mem.Allocator, session: *ui.Session) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const io = session.io orelse return;
    const source = session.local orelse return;
    defer session.refresh_requested = true;
    const failure = sync(io, allocator, source) catch |err| {
        session.data.sync_failure = @errorName(err);
        return;
    };
    if (failure) |message| {
        defer allocator.free(message);
        session.data.sync_failure = try session.arena.allocator().dupe(u8, message);
        return;
    }
    session.data.sync_failure = null;
    switch (session.data.current_page) {
        .repo_events => |route| {
            if (ui.RoutablePage.repoEventsRoute(route.name.slice(), route.view, null, "", route.moment)) |first|
                session.data.current_page = first;
        },
        else => {},
    }
}

fn remoteName(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    allocator: std.mem.Allocator,
) !?[]u8 {
    var remotes = try repo.listRemotes(io, allocator);
    defer remotes.deinit();
    const names = remotes.sections.keys();
    if (names.len == 0) return null;
    for (names) |name| {
        const remote_ref: rf.Ref = .{ .kind = .{ .remote = name }, .name = evt.events_ref.name };
        if (try repo.readRef(io, remote_ref) != null) return try allocator.dupe(u8, name);
    }
    return try allocator.dupe(u8, names[0]);
}

fn isLoopbackSshUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    const host = switch (uri.host orelse return false) {
        .raw => |value| value,
        .percent_encoded => |value| value,
    };
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "[::1]");
}

/// how the events branch compares with the remote's, as last fetched. a sync
/// fetches before it compares, so this only says what the last fetch knew.
pub const SyncState = enum {
    // no remote is configured
    no_remote,
    // the remote's events were never fetched, so nothing is known
    not_fetched,
    // the events branch is the remote's, as last fetched
    in_sync,
    // they differ: one side has events the other lacks
    sync_needed,
};

pub const SyncStatus = struct {
    // the remote a sync reaches, null when none is configured
    remote: ?[]u8,
    state: SyncState,
    // whether the repo has an events branch of its own
    local_events: bool,
};

/// where the events branch stands against the remote a sync would reach
pub fn syncStatus(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    allocator: std.mem.Allocator,
) !SyncStatus {
    const local_oid = try repo.readRef(io, evt.events_ref);
    const remote_name = (try remoteName(repo_kind, repo_opts, repo, io, allocator)) orelse
        return .{ .remote = null, .state = .no_remote, .local_events = local_oid != null };
    const remote_ref: rf.Ref = .{ .kind = .{ .remote = remote_name }, .name = evt.events_ref.name };
    const remote_oid = (try repo.readRef(io, remote_ref)) orelse
        return .{ .remote = remote_name, .state = .not_fetched, .local_events = local_oid != null };
    const same = if (local_oid) |*oid| std.mem.eql(u8, oid, &remote_oid) else false;
    return .{ .remote = remote_name, .state = if (same) .in_sync else .sync_needed, .local_events = local_oid != null };
}

/// the step a sync failed at. what it leaves behind follows from the step:
/// up to and including the merge nothing changed (a merge that fails, e.g.
/// on fetched events Haxy can't read, moves neither the events branch nor the
/// remote's ref); a failed push has merged the remote's events here without
/// sending ours; a failed confirmation has sent them but couldn't re-read the
/// remote. local events are never discarded.
pub const SyncStage = enum {
    // finding the remote to reach
    remote,
    // fetching the remote's events
    fetch,
    // merging them into the events branch, and reading the result
    merge,
    // pushing the merged events branch
    push,
    // fetching again, to record what the remote now holds
    confirm,
};

pub const SyncFailure = struct {
    stage: SyncStage,
    err: anyerror,
    // what the remote reported, when it said why (owned)
    remote_message: ?[]u8 = null,
};

pub const SyncResult = union(enum) {
    synced,
    failed: SyncFailure,

    pub fn deinit(self: *SyncResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .synced => {},
            .failed => |failure| if (failure.remote_message) |message| allocator.free(message),
        }
    }
};

/// a finished sync, as `lastSync` reports it
pub const LastSync = struct {
    // drawn at random once per process, so a restarted Haxy's syncs never
    // reuse an earlier process's ids
    incarnation: [8]u8,
    // counts syncs since this process started
    id: u64,
    finished_at: i64,
    // null when it synced
    failure: ?struct {
        stage: SyncStage,
        err: []const u8,
        remote_message: ?[]const u8,
    },
    remote_message_buffer: [max_remote_message]u8,

    pub const max_id_text = 16 + 1 + 20;

    /// the sync's id as clients see it: unique across this process's syncs
    /// and every other process's
    pub fn idText(self: *const LastSync, buffer: *[max_id_text]u8) []const u8 {
        const incarnation = std.fmt.bytesToHex(self.incarnation, .lower);
        return std.fmt.bufPrint(buffer, "{s}-{d}", .{ &incarnation, self.id }) catch unreachable;
    }
};

// what a remote's message is cut to when kept as the last sync's
const max_remote_message = 1024;

// held for a whole sync, so a process runs one at a time (the TUI and the
// web API alike)
var sync_mutex: std.Io.Mutex = .init;
// guards whether a sync runs and the last one's record, which change together
// when a sync finishes
var last_mutex: std.Io.Mutex = .init;
var sync_running = false;
var last_sync: ?LastSync = null;
var sync_count: u64 = 0;
var process_incarnation: ?[8]u8 = null;

/// whether a sync is running in this process, and the last one it finished
/// (null before the first), read together: a sync that just finished is
/// either still running or already the last one, never neither
pub const SyncSnapshot = struct {
    running: bool,
    last: ?*const LastSync,
};

/// the sync snapshot, its record copied into `buffer`
pub fn syncSnapshot(io: std.Io, buffer: *LastSync) SyncSnapshot {
    last_mutex.lockUncancelable(io);
    defer last_mutex.unlock(io);
    return .{ .running = sync_running, .last = if (last_sync) |last| copyLast(last, buffer) else null };
}

/// whether a sync is running in this process now
pub fn syncRunning(io: std.Io) bool {
    last_mutex.lockUncancelable(io);
    defer last_mutex.unlock(io);
    return sync_running;
}

/// the last sync this process finished, copied into `buffer`; null before
/// the first
pub fn lastSync(io: std.Io, buffer: *LastSync) ?*const LastSync {
    return syncSnapshot(io, buffer).last;
}

fn setRunning(io: std.Io, running: bool) void {
    last_mutex.lockUncancelable(io);
    defer last_mutex.unlock(io);
    sync_running = running;
}

// `record` in `buffer`, its message pointing into the buffer's own copy
fn copyLast(record: LastSync, buffer: *LastSync) *const LastSync {
    buffer.* = record;
    if (buffer.failure) |*failure| {
        if (failure.remote_message) |message| failure.remote_message = buffer.remote_message_buffer[0..message.len];
    }
    return buffer;
}

fn recordSync(io: std.Io, result: SyncResult, copy_into: ?*LastSync) void {
    last_mutex.lockUncancelable(io);
    defer last_mutex.unlock(io);
    sync_count += 1;
    const this_process = process_incarnation orelse blk: {
        var bytes: [8]u8 = undefined;
        io.random(&bytes);
        process_incarnation = bytes;
        break :blk bytes;
    };
    // finished: no longer running, and the last sync, in one step
    sync_running = false;
    var record: LastSync = .{
        .incarnation = this_process,
        .id = sync_count,
        .finished_at = std.Io.Timestamp.now(io, .real).toSeconds(),
        .failure = null,
        .remote_message_buffer = undefined,
    };
    switch (result) {
        .synced => {},
        .failed => |failure| {
            var kept: ?[]const u8 = null;
            if (failure.remote_message) |message| {
                // cut at a character boundary; a message that isn't utf-8 isn't kept
                if (std.unicode.utf8ValidateSlice(message)) {
                    var len = @min(message.len, max_remote_message);
                    while (len < message.len and len > 0 and message[len] & 0xc0 == 0x80) len -= 1;
                    @memcpy(record.remote_message_buffer[0..len], message[0..len]);
                    kept = record.remote_message_buffer[0..len];
                }
            }
            record.failure = .{ .stage = failure.stage, .err = @errorName(failure.err), .remote_message = kept };
        },
    }
    last_sync = record;
    if (copy_into) |buffer| _ = copyLast(record, buffer);
}

/// syncs the events branch with the remote, as the TUI's sync button does:
/// fetch the remote's events, merge them with the shared event merge rules,
/// push the result, then fetch again so the remote's ref records it. only the
/// events branch moves, so the code HEAD and work tree stay as they are.
/// fetched events are merged only if the merged history can be read, so
/// events Haxy can't read never reach the events branch or the remote.
/// failures say which step failed; nothing here discards local events.
/// error.SyncInProgress when another sync is running in this process.
/// `record`, when given, gets this sync's record as `lastSync` keeps it.
pub fn runSync(io: std.Io, allocator: std.mem.Allocator, source: ui.RepoSource, record: ?*LastSync) !SyncResult {
    if (!sync_mutex.tryLock()) return error.SyncInProgress;
    defer sync_mutex.unlock(io);
    setRunning(io, true);
    // a sync that stopped with an error records nothing; it isn't running
    errdefer setRunning(io, false);
    const result = try runSyncLocked(io, allocator, source);
    recordSync(io, result, record);
    return result;
}

fn runSyncLocked(io: std.Io, allocator: std.mem.Allocator, source: ui.RepoSource) !SyncResult {
    var message: std.Io.Writer.Allocating = .init(allocator);
    defer message.deinit();

    switch (source.repo_kind) {
        inline else => |repo_kind| {
            var any_repo = try rp.AnyRepo(repo_kind, .{ .ProgressCtx = Header.Progress }).open(io, allocator, source.localInitOpts());
            defer any_repo.deinit(io, allocator);
            switch (any_repo) {
                inline else => |*repo| {
                    const repo_opts = repo.self_repo_opts;
                    const remote_name = (try remoteName(repo_kind, repo_opts, repo, io, allocator)) orelse
                        return .{ .failed = .{ .stage = .remote, .err = error.RemoteNotFound } };
                    defer allocator.free(remote_name);

                    var config = try repo.listConfig(io, allocator);
                    defer config.deinit();
                    const configured_ssh = if (config.sections.get("core")) |core| core.get("sshcommand") else null;
                    const ssh = if (configured_ssh) |command| if (command.len > 0) command else "ssh" else "ssh";
                    const remote_section = try allocator.print("remote.{s}", .{remote_name});
                    defer allocator.free(remote_section);
                    const remote_config = config.sections.get(remote_section) orelse
                        return .{ .failed = .{ .stage = .remote, .err = error.RemoteNotFound } };
                    const fetch_url = remote_config.get("url") orelse
                        return .{ .failed = .{ .stage = .remote, .err = error.UrlNotFound } };
                    const push_url = remote_config.get("pushurl") orelse fetch_url;
                    const loopback_opts = " -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null";
                    const fetch_ssh_command = try allocator.print("{s}{s} -o BatchMode=yes -o LogLevel=QUIET", .{ ssh, if (isLoopbackSshUrl(fetch_url)) loopback_opts else "" });
                    defer allocator.free(fetch_ssh_command);
                    const push_ssh_command = try allocator.print("{s}{s} -o BatchMode=yes -o LogLevel=QUIET", .{ ssh, if (isLoopbackSshUrl(push_url)) loopback_opts else "" });
                    defer allocator.free(push_ssh_command);
                    const fetch_transport_opts: xit.net.Opts(repo_opts.ProgressCtx) = .{ .progress_ctx = .{ .message = &message }, .wire = .{ .ssh = .{ .command = fetch_ssh_command } } };
                    const push_transport_opts: xit.net.Opts(repo_opts.ProgressCtx) = .{ .progress_ctx = .{ .message = &message }, .wire = .{ .ssh = .{ .command = push_ssh_command } } };

                    const fetch_refspec = try allocator.print("+refs/heads/{s}:refs/remotes/{s}/{s}", .{ evt.events_ref.name, remote_name, evt.events_ref.name });
                    defer allocator.free(fetch_refspec);
                    var fetch_opts = fetch_transport_opts;
                    fetch_opts.refspecs = &.{fetch_refspec};
                    const remote_ref: rf.Ref = .{ .kind = .{ .remote = remote_name }, .name = evt.events_ref.name };
                    // where the remote's events stood as last fetched, which
                    // a merge failure puts back
                    const fetched_before = repo.readRef(io, remote_ref) catch |err|
                        return .{ .failed = .{ .stage = .fetch, .err = err } };
                    message.clearRetainingCapacity();
                    repo.fetch(io, allocator, remote_name, fetch_opts) catch |err|
                        return try transportFailure(allocator, .fetch, err, &message);

                    merge: {
                        // a local git repo's events have no transaction, so the
                        // merge holds the lock every shared event write takes
                        const locked = thread_write.lockEvents(io, source) catch |err|
                            return .{ .failed = .{ .stage = .merge, .err = err } };
                        defer thread_write.unlockEvents(io, locked);
                        const local_oid = repo.readRef(io, evt.events_ref) catch |err|
                            return .{ .failed = .{ .stage = .merge, .err = err } };
                        const remote_oid = repo.readRef(io, remote_ref) catch |err|
                            return .{ .failed = .{ .stage = .merge, .err = err } };
                        if (local_oid == null and remote_oid == null) {
                            evt.consume(.local, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{}) catch |err|
                                return .{ .failed = .{ .stage = .merge, .err = err } };
                            return .synced;
                        }
                        if (remote_oid == null) {
                            evt.consume(.local, .repo, repo_kind, repo_opts, io, allocator, repo, evt.events_ref, &.{}) catch |err|
                                return .{ .failed = .{ .stage = .merge, .err = err } };
                            break :merge;
                        }
                        // merged only if the result can be read: otherwise the
                        // events branch and event db stay as they were, and the
                        // remote's ref goes back to what was last merged, so a
                        // repo with no events of its own doesn't read the
                        // fetched ones instead. nothing is pushed.
                        evt.mergeAndConsumeEvents(repo_kind, repo_opts, io, allocator, repo, remote_ref) catch |err| {
                            evt.restoreFetchedRef(repo_kind, repo_opts, io, repo, remote_ref, if (fetched_before) |*oid| oid else null) catch |restore_err|
                                std.log.warn("sync: couldn't restore the remote's events ref after a failed merge: {s}", .{@errorName(restore_err)});
                            return .{ .failed = .{ .stage = .merge, .err = err } };
                        };
                        break :merge;
                    }

                    const push_refspec = try allocator.print("refs/heads/{s}:refs/heads/{s}", .{ evt.events_ref.name, evt.events_ref.name });
                    defer allocator.free(push_refspec);
                    message.clearRetainingCapacity();
                    repo.push(io, allocator, remote_name, push_refspec, false, push_transport_opts) catch |err|
                        return try transportFailure(allocator, .push, err, &message);
                    message.clearRetainingCapacity();
                    repo.fetch(io, allocator, remote_name, fetch_opts) catch |err|
                        return try transportFailure(allocator, .confirm, err, &message);
                },
            }
        },
    }
    return .synced;
}

// a fetch or push that failed, with what the remote said when it reported why
fn transportFailure(allocator: std.mem.Allocator, stage: SyncStage, err: anyerror, message: *std.Io.Writer.Allocating) !SyncResult {
    const remote_message = if (err == error.ServerReportedError and message.written().len != 0) try allocator.dupe(u8, message.written()) else null;
    return .{ .failed = .{ .stage = stage, .err = err, .remote_message = remote_message } };
}

/// the TUI's sync: null when it synced, the remote's message when it
/// reported one, otherwise the error that stopped it
pub fn sync(io: std.Io, allocator: std.mem.Allocator, source: ui.RepoSource) !?[]u8 {
    const result = try runSync(io, allocator, source, null);
    switch (result) {
        .synced => return null,
        .failed => |failure| return failure.remote_message orelse failure.err,
    }
}
