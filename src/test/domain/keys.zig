const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

// two ed25519 keys; the server only reads their type and blob
const key_one = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeIs8mJqigBZ5y84J4COgnAJJ5bHPKy+lM2SliMXbYm one@example";
const key_two = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC two@example";

test "domain: AddKey adds a key to the acting user's keys" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    try (domain.AddKey{ .key = key_one }).run(&alice);
    try (domain.AddKey{ .key = key_two ++ "\r" }).run(&alice);
    try std.testing.expectEqualStrings(key_one ++ "\n" ++ key_two, ((try server.account(server.alice)) orelse return error.TestExpectedUser).event.ssh_keys);
    try std.testing.expectEqualStrings("", ((try server.account(server.bob)) orelse return error.TestExpectedUser).event.ssh_keys);
}

test "domain: AddKey needs a login and a server" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.AddKey{ .key = key_one }).run(&ctx));
    }

    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var ctx = local.ctx(&arena);
    try std.testing.expectError(error.UnavailableHere, (domain.AddKey{ .key = key_one }).run(&ctx));
}

test "domain: AddKey rejects a bad, unsupported, repeated or extra key" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    try (domain.AddKey{ .key = key_one }).run(&alice);

    try std.testing.expectError(error.InvalidKey, (domain.AddKey{ .key = "not a key" }).run(&alice));
    try std.testing.expectError(error.InvalidKey, (domain.AddKey{ .key = "" }).run(&alice));
    // one key per line
    try std.testing.expectError(error.InvalidKey, (domain.AddKey{ .key = key_two ++ "\n" ++ key_two }).run(&alice));
    try std.testing.expectError(error.UnsupportedKey, (domain.AddKey{ .key = "ssh-dss AAAAB3NzaC1kc3MAAAAB" }).run(&alice));
    // the same key under another comment is the same key
    try std.testing.expectError(error.KeyAdded, (domain.AddKey{ .key = key_one ++ " again" }).run(&alice));
    try std.testing.expectEqualStrings(key_one, ((try server.account(server.alice)) orelse return error.TestExpectedUser).event.ssh_keys);
}

test "domain: AddKey stops at the most keys a user may hold" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    // 50 distinct keys: their blobs differ in one byte
    var blob: [51]u8 = undefined;
    @memcpy(blob[0..19], "\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20");
    @memset(blob[19..], 0);
    var i: u8 = 0;
    while (i < 51) : (i += 1) {
        blob[19] = i;
        var encoded: [std.base64.standard.Encoder.calcSize(51)]u8 = undefined;
        const key = try std.fmt.allocPrint(arena.allocator(), "ssh-ed25519 {s}", .{std.base64.standard.Encoder.encode(&encoded, &blob)});
        if (i < 50) {
            try (domain.AddKey{ .key = key }).run(&alice);
        } else {
            try std.testing.expectError(error.TooManyKeys, (domain.AddKey{ .key = key }).run(&alice));
        }
    }
}

test "domain: RemoveKey removes the acting user's key by its fingerprint" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    try (domain.AddKey{ .key = key_one }).run(&alice);
    try (domain.AddKey{ .key = key_two }).run(&alice);

    const fingerprint = evt.User.fingerprintOfKey(key_one) orelse return error.TestExpectedKey;
    try (domain.RemoveKey{ .fingerprint = &fingerprint }).run(&alice);
    try std.testing.expectEqualStrings(key_two, ((try server.account(server.alice)) orelse return error.TestExpectedUser).event.ssh_keys);
}

test "domain: RemoveKey finds no key for a malformed or unknown fingerprint" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    var bob = try server.ctx(&arena, server.bob);
    try (domain.AddKey{ .key = key_one }).run(&alice);
    try (domain.AddKey{ .key = key_two }).run(&bob);

    const bobs = evt.User.fingerprintOfKey(key_two) orelse return error.TestExpectedKey;
    // bob's key isn't alice's to remove, and nothing else names a key of hers:
    // a well-formed fingerprint of no key, short and long ones
    for ([_][]const u8{ &bobs, "", "SHA256:short", "SHA256:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "SHA256:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }) |fingerprint| {
        try std.testing.expectError(error.NotFound, (domain.RemoveKey{ .fingerprint = fingerprint }).run(&alice));
    }
    try std.testing.expectEqualStrings(key_one, ((try server.account(server.alice)) orelse return error.TestExpectedUser).event.ssh_keys);
    try std.testing.expectEqualStrings(key_two, ((try server.account(server.bob)) orelse return error.TestExpectedUser).event.ssh_keys);
}

test "domain: RemoveKey needs a login and a server" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const fingerprint = evt.User.fingerprintOfKey(key_one) orelse return error.TestExpectedKey;
    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.RemoveKey{ .fingerprint = &fingerprint }).run(&ctx));
    }

    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var ctx = local.ctx(&arena);
    try std.testing.expectError(error.UnavailableHere, (domain.RemoveKey{ .fingerprint = &fingerprint }).run(&ctx));
}

// a server session of `user`'s that connected over ssh with `key`
fn sshSession(server: *Server, arena: *std.heap.ArenaAllocator, user: fixture.Id, key: []const u8) !hx.ui.Session {
    var session = try hx.ui.Session.init(arena, &server.admin, .{ .user_id = &user });
    session.io = std.testing.io;
    session.users_dir = server.users_dir;
    session.ssh_key = key;
    return session;
}

test "domain: a password login over ssh remembers the session's key once, and lets it log in" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var session = try sshSession(server, &arena, server.alice, key_one);

    try session.rememberSshKey();
    const keys = ((try server.account(server.alice)) orelse return error.TestExpectedUser).event.ssh_keys;
    try std.testing.expect(std.mem.startsWith(u8, keys, key_one ++ " added "));
    try std.testing.expect(std.mem.endsWith(u8, keys, " via login"));
    // a second login with the same key adds nothing
    try session.rememberSshKey();
    try std.testing.expectEqualStrings(keys, ((try server.account(server.alice)) orelse return error.TestExpectedUser).event.ssh_keys);
}
