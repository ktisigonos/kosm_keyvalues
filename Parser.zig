//! Reads Valve's KeyValues into the tree kosm matches paths against. Hand-written: a file is
//! keys, each followed by a value or by a `{ ... }` block of more keys. Keys and values are
//! quoted strings or bare words; `//` starts a comment; a `[$WIN32]`-style conditional may
//! follow a value or block; `#base "file"` and `#include "file"` lines are directives. A key
//! written twice is two entries, so `set` refuses to pick one.

const Parser = @This();

const std = @import("std");
const kosm = @import("kosm");
const Node = kosm.Adapter.Node;
const Range = kosm.Adapter.Range;

allocator: std.mem.Allocator,
source: []const u8,
context: *kosm.Adapter.Context,
index: usize = 0,

const Error = kosm.Adapter.ParseError;

/// Deepest `{ ... }` nesting read, so a broken file can't exhaust the stack.
const max_depth = 128;

/// One token: its bytes in the file, and for strings the text between the quotes.
const Token = struct {
    kind: Kind,
    range: Range,
    text: []const u8,

    const Kind = enum { string, open, close, conditional, end };
};

/// An adapter `parser`: the file as one table. Nodes point into `source`.
pub fn parse(allocator: std.mem.Allocator, source: []const u8, context: *kosm.Adapter.Context) Error!Node {
    var parser: Parser = .{ .allocator = allocator, .source = source, .context = context };
    const children = try parser.entries(0, 0);
    return .{ .key = null, .kind = .table, .position = 0, .value = .{ .start = 0, .end = source.len }, .children = children };
}

/// Keys up to a `}` (inside the block opened at `open`) or the end of the file (at the top).
fn entries(parser: *Parser, depth: usize, open: usize) Error![]const Node {
    if (depth == max_depth) return parser.fail(parser.index, "blocks nest deeper than {d} levels", .{max_depth});
    var nodes: std.ArrayList(Node) = .empty;
    while (true) {
        const key = try parser.next();
        switch (key.kind) {
            .end => {
                if (depth != 0) return parser.fail(open, "this {{ is never closed; a }} is missing", .{});
                return nodes.items;
            },
            .close => {
                if (depth == 0) return parser.fail(key.range.start, "a }} closes no block", .{});
                return nodes.items;
            },
            .open => return parser.fail(key.range.start, "a {{ where a key belongs", .{}),
            .conditional => return parser.fail(key.range.start, "a conditional where a key belongs; it follows a value or block", .{}),
            .string => {},
        }
        if (depth == 0 and isDirective(key.text)) {
            const file = try parser.next();
            if (file.kind != .string) return parser.fail(key.range.start, "{s} needs a file name after it", .{key.text});
            continue;
        }
        try nodes.append(parser.allocator, try parser.entry(key, depth));
    }
}

/// The value or block after `key`, and the conditional after that, if any.
fn entry(parser: *Parser, key: Token, depth: usize) Error!Node {
    const value = try parser.next();
    const node: Node = switch (value.kind) {
        .string => .{ .key = key.text, .kind = .scalar, .position = key.range.start, .value = value.range },
        .open => blk: {
            const children = try parser.entries(depth + 1, value.range.start);
            break :blk .{ .key = key.text, .kind = .table, .position = key.range.start, .value = .{ .start = value.range.start, .end = parser.index }, .children = children };
        },
        else => return parser.fail(key.range.start, "key '{s}' has no value or block", .{key.text}),
    };
    const after = parser.index;
    if ((try parser.next()).kind != .conditional) parser.index = after;
    return node;
}

fn isDirective(text: []const u8) bool {
    return std.mem.eql(u8, text, "#base") or std.mem.eql(u8, text, "#include");
}

/// The next token, past spaces and comments.
fn next(parser: *Parser) Error!Token {
    const source = parser.source;
    while (parser.index < source.len) {
        const byte = source[parser.index];
        if (std.ascii.isWhitespace(byte)) {
            parser.index += 1;
        } else if (std.mem.startsWith(u8, source[parser.index..], "//")) {
            parser.index = std.mem.findScalarPos(u8, source, parser.index, '\n') orelse source.len;
        } else break;
    }
    const start = parser.index;
    if (start == source.len) return .{ .kind = .end, .range = .{ .start = start, .end = start }, .text = "" };
    switch (source[start]) {
        '{', '}' => {
            parser.index += 1;
            return .{ .kind = if (source[start] == '{') .open else .close, .range = .{ .start = start, .end = start + 1 }, .text = source[start .. start + 1] };
        },
        '"' => return parser.quoted(start),
        '[' => {
            const close = std.mem.findScalarPos(u8, source, start, ']') orelse return parser.fail(start, "a conditional's [ is never closed", .{});
            parser.index = close + 1;
            return .{ .kind = .conditional, .range = .{ .start = start, .end = close + 1 }, .text = source[start .. close + 1] };
        },
        else => {
            var end = start;
            while (end < source.len and !std.ascii.isWhitespace(source[end]) and std.mem.findScalar(u8, "{}\"", source[end]) == null) end += 1;
            parser.index = end;
            return .{ .kind = .string, .range = .{ .start = start, .end = end }, .text = source[start..end] };
        },
    }
}

/// `"text"`, where a backslash keeps the next byte from ending it.
fn quoted(parser: *Parser, start: usize) Error!Token {
    const source = parser.source;
    var index = start + 1;
    while (index < source.len and source[index] != '"') : (index += 1) {
        if (source[index] == '\\') index += 1;
        if (index < source.len and source[index] == '\n') return parser.fail(start, "a quoted string runs past the end of its line", .{});
    }
    if (index >= source.len) return parser.fail(start, "a quoted string is never closed", .{});
    parser.index = index + 1;
    return .{ .kind = .string, .range = .{ .start = start, .end = index + 1 }, .text = source[start + 1 .. index] };
}

fn fail(parser: *const Parser, position: usize, comptime format: []const u8, arguments: anytype) error{InvalidSyntax} {
    const line = 1 + std.mem.count(u8, parser.source[0..@min(position, parser.source.len)], "\n");
    return parser.context.invalidSyntax("line {d}: " ++ format, .{line} ++ arguments);
}

const testing = std.testing;

fn parseForTest(arena: *std.heap.ArenaAllocator, source: []const u8, context: *kosm.Adapter.Context) Error!Node {
    return parse(arena.allocator(), source, context);
}

fn expectFailure(source: []const u8, message: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: kosm.Adapter.Context = .{ .format = kosm.Format.kosm_default };
    try testing.expectError(error.InvalidSyntax, parseForTest(&arena, source, &context));
    try testing.expectEqualStrings(message, context.message());
}

test "blocks nest, quoted and bare words both work, and comments, conditionals and directives are skipped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var context: kosm.Adapter.Context = .{ .format = kosm.Format.kosm_default };
    const source = "#base \"SourceScheme.res\"\nScheme // the root\n{\n\tColors\n\t{\n\t\t\"BaseText\"\t\"255 255 255 255\"\t// text\n\t\t\"Path\"\t\t\"a \\\"quoted\\\" word\" [$WIN32]\n\t}\n\t\"Fonts\" { \"Default\" { \"1\" { \"name\" \"Tahoma\" \"tall\" 16 } } } [$X360]\n}\n";
    const root = try parseForTest(&arena, source, &context);
    try testing.expectEqual(1, root.children.len);
    const scheme = root.children[0];
    try testing.expectEqualStrings("Scheme", scheme.key.?);
    try testing.expectEqual(.table, scheme.kind);
    const colors = scheme.children[0];
    try testing.expectEqualStrings("BaseText", colors.children[0].key.?);
    const base_text = colors.children[0].value.?;
    try testing.expectEqualStrings("\"255 255 255 255\"", source[base_text.start..base_text.end]);
    const path = colors.children[1].value.?;
    try testing.expectEqualStrings("\"a \\\"quoted\\\" word\"", source[path.start..path.end]);
    const font = scheme.children[1].children[0].children[0];
    try testing.expectEqualStrings("1", font.key.?);
    const tall = font.children[1].value.?;
    try testing.expectEqualStrings("16", source[tall.start..tall.end]);
}

test "broken files are refused naming the line" {
    try expectFailure("Scheme\n{\n\t\"a\" \"b\"\n", "line 2: this { is never closed; a } is missing");
    try expectFailure("\"a\" \"b\"\n}\n", "line 2: a } closes no block");
    try expectFailure("Scheme\n{\n\t\"a\"\n}\n", "line 3: key 'a' has no value or block");
    try expectFailure("\"a\" \"open\n\"b\" \"c\"\n", "line 1: a quoted string runs past the end of its line");
    try expectFailure("{ }", "line 1: a { where a key belongs");
    try expectFailure("#base\n", "line 1: #base needs a file name after it");
}
