const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const cmd = @import("./command.zig");
const srv = @import("./serve.zig");
const ui = @import("./ui.zig");
const evt = @import("./event.zig");
const domain = @import("./domain.zig");
const mcp = @import("./mcp.zig");

// cook the terminal before a panic/segfault trace is printed, so the trace
// isn't mangled by raw mode and the alternate buffer
pub const std_options_debug_io = xit.xitui.terminal.crash_debug_io;

pub const RunOpts = struct {
    // stdin, which `haxy mcp` reads requests from
    in: ?*std.Io.Reader = null,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    // the user's global git config, used for the commit identity in local mode.
    // null by default so tests and the server paths never read it.
    global_config_path: ?[]const u8 = null,
    // false when NO_COLOR is set, so the TUI draws without colors
    color: bool = true,
};

pub fn main(init: std.process.Init) !u8 {
    const allocator = std.heap.smp_allocator;

    var threaded = std.Io.Threaded.init(allocator, .{
        .environ = init.minimal.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    var arg_it = try init.minimal.args.iterateAllocator(allocator);
    defer arg_it.deinit();
    _ = arg_it.skip();
    while (arg_it.next()) |arg| {
        try args.append(allocator, arg);
    }

    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    var stderr_writer = std.Io.File.stderr().writer(io, &.{});

    var environ_map = try std.process.Environ.createMap(init.minimal.environ, allocator);
    defer environ_map.deinit();
    const global_config_path = try xit.config.globalConfigPath(io, allocator, &environ_map);
    defer if (global_config_path) |path| allocator.free(path);

    const run_opts = RunOpts{
        .in = &stdin_reader.interface,
        .out = &stdout_writer.interface,
        .err = &stderr_writer.interface,
        .global_config_path = global_config_path,
        .color = std.mem.eql(u8, environ_map.get("NO_COLOR") orelse "", ""),
    };

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    run(.xit, .{}, io, allocator, args.items, cwd_path, run_opts) catch |err| switch (err) {
        error.HandledError => return 1,
        else => |e| return e,
    };

    return 0;
}

pub fn run(
    comptime repo_kind: rp.RepoKind,
    comptime any_repo_opts: rp.AnyRepoOpts(repo_kind),
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    cwd_path: []const u8,
    run_opts: RunOpts,
) !void {
    var cmd_args = try cmd.CommandArgs.init(allocator, args);
    defer cmd_args.deinit();

    switch (try cmd.CommandDispatch.init(&cmd_args)) {
        .invalid => |invalid| switch (invalid) {
            .command => |command| {
                try run_opts.err.print("\"{s}\" is not a valid command\n\n", .{command});
                try cmd.printHelp(null, run_opts.err);
                return error.HandledError;
            },
            .argument => |argument| {
                try run_opts.err.print("\"{s}\" is not a valid argument\n\n", .{argument.value});
                try cmd.printHelp(argument.command, run_opts.err);
                return error.HandledError;
            },
        },
        .help => |cmd_kind_maybe| try cmd.printHelp(cmd_kind_maybe, run_opts.out),
        .local => {
            // session-lifetime allocations (the repo path, session state)
            var session_arena = std.heap.ArenaAllocator.init(allocator);
            defer session_arena.deinit();

            const local = try findLocalRepo(io, allocator, &session_arena, cwd_path, run_opts);

            var session = ui.Session{
                .arena = &session_arena,
                .page_arena = &session_arena,
                .io = io,
                .local = local,
                .is_terminal = true,
                .color = run_opts.color,
                .data = .{
                    // the files root; local routes carry no identity
                    .current_page = .{ .repo_files = .{ .name = .{} } },
                    .host_kind = .local,
                },
            };

            // serve the web UI in the background while the TUI runs in the
            // foreground; the footer points at whatever port it bound.
            const Runnable = struct {
                io: std.Io,
                allocator: std.mem.Allocator,
                session: *ui.Session,

                pub fn run(self: @This(), web_url: []const u8) !void {
                    self.session.web_url = web_url;
                    try ui.run(self.io, self.allocator, self.session, null);
                }
            };

            try srv.runLocal(io, allocator, local, run_opts.err, Runnable{ .io = io, .allocator = allocator, .session = &session });
        },
        .cli => |cli_cmd| switch (cli_cmd) {
            .serve => |options| try srv.run(repo_kind, any_repo_opts, io, allocator, cwd_path, options, run_opts.err, {}),
            .delete_user => |options| try srv.deleteUser(io, allocator, cwd_path, options, run_opts.out, run_opts.err),
            .mcp => |options| try runMcp(io, allocator, cwd_path, options, run_opts),
        },
    }
}

// the nearest git or xit repo around `cwd_path`, its path in `arena`, or an
// error once the lack of one has been reported
fn findLocalRepo(
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    cwd_path: []const u8,
    run_opts: RunOpts,
) !ui.RepoSource {
    // probe both backends for a repo; the nearest one wins, so a repo
    // isn't shadowed by one it is nested inside. only the work path
    // and backend kind are kept; pages re-open the repo on each build.
    var found: ?ui.RepoSource = null;
    inline for ([_]rp.RepoKind{ .git, .xit }) |probe_kind| {
        if (rp.AnyRepo(probe_kind, .{}).open(io, allocator, .{ .path = cwd_path })) |repo| {
            var opened = repo;
            defer opened.deinit(io, allocator);
            const work_path = switch (opened) {
                inline else => |*r| r.core.work_path,
            };
            const found_len = if (found) |f| f.path.len else 0;
            if (work_path.len > found_len) {
                found = .{
                    .path = try arena.allocator().dupe(u8, work_path),
                    .repo_kind = probe_kind,
                    .global_config_path = run_opts.global_config_path,
                };
            }
        } else |err| switch (err) {
            error.RepoNotFound => {},
            else => |e| return e,
        }
    }
    return found orelse {
        try run_opts.err.print("no git or xit repo found in the current directory\n", .{});
        return error.HandledError;
    };
}

// serve mcp over stdin and stdout until stdin ends: in local mode on the repo
// around `cwd_path`, in server mode on the data dir as the named user
fn runMcp(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd_path: []const u8,
    options: cmd.McpOptions,
    run_opts: RunOpts,
) !void {
    const in = run_opts.in orelse {
        try run_opts.err.print("mcp needs stdin\n", .{});
        return error.HandledError;
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const mode: mcp.Mode = switch (options.mode) {
        .local => .{ .local = try findLocalRepo(io, allocator, &arena, cwd_path, run_opts) },
        .server => |server| blk: {
            const data_dir_path = try std.Io.Dir.path.resolveAlloc(aa, &.{ cwd_path, server.data_dir });
            const admin_repo_path = try std.Io.Dir.path.resolveAlloc(aa, &.{ data_dir_path, "admin" });
            var admin_repo = rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = admin_repo_path }) catch |open_err| switch (open_err) {
                error.RepoNotFound, error.FileNotFound => {
                    try run_opts.err.print("no haxy data in {s}\n", .{data_dir_path});
                    return error.HandledError;
                },
                else => |e| return e,
            };
            defer admin_repo.deinit(io, allocator);
            // the name is resolved once; each call re-checks the account is active
            const moment = try evt.currentMoment(evt.admin_repo_opts, &admin_repo);
            const user_id = (try evt.User.readIdByName(evt.AdminDB, evt.admin_repo_opts.hash, moment, server.user)) orelse {
                try run_opts.err.print("no user named {s}\n", .{server.user});
                return error.HandledError;
            };
            if (try domain.activeUser(moment, &arena, user_id) == null) {
                try run_opts.err.print("no user named {s}\n", .{server.user});
                return error.HandledError;
            }
            break :blk .{ .server = .{
                .admin_repo_path = admin_repo_path,
                .users_dir = try std.Io.Dir.path.resolveAlloc(aa, &.{ data_dir_path, "users" }),
                .user_id = user_id,
            } };
        },
    };

    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = mode, .allow_destructive = options.allow_destructive };
    try mcp.stdio.run(&server, in, run_opts.out, run_opts.err);
}
