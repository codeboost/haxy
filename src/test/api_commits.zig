const std = @import("std");
const xit = @import("xit");
const api = @import("../api.zig");
const api_commits = @import("../api/commits.zig");
const srch_cmmt = @import("../search_commit.zig");
const ui = @import("../ui.zig");

test "commit routes name a ref's history or one commit, on a server or the local repo" {
    const list = api_commits.route("/api/v1/repos/bobby/linux/commits").?;
    try std.testing.expectEqualStrings("bobby", list.target.server.owner);
    try std.testing.expectEqualStrings("linux", list.target.server.name);
    try std.testing.expectEqual(.list, std.meta.activeTag(list.resource));
    const one = api_commits.route("/api/v1/repos/bobby/linux/commits/0123456789abcdef0123456789abcdef01234567").?;
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", one.resource.commit);
    // names stay encoded until the handler decodes them
    try std.testing.expectEqualStrings("a%20b", api_commits.route("/api/v1/repos/a%20b/c/commits").?.target.server.owner);

    try std.testing.expectEqual(.local, std.meta.activeTag(api_commits.route("/api/v1/repo/commits").?.target));
    try std.testing.expectEqualStrings("abc", api_commits.route("/api/v1/repo/commits/abc").?.resource.commit);

    for ([_][]const u8{
        "/api/v1/repos/bobby/linux",
        "/api/v1/repos/bobby/linux/files",
        "/api/v1/repos/bobby/linux/commits/",
        "/api/v1/repos/bobby/linux/commits/abc/diff/x",
        "/api/v1/repos/bobby/linux/commitsx",
        "/api/v1/repos//linux/commits",
        "/api/v1/repos/bobby/commits",
        "/api/v1/repo/commits/",
        "/api/v1/repo/commitsx",
        "/api/v1/repo",
    }) |path| {
        try std.testing.expectEqual(null, api_commits.route(path));
    }
}

// a temporary repo of `kind` on branch master
fn TestRepo(comptime kind: xit.repo.RepoKind) type {
    return struct {
        const opts: xit.repo.RepoOpts(kind) = .{ .is_test = true };
        const Repo = xit.repo.Repo(kind, opts);
        const Oid = [xit.hash.hexLen(opts.hash)]u8;

        temp: std.testing.TmpDir,
        path: [:0]const u8,
        repo: Repo,
        arena: std.heap.ArenaAllocator,

        const Self = @This();
        const master = xit.ref.Ref{ .kind = .head, .name = "master" };

        fn init(self: *Self) !void {
            const io = std.testing.io;
            self.temp = std.testing.tmpDir(.{});
            self.path = try self.temp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
            self.repo = try Repo.init(io, std.testing.allocator, .{ .path = self.path });
            self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        }

        fn deinit(self: *Self) void {
            self.arena.deinit();
            self.repo.deinit(std.testing.io, std.testing.allocator);
            std.testing.allocator.free(self.path);
            self.temp.cleanup();
        }

        fn commit(self: *Self, metadata: xit.object.CommitMetadata(opts.hash)) !Oid {
            var with_author = metadata;
            if (with_author.author == null) with_author.author = "alice <alice@example.test>";
            with_author.allow_empty = true;
            return self.repo.commitAtRef(std.testing.io, std.testing.allocator, with_author, null, master);
        }

        // builds the commit index of every branch and tag tip, as a push does
        fn index(self: *Self) !void {
            if (kind != .xit) unreachable;
            const Reindex = struct {
                io: std.Io,
                core: *Repo.Core,

                pub fn run(ctx: @This(), cursor: *Repo.DB.Cursor(.read_write)) !void {
                    var moment = try Repo.DB.HashMap(.read_write).init(cursor.*);
                    const state = Repo.State(.read_write){ .core = ctx.core, .extra = .{ .moment = &moment } };
                    _ = try srch_cmmt.refreshInTransaction(opts, state, &moment, ctx.io, std.testing.allocator, &.{}, null);
                }
            };
            const io = std.testing.io;
            try self.repo.core.db_file.lock(io, .exclusive);
            defer self.repo.core.db_file.unlock(io);
            const history = try Repo.DB.ArrayList(.read_write).init(self.repo.core.db.rootCursor());
            try history.appendContext(.{ .slot = try history.getSlot(-1) }, Reindex{ .io = io, .core = &self.repo.core });
        }

        // the list's json for `query`, or the error it answers with
        fn list(self: *Self, host_kind: @import("../event.zig").HostKind, query: []const u8) !Answer {
            var out: std.Io.Writer.Allocating = .init(self.arena.allocator());
            const context: api_commits.Context = .{ .handle = .{ .location = .{ .repo = "" } }, .host_kind = host_kind };
            if (try api_commits.writeList(kind, opts, &self.arena, &self.repo, std.testing.io, std.testing.allocator, context, query, &out.writer)) |err| return .{ .err = err };
            return .{ .json = try std.json.parseFromSliceLeaky(std.json.Value, self.arena.allocator(), out.written(), .{}) };
        }

        // the list as read at an earlier snapshot of the repo
        fn listAt(self: *Self, moment: ui.Repo.Commits.Moment(kind, opts), query: []const u8) !Answer {
            var out: std.Io.Writer.Allocating = .init(self.arena.allocator());
            const context: api_commits.Context = .{ .handle = .{ .location = .{ .repo = "" } }, .host_kind = .server };
            if (try api_commits.writeListAt(kind, opts, &self.arena, &self.repo, std.testing.io, std.testing.allocator, context, moment, query, &out.writer)) |err| return .{ .err = err };
            return .{ .json = try std.json.parseFromSliceLeaky(std.json.Value, self.arena.allocator(), out.written(), .{}) };
        }

        fn one(self: *Self, oid: []const u8) !Answer {
            var out: std.Io.Writer.Allocating = .init(self.arena.allocator());
            const context: api_commits.Context = .{ .handle = .{ .location = .{ .repo = "" } }, .host_kind = .local };
            if (try api_commits.writeCommit(kind, opts, &self.arena, &self.repo, std.testing.io, std.testing.allocator, context, oid, &out.writer)) |err| return .{ .err = err };
            return .{ .json = try std.json.parseFromSliceLeaky(std.json.Value, self.arena.allocator(), out.written(), .{}) };
        }
    };
}

const Answer = union(enum) {
    json: std.json.Value,
    err: api.Error,

    fn ok(self: Answer) !std.json.ObjectMap {
        return switch (self) {
            .json => |value| value.object,
            .err => |err| {
                std.debug.print("unexpected error: {s} {s}\n", .{ @tagName(err.code), err.message });
                return error.UnexpectedError;
            },
        };
    }

    fn failure(self: Answer) !api.Error {
        return switch (self) {
            .err => |err| err,
            .json => error.ExpectedError,
        };
    }
};

fn field(object: std.json.ObjectMap, name: []const u8) std.json.Value {
    return object.get(name) orelse .null;
}

fn ids(items: std.json.Value, arena: std.mem.Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (items.array.items) |item| try out.append(arena, item.object.get("id").?.string);
    return out.items;
}

test "history pages through a ref's first-parent log newest first, keyed by commit" {
    var t: TestRepo(.git) = undefined;
    try t.init();
    defer t.deinit();
    const aa = t.arena.allocator();

    // 22 commits on master, the 21st a merge of a side commit
    var oids: [22]TestRepo(.git).Oid = undefined;
    oids[0] = try t.commit(.{ .message = "root", .timestamp = 1000 });
    const side = try t.repo.commitAtRef(std.testing.io, std.testing.allocator, .{ .author = "bob <bob@example.test>", .message = "side work", .parent_oids = &.{oids[0]}, .allow_empty = true, .timestamp = 1001 }, null, .{ .kind = .head, .name = "side" });
    for (1..22) |i| {
        const message = try std.fmt.allocPrint(aa, "change {d}\n\nmore about it", .{i});
        oids[i] = if (i == 20)
            try t.commit(.{ .message = "merge side", .parent_oids = &.{ oids[19], side }, .timestamp = 1000 + i * 10 })
        else
            try t.commit(.{ .message = message, .timestamp = 1000 + i * 10 });
    }

    const first = try (try t.list(.local, "")).ok();
    // the default branch, named explicitly
    const ref = field(first, "ref").object;
    try std.testing.expectEqualStrings("branch", field(ref, "kind").string);
    try std.testing.expectEqualStrings("master", field(ref, "name").string);
    try std.testing.expectEqualStrings("branch:master", field(ref, "id").string);
    try std.testing.expectEqualStrings(&oids[21], field(ref, "commit").string);

    // the TUI's page of 20, newest first
    const items = field(first, "items");
    try std.testing.expectEqual(20, items.array.items.len);
    for (try ids(items, aa), 0..) |id, i| try std.testing.expectEqualStrings(&oids[21 - i], id);
    const newest = items.array.items[0].object;
    try std.testing.expectEqualStrings("change 21", field(newest, "summary").string);
    try std.testing.expectEqualStrings(&oids[20], field(newest, "parent").string);
    try std.testing.expectEqualStrings("1970-01-01T00:20:10Z", field(newest, "committed_at").string);
    try std.testing.expectEqual(false, field(newest, "merge").bool);
    // a git repo has no statistics: unavailable, never zero
    try std.testing.expectEqual(std.json.Value.null, field(newest, "stats"));
    const merge = items.array.items[1].object;
    try std.testing.expectEqualStrings("merge side", field(merge, "summary").string);
    try std.testing.expectEqual(true, field(merge, "merge").bool);

    // the cursor names the next page's first commit
    const page = field(first, "page").object;
    try std.testing.expectEqual(true, field(page, "has_more").bool);
    try std.testing.expectEqualStrings(&oids[1], field(page, "next_cursor").string);
    try std.testing.expectEqualStrings("unknown", field(field(page, "count").object, "kind").string);

    // the walk follows first parents only, so the side commit never shows
    const second = try (try t.list(.local, try std.fmt.allocPrint(aa, "cursor={s}", .{field(page, "next_cursor").string}))).ok();
    try std.testing.expectEqualDeep(&[_][]const u8{ &oids[1], &oids[0] }, try ids(field(second, "items"), aa));
    try std.testing.expectEqual(std.json.Value.null, field(field(second, "page").object, "next_cursor"));
    try std.testing.expectEqual(std.json.Value.null, field(field(second, "items").array.items[1].object, "parent"));

    // a page size up to 100
    const small = try (try t.list(.local, "page_size=5")).ok();
    try std.testing.expectEqual(5, field(small, "items").array.items.len);
    try std.testing.expectEqualStrings(&oids[16], field(field(small, "page").object, "next_cursor").string);
    try std.testing.expectEqual(22, field(try (try t.list(.local, "page_size=500")).ok(), "items").array.items.len);

    // a cursor is a commit of this repo, as haxy gave it out
    for ([_][]const u8{ "cursor=zz", "cursor=%zz", "cursor=0000000000000000000000000000000000000000", "cursor=ABCDEF0000000000000000000000000000000000" }) |query| {
        const err = try (try t.list(.local, query)).failure();
        try std.testing.expectEqual(.validation, err.code);
        try std.testing.expectEqualStrings("cursor", err.field_errors[0].field);
    }
    try std.testing.expectEqualStrings("page_size", (try (try t.list(.local, "page_size=0")).failure()).field_errors[0].field);
}

test "commits show their committer only when it isn't the author" {
    var t: TestRepo(.xit) = undefined;
    try t.init();
    defer t.deinit();

    const root = try t.commit(.{ .message = "root", .timestamp = 100 });
    const applied = try t.commit(.{ .message = "applied", .committer = "carol <carol@example.test>", .timestamp = 200 });
    _ = try t.commit(.{ .message = "same\n\nbody", .author = "alice <alice@example.test>", .committer = "alice <alice@example.test>", .timestamp = 300 });

    const list = try (try t.list(.server, "")).ok();
    const items = field(list, "items").array.items;
    try std.testing.expectEqual(3, items.len);
    try std.testing.expectEqualStrings("same", field(items[0].object, "summary").string);
    try std.testing.expectEqualStrings("email", field(field(items[0].object, "author").object, "kind").string);
    try std.testing.expectEqual(std.json.Value.null, field(items[0].object, "committer"));
    try std.testing.expectEqualStrings(&applied, field(items[1].object, "id").string);
    try std.testing.expectEqualStrings("alice@example.test", field(field(items[1].object, "author").object, "email").string);
    try std.testing.expectEqualStrings("carol@example.test", field(field(items[1].object, "committer").object, "email").string);
    try std.testing.expectEqual(std.json.Value.null, field(items[2].object, "committer"));
    try std.testing.expectEqualStrings(&root, field(items[2].object, "id").string);

    // statistics come with pushed commits (see the e2e suite); these were
    // committed in place, so they have none, which is unavailable, not zero
    try std.testing.expectEqual(std.json.Value.null, field(items[2].object, "stats"));
    try std.testing.expectEqualStrings("unknown", field(field(field(list, "page").object, "count").object, "kind").string);
}

test "commit text that isn't utf-8 is shown with U+FFFD" {
    var t: TestRepo(.git) = undefined;
    try t.init();
    defer t.deinit();
    const oid = try t.commit(.{ .message = "caf\xe9\n\nna\xefve", .author = "al <al\xffice@example.test>", .timestamp = 100 });

    const item = field(try (try t.list(.local, "")).ok(), "items").array.items[0].object;
    try std.testing.expectEqualStrings("caf\u{FFFD}", field(item, "summary").string);
    try std.testing.expectEqualStrings("al\u{FFFD}ice@example.test", field(field(item, "author").object, "email").string);
    const one = try (try t.one(&oid)).ok();
    try std.testing.expectEqualStrings("caf\u{FFFD}\n\nna\u{FFFD}ve", field(one, "message").string);
}

test "commit search is offered on a server where the ref's tip is indexed, and unavailable elsewhere" {
    var t: TestRepo(.xit) = undefined;
    try t.init();
    defer t.deinit();
    const aa = t.arena.allocator();

    const root = try t.commit(.{ .message = "add the parser", .timestamp = 100 });
    _ = try t.commit(.{ .message = "fix the parser", .timestamp = 200 });
    const tip = try t.commit(.{ .message = "document the lexer", .timestamp = 300 });

    // no index yet: unavailable, which isn't the same as no matches
    const unindexed = field(try (try t.list(.server, "")).ok(), "search").object;
    try std.testing.expectEqual(false, field(unindexed, "available").bool);
    try std.testing.expectEqualStrings("unsupported", field(field(unindexed, "reason").object, "code").string);
    const refused = try (try t.list(.server, "search=parser")).failure();
    try std.testing.expectEqual(.unsupported, refused.code);

    try t.index();
    const indexed = try (try t.list(.server, "")).ok();
    try std.testing.expectEqual(true, field(field(indexed, "search").object, "available").bool);
    try std.testing.expectEqualStrings("branch:master", field(field(indexed, "search").object, "ref").string);
    try std.testing.expectEqual(std.json.Value.null, field(indexed, "query"));

    // words match by prefix, newest first, a page at a time
    const found = try (try t.list(.server, "search=pars&page_size=1")).ok();
    try std.testing.expectEqualStrings("pars", field(found, "query").string);
    try std.testing.expectEqualDeep(&[_][]const u8{"fix the parser"}, &[_][]const u8{field(field(found, "items").array.items[0].object, "summary").string});
    const next = field(field(found, "page").object, "next_cursor").string;
    try std.testing.expectEqualStrings("unknown", field(field(field(found, "page").object, "count").object, "kind").string);
    const rest = try (try t.list(.server, try std.fmt.allocPrint(aa, "search=pars&page_size=1&cursor={s}", .{next}))).ok();
    try std.testing.expectEqualDeep(&[_][]const u8{&root}, try ids(field(rest, "items"), aa));
    try std.testing.expectEqual(std.json.Value.null, field(field(rest, "page").object, "next_cursor"));
    try std.testing.expectEqual(0, field(try (try t.list(.server, "search=nothing")).ok(), "items").array.items.len);

    // a commit's history is searched on the default branch
    const at_commit = field(try (try t.list(.server, try std.fmt.allocPrint(aa, "ref=commit:{s}", .{&root}))).ok(), "search").object;
    try std.testing.expectEqualStrings("branch:master", field(at_commit, "ref").string);
    try std.testing.expectEqual(.unsupported, (try (try t.list(.server, try std.fmt.allocPrint(aa, "ref=commit:{s}&search=parser", .{&tip}))).failure()).code);

    // local mode offers no commit search, as the TUI has no search box there
    const local = field(try (try t.list(.local, "")).ok(), "search").object;
    try std.testing.expectEqual(false, field(local, "available").bool);
    try std.testing.expectEqual(.unsupported, (try (try t.list(.local, "search=parser")).failure()).code);
}

test "a commit opens with its whole message, up to the commits tab's limit" {
    var t: TestRepo(.git) = undefined;
    try t.init();
    defer t.deinit();
    const aa = t.arena.allocator();

    // longer than the tab's 50-line preview
    var long: std.Io.Writer.Allocating = .init(aa);
    try long.writer.writeAll("subject\n");
    for (0..80) |i| try long.writer.print("\nline {d}", .{i});
    const whole = try t.commit(.{ .message = long.written(), .timestamp = 100 });
    // longer than the 100 KiB a message is read up to, ending mid-character
    const huge = try aa.alloc(u8, ui.Repo.Commits.max_message_size + 10);
    @memset(huge, 'x');
    @memcpy(huge[ui.Repo.Commits.max_message_size - 1 ..][0.."\u{e9}".len], "\u{e9}");
    const cut = try t.commit(.{ .message = huge, .timestamp = 200 });

    const one = try (try t.one(&whole)).ok();
    try std.testing.expectEqualStrings(&whole, field(one, "id").string);
    try std.testing.expectEqualStrings("subject", field(one, "summary").string);
    try std.testing.expectEqualStrings(std.mem.trim(u8, long.written(), "\n"), field(one, "message").string);
    try std.testing.expectEqual(false, field(one, "message_truncated").bool);
    try std.testing.expectEqual(std.json.Value.null, field(one, "parent"));

    const truncated = try (try t.one(&cut)).ok();
    try std.testing.expectEqual(true, field(truncated, "message_truncated").bool);
    // cut at the limit, without the half character
    try std.testing.expectEqual(ui.Repo.Commits.max_message_size - 1, field(truncated, "message").string.len);
    try std.testing.expectEqualStrings(&whole, field(truncated, "parent").string);

    // anything but a full commit id of this repo is no commit
    var tree_oid: [40]u8 = undefined;
    {
        var moment = try t.repo.core.latestMoment();
        const state = TestRepo(.git).Repo.State(.read_only){ .core = &t.repo.core, .extra = .{ .moment = &moment } };
        var object = try xit.object.Object(.git, TestRepo(.git).opts).init(state, std.testing.io, std.testing.allocator, &whole);
        defer object.deinit();
        tree_oid = object.content.commit.tree;
    }
    for ([_][]const u8{ "", "abc", whole[0..39], "0000000000000000000000000000000000000000", "ABCDEF0000000000000000000000000000000000", &tree_oid }) |oid| {
        const err = try (try t.one(oid)).failure();
        try std.testing.expectEqual(.not_found, err.code);
    }
}

test "a log pinned to the commit its ref resolved to walks from it, even after the ref moved" {
    var t: TestRepo(.xit) = undefined;
    try t.init();
    defer t.deinit();
    const resolved = try t.commit(.{ .message = "resolved", .timestamp = 100 });
    const snapshot = try t.repo.core.latestMoment();
    // a push lands between resolving the branch and reading its log
    _ = try t.commit(.{ .message = "pushed meanwhile", .timestamp = 200 });

    const data = try ui.Repo.Commits.initWindow(.xit, TestRepo(.xit).opts, &t.arena, &t.repo, std.testing.io, std.testing.allocator, null, .{ .location = .{ .repo = "" } }, null, "", false, "", "", "", 20, .{ .ref_or_oid = .branch, .value = "master", .oid = &resolved, .moment = snapshot });
    try std.testing.expectEqual(1, data.commits.len);
    try std.testing.expectEqualStrings(&resolved, data.commits[0].oid);
    try std.testing.expectEqual(.branch, data.ref_or_oid);
}

test "a request reads one snapshot of the repo, even when a push lands while it reads" {
    var t: TestRepo(.xit) = undefined;
    try t.init();
    defer t.deinit();
    const aa = t.arena.allocator();
    const root = try t.commit(.{ .message = "add the parser", .timestamp = 100 });
    const old_tip = try t.commit(.{ .message = "fix the parser", .timestamp = 200 });
    try t.index();
    const snapshot = try t.repo.core.latestMoment();

    // a push lands: the branch moves, and the index drops the old tip's version
    _ = try t.commit(.{ .message = "document the parser", .timestamp = 300 });
    try t.index();

    // the request's snapshot still names the old tip, its log, its index and its count
    const list = try (try t.listAt(snapshot, "")).ok();
    try std.testing.expectEqualStrings(&old_tip, field(field(list, "ref").object, "commit").string);
    try std.testing.expectEqualDeep(&[_][]const u8{ &old_tip, &root }, try ids(field(list, "items"), aa));
    try std.testing.expectEqual(true, field(field(list, "history").object, "available").bool);
    try std.testing.expectEqual(true, field(field(list, "search").object, "available").bool);
    const found = try (try t.listAt(snapshot, "search=parser")).ok();
    try std.testing.expectEqualDeep(&[_][]const u8{ &old_tip, &root }, try ids(field(found, "items"), aa));

    // a fresh request sees the push
    try std.testing.expectEqual(3, field(try (try t.list(.server, "")).ok(), "items").array.items.len);
}
