//! a repo's administration writes (roles, settings, protected branches) check
//! what they read inside the transaction that lands them, so a write that
//! raced another one, or an owner who lost the role meanwhile, changes
//! nothing.

const std = @import("std");
const evt = @import("../../event.zig");

const owner_author = evt.CommitAuthor{ .name = "alice", .email = "alice@example.test" };

const Fixture = struct {
    temp: std.testing.TmpDir,
    users_dir: []u8,
    owner_id: [evt.event_id_size]u8,
    repo_id: [evt.event_id_size]u8,
    // two other users
    bob: [evt.event_id_size]u8,
    carol: [evt.event_id_size]u8,

    fn init() !Fixture {
        const io = std.testing.io;
        const allocator = std.testing.allocator;
        var temp = std.testing.tmpDir(.{});
        errdefer temp.cleanup();
        const temp_path = try temp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(temp_path);
        const users_dir = try std.Io.Dir.path.join(allocator, &.{ temp_path, "users" });
        errdefer allocator.free(users_dir);

        var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
        const owner_id = evt.EventWithId.randomId(prng.random());
        {
            const path = try evt.userRepoPath(allocator, users_dir, &owner_id);
            defer allocator.free(path);
            var user_repo = try evt.initUserRepo(io, allocator, path);
            defer user_repo.deinit(io, allocator);
        }
        const created = try evt.createRepo(io, allocator, users_dir, &owner_id, owner_author, "tools", "", .private, .sha1, null);
        return .{
            .temp = temp,
            .users_dir = users_dir,
            .owner_id = owner_id,
            .repo_id = created.repo_id,
            .bob = evt.EventWithId.randomId(prng.random()),
            .carol = evt.EventWithId.randomId(prng.random()),
        };
    }

    fn deinit(self: *Fixture) void {
        std.testing.allocator.free(self.users_dir);
        self.temp.cleanup();
    }

    // `actor` sets `user`'s grant to `to`, expecting it to be `from`
    fn change(self: *Fixture, actor: *const [evt.event_id_size]u8, user: *const [evt.event_id_size]u8, from: ?evt.Repo.Role, to: ?evt.Repo.Role) !void {
        try evt.changeRole(std.testing.io, std.testing.allocator, self.users_dir, &self.owner_id, &self.repo_id, actor, user, from, to, owner_author, null);
    }

    fn role(self: *Fixture, user: *const [evt.event_id_size]u8) !?evt.Repo.Role {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var user_repo = (try evt.openUserRepo(std.testing.io, std.testing.allocator, self.users_dir, &self.owner_id)).?;
        defer user_repo.deinit(std.testing.io, std.testing.allocator);
        return try evt.Grant.readRole(evt.UserDB, evt.user_repo_opts.hash, (try evt.userMoment(&user_repo)).?, &arena, &self.repo_id, user);
    }

    // the repo's event as its owner's user repo holds it now, in `arena`
    fn repo(self: *Fixture, arena: *std.heap.ArenaAllocator) !evt.Repo {
        var user_repo = (try evt.openUserRepo(std.testing.io, std.testing.allocator, self.users_dir, &self.owner_id)).?;
        defer user_repo.deinit(std.testing.io, std.testing.allocator);
        return (try evt.Repo.readById(evt.UserDB, evt.user_repo_opts.hash, (try evt.userMoment(&user_repo)).?, arena, &self.repo_id)).?.event;
    }
};

test "the main owner grants, promotes, demotes and revokes, each change landing on the role it read" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.change(&f.owner_id, &f.bob, null, .write);
    try std.testing.expectEqual(.write, try f.role(&f.bob));
    try f.change(&f.owner_id, &f.bob, .write, .owner);
    try std.testing.expectEqual(.owner, try f.role(&f.bob));
    try f.change(&f.owner_id, &f.bob, .owner, .write);
    try std.testing.expectEqual(.write, try f.role(&f.bob));
    try f.change(&f.owner_id, &f.bob, .write, null);
    try std.testing.expectEqual(null, try f.role(&f.bob));
}

test "a promote that read a grant revoked meanwhile writes nothing, so the revoked user stays out" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.change(&f.owner_id, &f.bob, null, .write);
    // one owner read bob as a member; another revokes him first
    try f.change(&f.owner_id, &f.bob, .write, null);
    try std.testing.expectError(error.RoleChanged, f.change(&f.owner_id, &f.bob, .write, .owner));
    try std.testing.expectEqual(null, try f.role(&f.bob));
}

test "adding a member who was made an owner meanwhile doesn't demote them" {
    var f = try Fixture.init();
    defer f.deinit();
    // one owner read bob as holding no role; another adds and promotes him first
    try f.change(&f.owner_id, &f.bob, null, .owner);
    try std.testing.expectError(error.RoleChanged, f.change(&f.owner_id, &f.bob, null, .write));
    try std.testing.expectEqual(.owner, try f.role(&f.bob));
}

test "two revokes of one member: the second finds nothing to revoke" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.change(&f.owner_id, &f.bob, null, .write);
    try f.change(&f.owner_id, &f.bob, .write, null);
    try std.testing.expectError(error.RoleChanged, f.change(&f.owner_id, &f.bob, .write, null));
}

test "a granted owner may change roles until they lose ownership; then their writes land nothing" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.change(&f.owner_id, &f.bob, null, .owner);
    try f.change(&f.bob, &f.carol, null, .write);
    try std.testing.expectEqual(.write, try f.role(&f.carol));

    // bob was authorized as an owner, then demoted before his write landed
    try f.change(&f.owner_id, &f.bob, .owner, .write);
    try std.testing.expectError(error.NotOwner, f.change(&f.bob, &f.carol, .write, .owner));
    try std.testing.expectEqual(.write, try f.role(&f.carol));
    // a member who never owned can't either
    try std.testing.expectError(error.NotOwner, f.change(&f.carol, &f.carol, .write, .owner));
}

test "the main owner holds no grant, so no role change applies to them" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.change(&f.owner_id, &f.bob, null, .owner);
    try std.testing.expectError(error.MainOwner, f.change(&f.bob, &f.owner_id, .owner, .write));
    try std.testing.expectError(error.MainOwner, f.change(&f.bob, &f.owner_id, .owner, null));
    try std.testing.expectError(error.MainOwner, f.change(&f.bob, &f.owner_id, null, .write));
}

test "a repo change that read the repo before another change landed writes nothing" {
    var f = try Fixture.init();
    defer f.deinit();
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // a settings change reads the repo...
    const read = try f.repo(&arena);
    var changed = read;
    changed.description = "made public";
    changed.read_access = .public;
    // ...while an owner protects a branch
    try evt.protectBranch(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.owner_id, "main", true, owner_author, null);

    try std.testing.expectError(error.RepoChanged, evt.writeRepoChange(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.owner_id, read, changed, owner_author));
    const now = try f.repo(&arena);
    try std.testing.expectEqualStrings("main", now.protected_branches);
    try std.testing.expectEqual(.private, now.read_access);
}

test "settings changes and protections made one after another all stay" {
    var f = try Fixture.init();
    defer f.deinit();
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try evt.protectBranch(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.owner_id, "main", true, owner_author, null);
    try evt.updateRepo(io, allocator, f.users_dir, &f.owner_id, &f.owner_id, owner_author, "tools", "tools", "now public", .public, .read, null, .write, null);
    try evt.protectBranch(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.owner_id, "release", true, owner_author, null);

    const now = try f.repo(&arena);
    try std.testing.expectEqualStrings("main\nrelease", now.protected_branches);
    try std.testing.expectEqualStrings("now public", now.description);
    try std.testing.expectEqual(.public, now.read_access);
    try std.testing.expectEqual(null, now.issue_role);
    try std.testing.expectEqual(.write, now.patch_role);
}

test "a settings change or protection by an owner who lost the role meanwhile lands nothing" {
    var f = try Fixture.init();
    defer f.deinit();
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try f.change(&f.owner_id, &f.bob, null, .owner);
    try evt.updateRepo(io, allocator, f.users_dir, &f.owner_id, &f.bob, owner_author, "tools", "tools", "by bob", .private, .read, .read, null, null);
    try f.change(&f.owner_id, &f.bob, .owner, null);
    try std.testing.expectError(error.NotOwner, evt.updateRepo(io, allocator, f.users_dir, &f.owner_id, &f.bob, owner_author, "tools", "tools", "public now", .public, .read, .read, null, null));
    try std.testing.expectError(error.NotOwner, evt.protectBranch(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.bob, "main", true, owner_author, null));

    const now = try f.repo(&arena);
    try std.testing.expectEqualStrings("by bob", now.description);
    try std.testing.expectEqual(.private, now.read_access);
    try std.testing.expectEqualStrings("", now.protected_branches);
}

test "a settings change retried after a rename doesn't follow the old name to a repo that reused it" {
    var f = try Fixture.init();
    defer f.deinit();
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // between the change's read and its write, the repo is renamed and a new
    // repo takes its old name, so the write finds the repo changed and reads again
    const Interleaved = struct {
        inner: evt.SettingsChange,
        f: *Fixture,
        interleaved: *bool,

        pub fn apply(self: @This(), arena: std.mem.Allocator, before: evt.Repo) !?evt.Repo {
            if (!self.interleaved.*) {
                self.interleaved.* = true;
                try evt.updateRepo(io, allocator, self.f.users_dir, &self.f.owner_id, &self.f.owner_id, owner_author, "tools", "old-tools", before.description, before.read_access, before.discuss_role, before.issue_role, before.patch_role, null);
                _ = try evt.createRepo(io, allocator, self.f.users_dir, &self.f.owner_id, owner_author, "tools", "the new one", .private, .sha1, null);
            }
            return self.inner.apply(arena, before);
        }
    };
    var interleaved = false;
    const change: evt.SettingsChange = .{ .old_name = "tools", .name = "tools", .description = "made public", .read_access = .public, .discuss_role = .read, .issue_role = .read, .patch_role = null, .revision = null };
    try std.testing.expectError(error.NotFound, evt.changeRepo(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.owner_id, owner_author, Interleaved{ .inner = change, .f = &f, .interleaved = &interleaved }));
    try std.testing.expect(interleaved);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // the renamed repo keeps its rename, and the one that took the name is untouched
    const renamed = try f.repo(&arena);
    try std.testing.expectEqualStrings("old-tools", renamed.name);
    try std.testing.expectEqual(.private, renamed.read_access);
    var user_repo = (try evt.openUserRepo(io, allocator, f.users_dir, &f.owner_id)).?;
    defer user_repo.deinit(io, allocator);
    const reused = (try evt.Repo.readByName(evt.UserDB, evt.user_repo_opts.hash, (try evt.userMoment(&user_repo)).?, &arena, "tools")).?;
    try std.testing.expect(!std.mem.eql(u8, &reused.event_id, &f.repo_id));
    try std.testing.expectEqualStrings("the new one", reused.repo.event.description);
    try std.testing.expectEqual(.private, reused.repo.event.read_access);
}

test "a change outside the event history (moving HEAD) runs only while its actor still owns the repo" {
    var f = try Fixture.init();
    defer f.deinit();
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const Count = struct {
        runs: *usize,
        pub fn run(self: @This()) !void {
            self.runs.* += 1;
        }
    };
    var runs: usize = 0;
    try evt.whileOwner(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.owner_id, Count{ .runs = &runs }, null);
    try f.change(&f.owner_id, &f.bob, null, .owner);
    try evt.whileOwner(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.bob, Count{ .runs = &runs }, null);
    try std.testing.expectEqual(2, runs);

    // bob was authorized as an owner, then demoted before the move
    try f.change(&f.owner_id, &f.bob, .owner, .write);
    try std.testing.expectError(error.NotOwner, evt.whileOwner(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.bob, Count{ .runs = &runs }, null));
    try std.testing.expectError(error.NotOwner, evt.whileOwner(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.carol, Count{ .runs = &runs }, null));
    try std.testing.expectEqual(2, runs);

    // a deleted repo has nothing to change
    try evt.deleteRepo(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, owner_author, null);
    try std.testing.expectError(error.NotFound, evt.whileOwner(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.owner_id, Count{ .runs = &runs }, null));
    try std.testing.expectEqual(2, runs);
}

test "a settings change made from settings read before another owner's change writes nothing" {
    var f = try Fixture.init();
    defer f.deinit();
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // a form loads the settings...
    const loaded = (try f.repo(&arena)).settingsRevision();
    // ...another owner makes the repo public...
    try evt.updateRepo(io, allocator, f.users_dir, &f.owner_id, &f.owner_id, owner_author, "tools", "tools", "", .public, .read, .read, null, null);
    // ...and the form, changing only the description, saves what it loaded
    try std.testing.expectError(error.Stale, evt.updateRepo(io, allocator, f.users_dir, &f.owner_id, &f.owner_id, owner_author, "tools", "tools", "new words", .private, .read, .read, null, loaded));
    const now = try f.repo(&arena);
    try std.testing.expectEqual(.public, now.read_access);
    try std.testing.expectEqualStrings("", now.description);

    // saved against the current revision, it lands
    try evt.updateRepo(io, allocator, f.users_dir, &f.owner_id, &f.owner_id, owner_author, "tools", "tools", "new words", .public, .read, .read, null, now.settingsRevision());
    try std.testing.expectEqualStrings("new words", (try f.repo(&arena)).description);
}

test "the settings revision covers the settings, not the protected branches" {
    var f = try Fixture.init();
    defer f.deinit();
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const loaded = (try f.repo(&arena)).settingsRevision();
    try evt.protectBranch(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.owner_id, "main", true, owner_author, null);
    try std.testing.expectEqual(loaded, (try f.repo(&arena)).settingsRevision());
    try evt.updateRepo(io, allocator, f.users_dir, &f.owner_id, &f.owner_id, owner_author, "tools", "tools", "", .private, .read, null, null, loaded);
    try std.testing.expect(!std.mem.eql(u8, &loaded, &(try f.repo(&arena)).settingsRevision()));
    try std.testing.expectEqualStrings("main", (try f.repo(&arena)).protected_branches);
}

test "a protection or a default-branch move asked for by a name lands only while the repo still has it" {
    var f = try Fixture.init();
    defer f.deinit();
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const Count = struct {
        runs: *usize,
        pub fn run(self: @This()) !void {
            self.runs.* += 1;
        }
    };
    var runs: usize = 0;

    // both land while the repo is still named tools
    try evt.protectBranch(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.owner_id, "main", true, owner_author, "tools");
    try evt.whileOwner(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.owner_id, Count{ .runs = &runs }, "tools");
    try std.testing.expectEqual(1, runs);

    // the repo is renamed after a request resolved it as tools
    try evt.updateRepo(io, allocator, f.users_dir, &f.owner_id, &f.owner_id, owner_author, "tools", "old-tools", "", .private, .read, .read, null, null);
    try std.testing.expectError(error.NotFound, evt.protectBranch(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.owner_id, "release", true, owner_author, "tools"));
    try std.testing.expectError(error.NotFound, evt.protectBranch(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.owner_id, "main", false, owner_author, "tools"));
    try std.testing.expectError(error.NotFound, evt.whileOwner(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.owner_id, Count{ .runs = &runs }, "tools"));
    try std.testing.expectEqual(1, runs);
    try std.testing.expectEqualStrings("main", (try f.repo(&arena)).protected_branches);
}

test "a role change asked for by a name lands only while the repo still has it" {
    var f = try Fixture.init();
    defer f.deinit();
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    try evt.changeRole(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.owner_id, &f.bob, null, .write, owner_author, "tools");
    try std.testing.expectEqual(.write, try f.role(&f.bob));

    // another owner renames the repo after a request resolved it as tools
    try evt.updateRepo(io, allocator, f.users_dir, &f.owner_id, &f.owner_id, owner_author, "tools", "old-tools", "", .private, .read, .read, null, null);
    try std.testing.expectError(error.NotFound, evt.changeRole(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.owner_id, &f.bob, .write, .owner, owner_author, "tools"));
    try std.testing.expectError(error.NotFound, evt.changeRole(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.owner_id, &f.bob, .write, null, owner_author, "tools"));
    try std.testing.expectError(error.NotFound, evt.changeRole(io, allocator, f.users_dir, &f.owner_id, &f.repo_id, &f.owner_id, &f.carol, null, .write, owner_author, "tools"));
    try std.testing.expectEqual(.write, try f.role(&f.bob));
    try std.testing.expectEqual(null, try f.role(&f.carol));
}
