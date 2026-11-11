//! `haxy mcp`'s argument parsing, through the dispatch `main.run` uses.

const std = @import("std");
const hx = @import("../../lib.zig");
const cmd = hx.command;

const allocator = std.testing.allocator;

fn expectDispatch(args: []const []const u8, expected: cmd.CommandDispatch) !void {
    var cmd_args = try cmd.CommandArgs.init(allocator, args);
    defer cmd_args.deinit();
    const dispatch = try cmd.CommandDispatch.init(&cmd_args);
    try std.testing.expectEqualDeep(expected, dispatch);
}

test "mcp cli: no flags runs in local mode" {
    try expectDispatch(&.{"mcp"}, .{ .cli = .{ .mcp = .local } });
}

test "mcp cli: --data-dir and --user together run in server mode" {
    try expectDispatch(&.{ "mcp", "--data-dir", "/srv/git", "--user", "alice" }, .{ .cli = .{ .mcp = .{ .server = .{ .data_dir = "/srv/git", .user = "alice" } } } });
    try expectDispatch(&.{ "mcp", "--user", "alice", "--data-dir", "/srv/git" }, .{ .cli = .{ .mcp = .{ .server = .{ .data_dir = "/srv/git", .user = "alice" } } } });
}

test "mcp cli: anything but no flags or both server flags with values is an invalid argument" {
    const invalid = struct {
        fn argument(value: []const u8) cmd.CommandDispatch {
            return .{ .invalid = .{ .argument = .{ .command = .mcp, .value = value } } };
        }
    };
    // one server flag without the other
    try expectDispatch(&.{ "mcp", "--data-dir", "/srv/git" }, invalid.argument("--data-dir"));
    try expectDispatch(&.{ "mcp", "--user", "alice" }, invalid.argument("--user"));
    // a server flag without a value
    try expectDispatch(&.{ "mcp", "--data-dir", "--user", "alice" }, invalid.argument("--data-dir"));
    try expectDispatch(&.{ "mcp", "--data-dir", "/srv/git", "--user" }, invalid.argument("--data-dir"));
    // a flag mcp doesn't take
    try expectDispatch(&.{ "mcp", "--web-listen", "127.0.0.1:8080" }, invalid.argument("--web-listen"));
    // a positional argument
    try expectDispatch(&.{ "mcp", "alice" }, invalid.argument("alice"));
}
