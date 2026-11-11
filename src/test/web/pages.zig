//! page snapshot baselines: the whole json of a fixed set of pages, per world
//! and per viewer where the page differs by viewer, compared with the goldens
//! in `golden/`. see `snapshot.zig` for the canonical form and how to rewrite
//! the goldens, and `world.zig` for the data.
//!
//! a GET has effects: it consumes a form flash and marks the viewer's
//! notifications on that thread read. so the order of the snapshots within a
//! world is fixed and part of the baseline: moving one can change another.

const std = @import("std");
const xit = @import("xit");
const h = @import("harness.zig");
const snap = @import("snapshot.zig");
const world = @import("world.zig");

const gpa = std.testing.allocator;

// takes a world's snapshots in order, collecting every failure
const Run = struct {
    report: snap.Report,
    book: *world.Book,
    broken: std.ArrayList([]const u8) = .empty,

    fn init(name: []const u8, book: *world.Book) Run {
        return .{ .report = snap.Report.init(name), .book = book };
    }

    fn deinit(self: *Run) void {
        self.broken.deinit(gpa);
        self.report.deinit();
    }

    // the page at `path` as `c` sees it, which is the route `route`
    fn page(self: *Run, name: []const u8, c: *h.Client, path: []const u8, route: []const u8) !void {
        try self.take(name, c, path, .{ .route = route });
    }

    // a page answered as not found
    fn missing(self: *Run, name: []const u8, c: *h.Client, path: []const u8) !void {
        try self.take(name, c, path, .{ .status = .not_found, .route = "not_found" });
    }

    fn take(self: *Run, name: []const u8, c: *h.Client, path: []const u8, expect: snap.Expect) !void {
        snap.take(&self.report, &self.book.names, c, name, path, expect) catch |err| switch (err) {
            error.TestSnapshotStatus, error.TestSnapshotNotJson, error.TestSnapshotRoute, error.TestSnapshotShape => {
                try self.broken.append(gpa, try self.book.print("{s} ({t})", .{ name, err }));
            },
            else => return err,
        };
    }

    fn finish(self: *Run) !void {
        if (self.broken.items.len != 0) {
            std.debug.print("\nworld {s}: {d} pages did not answer as expected:\n", .{ self.report.world, self.broken.items.len });
            for (self.broken.items) |name| std.debug.print("  {s}\n", .{name});
        }
        self.report.finish() catch |err| return err;
        if (self.broken.items.len != 0) return error.TestSnapshotBroken;
    }

    fn p(self: *Run, comptime fmt: []const u8, args: anytype) ![]const u8 {
        return self.book.print(fmt, args);
    }
};

// the newest undo entry of `repo` that wrote events, whose moment the events
// tab can show; the arrangement's commits and config writes are entries too
fn eventsMoment(c: *h.Client, repo: []const u8) !i64 {
    var buffer: [128]u8 = undefined;
    const r = try c.getJson(try std.fmt.bufPrint(&buffer, "{s}/undo", .{repo}));
    defer r.deinit();
    try r.expectStatus(.ok);
    const items = (r.jsonAt("page.repo.undo.items") orelse return error.TestExpectedJson).array.items;
    for (items) |item| if (item.object.get("buttons").?.array.items.len != 0) return item.object.get("index").?.integer;
    return error.TestNoEventsMoment;
}

test "web: page snapshots of the sha1 server world" {
    const w = try world.Server.build(.sha1, true);
    defer w.deinit();
    var run = Run.init("server-sha1", &w.book);
    defer run.deinit();
    const b = &w.book;

    const roof = b.real("issue", "leaky-roof");
    const comment = struct {
        fn id(book: *world.Book, n: []const u8) []const u8 {
            return book.real("comment", n);
        }
    }.id;
    const open = "/alice:open";

    // ---- home and users
    try run.page("home.anon", &w.anon, "/", "home_about");
    try run.page("home.alice", &w.alice, "/", "home_about");
    try run.page("users.anon", &w.anon, "/home/users", "home_users");
    try run.page("users.second-window", &w.anon, "/home/users/start:20", "home_users");
    try run.page("users.search", &w.alice, "/home/users/search:user1", "home_users");
    try run.page("alice.anon", &w.anon, "/alice", "user_repos");
    try run.page("alice.alice", &w.alice, "/alice", "user_repos");
    try run.page("alice.bob", &w.bob, "/alice", "user_repos");
    try run.page("alice.second-window", &w.alice, "/alice/repos/start:20", "user_repos");
    try run.page("alice.search", &w.alice, "/alice/repos/search:repo1", "user_repos");
    try run.page("bob.forks.bob", &w.bob, "/bob/forks", "user_forks");
    try run.page("bob.forks.anon", &w.anon, "/bob/forks", "user_forks");
    try run.page("bob.forks.alice", &w.alice, "/bob/forks", "user_forks");
    try run.page("alice.repo-new", &w.alice, "/alice/repo/new", "user_repo_new");
    try run.page("alice.user-tab.bob", &w.bob, "/alice/user", "user_user");
    try run.page("repo-new.alice", &w.alice, "/home/repo/new", "home_repo_new");
    try run.page("user-new.anon", &w.anon, "/home/user/new", "home_user_new");
    try run.page("login.anon", &w.anon, "/home/user", "home_user");
    try run.missing("not-found.anon", &w.anon, "/home/not-found");
    try run.missing("unknown-route.alice", &w.alice, "/alice:open/no/such/page");
    try run.missing("unknown-user.anon", &w.anon, "/nobody");

    // ---- alice's account; the inbox before she opens the long issue again
    try run.page("inbox.alice", &w.alice, "/home/user", "home_user");
    try run.page("inbox.bob", &w.bob, "/home/user", "home_user");
    try run.page("account-settings.alice", &w.alice, "/home/user/settings", "home_user");
    try run.page("keys.alice", &w.alice, "/home/user/keys", "home_user");
    try run.page("key.alice", &w.alice, "/home/user/keys/key:" ++ world.alice_fingerprint, "home_user");
    try run.page("key-remove.alice", &w.alice, "/home/user/keys/key:" ++ world.alice_fingerprint ++ "/removekey", "home_user");
    try run.page("account-delete.alice", &w.alice, "/home/user/delete", "home_user");

    // ---- open: files, by viewer
    for ([_]struct { []const u8, *h.Client }{
        .{ "anon", &w.anon }, .{ "alice", &w.alice }, .{ "bob", &w.bob }, .{ "erin", &w.erin }, .{ "carol", &w.carol }, .{ "frank", &w.frank },
    }) |viewer| try run.page(try run.p("open.{s}", .{viewer[0]}), viewer[1], open, "repo_files");
    try run.page("files.dir", &w.alice, open ++ "/files/branch:master/path:src", "repo_files");
    try run.page("files.nested-dir", &w.anon, open ++ "/files/branch:master/path:src/lib", "repo_files");
    try run.page("files.markdown", &w.alice, open ++ "/files/branch:master/path:docs/guide.md", "repo_files");
    try run.page("files.long", &w.alice, open ++ "/files/branch:master/path:docs/long.txt", "repo_files");
    try run.page("files.long-second-window", &w.alice, open ++ "/files/branch:master/line:5001/path:docs/long.txt", "repo_files");
    try run.page("files.binary", &w.alice, open ++ "/files/branch:master/path:logo.png", "repo_files");
    try run.page("files.find", &w.alice, open ++ "/files/find:util", "repo_files");
    try run.page("files.find-selected", &w.alice, open ++ "/files/find:util/path:src/lib/util.zig", "repo_files");
    try run.page("files.tag", &w.alice, open ++ "/files/tag:v1.0", "repo_files");
    try run.page("files.object", &w.alice, try run.p(open ++ "/files/object:{s}/path:src", .{b.real("commit", "initial")}), "repo_files");
    try run.page("files.branch-slash", &w.alice, open ++ "/files/branch:team%2Fnext", "repo_files");
    try run.page("files.branch-percent", &w.alice, open ++ "/files/branch:100%25done", "repo_files");
    try run.page("files.branch-unicode", &w.alice, open ++ "/files/branch:caf%C3%A9", "repo_files");
    try run.page("files.feature-file", &w.alice, open ++ "/files/branch:feature/path:feature.txt", "repo_files");
    try run.page("files.patchrev", &w.alice, try run.p(open ++ "/files/patchrev:{s}", .{b.real("patchrev", "p-open")}), "repo_files");
    try run.missing("files.no-such-branch", &w.alice, open ++ "/files/branch:nope");

    // ---- history and diffs
    try run.page("commits", &w.alice, open ++ "/commits", "repo_commits");
    try run.page("commits.anon", &w.anon, open ++ "/commits/branch:master", "repo_commits");
    try run.page("commits.later-window", &w.alice, try run.p(open ++ "/commits/branch:master/from:{s}", .{b.real("commit", "change-03")}), "repo_commits");
    try run.page("commits.search", &w.alice, open ++ "/commits/branch:master/search:change", "repo_commits");
    try run.page("commits.message", &w.alice, try run.p(open ++ "/commits/object:{s}/message", .{b.real("commit", "change-02")}), "repo_commits");
    try run.page("commits.object", &w.alice, try run.p(open ++ "/commits/object:{s}", .{b.real("commit", "feature-2")}), "repo_commits");
    try run.page("commits.merge", &w.alice, try run.p(open ++ "/commits/merge:{s}", .{b.real("commit", "merge-side")}), "repo_commits");
    try run.page("commits.tag", &w.alice, open ++ "/commits/tag:v1.0", "repo_commits");
    try run.page("commits.feature", &w.alice, open ++ "/commits/branch:feature", "repo_commits");
    try run.page("diff.commit", &w.alice, try run.p(open ++ "/diff/object:{s}/base:{s}", .{ b.real("commit", "change-02"), b.real("commit", "change-01") }), "repo_diff");
    try run.page("diff.windows", &w.alice, try run.p(open ++ "/diff/object:{s}/base:{s}", .{ b.real("commit", "shout"), b.real("commit", "change-22") }), "repo_diff");
    try run.page("diff.second-window", &w.alice, try run.p(open ++ "/diff/object:{s}/base:{s}/start:10", .{ b.real("commit", "shout"), b.real("commit", "change-22") }), "repo_diff");
    try run.page("diff.file", &w.alice, try run.p(open ++ "/diff/object:{s}/base:{s}/path:src/main.zig", .{ b.real("commit", "feature-1"), b.real("commit", "shout") }), "repo_diff");
    try run.page("diff.patchrev", &w.alice, try run.p(open ++ "/diff/patchrev:{s}", .{b.real("patchrev", "p-open")}), "repo_diff");

    // ---- refs
    try run.page("refs", &w.alice, open ++ "/refs", "repo_refs");
    try run.page("refs.later-window", &w.anon, open ++ "/refs/branch:b%2F40", "repo_refs");
    try run.page("refs.tags", &w.alice, open ++ "/refs/tag:v1.0", "repo_refs");
    try run.page("refs.search", &w.alice, open ++ "/refs/search:fix", "repo_refs");

    // ---- issues
    for ([_]struct { []const u8, *h.Client }{
        .{ "anon", &w.anon }, .{ "alice", &w.alice }, .{ "bob", &w.bob }, .{ "erin", &w.erin }, .{ "carol", &w.carol },
    }) |viewer| try run.page(try run.p("issues.{s}", .{viewer[0]}), viewer[1], open ++ "/issues", "repo_issues");
    try run.page("issues.closed", &w.alice, open ++ "/issues/closed", "repo_issues");
    try run.page("issues.second-window", &w.alice, try run.p(open ++ "/issues/start:{s}/open", .{b.real("issue", "issue-01")}), "repo_issues");
    try run.page("issues.search", &w.alice, open ++ "/issues/open/search:roof", "repo_issues");
    try run.page("issues.search-closed", &w.bob, open ++ "/issues/closed/search:door", "repo_issues");
    try run.page("issues.labels", &w.alice, open ++ "/issues/labels", "repo_issues");
    try run.page("issues.new", &w.bob, open ++ "/issues/new", "repo_issues");
    // alice opening it marks the comments since she last read it as read
    for ([_]struct { []const u8, *h.Client }{
        .{ "anon", &w.anon }, .{ "alice", &w.alice }, .{ "bob", &w.bob }, .{ "erin", &w.erin }, .{ "carol", &w.carol }, .{ "frank", &w.frank },
    }) |viewer| try run.page(try run.p("roof.{s}", .{viewer[0]}), viewer[1], try run.p(open ++ "/issue:{s}", .{roof}), "repo_issues");
    try run.page("roof.comments-second-window", &w.alice, try run.p(open ++ "/issue:{s}/start:10", .{roof}), "repo_issues");
    try run.page("roof.comment", &w.bob, try run.p(open ++ "/issue:{s}/comment:{s}", .{ roof, comment(b, "leaky-roof.c06") }), "repo_issues");
    try run.page("roof.comment-second-window", &w.alice, try run.p(open ++ "/issue:{s}/comment:{s}/start:10", .{ roof, comment(b, "leaky-roof.c12") }), "repo_issues");
    try run.page("roof.reply", &w.alice, try run.p(open ++ "/issue:{s}/comment:{s}/new", .{ roof, comment(b, "leaky-roof.c03") }), "repo_issues");
    try run.page("roof.new-comment", &w.carol, try run.p(open ++ "/issue:{s}/new", .{roof}), "repo_issues");
    try run.page("roof.edit-comment", &w.frank, try run.p(open ++ "/issue:{s}/comment:{s}/edit", .{ roof, comment(b, "leaky-roof.c02") }), "repo_issues");
    try run.page("roof.edit", &w.alice, try run.p(open ++ "/issue:{s}/edit", .{roof}), "repo_issues");
    try run.page("roof.description", &w.bob, try run.p(open ++ "/issue:{s}/description", .{roof}), "repo_issues");
    try run.page("roof.remove", &w.alice, try run.p(open ++ "/issue:{s}/remove", .{roof}), "repo_issues");
    try run.page("roof.remove-comment", &w.alice, try run.p(open ++ "/issue:{s}/comment:{s}/remove", .{ roof, comment(b, "leaky-roof.c10") }), "repo_issues");
    try run.page("roof.remove-attachment", &w.alice, try run.p(open ++ "/issue:{s}/attachment:{s}/remove", .{ roof, b.real("attach", "roof-photo") }), "repo_issues");
    try run.page("roof.resolve", &w.alice, try run.p(open ++ "/issue:{s}/resolve", .{roof}), "repo_issues");
    try run.page("roof.in-search", &w.alice, try run.p(open ++ "/issue:{s}/search:roof", .{roof}), "repo_issues");
    try run.page("door.closed", &w.bob, try run.p(open ++ "/issue:{s}", .{b.real("issue", "flaky-door")}), "repo_issues");
    try run.page("renamed.edited", &w.alice, try run.p(open ++ "/issue:{s}", .{b.real("issue", "renamed")}), "repo_issues");
    try run.missing("old-news.removed", &w.alice, try run.p(open ++ "/issue:{s}", .{b.real("issue", "old-news")}));
    try run.page("issues.conflicts", &w.alice, open ++ "/issues/conflicts", "repo_issues");

    // ---- discussions
    for ([_]struct { []const u8, *h.Client }{ .{ "anon", &w.anon }, .{ "alice", &w.alice }, .{ "carol", &w.carol } }) |viewer|
        try run.page(try run.p("discussions.{s}", .{viewer[0]}), viewer[1], open ++ "/discussions", "repo_discussions");
    try run.page("discussions.second-window", &w.alice, try run.p(open ++ "/discussions/start:{s}/recent", .{b.real("discuss", "roadmap")}), "repo_discussions");
    try run.page("discussions.search", &w.alice, open ++ "/discussions/recent/search:roadmap", "repo_discussions");
    try run.page("discussions.labels", &w.alice, open ++ "/discussions/labels", "repo_discussions");
    try run.page("discussions.new", &w.carol, open ++ "/discussions/new", "repo_discussions");
    const roadmap = b.real("discuss", "roadmap");
    try run.page("roadmap.alice", &w.alice, try run.p(open ++ "/discuss:{s}", .{roadmap}), "repo_discussions");
    try run.page("roadmap.carol", &w.carol, try run.p(open ++ "/discuss:{s}", .{roadmap}), "repo_discussions");
    try run.page("roadmap.comment", &w.bob, try run.p(open ++ "/discuss:{s}/comment:{s}", .{ roadmap, comment(b, "roadmap.c02") }), "repo_discussions");
    try run.page("roadmap.edit", &w.alice, try run.p(open ++ "/discuss:{s}/edit", .{roadmap}), "repo_discussions");
    try run.page("roadmap.description", &w.alice, try run.p(open ++ "/discuss:{s}/description", .{roadmap}), "repo_discussions");
    try run.page("roadmap.remove", &w.alice, try run.p(open ++ "/discuss:{s}/remove", .{roadmap}), "repo_discussions");

    // ---- patches
    for ([_]struct { []const u8, *h.Client }{
        .{ "anon", &w.anon }, .{ "alice", &w.alice }, .{ "bob", &w.bob }, .{ "erin", &w.erin }, .{ "carol", &w.carol },
    }) |viewer| try run.page(try run.p("patches.{s}", .{viewer[0]}), viewer[1], open ++ "/patches", "repo_patches");
    try run.page("patches.closed", &w.alice, open ++ "/patches/closed", "repo_patches");
    try run.page("patches.merged", &w.alice, open ++ "/patches/merged", "repo_patches");
    try run.page("patches.drafts.alice", &w.alice, open ++ "/patches/drafts", "repo_patches");
    try run.page("patches.drafts.bob", &w.bob, open ++ "/patches/drafts", "repo_patches");
    try run.page("patches.drafts.carol", &w.carol, open ++ "/patches/drafts", "repo_patches");
    try run.page("patches.labels", &w.alice, open ++ "/patches/labels", "repo_patches");
    try run.page("patches.new", &w.bob, open ++ "/patches/new", "repo_patches");
    try run.page("patches.search", &w.alice, open ++ "/patches/open/search:feature", "repo_patches");
    const p_open = b.real("patch", "p-open");
    for ([_]struct { []const u8, *h.Client }{ .{ "anon", &w.anon }, .{ "alice", &w.alice }, .{ "bob", &w.bob } }) |viewer|
        try run.page(try run.p("p-open.{s}", .{viewer[0]}), viewer[1], try run.p(open ++ "/patch:{s}", .{p_open}), "repo_patches");
    try run.page("p-open.merge", &w.alice, try run.p(open ++ "/patch:{s}/merge", .{p_open}), "repo_patches");
    try run.page("p-open.edit", &w.bob, try run.p(open ++ "/patch:{s}/edit", .{p_open}), "repo_patches");
    try run.page("p-open.description", &w.alice, try run.p(open ++ "/patch:{s}/description", .{p_open}), "repo_patches");
    try run.page("p-open.comment", &w.alice, try run.p(open ++ "/patch:{s}/comment:{s}", .{ p_open, comment(b, "p-open.c02") }), "repo_patches");
    try run.page("p-stale.alice", &w.alice, try run.p(open ++ "/patch:{s}", .{b.real("patch", "p-stale")}), "repo_patches");
    try run.page("p-stale.merge", &w.alice, try run.p(open ++ "/patch:{s}/merge", .{b.real("patch", "p-stale")}), "repo_patches");
    try run.page("p-closed.alice", &w.alice, try run.p(open ++ "/patch:{s}", .{b.real("patch", "p-closed")}), "repo_patches");
    try run.page("p-merged.alice", &w.alice, try run.p(open ++ "/patch:{s}", .{b.real("patch", "p-merged")}), "repo_patches");
    try run.page("p-squashed.anon", &w.anon, try run.p(open ++ "/patch:{s}", .{b.real("patch", "p-squashed")}), "repo_patches");
    const alice_draft = b.real("patch", "alice-draft");
    try run.page("alice-draft.alice", &w.alice, try run.p(open ++ "/patch:{s}", .{alice_draft}), "repo_patches");
    try run.page("alice-draft.publish", &w.alice, try run.p(open ++ "/patch:{s}/publish", .{alice_draft}), "repo_patches");
    try run.missing("alice-draft.bob", &w.bob, try run.p(open ++ "/patch:{s}", .{alice_draft}));
    try run.page("bob-fork.alice", &w.alice, try run.p(open ++ "/patch:{s}", .{b.real("patch", "bob-fork")}), "repo_patches");
    try run.page("patches.conflicts", &w.alice, open ++ "/patches/conflicts", "repo_patches");

    // ---- forks: a published one, a draft, one whose target was renamed and
    // one whose target was deleted
    const bob_fork = b.real("patch", "bob-fork");
    try run.page("fork.anon", &w.anon, try run.p("/bob:open+{s}", .{bob_fork}), "fork_patch");
    try run.page("fork.bob", &w.bob, try run.p("/bob:open+{s}", .{bob_fork}), "fork_patch");
    try run.page("fork.files", &w.bob, try run.p("/bob:open+{s}/files", .{bob_fork}), "fork_files");
    try run.page("fork.file", &w.alice, try run.p("/bob:open+{s}/files/path:fork.txt", .{bob_fork}), "fork_files");
    try run.page("fork.commits", &w.bob, try run.p("/bob:open+{s}/commits", .{bob_fork}), "fork_commits");
    try run.page("fork.diff", &w.alice, try run.p("/bob:open+{s}/diff", .{bob_fork}), "fork_diff");
    try run.page("fork.delete", &w.bob, try run.p("/bob:open+{s}/delete", .{bob_fork}), "fork_delete");
    try run.missing("fork.delete.alice", &w.alice, try run.p("/bob:open+{s}/delete", .{bob_fork}));
    try run.page("fork.draft.bob", &w.bob, try run.p("/bob:open+{s}", .{b.real("patch", "bob-draft")}), "fork_patch");
    try run.page("fork.renamed-target.bob", &w.bob, try run.p("/bob:moving+{s}", .{b.real("patch", "moving-draft")}), "fork_patch");
    try run.page("fork.deleted-target.bob", &w.bob, try run.p("/bob:doomed+{s}", .{b.real("patch", "doomed-draft")}), "fork_patch");
    try run.missing("fork.deleted-target.alice", &w.alice, try run.p("/bob:doomed+{s}", .{b.real("patch", "doomed-draft")}));
    try run.page("moved.alice", &w.alice, "/alice:moved/patches/drafts", "repo_patches");

    // ---- events and undo
    try run.page("events.alice", &w.alice, open ++ "/events/active", "repo_events");
    try run.page("events.bob", &w.bob, open ++ "/events/active", "repo_events");
    try run.missing("events.erin", &w.erin, open ++ "/events/active");
    try run.page("events.removed", &w.alice, open ++ "/events/removed", "repo_events");
    try run.page("events.moment", &w.alice, try run.p(open ++ "/events/active/moment:{d}", .{try eventsMoment(&w.alice, open)}), "repo_events");
    try run.page("events.detail", &w.alice, try run.p(open ++ "/event:{s}/kind:issue", .{roof}), "repo_events");
    try run.page("undo.alice", &w.alice, open ++ "/undo", "repo_undo");
    try run.page("undo.selected", &w.alice, open ++ "/undo/3", "repo_undo");
    try run.page("undo.tools", &w.alice, "/alice:tools/undo", "repo_undo");

    // ---- settings, members, branches
    try run.page("settings.alice", &w.alice, open ++ "/repo/settings", "repo_settings");
    try run.page("settings.frank", &w.frank, open ++ "/repo/settings", "repo_settings");
    try run.missing("settings.bob", &w.bob, open ++ "/repo/settings");
    try run.page("members.alice", &w.alice, open ++ "/repo/members", "repo_members");
    try run.page("members.revoke", &w.alice, open ++ "/repo/members/user:bob/revoke", "repo_members");
    try run.page("members.demote", &w.alice, open ++ "/repo/members/user:frank/demote", "repo_members");
    try run.page("branches.open", &w.alice, open ++ "/repo/branches", "repo_branches");
    try run.page("branches.tools", &w.alice, "/alice:tools/repo/branches", "repo_branches");
    try run.page("branches.tools-selected", &w.alice, "/alice:tools/repo/branches/branch:release", "repo_branches");
    try run.page("repo-delete.alice", &w.alice, open ++ "/repo/delete", "repo_delete");
    try run.page("repo-repo-new.alice", &w.alice, open ++ "/repo/new", "repo_repo_new");
    try run.page("repo-user.alice", &w.alice, open ++ "/user", "repo_user");

    // ---- tools: a members-only issues tab, patches off, another default branch
    try run.page("tools.anon", &w.anon, "/alice:tools", "repo_files");
    try run.page("tools.bob", &w.bob, "/alice:tools", "repo_files");
    try run.page("tools.issues.anon", &w.anon, "/alice:tools/issues", "repo_issues");
    try run.page("tools.issues.bob", &w.bob, "/alice:tools/issues", "repo_issues");
    try run.page("tools.issues.carol", &w.carol, "/alice:tools/issues", "repo_issues");
    try run.missing("tools.patches.alice", &w.alice, "/alice:tools/patches");

    // ---- the private repo
    try run.missing("secret.anon", &w.anon, "/alice:secret");
    try run.missing("secret.carol", &w.carol, "/alice:secret/issues");
    try run.page("secret.bob", &w.bob, "/alice:secret", "repo_files");
    try run.page("secret.issues.bob", &w.bob, "/alice:secret/issues", "repo_issues");
    try run.missing("no-such-repo.alice", &w.alice, "/alice:nothing");

    // ---- the inbox after alice opened the long issue
    try run.page("inbox.alice-after", &w.alice, "/home/user", "home_user");

    try run.finish();
}

test "web: page snapshots of the sha256 server world" {
    const w = try world.Server.build(.sha256, false);
    defer w.deinit();
    var run = Run.init("server-sha256", &w.book);
    defer run.deinit();
    const b = &w.book;
    const open = "/alice:open";
    const roof = b.real("issue", "leaky-roof");

    try run.page("alice.alice", &w.alice, "/alice", "user_repos");
    try run.page("open.anon", &w.anon, open, "repo_files");
    try run.page("open.alice", &w.alice, open, "repo_files");
    try run.page("files.dir", &w.alice, open ++ "/files/branch:master/path:src", "repo_files");
    try run.page("files.long", &w.alice, open ++ "/files/branch:master/path:docs/long.txt", "repo_files");
    try run.page("files.tag", &w.alice, open ++ "/files/tag:v1.0", "repo_files");
    try run.page("commits", &w.alice, open ++ "/commits", "repo_commits");
    try run.page("commits.message", &w.alice, try run.p(open ++ "/commits/object:{s}/message", .{b.real("commit", "change-02")}), "repo_commits");
    try run.page("commits.merge", &w.alice, try run.p(open ++ "/commits/merge:{s}", .{b.real("commit", "merge-side")}), "repo_commits");
    try run.page("diff.commit", &w.alice, try run.p(open ++ "/diff/object:{s}/base:{s}", .{ b.real("commit", "change-02"), b.real("commit", "change-01") }), "repo_diff");
    try run.page("refs", &w.alice, open ++ "/refs", "repo_refs");
    try run.page("issues.alice", &w.alice, open ++ "/issues", "repo_issues");
    try run.page("roof.bob", &w.bob, try run.p(open ++ "/issue:{s}", .{roof}), "repo_issues");
    try run.page("roof.anon", &w.anon, try run.p(open ++ "/issue:{s}", .{roof}), "repo_issues");
    try run.page("roof.comment", &w.alice, try run.p(open ++ "/issue:{s}/comment:{s}", .{ roof, b.real("comment", "leaky-roof.c01") }), "repo_issues");
    try run.page("discussions.alice", &w.alice, open ++ "/discussions", "repo_discussions");
    try run.page("roadmap.alice", &w.alice, try run.p(open ++ "/discuss:{s}", .{b.real("discuss", "roadmap")}), "repo_discussions");
    try run.page("patches.alice", &w.alice, open ++ "/patches", "repo_patches");
    try run.page("patches.drafts.alice", &w.alice, open ++ "/patches/drafts", "repo_patches");
    try run.page("p-open.alice", &w.alice, try run.p(open ++ "/patch:{s}", .{b.real("patch", "p-open")}), "repo_patches");
    try run.page("p-open.merge", &w.alice, try run.p(open ++ "/patch:{s}/merge", .{b.real("patch", "p-open")}), "repo_patches");
    try run.page("diff.patchrev", &w.alice, try run.p(open ++ "/diff/patchrev:{s}", .{b.real("patchrev", "p-open")}), "repo_diff");
    try run.page("fork.alice", &w.alice, try run.p("/alice:open+{s}", .{b.real("patch", "alice-draft")}), "fork_patch");
    try run.page("events.alice", &w.alice, open ++ "/events/active", "repo_events");
    try run.page("undo.alice", &w.alice, open ++ "/undo", "repo_undo");
    try run.page("settings.alice", &w.alice, open ++ "/repo/settings", "repo_settings");
    try run.page("inbox.alice", &w.alice, "/home/user", "home_user");
    try run.finish();
}

fn localPages(comptime kind: xit.repo.RepoKind, comptime name: []const u8) !void {
    const w = try world.Local(kind).build();
    defer w.deinit();
    var run = Run.init(name, &w.book);
    defer run.deinit();
    const b = &w.book;
    const here = &w.here;
    const roof = b.real("issue", "leaky-roof");
    const conflicted = b.real("issue", "conflicted");
    const p_conflicted = b.real("patch", "p-conflicted");

    try run.page("files", here, "/", "repo_files");
    try run.page("files.dir", here, "/files/branch:master/path:src", "repo_files");
    try run.page("files.markdown", here, "/files/branch:master/path:README.md", "repo_files");
    try run.page("files.binary", here, "/files/branch:master/path:logo.png", "repo_files");
    try run.page("files.branch-slash", here, "/files/branch:team%2Fnext", "repo_files");
    try run.page("files.tag", here, "/files/tag:v1.0", "repo_files");
    try run.page("commits", here, "/commits", "repo_commits");
    try run.page("commits.message", here, try run.p("/commits/object:{s}/message", .{b.real("commit", "again")}), "repo_commits");
    try run.page("diff.commit", here, try run.p("/diff/object:{s}/base:{s}", .{ b.real("commit", "again"), b.real("commit", "files") }), "repo_diff");
    try run.page("refs", here, "/refs", "repo_refs");
    try run.page("issues", here, "/issues", "repo_issues");
    try run.page("issues.closed", here, "/issues/closed", "repo_issues");
    try run.page("roof", here, try run.p("/issue:{s}", .{roof}), "repo_issues");
    try run.page("roof.comment", here, try run.p("/issue:{s}/comment:{s}", .{ roof, b.real("comment", "leaky-roof.c01") }), "repo_issues");
    try run.page("roof.edit", here, try run.p("/issue:{s}/edit", .{roof}), "repo_issues");
    try run.page("issues.new", here, "/issues/new", "repo_issues");
    try run.page("discussions", here, "/discussions", "repo_discussions");
    try run.page("roadmap", here, try run.p("/discuss:{s}", .{b.real("discuss", "roadmap")}), "repo_discussions");
    try run.page("patches", here, "/patches", "repo_patches");
    try run.page("p-open", here, try run.p("/patch:{s}", .{b.real("patch", "p-open")}), "repo_patches");
    try run.page("diff.patchrev", here, try run.p("/diff/patchrev:{s}", .{b.real("patchrev", "p-open")}), "repo_diff");
    try run.page("events", here, "/events/active", "repo_events");
    // a local host has no undo tab
    try run.missing("undo", here, "/undo");
    // the conflicts, on both sides
    try run.page("issues.conflicts", here, "/issues/conflicts", "repo_issues");
    try run.page("conflicted", here, try run.p("/issue:{s}", .{conflicted}), "repo_issues");
    try run.page("conflicted.resolve", here, try run.p("/issue:{s}/resolve", .{conflicted}), "repo_issues");
    try run.page("conflicted.resolve-theirs", here, try run.p("/issue:{s}/theirs:title,d0/resolve", .{conflicted}), "repo_issues");
    try run.page("patches.conflicts", here, "/patches/conflicts", "repo_patches");
    try run.page("p-conflicted.resolve", here, try run.p("/patch:{s}/resolve", .{p_conflicted}), "repo_patches");
    try run.page("there.issues", &w.there, "/issues", "repo_issues");
    try run.page("there.conflicted.resolve", &w.there, try run.p("/issue:{s}/resolve", .{conflicted}), "repo_issues");
    try run.finish();
}

test "web: page snapshots of the local git world" {
    try localPages(.git, "local-git");
}

test "web: page snapshots of the local xit world" {
    try localPages(.xit, "local-xit");
}

// the texts a search or find is typed with: percent-encoded as a browser sends
// them, and as a sloppy link might (a raw `%41`, a raw `+`, raw utf-8)
const edge_searches = [_]struct { []const u8, []const u8 }{
    .{ "pct", "tok%2541" },
    .{ "pct-raw", "tok%41" },
    .{ "a", "tokA" },
    .{ "plus", "tok%2Bplus" },
    .{ "plus-raw", "tok+plus" },
    .{ "space", "tok%20plus" },
    .{ "uni", "tok%C3%A9toile" },
    .{ "uni-raw", "tokétoile" },
    .{ "slash", "tok%2Fslash" },
    .{ "label-pct", "label%3Alab%2541" },
    .{ "label-plus", "label%3Alab%2Bplus" },
    .{ "label-uni", "label%3Alab%C3%A9" },
    .{ "label-none", "label%3Anomatch" },
    .{ "assignee-bob", "assignee%3Abob%40example.test" },
    .{ "assignee-carol", "assignee%3Acarol%40example.test" },
    .{ "assignee-none", "assignee%3Anobody%40example.test" },
};

test "web: page snapshots of the edges world" {
    const w = try world.Server.buildMode(.sha1, .edges);
    defer w.deinit();
    var run = Run.init("edges", &w.book);
    defer run.deinit();
    const b = &w.book;
    const open = "/alice:open";

    // ---- each list searched by each awkward text
    for ([_]struct { []const u8, []const u8, []const u8 }{
        .{ "issues", "/issues/open", "repo_issues" },
        .{ "discussions", "/discussions/recent", "repo_discussions" },
        .{ "patches", "/patches/open", "repo_patches" },
    }) |list| {
        try run.page(try run.p("{s}", .{list[0]}), &w.alice, try run.p(open ++ "{s}", .{list[1]}), list[2]);
        for (edge_searches) |search| {
            try run.page(try run.p("{s}.search.{s}", .{ list[0], search[0] }), &w.alice, try run.p(open ++ "{s}/search:{s}", .{ list[1], search[1] }), list[2]);
        }
    }

    // ---- a selected thread the search includes, and one it excludes
    for ([_]struct { []const u8, []const u8, []const u8, []const u8 }{
        .{ "issue", "issue", "i", "repo_issues" },
        .{ "discuss", "discuss", "d", "repo_discussions" },
        .{ "patch", "patch", "p", "repo_patches" },
    }) |kind| {
        const included = b.real(kind[1], try run.p("{s}-pct", .{kind[2]}));
        const excluded = b.real(kind[1], try run.p("{s}-a", .{kind[2]}));
        try run.page(try run.p("{s}.selected-included", .{kind[0]}), &w.alice, try run.p(open ++ "/{s}:{s}/search:tok%2541", .{ kind[0], included }), kind[3]);
        try run.page(try run.p("{s}.selected-excluded", .{kind[0]}), &w.alice, try run.p(open ++ "/{s}:{s}/search:tok%2541", .{ kind[0], excluded }), kind[3]);
        try run.page(try run.p("{s}.selected-label", .{kind[0]}), &w.alice, try run.p(open ++ "/{s}:{s}/search:label%3Alab%2541", .{ kind[0], included }), kind[3]);
    }

    // ---- files: find and odd paths. a path: value is taken raw, so its
    // percent-encoded spelling names nothing
    for ([_]struct { []const u8, []const u8 }{
        .{ "pct", "tok%2541" },     .{ "pct-raw", "tok%41" }, .{ "plus", "tok%2Bplus" },  .{ "plus-raw", "tok+plus" },
        .{ "space", "tok%20plus" }, .{ "uni", "tok%C3%A9" },  .{ "dir-pct", "dir%2541" },
    }) |find| try run.page(try run.p("files.find.{s}", .{find[0]}), &w.alice, try run.p(open ++ "/files/find:{s}", .{find[1]}), "repo_files");
    try run.page("files.find-selected", &w.alice, open ++ "/files/find:tok%2541/path:tok%2541.txt", "repo_files");
    try run.missing("files.dir-pct", &w.alice, open ++ "/files/branch:master/path:dir%2541");
    try run.page("files.dir-pct-raw", &w.alice, open ++ "/files/branch:master/path:dir%41", "repo_files");
    try run.page("files.file-pct-raw", &w.alice, open ++ "/files/branch:master/path:tok%41.txt", "repo_files");
    try run.page("files.file-plus-raw", &w.alice, open ++ "/files/branch:master/path:tok+plus.txt", "repo_files");
    try run.missing("files.dir-space", &w.alice, open ++ "/files/branch:master/path:dir%20A");
    try run.missing("files.dir-plus-uni", &w.alice, open ++ "/files/branch:master/path:dir%2B%C3%A9");
    try run.missing("files.file-pct", &w.alice, open ++ "/files/branch:master/path:tok%2541.txt");
    try run.missing("files.file-space", &w.alice, open ++ "/files/branch:master/path:tok%20plus.txt");
    try run.page("files.branch-pct", &w.alice, open ++ "/files/branch:tok%2541", "repo_files");
    try run.page("files.branch-plus", &w.alice, open ++ "/files/branch:tok%2Bplus", "repo_files");
    try run.page("files.branch-slash", &w.alice, open ++ "/files/branch:tok%2Fslash", "repo_files");
    try run.page("files.tag-pct", &w.alice, open ++ "/files/tag:v%2541", "repo_files");

    // ---- commits searched by each awkward text
    for (edge_searches[0..9]) |search| {
        try run.page(try run.p("commits.search.{s}", .{search[0]}), &w.alice, try run.p(open ++ "/commits/branch:master/search:{s}", .{search[1]}), "repo_commits");
    }
    try run.page("commits.branch-plus", &w.alice, open ++ "/commits/branch:tok%2Bplus", "repo_commits");
    try run.page("commits.branch-uni", &w.alice, open ++ "/commits/branch:tok%C3%A9toile", "repo_commits");

    // ---- refs windows before and after a cursor with an encoded name
    try run.page("refs", &w.alice, open ++ "/refs", "repo_refs");
    try run.page("refs.from-pct", &w.alice, open ++ "/refs/branch:tok%2541", "repo_refs");
    try run.page("refs.from-plus", &w.alice, open ++ "/refs/branch:tok%2Bplus", "repo_refs");
    try run.page("refs.from-slash", &w.alice, open ++ "/refs/branch:tok%2Fslash", "repo_refs");
    try run.page("refs.from-uni", &w.alice, open ++ "/refs/branch:tok%C3%A9toile", "repo_refs");
    try run.page("refs.tag-from-pct", &w.alice, open ++ "/refs/tag:v%2541", "repo_refs");
    try run.page("refs.search-pct", &w.alice, open ++ "/refs/search:tok%2541", "repo_refs");
    try run.page("refs.search-plus", &w.alice, open ++ "/refs/search:tok%2B", "repo_refs");
    try run.page("refs.search-uni", &w.alice, open ++ "/refs/search:tok%C3%A9", "repo_refs");

    // ---- the second comment window of a long thread of each kind, with and
    // without a selected comment, and a permalink beyond the first window
    for ([_]struct { []const u8, []const u8, []const u8, []const u8 }{
        .{ "issue", "issue", "i-long", "repo_issues" },
        .{ "discuss", "discuss", "d-long", "repo_discussions" },
        .{ "patch", "patch", "p-long", "repo_patches" },
    }) |kind| {
        const id = b.real(kind[1], kind[2]);
        const c03 = b.real("comment", try run.p("{s}.c03", .{kind[2]}));
        const c12 = b.real("comment", try run.p("{s}.c12", .{kind[2]}));
        try run.page(try run.p("{s}.long", .{kind[0]}), &w.bob, try run.p(open ++ "/{s}:{s}", .{ kind[0], id }), kind[3]);
        try run.page(try run.p("{s}.long.second-window", .{kind[0]}), &w.bob, try run.p(open ++ "/{s}:{s}/start:10", .{ kind[0], id }), kind[3]);
        try run.page(try run.p("{s}.long.second-window-comment", .{kind[0]}), &w.bob, try run.p(open ++ "/{s}:{s}/comment:{s}/start:10", .{ kind[0], id, c03 }), kind[3]);
        try run.page(try run.p("{s}.long.permalink-beyond", .{kind[0]}), &w.bob, try run.p(open ++ "/{s}:{s}/comment:{s}", .{ kind[0], id, c12 }), kind[3]);
        try run.page(try run.p("{s}.long.permalink-beyond-window", .{kind[0]}), &w.bob, try run.p(open ++ "/{s}:{s}/comment:{s}/start:10", .{ kind[0], id, c12 }), kind[3]);
    }

    // ---- drafts logged out and by their author
    try run.page("drafts.anon", &w.anon, open ++ "/patches/drafts", "repo_patches");
    try run.page("drafts.bob", &w.bob, open ++ "/patches/drafts", "repo_patches");

    // ---- the user page's repo search and the home page's user search
    for ([_]struct { []const u8, []const u8 }{ .{ "pct", "tok%2541" }, .{ "plus", "tok%2Bplus" }, .{ "uni", "b%C3%A9" }, .{ "match", "op" } }) |search| {
        try run.page(try run.p("alice.search.{s}", .{search[0]}), &w.anon, try run.p("/alice/repos/search:{s}", .{search[1]}), "user_repos");
    }
    for ([_]struct { []const u8, []const u8 }{ .{ "pct", "tok%2541" }, .{ "plus", "b%2B" }, .{ "uni", "b%C3%A9" }, .{ "match", "bo" } }) |search| {
        try run.page(try run.p("users.search.{s}", .{search[0]}), &w.anon, try run.p("/home/users/search:{s}", .{search[1]}), "home_users");
    }
    try run.finish();
}

test "web: page snapshots of the local edges world" {
    const w = try world.Local(.git).buildMode(true);
    defer w.deinit();
    var run = Run.init("edges-local", &w.book);
    defer run.deinit();
    const b = &w.book;
    const oldest = b.real("issue", "conflict-01");
    try run.page("issues", &w.here, "/issues", "repo_issues");
    try run.page("conflicts", &w.here, "/issues/conflicts", "repo_issues");
    try run.page("conflicts.second-window", &w.here, try run.p("/issues/start:{s}/conflicts", .{b.real("issue", "conflict-02")}), "repo_issues");
    try run.page("conflict.oldest", &w.here, try run.p("/issue:{s}", .{oldest}), "repo_issues");
    try run.page("conflict.oldest-resolve", &w.here, try run.p("/issue:{s}/resolve", .{oldest}), "repo_issues");
    try run.page("conflict.oldest-searched", &w.here, try run.p("/issue:{s}/search:ours", .{oldest}), "repo_issues");
    try run.finish();
}
