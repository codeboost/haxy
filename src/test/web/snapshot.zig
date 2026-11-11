//! whole-page snapshots of the web ui's json, compared with recorded goldens.
//! a page's json is taken with `getJson`, its status, content type and route
//! checked, then canonicalized: object keys sorted, arrays kept in order,
//! pretty-printed one value per line.
//!
//! what varies from run to run is fixed at arrangement rather than normalised:
//! `Det.io` is the test io with the wall clock frozen at a time the world sets
//! and ids drawn from a prng the world reseeds before each step, so event ids,
//! commit oids and every timestamp a form stamps come out the same each run.
//! what is still rewritten, each rule narrow and explicit:
//!
//! | value                         | treatment                                    |
//! |-------------------------------|----------------------------------------------|
//! | `session.now`                 | must be an integer; becomes "<now>"          |
//! | `session.ansi_art`            | must be a string; becomes "<ansi_art>"       |
//! | a registered id or oid (hex)  | every occurrence in a string value or object |
//! |                               | key becomes its name, as "<issue:leaky-roof>"|
//! | a registered id's raw bytes   | a whole value that is those 16 bytes, as a   |
//! |                               | string or an array of numbers (zig's json of |
//! |                               | a byte slice), becomes "<bytes:user:alice>"  |
//!
//! the names make goldens readable and keep the id table honest: a value that
//! is not in the table is left as it is. nothing is replaced by pattern.
//!
//! goldens live in `src/test/web/golden/<world>/<name>.json`, read at run time
//! from the build root (where `zig build test` runs tests). to rewrite them:
//!
//!     HAXY_SNAPSHOT_UPDATE=1 zig build test -Dtest-filter="web: page snapshots"
//!
//! an environment variable rather than a build option, so these files import
//! nothing but std and the harness and still run against older trees. a
//! mismatch prints the first differing lines and leaves the whole actual
//! snapshot under `.zig-cache/snapshot-actual/<world>/<name>.json`.

const std = @import("std");
const h = @import("harness.zig");

const io = std.testing.io;
const gpa = std.testing.allocator;

pub const golden_dir = "src/test/web/golden";
pub const actual_dir = ".zig-cache/snapshot-actual";
pub const update_variable = "HAXY_SNAPSHOT_UPDATE";

// ---- a test io with a frozen wall clock and seeded randomness

// the clock and the prng are global to the test process, so the snapshot
// tests must run one at a time, as zig's test runner runs them; a world that
// ran beside another would draw from its clock and seed
pub const Det = struct {
    // the first step's time: 2023-11-14 22:13:20 utc
    pub const base_seconds: i64 = 1_700_000_000;

    var seconds: i64 = base_seconds;
    var prng: std.Random.DefaultPrng = .init(0);
    var vtable: std.Io.VTable = undefined;

    pub fn io() std.Io {
        vtable = std.testing.io.vtable.*;
        vtable.now = now;
        vtable.random = random;
        return .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    }

    // a fresh start, so each world starts from the same clock and seed
    pub fn reset() void {
        seconds = base_seconds;
        prng = .init(0);
    }

    // the wall clock reads `at` until moved again
    pub fn setClock(at: i64) void {
        seconds = at;
    }

    pub fn clock() i64 {
        return seconds;
    }

    // what follows draws its ids from `seed` alone, whatever drew before
    pub fn reseed(seed: u64) void {
        prng = .init(seed);
    }

    pub fn reseedText(text: []const u8) void {
        reseed(std.hash.Wyhash.hash(0, text));
    }

    fn now(userdata: ?*anyopaque, which: std.Io.Clock) std.Io.Timestamp {
        if (which == .real) return .{ .nanoseconds = @as(i96, seconds) * std.time.ns_per_s };
        return std.testing.io.vtable.now(userdata, which);
    }

    fn random(_: ?*anyopaque, buffer: []u8) void {
        prng.random().bytes(buffer);
    }
};

// ---- the table from real ids to stable names

pub const id_size = 16;

pub const Names = struct {
    arena: std.heap.ArenaAllocator,
    // hex text (event ids, commit oids) to its name, longest first when applied
    hex: std.ArrayList(Entry) = .empty,
    // a 16-byte id's raw bytes to its name
    raw: std.ArrayList(Raw) = .empty,

    const Entry = struct { real: []const u8, name: []const u8 };
    const Raw = struct { bytes: [id_size]u8, name: []const u8 };

    pub fn init() Names {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Names) void {
        self.hex.deinit(gpa);
        self.raw.deinit(gpa);
        self.arena.deinit();
    }

    // the name a hex value has, or null
    pub fn nameOf(self: *const Names, real: []const u8) ?[]const u8 {
        for (self.hex.items) |entry| if (std.mem.eql(u8, entry.real, real)) return entry.name;
        return null;
    }

    pub fn has(self: *const Names, real: []const u8) bool {
        return self.nameOf(real) != null;
    }

    fn nameTaken(self: *const Names, name: []const u8) bool {
        for (self.hex.items) |entry| if (std.mem.eql(u8, entry.name, name)) return true;
        return false;
    }

    // name `real`, a hex id or oid, as "<kind:label>". naming one value twice
    // or giving two values one name fails: the table is a bijection
    pub fn addHex(self: *Names, real: []const u8, kind: []const u8, label: []const u8) ![]const u8 {
        const aa = self.arena.allocator();
        const name = try std.fmt.allocPrint(aa, "<{s}:{s}>", .{ kind, label });
        if (self.nameOf(real)) |existing| {
            std.debug.print("{s} is named {s} already, not {s}\n", .{ real, existing, name });
            return error.TestNameTwice;
        }
        if (self.nameTaken(name)) {
            std.debug.print("the name {s} is taken, so {s} cannot have it\n", .{ name, real });
            return error.TestNameTaken;
        }
        if (real.len == 0) return error.TestEmptyName;
        for (real) |c| if (!std.ascii.isHex(c)) {
            std.debug.print("{s} is not hex\n", .{real});
            return error.TestNotHex;
        };
        try self.hex.append(gpa, .{ .real = try aa.dupe(u8, real), .name = name });
        return name;
    }

    // name `real` with the first of `label`, `label#2`, `label#3`... not taken
    pub fn addHexFresh(self: *Names, real: []const u8, kind: []const u8, label: []const u8) ![]const u8 {
        var buffer: [256]u8 = undefined;
        var n: usize = 1;
        while (true) : (n += 1) {
            const numbered = if (n == 1) label else try std.fmt.bufPrint(&buffer, "{s}#{d}", .{ label, n });
            const name = try std.fmt.bufPrint(buffer[128..], "<{s}:{s}>", .{ kind, numbered });
            if (!self.nameTaken(name)) return self.addHex(real, kind, numbered);
        }
    }

    // name a 16-byte id, both as hex and as its raw bytes
    pub fn addId(self: *Names, bytes: *const [id_size]u8, kind: []const u8, label: []const u8) ![]const u8 {
        const name = try self.addHex(&std.fmt.bytesToHex(bytes.*, .lower), kind, label);
        try self.raw.append(gpa, .{ .bytes = bytes.*, .name = name });
        return name;
    }

    // name a 16-byte id given as hex, also as its raw bytes
    pub fn addIdHex(self: *Names, real: []const u8, kind: []const u8, label: []const u8) ![]const u8 {
        var bytes: [id_size]u8 = undefined;
        if (real.len != id_size * 2) return error.TestNotAnId;
        _ = try std.fmt.hexToBytes(&bytes, real);
        return self.addId(&bytes, kind, label);
    }

    pub fn addIdHexFresh(self: *Names, real: []const u8, kind: []const u8, label: []const u8) ![]const u8 {
        const name = try self.addHexFresh(real, kind, label);
        var bytes: [id_size]u8 = undefined;
        _ = try std.fmt.hexToBytes(&bytes, real);
        try self.raw.append(gpa, .{ .bytes = bytes, .name = name });
        return name;
    }

    fn rawName(self: *const Names, bytes: []const u8) ?[]const u8 {
        if (bytes.len != id_size) return null;
        for (self.raw.items) |entry| if (std.mem.eql(u8, &entry.bytes, bytes)) return entry.name;
        return null;
    }

    // `text` with every registered hex value in it replaced by its name
    fn substitute(self: *const Names, aa: std.mem.Allocator, text: []const u8) ![]const u8 {
        var result = text;
        for (self.hex.items) |entry| {
            if (std.mem.indexOf(u8, result, entry.real) == null) continue;
            result = try std.mem.replaceOwned(u8, aa, result, entry.real, entry.name);
        }
        return result;
    }

    // longest values first, so no value is replaced inside a longer one
    pub fn seal(self: *Names) void {
        std.mem.sort(Entry, self.hex.items, {}, struct {
            fn longer(_: void, a: Entry, b: Entry) bool {
                return a.real.len > b.real.len;
            }
        }.longer);
    }
};

// ---- canonical form

const Rewrite = enum { none, now, ansi_art };

fn rewriteAt(path: []const []const u8) Rewrite {
    if (path.len != 2 or !std.mem.eql(u8, path[0], "session")) return .none;
    if (std.mem.eql(u8, path[1], "now")) return .now;
    if (std.mem.eql(u8, path[1], "ansi_art")) return .ansi_art;
    return .none;
}

// the bytes a json value holds when it is zig's serialization of a byte
// slice: a string, or an array of integers 0 to 255
fn rawBytes(aa: std.mem.Allocator, value: std.json.Value) !?[]const u8 {
    switch (value) {
        .string => |s| return s,
        .array => |a| {
            const bytes = try aa.alloc(u8, a.items.len);
            for (a.items, bytes) |item, *byte| {
                if (item != .integer or item.integer < 0 or item.integer > 255) return null;
                byte.* = @intCast(item.integer);
            }
            return bytes;
        },
        else => return null,
    }
}

const Canon = struct {
    aa: std.mem.Allocator,
    names: *const Names,
    path: std.ArrayList([]const u8) = .empty,

    fn value(self: *Canon, v: std.json.Value) !std.json.Value {
        switch (rewriteAt(self.path.items)) {
            .now => {
                if (v != .integer) return self.fail("session.now is not an integer", v);
                return .{ .string = "<now>" };
            },
            .ansi_art => {
                if (v != .string) return self.fail("session.ansi_art is not a string", v);
                return .{ .string = "<ansi_art>" };
            },
            .none => {},
        }
        // a registered id serialized as its raw bytes
        if (v == .array and v.array.items.len == id_size) if (try rawBytes(self.aa, v)) |bytes| if (self.names.rawName(bytes)) |name|
            return .{ .string = try std.fmt.allocPrint(self.aa, "<bytes:{s}", .{name[1..]}) };
        switch (v) {
            .string => |s| {
                if (self.names.rawName(s)) |name| return .{ .string = try std.fmt.allocPrint(self.aa, "<bytes:{s}", .{name[1..]}) };
                return .{ .string = try self.names.substitute(self.aa, s) };
            },
            .number_string => |s| return .{ .number_string = s },
            .array => |a| {
                var out = std.json.Array.init(self.aa);
                try out.ensureTotalCapacity(a.items.len);
                for (a.items) |item| {
                    try self.path.append(self.aa, "*");
                    defer _ = self.path.pop();
                    out.appendAssumeCapacity(try self.value(item));
                }
                return .{ .array = out };
            },
            .object => |o| {
                const Pair = struct { key: []const u8, value: std.json.Value };
                var pairs: std.ArrayList(Pair) = .empty;
                var it = o.iterator();
                while (it.next()) |entry| {
                    try self.path.append(self.aa, entry.key_ptr.*);
                    defer _ = self.path.pop();
                    try pairs.append(self.aa, .{ .key = try self.names.substitute(self.aa, entry.key_ptr.*), .value = try self.value(entry.value_ptr.*) });
                }
                std.mem.sort(Pair, pairs.items, {}, struct {
                    fn less(_: void, a: Pair, b: Pair) bool {
                        return std.mem.lessThan(u8, a.key, b.key);
                    }
                }.less);
                var out: std.json.ObjectMap = .empty;
                for (pairs.items) |pair| {
                    if (out.contains(pair.key)) return self.fail("two keys became one name", .{ .string = pair.key });
                    try out.put(self.aa, pair.key, pair.value);
                }
                return .{ .object = out };
            },
            else => return v,
        }
    }

    fn fail(self: *Canon, what: []const u8, v: std.json.Value) error{TestSnapshotShape} {
        std.debug.print("{s} at ", .{what});
        for (self.path.items, 0..) |segment, i| std.debug.print("{s}{s}", .{ if (i == 0) "" else ".", segment });
        std.debug.print(": {any}\n", .{v});
        return error.TestSnapshotShape;
    }
};

// the canonical text of a page's json
pub fn canonical(aa: std.mem.Allocator, names: *const Names, json: std.json.Value) ![]const u8 {
    var canon: Canon = .{ .aa = aa, .names = names };
    const rewritten = try canon.value(json);
    var out: std.Io.Writer.Allocating = .init(aa);
    try std.json.Stringify.value(rewritten, .{ .whitespace = .indent_1 }, &out.writer);
    try out.writer.writeByte('\n');
    return out.written();
}

// ---- comparing with goldens

pub fn updating() bool {
    var map = std.testing.environ.createMap(gpa) catch return false;
    defer map.deinit();
    const value = map.get(update_variable) orelse return false;
    return value.len != 0 and !std.mem.eql(u8, value, "0");
}

// what one world's snapshots found, reported together when it ends
pub const Report = struct {
    world: []const u8,
    arena: std.heap.ArenaAllocator,
    update: bool,
    taken: std.ArrayList([]const u8) = .empty,
    mismatched: std.ArrayList([]const u8) = .empty,
    written: usize = 0,

    pub fn init(world: []const u8) Report {
        return .{ .world = world, .arena = std.heap.ArenaAllocator.init(gpa), .update = updating() };
    }

    pub fn deinit(self: *Report) void {
        self.taken.deinit(gpa);
        self.mismatched.deinit(gpa);
        self.arena.deinit();
    }

    // compare `text` with the golden `name`, or write it when updating
    pub fn check(self: *Report, name: []const u8, text: []const u8) !void {
        const aa = self.arena.allocator();
        for (self.taken.items) |earlier| if (std.mem.eql(u8, earlier, name)) {
            std.debug.print("snapshot {s}/{s} is taken twice\n", .{ self.world, name });
            return error.TestSnapshotTwice;
        };
        try self.taken.append(gpa, try aa.dupe(u8, name));
        const sub_path = try std.fmt.allocPrint(aa, "{s}/{s}/{s}.json", .{ golden_dir, self.world, name });
        const cwd = std.Io.Dir.cwd();
        if (self.update) {
            const existing = cwd.readFileAlloc(io, sub_path, aa, .unlimited) catch null;
            if (existing != null and std.mem.eql(u8, existing.?, text)) return;
            try cwd.createDirPath(io, std.Io.Dir.path.dirname(sub_path).?);
            try cwd.writeFile(io, .{ .sub_path = sub_path, .data = text });
            self.written += 1;
            return;
        }
        const expected = cwd.readFileAlloc(io, sub_path, aa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("\nsnapshot {s}/{s}: no golden at {s}\n", .{ self.world, name, sub_path });
                try self.mismatch(name, text);
                return;
            },
            else => return err,
        };
        if (std.mem.eql(u8, expected, text)) return;
        std.debug.print("\nsnapshot {s}/{s} differs from {s}\n", .{ self.world, name, sub_path });
        printDiff(expected, text);
        try self.mismatch(name, text);
    }

    fn mismatch(self: *Report, name: []const u8, text: []const u8) !void {
        const aa = self.arena.allocator();
        try self.mismatched.append(gpa, try aa.dupe(u8, name));
        const sub_path = try std.fmt.allocPrint(aa, "{s}/{s}/{s}.json", .{ actual_dir, self.world, name });
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, std.Io.Dir.path.dirname(sub_path).?);
        try cwd.writeFile(io, .{ .sub_path = sub_path, .data = text });
        std.debug.print("  the actual snapshot is at {s}\n", .{sub_path});
    }

    // fail when anything differed, naming every snapshot that did
    pub fn finish(self: *Report) !void {
        if (self.update) {
            std.debug.print("world {s}: {d} snapshots, {d} goldens written\n", .{ self.world, self.taken.items.len, self.written });
            return;
        }
        if (self.mismatched.items.len == 0) return;
        std.debug.print("\nworld {s}: {d} of {d} snapshots differ:\n", .{ self.world, self.mismatched.items.len, self.taken.items.len });
        for (self.mismatched.items) |name| std.debug.print("  {s}\n", .{name});
        std.debug.print("rewrite the goldens with {s}=1 once the change is meant\n", .{update_variable});
        return error.TestSnapshotMismatch;
    }
};

// the first differing line of two texts, with a few lines either side
fn printDiff(expected: []const u8, actual: []const u8) void {
    var e_lines: std.ArrayList([]const u8) = .empty;
    defer e_lines.deinit(gpa);
    var a_lines: std.ArrayList([]const u8) = .empty;
    defer a_lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, expected, '\n');
    while (it.next()) |line| e_lines.append(gpa, line) catch return;
    it = std.mem.splitScalar(u8, actual, '\n');
    while (it.next()) |line| a_lines.append(gpa, line) catch return;
    var first: usize = 0;
    while (first < e_lines.items.len and first < a_lines.items.len and std.mem.eql(u8, e_lines.items[first], a_lines.items[first])) first += 1;
    // and the last, counting from the end, so an insertion shows as one
    var tail: usize = 0;
    while (tail < e_lines.items.len - first and tail < a_lines.items.len - first and
        std.mem.eql(u8, e_lines.items[e_lines.items.len - 1 - tail], a_lines.items[a_lines.items.len - 1 - tail])) tail += 1;
    const context = 3;
    const shown = 12;
    const from = first -| context;
    std.debug.print("  first difference at line {d} ({d} lines expected, {d} actual):\n", .{ first + 1, e_lines.items.len, a_lines.items.len });
    for (e_lines.items[from..first]) |line| std.debug.print("    {s}\n", .{line});
    const e_end = e_lines.items.len - tail;
    const a_end = a_lines.items.len - tail;
    for (e_lines.items[first..@min(e_end, first + shown)]) |line| std.debug.print("  - {s}\n", .{line});
    if (e_end > first + shown) std.debug.print("  - ({d} more)\n", .{e_end - first - shown});
    for (a_lines.items[first..@min(a_end, first + shown)]) |line| std.debug.print("  + {s}\n", .{line});
    if (a_end > first + shown) std.debug.print("  + ({d} more)\n", .{a_end - first - shown});
    for (a_lines.items[a_end..@min(a_lines.items.len, a_end + context)]) |line| std.debug.print("    {s}\n", .{line});
}

// ---- taking a snapshot

pub const Expect = struct {
    status: std.http.Status = .ok,
    // the route the session says the page is: a `session.current_page` tag
    route: []const u8,
};

// GET `path` as json and compare its canonical form with the golden `name`.
// the request draws its randomness from the snapshot's name, so what a page
// build draws does not depend on what ran before it
pub fn take(report: *Report, names: *const Names, c: *h.Client, name: []const u8, path: []const u8, expect: Expect) !void {
    Det.reseedText(name);
    const r = try c.getJson(path);
    defer r.deinit();
    if (r.status != expect.status) {
        r.describe();
        std.debug.print("snapshot {s}/{s}: GET {s} answered {d}, not {d}\n", .{ report.world, name, path, @backingInt(r.status), @backingInt(expect.status) });
        return error.TestSnapshotStatus;
    }
    const content_type = r.header("content-type") orelse "";
    if (!std.mem.eql(u8, content_type, "application/json") or r.json == null) {
        r.describe();
        std.debug.print("snapshot {s}/{s}: GET {s} is not json\n", .{ report.world, name, path });
        return error.TestSnapshotNotJson;
    }
    const route = r.jsonAt("session.current_page") orelse .null;
    const tag = if (route == .object and route.object.count() == 1) route.object.keys()[0] else if (route == .string) route.string else "";
    if (!std.mem.eql(u8, tag, expect.route)) {
        r.describe();
        std.debug.print("snapshot {s}/{s}: GET {s} is the page {s}, not {s}\n", .{ report.world, name, path, tag, expect.route });
        return error.TestSnapshotRoute;
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const text = try canonical(arena.allocator(), names, r.json.?);
    try report.check(name, text);
}
