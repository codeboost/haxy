//! the delete tabs: a repo, a fork draft and the account itself

const std = @import("std");
const h = @import("harness.zig");

const evt = @import("../../event.zig");

const gpa = std.testing.allocator;

fn expectRefused(r: *const h.Response, status: std.http.Status, text: []const u8) !void {
    try r.expectStatus(status);
    if (std.mem.eql(u8, r.body, text)) return;
    r.describe();
    std.debug.print("expected the body \"{s}\"\n", .{text});
    return error.TestExpectedEqual;
}

// `r` is a page that loaded, whose array at `path` holds `len` items
fn expectArrayLen(r: *const h.Response, path: []const u8, len: usize) !void {
    try r.expectStatus(.ok);
    if (r.jsonAt(path)) |value| if (value == .array and value.array.items.len == len) return;
    r.describe();
    std.debug.print("expected an array of {d} at \"{s}\"\n", .{ len, path });
    return error.TestExpectedEqual;
}

// neither a header nor the body carries `secret`
fn expectNoSecret(r: *const h.Response, secret: []const u8) !void {
    for (r.headers) |header| if (std.mem.indexOf(u8, header.value, secret) != null) {
        r.describe();
        std.debug.print("a header carries \"{s}\"\n", .{secret});
        return error.TestUnexpectedText;
    };
    try r.expectBodyLacks(secret);
}

fn expectPage(c: *h.Client, path: []const u8, status: std.http.Status) !void {
    const r = try c.getJson(path);
    defer r.deinit();
    try r.expectStatus(status);
}

fn postDelete(c: *h.Client, tab: []const u8, confirm: []const u8, pass: []const u8) !*h.Response {
    var buf: [256]u8 = undefined;
    return c.post(try std.fmt.bufPrint(&buf, "{s}/delete", .{tab}), &.{ .{ "confirm", confirm }, .{ "password", pass } });
}

// a failed delete goes back to its tab naming the failure and the target kind,
// keeping the confirmation
fn expectDeleteFailure(c: *h.Client, r: *const h.Response, tab: []const u8, failure: []const u8, target: []const u8, confirm: []const u8) !void {
    try r.expectRedirect(tab);
    const form = try c.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.delete.failure", failure);
    try form.expectJson("session.form_feedback.delete.target", target);
    try form.expectJson("session.form_feedback.delete.confirm", confirm);
}

// changes a user's password to "changed" through the settings form with
// another browser logged in as them
const ChangePassword = struct {
    browser: *h.Client,
    email: []const u8,

    fn run(self: *ChangePassword) anyerror!void {
        const r = try self.browser.post("/home/user/settings/user", &.{
            .{ "email", self.email },
            .{ "current_password", h.password },
            .{ "new_password", "changed" },
            .{ "new_password_again", "changed" },
        });
        defer r.deinit();
        try r.expectRedirect("/home/user/settings");
    }
};

// ---- deleting a repo

test "web: the creator deletes a repo, which is then gone for everyone" {
    try expectRepoDeleted(.sha1);
}

test "web: the creator deletes a sha256 repo" {
    try expectRepoDeleted(.sha256);
}

fn expectRepoDeleted(comptime hash_kind: @import("xit").hash.HashKind) !void {
    const server = try h.Server.init(hash_kind);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    const r = try postDelete(&alice, "/alice:open/repo/delete", "alice:open", h.password);
    defer r.deinit();
    try r.expectRedirect("/alice");
    const page = try alice.followJson(r);
    defer page.deinit();
    try expectArrayLen(page, "page.user.repos", 1);
    try page.expectJson("page.user.repos.0.event.name", "secret");

    try expectPage(&alice, "/alice:open", .not_found);
    try expectPage(&bob, "/alice:open", .not_found);
    // the other repo stays
    try expectPage(&bob, "/alice:secret", .ok);
}

test "web: another owner of a repo finds nothing to delete" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    try evt.grantRole(std.testing.io, gpa, server.users_dir, &server.alice, &server.open.repo_id, &server.bob, .owner, h.Server.alice_author);
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    const r = try postDelete(&bob, "/alice:open/repo/delete", "alice:open", h.password);
    defer r.deinit();
    try expectRefused(r, .not_found, "nothing to delete");
    try expectPage(&bob, "/alice:open", .ok);
}

test "web: a member and a stranger find nothing to delete" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    for ([_][]const u8{ "bob", "carol" }) |name| {
        var c = try server.clientAs(name);
        defer c.deinit();
        const r = try postDelete(&c, "/alice:open/repo/delete", "alice:open", h.password);
        defer r.deinit();
        try expectRefused(r, .not_found, "nothing to delete");
    }
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    try expectPage(&alice, "/alice:open", .ok);
}

test "web: a stranger deleting a private repo gets the answer for a repo that does not exist" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const secret = try postDelete(&carol, "/alice:secret/repo/delete", "alice:secret", h.password);
    defer secret.deinit();
    const missing = try postDelete(&carol, "/alice:nothing/repo/delete", "alice:nothing", h.password);
    defer missing.deinit();
    try expectRefused(secret, .not_found, "nothing to delete");
    try expectRefused(missing, .not_found, "nothing to delete");
    try std.testing.expectEqualStrings(missing.header("content-type").?, secret.header("content-type").?);
}

test "web: a wrong confirmation comes back as such, whatever the password" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    // the confirmation is checked before the password
    for ([_][]const u8{ h.password, "Wrong-Pass-81" }) |pass| {
        const r = try postDelete(&alice, "/alice:open/repo/delete", "alice:opne", pass);
        defer r.deinit();
        try expectNoSecret(r, "Wrong-Pass-81");
        try expectDeleteFailure(&alice, r, "/alice:open/repo/delete", "wrong_confirm", "repo", "alice:opne");
    }
    try expectPage(&alice, "/alice:open", .ok);
}

test "web: a wrong password with the right confirmation comes back as such and returns no password" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try postDelete(&alice, "/alice:open/repo/delete", "alice:open", "Wrong-Pass-82");
    defer r.deinit();
    try expectNoSecret(r, "Wrong-Pass-82");
    try r.expectRedirect("/alice:open/repo/delete");
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.delete.failure", "wrong_password");
    try form.expectJson("session.form_feedback.delete.target", "repo");
    try form.expectJson("session.form_feedback.delete.confirm", "alice:open");
    try expectNoSecret(form, "Wrong-Pass-82");
    try expectPage(&alice, "/alice:open", .ok);
}

test "web: a member's wrong confirmation comes back as such before ownership is checked" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    const r = try postDelete(&bob, "/alice:open/repo/delete", "nope", h.password);
    defer r.deinit();
    try r.expectRedirect("/alice:open/repo/delete");
    // the delete tab is the creator's only, so bob's page is not found
    const form = try bob.getJson("/alice:open/repo/delete");
    defer form.deinit();
    try form.expectStatus(.not_found);
    try form.expectJson("session.form_feedback.delete.failure", "wrong_confirm");
}

test "web: deleting is refused to the logged out and a removed account's session, whatever the form says" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();
    var dave = server.client();
    defer dave.deinit();
    try server.mintSession(&dave, server.dave);

    for ([_]*h.Client{ &visitor, &dave }) |c| {
        for ([_][]const u8{ "/alice:open/repo/delete", "/home/user/delete", "/alice:open/issues" }) |tab| {
            const r = try postDelete(c, tab, "wrong", "wrong");
            defer r.deinit();
            try expectRefused(r, .forbidden, "log in to make changes");
        }
    }
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    try expectPage(&alice, "/alice:open", .ok);
}

test "web: a delete posted from a page that is no delete tab finds nothing to delete" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    for ([_][]const u8{ "/alice:open/issues", "/alice:open", "/home/user/settings", "/alice:open/repo/settings" }) |tab| {
        const r = try postDelete(&alice, tab, "alice:open", h.password);
        defer r.deinit();
        try expectRefused(r, .not_found, "nothing to delete");
    }
    try expectPage(&alice, "/alice:open", .ok);
}

test "web: a delete sent with the password set while its body was in flight succeeds" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var other_tab = try server.clientAs("alice");
    defer other_tab.deinit();

    var change: ChangePassword = .{ .browser = &other_tab, .email = "alice@example.test" };
    const r = try alice.postWith("/alice:open/repo/delete/delete", &.{ .{ "confirm", "alice:open" }, .{ "password", "changed" } }, .{
        .between = .init(&change, ChangePassword.run),
    });
    defer r.deinit();
    try std.testing.expect(r.hook_ran);
    try r.expectRedirect("/alice");
    try expectPage(&alice, "/alice:open", .not_found);
}

// deletes alice's account through the form with another browser
const DeleteAccount = struct {
    browser: *h.Client,

    fn run(self: *DeleteAccount) anyerror!void {
        const r = try postDelete(self.browser, "/home/user/delete", "alice", h.password);
        defer r.deinit();
        try r.expectRedirect("/");
    }
};

test "web: a repo delete whose account is deleted while its body is in flight finds nothing to delete" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var other_tab = try server.clientAs("alice");
    defer other_tab.deinit();

    var removal: DeleteAccount = .{ .browser = &other_tab };
    const r = try alice.postWith("/alice:open/repo/delete/delete", &.{ .{ "confirm", "alice:open" }, .{ "password", h.password } }, .{
        .between = .init(&removal, DeleteAccount.run),
    });
    defer r.deinit();
    try std.testing.expect(r.hook_ran);
    try expectRefused(r, .not_found, "nothing to delete");
}

// ---- deleting the account

test "web: deleting the account logs it out everywhere and removes its page and repos" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    // another browser holding the same session
    var copy = server.client();
    defer copy.deinit();
    try copy.setCookie("haxy_session", alice.cookie("haxy_session").?, "/");
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    const r = try postDelete(&alice, "/home/user/delete", "alice", h.password);
    defer r.deinit();
    try r.expectRedirect("/");
    const cookies = try r.headerValues("set-cookie");
    try std.testing.expectEqual(1, cookies.len);
    try std.testing.expectEqualStrings("haxy_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0", cookies[0]);
    try std.testing.expectEqual(null, alice.cookie("haxy_session"));

    const page = try copy.getJson("/");
    defer page.deinit();
    try page.expectJson("session.user_id", null);
    const write = try copy.post("/home/repo/new", &.{ .{ "name", "late" }, .{ "description", "" }, .{ "hash", "sha1" }, .{ "access", "public" } });
    defer write.deinit();
    try expectRefused(write, .forbidden, "log in to make changes");

    try expectPage(&bob, "/alice", .not_found);
    try expectPage(&bob, "/alice:open", .not_found);
    try expectPage(&bob, "/alice:secret", .not_found);

    var again = server.client();
    defer again.deinit();
    const login = try again.post("/home/user/login", &.{ .{ "username", "alice" }, .{ "password", h.password } });
    defer login.deinit();
    try login.expectRedirect("/home/user");
    const form = try again.followJson(login);
    defer form.deinit();
    try form.expectJson("session.form_feedback.login.failure", "unknown_user");
}

test "web: the account delete tab on any page deletes the actor's own account only" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    // bob's page names bob, but the confirmation must be alice's own name
    const theirs = try postDelete(&alice, "/bob/user/delete", "bob", h.password);
    defer theirs.deinit();
    try expectDeleteFailure(&alice, theirs, "/bob/user/delete", "wrong_confirm", "user", "bob");
    try expectPage(&alice, "/bob", .ok);

    const own = try postDelete(&alice, "/bob/user/delete", "alice", h.password);
    defer own.deinit();
    try own.expectRedirect("/");
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    try expectPage(&bob, "/bob", .ok);
    try expectPage(&bob, "/alice", .not_found);
}

test "web: an account delete with a wrong confirmation or password comes back as such" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    for ([_][]const u8{ h.password, "Wrong-Pass-83" }) |pass| {
        const r = try postDelete(&alice, "/home/user/delete", "alcie", pass);
        defer r.deinit();
        try expectDeleteFailure(&alice, r, "/home/user/delete", "wrong_confirm", "user", "alcie");
    }
    const r = try postDelete(&alice, "/home/user/delete", "alice", "Wrong-Pass-83");
    defer r.deinit();
    try expectNoSecret(r, "Wrong-Pass-83");
    try expectDeleteFailure(&alice, r, "/home/user/delete", "wrong_password", "user", "alice");

    const page = try alice.getJson("/home/user");
    defer page.deinit();
    try page.expectJson("session.user_name", "alice");
}

test "web: an account delete is refused when the password changes while its body is in flight" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var other_tab = try server.clientAs("alice");
    defer other_tab.deinit();

    var change: ChangePassword = .{ .browser = &other_tab, .email = "alice@example.test" };
    const r = try alice.postWith("/home/user/delete/delete", &.{ .{ "confirm", "alice" }, .{ "password", h.password } }, .{
        .between = .init(&change, ChangePassword.run),
    });
    defer r.deinit();
    try std.testing.expect(r.hook_ran);
    try expectDeleteFailure(&alice, r, "/home/user/delete", "wrong_password", "user", "alice");

    var bob = try server.clientAs("bob");
    defer bob.deinit();
    try expectPage(&bob, "/alice", .ok);
    var fresh = server.client();
    defer fresh.deinit();
    try fresh.login("alice", "changed");
}

// ---- deleting a fork draft

// turns alice:open's patch tab on for members, gives it a master branch and
// has bob open a fork-backed patch draft on it. returns the draft's fork
// delete tab, "/bob:open+<id>/delete", owned by the caller.
fn arrangeFork(server: *h.Server, bob: *h.Client) ![]u8 {
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const settings = try alice.post("/alice:open/repo/settings", &.{
        .{ "name", "open" },            .{ "description", "" },       .{ "access", "public" },
        .{ "discuss_role", "anybody" }, .{ "issue_role", "anybody" }, .{ "patch_role", "members" },
    });
    defer settings.deinit();
    try settings.expectRedirect("/alice:open/repo/settings");
    try h.commitOnBranch(server, server.open, "master", "readme.txt", "hello\n");

    const draft = try bob.post("/alice:open/patches/new", &.{
        .{ "title", "a draft" }, .{ "labels", "" }, .{ "description", "" }, .{ "target_branch", "master" },
    });
    defer draft.deinit();
    try draft.expectStatus(.see_other);
    const location = draft.header("location").?;
    const prefix = "/alice:open/patch:";
    if (!std.mem.startsWith(u8, location, prefix)) {
        draft.describe();
        return error.TestUnexpectedDraftLocation;
    }
    return std.fmt.allocPrint(gpa, "/bob:open+{s}/delete", .{location[prefix.len..]});
}

test "web: the forker deletes a fork draft, which is then gone" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    const tab = try arrangeFork(server, &bob);
    defer gpa.free(tab);
    try expectPage(&bob, tab, .ok);

    const r = try postDelete(&bob, tab, "bob:open", h.password);
    defer r.deinit();
    try r.expectRedirect("/bob");
    const page = try bob.followJson(r);
    defer page.deinit();
    try expectArrayLen(page, "page.user.forks", 0);
    try expectPage(&bob, tab, .not_found);
}

test "web: the repo's owner finds nothing to delete in another user's fork draft" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    const tab = try arrangeFork(server, &bob);
    defer gpa.free(tab);
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try postDelete(&alice, tab, "bob:open", h.password);
    defer r.deinit();
    try expectRefused(r, .not_found, "nothing to delete");
    try expectPage(&bob, tab, .ok);
}

test "web: a fork draft delete with a wrong confirmation or password comes back as such" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    const tab = try arrangeFork(server, &bob);
    defer gpa.free(tab);

    const confirm = try postDelete(&bob, tab, "alice:open", h.password);
    defer confirm.deinit();
    try expectDeleteFailure(&bob, confirm, tab, "wrong_confirm", "fork", "alice:open");
    const pass = try postDelete(&bob, tab, "bob:open", "Wrong-Pass-84");
    defer pass.deinit();
    try expectNoSecret(pass, "Wrong-Pass-84");
    try expectDeleteFailure(&bob, pass, tab, "wrong_password", "fork", "bob:open");
    try expectPage(&bob, tab, .ok);
}

test "web: a fork draft delete is refused when the password changes while its body is in flight" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    const tab = try arrangeFork(server, &bob);
    defer gpa.free(tab);
    var other_tab = try server.clientAs("bob");
    defer other_tab.deinit();

    var change: ChangePassword = .{ .browser = &other_tab, .email = "bob@example.test" };
    var buf: [256]u8 = undefined;
    const r = try bob.postWith(try std.fmt.bufPrint(&buf, "{s}/delete", .{tab}), &.{ .{ "confirm", "bob:open" }, .{ "password", h.password } }, .{
        .between = .init(&change, ChangePassword.run),
    });
    defer r.deinit();
    try std.testing.expect(r.hook_ran);
    try expectDeleteFailure(&bob, r, tab, "wrong_password", "fork", "bob:open");
    try expectPage(&bob, tab, .ok);
}

test "web: a fork delete whose url names a malformed or unknown fork finds nothing to delete" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    for ([_][]const u8{ "/bob:open+zz/delete", "/bob:open+0123456789abcdef0123456789abcdeg/delete", "/bob:open+0123456789abcdef0123456789abcdef/delete" }) |tab| {
        const r = try postDelete(&bob, tab, "bob:open", h.password);
        defer r.deinit();
        try expectRefused(r, .not_found, "nothing to delete");
    }
}

test "web: the repo and fork delete routes do not exist in local mode" {
    var local = try h.Local(.xit).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();

    for ([_][]const u8{ "/repo/delete", "/tester:repo+0123456789abcdef0123456789abcdef/delete" }) |tab| {
        const r = try postDelete(&browser, tab, "tester", "x");
        defer r.deinit();
        try expectRefused(r, .method_not_allowed, "method not allowed");
    }
}
