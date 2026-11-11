const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const fixture = @import("fixture.zig");

const io = std.testing.io;
const allocator = std.testing.allocator;

// a read that failed, and not because what it names is missing
fn expectFailedRead(result: anytype) !void {
    if (result) |_| return error.TestUnexpectedSuccess else |err| {
        errdefer std.debug.print("failed with {s}\n", .{@errorName(err)});
        try std.testing.expect(err != error.NotFound);
        try std.testing.expectEqual(.internal, domain.classify(err).kind);
    }
}

test "domain: ref resolution: a branch whose ref can't be read fails as storage, not as missing" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    try local.commitBranch("side", "side\n");
    try local.commitBranch("team/a", "team\n");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    // names no ref: unknown, below a ref, or a directory of refs
    for ([_][]const u8{ "nope", "side/x", "team" }) |name| {
        try std.testing.expectError(error.NotFound, (domain.ListCommits{ .repo = "", .ref_kind = .branch, .ref = name }).run(&ctx));
        try std.testing.expectError(error.NotFound, (domain.ListFiles{ .repo = "", .ref_kind = .branch, .ref = name }).run(&ctx));
    }

    // the ref is there but can't be read
    var dir = try std.Io.Dir.cwd().openDir(io, local.path, .{});
    defer dir.close(io);
    try dir.setFilePermissions(io, ".git/refs/heads/side", .fromMode(0), .{});
    defer dir.setFilePermissions(io, ".git/refs/heads/side", .default_file, .{}) catch {};
    try expectFailedRead((domain.ListCommits{ .repo = "", .ref_kind = .branch, .ref = "side" }).run(&ctx));
    try expectFailedRead((domain.ListFiles{ .repo = "", .ref_kind = .branch, .ref = "side" }).run(&ctx));
    try expectFailedRead((domain.ReadFile{ .repo = "", .ref_kind = .branch, .ref = "side", .path = "readme.txt" }).run(&ctx));
}
