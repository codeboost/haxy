//! conflicted issues and patches, made by two local repos that edit the same
//! thread and sync events through a file remote, and resolving them through
//! the resolve form. no server form can make a conflict.

const std = @import("std");
const xit = @import("xit");
const h = @import("harness.zig");

const io = std.testing.io;
const gpa = std.testing.allocator;
const RepoKind = xit.repo.RepoKind;

const base_description = "one\ntwo\nthree\n";

// two local repos: `here` has `there` as its remote and does the syncing
fn Sides(comptime kind: RepoKind) type {
    return struct {
        there_repo: h.Local(kind),
        here_repo: h.Local(kind),
        here: h.Client,
        there: h.Client,

        const Self = @This();

        fn init(self: *Self) !void {
            self.there_repo = try h.Local(kind).init();
            errdefer self.there_repo.deinit();
            self.here_repo = try h.Local(kind).init();
            errdefer self.here_repo.deinit();
            var repo = try xit.repo.Repo(kind, h.Local(kind).repo_opts).open(io, gpa, .{ .path = self.here_repo.path });
            defer repo.deinit(io, gpa);
            try repo.addRemote(io, gpa, .{ .name = "origin", .value = self.there_repo.path });
            self.here = self.here_repo.client();
            self.there = self.there_repo.client();
        }

        fn deinit(self: *Self) void {
            self.here.deinit();
            self.there.deinit();
            self.here_repo.deinit();
            self.there_repo.deinit();
        }

        fn sync(self: *Self) !void {
            const r = try self.here.post("/sync", &.{});
            defer r.deinit();
            try r.expectRedirect("/events");
            const cookies = try r.headerValues("set-cookie");
            try std.testing.expectEqualStrings("haxy_local_flash=; Path=/; Max-Age=0", cookies[0]);
        }

        // a branch with a commit of its own in one side's repo
        fn branch(local: *const h.Local(kind), name: []const u8) !void {
            var repo = try xit.repo.Repo(kind, h.Local(kind).repo_opts).open(io, gpa, .{ .path = local.path });
            defer repo.deinit(io, gpa);
            try repo.addBranch(io, .{ .name = name });
            {
                var selected = try repo.switchDir(io, gpa, .{ .target = .{ .ref = .{ .kind = .head, .name = name } } });
                selected.deinit();
            }
            {
                const file = try repo.core.work_dir.createFile(io, "readme.txt", .{ .truncate = true });
                defer file.close(io);
                try file.writeStreamingAll(io, name);
            }
            try repo.add(io, gpa, &.{"readme.txt"});
            _ = try repo.commit(io, gpa, .{ .message = name, .author = "tester <tester@example.test>" });
            var restored = try repo.switchDir(io, gpa, .{ .target = .{ .ref = .{ .kind = .head, .name = "master" } } });
            restored.deinit();
        }
    };
}

const Fields = struct { title: []const u8 = "base", labels: []const u8 = "a", description: []const u8 = base_description };

fn located(c: *h.Client, r: *const h.Response) ![]const u8 {
    try r.expectStatus(.see_other);
    return c.arena.allocator().dupe(u8, r.header("location") orelse return error.TestExpectedLocation);
}

fn path(c: *h.Client, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(c.arena.allocator(), fmt, args);
}

fn edit(c: *h.Client, thread: []const u8, fields: Fields, target_branch: ?[]const u8) !void {
    var form: std.ArrayList(h.Field) = .empty;
    defer form.deinit(gpa);
    try form.appendSlice(gpa, &.{ .{ "title", fields.title }, .{ "labels", fields.labels }, .{ "description", fields.description } });
    if (target_branch) |value| try form.append(gpa, .{ "target_branch", value });
    const r = try c.post(try path(c, "{s}/edit", .{thread}), form.items);
    defer r.deinit();
    try r.expectRedirect(thread);
}

// a GET brings a local repo's pages up to its events branch
fn refresh(c: *h.Client, list: []const u8) !void {
    const r = try c.getJson(list);
    defer r.deinit();
    try r.expectStatus(.ok);
}

// an issue made here and synced there, then edited to `ours` here and
// `theirs` there, and synced again. returns its page.
fn conflictIssue(comptime kind: RepoKind, s: *Sides(kind), ours: Fields, theirs: Fields) ![]const u8 {
    const created = try s.here.post("/issues/new", &.{ .{ "title", "base" }, .{ "labels", "a" }, .{ "description", base_description } });
    defer created.deinit();
    const issue = try located(&s.here, created);
    try s.sync();
    try refresh(&s.there, "/issues");
    try edit(&s.here, issue, ours, null);
    try edit(&s.there, issue, theirs, null);
    try s.sync();
    return issue;
}

const all_apart: struct { Fields, Fields } = .{
    .{ .title = "ours", .labels = "a ours", .description = "one\nOURS\nthree\n" },
    .{ .title = "theirs", .labels = "a theirs", .description = "one\nTHEIRS\nthree\n" },
};

fn conflictsCount(c: *h.Client, list: []const u8, window: []const u8) !i64 {
    const page = try c.getJson(list);
    defer page.deinit();
    const count = page.jsonAt(window) orelse {
        page.describe();
        return error.TestExpectedJson;
    };
    return count.integer;
}

fn expectIssueConflicts(c: *h.Client, expected: i64) !void {
    try std.testing.expectEqual(expected, try conflictsCount(c, "/issues", "page.repo.issues.conflicts.count"));
}

fn expectIssue(c: *h.Client, issue: []const u8, fields: Fields) !void {
    const page = try c.getJson(issue);
    defer page.deinit();
    try page.expectStatus(.ok);
    try page.expectJson("page.repo.issues.open.items.0.conflicted", false);
    try page.expectJson("page.repo.issues.open.items.0.record.event.title", fields.title);
    try page.expectJson("page.repo.issues.open.items.0.record.event.labels", fields.labels);
    try page.expectJson("page.repo.issues.open.items.0.record.event.description", fields.description);
}

// ---- what a conflict shows

fn expectConflictListed(comptime kind: RepoKind) !void {
    var s: Sides(kind) = undefined;
    try s.init();
    defer s.deinit();
    const issue = try conflictIssue(kind, &s, all_apart[0], all_apart[1]);

    const list = try s.here.getJson("/issues");
    defer list.deinit();
    try list.expectJson("page.repo.issues.open.count", 1);
    try list.expectJson("page.repo.issues.conflicts.count", 1);
    try list.expectJson("page.repo.issues.conflicts.items.0.conflicted", true);
    // the live fields are ours until it is resolved
    try list.expectJson("page.repo.issues.conflicts.items.0.record.event.title", "ours");
    try list.expectJson("page.repo.issues.open.items.0.conflicted", true);

    const window = try s.here.getJson("/issues/conflicts");
    defer window.deinit();
    try window.expectJson("page.repo.issues.view", "conflicts");
    try window.expectJson("page.repo.issues.conflicts.items.0.record.event.description", "one\nOURS\nthree\n");

    const thread = try s.here.getJson(issue);
    defer thread.deinit();
    try thread.expectJson("page.repo.issues.open.items.0.conflicted", true);
    // the thread page names no conflict; the resolve page does
    try thread.expectJson("page.repo.issues.conflict", null);

    // the push took the merge there, which is conflicted the same way
    const there = try s.there.getJson("/issues");
    defer there.deinit();
    try there.expectJson("page.repo.issues.conflicts.count", 1);
    try there.expectJson("page.repo.issues.conflicts.items.0.record.event.title", "ours");
}

test "web: an issue edited apart in two synced local repos is listed as conflicted on both sides" {
    try expectConflictListed(.git);
    try expectConflictListed(.xit);
}

fn expectResolvePage(comptime kind: RepoKind) !void {
    var s: Sides(kind) = undefined;
    try s.init();
    defer s.deinit();
    const issue = try conflictIssue(kind, &s, all_apart[0], all_apart[1]);

    const page = try s.here.getJson(try path(&s.here, "{s}/resolve", .{issue}));
    defer page.deinit();
    try page.expectStatus(.ok);
    try page.expectJson("page.repo.issues.view", "resolve");
    try page.expectJson("page.repo.issues.theirs_picks", "");
    try page.expectJson("page.repo.issues.conflict.title.ours.text", "ours");
    try page.expectJson("page.repo.issues.conflict.title.theirs.text", "theirs");
    try page.expectJson("page.repo.issues.conflict.labels.ours.text", "a ours");
    try page.expectJson("page.repo.issues.conflict.labels.theirs.text", "a theirs");
    // the description in chunks, the conflicting one numbered d0 by the form
    try page.expectJson("page.repo.issues.conflict.description.chunks.0.same", "one");
    try page.expectJson("page.repo.issues.conflict.description.chunks.1.conflict.ours", "OURS");
    try page.expectJson("page.repo.issues.conflict.description.chunks.1.conflict.theirs", "THEIRS");
    try page.expectJson("page.repo.issues.conflict.description.chunks.2.same", "three\n");
    try std.testing.expectEqual(null, page.jsonAt("page.repo.issues.conflict.description.chunks.3"));

    // picking their side is a url, which the snapshot carries for the form's prefills
    const picked = try s.here.getJson(try path(&s.here, "/issue:{s}/theirs:title,d0/resolve", .{issue["/issue:".len..]}));
    defer picked.deinit();
    try picked.expectStatus(.ok);
    try picked.expectJson("page.repo.issues.theirs_picks", "title,d0");
    try picked.expectJson("page.repo.issues.conflict.title.theirs.text", "theirs");
}

test "web: a conflicted issue's resolve page shows both sides and the description's conflicting hunk" {
    try expectResolvePage(.git);
    try expectResolvePage(.xit);
}

fn expectOneFieldApart(comptime kind: RepoKind, ours: Fields, theirs: Fields, apart: []const u8) !void {
    var s: Sides(kind) = undefined;
    try s.init();
    defer s.deinit();
    const issue = try conflictIssue(kind, &s, ours, theirs);
    try expectIssueConflicts(&s.here, 1);
    const page = try s.here.getJson(try path(&s.here, "{s}/resolve", .{issue}));
    defer page.deinit();
    for ([_][]const u8{ "title", "labels", "description" }) |field| {
        const at = try path(&s.here, "page.repo.issues.conflict.{s}", .{field});
        if (std.mem.eql(u8, field, apart)) try page.expectJsonHas(at) else try page.expectJson(at, null);
    }
}

test "web: an issue's title, labels and description each conflict on their own" {
    inline for ([_]RepoKind{ .git, .xit }) |kind| {
        try expectOneFieldApart(kind, .{ .title = "ours" }, .{ .title = "theirs" }, "title");
        try expectOneFieldApart(kind, .{ .labels = "a ours" }, .{ .labels = "a theirs" }, "labels");
        try expectOneFieldApart(kind, .{ .description = "one\nOURS\nthree\n" }, .{ .description = "one\nTHEIRS\nthree\n" }, "description");
    }
}

// ---- resolving

fn expectResolved(comptime kind: RepoKind, form: []const h.Field, result: Fields) !void {
    var s: Sides(kind) = undefined;
    try s.init();
    defer s.deinit();
    const issue = try conflictIssue(kind, &s, all_apart[0], all_apart[1]);

    const r = try s.here.post(try path(&s.here, "{s}/resolve", .{issue}), form);
    defer r.deinit();
    try r.expectRedirect(issue);
    try expectIssueConflicts(&s.here, 0);
    try expectIssue(&s.here, issue, result);

    // the resolution travels with the next sync
    try s.sync();
    try expectIssueConflicts(&s.there, 0);
    try expectIssue(&s.there, issue, result);
}

test "web: resolving a conflicted issue by taking our side settles it on both sides" {
    const form: []const h.Field = &.{ .{ "title", "ours" }, .{ "labels", "a ours" }, .{ "d0", "OURS" } };
    try expectResolved(.git, form, all_apart[0]);
    try expectResolved(.xit, form, all_apart[0]);
}

test "web: resolving a conflicted issue by taking their side settles it on both sides" {
    const form: []const h.Field = &.{ .{ "title", "theirs" }, .{ "labels", "a theirs" }, .{ "d0", "THEIRS" } };
    try expectResolved(.git, form, all_apart[1]);
    try expectResolved(.xit, form, all_apart[1]);
}

test "web: resolving a conflicted issue with edited text keeps that text, its hunk's line breaks normalized" {
    const form: []const h.Field = &.{ .{ "title", "settled" }, .{ "labels", "a both" }, .{ "d0", "OURS\r\nTHEIRS" } };
    const result: Fields = .{ .title = "settled", .labels = "a both", .description = "one\nOURS\nTHEIRS\nthree\n" };
    try expectResolved(.git, form, result);
    try expectResolved(.xit, form, result);
}

test "web: a resolve with no hunks keeps our hunk, and hunks past the conflicting ones are ignored" {
    inline for ([_]RepoKind{ .git, .xit }) |kind| {
        try expectResolved(kind, &.{ .{ "title", "theirs" }, .{ "labels", "a theirs" } }, .{ .title = "theirs", .labels = "a theirs", .description = "one\nOURS\nthree\n" });
        try expectResolved(kind, &.{ .{ "title", "theirs" }, .{ "labels", "a theirs" }, .{ "d0", "THEIRS" }, .{ "d1", "extra" } }, all_apart[1]);
    }
}

test "web: a resolve without title or labels keeps our live ones" {
    inline for ([_]RepoKind{ .git, .xit }) |kind| {
        try expectResolved(kind, &.{.{ "d0", "THEIRS" }}, .{ .title = "ours", .labels = "a ours", .description = "one\nTHEIRS\nthree\n" });
    }
}

fn expectRefusedResolve(comptime kind: RepoKind, form: []const h.Field) !void {
    var s: Sides(kind) = undefined;
    try s.init();
    defer s.deinit();
    const issue = try conflictIssue(kind, &s, all_apart[0], all_apart[1]);

    const resolve = try path(&s.here, "{s}/resolve", .{issue});
    const r = try s.here.post(resolve, form);
    defer r.deinit();
    // invalid fields go back to the resolve form, with no feedback
    try r.expectRedirect(resolve);
    try std.testing.expectEqual(null, s.here.cookie("haxy_local_flash"));
    const page = try s.here.followJson(r);
    defer page.deinit();
    try page.expectJson("session.form_feedback", null);
    try page.expectJson("page.repo.issues.conflict.title.theirs.text", "theirs");
    try expectIssueConflicts(&s.here, 1);
}

const label_65: []const u8 = blk: {
    const text: [65]u8 = @splat('l');
    break :blk &text;
};

test "web: resolving a conflicted issue to a blank title or an overlong label goes back to the resolve form and leaves the conflict" {
    inline for ([_]RepoKind{ .git, .xit }) |kind| {
        try expectRefusedResolve(kind, &.{ .{ "title", " " }, .{ "labels", "a" }, .{ "d0", "OURS" } });
        try expectRefusedResolve(kind, &.{ .{ "title", "settled" }, .{ "labels", "a " ++ label_65 }, .{ "d0", "OURS" } });
    }
}

test "web: resolving an issue of a local repo that names no issue is not found" {
    var s: Sides(.git) = undefined;
    try s.init();
    defer s.deinit();

    const r = try s.here.post("/issue:00000000000000000000000000000000/resolve", &.{ .{ "title", "x" }, .{ "d0", "y" } });
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("issue not found", r.body);
}

// ---- patches

// a patch from feature made here and synced there, then edited apart on both
// sides and synced again. both keep master as its target: changing the target
// rebuilds the patch from its source branch, which the other side's unrelated
// history can't do (and a local patch edit that fails that way answers 500
// InvalidFormFeedback, at 66c1ab6 too). so its status, revision and target
// branch, the fields a theirs: pick takes, can't be made to conflict this way.
fn conflictPatch(comptime kind: RepoKind, s: *Sides(kind)) ![]const u8 {
    try Sides(kind).branch(&s.here_repo, "feature");
    const created = try s.here.post("/patches/new", &.{
        .{ "title", "base" }, .{ "labels", "a" }, .{ "description", base_description }, .{ "target_branch", "master" }, .{ "source_branch", "feature" },
    });
    defer created.deinit();
    const patch = try located(&s.here, created);
    try s.sync();
    try refresh(&s.there, "/patches");
    try edit(&s.here, patch, all_apart[0], "master");
    try edit(&s.there, patch, all_apart[1], "master");
    try s.sync();
    return patch;
}

fn expectPatchConflict(comptime kind: RepoKind) !void {
    var s: Sides(kind) = undefined;
    try s.init();
    defer s.deinit();
    const patch = try conflictPatch(kind, &s);
    try std.testing.expectEqual(1, try conflictsCount(&s.here, "/patches", "page.repo.patches.conflicts.count"));
    try std.testing.expectEqual(1, try conflictsCount(&s.there, "/patches", "page.repo.patches.conflicts.count"));

    const page = try s.here.getJson(try path(&s.here, "{s}/resolve", .{patch}));
    defer page.deinit();
    try page.expectJson("page.repo.patches.view", "resolve");
    try page.expectJson("page.repo.patches.conflict.title.ours.text", "ours");
    try page.expectJson("page.repo.patches.conflict.title.theirs.text", "theirs");
    try page.expectJson("page.repo.patches.conflict.labels.theirs.text", "a theirs");
    try page.expectJson("page.repo.patches.conflict.description.chunks.1.conflict.theirs", "THEIRS");
    try page.expectJson("page.repo.patches.conflict.target_branch", null);
    try page.expectJson("page.repo.patches.conflict.status", null);

    const r = try s.here.post(try path(&s.here, "{s}/resolve", .{patch}), &.{ .{ "title", "theirs" }, .{ "labels", "a" }, .{ "d0", "THEIRS" } });
    defer r.deinit();
    try r.expectRedirect(patch);
    try std.testing.expectEqual(0, try conflictsCount(&s.here, "/patches", "page.repo.patches.conflicts.count"));
    const shown = try s.here.getJson(patch);
    defer shown.deinit();
    try shown.expectJson("page.repo.patches.open.items.0.conflicted", false);
    try shown.expectJson("page.repo.patches.open.items.0.record.event.title", "theirs");
    try shown.expectJson("page.repo.patches.open.items.0.record.event.labels", "a");
    try shown.expectJson("page.repo.patches.open.items.0.record.event.description", "one\nTHEIRS\nthree\n");
    try shown.expectJson("page.repo.patches.open.items.0.record.event.target_branch", "master");

    try s.sync();
    try std.testing.expectEqual(0, try conflictsCount(&s.there, "/patches", "page.repo.patches.conflicts.count"));
}

test "web: a patch edited apart in two synced local repos conflicts on both sides and resolves through the form" {
    try expectPatchConflict(.git);
    try expectPatchConflict(.xit);
}
