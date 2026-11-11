//! drives the web ui as a browser would: request bytes in, response bytes out,
//! through web.serveConnection, on a host over temp data. a test acts through
//! requests and observes only responses.
//!
//!     test "web: a taken repo name comes back with the form filled in" {
//!         const server = try h.Server.init(.sha1);
//!         defer server.deinit();
//!         var alice = try server.clientAs("alice");
//!         defer alice.deinit();
//!
//!         const r = try alice.post("/home/repo/new", &.{
//!             .{ "name", "open" }, .{ "description", "again" }, .{ "hash", "sha1" }, .{ "access", "public" },
//!         });
//!         defer r.deinit();
//!         try r.expectRedirect("/home/repo/new");
//!         const page = try alice.followJson(r);
//!         defer page.deinit();
//!         try page.expectJson("session.form_feedback.repo.failure", "name_taken");
//!         try page.expectJson("session.form_feedback.repo.fields.name", "open");
//!     }
//!
//! hosts: `Server.init(hash_kind)`: alice (owns public `open`, private
//! `secret`), bob (write on both), carol (a stranger), dave (granted write,
//! then removed), password `password`; ids, `open`, `secret`, `admin`,
//! `users_dir`, `admin_repo_path`, `host()` for arranging data.
//! `Local(.git|.xit).init()`: one commit, committer `tester`.
//! clients (own cookie jar; no Expires, Domain, Secure or positive Max-Age):
//! `server.client()`, `server.clientAs("bob")`, `server.mintSession(&c, id)`,
//! `local.client()`. `get`, `getJson`, `post(path, fields)`, `postWithheld`
//! (body declared, never sent), `postWith(path, fields, .{ .headers,
//! .between, .withhold_body })`, `send(.{ .method, .path, .headers, .body })`,
//! `sendAll(requests, .one_by_one | .buffered)` for one keep-alive connection,
//! `follow`/`followJson`. a null header value drops a default. `.between =
//! .init(&ctx, run)` runs after the head, before the body (`r.hook_ran`).
//! responses (`deinit` each): `status`, `body`, `header`, `headerValues`,
//! `jsonAt("a.b.0")`, `server_log`, `reads_after_head`; `expectStatus`,
//! `expectRedirect`, `expectBody`, `expectJson(path, "s"|null|true|3)`,
//! `expectJsonHas`, `expectJsonLen`, `expectBodyContains`, `expectBodyLacks`,
//! `expectBodyUnread`, `expectConnectionClose`. only flushed bytes count.

const std = @import("std");
const xit = @import("xit");
const web = @import("../../web.zig");
const evt = @import("../../event.zig");
const rp = xit.repo;
const hash = xit.hash;

const io = std.testing.io;
const gpa = std.testing.allocator;

pub const Id = [evt.event_id_size]u8;
pub const password = "password";
pub const host_name = "haxy.test";

// a server data dir with the cast the domain tests also use
pub const Server = struct {
    temp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    admin: rp.Repo(.xit, evt.admin_repo_opts),
    admin_repo_path: []const u8,
    users_dir: []const u8,
    session_store: web.SessionStore,
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

    // heap allocated so the clients' host and the admin repo stay put
    pub fn init(comptime hash_kind: hash.HashKind) !*Server {
        const self = try gpa.create(Server);
        errdefer gpa.destroy(self);
        self.temp = std.testing.tmpDir(.{});
        errdefer self.temp.cleanup();
        self.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena.deinit();
        const aa = self.arena.allocator();
        const base = try self.temp.dir.realPathFileAlloc(io, ".", aa);
        self.users_dir = try std.Io.Dir.path.join(aa, &.{ base, "users" });
        self.admin_repo_path = try std.Io.Dir.path.join(aa, &.{ base, "admin" });
        self.admin = try evt.initAdminRepo(io, gpa, self.admin_repo_path);
        errdefer self.admin.deinit(io, gpa);
        self.session_store = try web.SessionStore.init(io, self.temp.dir);
        errdefer self.session_store.deinit();

        self.alice = try self.createUser(alice_author);
        self.bob = try self.createUser(bob_author);
        self.carol = try self.createUser(carol_author);
        self.dave = try self.createUser(dave_author);

        self.open = try evt.createRepo(io, gpa, self.users_dir, &self.alice, alice_author, "open", "", .public, hash_kind, null);
        self.secret = try evt.createRepo(io, gpa, self.users_dir, &self.alice, alice_author, "secret", "", .private, hash_kind, null);
        for ([_]evt.RepoLocation{ self.open, self.secret }) |location| {
            for ([_]*const Id{ &self.bob, &self.dave }) |user| {
                try evt.grantRole(io, gpa, self.users_dir, &self.alice, &location.repo_id, user, .write, alice_author);
            }
        }
        try evt.deleteUser(io, gpa, self.users_dir, &self.admin, &self.dave, dave_author);
        return self;
    }

    // an account with the cast's password
    pub fn createUser(self: *Server, author: evt.CommitAuthor) !Id {
        return try evt.createUser(io, gpa, self.users_dir, &self.admin, author.name, author.email, password, password);
    }

    pub fn deinit(self: *Server) void {
        self.session_store.deinit();
        self.admin.deinit(io, gpa);
        self.arena.deinit();
        self.temp.cleanup();
        gpa.destroy(self);
    }

    pub fn host(self: *const Server) web.Host {
        return .{ .server = .{
            .admin_repo_path = self.admin_repo_path,
            .users_dir = self.users_dir,
            .session_store = self.session_store,
            .web_url = "http://" ++ host_name,
            .ssh_url = null,
            .git_ssh_prefix = "",
            .serve_git = refuseGit,
        } };
    }

    // a logged-out browser
    pub fn client(self: *const Server) Client {
        return Client.init(self.host());
    }

    // a browser logged in as `name` with the cast's password, through the login form
    pub fn clientAs(self: *const Server, name: []const u8) !Client {
        var result = self.client();
        errdefer result.deinit();
        try result.login(name, password);
        return result;
    }

    // give `c` a session for `user` straight from the store, as if it had
    // logged in before the account changed
    pub fn mintSession(self: *const Server, c: *Client, user: Id) !void {
        const token = try self.session_store.create(&user);
        try c.setCookie("haxy_session", &token, "/");
    }
};

// git over http is not this harness's seam
fn refuseGit(_: std.Io, _: std.mem.Allocator, _: []const u8, _: []const u8, _: *std.http.Server, request: *std.http.Server.Request, _: *std.Io.Writer) anyerror!void {
    std.debug.print("unexpected git request: {s}\n", .{request.head.target});
    return error.TestUnexpectedGitRequest;
}

pub const local_author: evt.CommitAuthor = .{ .name = "tester", .email = "tester@example.test" };

// a temp local repo with one commit on master and a committer identity, the
// way `haxy` with no arguments serves one
pub fn Local(comptime kind: rp.RepoKind) type {
    return struct {
        temp: std.testing.TmpDir,
        path: [:0]const u8,

        const Self = @This();
        pub const repo_opts: rp.RepoOpts(kind) = .{};

        pub fn init() !Self {
            var temp = std.testing.tmpDir(.{});
            errdefer temp.cleanup();
            const path = try temp.dir.realPathFileAlloc(io, ".", gpa);
            errdefer gpa.free(path);
            var repo = try rp.Repo(kind, repo_opts).init(io, gpa, .{ .path = path });
            defer repo.deinit(io, gpa);
            try repo.addConfig(io, gpa, .{ .name = "user.name", .value = local_author.name });
            try repo.addConfig(io, gpa, .{ .name = "user.email", .value = local_author.email });
            {
                const file = try repo.core.work_dir.createFile(io, "readme.txt", .{});
                defer file.close(io);
                try file.writeStreamingAll(io, "hello\n");
            }
            try repo.add(io, gpa, &.{"readme.txt"});
            _ = try repo.commit(io, gpa, .{ .message = "first", .author = "tester <tester@example.test>" });
            return .{ .temp = temp, .path = path };
        }

        pub fn deinit(self: *Self) void {
            gpa.free(self.path);
            self.temp.cleanup();
        }

        pub fn host(self: *const Self) web.Host {
            return .{ .local = .{ .path = self.path, .repo_kind = kind } };
        }

        pub fn client(self: *const Self) Client {
            return Client.init(self.host());
        }
    };
}

// a header the client sends; a null value drops one it would send by default
pub const Header = struct { name: []const u8, value: ?[]const u8 };

// what runs between the server reading a request's head and its body. it may
// make requests of its own with other clients.
pub const Hook = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque) anyerror!void,

    pub fn init(context: anytype, comptime run: fn (@TypeOf(context)) anyerror!void) Hook {
        const Context = @TypeOf(context);
        return .{ .context = @ptrCast(context), .run = struct {
            fn call(pointer: *anyopaque) anyerror!void {
                return run(@as(Context, @ptrCast(@alignCast(pointer))));
            }
        }.call };
    }
};

pub const Request = struct {
    method: []const u8 = "GET",
    path: []const u8,
    // added after the defaults, replacing one of the same name
    headers: []const Header = &.{},
    // sent with a form content-type and its length unless headers say otherwise
    body: ?[]const u8 = null,
    between: ?Hook = null,
    // declare the body but never send it, as a client that stalls would: any
    // read past the head counts in the response's `reads_after_head`
    withhold_body: bool = false,
};

pub const PostOptions = struct {
    headers: []const Header = &.{},
    between: ?Hook = null,
    withhold_body: bool = false,
};

pub const Field = struct { []const u8, []const u8 };

// how the requests of one connection reach the server
pub const Delivery = enum {
    // each head in its own read, then its body in the next
    one_by_one,
    // every byte already in the reader's buffer when the server starts
    buffered,
};

// the responses of one connection, in order
pub const Responses = struct {
    items: []*Response,

    pub fn deinit(self: Responses) void {
        for (self.items) |r| r.deinit();
        gpa.free(self.items);
    }
};

const Cookie = struct { name: []const u8, value: []const u8, path: []const u8 };

// a browser with a cookie jar. the jar keeps name, value and path, honours
// Path and Max-Age<=0; it does not model Expires, Domain, Secure or a
// positive Max-Age running out.
pub const Client = struct {
    host: web.Host,
    arena: std.heap.ArenaAllocator,
    cookies: std.ArrayList(Cookie),

    pub fn init(host: web.Host) Client {
        return .{ .host = host, .arena = std.heap.ArenaAllocator.init(gpa), .cookies = .empty };
    }

    pub fn deinit(self: *Client) void {
        self.cookies.deinit(gpa);
        self.arena.deinit();
    }

    pub fn get(self: *Client, path: []const u8) !*Response {
        return self.send(.{ .path = path });
    }

    // the page snapshot a third-party frontend renders from
    pub fn getJson(self: *Client, path: []const u8) !*Response {
        return self.send(.{ .path = path, .headers = &.{.{ .name = "accept", .value = "application/json" }} });
    }

    // a urlencoded form post, as a browser submits one
    pub fn post(self: *Client, path: []const u8, fields: []const Field) !*Response {
        return self.postWith(path, fields, .{});
    }

    // a form post whose body is declared but never sent; a prompt refusal
    // answers without asking for it (see `expectBodyUnread`)
    pub fn postWithheld(self: *Client, path: []const u8, fields: []const Field) !*Response {
        return self.postWith(path, fields, .{ .withhold_body = true });
    }

    pub fn postWith(self: *Client, path: []const u8, fields: []const Field, options: PostOptions) !*Response {
        var body: std.Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        try encodeForm(&body.writer, fields);
        return self.send(.{ .method = "POST", .path = path, .headers = options.headers, .body = body.written(), .between = options.between, .withhold_body = options.withhold_body });
    }

    // GET where a redirect points, with this client's cookies
    pub fn follow(self: *Client, r: *const Response) !*Response {
        return self.get(try redirectTarget(r));
    }

    pub fn followJson(self: *Client, r: *const Response) !*Response {
        return self.getJson(try redirectTarget(r));
    }

    // log in through the login form on the home user tab
    pub fn login(self: *Client, name: []const u8, pass: []const u8) !void {
        const r = try self.post("/home/user/login", &.{ .{ "username", name }, .{ "password", pass } });
        defer r.deinit();
        try r.expectStatus(.see_other);
        if (self.cookie("haxy_session") == null) {
            std.debug.print("logging in as {s} set no session cookie\n", .{name});
            return error.TestExpectedSession;
        }
    }

    // the value of the cookie `name` the jar holds, under any path
    pub fn cookie(self: *const Client, name: []const u8) ?[]const u8 {
        for (self.cookies.items) |c| if (std.mem.eql(u8, c.name, name)) return c.value;
        return null;
    }

    pub fn setCookie(self: *Client, name: []const u8, value: []const u8, path: []const u8) !void {
        const aa = self.arena.allocator();
        for (self.cookies.items) |*c| if (std.mem.eql(u8, c.name, name) and std.mem.eql(u8, c.path, path)) {
            c.value = try aa.dupe(u8, value);
            return;
        };
        try self.cookies.append(gpa, .{ .name = try aa.dupe(u8, name), .value = try aa.dupe(u8, value), .path = try aa.dupe(u8, path) });
    }

    fn removeCookie(self: *Client, name: []const u8, path: []const u8) void {
        for (self.cookies.items, 0..) |c, i| if (std.mem.eql(u8, c.name, name) and std.mem.eql(u8, c.path, path)) {
            _ = self.cookies.orderedRemove(i);
            return;
        };
    }

    // one connection carrying one request
    pub fn send(self: *Client, request: Request) !*Response {
        const responses = try self.sendAll(&.{request}, .one_by_one);
        defer gpa.free(responses.items);
        if (responses.items.len == 1) return responses.items[0];
        std.debug.print("{s} {s} got no response\n", .{ request.method, request.path });
        return error.TestExpectedResponse;
    }

    // one connection carrying several requests, as a keep-alive browser sends
    // them. the responses come back in order; a request the server never
    // answered has none, so there may be fewer responses than requests.
    pub fn sendAll(self: *Client, requests: []const Request, delivery: Delivery) !Responses {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const aa = arena.allocator();

        const wires = try aa.alloc(Wire, requests.len);
        for (requests, wires) |request, *wire| {
            if (delivery == .buffered and (request.between != null or request.withhold_body)) return error.TestBufferedCannotPause;
            wire.* = .{ .head = try self.writeHead(aa, request), .body = request.body orelse "", .hook = request.between, .withhold = request.withhold_body };
        }

        var in: WireReader = .{
            .wires = wires,
            .interface = .{ .vtable = &.{ .stream = WireReader.stream }, .buffer = undefined, .seek = 0, .end = 0 },
        };
        switch (delivery) {
            .one_by_one => {
                in.interface.buffer = try aa.alloc(u8, 4096);
                if (wires.len != 0) in.head = wires[0].head;
                if (wires.len != 0) in.body = wires[0].body;
            },
            .buffered => {
                var all: std.ArrayList(u8) = .empty;
                for (wires) |wire| {
                    try all.appendSlice(aa, wire.head);
                    try all.appendSlice(aa, wire.body);
                }
                try all.ensureTotalCapacity(aa, 4096);
                in.interface.buffer = all.allocatedSlice();
                in.interface.end = all.items.len;
                in.index = wires.len;
            },
        }
        var out_buffer: [4096]u8 = undefined;
        var out: Capture = .{ .interface = .{ .vtable = &.{ .drain = Capture.drain }, .buffer = &out_buffer } };
        defer out.bytes.deinit(gpa);
        var log: std.Io.Writer.Allocating = .init(gpa);
        defer log.deinit();

        const served = web.serveConnection(io, gpa, &in.interface, &out.interface, self.host, &log.writer);
        for (wires) |wire| if (wire.hook_err) |err| {
            std.debug.print("the hook between head and body failed: {t}\n", .{err});
            return err;
        };
        served catch |err| {
            std.debug.print("the connection failed: {t}\nserver log:\n{s}\n", .{ err, log.written() });
            return err;
        };
        // only what the server flushed reached the client
        if (out.interface.end != 0) {
            std.debug.print("the server left {d} bytes unflushed:\n{s}\n", .{ out.interface.end, out.interface.buffer[0..out.interface.end] });
            return error.TestUnflushedResponse;
        }

        var responses: std.ArrayList(*Response) = .empty;
        errdefer {
            for (responses.items) |r| r.deinit();
            responses.deinit(gpa);
        }
        var rest: []const u8 = out.bytes.items;
        while (rest.len != 0) {
            if (responses.items.len == requests.len) {
                std.debug.print("bytes after the last response:\n{s}\n", .{rest});
                return error.TestTrailingResponseBytes;
            }
            const i = responses.items.len;
            var used: usize = undefined;
            const r = try Response.parseOne(rest, log.written(), std.mem.eql(u8, requests[i].method, "HEAD"), &used, true);
            rest = rest[used..];
            r.hook_ran = wires[i].hook_ran;
            r.reads_after_head = wires[i].reads_after_head;
            try responses.append(gpa, r);
            try self.keepCookies(r, pathOf(requests[i].path));
        }
        for (wires[responses.items.len..]) |wire| if (wire.reads_after_head != 0) {
            std.debug.print("the server read {d} times past the head of an unanswered request whose body was withheld\nserver log:\n{s}\n", .{ wire.reads_after_head, log.written() });
        };
        return .{ .items = try responses.toOwnedSlice(gpa) };
    }

    // the request line and headers: the defaults, then the test's over them
    fn writeHead(self: *const Client, aa: std.mem.Allocator, request: Request) ![]const u8 {
        var head: std.Io.Writer.Allocating = .init(aa);
        const w = &head.writer;
        try w.print("{s} {s} HTTP/1.1\r\n", .{ request.method, request.path });
        var headers: std.ArrayList(Header) = .empty;
        var cookie_line: std.Io.Writer.Allocating = .init(aa);
        try self.writeCookies(&cookie_line.writer, pathOf(request.path));
        try headers.append(aa, .{ .name = "host", .value = host_name });
        if (cookie_line.written().len != 0) try headers.append(aa, .{ .name = "cookie", .value = cookie_line.written() });
        if (request.body) |body| {
            try headers.append(aa, .{ .name = "content-type", .value = "application/x-www-form-urlencoded" });
            try headers.append(aa, .{ .name = "content-length", .value = try std.fmt.allocPrint(aa, "{d}", .{body.len}) });
        }
        for (request.headers) |extra| {
            const replaced = for (headers.items) |*existing| {
                if (std.ascii.eqlIgnoreCase(existing.name, extra.name)) {
                    existing.value = extra.value;
                    break true;
                }
            } else false;
            if (!replaced) try headers.append(aa, extra);
        }
        for (headers.items) |header| if (header.value) |value| try w.print("{s}: {s}\r\n", .{ header.name, value });
        try w.writeAll("\r\n");
        return head.written();
    }

    // the cookie header for `path`: the cookies whose path covers it, longest
    // path first, as browsers send them
    pub fn writeCookies(self: *const Client, w: *std.Io.Writer, path: []const u8) !void {
        var matching: std.ArrayList(Cookie) = .empty;
        defer matching.deinit(gpa);
        for (self.cookies.items) |c| if (pathMatches(c.path, path)) try matching.append(gpa, c);
        std.mem.sort(Cookie, matching.items, {}, struct {
            fn longer(_: void, a: Cookie, b: Cookie) bool {
                return a.path.len > b.path.len;
            }
        }.longer);
        for (matching.items, 0..) |c, i| {
            if (i != 0) try w.writeAll("; ");
            try w.print("{s}={s}", .{ c.name, c.value });
        }
    }

    // take in every set-cookie line of a response to a request for `request_path`
    pub fn keepCookies(self: *Client, r: *const Response, request_path: []const u8) !void {
        for (r.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, "set-cookie")) try self.keepCookie(header.value, request_path);
    }

    // take in one set-cookie line answered to a request for `request_path`
    pub fn keepCookie(self: *Client, line: []const u8, request_path: []const u8) !void {
        var parts = std.mem.splitScalar(u8, line, ';');
        const pair = std.mem.trim(u8, parts.first(), " ");
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return;
        const name = pair[0..eq];
        const value = pair[eq + 1 ..];
        // rfc 6265's default path: the request path up to its last slash
        const default_path: []const u8 = if (std.mem.lastIndexOfScalar(u8, request_path, '/')) |slash| (if (slash == 0) "/" else request_path[0..slash]) else "/";
        var path = default_path;
        var expired = false;
        while (parts.next()) |raw| {
            const attribute = std.mem.trim(u8, raw, " ");
            const attribute_eq = std.mem.indexOfScalar(u8, attribute, '=') orelse continue;
            const key = attribute[0..attribute_eq];
            const attribute_value = attribute[attribute_eq + 1 ..];
            // an empty or relative path falls back to the default, as browsers do
            if (std.ascii.eqlIgnoreCase(key, "path")) path = if (attribute_value.len != 0 and attribute_value[0] == '/') attribute_value else default_path;
            if (std.ascii.eqlIgnoreCase(key, "max-age")) expired = (std.fmt.parseInt(i64, attribute_value, 10) catch 1) <= 0;
        }
        if (expired) self.removeCookie(name, path) else try self.setCookie(name, value, path);
    }
};

// a request target without its query
fn pathOf(target: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;
}

fn pathMatches(cookie_path: []const u8, request_path: []const u8) bool {
    if (cookie_path.len == 0) return false;
    if (!std.mem.startsWith(u8, request_path, cookie_path)) return false;
    if (request_path.len == cookie_path.len) return true;
    return cookie_path[cookie_path.len - 1] == '/' or request_path[cookie_path.len] == '/';
}

// form fields urlencoded as a browser submits them
pub fn encodeForm(w: *std.Io.Writer, fields: []const Field) !void {
    for (fields, 0..) |field, i| {
        if (i != 0) try w.writeByte('&');
        try formEncode(w, field[0]);
        try w.writeByte('=');
        try formEncode(w, field[1]);
    }
}

fn formEncode(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try w.writeByte(c),
        ' ' => try w.writeByte('+'),
        else => try w.print("%{X:0>2}", .{c}),
    };
}

fn redirectTarget(r: *const Response) ![]const u8 {
    if (r.status.class() != .redirect) {
        r.describe();
        std.debug.print("expected a redirect to follow, got {d}\n", .{@intFromEnum(r.status)});
        return error.TestExpectedRedirect;
    }
    return r.header("location") orelse {
        r.describe();
        std.debug.print("expected a location to follow\n", .{});
        return error.TestExpectedLocation;
    };
}

// one request as it goes over the wire
const Wire = struct {
    head: []const u8,
    body: []const u8,
    hook: ?Hook,
    withhold: bool,
    hook_ran: bool = false,
    hook_err: ?anyerror = null,
    reads_after_head: usize = 0,
};

// gives the server each request's head in one read and its body in the next,
// running a request's hook when the server first asks for more than its head
const WireReader = struct {
    interface: std.Io.Reader,
    wires: []Wire,
    index: usize = 0,
    head: []const u8 = "",
    body: []const u8 = "",

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *WireReader = @alignCast(@fieldParentPtr("interface", r));
        while (self.index < self.wires.len) {
            const wire = &self.wires[self.index];
            if (self.head.len != 0) {
                const n = try w.write(limit.sliceConst(self.head));
                self.head = self.head[n..];
                return n;
            }
            // past this request's head
            if (wire.withhold) {
                wire.reads_after_head += 1;
                return error.ReadFailed;
            }
            if (wire.hook) |hook| {
                wire.hook = null;
                wire.hook_ran = true;
                hook.run(hook.context) catch |err| {
                    wire.hook_err = err;
                    return error.ReadFailed;
                };
            }
            if (self.body.len != 0) {
                const n = try w.write(limit.sliceConst(self.body));
                self.body = self.body[n..];
                return n;
            }
            // on to the next request on this connection
            self.index += 1;
            if (self.index < self.wires.len) {
                self.head = self.wires[self.index].head;
                self.body = self.wires[self.index].body;
            }
        }
        return error.EndOfStream;
    }
};

// keeps only what the server flushed: bytes still in the buffer when the
// connection ends never reached the client
const Capture = struct {
    interface: std.Io.Writer,
    bytes: std.ArrayList(u8) = .empty,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Capture = @alignCast(@fieldParentPtr("interface", w));
        self.bytes.appendSlice(gpa, w.buffer[0..w.end]) catch return error.WriteFailed;
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            self.bytes.appendSlice(gpa, slice) catch return error.WriteFailed;
            n += slice.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| self.bytes.appendSlice(gpa, last) catch return error.WriteFailed;
        return n + last.len * splat;
    }
};

pub const Response = struct {
    arena: *std.heap.ArenaAllocator,
    status: std.http.Status,
    headers: []const std.http.Header,
    body: []const u8,
    // the parsed body when the server answered with json
    json: ?std.json.Value,
    // what the server wrote to its error writer during the connection
    server_log: []const u8,
    // whether a hook given to the request ran
    hook_ran: bool = false,
    // how often the server asked for bytes past the head of a request whose
    // body was withheld
    reads_after_head: usize = 0,

    // exactly one response, nothing before or after it. quiet on failure, for
    // tests of the parser itself
    pub fn parse(bytes: []const u8, log: []const u8, is_head: bool) !*Response {
        var used: usize = undefined;
        const self = try parseOne(bytes, log, is_head, &used, false);
        if (used == bytes.len) return self;
        self.deinit();
        return error.TestTrailingResponseBytes;
    }

    // the response at the start of `bytes`, setting `used` to its length
    fn parseOne(bytes: []const u8, log: []const u8, is_head: bool, used: *usize, loud: bool) !*Response {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        errdefer {
            arena.deinit();
            gpa.destroy(arena);
        }
        const aa = arena.allocator();
        const self = try aa.create(Response);
        errdefer if (loud) std.debug.print("could not parse the response:\n{s}\nserver log:\n{s}\n", .{ bytes, log });

        const head_end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.TestResponseTruncated;
        var lines = std.mem.splitSequence(u8, bytes[0..head_end], "\r\n");
        const code = try parseStatusLine(lines.first());

        var headers: std.ArrayList(std.http.Header) = .empty;
        var content_length: ?usize = null;
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.TestBadHeader;
            const name = line[0..colon];
            if (name.len == 0) return error.TestBadHeader;
            for (name) |c| if (!isTokenChar(c)) return error.TestBadHeader;
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            for (value) |c| if ((c < 0x20 and c != '\t') or c == 0x7f) return error.TestBadHeader;
            const field: std.http.Header = .{ .name = try aa.dupe(u8, name), .value = try aa.dupe(u8, value) };
            try headers.append(aa, field);
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                const length = std.fmt.parseInt(usize, value, 10) catch return error.TestBadHeader;
                if (content_length) |earlier| if (earlier != length) return error.TestConflictingContentLength;
                content_length = length;
            }
            if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                // the web ui answers with content-length only; teach the harness when that changes
                std.debug.print("unparsed transfer-encoding: {s}\n", .{value});
                return error.TestUnsupportedTransferEncoding;
            }
        }
        const rest = bytes[head_end + 4 ..];
        const body_len: usize = if (is_head) 0 else content_length orelse return error.TestMissingContentLength;
        if (rest.len < body_len) return error.TestResponseTruncated;
        const body = try aa.dupe(u8, rest[0..body_len]);
        used.* = head_end + 4 + body_len;

        self.* = .{
            .arena = arena,
            .status = @enumFromInt(code),
            .headers = headers.items,
            .body = body,
            .json = null,
            .server_log = try aa.dupe(u8, log),
        };
        if (self.header("content-type")) |content_type| if (std.mem.startsWith(u8, content_type, "application/json")) {
            self.json = try std.json.parseFromSliceLeaky(std.json.Value, aa, body, .{});
        };
        return self;
    }

    // "HTTP/1.1 " then a three-digit code, then nothing or a space and a reason
    fn parseStatusLine(line: []const u8) !u10 {
        const prefix = "HTTP/1.1 ";
        if (!std.mem.startsWith(u8, line, prefix) or line.len < prefix.len + 3) return error.TestBadStatusLine;
        const digits = line[prefix.len..][0..3];
        for (digits) |c| if (!std.ascii.isDigit(c)) return error.TestBadStatusLine;
        const code = std.fmt.parseInt(u10, digits, 10) catch return error.TestBadStatusLine;
        if (code < 100 or code > 599) return error.TestBadStatusLine;
        const reason = line[prefix.len + 3 ..];
        if (reason.len != 0 and reason[0] != ' ') return error.TestBadStatusLine;
        for (reason) |c| if ((c < 0x20 and c != '\t') or c == 0x7f) return error.TestBadStatusLine;
        return code;
    }

    fn isTokenChar(c: u8) bool {
        return switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
            else => false,
        };
    }

    pub fn deinit(self: *const Response) void {
        const arena = self.arena;
        arena.deinit();
        gpa.destroy(arena);
    }

    // the first value of the header `name`
    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {
        for (self.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    // every value of the header `name`, as for several set-cookie lines
    pub fn headerValues(self: *const Response, name: []const u8) ![]const []const u8 {
        var values: std.ArrayList([]const u8) = .empty;
        for (self.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) try values.append(self.arena.allocator(), h.value);
        return values.items;
    }

    // the json value at a dotted path, where a number indexes an array; null
    // when the path is missing
    pub fn jsonAt(self: *const Response, path: []const u8) ?std.json.Value {
        var value = self.json orelse return null;
        if (path.len == 0) return value;
        var segments = std.mem.splitScalar(u8, path, '.');
        while (segments.next()) |segment| {
            value = switch (value) {
                .object => |object| object.get(segment) orelse return null,
                .array => |array| blk: {
                    const index = std.fmt.parseInt(usize, segment, 10) catch return null;
                    if (index >= array.items.len) return null;
                    break :blk array.items[index];
                },
                else => return null,
            };
        }
        return value;
    }

    pub fn expectStatus(self: *const Response, expected: std.http.Status) !void {
        if (self.status == expected) return;
        self.describe();
        std.debug.print("expected status {d}, got {d}\n", .{ @intFromEnum(expected), @intFromEnum(self.status) });
        return error.TestExpectedEqual;
    }

    // a 303 to `location`
    pub fn expectRedirect(self: *const Response, location: []const u8) !void {
        try self.expectStatus(.see_other);
        const actual = self.header("location") orelse "(none)";
        if (std.mem.eql(u8, actual, location)) return;
        self.describe();
        std.debug.print("expected a redirect to \"{s}\", got \"{s}\"\n", .{ location, actual });
        return error.TestExpectedEqual;
    }

    // the body is exactly `text`
    pub fn expectBody(self: *const Response, text: []const u8) !void {
        if (std.mem.eql(u8, self.body, text)) return;
        self.describe();
        std.debug.print("expected the body \"{s}\"\n", .{text});
        return error.TestExpectedEqual;
    }

    // the server answered without asking for the withheld body
    pub fn expectBodyUnread(self: *const Response) !void {
        if (self.reads_after_head == 0) return;
        self.describe();
        std.debug.print("the server read {d} times past the head of a request whose body was withheld\n", .{self.reads_after_head});
        return error.TestBodyRead;
    }

    // the server closes the connection after this response
    pub fn expectConnectionClose(self: *const Response) !void {
        if (self.header("connection")) |value| if (std.ascii.eqlIgnoreCase(value, "close")) return;
        self.describe();
        std.debug.print("expected connection: close\n", .{});
        return error.TestExpectedClose;
    }

    // the json at `path` is `expected`: a string, null, a bool or an integer
    pub fn expectJson(self: *const Response, path: []const u8, expected: anytype) !void {
        const actual = self.jsonAt(path) orelse {
            self.describe();
            std.debug.print("expected json at \"{s}\", found nothing there\n", .{path});
            return error.TestExpectedJson;
        };
        const Expected = @TypeOf(expected);
        const matches = switch (@typeInfo(Expected)) {
            .null => actual == .null,
            .bool => actual == .bool and actual.bool == expected,
            .int, .comptime_int => actual == .integer and actual.integer == expected,
            else => actual == .string and std.mem.eql(u8, actual.string, @as([]const u8, expected)),
        };
        if (matches) return;
        self.describe();
        var shown: std.Io.Writer.Allocating = .init(gpa);
        defer shown.deinit();
        std.json.Stringify.value(actual, .{}, &shown.writer) catch {};
        switch (@typeInfo(Expected)) {
            .null, .bool, .int, .comptime_int => std.debug.print("expected json at \"{s}\" to be {any}, got {s}\n", .{ path, expected, shown.written() }),
            else => std.debug.print("expected json at \"{s}\" to be \"{s}\", got {s}\n", .{ path, @as([]const u8, expected), shown.written() }),
        }
        return error.TestExpectedEqual;
    }

    // something, even null, is at `path`
    pub fn expectJsonHas(self: *const Response, path: []const u8) !void {
        if (self.jsonAt(path) != null) return;
        self.describe();
        std.debug.print("expected json at \"{s}\", found nothing there\n", .{path});
        return error.TestExpectedJson;
    }

    // an array of `len` items is at `path`
    pub fn expectJsonLen(self: *const Response, path: []const u8, len: usize) !void {
        const actual = self.jsonAt(path) orelse {
            self.describe();
            std.debug.print("expected an array at \"{s}\", found nothing there\n", .{path});
            return error.TestExpectedJson;
        };
        if (actual == .array and actual.array.items.len == len) return;
        self.describe();
        if (actual == .array) {
            std.debug.print("expected {d} items at \"{s}\", got {d}\n", .{ len, path, actual.array.items.len });
        } else {
            std.debug.print("expected an array at \"{s}\", got a {t}\n", .{ path, actual });
        }
        return error.TestExpectedEqual;
    }

    pub fn expectBodyContains(self: *const Response, text: []const u8) !void {
        if (std.mem.indexOf(u8, self.body, text) != null) return;
        self.describe();
        std.debug.print("expected the body to contain \"{s}\"\n", .{text});
        return error.TestExpectedText;
    }

    pub fn expectBodyLacks(self: *const Response, text: []const u8) !void {
        if (std.mem.indexOf(u8, self.body, text) == null) return;
        self.describe();
        std.debug.print("expected the body not to contain \"{s}\"\n", .{text});
        return error.TestUnexpectedText;
    }

    // print the response for a failing test: html bodies are long, so cut
    pub fn describe(self: *const Response) void {
        std.debug.print("response {d}\n", .{@intFromEnum(self.status)});
        for (self.headers) |h| std.debug.print("{s}: {s}\n", .{ h.name, h.value });
        const limit = 4000;
        const session = self.jsonAt("session");
        if (session != null and session.? == .object) {
            // the session is what form tests look at; the art in it is noise
            var shown: std.Io.Writer.Allocating = .init(gpa);
            defer shown.deinit();
            var copy = session.?.object.clone(gpa) catch return;
            defer copy.deinit(gpa);
            _ = copy.orderedRemove("ansi_art");
            std.json.Stringify.value(std.json.Value{ .object = copy }, .{}, &shown.writer) catch {};
            std.debug.print("\nsession: {s}\n", .{shown.written()});
            if (self.jsonAt("page")) |page| {
                shown.clearRetainingCapacity();
                std.json.Stringify.value(page, .{}, &shown.writer) catch {};
                const text = shown.written();
                std.debug.print("page: {s}{s}\n", .{ text[0..@min(text.len, limit)], if (text.len > limit) " (cut)" else "" });
            }
        } else {
            std.debug.print("\n{s}{s}\n", .{ self.body[0..@min(self.body.len, limit)], if (self.body.len > limit) "\n(cut)" else "" });
        }
        if (self.server_log.len != 0) std.debug.print("server log:\n{s}\n", .{self.server_log});
    }
};

// commit `contents` as the file `file_name` on `branch` of a server repo,
// starting the branch from master when it doesn't exist yet and leaving master
// checked out, so a patch has branches to name. a first commit to an empty
// repo goes on master.
pub fn commitOnBranch(server: *const Server, location: evt.RepoLocation, branch: []const u8, file_name: []const u8, contents: []const u8) !void {
    const path = try evt.repoPath(gpa, server.users_dir, &location.owner_id, &location.repo_id);
    defer gpa.free(path);
    var any_repo = try rp.AnyRepo(.xit, .{}).open(io, gpa, .{ .path = path });
    defer any_repo.deinit(io, gpa);
    switch (any_repo) {
        inline else => |*repo| {
            // server repos are bare, so give this one a worktree for the commit
            try repo.addConfig(io, gpa, .{ .name = "core.bare", .value = "false" });
            defer repo.addConfig(io, gpa, .{ .name = "core.bare", .value = "true" }) catch {};
            const on_master = std.mem.eql(u8, branch, "master");
            if (!on_master) {
                if (try repo.readRef(io, .{ .kind = .head, .name = branch }) == null) try repo.addBranch(io, .{ .name = branch });
                var selected = try repo.switchDir(io, gpa, .{ .target = .{ .ref = .{ .kind = .head, .name = branch } } });
                selected.deinit();
            }
            {
                const file = try repo.core.work_dir.createFile(io, file_name, .{ .truncate = true });
                defer file.close(io);
                try file.writeStreamingAll(io, contents);
            }
            try repo.add(io, gpa, &.{file_name});
            _ = try repo.commit(io, gpa, .{ .message = contents, .author = "tester <tester@example.test>" });
            if (!on_master) {
                var restored = try repo.switchDir(io, gpa, .{ .target = .{ .ref = .{ .kind = .head, .name = "master" } } });
                restored.deinit();
            }
        },
    }
}
