//! the stdio transport: one json-rpc message per line on stdin, one response
//! per line on stdout, diagnostics on stderr.

const std = @import("std");
const mcp = @import("../mcp.zig");

// the longest request line read, in bytes, without its newline
pub const max_line_len = 1 << 20;

// answer every line `in` holds until it ends. one call runs at a time.
pub fn run(server: *mcp.Server, in: *std.Io.Reader, out: *std.Io.Writer, err: *std.Io.Writer) !void {
    var line: std.Io.Writer.Allocating = .init(server.gpa);
    defer line.deinit();
    // each response is written to `out` whole, in one write, however `out`
    // is buffered
    var response: std.Io.Writer.Allocating = .init(server.gpa);
    defer response.deinit();
    while (true) {
        line.clearRetainingCapacity();
        // one byte past the bound tells a line at it from one over it
        _ = in.streamDelimiterLimit(&line.writer, '\n', .limited(max_line_len + 1)) catch |stream_err| switch (stream_err) {
            error.StreamTooLong => {
                try err.print("mcp: skipped a request line over {d} bytes\n", .{max_line_len});
                try err.flush();
                try mcp.jsonrpc.writeError(out, null, .parse_error, "parse error: line too long");
                try out.flush();
                // the rest of the line, up to and with its newline
                _ = in.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                    error.EndOfStream => return,
                    else => |e| return e,
                };
                continue;
            },
            else => |e| return e,
        };
        // the delimiter is next unless the stream ended
        const ended = in.bufferedLen() == 0;
        if (!ended) in.toss(1);
        if (std.mem.trim(u8, line.written(), " \t\r").len != 0) {
            response.clearRetainingCapacity();
            try server.handle(line.written(), &response.writer);
            try out.writeAll(response.written());
            try out.flush();
        }
        if (ended) return;
    }
}
