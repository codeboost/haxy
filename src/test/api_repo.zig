const std = @import("std");
const api_repo = @import("../api/repo.zig");
const api_path = @import("../api/path.zig");
const query_params = @import("../api/query.zig");
const ui = @import("../ui.zig");
const evt = @import("../event.zig");

test "repo routes name the local repo or a server repo by owner and name" {
    const overview = api_repo.route("/api/v1/repos/bobby/linux").?;
    try std.testing.expectEqualStrings("bobby", overview.target.server.owner);
    try std.testing.expectEqualStrings("linux", overview.target.server.name);
    try std.testing.expectEqual(.overview, overview.resource);
    try std.testing.expectEqual(.files, api_repo.route("/api/v1/repos/bobby/linux/files").?.resource);
    // names stay encoded until the handler decodes them
    try std.testing.expectEqualStrings("a%20b", api_repo.route("/api/v1/repos/a%20b/c/files").?.target.server.owner);

    try std.testing.expectEqual(api_repo.Route{ .target = .local, .resource = .overview }, api_repo.route("/api/v1/repo").?);
    try std.testing.expectEqual(api_repo.Route{ .target = .local, .resource = .files }, api_repo.route("/api/v1/repo/files").?);

    for ([_][]const u8{ "/api/v1/repos", "/api/v1/repos/bobby", "/api/v1/repos/bobby/", "/api/v1/repos//linux", "/api/v1/repos/bobby/linux/commits", "/api/v1/repos/bobby/linux/files/x", "/api/v1/repo/x", "/api/v1/repositories" }) |path| {
        try std.testing.expectEqual(null, api_repo.route(path));
    }
}

fn data(host_kind: evt.HostKind, ssh: ?[]const u8) ui.Session.Data {
    return .{ .host_kind = host_kind, .git_http_url = if (host_kind == .server) "http://haxy.test" else null, .git_ssh_url = ssh, .git_ssh_prefix = if (ssh != null) "GIT_SSH_COMMAND='ssh -p 2222' " else "" };
}

fn handle(access: evt.Repo.Access, role: ?evt.Repo.Role) ui.RepoHandle {
    return .{
        .location = .{ .repo = "bobby:linux" },
        .viewer = if (role) |r| .{ .role = r, .email = "bobby@example.test" } else null,
        .read_access = access,
    };
}

test "clone commands use the host's own urls; only a public repo clones over http, and everyone starts on ssh" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const public = try ui.widget.cloneCommands(aa, data(.server, "ssh://haxy.test:2222"), handle(.public, null));
    try std.testing.expectEqual(2, public.list.len);
    try std.testing.expectEqual(.http, public.list[0].protocol);
    try std.testing.expectEqualStrings("http://haxy.test/bobby:linux", public.list[0].url);
    try std.testing.expectEqualStrings("git clone http://haxy.test/bobby:linux", public.list[0].command);
    try std.testing.expectEqualStrings("GIT_SSH_COMMAND='ssh -p 2222' git clone ssh://haxy.test:2222/bobby:linux", public.list[1].command);
    try std.testing.expectEqual(1, public.preferred);
    try std.testing.expectEqual(1, (try ui.widget.cloneCommands(aa, data(.server, "ssh://haxy.test:2222"), handle(.public, .write))).preferred);

    const private = try ui.widget.cloneCommands(aa, data(.server, "ssh://haxy.test:2222"), handle(.private, .read));
    try std.testing.expectEqual(1, private.list.len);
    try std.testing.expectEqual(.ssh, private.list[0].protocol);

    try std.testing.expectEqual(0, (try ui.widget.cloneCommands(aa, data(.server, null), handle(.private, .owner))).list.len);
    try std.testing.expectEqual(0, (try ui.widget.cloneCommands(aa, data(.local, null), handle(.private, .owner))).list.len);
}

test "the remote command is offered over ssh to whoever may push, on a server only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const remote = (try ui.widget.remoteCommand(aa, data(.server, "ssh://haxy.test:2222"), handle(.public, .write))).?;
    try std.testing.expectEqualStrings("git remote add origin ssh://haxy.test:2222/bobby:linux", remote.command);
    try std.testing.expectEqual(null, try ui.widget.remoteCommand(aa, data(.server, "ssh://haxy.test:2222"), handle(.public, .read)));
    try std.testing.expectEqual(null, try ui.widget.remoteCommand(aa, data(.server, "ssh://haxy.test:2222"), handle(.public, null)));
    try std.testing.expectEqual(null, try ui.widget.remoteCommand(aa, data(.server, null), handle(.public, .owner)));
    try std.testing.expectEqual(null, try ui.widget.remoteCommand(aa, data(.local, null), handle(.public, .owner)));
}

test "a repo's sections follow its thread settings and the viewer's role" {
    const repo: evt.Repo = .{ .user_id = @splat('0'), .name = "linux", .description = "", .issue_role = null, .patch_role = .read };
    var shown: std.ArrayList(ui.Repo.Section) = .empty;
    defer shown.deinit(std.testing.allocator);
    for (std.enums.values(ui.Repo.Section)) |section| {
        if (ui.Repo.hasSection(section, repo, handle(.public, null), .server, .xit)) try shown.append(std.testing.allocator, section);
    }
    try std.testing.expectEqualSlices(ui.Repo.Section, &.{ .files, .commits, .refs, .discussions, .patches }, shown.items);

    try std.testing.expect(ui.Repo.hasSection(.events, repo, handle(.public, .write), .server, .xit));
    try std.testing.expect(ui.Repo.hasSection(.undo, repo, handle(.public, .write), .server, .xit));
    try std.testing.expect(!ui.Repo.hasSection(.undo, repo, handle(.public, .owner), .local, .git));
    try std.testing.expect(!ui.Repo.hasSection(.settings, repo, handle(.public, .write), .server, .xit));
    try std.testing.expect(ui.Repo.hasSection(.settings, repo, handle(.public, .owner), .server, .xit));
}

test "a directory lists its subdirectories first, each group keeping the tree's name order" {
    const Entry = struct {
        dir: bool,
        pub fn isTree(self: @This()) bool {
            return self.dir;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = [_]Entry{ .{ .dir = false }, .{ .dir = true }, .{ .dir = false }, .{ .dir = true } };
    try std.testing.expectEqualSlices(usize, &.{ 1, 3, 0, 2 }, try ui.Repo.Files.listOrder(arena.allocator(), &entries));
}

test "only a markdown file one first window holds whole renders as markdown" {
    const Files = ui.Repo.Files;
    try std.testing.expect(Files.showsMarkdown("README.md", 0, 10, false));
    try std.testing.expect(Files.showsMarkdown("guide.MARKDOWN", 0, 10, false));
    try std.testing.expect(!Files.showsMarkdown("README", 0, 10, false));
    try std.testing.expect(!Files.showsMarkdown("big.md", 0, 5000, true));
    try std.testing.expect(!Files.showsMarkdown("big.md", 5000, 10, false));
    try std.testing.expect(Files.isReadme("readme.md") and Files.isReadme("README") and !Files.isReadme("README.txt"));
}

test "repository paths travel percent-encoded byte for byte, with a lossy name for display" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // git paths are bytes: this one isn't utf-8, and holds what urls and
    // query strings treat specially
    const raw = "docs/caf\xe9 x+%2F&#?.txt";
    const encoded = try api_path.encode(aa, raw);
    try std.testing.expectEqualStrings("docs/caf%E9%20x%2B%252F%26%23%3F.txt", encoded);
    // sent back as the `path` parameter, it decodes to the same bytes
    const query = try std.fmt.allocPrint(aa, "path={s}&line=2", .{encoded});
    try std.testing.expectEqualStrings(raw, (try query_params.param(aa, query, "path")).?);

    try std.testing.expectEqualStrings("caf\u{FFFD} x+%2F&#?.txt", try api_path.display(aa, "caf\xe9 x+%2F&#?.txt"));
    try std.testing.expectEqualStrings("naïve", try api_path.display(aa, "naïve"));
    try std.testing.expectEqualStrings("na%C3%AFve-_.~", try api_path.encode(aa, "naïve-_.~"));
}
