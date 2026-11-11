//! comments and replies on issues and discussions: posting, editing, removing

const std = @import("std");
const h = @import("harness.zig");
const evt = @import("../../event.zig");

const no_thread = "/alice:open/issue:00000000000000000000000000000000";

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

fn newIssue(c: *h.Client, repo: []const u8, title: []const u8) ![]const u8 {
    return redirected(c, try path(c, "{s}/issues/new", .{repo}), &.{ .{ "title", title }, .{ "labels", "" }, .{ "description", "" } });
}

fn comment(c: *h.Client, parent: []const u8, body: []const u8) ![]const u8 {
    return redirected(c, try path(c, "{s}/new", .{parent}), &.{.{ "body", body }});
}

// the id after the url's last colon
fn lastId(url: []const u8) []const u8 {
    return url[std.mem.lastIndexOfScalar(u8, url, ':').? + 1 ..];
}

fn expectCommentCount(c: *h.Client, issue: []const u8, count: i64) !void {
    const page = try c.getJson(issue);
    defer page.deinit();
    try page.expectStatus(.ok);
    try page.expectJson("page.repo.issues.open.items.0.comments.count", count);
}

fn expectFirstBody(c: *h.Client, issue: []const u8, body: []const u8) !void {
    const page = try c.getJson(issue);
    defer page.deinit();
    try page.expectJson("page.repo.issues.open.items.0.comments.comments.0.comment.event.body", body);
}

// new comments

test "web: a comment leads to its permalink, which shows it to anyone" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const issue = try newIssue(&alice, "/alice:open", "the roof leaks");

    const r = try carol.post(try path(&carol, "{s}/new", .{issue}), &.{.{ "body", "me too\r\nsince monday" }});
    defer r.deinit();
    try r.expectStatus(.see_other);
    const location = r.header("location").?;
    try std.testing.expect(std.mem.startsWith(u8, location, try path(&carol, "{s}/comment:", .{issue})));
    try std.testing.expectEqual(issue.len + "/comment:".len + 32, location.len);

    const page = try carol.followJson(r);
    defer page.deinit();
    try page.expectStatus(.ok);
    try page.expectJson("page.repo.issues.comment_id", lastId(location));
    try page.expectJson("page.repo.issues.open.items.0.comments.count", 1);
    try page.expectJson("page.repo.issues.open.items.0.comments.comments.0.comment.event.body", "me too\nsince monday");
    try page.expectJson("page.repo.issues.open.items.0.comments.comments.0.author.user_name", "carol");
    try page.expectJson("page.repo.issues.open.items.0.comments.comments.0.parent_author", null);

    var visitor = server.client();
    defer visitor.deinit();
    try expectFirstBody(&visitor, issue, "me too\nsince monday");
}

test "web: a reply to a comment names the comment as its parent" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    const issue = try newIssue(&alice, "/alice:open", "question");
    const first = try comment(&alice, issue, "what do you think?");

    const r = try bob.post(try path(&bob, "{s}/new", .{first}), &.{.{ "body", "looks fine" }});
    defer r.deinit();
    try r.expectStatus(.see_other);
    // the reply's permalink hangs off the thread, not the parent
    try std.testing.expect(std.mem.startsWith(u8, r.header("location").?, try path(&bob, "{s}/comment:", .{issue})));
    try std.testing.expect(!std.mem.eql(u8, r.header("location").?, first));

    const page = try bob.followJson(r);
    defer page.deinit();
    try page.expectJson("page.repo.issues.open.items.0.comments.count", 2);
    try page.expectJson("page.repo.issues.open.items.0.comments.comments.1.comment.event.body", "looks fine");
    try page.expectJson("page.repo.issues.open.items.0.comments.comments.1.comment.event.parent_id", lastId(first));
    try page.expectJson("page.repo.issues.open.items.0.comments.comments.1.parent_author.user_name", "alice");
}

test "web: a comment on a discussion is shown on it" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    const discussion = try redirected(&bob, "/alice:open/discussions/new", &.{ .{ "title", "talk" }, .{ "labels", "" }, .{ "description", "" } });

    const r = try bob.post(try path(&bob, "{s}/new", .{discussion}), &.{.{ "body", "hello all" }});
    defer r.deinit();
    try r.expectStatus(.see_other);
    try std.testing.expect(std.mem.startsWith(u8, r.header("location").?, try path(&bob, "{s}/comment:", .{discussion})));
    const page = try bob.followJson(r);
    defer page.deinit();
    try page.expectJson("page.repo.discussions.recent.items.0.comments.comments.0.comment.event.body", "hello all");
}

test "web: an empty comment goes back to the comment form with no feedback, and nothing is posted" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "quiet");

    const r = try alice.post(try path(&alice, "{s}/new", .{issue}), &.{.{ "body", "" }});
    defer r.deinit();
    try r.expectRedirect(try path(&alice, "{s}/new", .{issue}));
    try std.testing.expectEqual(0, (try r.headerValues("set-cookie")).len);
    try expectCommentCount(&alice, issue, 0);
}

test "web: a comment on a thread or parent that does not exist is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "real");

    const no_parent = try alice.post(no_thread ++ "/new", &.{.{ "body", "anyone?" }});
    defer no_parent.deinit();
    const no_reply_parent = try alice.post(try path(&alice, "{s}/comment:00000000000000000000000000000000/new", .{issue}), &.{.{ "body", "anyone?" }});
    defer no_reply_parent.deinit();
    for ([_]*h.Response{ no_parent, no_reply_parent }) |r| {
        try r.expectStatus(.not_found);
        try std.testing.expectEqualStrings("comment parent not found", r.body);
    }
    try expectCommentCount(&alice, issue, 0);
}

test "web: an empty comment on a thread that does not exist is checked for its body first" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    // 66c1ab6 validated the body before looking for the thread
    const r = try alice.post(no_thread ++ "/new", &.{.{ "body", "" }});
    defer r.deinit();
    try r.expectRedirect(no_thread ++ "/new");
}

test "web: a comment url whose thread id is not an id has no target" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.post("/alice:open/issue:nothex/new", &.{.{ "body", "hi" }});
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("new event target not found", r.body);
}

test "web: a logged-out visitor or a removed account cannot comment, whatever the body" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "closed doors");

    var visitor = server.client();
    defer visitor.deinit();
    var dave = server.client();
    defer dave.deinit();
    try server.mintSession(&dave, server.dave);
    const new = try path(&alice, "{s}/new", .{issue});
    // an empty body would send anyone allowed back to the form
    const logged_out = try visitor.post(new, &.{.{ "body", "" }});
    defer logged_out.deinit();
    const removed = try dave.post(new, &.{.{ "body", "from beyond" }});
    defer removed.deinit();
    for ([_]*h.Response{ logged_out, removed }) |r| {
        try r.expectStatus(.forbidden);
        try std.testing.expectEqualStrings("log in to make changes", r.body);
    }
    try expectCommentCount(&alice, issue, 0);
}

test "web: a stranger commenting on a private repo's issue is told the repo does not exist, as for one that does not" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const issue = try newIssue(&alice, "/alice:secret", "private matters");

    const hidden = try carol.post(try path(&carol, "{s}/new", .{issue}), &.{.{ "body", "peek" }});
    defer hidden.deinit();
    const missing = try carol.post("/alice:nothing/issue:00000000000000000000000000000000/new", &.{.{ "body", "peek" }});
    defer missing.deinit();
    for ([_]*h.Response{ hidden, missing }) |r| {
        try r.expectStatus(.not_found);
        try std.testing.expectEqualStrings("repo not found", r.body);
    }
    try expectCommentCount(&alice, issue, 0);
}

test "web: a stranger cannot comment in a tab for members" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const issue = try newIssue(&alice, "/alice:open", "members only");
    {
        const r = try alice.post("/alice:open/repo/settings", &.{
            .{ "name", "open" },              .{ "description", "" },       .{ "access", "public" },
            .{ "discuss_role", "anybody" }, .{ "issue_role", "members" }, .{ "patch_role", "nobody" },
        });
        defer r.deinit();
        try r.expectRedirect("/alice:open/repo/settings");
    }

    const r = try carol.post(try path(&carol, "{s}/new", .{issue}), &.{.{ "body", "let me" }});
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("you don't have permission to do that", r.body);
    try expectCommentCount(&alice, issue, 0);
}

test "web: a comment on a sha256 repo is shown on its thread" {
    const server = try h.Server.init(.sha256);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "hashed");

    const first = try comment(&alice, issue, "noted");
    try std.testing.expect(std.mem.startsWith(u8, first, try path(&alice, "{s}/comment:", .{issue})));
    try expectFirstBody(&alice, issue, "noted");
}

// editing comments

test "web: a comment's author, a member with write and the owner may each edit it" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const issue = try newIssue(&alice, "/alice:open", "discuss");
    // carol holds only the read role a public repo gives anyone
    const carols = try comment(&carol, issue, "first draft");

    const edit = try path(&carol, "{s}/edit", .{carols});
    for ([_]struct { *h.Client, []const u8 }{ .{ &carol, "by carol" }, .{ &bob, "by bob" }, .{ &alice, "by alice\r\nindeed" } }) |turn| {
        const r = try turn[0].post(edit, &.{.{ "body", turn[1] }});
        defer r.deinit();
        try r.expectRedirect(carols);
    }
    try expectFirstBody(&carol, issue, "by alice\nindeed");
    const page = try carol.getJson(issue);
    defer page.deinit();
    // an edit keeps the comment's author
    try page.expectJson("page.repo.issues.open.items.0.comments.comments.0.author.user_name", "carol");
}

test "web: a stranger cannot edit someone else's comment, whatever the body" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const issue = try newIssue(&alice, "/alice:open", "mine");
    const alices = try comment(&alice, issue, "as written");

    const edit = try path(&carol, "{s}/edit", .{alices});
    // an empty body would send the author back to the form
    for ([_][]const u8{ "rewritten", "" }) |body| {
        const r = try carol.post(edit, &.{.{ "body", body }});
        defer r.deinit();
        try r.expectStatus(.forbidden);
        try std.testing.expectEqualStrings("you don't have permission to do that", r.body);
    }
    try expectFirstBody(&alice, issue, "as written");
}

test "web: a member with only the read role cannot edit someone else's comment" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    const erin_author: evt.CommitAuthor = .{ .name = "erin", .email = "erin@example.test" };
    const erin_id = try server.createUser(erin_author);
    try evt.grantRole(std.testing.io, std.testing.allocator, server.users_dir, &server.alice, &server.secret.repo_id, &erin_id, .read, h.Server.alice_author);
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var erin = try server.clientAs("erin");
    defer erin.deinit();
    const issue = try newIssue(&alice, "/alice:secret", "private");
    const alices = try comment(&alice, issue, "as written");

    const r = try erin.post(try path(&erin, "{s}/edit", .{alices}), &.{.{ "body", "erin's take" }});
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("you don't have permission to do that", r.body);
    try expectFirstBody(&alice, issue, "as written");

    // her own comment is hers to edit
    const erins = try comment(&erin, issue, "erin's");
    const own = try erin.post(try path(&erin, "{s}/edit", .{erins}), &.{.{ "body", "erin's, edited" }});
    defer own.deinit();
    try own.expectRedirect(erins);
}

test "web: an empty comment edit goes back to the edit form and keeps the comment" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "keep");
    const alices = try comment(&alice, issue, "keep me");

    const edit = try path(&alice, "{s}/edit", .{alices});
    const r = try alice.post(edit, &.{.{ "body", "" }});
    defer r.deinit();
    try r.expectRedirect(edit);
    try std.testing.expectEqual(0, (try r.headerValues("set-cookie")).len);
    try expectFirstBody(&alice, issue, "keep me");
}

test "web: editing a comment that does not exist is not found for the owner and forbidden for a stranger" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const issue = try newIssue(&alice, "/alice:open", "real");
    const edit = try path(&alice, "{s}/comment:00000000000000000000000000000000/edit", .{issue});

    const owner = try alice.post(edit, &.{.{ "body", "ghost" }});
    defer owner.deinit();
    try owner.expectStatus(.not_found);
    try std.testing.expectEqualStrings("comment not found", owner.body);

    const stranger = try carol.post(edit, &.{.{ "body", "ghost" }});
    defer stranger.deinit();
    try stranger.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("you don't have permission to do that", stranger.body);
}

test "web: a logged-out visitor cannot edit a comment" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "real");
    const alices = try comment(&alice, issue, "as written");

    var visitor = server.client();
    defer visitor.deinit();
    const r = try visitor.post(try path(&visitor, "{s}/edit", .{alices}), &.{.{ "body", "vandal" }});
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("log in to make changes", r.body);
    try expectFirstBody(&alice, issue, "as written");
}

// removing comments

test "web: removing a comment goes back to its thread, which shows it as removed" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const issue = try newIssue(&alice, "/alice:open", "busy");
    const carols = try comment(&carol, issue, "oops");

    const r = try carol.post(try path(&carol, "{s}/remove", .{carols}), &.{});
    defer r.deinit();
    try r.expectRedirect(issue);
    // the thread keeps its place, marked removed
    const page = try alice.getJson(issue);
    defer page.deinit();
    try page.expectJson("page.repo.issues.open.items.0.comments.comments.0.comment.removed", true);
}

test "web: a stranger cannot remove someone else's comment" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const issue = try newIssue(&alice, "/alice:open", "busy");
    const alices = try comment(&alice, issue, "stays");

    const r = try carol.post(try path(&carol, "{s}/remove", .{alices}), &.{});
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("you don't have permission to do that", r.body);
    try expectCommentCount(&alice, issue, 1);
}

test "web: removing a comment that does not exist is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "real");

    const r = try alice.post(try path(&alice, "{s}/comment:00000000000000000000000000000000/remove", .{issue}), &.{});
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("event not found", r.body);
}

// local mode

fn expectLocalComments(comptime kind: @import("xit").repo.RepoKind) !void {
    var local = try h.Local(kind).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();

    const issue = try newIssue(&browser, "", "local");
    const first = try comment(&browser, issue, "first");
    try std.testing.expect(std.mem.startsWith(u8, first, try path(&browser, "{s}/comment:", .{issue})));
    const reply = try comment(&browser, first, "reply");
    {
        const r = try browser.post(try path(&browser, "{s}/edit", .{first}), &.{.{ "body", "first, edited" }});
        defer r.deinit();
        try r.expectRedirect(first);
    }
    {
        const r = try browser.post(try path(&browser, "{s}/new", .{issue}), &.{.{ "body", "" }});
        defer r.deinit();
        try r.expectRedirect(try path(&browser, "{s}/new", .{issue}));
    }
    {
        const page = try browser.getJson(issue);
        defer page.deinit();
        try page.expectJson("page.repo.issues.open.items.0.comments.count", 2);
        try page.expectJson("page.repo.issues.open.items.0.comments.comments.0.comment.event.body", "first, edited");
        try page.expectJson("page.repo.issues.open.items.0.comments.comments.1.comment.event.parent_id", lastId(first));
        try page.expectJson("page.repo.issues.open.items.0.comments.comments.0.comment.author_email", "tester@example.test");
    }
    {
        const r = try browser.post(try path(&browser, "{s}/remove", .{reply}), &.{});
        defer r.deinit();
        try r.expectRedirect(issue);
    }
    const page = try browser.getJson(issue);
    defer page.deinit();
    try page.expectJson("page.repo.issues.open.items.0.comments.comments.0.comment.removed", false);
    try page.expectJson("page.repo.issues.open.items.0.comments.comments.1.comment.removed", true);
}

test "web: a local repo's comments can be posted, replied to, edited and removed" {
    try expectLocalComments(.git);
    try expectLocalComments(.xit);
}

test "web: a comment edit url whose comment id is not an id names no event" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "real");

    const r = try alice.post(try path(&alice, "{s}/comment:zz/edit", .{issue}), &.{.{ "body", "x" }});
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("event not found", r.body);
}

test "web: a logged-out visitor cannot remove a comment" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "busy");
    const alices = try comment(&alice, issue, "stays");

    var visitor = server.client();
    defer visitor.deinit();
    const r = try visitor.post(try path(&visitor, "{s}/remove", .{alices}), &.{});
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("log in to make changes", r.body);
    const page = try alice.getJson(issue);
    defer page.deinit();
    try page.expectJson("page.repo.issues.open.items.0.comments.comments.0.comment.removed", false);
}

test "web: a stranger removing a comment on a private repo is told the repo does not exist" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const issue = try newIssue(&alice, "/alice:secret", "hidden");
    const alices = try comment(&alice, issue, "stays");

    const r = try carol.post(try path(&carol, "{s}/remove", .{alices}), &.{});
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("repo not found", r.body);
    const page = try alice.getJson(issue);
    defer page.deinit();
    try page.expectJson("page.repo.issues.open.items.0.comments.comments.0.comment.removed", false);
}

fn expectLocalEmptyCommentEdit(comptime kind: @import("xit").repo.RepoKind) !void {
    var local = try h.Local(kind).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();
    const issue = try newIssue(&browser, "", "local");
    const first = try comment(&browser, issue, "keep me");

    const edit = try path(&browser, "{s}/edit", .{first});
    const r = try browser.post(edit, &.{.{ "body", "" }});
    defer r.deinit();
    try r.expectRedirect(edit);
    try std.testing.expectEqual(null, browser.cookie("haxy_local_flash"));
    try expectFirstBody(&browser, issue, "keep me");
}

test "web: an empty local comment edit goes back to the edit form and keeps the comment" {
    try expectLocalEmptyCommentEdit(.git);
    try expectLocalEmptyCommentEdit(.xit);
}
