const std = @import("std");
const evt = @import("../event.zig");
const ui = @import("../ui.zig");
const fork = @import("../fork.zig");
const xit = @import("xit");
const rp = xit.repo;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;
const inp = @import("./input.zig");

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

/// the fork a route names, as a viewer may see it
pub const Resolved = struct {
    forker_id: [evt.event_id_size]u8,
    id: [evt.event_id_size]u8,
    record: evt.Fork.Record,
    // the viewer is its forker
    forker: bool,
    // null once its target, or the target's owner, is gone
    target: ?evt.Repo.RepoWithRole,
    // what the viewer may do, which the fork shares with its target
    target_role: evt.Repo.Role,
    target_id: [evt.event_id_size]u8,
    owner_id: [evt.event_id_size]u8,
    // "owner:name" of its target, by the target's current name
    target_identity: []const u8,
};

/// the role a viewer has in a fork whose target is `target` (null once it is
/// gone), or null when the fork is hidden from them
pub fn roleIn(target: ?evt.Repo.RepoWithRole, forker: bool) ?evt.Repo.Role {
    // a deleted target, or one whose owner was deleted, leaves the fork to its forker
    const found = target orelse return if (forker) .read else null;
    // patches that are off take their drafts with them
    if (found.repo.event.patch_role == null) return null;
    // a draft is as readable as the repo it targets
    return found.role;
}

/// the fork `forker_name` made of a repo named `repo_name`, with id
/// `id_text`, or null when it is missing, removed or hidden from `viewer`
pub fn resolve(
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    users_dir: []const u8,
    haxy_moment: evt.AdminDB.HashMap(.read_only),
    viewer: ?[evt.event_id_size]u8,
    forker_name: []const u8,
    repo_name: []const u8,
    id_text: []const u8,
) !?Resolved {
    const gpa = arena.child_allocator;
    const id = evt.parseEventId(id_text) catch return null;
    const forker_id = (try evt.User.readIdByName(evt.AdminDB, evt.admin_repo_opts.hash, haxy_moment, forker_name)) orelse return null;
    const record = (try evt.readForkById(io, gpa, arena, users_dir, &forker_id, &id)) orelse return null;
    if (record.removed) return null;
    const forker = if (viewer) |user_id| std.mem.eql(u8, &user_id, &forker_id) else false;
    const target_id = try evt.parseEventId(&record.event.repo_id);
    const owner_id = try evt.parseEventId(&record.event.repo_user_id);
    const target = try evt.readRepoById(io, gpa, arena, users_dir, &owner_id, &target_id, viewer);
    const target_role = roleIn(target, forker) orelse return null;
    // the url keeps the name the fork was made under, even after a rename
    if (!std.mem.eql(u8, record.event.repo_name, repo_name)) return null;
    const owner = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, haxy_moment, arena, &owner_id)) orelse return null;
    return .{
        .forker_id = forker_id,
        .id = id,
        .record = record,
        .forker = forker,
        .target = target,
        .target_role = target_role,
        .target_id = target_id,
        .owner_id = owner_id,
        .target_identity = try arena.allocator().print("{s}:{s}", .{ owner.event.name, if (target) |found| found.repo.event.name else repo_name }),
    };
}

/// what a fork holds: its patch branch's tip, the base its commits and diff
/// start from, and its patch as the fork page shows it
pub fn Contents(comptime hex_len: usize) type {
    return struct {
        head: [hex_len]u8,
        // the newest revision's base, else the tip itself
        base: [hex_len]u8,
        commit_count: ?u64,
        // its patch: the target's draft or patch while readable there (with
        // `repo_source` set), else what the fork itself retains
        patch: Patches,
    };
}

/// reads `fork_repo`, the fork `resolved` names, as `viewer` (the fork's
/// viewer, which is the target's) sees it
pub fn readContents(
    comptime repo_opts: rp.RepoOpts(.xit),
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    session: *ui.Session,
    resolved: Resolved,
    identity: []const u8,
    fork_repo: *rp.Repo(.xit, repo_opts),
    viewer: ?ui.Viewer,
) !Contents(xit.hash.hexLen(repo_opts.hash)) {
    const haxy_moment = session.haxy_moment orelse return error.NoMoment;
    const users_dir = session.users_dir orelse return error.NotFound;
    const aa = arena.allocator();
    const id = resolved.id;
    const id_hex = std.fmt.bytesToHex(id, .lower);
    const fork_moment = try evt.currentMoment(repo_opts, fork_repo);
    const retained_patch = (try evt.Patch.readById(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_moment, arena, &id)) orelse return error.NotFound;
    const fork_oid = (try fork_repo.readRef(io, fork.ref)) orelse return error.NotFound;
    const newest_revision = try evt.PatchRev.readNewest(evt.EventDB(repo_opts.hash), repo_opts.hash, fork_moment, arena);
    var commits_base_oid = fork_oid;
    if (newest_revision) |revision| {
        if (revision.record.event.base_oid.len != commits_base_oid.len) return error.NotFound;
        @memcpy(&commits_base_oid, revision.record.event.base_oid);
    }

    const target_path = try evt.repoPath(aa, users_dir, &resolved.owner_id, &resolved.target_id);
    const target_source = ui.RepoSource{ .path = target_path, .repo_kind = .xit };
    var target_repo_maybe: ?rp.Repo(.xit, repo_opts) = if (resolved.target != null)
        rp.Repo(.xit, repo_opts).open(io, arena.child_allocator, target_source.localInitOpts()) catch null
    else
        null;
    defer if (target_repo_maybe) |*target_repo| target_repo.deinit(io, arena.child_allocator);

    const retained_entry = Patches.PatchWithId{
        .id = try aa.dupe(u8, &id_hex),
        .record = retained_patch,
        .author = try ui.Author.initFromEmail(haxy_moment, arena, retained_patch.author_email),
        .draft = resolved.record.event.stage == .draft,
        .revision_oid = try aa.dupe(u8, &fork_oid),
        .fork_exists = true,
        .fork_identity = try aa.dupe(u8, identity),
        .target_deleted = resolved.target == null,
    };
    var patch_data = try Patches.detailResult(aa, resolved.target_identity, retained_entry);

    if (target_repo_maybe) |*target_repo| switch (resolved.record.event.stage) {
        .draft => if (try Patches.loadDraftEntry(.xit, repo_opts, arena, io, haxy_moment, fork_repo, target_repo, id, identity)) |entry| {
            patch_data = try Patches.detailResult(aa, resolved.target_identity, entry);
            patch_data.repo_source = target_source;
        },
        .publish => {
            patch_data = Patches.init(.xit, repo_opts, arena, target_repo, io, haxy_moment, session, resolved.target_id, resolved.target_identity, retained_patch.event.target_branch, "", &id_hex, "", 0, "", .open, viewer, .{}) catch |err| switch (err) {
                error.NotFound => patch_data,
                else => |other| return other,
            };
            if (patch_data.selectedThread() != null) patch_data.repo_source = target_source;
        },
    };
    patch_data.repo_id = resolved.target_id;
    return .{
        .head = fork_oid,
        .base = commits_base_oid,
        .commit_count = if (newest_revision) |revision| revision.record.commit_count else 0,
        .patch = patch_data,
    };
}

pub fn init(arena: *std.heap.ArenaAllocator, session: *ui.Session, route: ui.RoutablePage) !Self {
    const io = session.io orelse return error.NotFound;
    const users_dir = session.users_dir orelse return error.NotFound;
    const haxy_moment = session.haxy_moment orelse return error.NoMoment;
    const route_fork = route.forkRoute() orelse return error.UnexpectedRoute;
    // the route's identity names the forker and the repo name the fork was made under
    const identity = ui.RoutablePage.RepoIdentity.parse(route_fork.name.slice()) orelse return error.NotFound;
    const resolved = (try resolve(arena, io, users_dir, haxy_moment, session.userId(), identity.owner, identity.name, route_fork.id.slice())) orelse return error.NotFound;
    const forker = resolved.forker;
    if (route == .fork_delete and !forker) return error.NotFound;

    const aa = arena.allocator();
    const id_hex = std.fmt.bytesToHex(resolved.id, .lower);
    // the fork's viewer is the target repo's
    const handle = ui.RepoHandle{
        .location = .{ .fork = .{ .identity = identity.identity, .id = &id_hex } },
        .viewer = try ui.Viewer.init(session, arena, resolved.target_role),
    };
    const fork_path = try fork.forkPath(aa, users_dir, &resolved.forker_id, &resolved.id);
    // a fork shares its target's hash kind
    var any_fork = try rp.AnyRepo(.xit, .{}).open(io, arena.child_allocator, .{ .path = fork_path, .require_repo_root = true });
    defer any_fork.deinit(io, arena.child_allocator);
    switch (any_fork) {
        inline else => |*fork_repo| {
            const repo_opts = fork_repo.self_repo_opts;
            const contents = try readContents(repo_opts, arena, io, session, resolved, identity.identity, fork_repo, handle.viewer);
            const fork_oid = contents.head;
            const commits_base_oid = contents.base;
            const patch_data = contents.patch;

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
            const commits_message = route == .fork_commits and route.fork_commits.message;
            const files = try Files.init(.xit, repo_opts, arena, fork_repo, io, arena.child_allocator, handle, requested_ref, requested_value, files_path, files_line, files_find);
            var commits = try Commits.init(.xit, repo_opts, arena, fork_repo, io, arena.child_allocator, haxy_moment, handle, requested_ref, requested_value, commits_message, &commits_base_oid, "", "");
            commits.commit_count = contents.commit_count;
            const diff_start: usize = switch (route) {
                .fork_diff => |d| d.start,
                else => 0,
            };
            const diff_path = switch (route) {
                .fork_diff => |*d| try aa.dupe(u8, d.path.slice()),
                else => "",
            };
            // a named commit's diff is against the route's base (all zeros for
            // none), else the diff is the whole patch's
            const diff_oid: []const u8, const diff_base_oid: []const u8 = switch (route) {
                .fork_diff => |*d| .{ try aa.dupe(u8, d.oid.slice()), try aa.dupe(u8, d.base_oid.slice()) },
                else => .{ "", "" },
            };
            const diff_base: ?@TypeOf(fork_oid), const diff_head: @TypeOf(fork_oid) = if (diff_oid.len == 0) .{ commits_base_oid, fork_oid } else named: {
                evt.PatchRev.validateOid(repo_opts.hash, diff_oid) catch return error.NotFound;
                evt.PatchRev.validateOid(repo_opts.hash, diff_base_oid) catch return error.NotFound;
                break :named .{ if (std.mem.allEqual(u8, diff_base_oid, '0')) null else diff_base_oid[0..fork_oid.len].*, diff_oid[0..fork_oid.len].* };
            };

            return .{
                .header = try Header.init(arena, try aa.dupe(u8, identity.name), identity.owner, &id_hex, requested_value),
                .files = files,
                .commits = commits,
                .patch = patch_data,
                .diff = .{
                    .route = .{ .fork = .{ .identity = try aa.dupe(u8, identity.identity), .id = try aa.dupe(u8, &id_hex), .oid = diff_oid, .base_oid = diff_base_oid, .patch_base_oid = try aa.dupe(u8, &commits_base_oid) } },
                    .path = diff_path,
                    .window = try Diff.render(.xit, repo_opts, io, arena.child_allocator, aa, fork_repo, if (diff_base) |*base| base else null, diff_head, .{ .start = diff_start, .path = diff_path }),
                },
                .delete = if (forker) .{ .target = .{ .fork = .{ .identity = try aa.dupe(u8, identity.identity), .id = id_hex } } } else null,
                .user_notifications = try ui.UserNotifications.init(arena, session, route.userTab()),
                .quit = Quit.init(),
            };
        },
    }
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
