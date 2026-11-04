const std = @import("std");
const srv = @import("../serve.zig");

fn expectWebUrl(expected: []const u8, web_listen: ?[]const u8, port: u16) !void {
    const url = try srv.localWebUrl(std.testing.allocator, web_listen, port);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(expected, url);
}

test "the local web url uses localhost unless an explicit address was bound" {
    try expectWebUrl("http://localhost:8080", null, 8080);
    try expectWebUrl("http://localhost:51234", null, 51234);
}

test "the local web url points at an explicitly bound interface" {
    try expectWebUrl("http://192.168.1.20:9000", "192.168.1.20:9000", 9000);
    try expectWebUrl("http://127.0.0.1:9000", "127.0.0.1:9000", 9000);
    try expectWebUrl("http://[::1]:9000", "[::1]:9000", 9000);
}

test "the local web url uses localhost for wildcard binds" {
    try expectWebUrl("http://localhost:9000", "0.0.0.0:9000", 9000);
    try expectWebUrl("http://localhost:9000", "[::]:9000", 9000);
    try expectWebUrl("http://localhost:9000", ":::9000", 9000);
}
