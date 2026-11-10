const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../../event.zig");
const domain = @import("../../domain.zig");
const ui = @import("../../ui.zig");
const inp = @import("../input.zig");
const Comment = @import("./Comment.zig");
const xit = @import("xit");
const rp = xit.repo;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const wasm = builtin.target.cpu.arch == .wasm32;

// the repo's default and protected branches, which only its owners see
identity: []const u8,
// the branch HEAD names ("" when detached)
default_branch: []const u8,
names: []const []const u8,

const Self = @This();

pub const Action = enum { default, protect, unprotect };

pub fn init(arena: *std.heap.ArenaAllocator, identity: []const u8, repo: evt.Repo, default_branch: []const u8) !Self {
    const aa = arena.allocator();
    return .{
        .identity = try aa.dupe(u8, identity),
        .default_branch = try aa.dupe(u8, default_branch),
        .names = try repo.protectedBranchNames(aa),
    };
}

// the domain's branch name limit is the encoded length a branch route holds
comptime {
    std.debug.assert(domain.branch_encoded_max_len == ui.RoutablePage.ref_route_max_len);
}

pub const View = struct {
    scroll: wgt.Scroll(ui.Widget),
    data: *const Self,
    session: *ui.Session,

    const about_index = 0;
    const default_index = 1;
    const add_index = 2;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        const aa = session.page_arena.allocator();
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .vert });
        errdefer box.deinit(allocator);
        const route = ui.RoutablePage.repoBranchesRoute(data.identity) orelse return error.RouteTooLong;
        const url = try route.toUrl(session.page_arena);

        {
            var about = try ui.widget.initAbout(allocator, &.{
                .{ .text = "the default branch is what the repo page shows and clones check out.\n" },
                .{ .text = "protected branches can't be deleted or force pushed.\n" },
                .{ .text = "owners", .style = .{ .bold = true } },
                .{ .text = " can push directly to them.\n" },
                .{ .text = "members", .style = .{ .bold = true } },
                .{ .text = " can only change them by merging a patch." },
            });
            errdefer about.deinit(allocator);
            try box.children.put(allocator, about.getFocus().id, .{ .widget = .{ .box = about }, .rect = null, .min_size = null });
        }
        // a failed submission keeps its text in the input it came from
        const saved = session.formFeedback(.repo_branches);
        try addFormRow(allocator, &box, session, try aa.print("form:{s}/default", .{url}), " default branch ", if (saved) |value| (if (value.default) value.name else data.default_branch) else data.default_branch);
        try addFormRow(allocator, &box, session, try aa.print("form:{s}/protect", .{url}), " add a protected branch ", if (saved) |value| (if (value.default) "" else value.name) else "");

        // the branch rows follow the add row in the same box
        for (data.names) |branch| {
            const encoded = try ui.urlEncodeRef(aa, branch);
            var row_route = route;
            row_route.repo_branches.branch = ui.RoutablePage.Array(ui.RoutablePage.ref_route_max_len).from(encoded) orelse return error.RouteTooLong;
            const row_url = try row_route.toUrl(session.page_arena);

            var row_box = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .horiz });
            errdefer row_box.deinit(allocator);
            row_box.getFocus().kind = .{ .custom = try aa.print("form:{s}", .{row_url}) };
            {
                const files_route = ui.RoutablePage.repoFilesRoute(data.identity, .branch, encoded, "", 0) orelse return error.RouteTooLong;
                var name = try Comment.linkBox(allocator, session, branch, files_route);
                errdefer name.deinit(allocator);
                try row_box.children.put(allocator, name.getFocus().id, .{ .widget = .{ .text_box = name }, .rect = null, .min_size = null });
            }
            {
                var remove = try wgt.TextBox.init(allocator, "✕", .{ .border = .single, .round_corners = true, .wrap_kind = .none });
                errdefer remove.deinit(allocator);
                remove.getFocus().mode = .all;
                remove.getFocus().kind = .{ .custom = try aa.print("submit:{s}/unprotect", .{row_url}) };
                try row_box.children.put(allocator, remove.getFocus().id, .{ .widget = .{ .text_box = remove }, .rect = null, .min_size = .{ .width = 3, .height = null } });
            }
            row_box.getFocus().child_id = row_box.children.keys()[0];
            try box.children.put(allocator, row_box.getFocus().id, .{ .widget = .{ .box = row_box }, .rect = null, .min_size = null });
        }

        box.getFocus().child_id = box.children.keys()[about_index];
        var center = try ui.widget.Center.init(allocator, .{ .box = box });
        errdefer center.deinit(allocator);
        return .{
            .scroll = try wgt.Scroll(ui.Widget).init(allocator, .{ .center = center }, .{ .direction = .vert, .web_native = !session.is_terminal, .fill = true }),
            .data = data,
            .session = session,
        };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.scroll.deinit(allocator);
    }

    fn contentBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.scroll.child.center.child.box;
    }

    // a row holding one text input in its own form
    fn addFormRow(allocator: std.mem.Allocator, box: *wgt.Box(ui.Widget), session: *ui.Session, form: []const u8, label: []const u8, content: []const u8) !void {
        var row = try wgt.Box(ui.Widget).init(allocator, .{ .border = null, .direction = .horiz });
        errdefer row.deinit(allocator);
        row.getFocus().kind = .{ .custom = form };
        var name = try wgt.TextInput.init(allocator, .{ .top_label = .{ .text = label }, .name = "name", .visible_width = 30, .round_corners = true, .render_content = session.is_terminal });
        errdefer name.deinit(allocator);
        name.getFocus().mode = .all;
        try name.setContent(allocator, content);
        row.getFocus().child_id = name.getFocus().id;
        try row.children.put(allocator, name.getFocus().id, .{ .widget = .{ .text_input = name }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        try box.children.put(allocator, row.getFocus().id, .{ .widget = .{ .box = row }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
    }

    fn formInput(self: *View, index: usize) *wgt.TextInput {
        return &self.contentBox().children.values()[index].widget.box.children.values()[0].widget.text_input;
    }

    // the form row with focus, if any
    fn activeForm(self: *View) ?usize {
        const rows = self.contentBox();
        const index = rows.children.getIndex(rows.getFocus().child_id orelse return null) orelse return null;
        return if (index == default_index or index == add_index) index else null;
    }

    fn aboutBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.contentBox().children.values()[about_index].widget.box;
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        try self.labelInputs(root_focus);
        ui.widget.markAboutFocused(self.aboutBox(), root_focus);
        // the window's height as a minimum centers rows that fit
        try self.scroll.build(allocator, .{
            .min_size = .{ .width = constraint.min_size.width, .height = constraint.max_size.height orelse constraint.min_size.height },
            .max_size = constraint.max_size,
        }, root_focus);
    }

    // label the inputs for this frame and register them for the web form
    // handling. a failure labels the input it came from.
    fn labelInputs(self: *View, root_focus: *Focus) !void {
        const saved = self.session.formFeedback(.repo_branches);
        for ([_]usize{ default_index, add_index }) |index| {
            const name = self.formInput(index);
            const default = index == default_index;
            const failure = if (saved) |value| (if (value.default == default) value.failure else null) else null;
            name.options.top_label.text = if (failure) |value| switch (value) {
                .not_found => if (default) " default branch (not found) " else " add a protected branch (not found) ",
                .already_added => " add a protected branch (already added) ",
                .too_many => " add a protected branch (too many branches) ",
                .too_long => if (default) " default branch (name too long) " else " add a protected branch (name too long) ",
            } else if (default) " default branch " else " add a protected branch ";
            name.options.bottom_label.text = if (root_focus.grandchild_id == name.getFocus().id) " press enter " else "";
            try self.session.text_inputs.put(self.session.arena.allocator(), name.getFocus().id, name);
        }
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        // a form row keeps every key but the vertical ones, which move between rows
        if (self.activeForm()) |index| if (inp.vertDirection(key) == .none) {
            if (key == .enter) {
                const name = try self.formInput(index).text(allocator);
                defer allocator.free(name);
                try self.act(allocator, if (index == default_index) .default else .protect, name);
            } else try self.formInput(index).input(allocator, key, root_focus);
            return;
        };

        const rows = self.contentBox();
        const current = rows.children.getIndex(rows.getFocus().child_id orelse return) orelse return;
        if (inp.rowDelta(key, @intCast(rows.children.count()))) |delta| {
            ui.widget.moveRowFocus(rows, &self.scroll, root_focus, delta);
            return;
        }
        switch (key) {
            .arrow_left, .arrow_right => _ = ui.widget.moveInSelectedRow(rows, root_focus, key == .arrow_right),
            else => {
                // the text and the form rows sit above the rows, and a row's name is a link the host follows
                if (current <= add_index) return;
                const row_box = &rows.children.values()[current].widget.box;
                const button_id = row_box.getFocus().child_id orelse return;
                if (row_box.children.getIndex(button_id) != 1 or !inp.activated(root_focus, button_id, key)) return;
                try self.act(allocator, .unprotect, self.data.names[current - add_index - 1]);
            },
        }
    }

    // the terminal performs the action itself; the web posts the form instead
    fn act(self: *View, _: std.mem.Allocator, action: Action, branch: []const u8) !void {
        if (comptime wasm) return;
        if (self.session.io == null or self.session.users_dir == null) return;
        // a session that may no longer manage branches does nothing
        if (try self.session.authorize(self.data.identity, .owner, null) == null) return;
        var ctx = try self.session.ctx(self.session.page_arena);
        const result = switch (action) {
            .default => (domain.SetDefaultBranch{ .repo = self.data.identity, .branch = branch }).run(&ctx),
            .protect => (domain.ProtectBranch{ .repo = self.data.identity, .branch = branch }).run(&ctx),
            .unprotect => (domain.UnprotectBranch{ .repo = self.data.identity, .branch = branch }).run(&ctx),
        };
        result catch |err| {
            // access lost since the check above leaves the form, like failing it
            if (ui.lostAccess(err)) return;
            const failure = ui.Session.FormFeedback.BranchesFailure.fromError(err) orelse return err;
            self.session.data.form_feedback = .{ .repo_branches = .{ .failure = failure, .name = try self.session.arena.allocator().dupe(u8, branch), .default = action == .default } };
            return;
        };
        try self.session.navigate(ui.RoutablePage.repoBranchesRoute(self.data.identity) orelse return error.RouteTooLong);
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

    // up leaves the view from the explanatory text
    pub fn atTop(self: *View) bool {
        return self.contentBox().getFocus().child_id == self.aboutBox().getFocus().id;
    }
};
