const std = @import("std");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const df = xit.diff;
const wgt = xit.xitui.widget;
const layout = xit.xitui.layout;
const Key = xit.xitui.input.Key;
const Grid = xit.xitui.grid.Grid;
const Focus = xit.xitui.focus.Focus;
const inp = @import("../input.zig");

pub const page_size = 10;

// the most cells a page's content may take: its line count times its widest line
const max_page_cells = 1_000_000;

/// one entry of a diff window: a hunk of a changed text file, or a whole
/// file shown only by its path (an added or removed file, a binary one, or a
/// change too large to diff)
pub const Hunk = struct {
    // the file's path, on the first of its entries in a window (a hunk that
    // continues the file before it has none)
    path: ?[]const u8 = null,
    status: Status = .changed,
    kind: Kind = .hunk,
    // a hunk's lines, empty for the other kinds
    lines: []const Line = &.{},
};

pub const Kind = enum {
    // lines of a changed text file
    hunk,
    // an added or removed text file, which shows only its path
    file,
    // a file xit reads as binary: not utf-8, or past its text limits
    // (`max_text_size`, `max_line_size`, `max_line_count`)
    binary,
    // a change past xit's diff limits (`max_edit_count`)
    too_large,
};

pub const Line = struct {
    // the edit: ' ' kept, '+' inserted, '-' deleted
    prefix: u8,
    // 1-based line numbers, null on the side the line isn't on
    old: ?usize,
    new: ?usize,
    text: []const u8,
};

pub const Status = enum {
    added,
    removed,
    changed,

    fn label(self: Status) []const u8 {
        return switch (self) {
            .added => " added ",
            .removed => " removed ",
            .changed => " changed ",
        };
    }

    fn border(self: Status) wgt.Border {
        const color: Grid.Color.Ansi = switch (self) {
            .added => .green,
            .removed => .red,
            .changed => return .single,
        };
        return .{ .kind = .single, .style = .{ .fg = .ansi(color) } };
    }
};

pub const Window = struct {
    hunks: []const Hunk = &.{},
    start: usize = 0,
    has_more: bool = false,
    // the diff past these entries is beyond xit's limit on the lines a diff
    // reads (`max_total_line_count`), so the window ends early
    truncated: bool = false,
};

/// which window of a diff to render
pub const Options = struct {
    // the index of the window's first entry, counted across all files
    start: usize = 0,
    // a file's path: only its entries ("" for every file)
    path: []const u8 = "",
    // the most entries a window holds
    limit: usize = page_size,
};

route: Route,
path: []const u8 = "",
window: Window,

const Self = @This();

pub const Route = union(enum) {
    repo: struct { identity: []const u8, ref_or_oid: ui.RoutablePage.RefOrOid, value: []const u8, base_oid: []const u8 },
    // `base_oid` is the revision's base commit, which the url leaves out
    patchrev: struct { identity: []const u8, id: []const u8, base_oid: []const u8 },
    // `oid` names one commit's diff against `base_oid` ("" = the whole patch).
    // `patch_base_oid` is the whole patch's base commit, which the url leaves out
    fork: struct { identity: []const u8, id: []const u8, oid: []const u8 = "", base_oid: []const u8 = "", patch_base_oid: []const u8 = "" },

    pub fn page(self: Route, start: usize, path: []const u8) ?ui.RoutablePage {
        return switch (self) {
            .repo => |r| ui.RoutablePage.repoDiffRoute(r.identity, r.ref_or_oid, r.value, start, path, r.base_oid),
            .patchrev => |r| ui.RoutablePage.repoPatchRevDiffRoute(r.identity, r.id, start, path),
            .fork => |f| ui.RoutablePage.forkDiffRoute(f.identity, f.id, f.oid, f.base_oid, start, path),
        };
    }

    fn link(self: Route, arena: *std.heap.ArenaAllocator, start: usize, path: []const u8) ![]const u8 {
        const route = self.page(start, path) orelse return error.RouteTooLong;
        return arena.allocator().print("a:{s}", .{try route.toUrl(arena)});
    }

    // a link to the file's content in the files view, from the base commit for a removed file
    fn fileLink(self: Route, arena: *std.heap.ArenaAllocator, path: []const u8, status: Status) ![]const u8 {
        const route = (if (status == .removed) switch (self) {
            .repo => |r| ui.RoutablePage.repoFilesRoute(r.identity, .object, r.base_oid, path, 0),
            .patchrev => |r| ui.RoutablePage.repoFilesRoute(r.identity, .object, r.base_oid, path, 0),
            .fork => |f| ui.RoutablePage.forkFilesRoute(f.identity, f.id, if (f.base_oid.len != 0) f.base_oid else f.patch_base_oid, path, 0),
        } else switch (self) {
            .repo => |r| ui.RoutablePage.repoFilesRoute(r.identity, r.ref_or_oid, r.value, path, 0),
            .patchrev => |r| ui.RoutablePage.repoPatchRevFilesRoute(r.identity, r.id, path, 0),
            .fork => |f| ui.RoutablePage.forkFilesRoute(f.identity, f.id, f.oid, path, 0),
        }) orelse return error.RouteTooLong;
        return arena.allocator().print("a:{s}", .{try route.toUrl(arena)});
    }
};

pub fn init(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    route: ui.RoutablePage.RepoDiffRoute,
) !Self {
    const aa = arena.allocator();
    const oid_len = comptime xit.hash.hexLen(repo_opts.hash);
    const identity = try aa.dupe(u8, route.name.slice());
    if (route.patchrev_id.len != 0) {
        // the revision and every file it compares come from one snapshot
        var moment = try repo.core.latestMoment();
        const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
        const path = try aa.dupe(u8, route.path.slice());
        const revision = (try renderRevisionAt(repo_kind, repo_opts, arena, repo, io, gpa, state, route.patchrev_id.slice(), .{ .start = route.start, .path = path })) orelse return error.NotFound;
        return .{
            .route = .{ .patchrev = .{ .identity = identity, .id = try aa.dupe(u8, route.patchrev_id.slice()), .base_oid = try aa.dupe(u8, revision.record.event.base_oid) } },
            .path = path,
            .window = revision.window,
        };
    }
    const base_oid, const head_oid, const diff_route = blk: {
        const resolved = (try ui.ResolvedRefOrOid(repo_kind, repo_opts).init(repo, io, aa, route.ref_or_oid, route.value.slice())) orelse return error.NotFound;
        evt.PatchRev.validateOid(repo_opts.hash, &resolved.oid) catch return error.NotFound;
        evt.PatchRev.validateOid(repo_opts.hash, route.base_oid.slice()) catch return error.NotFound;

        var moment = try repo.core.latestMoment();
        const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
        // peel annotated tags before comparing their trees
        var tip = try xit.object.Object(repo_kind, repo_opts).initCommit(state, io, gpa, &resolved.oid);
        defer tip.deinit();
        break :blk .{
            route.base_oid.slice()[0..oid_len].*,
            tip.oid,
            Route{ .repo = .{
                .identity = identity,
                .ref_or_oid = resolved.ref_or_oid,
                .value = resolved.value,
                .base_oid = try aa.dupe(u8, route.base_oid.slice()),
            } },
        };
    };
    const path = try aa.dupe(u8, route.path.slice());
    return .{
        .route = diff_route,
        .path = path,
        .window = try render(repo_kind, repo_opts, io, gpa, aa, repo, if (std.mem.allEqual(u8, &base_oid, '0')) null else &base_oid, head_oid, .{ .start = route.start, .path = path }),
    };
}

/// a patch revision's diff and the revision itself
pub fn Revision(comptime hash_kind: xit.hash.HashKind) type {
    return struct {
        record: evt.PatchRev.Record,
        // the trees the revision recorded: its base commit's and its source
        // commit's
        base_tree: [xit.hash.hexLen(hash_kind)]u8,
        head_tree: [xit.hash.hexLen(hash_kind)]u8,
        window: Window,
    };
}

/// a window of patch revision `id_hex`'s diff, read in the snapshot `state`
/// (the revision too, in an xit repo): the tree of the commit it was based
/// on against its source commit's, so what its target already had before is
/// left out. the TUI's patch diff and the web API's revision diff both read
/// it here. null when the repo has no such revision.
pub fn renderRevisionAt(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: *std.heap.ArenaAllocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    state: rp.Repo(repo_kind, repo_opts).State(.read_only),
    id_hex: []const u8,
    options: Options,
) !?Revision(repo_opts.hash) {
    const oid_len = comptime xit.hash.hexLen(repo_opts.hash);
    const record = (try ui.Repo.Files.readPatchRevAt(repo_kind, repo_opts, arena, repo, io, gpa, state.extra.moment, id_hex)) orelse return null;
    if (record.base_tree_oid.len != oid_len or record.head_tree_oid.len != oid_len) return null;
    const base_tree = record.base_tree_oid[0..oid_len].*;
    const head_tree = record.head_tree_oid[0..oid_len].*;
    return .{
        .record = record,
        .base_tree = base_tree,
        .head_tree = head_tree,
        .window = try renderAt(repo_kind, repo_opts, io, gpa, arena.allocator(), state, if (std.mem.allEqual(u8, &base_tree, '0')) null else &base_tree, head_tree, options),
    };
}

// render a window of the net diff between two commits or trees
pub fn render(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    base_oid: ?*const [xit.hash.hexLen(repo_opts.hash)]u8,
    head_oid: [xit.hash.hexLen(repo_opts.hash)]u8,
    options: Options,
) !Window {
    var moment = try repo.core.latestMoment();
    const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
    return renderAt(repo_kind, repo_opts, io, gpa, arena, state, base_oid, head_oid, options);
}

/// `render` read in one snapshot of the repo, `state`, so a caller can read
/// the commits it compares in the same one. this decides every diff window
/// haxy shows, in the TUI and the JSON API: which entries a window holds,
/// how many, and which changes are placeholders.
pub fn renderAt(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    state: rp.Repo(repo_kind, repo_opts).State(.read_only),
    base_oid: ?*const [xit.hash.hexLen(repo_opts.hash)]u8,
    head_oid: [xit.hash.hexLen(repo_opts.hash)]u8,
    options: Options,
) !Window {
    const start = options.start;
    const path = options.path;
    const limit = @max(options.limit, 1);
    var tree_diff = xit.tree.TreeDiff(repo_kind, repo_opts).init(gpa);
    defer tree_diff.deinit();
    try tree_diff.compare(state, io, base_oid, &head_oid, null);

    var file_iter = try df.FileIterator(repo_kind, repo_opts).init(state, io, gpa, .{ .tree = .{ .tree_diff = &tree_diff } });

    var hunks: std.ArrayList(Hunk) = .empty;
    var index: usize = 0; // running entry index across all files
    var has_more = false;
    var truncated = false;
    // the page's content grid is its line count times its widest line
    var lines: usize = 0;
    var widest: usize = 0;

    file_loop: while (true) {
        // past xit's limit on the lines a diff reads, the rest can't be read
        const pair_val = file_iter.next() catch |err| switch (err) {
            error.DiffTooLarge => {
                truncated = true;
                break :file_loop;
            },
            else => |e| return e,
        } orelse break;
        var pair = pair_val;
        defer pair.deinit();

        if (path.len != 0 and !std.mem.eql(u8, pair.path, path)) continue;

        const status: Status = if (pair.a.source == .nothing) .added else if (pair.b.source == .nothing) .removed else .changed;
        const binary = pair.a.source == .binary or pair.b.source == .binary;

        // an added, removed or binary file shows only its path
        if (status != .changed or binary) {
            const i = index;
            index += 1;
            if (i < start) continue;
            if (!fits(hunks.items.len, limit, lines, widest, 1, pair.path.len)) {
                has_more = true;
                break :file_loop;
            }
            lines += 1;
            widest = @max(widest, pair.path.len);
            try hunks.append(arena, .{ .path = try arena.dupe(u8, pair.path), .status = status, .kind = if (binary) .binary else .file });
            continue;
        }

        var hunk_iter = try df.HunkIterator(repo_kind, repo_opts).init(gpa, &pair.a, &pair.b);
        defer hunk_iter.deinit(gpa);

        // the path label rides on the first of this file's hunks we actually show.
        var path_attached = false;
        while (true) {
            // past xit's limit on a file's edits, the rest of the file is one
            // placeholder, at the same index in every window
            const hunk_val = hunk_iter.next(gpa) catch |err| switch (err) {
                error.DiffTooLarge => {
                    const i = index;
                    index += 1;
                    if (i < start) break;
                    if (!fits(hunks.items.len, limit, lines, widest, 1, pair.path.len)) {
                        has_more = true;
                        break :file_loop;
                    }
                    lines += 1;
                    widest = @max(widest, pair.path.len);
                    try hunks.append(arena, .{ .path = try arena.dupe(u8, pair.path), .kind = .too_large });
                    break;
                },
                else => |e| return e,
            } orelse break;
            var hunk = hunk_val;
            defer hunk.deinit(gpa);

            const i = index;
            index += 1;
            if (i < start) continue; // before this window
            if (hunks.items.len >= limit) {
                has_more = true;
                break :file_loop;
            }
            const read = try readHunk(repo_kind, repo_opts, arena, &hunk_iter, &hunk);
            // the first hunk always goes in, xit's max_hunk_edits bounds it
            if (!fits(hunks.items.len, limit, lines, widest, read.lines.len, read.widest)) {
                has_more = true;
                break :file_loop;
            }
            lines += read.lines.len;
            widest = @max(widest, read.widest);
            try hunks.append(arena, .{
                .path = if (path_attached) null else try arena.dupe(u8, pair.path),
                .lines = read.lines,
            });
            path_attached = true;
        }
    }

    return .{ .hunks = try hunks.toOwnedSlice(arena), .start = start, .has_more = has_more, .truncated = truncated };
}

// whether an entry of `entry_lines` lines, `entry_widest` wide, fits a window
// holding `count` entries in `lines` lines at most `widest` wide. the first
// entry always does.
fn fits(count: usize, limit: usize, lines: usize, widest: usize, entry_lines: usize, entry_widest: usize) bool {
    if (count == 0) return true;
    return count < limit and (lines + entry_lines) * @max(widest, entry_widest) <= max_page_cells;
}

// a hunk's lines, and its width as the TUI shows it: each line's number,
// right-aligned, then a space and its prefix before its text
fn readHunk(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    arena: std.mem.Allocator,
    hunk_iter: *df.HunkIterator(repo_kind, repo_opts),
    hunk: *df.Hunk(repo_kind, repo_opts),
) !struct { lines: []const Line, widest: usize } {
    const lines = try arena.alloc(Line, hunk.edits.items.len);
    var widest_text: usize = 0;
    for (hunk.edits.items, lines) |edit, *line| {
        line.* = switch (edit) {
            .eql => |e| .{ .prefix = ' ', .old = e.old_line.num + 1, .new = e.new_line.num + 1, .text = try arena.dupe(u8, try hunk_iter.line_iter_b.get(e.new_line.num)) },
            .ins => |e| .{ .prefix = '+', .old = null, .new = e.new_line.num + 1, .text = try arena.dupe(u8, try hunk_iter.line_iter_b.get(e.new_line.num)) },
            .del => |e| .{ .prefix = '-', .old = e.old_line.num + 1, .new = null, .text = try arena.dupe(u8, try hunk_iter.line_iter_a.get(e.old_line.num)) },
        };
        widest_text = @max(widest_text, line.text.len);
    }
    return .{ .lines = lines, .widest = numberWidth(lines) + 2 + widest_text };
}

// the line number the TUI shows for a line: the new side's for kept and
// inserted lines, the old side's for deleted ones
fn shownNumber(line: Line) usize {
    return line.new orelse line.old orelse 0;
}

// the digits of a hunk's widest shown line number
fn numberWidth(lines: []const Line) usize {
    var max_num: usize = 1;
    for (lines) |line| max_num = @max(max_num, shownNumber(line));
    return std.fmt.count("{d}", .{max_num});
}

// a hunk as the TUI shows it: right-aligned line numbers, each line's prefix
// and its text
fn hunkText(arena: std.mem.Allocator, lines: []const Line) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const width = numberWidth(lines);
    for (lines, 0..) |line, i| {
        if (i != 0) try out.writer.writeByte('\n');
        const num = shownNumber(line);
        try out.writer.splatByteAll(' ', width - std.fmt.count("{d}", .{num}));
        try out.writer.print("{d} {c}{s}", .{ num, line.prefix, line.text });
    }
    return out.toOwnedSlice();
}

fn appendWindow(data: @This(), allocator: std.mem.Allocator, session: *ui.Session, box: *wgt.Box(ui.Widget)) !void {
    if (data.path.len != 0) {
        const status = if (data.window.hunks.len > 0) data.window.hunks[0].status else .changed;
        try addSpans(allocator, box, &.{.{ .text = data.path }}, try data.route.fileLink(session.page_arena, data.path, status), status.label(), status.border());
        try addLink(allocator, box, "← all files", try data.route.link(session.page_arena, 0, ""));
    }
    if (data.window.start > 0) try addLink(allocator, box, "← previous", try data.route.link(session.page_arena, data.window.start -| page_size, data.path));
    for (data.window.hunks) |hunk| {
        if (data.path.len == 0 or hunk.kind != .hunk) if (hunk.path) |path| {
            // a changed text file's path narrows the diff to it, the others open the file
            const link = if (data.path.len == 0 and hunk.kind == .hunk) try data.route.link(session.page_arena, 0, path) else try data.route.fileLink(session.page_arena, path, hunk.status);
            try addSpans(allocator, box, &.{.{ .text = path }}, link, entryLabel(hunk), hunk.status.border());
        };
        if (hunk.lines.len != 0) try addHunk(allocator, session.page_arena.allocator(), box, hunk);
    }
    // the rest of the diff couldn't be read, so this isn't the whole of it
    if (data.window.truncated) try addSpans(allocator, box, &.{.{ .text = "the rest of this diff is too large to show" }}, "", " incomplete ", .{ .kind = .single, .style = .{ .fg = .ansi(.yellow) } });
    if (data.window.has_more) try addLink(allocator, box, "next →", try data.route.link(session.page_arena, data.window.start + data.window.hunks.len, data.path));
}

// an entry's label: its status, or why it shows no lines
fn entryLabel(hunk: Hunk) []const u8 {
    return switch (hunk.kind) {
        .too_large => " too large to diff ",
        .binary => if (hunk.status == .changed) " binary " else hunk.status.label(),
        .hunk, .file => hunk.status.label(),
    };
}

fn addLink(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), text: []const u8, link: []const u8) !void {
    try addSpans(allocator, box, &.{.{ .text = text }}, link, "", .single);
}

// one span per line, inserted lines green and deleted lines red. the text
// box copies the text, so the spans only live until init.
fn addHunk(allocator: std.mem.Allocator, page_arena: std.mem.Allocator, box: *wgt.Box(ui.Widget), hunk: Hunk) !void {
    const text = try hunkText(page_arena, hunk.lines);
    var spans: std.ArrayList(wgt.Span) = .empty;
    defer spans.deinit(allocator);
    var start: usize = 0;
    for (hunk.lines) |line| {
        // each span keeps its trailing newline so the text box still breaks there
        const end = if (std.mem.indexOfScalarPos(u8, text, start, '\n')) |nl| nl + 1 else text.len;
        const style: wgt.Style = switch (line.prefix) {
            '+' => .{ .fg = .ansi(.green) },
            '-' => .{ .fg = .ansi(.red) },
            else => .{},
        };
        try spans.append(allocator, .{ .text = text[start..end], .style = style });
        start = end;
    }
    try addSpans(allocator, box, spans.items, "", "", .single);
}

fn addSpans(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), spans: []const wgt.Span, link: []const u8, label: []const u8, border: wgt.Border) !void {
    var tb = try wgt.TextBox.initSpans(allocator, spans, .{ .border = border, .round_corners = true, .wrap_kind = .none, .top_label = .{ .text = label } });
    errdefer tb.deinit(allocator);
    tb.getFocus().mode = .all;
    if (link.len != 0) tb.getFocus().kind = .{ .custom = link };
    try box.children.put(allocator, tb.getFocus().id, .{ .widget = .{ .text_box = tb }, .rect = null, .min_size = null, .flex = .shrink });
}

pub const View = struct {
    scroll: wgt.Scroll(ui.Widget),

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var view: View = blk: {
            var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
            errdefer box.deinit(allocator);
            break :blk .{ .scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .box = box }, .{ .direction = .both, .web_native = !session.is_terminal, .fill = true }) };
        };
        errdefer view.deinit(allocator);
        const box = view.inner();
        try data.appendWindow(allocator, session, box);
        if (box.children.count() == 0) try addLink(allocator, box, "no changes", "");
        box.getFocus().child_id = box.children.keys()[0];
        return view;
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.scroll.deinit(allocator);
    }
    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        try self.scroll.build(allocator, constraint, root_focus);
    }
    pub fn clearGrid(self: *View) void {
        self.scroll.clearGrid();
    }
    pub fn getGrid(self: View) ?Grid {
        return self.scroll.getGrid();
    }
    pub fn getFocus(self: *View) *Focus {
        return self.scroll.getFocus();
    }
    pub fn atTop(self: *View) bool {
        const box = self.inner();
        return self.scroll.y == 0 and (box.children.count() == 0 or box.getFocus().child_id == box.children.keys()[0]);
    }
    fn inner(self: *View) *wgt.Box(ui.Widget) {
        return &self.scroll.child.box;
    }
    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = allocator;
        const sc = &self.scroll;
        const box = self.inner();
        if (inp.rowDelta(key, @intCast(box.children.count()))) |delta| return ui.widget.moveRowFocus(box, sc, root_focus, delta);
        switch (key) {
            // scroll horizontally within the diff
            .arrow_left => if (!ui.widget.moveInSelectedRow(box, root_focus, false) and sc.x > 0) {
                sc.x -= 1;
                sc.clampToContent();
            },
            .arrow_right => if (!ui.widget.moveInSelectedRow(box, root_focus, true)) {
                sc.x += 1;
                sc.clampToContent();
            },
            // Enter / a click on a "previous"/"next" row follow its "a:" link in
            // the host (it reloads the adjacent window), so they don't reach here.
            else => {},
        }
    }
};
