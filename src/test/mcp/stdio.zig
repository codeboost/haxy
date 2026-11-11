//! the stdio transport's framing: one json-rpc message per line.

const std = @import("std");
const hx = @import("../../lib.zig");
const mcp = hx.mcp;
const fixture = @import("../domain/fixture.zig");

const io = std.testing.io;
const allocator = std.testing.allocator;

// what the loop writes for everything `in` holds, ending at its end
fn serve(in: *std.Io.Reader) ![]u8 {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(allocator);
    defer err.deinit();
    try mcp.stdio.run(&server, in, &out.writer, &err.writer);
    return try out.toOwnedSlice();
}

test "mcp stdio: several messages in one read get a reply each, in order" {
    var in: std.Io.Reader = .fixed(
        \\{"jsonrpc":"2.0","id":1,"method":"ping"}
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\{"jsonrpc":"2.0","id":2,"method":"ping"}
        \\
    );
    const out = try serve(&in);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"result":{}}
        \\{"jsonrpc":"2.0","id":2,"result":{}}
        \\
    , out);
}

test "mcp stdio: a message split across reads is answered once it is whole" {
    var buffer: [16]u8 = undefined;
    var in: std.testing.Reader = .init(&buffer, &.{
        .{ .buffer = "{\"jsonrpc\":\"2.0\",\"id\":1," },
        .{ .buffer = "\"method\":\"ping\"}\n{\"jsonrpc\":\"2.0\"," },
        .{ .buffer = "\"id\":2,\"method\":\"ping\"}\n" },
    });
    const out = try serve(&in.interface);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":1,"result":{}}
        \\{"jsonrpc":"2.0","id":2,"result":{}}
        \\
    , out);
}

test "mcp stdio: the end of input ends the loop, answering a last line without a newline" {
    {
        var in: std.Io.Reader = .fixed("");
        const out = try serve(&in);
        defer allocator.free(out);
        try std.testing.expectEqualStrings("", out);
    }
    {
        var in: std.Io.Reader = .fixed("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}");
        const out = try serve(&in);
        defer allocator.free(out);
        try std.testing.expectEqualStrings(
            \\{"jsonrpc":"2.0","id":1,"result":{}}
            \\{"jsonrpc":"2.0","id":2,"result":{}}
            \\
        , out);
    }
}

test "mcp stdio: a line over the bound is a parse error and the loop goes on" {
    const long = try allocator.alloc(u8, mcp.stdio.max_line_len + 1);
    defer allocator.free(long);
    @memset(long, ' ');
    const input = try std.mem.concat(allocator, u8, &.{ long, "\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n" });
    defer allocator.free(input);
    var buffer: [4096]u8 = undefined;
    var in: std.testing.Reader = .init(&buffer, &.{.{ .buffer = input }});
    const out = try serve(&in.interface);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error: line too long"}}
        \\{"jsonrpc":"2.0","id":2,"result":{}}
        \\
    , out);
}

test "mcp stdio: a line at the bound is read whole" {
    const ping = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
    // padded with spaces after the object, which json allows
    const line = try allocator.alloc(u8, mcp.stdio.max_line_len);
    defer allocator.free(line);
    @memset(line, ' ');
    @memcpy(line[0..ping.len], ping);
    const input = try std.mem.concat(allocator, u8, &.{ line, "\n" });
    defer allocator.free(input);
    var in: std.Io.Reader = .fixed(input);
    const out = try serve(&in);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n", out);
}
