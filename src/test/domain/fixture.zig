//! temp server data and temp local repos for the domain tests. every fixture
//! lives in a tmp dir it removes on deinit.

const std = @import("std");
const hx = @import("../../lib.zig");
const evt = hx.event;
const domain = hx.domain;
const xit = hx.xit;
const rp = xit.repo;
const hash = xit.hash;

const io = std.testing.io;
const allocator = std.testing.allocator;

pub const Id = [evt.event_id_size]u8;

// a server data dir holding:
// - alice, who created the public repo `alice:open` and the private repo
//   `alice:secret`, with their default tabs (the patch tab is off)
// - bob, granted write on both repos
// - carol, a stranger to both
// - dave, granted write on both repos and then removed
pub const Server = struct {
    temp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    admin: rp.Repo(.xit, evt.admin_repo_opts),
    users_dir: []const u8,
    alice: Id,
    bob: Id,
    carol: Id,
    dave: Id,
    open: evt.RepoLocation,
    secret: evt.RepoLocation,

    pub const alice_author: evt.CommitAuthor = .{ .name = "alice", .email = "alice@example.test" };
    pub const bob_author: evt.CommitAuthor = .{ .name = "bob", .email = "bob@example.test" };
    pub const carol_author: evt.CommitAuthor = .{ .name = "carol", .email = "carol@example.test" };
    pub const dave_author: evt.CommitAuthor = .{ .name = "dave", .email = "dave@example.test" };

    // heap allocated so the admin repo a Ctx points at stays put
    pub fn init(comptime hash_kind: hash.HashKind) !*Server {
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        self.temp = std.testing.tmpDir(.{});
        errdefer self.temp.cleanup();
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();
        const aa = self.arena.allocator();
        const base = try self.temp.dir.realPathFileAlloc(io, ".", aa);
        self.users_dir = try std.Io.Dir.path.join(aa, &.{ base, "users" });
        self.admin = try evt.initAdminRepo(io, allocator, try std.Io.Dir.path.join(aa, &.{ base, "admin" }));
        errdefer self.admin.deinit(io, allocator);

        self.alice = try createUser(self, alice_author);
        self.bob = try createUser(self, bob_author);
        self.carol = try createUser(self, carol_author);
        self.dave = try createUser(self, dave_author);

        self.open = try evt.createRepo(io, allocator, self.users_dir, &self.alice, alice_author, "open", "", .public, hash_kind, null);
        self.secret = try evt.createRepo(io, allocator, self.users_dir, &self.alice, alice_author, "secret", "", .private, hash_kind, null);
        for ([_]evt.RepoLocation{ self.open, self.secret }) |location| {
            for ([_]*const Id{ &self.bob, &self.dave }) |user| {
                try evt.grantRole(io, allocator, self.users_dir, &self.alice, &location.repo_id, user, .write, alice_author);
            }
        }
        try evt.deleteUser(io, allocator, self.users_dir, &self.admin, &self.dave, dave_author);
        return self;
    }

    fn createUser(self: *Server, author: evt.CommitAuthor) !Id {
        return try evt.createUser(io, allocator, self.users_dir, &self.admin, author.name, author.email, "password", "password");
    }

    pub fn deinit(self: *Server) void {
        self.admin.deinit(io, allocator);
        self.arena.deinit();
        self.temp.cleanup();
        allocator.destroy(self);
    }

    // a context acting as `user`, or logged out when null. results land in `arena`.
    pub fn ctx(self: *Server, arena: *std.heap.ArenaAllocator, user: ?Id) !domain.Ctx {
        return try domain.Ctx.initServer(io, allocator, arena, &self.admin, self.users_dir, user, 0);
    }

    // the on-disk path of a repo in the fixture
    pub fn repoPath(self: *Server, location: evt.RepoLocation) ![]const u8 {
        return try std.Io.Dir.path.join(self.arena.allocator(), &.{ self.users_dir, &std.fmt.bytesToHex(location.owner_id, .lower), "repos", &std.fmt.bytesToHex(location.repo_id, .lower) });
    }

    // add an issue authored by `author` to a repo, returning its id
    pub fn addIssue(self: *Server, location: evt.RepoLocation, author: evt.CommitAuthor, id: Id) !void {
        try self.addEvent(location, author, id, .{ .issue = .{ .title = "an issue", .description = "", .labels = "" } });
    }

    // add an event authored by `author` to a repo under the id `id`
    pub fn addEvent(self: *Server, location: evt.RepoLocation, author: evt.CommitAuthor, id: Id, event: evt.Event) !void {
        const path = try self.repoPath(location);
        var any_repo = try rp.AnyRepo(.xit, .{}).open(io, allocator, .{ .path = path });
        defer any_repo.deinit(io, allocator);
        switch (any_repo) {
            inline else => |*repo| try evt.consume(
                .{ .server = .{ .users_dir = self.users_dir, .admin_repo_path = self.admin.core.work_path } },
                .repo,
                .xit,
                repo.self_repo_opts,
                io,
                allocator,
                repo,
                evt.events_ref,
                &.{.{ .id = std.fmt.bytesToHex(id, .lower), .author = author, .event = event }},
            ),
        }
    }
};

// a temp local repo of `kind` and `hash_kind` with one commit on master, the
// way `haxy` with no arguments sees a repo
pub fn Local(comptime kind: rp.RepoKind, comptime hash_kind: hash.HashKind) type {
    return struct {
        temp: std.testing.TmpDir,
        path: [:0]const u8,
        // the oid master points at
        master_oid: [hash.hexLen(hash_kind)]u8,

        const Self = @This();
        pub const repo_opts: rp.RepoOpts(kind) = .{ .hash = hash_kind };

        pub fn init() !Self {
            var temp = std.testing.tmpDir(.{});
            errdefer temp.cleanup();
            const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
            errdefer allocator.free(path);
            var repo = try rp.Repo(kind, repo_opts).init(io, allocator, .{ .path = path });
            defer repo.deinit(io, allocator);
            {
                const file = try repo.core.work_dir.createFile(io, "readme.txt", .{});
                defer file.close(io);
                try file.writeStreamingAll(io, "hello\n");
            }
            try repo.add(io, allocator, &.{"readme.txt"});
            const oid = try repo.commit(io, allocator, .{ .message = "first", .author = "tester <tester@example.test>" });
            return .{ .temp = temp, .path = path, .master_oid = oid };
        }

        pub fn deinit(self: *Self) void {
            allocator.free(self.path);
            self.temp.cleanup();
        }

        pub fn source(self: *const Self) hx.ui.RepoSource {
            return .{ .path = self.path, .repo_kind = kind };
        }

        // set the repo's user.name and user.email
        pub fn setAuthor(self: *const Self, author: evt.CommitAuthor) !void {
            var repo = try rp.Repo(kind, repo_opts).open(io, allocator, .{ .path = self.path });
            defer repo.deinit(io, allocator);
            try repo.addConfig(io, allocator, .{ .name = "user.name", .value = author.name });
            try repo.addConfig(io, allocator, .{ .name = "user.email", .value = author.email });
        }

        // add an event to the events branch and consume it, as a write does
        pub fn addEvent(self: *const Self, author: evt.CommitAuthor, id: Id, event: evt.Event) !void {
            var repo = try rp.Repo(kind, repo_opts).open(io, allocator, .{ .path = self.path });
            defer repo.deinit(io, allocator);
            try evt.consume(.local, .repo, kind, repo_opts, io, allocator, &repo, evt.events_ref, &.{.{ .id = std.fmt.bytesToHex(id, .lower), .author = author, .event = event }});
        }

        // commit an event to a git repo's events branch without consuming it
        // into the event db next to the repo, as a fetch or a push from
        // elsewhere leaves it
        pub fn commitUnconsumed(self: *const Self, author: evt.CommitAuthor, id: Id, event: evt.Event) !void {
            if (kind != .git) @compileError("a xit repo consumes in the commit's transaction");
            var repo = try rp.Repo(kind, repo_opts).open(io, allocator, .{ .path = self.path });
            defer repo.deinit(io, allocator);
            try evt.commitEvents(kind, repo_opts, .{ .core = &repo.core, .extra = .{} }, io, allocator, evt.events_ref, &.{.{ .id = std.fmt.bytesToHex(id, .lower), .author = author, .event = event }}, null);
        }

        pub fn ctx(self: *const Self, arena: *std.heap.ArenaAllocator) domain.Ctx {
            return domain.Ctx.initLocal(io, allocator, arena, self.source(), 0);
        }
    };
}
