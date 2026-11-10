//! adding and removing a user's ssh keys through the keys tab

const std = @import("std");
const h = @import("harness.zig");

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

const alice_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINAoMC501vhkyMjEvSuehVQput+n8qmUt1TiVgb/43F0 alice@laptop";
// its fingerprint, url-encoded as the keys tab links it
const alice_fingerprint = "SHA256%3A8wligOakas02tWoqup%2B5u9f%2ByfYeK5dIgSHRhyrb9mw";
const bob_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG6x9t/QQvHBWRwlLvoGVIAJP2nWw8MvMgyUgUQPDKdp bob@desk";
// a well-formed fingerprint no key here has
const unheld_fingerprint = "SHA256%3AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const keys_path = "page.home.user_notifications.ssh_keys.keys";

fn addKey(c: *h.Client, key: []const u8) !*h.Response {
    return c.post("/home/user/keys/addkey", &.{.{ "key", key }});
}

fn removeKey(c: *h.Client, encoded_fingerprint: []const u8) !*h.Response {
    var buf: [256]u8 = undefined;
    return c.post(try std.fmt.bufPrint(&buf, "/home/user/keys/key:{s}/removekey/removekey", .{encoded_fingerprint}), &.{});
}

// the keys tab lists exactly `expected`
fn expectKeys(c: *h.Client, expected: []const []const u8) !void {
    const page = try c.getJson("/home/user/keys");
    defer page.deinit();
    try expectArrayLen(page, keys_path, expected.len);
    var buf: [64]u8 = undefined;
    for (expected, 0..) |want, i| try page.expectJson(try std.fmt.bufPrint(&buf, keys_path ++ ".{d}", .{i}), want);
}

// a distinct well-formed ed25519 line for `n`; the server checks the type and
// the base64, not the curve point
fn numberedKey(buf: []u8, n: usize) ![]const u8 {
    var blob: [32]u8 = @splat('k');
    _ = try std.fmt.bufPrint(&blob, "{d:0>4}", .{n});
    var encoded: [std.base64.standard.Encoder.calcSize(32)]u8 = undefined;
    return std.fmt.bufPrint(buf, "ssh-ed25519 {s} key{d}", .{ std.base64.standard.Encoder.encode(&encoded, &blob), n });
}

// ---- POST …/addkey

test "web: an added ed25519 key is listed on the keys tab" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try addKey(&alice, alice_key);
    defer r.deinit();
    try r.expectRedirect("/home/user/keys");
    const page = try alice.followJson(r);
    defer page.deinit();
    try page.expectJson("session.form_feedback", null);
    try page.expectJson(keys_path ++ ".0", alice_key);

    // the key is alice's alone
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    try expectKeys(&bob, &.{});
}

test "web: a key with surrounding blanks is stored trimmed" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try addKey(&alice, "  " ++ alice_key ++ "\r");
    defer r.deinit();
    try r.expectRedirect("/home/user/keys");
    try expectKeys(&alice, &.{alice_key});
}

test "web: a malformed key comes back as invalid with the text kept" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    for ([_][]const u8{ "not a key", "ssh-ed25519", "ssh-ed25519 !!!notbase64!!!", alice_key ++ "\n" ++ bob_key }) |text| {
        const r = try addKey(&alice, text);
        defer r.deinit();
        try r.expectRedirect("/home/user/keys");
        const form = try alice.followJson(r);
        defer form.deinit();
        try form.expectJson("session.form_feedback.user_keys.failure", "invalid");
        try form.expectJson("session.form_feedback.user_keys.key", text);
    }
    try expectKeys(&alice, &.{});
}

test "web: a key of a type the ssh server does not verify comes back as unsupported" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const dss = "ssh-dss AAAAB3NzaC1kc3MAAACBAP8= old@box";
    const r = try addKey(&alice, dss);
    defer r.deinit();
    try r.expectRedirect("/home/user/keys");
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.user_keys.failure", "unsupported");
    try form.expectJson("session.form_feedback.user_keys.key", dss);
    try expectKeys(&alice, &.{});
}

test "web: adding a key twice comes back as already added, keeping one copy" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const first = try addKey(&alice, alice_key);
    defer first.deinit();
    try first.expectRedirect("/home/user/keys");
    // the same key under another comment is the same key
    const second = try addKey(&alice, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINAoMC501vhkyMjEvSuehVQput+n8qmUt1TiVgb/43F0 again");
    defer second.deinit();
    try second.expectRedirect("/home/user/keys");
    const form = try alice.followJson(second);
    defer form.deinit();
    try form.expectJson("session.form_feedback.user_keys.failure", "already_added");
    try expectKeys(&alice, &.{alice_key});
}

test "web: two users may add the same key" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    const a = try addKey(&alice, alice_key);
    defer a.deinit();
    try a.expectRedirect("/home/user/keys");
    const b = try addKey(&bob, alice_key);
    defer b.deinit();
    try b.expectRedirect("/home/user/keys");
    try expectKeys(&bob, &.{alice_key});
}

test "web: a key past the fiftieth comes back as too many" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    var buf: [128]u8 = undefined;
    for (0..50) |n| {
        const r = try addKey(&alice, try numberedKey(&buf, n));
        defer r.deinit();
        try r.expectRedirect("/home/user/keys");
        const page = try alice.followJson(r);
        defer page.deinit();
        try page.expectJson("session.form_feedback", null);
    }
    const r = try addKey(&alice, alice_key);
    defer r.deinit();
    try r.expectRedirect("/home/user/keys");
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.user_keys.failure", "too_many");
    try form.expectJson("session.form_feedback.user_keys.key", alice_key);
    try expectArrayLen(form, keys_path, 50);
    try form.expectJson(keys_path ++ ".49", try numberedKey(&buf, 49));
}

test "web: adding a key is refused to the logged out and a removed account's session, whatever the form says" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();
    var dave = server.client();
    defer dave.deinit();
    try server.mintSession(&dave, server.dave);

    for ([_]*h.Client{ &visitor, &dave }) |c| {
        const r = try addKey(c, alice_key);
        defer r.deinit();
        try expectRefused(r, .forbidden, "log in to make changes");
        // differs from 66c1ab6: there a removed account's malformed key failed
        // parsing first and came back as a 303 with invalid; it is now refused
        // before the body is read. accepted as B2 in
        // docs/reviews/05-phase4-codex.md (add key row).
        const bad = try addKey(c, "not a key");
        defer bad.deinit();
        try expectRefused(bad, .forbidden, "log in to make changes");
    }
}

// ---- POST …/removekey

test "web: removing a key drops it from the keys tab and returns there" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    for ([_][]const u8{ alice_key, bob_key }) |key| {
        const r = try addKey(&alice, key);
        defer r.deinit();
        try r.expectRedirect("/home/user/keys");
    }

    const r = try removeKey(&alice, alice_fingerprint);
    defer r.deinit();
    try r.expectRedirect("/home/user/keys");
    try expectKeys(&alice, &.{bob_key});
}

test "web: removing a key from another page's keys tab returns to that tab" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const added = try addKey(&alice, alice_key);
    defer added.deinit();

    const r = try alice.post("/alice:open/user/keys/key:" ++ alice_fingerprint ++ "/removekey/removekey", &.{});
    defer r.deinit();
    try r.expectRedirect("/alice:open/user/keys");
    try expectKeys(&alice, &.{});
}

test "web: removing a fingerprint the user does not hold changes nothing and returns to the tab" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    const added = try addKey(&alice, alice_key);
    defer added.deinit();

    const unheld = try removeKey(&alice, unheld_fingerprint);
    defer unheld.deinit();
    try unheld.expectRedirect("/home/user/keys");
    // bob names alice's key, which only touches his own keys
    const other = try removeKey(&bob, alice_fingerprint);
    defer other.deinit();
    try other.expectRedirect("/home/user/keys");
    try expectKeys(&alice, &.{alice_key});
}

test "web: a removal whose url names no well-formed key is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const added = try addKey(&alice, alice_key);
    defer added.deinit();

    for ([_][]const u8{
        "/home/user/keys/key:SHA256%3Ashort/removekey/removekey",
        "/home/user/keys/removekey",
        "/home/user/settings/removekey",
        "/alice:open/issues/removekey",
    }) |path| {
        const r = try alice.post(path, &.{});
        defer r.deinit();
        try expectRefused(r, .not_found, "ssh key not found");
    }
    try expectKeys(&alice, &.{alice_key});
}

test "web: removing a key is refused to the logged out and a removed account's session" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();
    var dave = server.client();
    defer dave.deinit();
    try server.mintSession(&dave, server.dave);

    for ([_]*h.Client{ &visitor, &dave }) |c| {
        const r = try removeKey(c, alice_fingerprint);
        defer r.deinit();
        try expectRefused(r, .forbidden, "log in to make changes");
    }
    // logged out, even a malformed url is refused as such
    const bad = try visitor.post("/home/user/settings/removekey", &.{});
    defer bad.deinit();
    try expectRefused(bad, .forbidden, "log in to make changes");
}
