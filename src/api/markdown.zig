//! markdown as JSON: the blocks `markdown.zig` parses, so a client shows the
//! same structure the TUI does. every variant carries a `kind` field.

const std = @import("std");
const md = @import("../markdown.zig");

const Error = std.Io.Writer.Error;

/// serializes as an array of blocks
pub const Blocks = struct {
    blocks: []const md.Block,

    pub fn jsonStringify(self: Blocks, json: *std.json.Stringify) Error!void {
        try writeBlocks(json, self.blocks);
    }
};

fn writeBlocks(json: *std.json.Stringify, blocks: []const md.Block) Error!void {
    try json.beginArray();
    for (blocks) |block| try writeBlock(json, block);
    try json.endArray();
}

fn writeBlock(json: *std.json.Stringify, block: md.Block) Error!void {
    try json.beginObject();
    try json.objectField("kind");
    try json.write(@tagName(block));
    switch (block) {
        .heading => |heading| {
            try json.objectField("level");
            try json.write(heading.level);
            try json.objectField("center");
            try json.write(heading.center);
            try writeInlines(json, heading.inlines);
        },
        .paragraph => |paragraph| {
            try json.objectField("center");
            try json.write(paragraph.center);
            try json.objectField("pre");
            try json.write(paragraph.pre);
            try writeInlines(json, paragraph.inlines);
        },
        .code, .raw => |lines| {
            try json.objectField("lines");
            try json.write(lines);
        },
        .quote => |blocks| {
            try json.objectField("blocks");
            try writeBlocks(json, blocks);
        },
        .list => |list| {
            try json.objectField("ordered");
            try json.write(list.ordered);
            // the first number of an ordered list; 0 for an unordered one
            try json.objectField("start");
            try json.write(list.start);
            try json.objectField("items");
            try json.beginArray();
            for (list.items) |item| {
                try json.beginObject();
                try json.objectField("task");
                try json.write(item.task);
                try json.objectField("blocks");
                try writeBlocks(json, item.blocks);
                try json.endObject();
            }
            try json.endArray();
        },
        .rule => {},
    }
    try json.endObject();
}

fn writeInlines(json: *std.json.Stringify, inlines: []const md.Inline) Error!void {
    try json.objectField("inlines");
    try json.beginArray();
    for (inlines) |run| {
        try json.write(.{
            .text = run.text,
            .bold = run.style.bold,
            .italic = run.style.italic,
            .strike = run.style.strike,
            .code = run.style.code,
            .link = run.link,
        });
    }
    try json.endArray();
}
