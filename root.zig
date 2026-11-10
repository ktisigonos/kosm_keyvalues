//! Valve's KeyValues: the `keyvalues` adapter, for `.res` and `.vdf` files.

const std = @import("std");
const kosm = @import("kosm");

/// Edits KeyValues files (`.res`, `.vdf`; any other with `.lang = "keyvalues"`). Values are
/// written quoted; colors default to `r g b a`, the spelling of Valve's schemes.
pub const adapter: kosm.Adapter = .{
    .name = "keyvalues",
    .extensions = &.{ ".res", ".vdf" },
    .default_format = .{
        .color = .init("{} {} {} {}", &.{ .red_255, .green_255, .blue_255, .alpha_255 }),
        .boolean = .one_zero,
    },
    .format = format,
    .parser = @import("Parser.zig").parse,
    .comment = .{ .line = "//" },
};

/// Longest value `format` renders before checking it.
const max_text_length = 64 * 1024;

/// Every value is written as a quoted string, which is how Valve's tools write them.
fn format(writer: *std.Io.Writer, value: kosm.Value, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    switch (value) {
        .list => return context.unsupported("KeyValues has no lists; a key written twice is two entries", .{}),
        .table => return context.unsupported("a table is a {{ ... }} block, which edit can't write; set its keys one by one", .{}),
        else => {},
    }
    var buffer: [max_text_length]u8 = undefined;
    var rendered: std.Io.Writer = .fixed(&buffer);
    writePlain(&rendered, value, context) catch |err| switch (err) {
        error.WriteFailed => return context.unsupported("the value is longer than {d} bytes", .{max_text_length}),
        error.UnsupportedValue => return error.UnsupportedValue,
    };
    const text = rendered.buffered();
    if (std.mem.findAny(u8, text, "\r\n") != null) return context.unsupported("\"{s}\" holds a line break, which ends a KeyValues string", .{text});
    if (std.mem.findScalar(u8, text, '"') != null) return context.unsupported("\"{s}\" holds a quote, which not every KeyValues reader unescapes", .{text});
    if (std.mem.endsWith(u8, text, "\\")) return context.unsupported("\"{s}\" ends with a backslash, which would escape the closing quote", .{text});
    try writer.print("\"{s}\"", .{text});
}

/// A value's text: parts of a joined value are written back to back.
fn writePlain(writer: *std.Io.Writer, value: kosm.Value, context: *kosm.Adapter.Context) kosm.Adapter.Error!void {
    switch (value) {
        .string, .raw => |text| try writer.writeAll(text),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| try context.writeFloat(writer, float),
        .boolean => |boolean| try context.writeBoolean(writer, boolean),
        .color => |color| try context.writeColor(writer, color),
        .joined => |parts| for (parts) |part| try writePlain(writer, part, context),
        .list, .table => return context.unsupported("a joined value holds plain values, not a {s}", .{@tagName(value)}),
    }
}

const testing = std.testing;

fn expectFormatted(expected: []const u8, value: kosm.Value) !void {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var context: kosm.Adapter.Context = .{ .format = adapter.default_format.resolve() };
    try format(&output.writer, value, &context);
    try testing.expectEqualStrings(expected, output.written());
}

fn expectUnsupported(message: []const u8, value: kosm.Value) !void {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var context: kosm.Adapter.Context = .{ .format = adapter.default_format.resolve() };
    try testing.expectError(error.UnsupportedValue, format(&output.writer, value, &context));
    try testing.expectEqualStrings(message, context.message());
}

test "values are quoted, colors r g b a and booleans 1 or 0" {
    try expectFormatted("\"Tahoma\"", .{ .string = "Tahoma" });
    try expectFormatted("\"16\"", .{ .integer = 16 });
    try expectFormatted("\"1\"", .{ .boolean = true });
    try expectFormatted("\"4 28 38 255\"", .{ .color = kosm.hex("041c26") });
    try expectFormatted("\"C:\\fonts\\a.ttf\"", .{ .string = "C:\\fonts\\a.ttf" });
}

test "text a KeyValues string can't hold is refused" {
    try expectUnsupported("\"a \"b\"\" holds a quote, which not every KeyValues reader unescapes", .{ .string = "a \"b\"" });
    try expectUnsupported("\"a\nb\" holds a line break, which ends a KeyValues string", .{ .string = "a\nb" });
    try expectUnsupported("\"C:\\\" ends with a backslash, which would escape the closing quote", .{ .string = "C:\\" });
    try expectUnsupported("KeyValues has no lists; a key written twice is two entries", .{ .list = &.{} });
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("Parser.zig");
}
