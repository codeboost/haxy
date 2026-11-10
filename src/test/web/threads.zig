//! creating, editing, closing and removing issues and discussions, and the
//! search box over their lists

const std = @import("std");
const h = @import("harness.zig");

// post a form that must redirect, and give back where it leads
fn redirected(c: *h.Client, url: []const u8, fields: []const h.Field) ![]const u8 {
    const r = try c.post(url, fields);
    defer r.deinit();
    try r.expectStatus(.see_other);
    return try c.arena.allocator().dupe(u8, r.header("location").?);
}

fn path(c: *h.Client, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return try std.fmt.allocPrint(c.arena.allocator(), fmt, args);
}

// an issue alice opened on her public repo, through the form
fn aliceIssue(alice: *h.Client, title: []const u8) ![]const u8 {
    return redirected(alice, "/alice:open/issues/new", &.{ .{ "title", title }, .{ "labels", "" }, .{ "description", "" } });
}

// the open repo's tab roles, through the settings form
fn setTabRoles(alice: *h.Client, discuss: []const u8, issue: []const u8) !void {
    const r = try alice.post("/alice:open/repo/settings", &.{
        .{ "name", "open" },           .{ "description", "" },     .{ "access", "public" },
        .{ "discuss_role", discuss }, .{ "issue_role", issue }, .{ "patch_role", "nobody" },
    });
    defer r.deinit();
    try r.expectRedirect("/alice:open/repo/settings");
}

fn expectIssueCount(c: *h.Client, list: []const u8, open: i64, closed: i64) !void {
    const page = try c.getJson(list);
    defer page.deinit();
    try page.expectStatus(.ok);
    try page.expectJson("page.repo.issues.open.count", open);
    try page.expectJson("page.repo.issues.closed.count", closed);
}

// new threads

test "web: a new issue leads to its page, which shows its title, labels and description to anyone" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.post("/alice:open/issues/new", &.{
        .{ "title", "the roof leaks" }, .{ "labels", "bug roof" }, .{ "description", "drips\r\non the floor" },
    });
    defer r.deinit();
    try r.expectStatus(.see_other);
    const location = r.header("location").?;
    try std.testing.expect(std.mem.startsWith(u8, location, "/alice:open/issue:"));
    try std.testing.expectEqual("/alice:open/issue:".len + 32, location.len);
    try std.testing.expectEqualStrings("", r.body);

    const page = try alice.followJson(r);
    defer page.deinit();
    try page.expectStatus(.ok);
    try page.expectJson("page.repo.issues.open.count", 1);
    try page.expectJson("page.repo.issues.open.items.0.record.event.title", "the roof leaks");
    try page.expectJson("page.repo.issues.open.items.0.record.event.labels", "bug roof");
    // the browser's crlf line breaks are stored as plain newlines
    try page.expectJson("page.repo.issues.open.items.0.record.event.description", "drips\non the floor");
    try page.expectJson("page.repo.issues.open.items.0.record.event.status", "open");
    try page.expectJson("page.repo.issues.open.items.0.author.user_name", "alice");

    var visitor = server.client();
    defer visitor.deinit();
    const seen = try visitor.getJson(location);
    defer seen.deinit();
    try seen.expectStatus(.ok);
    try seen.expectJson("page.repo.issues.open.items.0.record.event.title", "the roof leaks");
}

test "web: a new discussion leads to its page and is listed among the recent ones" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    const r = try bob.post("/alice:open/discussions/new", &.{ .{ "title", "plans for spring" }, .{ "labels", "ideas" }, .{ "description", "what next" } });
    defer r.deinit();
    try r.expectStatus(.see_other);
    try std.testing.expect(std.mem.startsWith(u8, r.header("location").?, "/alice:open/discuss:"));

    const page = try bob.followJson(r);
    defer page.deinit();
    try page.expectStatus(.ok);
    try page.expectJson("page.repo.discussions.recent.items.0.record.event.title", "plans for spring");
    try page.expectJson("page.repo.discussions.recent.items.0.record.event.labels", "ideas");
    try page.expectJson("page.repo.discussions.recent.items.0.record.event.description", "what next");
    try page.expectJson("page.repo.discussions.recent.items.0.author.user_name", "bob");

    const list = try bob.getJson("/alice:open/discussions");
    defer list.deinit();
    try list.expectJson("page.repo.discussions.recent.count", 1);
}

test "web: an issue without a title comes back once with its labels and description retained, and nothing is created" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.post("/alice:open/issues/new", &.{ .{ "title", "   " }, .{ "labels", "bug" }, .{ "description", "no\r\ntitle" } });
    defer r.deinit();
    try r.expectRedirect("/alice:open/issues/new");
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectStatus(.ok);
    try form.expectJson("session.form_feedback.issue.failure", "required_title");
    try form.expectJson("session.form_feedback.issue.fields.title", "   ");
    try form.expectJson("session.form_feedback.issue.fields.labels", "bug");
    try form.expectJson("session.form_feedback.issue.fields.description", "no\ntitle");

    const again = try alice.getJson("/alice:open/issues/new");
    defer again.deinit();
    try again.expectJson("session.form_feedback", null);
    try expectIssueCount(&alice, "/alice:open/issues", 0, 0);
}

test "web: a discussion without a title comes back with its fields retained" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.post("/alice:open/discussions/new", &.{ .{ "title", "" }, .{ "labels", "x y" }, .{ "description", "words" } });
    defer r.deinit();
    try r.expectRedirect("/alice:open/discussions/new");
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.discussion.failure", "required_title");
    try form.expectJson("session.form_feedback.discussion.fields.title", "");
    try form.expectJson("session.form_feedback.discussion.fields.labels", "x y");
    try form.expectJson("session.form_feedback.discussion.fields.description", "words");

    const list = try alice.getJson("/alice:open/discussions");
    defer list.deinit();
    try list.expectJson("page.repo.discussions.recent.count", 0);
}

test "web: an issue with an overlong label goes back to the form with no feedback" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const long_label: [65]u8 = @splat('l');
    const r = try alice.post("/alice:open/issues/new", &.{ .{ "title", "fine" }, .{ "labels", "ok " ++ &long_label }, .{ "description", "" } });
    defer r.deinit();
    try r.expectRedirect("/alice:open/issues/new");
    try std.testing.expectEqual(0, (try r.headerValues("set-cookie")).len);
    try expectIssueCount(&alice, "/alice:open/issues", 0, 0);

    // 64 bytes is the longest label taken
    const label_64: [64]u8 = @splat('l');
    _ = try aliceIssue(&alice, "fine");
    const ok = try alice.post("/alice:open/issues/new", &.{ .{ "title", "fine too" }, .{ "labels", &label_64 }, .{ "description", "" } });
    defer ok.deinit();
    try ok.expectStatus(.see_other);
    try expectIssueCount(&alice, "/alice:open/issues", 2, 0);
}

test "web: a logged-out visitor cannot open an issue, whatever the form says" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    // an empty title would be a form failure for anyone allowed to post
    const r = try visitor.post("/alice:open/issues/new", &.{ .{ "title", "" }, .{ "labels", "" }, .{ "description", "" } });
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("log in to make changes", r.body);
    try std.testing.expectEqual(null, r.header("location"));

    try expectIssueCount(&visitor, "/alice:open/issues", 0, 0);
}

test "web: a removed account's old session cannot open an issue" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var dave = server.client();
    defer dave.deinit();
    try server.mintSession(&dave, server.dave);

    const r = try dave.post("/alice:open/issues/new", &.{ .{ "title", "from beyond" }, .{ "labels", "" }, .{ "description", "" } });
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("log in to make changes", r.body);

    var alice = try server.clientAs("alice");
    defer alice.deinit();
    try expectIssueCount(&alice, "/alice:open/issues", 0, 0);
}

test "web: a stranger posting to a private repo is told it does not exist, as for a repo that does not" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const secret = try carol.post("/alice:secret/issues/new", &.{ .{ "title", "hello" }, .{ "labels", "" }, .{ "description", "" } });
    defer secret.deinit();
    const missing = try carol.post("/alice:nothing/issues/new", &.{ .{ "title", "hello" }, .{ "labels", "" }, .{ "description", "" } });
    defer missing.deinit();
    for ([_]*h.Response{ secret, missing }) |r| {
        try r.expectStatus(.not_found);
        try std.testing.expectEqualStrings("repo not found", r.body);
    }

    var alice = try server.clientAs("alice");
    defer alice.deinit();
    try expectIssueCount(&alice, "/alice:secret/issues", 0, 0);
}

test "web: a tab that is off has no new thread form to post to" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    try setTabRoles(&alice, "nobody", "anybody");

    // even the owner finds the tab missing
    const r = try alice.post("/alice:open/discussions/new", &.{ .{ "title", "hello" }, .{ "labels", "" }, .{ "description", "" } });
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("repo not found", r.body);
}

test "web: a tab for members refuses a stranger and takes a member" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    try setTabRoles(&alice, "anybody", "members");

    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const refused = try carol.post("/alice:open/issues/new", &.{ .{ "title", "let me in" }, .{ "labels", "" }, .{ "description", "" } });
    defer refused.deinit();
    try refused.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("you don't have permission to do that", refused.body);
    try expectIssueCount(&alice, "/alice:open/issues", 0, 0);

    var bob = try server.clientAs("bob");
    defer bob.deinit();
    const taken = try bob.post("/alice:open/issues/new", &.{ .{ "title", "member's issue" }, .{ "labels", "" }, .{ "description", "" } });
    defer taken.deinit();
    try taken.expectStatus(.see_other);
    try expectIssueCount(&alice, "/alice:open/issues", 1, 0);
}

test "web: a new issue on a sha256 repo is shown on its page" {
    const server = try h.Server.init(.sha256);
    defer server.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    const r = try bob.post("/alice:secret/issues/new", &.{ .{ "title", "hashed" }, .{ "labels", "" }, .{ "description", "" } });
    defer r.deinit();
    try r.expectStatus(.see_other);
    try std.testing.expect(std.mem.startsWith(u8, r.header("location").?, "/alice:secret/issue:"));
    const page = try bob.followJson(r);
    defer page.deinit();
    try page.expectJson("page.repo.issues.open.items.0.record.event.title", "hashed");
}

// takes bob's role on the secret repo away through alice's members form
const RevokeBob = struct {
    alice: *h.Client,

    fn run(self: *RevokeBob) anyerror!void {
        const r = try self.alice.post("/alice:secret/repo/members/user:bob/revoke", &.{});
        defer r.deinit();
        try r.expectStatus(.see_other);
    }
};

test "web: a member whose role is taken away while the new issue's body is in flight is refused" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    var revoke: RevokeBob = .{ .alice = &alice };
    const r = try bob.postWith("/alice:secret/issues/new", &.{ .{ "title", "sneaking in" }, .{ "labels", "" }, .{ "description", "" } }, .{
        .between = .init(&revoke, RevokeBob.run),
    });
    defer r.deinit();
    try std.testing.expect(r.hook_ran);
    // differs from 66c1ab6: there the role was checked only before the body,
    // so the issue was written as bob (303 to it). the operation now
    // authorizes again after the body (docs/reviews/03-phase2-codex.md,
    // finding 2: "keep authorization inside the operation too"), and bob no
    // longer finds the repo.
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("repo not found", r.body);
    try expectIssueCount(&alice, "/alice:secret/issues", 0, 0);
}

// editing a thread

test "web: an issue's author, a member with write and the owner may each edit it" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    // carol holds only the read role a public repo gives anyone
    const issue = try redirected(&carol, "/alice:open/issues/new", &.{ .{ "title", "carol's" }, .{ "labels", "" }, .{ "description", "" } });
    const edit = try path(&carol, "{s}/edit", .{issue});
    for ([_]struct { *h.Client, []const u8 }{ .{ &carol, "by carol" }, .{ &bob, "by bob" }, .{ &alice, "by alice" } }) |turn| {
        const r = try turn[0].post(edit, &.{ .{ "title", turn[1] }, .{ "labels", "edited" }, .{ "description", "new\r\nwords" } });
        defer r.deinit();
        try r.expectRedirect(issue);
        const page = try carol.getJson(issue);
        defer page.deinit();
        try page.expectJson("page.repo.issues.open.items.0.record.event.title", turn[1]);
        try page.expectJson("page.repo.issues.open.items.0.record.event.labels", "edited");
        try page.expectJson("page.repo.issues.open.items.0.record.event.description", "new\nwords");
    }
}

test "web: a stranger cannot edit someone else's issue, and it stays as it was" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const issue = try aliceIssue(&alice, "alice's");
    const r = try carol.post(try path(&carol, "{s}/edit", .{issue}), &.{ .{ "title", "carol was here" }, .{ "labels", "" }, .{ "description", "" } });
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("you don't have permission to do that", r.body);

    const page = try alice.getJson(issue);
    defer page.deinit();
    try page.expectJson("page.repo.issues.open.items.0.record.event.title", "alice's");
}

test "web: a stranger's untitled edit of someone else's issue is checked for its title first" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const issue = try aliceIssue(&alice, "alice's");
    const edit = try path(&carol, "{s}/edit", .{issue});
    // 66c1ab6 read and validated the fields before asking who wrote the issue
    const r = try carol.post(edit, &.{ .{ "title", "" }, .{ "labels", "x" }, .{ "description", "y" } });
    defer r.deinit();
    try r.expectRedirect(edit);
    const form = try carol.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.issue.failure", "required_title");
    try form.expectJson("session.form_feedback.issue.fields.labels", "x");
}

test "web: an untitled issue edit comes back with its fields retained and the issue unchanged" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const issue = try aliceIssue(&alice, "keep me");
    const edit = try path(&alice, "{s}/edit", .{issue});
    const r = try alice.post(edit, &.{ .{ "title", "" }, .{ "labels", "a b" }, .{ "description", "c\r\nd" } });
    defer r.deinit();
    try r.expectRedirect(edit);
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.issue.failure", "required_title");
    try form.expectJson("session.form_feedback.issue.fields.title", "");
    try form.expectJson("session.form_feedback.issue.fields.labels", "a b");
    try form.expectJson("session.form_feedback.issue.fields.description", "c\nd");

    const page = try alice.getJson(issue);
    defer page.deinit();
    try page.expectJson("page.repo.issues.open.items.0.record.event.title", "keep me");
}

test "web: an untitled discussion edit comes back with discussion feedback" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const discussion = try redirected(&alice, "/alice:open/discussions/new", &.{ .{ "title", "talk" }, .{ "labels", "" }, .{ "description", "" } });
    const edit = try path(&alice, "{s}/edit", .{discussion});
    const r = try alice.post(edit, &.{ .{ "title", "" }, .{ "labels", "" }, .{ "description", "gone" } });
    defer r.deinit();
    try r.expectRedirect(edit);
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.discussion.failure", "required_title");
    try form.expectJson("session.form_feedback.discussion.fields.description", "gone");

    const ok = try alice.post(edit, &.{ .{ "title", "talk more" }, .{ "labels", "" }, .{ "description", "" } });
    defer ok.deinit();
    try ok.expectRedirect(discussion);
    const page = try alice.getJson(discussion);
    defer page.deinit();
    try page.expectJson("page.repo.discussions.recent.items.0.record.event.title", "talk more");
}

test "web: an issue edit with an overlong label goes back to the form with no feedback" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const issue = try aliceIssue(&alice, "labelled");
    const edit = try path(&alice, "{s}/edit", .{issue});
    const long_label: [65]u8 = @splat('l');
    const r = try alice.post(edit, &.{ .{ "title", "labelled" }, .{ "labels", &long_label }, .{ "description", "" } });
    defer r.deinit();
    try r.expectRedirect(edit);
    try std.testing.expectEqual(0, (try r.headerValues("set-cookie")).len);
}

test "web: editing an issue that does not exist is not found for the owner and forbidden for a stranger" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const edit = "/alice:open/issue:00000000000000000000000000000000/edit";
    const fields: []const h.Field = &.{ .{ "title", "ghost" }, .{ "labels", "" }, .{ "description", "" } };
    const owner = try alice.post(edit, fields);
    defer owner.deinit();
    try owner.expectStatus(.not_found);
    try std.testing.expectEqualStrings("issue not found", owner.body);

    // a stranger may change only what they wrote, and wrote nothing here
    const stranger = try carol.post(edit, fields);
    defer stranger.deinit();
    try stranger.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("you don't have permission to do that", stranger.body);
}

test "web: an edit url whose id is not an id names no event" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.post("/alice:open/issue:nothex/edit", &.{ .{ "title", "x" }, .{ "labels", "" }, .{ "description", "" } });
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("event not found", r.body);
}

test "web: a logged-out visitor cannot edit an issue" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try aliceIssue(&alice, "mine");

    var visitor = server.client();
    defer visitor.deinit();
    const r = try visitor.post(try path(&visitor, "{s}/edit", .{issue}), &.{ .{ "title", "" }, .{ "labels", "" }, .{ "description", "" } });
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("log in to make changes", r.body);
}

// status

test "web: closing an issue moves it out of the open list, and opening brings it back" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const issue = try aliceIssue(&alice, "fix me");
    _ = try aliceIssue(&alice, "still open");
    try expectIssueCount(&alice, "/alice:open/issues", 2, 0);

    const closed = try alice.post(try path(&alice, "{s}/close", .{issue}), &.{});
    defer closed.deinit();
    try closed.expectRedirect(issue);
    const page = try alice.followJson(closed);
    defer page.deinit();
    try page.expectJson("page.repo.issues.view", "closed");
    try page.expectJson("page.repo.issues.closed.items.0.record.event.title", "fix me");
    try page.expectJson("page.repo.issues.closed.items.0.record.event.status", "closed");

    const list = try alice.getJson("/alice:open/issues");
    defer list.deinit();
    try list.expectJson("page.repo.issues.open.count", 1);
    try list.expectJson("page.repo.issues.open.items.0.record.event.title", "still open");
    const closed_list = try alice.getJson("/alice:open/issues/closed");
    defer closed_list.deinit();
    try closed_list.expectJson("page.repo.issues.closed.count", 1);
    try closed_list.expectJson("page.repo.issues.closed.items.0.record.event.title", "fix me");

    const opened = try alice.post(try path(&alice, "{s}/open", .{issue}), &.{});
    defer opened.deinit();
    try opened.expectRedirect(issue);
    try expectIssueCount(&alice, "/alice:open/issues", 2, 0);
}

test "web: a stranger cannot close someone else's issue but may close their own" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const alices = try aliceIssue(&alice, "alice's");
    const refused = try carol.post(try path(&carol, "{s}/close", .{alices}), &.{});
    defer refused.deinit();
    try refused.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("you don't have permission to do that", refused.body);
    try expectIssueCount(&alice, "/alice:open/issues", 1, 0);

    const carols = try redirected(&carol, "/alice:open/issues/new", &.{ .{ "title", "carol's" }, .{ "labels", "" }, .{ "description", "" } });
    const taken = try carol.post(try path(&carol, "{s}/close", .{carols}), &.{});
    defer taken.deinit();
    try taken.expectRedirect(carols);
    try expectIssueCount(&alice, "/alice:open/issues", 1, 1);
}

test "web: closing an issue that does not exist is not found for the owner and forbidden for a stranger" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const close = "/alice:open/issue:00000000000000000000000000000000/close";
    const owner = try alice.post(close, &.{});
    defer owner.deinit();
    try owner.expectStatus(.not_found);
    try std.testing.expectEqualStrings("thread not found", owner.body);

    const stranger = try carol.post(close, &.{});
    defer stranger.deinit();
    try stranger.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("you don't have permission to do that", stranger.body);
}

test "web: a discussion has no status to close" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const discussion = try redirected(&alice, "/alice:open/discussions/new", &.{ .{ "title", "talk" }, .{ "labels", "" }, .{ "description", "" } });
    const r = try alice.post(try path(&alice, "{s}/close", .{discussion}), &.{});
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("event not found", r.body);
}

test "web: closing a thread url with a malformed id or on a private repo is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const malformed = try alice.post("/alice:open/issue:zz/close", &.{});
    defer malformed.deinit();
    try malformed.expectStatus(.not_found);
    try std.testing.expectEqualStrings("thread not found", malformed.body);

    const issue = try redirected(&alice, "/alice:secret/issues/new", &.{ .{ "title", "hidden" }, .{ "labels", "" }, .{ "description", "" } });
    const hidden = try carol.post(try path(&carol, "{s}/close", .{issue}), &.{});
    defer hidden.deinit();
    const missing = try carol.post("/alice:nothing/issue:00000000000000000000000000000000/close", &.{});
    defer missing.deinit();
    for ([_]*h.Response{ hidden, missing }) |r| {
        try r.expectStatus(.not_found);
        try std.testing.expectEqualStrings("repo not found", r.body);
    }
    try expectIssueCount(&alice, "/alice:secret/issues", 1, 0);
}

test "web: a logged-out visitor cannot close an issue" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try aliceIssue(&alice, "open still");

    var visitor = server.client();
    defer visitor.deinit();
    const r = try visitor.post(try path(&visitor, "{s}/close", .{issue}), &.{});
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("log in to make changes", r.body);
    try expectIssueCount(&alice, "/alice:open/issues", 1, 0);
}

// removal

test "web: removing an issue goes back to the list, which no longer has it" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const issue = try aliceIssue(&alice, "doomed");
    const r = try alice.post(try path(&alice, "{s}/remove", .{issue}), &.{});
    defer r.deinit();
    try r.expectRedirect("/alice:open/issues");
    try expectIssueCount(&alice, "/alice:open/issues", 0, 0);

    // its page is gone with it
    const gone = try alice.getJson(issue);
    defer gone.deinit();
    try gone.expectStatus(.not_found);
}

test "web: removing a discussion goes back to the discussions list" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    const discussion = try redirected(&bob, "/alice:open/discussions/new", &.{ .{ "title", "short lived" }, .{ "labels", "" }, .{ "description", "" } });
    const r = try bob.post(try path(&bob, "{s}/remove", .{discussion}), &.{});
    defer r.deinit();
    try r.expectRedirect("/alice:open/discussions");
    const list = try bob.getJson("/alice:open/discussions");
    defer list.deinit();
    try list.expectJson("page.repo.discussions.recent.count", 0);
}

test "web: a stranger cannot remove someone else's issue" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const issue = try aliceIssue(&alice, "stays");
    const r = try carol.post(try path(&carol, "{s}/remove", .{issue}), &.{});
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("you don't have permission to do that", r.body);
    try expectIssueCount(&alice, "/alice:open/issues", 1, 0);
}

test "web: removing an issue that does not exist is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.post("/alice:open/issue:00000000000000000000000000000000/remove", &.{});
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("event not found", r.body);
}

test "web: a logged-out visitor cannot remove an issue" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try aliceIssue(&alice, "stays");

    var visitor = server.client();
    defer visitor.deinit();
    const r = try visitor.post(try path(&visitor, "{s}/remove", .{issue}), &.{});
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("log in to make changes", r.body);
    try expectIssueCount(&alice, "/alice:open/issues", 1, 0);
}

// search

test "web: searching issues leads to the open list filtered by the text" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    _ = try aliceIssue(&alice, "the roof leaks");
    _ = try aliceIssue(&alice, "the door squeaks");

    const r = try alice.post("/alice:open/issues/search", &.{.{ "search", "roof leaks" }});
    defer r.deinit();
    try r.expectRedirect("/alice:open/issues/open/search:roof%20leaks");
    const page = try alice.followJson(r);
    defer page.deinit();
    try page.expectJson("page.repo.issues.search", "roof leaks");
    try page.expectJson("page.repo.issues.open.count", 1);
    try page.expectJson("page.repo.issues.open.items.0.record.event.title", "the roof leaks");
}

test "web: an empty search of a discussions list leads back to the plain list" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    // searching needs no account
    const r = try visitor.post("/alice:open/discussions/search", &.{.{ "search", "" }});
    defer r.deinit();
    try r.expectRedirect("/alice:open/discussions/recent");
}

test "web: searching from a page with no list to search is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    const unknown = try visitor.post("/alice:open/no/such/page/search", &.{.{ "search", "x" }});
    defer unknown.deinit();
    try unknown.expectStatus(.not_found);
    try std.testing.expectEqualStrings("not found", unknown.body);

    const settings = try visitor.post("/alice:open/repo/delete/search", &.{.{ "search", "x" }});
    defer settings.deinit();
    try settings.expectStatus(.not_found);
    try std.testing.expectEqualStrings("not found", settings.body);
}

// the urls of the other host kind

test "web: a server asked for a local thread url finds no repo" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.post("/issues/new", &.{ .{ "title", "where" }, .{ "labels", "" }, .{ "description", "" } });
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("repo not found", r.body);
}

test "web: a logged-out visitor posting a local thread url to a server is told to log in" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    // 66c1ab6 asked for a login before looking at which repo the url names
    for ([_][]const u8{ "/issues/new", "/discussions/new", "/patches/new" }) |url| {
        const r = try visitor.post(url, &.{ .{ "title", "where" }, .{ "labels", "" }, .{ "description", "" }, .{ "target_branch", "master" } });
        defer r.deinit();
        try r.expectStatus(.forbidden);
        try std.testing.expectEqualStrings("log in to make changes", r.body);
    }
}

test "web: a logged-out upload to a thread url that names no repo is told to log in" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    // 66c1ab6 asked for a login before looking at the repo or the target's kind
    const targets = [_][]const u8{ "/issue:00000000000000000000000000000000/attach", "/alice:open/issue:00000000000000000000000000000000/comment:00000000000000000000000000000000/attach" };
    for (targets) |url| {
        const r = try visitor.send(.{ .method = "POST", .path = url, .body = "bytes", .headers = &.{
            .{ .name = "content-type", .value = "application/octet-stream" },
            .{ .name = "x-attachment-name", .value = "a.txt" },
        } });
        defer r.deinit();
        try r.expectStatus(.forbidden);
        try std.testing.expectEqualStrings("log in to make changes", r.body);
    }
}

test "web: a local host asked for a server thread url finds no repo" {
    var local = try h.Local(.xit).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();

    const r = try browser.post("/alice:open/issues/new", &.{ .{ "title", "where" }, .{ "labels", "" }, .{ "description", "" } });
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("repo not found", r.body);
}

test "web: a local host finds no repo for an untitled server thread url either" {
    var local = try h.Local(.xit).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();

    const r = try browser.post("/alice:open/issues/new", &.{ .{ "title", "" }, .{ "labels", "" }, .{ "description", "" } });
    defer r.deinit();
    // differs from 66c1ab6: there the fields were validated before the url's
    // repo was resolved, so this answered 303 to "/alice:open/issues/new" with
    // the haxy_local_flash cookie "required_title:issue". accepted as D4: a
    // local host answers 404 "repo not found" to a server-style url whatever
    // the body says.
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("repo not found", r.body);
    try std.testing.expectEqual(null, browser.cookie("haxy_local_flash"));
}

test "web: a local host has no account routes to post to" {
    var local = try h.Local(.git).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();

    const r = try browser.post("/issue:00000000000000000000000000000000/subscribe", &.{});
    defer r.deinit();
    try r.expectStatus(.method_not_allowed);
    try std.testing.expectEqualStrings("method not allowed", r.body);
}

// local mode

fn expectLocalThreadLife(comptime kind: @import("xit").repo.RepoKind) !void {
    var local = try h.Local(kind).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();

    const discussion = try redirected(&browser, "/discussions/new", &.{ .{ "title", "local talk" }, .{ "labels", "here" }, .{ "description", "a\r\nb" } });
    try std.testing.expect(std.mem.startsWith(u8, discussion, "/discuss:"));
    {
        const page = try browser.getJson(discussion);
        defer page.deinit();
        try page.expectJson("page.repo.discussions.recent.items.0.record.event.title", "local talk");
        try page.expectJson("page.repo.discussions.recent.items.0.record.event.description", "a\nb");
        // local events are written as the repo's committer
        try page.expectJson("page.repo.discussions.recent.items.0.record.author_email", "tester@example.test");
    }

    const issue = try redirected(&browser, "/issues/new", &.{ .{ "title", "local bug" }, .{ "labels", "" }, .{ "description", "" } });
    try std.testing.expect(std.mem.startsWith(u8, issue, "/issue:"));
    const edit = try path(&browser, "{s}/edit", .{issue});
    {
        const r = try browser.post(edit, &.{ .{ "title", "local bug, renamed" }, .{ "labels", "x" }, .{ "description", "" } });
        defer r.deinit();
        try r.expectRedirect(issue);
    }
    {
        const r = try browser.post(edit, &.{ .{ "title", "" }, .{ "labels", "x" }, .{ "description", "" } });
        defer r.deinit();
        try r.expectRedirect(edit);
        try std.testing.expectEqualStrings("required_title:issue", browser.cookie("haxy_local_flash") orelse "(none)");
        const form = try browser.followJson(r);
        defer form.deinit();
        try form.expectJson("session.form_feedback.issue.failure", "required_title");
    }
    {
        const r = try browser.post(try path(&browser, "{s}/close", .{issue}), &.{});
        defer r.deinit();
        try r.expectRedirect(issue);
        const page = try browser.followJson(r);
        defer page.deinit();
        try page.expectJson("page.repo.issues.closed.items.0.record.event.title", "local bug, renamed");
        try page.expectJson("page.repo.issues.open.count", 0);
    }
    {
        const r = try browser.post(try path(&browser, "{s}/remove", .{issue}), &.{});
        defer r.deinit();
        try r.expectRedirect("/issues");
        const list = try browser.getJson("/issues/closed");
        defer list.deinit();
        try list.expectJson("page.repo.issues.closed.count", 0);
    }
    {
        const r = try browser.post("/issues/search", &.{.{ "search", "bug" }});
        defer r.deinit();
        try r.expectRedirect("/issues/open/search:bug");
    }
}

test "web: a local repo's threads can be opened, edited, closed, removed and searched" {
    try expectLocalThreadLife(.git);
    try expectLocalThreadLife(.xit);
}

// reopening

test "web: a logged-out visitor cannot reopen an issue" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try aliceIssue(&alice, "shut");
    {
        const r = try alice.post(try path(&alice, "{s}/close", .{issue}), &.{});
        defer r.deinit();
        try r.expectRedirect(issue);
    }

    var visitor = server.client();
    defer visitor.deinit();
    const r = try visitor.post(try path(&visitor, "{s}/open", .{issue}), &.{});
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("log in to make changes", r.body);
    try expectIssueCount(&alice, "/alice:open/issues", 0, 1);
}

test "web: a stranger cannot reopen someone else's issue" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const issue = try aliceIssue(&alice, "shut");
    {
        const r = try alice.post(try path(&alice, "{s}/close", .{issue}), &.{});
        defer r.deinit();
        try r.expectRedirect(issue);
    }

    const r = try carol.post(try path(&carol, "{s}/open", .{issue}), &.{});
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("you don't have permission to do that", r.body);
    try expectIssueCount(&alice, "/alice:open/issues", 0, 1);
}

test "web: reopening on a private repo, a missing issue or a malformed id is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const hidden = try redirected(&alice, "/alice:secret/issues/new", &.{ .{ "title", "hidden" }, .{ "labels", "" }, .{ "description", "" } });

    const private = try carol.post(try path(&carol, "{s}/open", .{hidden}), &.{});
    defer private.deinit();
    const no_repo = try carol.post("/alice:nothing/issue:00000000000000000000000000000000/open", &.{});
    defer no_repo.deinit();
    for ([_]*h.Response{ private, no_repo }) |r| {
        try r.expectStatus(.not_found);
        try std.testing.expectEqualStrings("repo not found", r.body);
    }

    const missing = try alice.post("/alice:open/issue:00000000000000000000000000000000/open", &.{});
    defer missing.deinit();
    const malformed = try alice.post("/alice:open/issue:zz/open", &.{});
    defer malformed.deinit();
    for ([_]*h.Response{ missing, malformed }) |r| {
        try r.expectStatus(.not_found);
        try std.testing.expectEqualStrings("thread not found", r.body);
    }

    // a stranger may change only what they wrote, and wrote nothing here
    const stranger = try carol.post("/alice:open/issue:00000000000000000000000000000000/open", &.{});
    defer stranger.deinit();
    try stranger.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("you don't have permission to do that", stranger.body);
}

fn expectLocalReopen(comptime kind: @import("xit").repo.RepoKind) !void {
    var local = try h.Local(kind).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();
    const issue = try redirected(&browser, "/issues/new", &.{ .{ "title", "again" }, .{ "labels", "" }, .{ "description", "" } });
    {
        const r = try browser.post(try path(&browser, "{s}/close", .{issue}), &.{});
        defer r.deinit();
        try r.expectRedirect(issue);
    }
    const r = try browser.post(try path(&browser, "{s}/open", .{issue}), &.{});
    defer r.deinit();
    try r.expectRedirect(issue);
    const page = try browser.followJson(r);
    defer page.deinit();
    try page.expectJson("page.repo.issues.open.items.0.record.event.status", "open");
    try page.expectJson("page.repo.issues.closed.count", 0);
}

test "web: a local repo's closed issue can be reopened" {
    try expectLocalReopen(.git);
    try expectLocalReopen(.xit);
}

// discussions

test "web: a logged-out visitor cannot start a discussion, whatever the form says" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    const r = try visitor.post("/alice:open/discussions/new", &.{ .{ "title", "" }, .{ "labels", "" }, .{ "description", "" } });
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("log in to make changes", r.body);
    const list = try visitor.getJson("/alice:open/discussions");
    defer list.deinit();
    try list.expectJson("page.repo.discussions.recent.count", 0);
}

test "web: a discussions tab for members refuses a stranger" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    try setTabRoles(&alice, "members", "anybody");
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const r = try carol.post("/alice:open/discussions/new", &.{ .{ "title", "let me talk" }, .{ "labels", "" }, .{ "description", "" } });
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("you don't have permission to do that", r.body);
    const list = try alice.getJson("/alice:open/discussions");
    defer list.deinit();
    try list.expectJson("page.repo.discussions.recent.count", 0);
}

test "web: a stranger starting a discussion on a private repo is told it does not exist" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const r = try carol.post("/alice:secret/discussions/new", &.{ .{ "title", "hello" }, .{ "labels", "" }, .{ "description", "" } });
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("repo not found", r.body);
}

test "web: a stranger editing an issue on a private repo is told it does not exist" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const issue = try redirected(&alice, "/alice:secret/issues/new", &.{ .{ "title", "hidden" }, .{ "labels", "" }, .{ "description", "" } });

    const r = try carol.post(try path(&carol, "{s}/edit", .{issue}), &.{ .{ "title", "seen" }, .{ "labels", "" }, .{ "description", "" } });
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("repo not found", r.body);
    const page = try alice.getJson(issue);
    defer page.deinit();
    try page.expectJson("page.repo.issues.open.items.0.record.event.title", "hidden");
}

// removal refusals

test "web: a logged-out visitor cannot remove a discussion" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const discussion = try redirected(&alice, "/alice:open/discussions/new", &.{ .{ "title", "stays" }, .{ "labels", "" }, .{ "description", "" } });

    var visitor = server.client();
    defer visitor.deinit();
    const r = try visitor.post(try path(&visitor, "{s}/remove", .{discussion}), &.{});
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("log in to make changes", r.body);
    const list = try alice.getJson("/alice:open/discussions");
    defer list.deinit();
    try list.expectJson("page.repo.discussions.recent.count", 1);
}

test "web: a stranger removing a discussion on a private repo is told it does not exist" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const discussion = try redirected(&alice, "/alice:secret/discussions/new", &.{ .{ "title", "hidden" }, .{ "labels", "" }, .{ "description", "" } });

    const r = try carol.post(try path(&carol, "{s}/remove", .{discussion}), &.{});
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("repo not found", r.body);
    const list = try alice.getJson("/alice:secret/discussions");
    defer list.deinit();
    try list.expectJson("page.repo.discussions.recent.count", 1);
}

test "web: removing a thread or comment with a malformed id names no event" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try aliceIssue(&alice, "real");

    const thread = try alice.post("/alice:open/issue:zz/remove", &.{});
    defer thread.deinit();
    const discussion = try alice.post("/alice:open/discuss:zz/remove", &.{});
    defer discussion.deinit();
    const comment = try alice.post(try path(&alice, "{s}/comment:zz/remove", .{issue}), &.{});
    defer comment.deinit();
    for ([_]*h.Response{ thread, discussion, comment }) |r| {
        try r.expectStatus(.not_found);
        try std.testing.expectEqualStrings("event not found", r.body);
    }
    try expectIssueCount(&alice, "/alice:open/issues", 1, 0);
}

// more searching

test "web: a stranger searching a private repo's issues is sent to a list that is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    _ = try redirected(&alice, "/alice:secret/issues/new", &.{ .{ "title", "hidden roof" }, .{ "labels", "" }, .{ "description", "" } });
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    // the search form only builds a url; the list it leads to checks access
    const r = try carol.post("/alice:secret/issues/search", &.{.{ "search", "roof" }});
    defer r.deinit();
    try r.expectRedirect("/alice:secret/issues/open/search:roof");
    const page = try carol.followJson(r);
    defer page.deinit();
    try page.expectStatus(.not_found);
    try page.expectBodyLacks("hidden roof");
}

test "web: a search text is percent-encoded into the list's url and decoded on its page" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    _ = try aliceIssue(&alice, "about a/b c% things");
    _ = try aliceIssue(&alice, "unrelated");

    const r = try alice.post("/alice:open/issues/search", &.{.{ "search", "a/b c%" }});
    defer r.deinit();
    try r.expectRedirect("/alice:open/issues/open/search:a%2Fb%20c%25");
    const page = try alice.followJson(r);
    defer page.deinit();
    try page.expectJson("page.repo.issues.search", "a/b c%");
}

fn expectLocalSearchFilters(comptime kind: @import("xit").repo.RepoKind) !void {
    var local = try h.Local(kind).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();
    _ = try redirected(&browser, "/issues/new", &.{ .{ "title", "the roof leaks" }, .{ "labels", "" }, .{ "description", "" } });
    _ = try redirected(&browser, "/issues/new", &.{ .{ "title", "the door squeaks" }, .{ "labels", "" }, .{ "description", "" } });

    const r = try browser.post("/issues/search", &.{.{ "search", "roof" }});
    defer r.deinit();
    try r.expectRedirect("/issues/open/search:roof");
    const page = try browser.followJson(r);
    defer page.deinit();
    try page.expectJson("page.repo.issues.search", "roof");
    try page.expectJson("page.repo.issues.open.count", 1);
    try page.expectJson("page.repo.issues.open.items.0.record.event.title", "the roof leaks");
}

test "web: a local search leads to a list filtered by the text" {
    try expectLocalSearchFilters(.git);
    try expectLocalSearchFilters(.xit);
}

// local discussions

fn expectLocalDiscussionForms(comptime kind: @import("xit").repo.RepoKind) !void {
    var local = try h.Local(kind).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();
    {
        const r = try browser.post("/discussions/new", &.{ .{ "title", "" }, .{ "labels", "" }, .{ "description", "untitled" } });
        defer r.deinit();
        try r.expectRedirect("/discussions/new");
        try std.testing.expectEqualStrings("required_title:discussion", browser.cookie("haxy_local_flash") orelse "(none)");
        const form = try browser.followJson(r);
        defer form.deinit();
        try form.expectJson("session.form_feedback.discussion.failure", "required_title");
    }
    const discussion = try redirected(&browser, "/discussions/new", &.{ .{ "title", "talk" }, .{ "labels", "" }, .{ "description", "" } });
    {
        const r = try browser.post(try path(&browser, "{s}/edit", .{discussion}), &.{ .{ "title", "talk, renamed" }, .{ "labels", "" }, .{ "description", "" } });
        defer r.deinit();
        try r.expectRedirect(discussion);
        const page = try browser.followJson(r);
        defer page.deinit();
        try page.expectJson("page.repo.discussions.recent.items.0.record.event.title", "talk, renamed");
    }
    {
        const r = try browser.post(try path(&browser, "{s}/remove", .{discussion}), &.{});
        defer r.deinit();
        try r.expectRedirect("/discussions");
        const list = try browser.getJson("/discussions");
        defer list.deinit();
        try list.expectJson("page.repo.discussions.recent.count", 0);
    }
}

test "web: a local repo's discussions refuse no title, and can be edited and removed" {
    try expectLocalDiscussionForms(.git);
    try expectLocalDiscussionForms(.xit);
}
