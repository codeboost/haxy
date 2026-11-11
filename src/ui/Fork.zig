const std = @import("std");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const xit = @import("xit");
const rp = xit.repo;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const inp = @import("./input.zig");
const domain = @import("../domain.zig");

pub const Header = @import("./Fork/Header.zig");
pub const Files = @import("./Repo/Files.zig");
pub const Commits = @import("./Repo/Commits.zig");
pub const Diff = @import("./Repo/Diff.zig");
pub const Patches = @import("./Repo/Patches.zig");
pub const Quit = @import("./Quit.zig");

header: Header,
files: Files,
commits: Commits,
patch: Patches,
diff: Diff,
// the delete tab's form, for the forker only
delete: ?ui.Delete,
user_notifications: ui.UserNotifications,
quit: Quit,

const Self = @This();

pub fn init(arena: *std.heap.ArenaAllocator, session: *ui.Session, route: ui.RoutablePage) !Self {
    const io = session.io orelse return error.NotFound;
    const users_dir = session.users_dir orelse return error.NotFound;
    const haxy_moment = session.haxy_moment orelse return error.NoMoment;
    const route_fork = route.forkRoute() orelse return error.UnexpectedRoute;
    // the route's identity names the forker and the repo name the fork was made under
    const identity = ui.RoutablePage.RepoIdentity.parse(route_fork.name.slice()) orelse return error.NotFound;
    const id = evt.parseEventId(route_fork.id.slice()) catch return error.NotFound;
    const gpa = arena.child_allocator;
    // the reads that take a fork resolve it the same way
    const resolved = (try domain.resolveForkWith(io, gpa, arena, haxy_moment, users_dir, session.userId(), identity.owner, identity.name, id)) orelse return error.NotFound;
    const forker = resolved.forker;
    if (route == .fork_delete and !forker) return error.NotFound;
    const fork_record = resolved.record;
    const target_id = resolved.target_id;
    const owner_id = resolved.owner_id;
    // null once the target or its owner is deleted
    const target = resolved.target;
    const target_role = resolved.role;
    const owner = resolved.owner;

    const aa = arena.allocator();
    const target_identity = try aa.print("{s}:{s}", .{ owner.event.name, if (target) |found| found.repo.event.name else identity.name });
    const id_hex = std.fmt.bytesToHex(id, .lower);
    // the fork's viewer is the target repo's
    const handle = ui.RepoHandle{
        .location = .{ .fork = .{ .identity = identity.identity, .id = &id_hex } },
        .viewer = try ui.Viewer.init(session, arena, target_role),
    };
    // a fork shares its target's hash kind
    var any_fork = try rp.AnyRepo(.xit, .{}).open(io, arena.child_allocator, .{ .path = resolved.path, .require_repo_root = true });
    defer any_fork.deinit(io, arena.child_allocator);
    switch (any_fork) {
        inline else => |*fork_repo| {
            const repo_opts = fork_repo.self_repo_opts;
            const tip = (try domain.readForkTip(repo_opts, io, arena, fork_repo, &id)) orelse return error.NotFound;
            const retained_patch = tip.patch;
            const fork_oid = tip.head;

            const target_path = try evt.repoPath(aa, users_dir, &owner_id, &target_id);
            const target_source = ui.RepoSource{ .path = target_path, .repo_kind = .xit };
            var target_repo_maybe: ?rp.Repo(.xit, repo_opts) = if (target != null)
                rp.Repo(.xit, repo_opts).open(io, arena.child_allocator, target_source.localInitOpts()) catch null
            else
                null;
            defer if (target_repo_maybe) |*target_repo| target_repo.deinit(io, arena.child_allocator);

            const target_branch = retained_patch.event.target_branch;

            const retained_entry = Patches.PatchWithId{
                .id = try aa.dupe(u8, &id_hex),
                .record = retained_patch,
                .author = try ui.Author.initFromEmail(haxy_moment, arena, retained_patch.author_email),
                .draft = fork_record.event.stage == .draft,
                .revision_oid = try aa.dupe(u8, &fork_oid),
                .fork_exists = true,
                .fork_identity = try aa.dupe(u8, identity.identity),
                .target_deleted = target == null,
            };
            var patch_data = try Patches.detailResult(aa, target_identity, retained_entry);

            if (target_repo_maybe) |*target_repo| switch (fork_record.event.stage) {
                .draft => if (try Patches.loadDraftEntry(.xit, repo_opts, arena, io, haxy_moment, fork_repo, target_repo, id, identity.identity)) |entry| {
                    patch_data = try Patches.detailResult(aa, target_identity, entry);
                    patch_data.repo_source = target_source;
                },
                .publish => {
                    patch_data = Patches.init(.xit, repo_opts, arena, target_repo, io, haxy_moment, session.users_dir, Patches.DraftsOwner.of(session.userId(), session.data.user_name), target_id, target_identity, target_branch, "", &id_hex, "", 0, "", .open, handle.viewer) catch |err| switch (err) {
                        error.NotFound => patch_data,
                        else => |other| return other,
                    };
                    if (patch_data.selectedThread() != null) patch_data.repo_source = target_source;
                },
            };
            patch_data.repo_id = target_id;

            const requested_ref: ?ui.RoutablePage.RefOrOid = switch (route) {
                .fork_files => |f| if (f.oid.len == 0) null else .object,
                .fork_commits => |c| if (c.oid.len == 0) null else .object,
                else => null,
            };
            const requested_value: []const u8 = switch (route) {
                .fork_files => |*f| f.oid.slice(),
                .fork_commits => |*c| c.oid.slice(),
                else => "",
            };
            const files_path: []const u8 = switch (route) {
                .fork_files => |*f| f.path.slice(),
                else => "",
            };
            const files_line: usize = switch (route) {
                .fork_files => |f| f.line,
                else => 0,
            };
            const files_find: []const u8 = switch (route) {
                .fork_files => |*f| f.find.slice(),
                else => "",
            };
            // the loaders read the oid and the find decoded, as the route holds
            // them url-encoded; the header shows the route's form
            const requested = if (requested_ref == null) requested_value else std.Uri.percentDecodeInPlace(try aa.dupe(u8, requested_value));
            const find = if (files_find.len == 0) "" else std.Uri.percentDecodeInPlace(try aa.dupe(u8, files_find));
            const commits_message = route == .fork_commits and route.fork_commits.message;
            const files = try Files.load(.xit, repo_opts, arena, fork_repo, io, arena.child_allocator, handle, requested_ref, requested, files_path, files_line, find);
            const commits = try loadCommits(repo_opts, arena, fork_repo, io, arena.child_allocator, haxy_moment, handle, tip, requested_ref, requested, commits_message, "");
            const diff_start: usize = switch (route) {
                .fork_diff => |d| d.start,
                else => 0,
            };
            const diff_path: []const u8, const diff_oid: []const u8, const diff_base_oid: []const u8 = switch (route) {
                .fork_diff => |*d| .{ d.path.slice(), d.oid.slice(), d.base_oid.slice() },
                else => .{ "", "", "" },
            };
            const diff = try loadDiff(repo_opts, arena, fork_repo, io, arena.child_allocator, identity.identity, &id_hex, tip, diff_oid, diff_base_oid, diff_start, diff_path);

            return .{
                .header = try Header.init(arena, try aa.dupe(u8, identity.name), identity.owner, &id_hex, requested_value),
                .files = files,
                .commits = commits,
                .patch = patch_data,
                .diff = diff,
                .delete = if (forker) .{ .target = .{ .fork = .{ .identity = try aa.dupe(u8, identity.identity), .id = id_hex } } } else null,
                .user_notifications = try ui.UserNotifications.init(arena, session, route.userTab()),
                .quit = Quit.init(),
            };
        },
    }
}

// the fork's log from the requested commit, or its head, back to the base of
// its newest revision, counted as that revision counts it. the fork page and
// the reads that take a fork share this.
pub fn loadCommits(
    comptime repo_opts: rp.RepoOpts(.xit),
    arena: *std.heap.ArenaAllocator,
    fork_repo: *rp.Repo(.xit, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    admin_moment: ?evt.AdminDB.HashMap(.read_only),
    handle: ui.RepoHandle,
    tip: domain.ForkTip(repo_opts.hash),
    requested_ref: ?ui.RoutablePage.RefOrOid,
    // decoded
    requested_value: []const u8,
    message: bool,
    // the oid of the window's first commit; "" for the first window
    from: []const u8,
) !Commits {
    var commits = try Commits.load(.xit, repo_opts, arena, fork_repo, io, gpa, admin_moment, handle, requested_ref, requested_value, message, &tip.base, "", from);
    commits.commit_count = tip.commit_count;
    return commits;
}

// a window of the fork's diff: the commit `oid` names against `base_oid` (all
// zeros for none), or the whole patch's when `oid` is "". `Diff.init` takes
// only a repo's route, so the fork page and the reads that take a fork share
// this instead. an oid that isn't a full hex oid is NotFound.
pub fn loadDiff(
    comptime repo_opts: rp.RepoOpts(.xit),
    arena: *std.heap.ArenaAllocator,
    fork_repo: *rp.Repo(.xit, repo_opts),
    io: std.Io,
    gpa: std.mem.Allocator,
    // the fork's "forker:name" and hex id, for the diff's links
    identity: []const u8,
    id_hex: []const u8,
    tip: domain.ForkTip(repo_opts.hash),
    oid: []const u8,
    base_oid: []const u8,
    start: usize,
    path: []const u8,
) !Diff {
    const aa = arena.allocator();
    const diff_path = try aa.dupe(u8, path);
    const diff_oid = try aa.dupe(u8, oid);
    const diff_base_oid = try aa.dupe(u8, base_oid);
    const Oid = @TypeOf(tip.head);
    const diff_base: ?Oid, const diff_head: Oid = if (diff_oid.len == 0) .{ tip.base, tip.head } else named: {
        evt.PatchRev.validateOid(repo_opts.hash, diff_oid) catch return error.NotFound;
        evt.PatchRev.validateOid(repo_opts.hash, diff_base_oid) catch return error.NotFound;
        break :named .{ if (std.mem.allEqual(u8, diff_base_oid, '0')) null else diff_base_oid[0..tip.head.len].*, diff_oid[0..tip.head.len].* };
    };
    return .{
        .route = .{ .fork = .{ .identity = try aa.dupe(u8, identity), .id = try aa.dupe(u8, id_hex), .oid = diff_oid, .base_oid = diff_base_oid, .patch_base_oid = try aa.dupe(u8, &tip.base) } },
        .path = diff_path,
        .window = try Diff.render(.xit, repo_opts, io, gpa, aa, fork_repo, if (diff_base) |*base| base else null, diff_head, start, diff_path),
    };
}

pub const View = struct {
    box: wgt.Box(ui.Widget),

    const header_index: usize = 0;
    const stack_index: usize = 1;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer box.deinit(allocator);
        {
            var header = try Header.View.init(allocator, &data.header, data.commits.commit_count, data.delete != null, session);
            errdefer header.deinit(allocator);
            try box.children.put(allocator, header.getFocus().id, .{ .widget = .{ .fork_header = header }, .rect = null, .min_size = null });
        }
        {
            var stack = try wgt.Stack(ui.Widget).init(allocator);
            errdefer stack.deinit(allocator);
            const selected = data.patch.selectedThread() orelse return error.NotFound;
            var patch_detail = try Patches.Detail.init(allocator, &data.patch, session, selected.*, .{ .actions = data.patch.repo_source != null });
            errdefer patch_detail.deinit(allocator);
            try stack.children.put(allocator, patch_detail.getFocus().id, .{ .repo_patch_detail = patch_detail });
            {
                var diff = try Diff.View.init(allocator, &data.diff, session);
                errdefer diff.deinit(allocator);
                try stack.children.put(allocator, diff.getFocus().id, .{ .diff_view = diff });
            }
            {
                var files = try Files.View.init(allocator, &data.files, session);
                errdefer files.deinit(allocator);
                try stack.children.put(allocator, files.getFocus().id, .{ .repo_files = files });
            }
            {
                var commits = try Commits.View.init(allocator, &data.commits, session);
                errdefer commits.deinit(allocator);
                try stack.children.put(allocator, commits.getFocus().id, .{ .repo_commits = commits });
            }
            const identity = try session.page_arena.allocator().print("{s}:{s}", .{ data.header.forker_name, data.header.name });
            // right after commits, as in the header
            if (data.delete) |delete| {
                var view = try ui.Delete.View.init(allocator, delete, session, ui.RoutablePage.forkDeleteRoute(identity, data.header.id) orelse return error.RouteTooLong);
                errdefer view.deinit(allocator);
                try stack.children.put(allocator, view.getFocus().id, .{ .delete_form = view });
            }
            if (session.data.user_id != null) {
                const route = ui.RoutablePage.forkRepoNewRoute(identity, data.header.id) orelse return error.RouteTooLong;
                var new_repo = try ui.NewRepo.View.init(allocator, session, route);
                errdefer new_repo.deinit(allocator);
                try stack.children.put(allocator, new_repo.getFocus().id, .{ .new_repo = new_repo });
            } else if (session.data.host_kind == .server) {
                const route = ui.RoutablePage.forkUserNewRoute(identity, data.header.id) orelse return error.RouteTooLong;
                var new_user = try ui.NewUser.View.init(allocator, session, route);
                errdefer new_user.deinit(allocator);
                try stack.children.put(allocator, new_user.getFocus().id, .{ .new_user = new_user });
            }
            if (session.data.host_kind == .server) {
                const route = ui.RoutablePage.forkUserRoute(identity, data.header.id) orelse return error.RouteTooLong;
                var user_view = try ui.UserSettings.initView(allocator, session, &data.user_notifications, route);
                errdefer user_view.deinit(allocator);
                try stack.children.put(allocator, user_view.getFocus().id, user_view);
            }
            if (session.is_terminal) {
                var quit = try Quit.View.init(allocator, session);
                errdefer quit.deinit(allocator);
                try stack.children.put(allocator, quit.getFocus().id, .{ .quit = quit });
            }
            try box.children.put(allocator, stack.getFocus().id, .{ .widget = .{ .stack = stack }, .rect = null, .min_size = null });
        }
        // a page opens on its tabs, except that search results open in the
        // files tab's search box.
        box.getFocus().child_id = box.children.keys()[if (data.files.find != null) stack_index else header_index];
        return .{ .box = box };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.box.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const header = &self.box.children.values()[header_index].widget.fork_header;
        const stack = &self.box.children.values()[stack_index].widget.stack;
        if (header.getSelectedIndex()) |index| stack.getFocus().child_id = stack.children.keys()[index];
        try self.box.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        const stack = &self.box.children.values()[stack_index].widget.stack;
        const current_id = self.box.getFocus().child_id orelse return;
        const current_index = self.box.children.getIndex(current_id) orelse return;
        const child = &self.box.children.values()[current_index].widget;
        var next_index = current_index;
        switch (inp.vertDirection(key)) {
            .up => switch (child.*) {
                .fork_header => try child.input(allocator, key, root_focus),
                .stack => if (stack.getSelected()) |selected| {
                    if (selected.atTop(root_focus)) next_index = header_index else try child.input(allocator, key, root_focus);
                },
                else => {},
            },
            .down => switch (child.*) {
                .fork_header => {
                    if (stack.getSelected()) |selected| switch (selected.*) {
                        .repo_patch_detail => |*view| if (view.focusFirst(root_focus)) return,
                        .repo_files => |*view| if (view.focusHeader(root_focus)) return,
                        .repo_commits => |*view| if (view.focusHeader(root_focus)) return,
                        .user_notifications => |*view| if (view.focusHeader(root_focus)) return,
                        else => {},
                    };
                    next_index = stack_index;
                },
                .stack => try child.input(allocator, key, root_focus),
                else => {},
            },
            .none => try child.input(allocator, key, root_focus),
        }
        if (next_index != current_index) root_focus.setFocus(self.box.children.keys()[next_index]);
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
