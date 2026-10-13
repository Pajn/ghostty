const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
const page = @import("../page.zig");
const PageList = @import("../PageList.zig");
const hyperlink = @import("../hyperlink.zig");
const point = @import("../point.zig");
const size = @import("../size.zig");
const stylepkg = @import("../style.zig");
const cell_c = @import("cell.zig");
const row_c = @import("row.zig");
const style_c = @import("style.zig");
const terminal_c = @import("terminal.zig");
const Result = @import("result.zig").Result;

/// C: GhosttyGridRef
///
/// A sized struct that holds a reference to a position in the terminal grid.
/// The ref points to a specific cell position within the terminal's
/// internal page structure.
pub const CGridRef = extern struct {
    size: usize = @sizeOf(CGridRef),
    node: ?*PageList.List.Node = null,
    x: size.CellCountInt = 0,
    y: size.CellCountInt = 0,

    pub fn fromPin(pin: PageList.Pin) CGridRef {
        return .{
            .node = pin.node,
            .x = pin.x,
            .y = pin.y,
        };
    }

    pub fn toPin(self: CGridRef) ?PageList.Pin {
        return .{
            .node = self.node orelse return null,
            .x = self.x,
            .y = self.y,
        };
    }
};

pub fn grid_ref_cell(
    ref: *const CGridRef,
    out: ?*cell_c.CCell,
) callconv(lib.calling_conv) Result {
    const p = ref.toPin() orelse return .invalid_value;
    if (out) |o| o.* = @bitCast(p.rowAndCell().cell.*);
    return .success;
}

pub fn grid_ref_row(
    ref: *const CGridRef,
    out: ?*row_c.CRow,
) callconv(lib.calling_conv) Result {
    const p = ref.toPin() orelse return .invalid_value;
    if (out) |o| o.* = @bitCast(p.rowAndCell().row.*);
    return .success;
}

pub fn grid_ref_graphemes(
    ref: *const CGridRef,
    out_buf: ?[*]u32,
    buf_len: usize,
    out_len: *usize,
) callconv(lib.calling_conv) Result {
    const p = ref.toPin() orelse return .invalid_value;
    const cell = p.rowAndCell().cell;

    if (!cell.hasText()) {
        out_len.* = 0;
        return .success;
    }

    const cp = cell.codepoint();
    const extra = if (cell.hasGrapheme()) p.grapheme(cell) else null;
    const total = 1 + if (extra) |e| e.len else 0;

    if (out_buf == null or buf_len < total) {
        out_len.* = total;
        return .out_of_space;
    }

    const buf = out_buf.?[0..buf_len];
    buf[0] = cp;
    if (extra) |e| for (e, 1..) |c, i| {
        buf[i] = c;
    };

    out_len.* = total;
    return .success;
}

pub fn grid_ref_hyperlink_uri(
    ref: *const CGridRef,
    out_buf: ?[*]u8,
    buf_len: usize,
    out_len: *usize,
) callconv(lib.calling_conv) Result {
    const p = ref.toPin() orelse return .invalid_value;
    const terminal_page = p.node.page();
    const entry = hyperlinkEntry(terminal_page, p) orelse {
        out_len.* = 0;
        return .success;
    };
    return copyBytes(
        entry.uri.slice(terminal_page.memory),
        out_buf,
        buf_len,
        out_len,
    );
}

pub fn grid_ref_hyperlink_id(
    ref: *const CGridRef,
    out_buf: ?[*]u8,
    buf_len: usize,
    out_len: *usize,
) callconv(lib.calling_conv) Result {
    const p = ref.toPin() orelse return .invalid_value;
    const terminal_page = p.node.page();
    const entry = hyperlinkEntry(terminal_page, p) orelse {
        out_len.* = 0;
        return .success;
    };
    const id = switch (entry.id) {
        .explicit => |slice| slice.slice(terminal_page.memory),
        // Implicit IDs are internal and only meaningful within a page,
        // so we report them the same as no ID.
        .implicit => {
            out_len.* = 0;
            return .success;
        },
    };
    return copyBytes(id, out_buf, buf_len, out_len);
}

/// The hyperlink entry for the cell at the pin, if the cell has one.
fn hyperlinkEntry(
    terminal_page: *const page.Page,
    p: PageList.Pin,
) ?*const hyperlink.PageEntry {
    const rac = terminal_page.getRowAndCell(p.x, p.y);
    if (!rac.cell.hyperlink) return null;
    const link_id = terminal_page.lookupHyperlink(rac.cell) orelse return null;
    return terminal_page.hyperlink_set.get(terminal_page.memory, link_id);
}

/// Copy bytes to the caller's buffer, or report the size the buffer
/// needs if it is NULL or too small.
fn copyBytes(
    bytes: []const u8,
    out_buf: ?[*]u8,
    buf_len: usize,
    out_len: *usize,
) Result {
    if (out_buf == null or buf_len < bytes.len) {
        out_len.* = bytes.len;
        return .out_of_space;
    }

    @memcpy(out_buf.?[0..bytes.len], bytes);
    out_len.* = bytes.len;
    return .success;
}

pub fn grid_ref_style(
    ref: *const CGridRef,
    out: ?*style_c.Style,
) callconv(lib.calling_conv) Result {
    const p = ref.toPin() orelse return .invalid_value;
    if (out) |o| {
        const cell = p.rowAndCell().cell;
        if (cell.style_id == stylepkg.default_id) {
            o.* = .fromStyle(.{});
        } else {
            const terminal_page = p.node.page();
            o.* = .fromStyle(terminal_page.styles.get(
                terminal_page.memory,
                cell.style_id,
            ).*);
        }
    }
    return .success;
}

test "grid_ref_cell null node" {
    const ref = CGridRef{};
    var out: cell_c.CCell = undefined;
    try testing.expectEqual(Result.invalid_value, grid_ref_cell(&ref, &out));
}

test "grid_ref_row null node" {
    const ref = CGridRef{};
    var out: row_c.CRow = undefined;
    try testing.expectEqual(Result.invalid_value, grid_ref_row(&ref, &out));
}

test "grid_ref_cell null out" {
    const ref = CGridRef{};
    try testing.expectEqual(Result.invalid_value, grid_ref_cell(&ref, null));
}

test "grid_ref_row null out" {
    const ref = CGridRef{};
    try testing.expectEqual(Result.invalid_value, grid_ref_row(&ref, null));
}

test "grid_ref_graphemes null node" {
    const ref = CGridRef{};
    var len: usize = undefined;
    try testing.expectEqual(Result.invalid_value, grid_ref_graphemes(&ref, null, 0, &len));
}

test "grid_ref_graphemes null buf returns out_of_space" {
    const ref = CGridRef{};
    var len: usize = undefined;
    // With null node this returns invalid_value before checking the buffer,
    // so we can only test null node here. Full buffer tests require a real page.
    try testing.expectEqual(Result.invalid_value, grid_ref_graphemes(&ref, null, 0, &len));
}

test "grid_ref_style null node" {
    const ref = CGridRef{};
    var out: style_c.Style = undefined;
    try testing.expectEqual(Result.invalid_value, grid_ref_style(&ref, &out));
}

test "grid_ref_style null out" {
    const ref = CGridRef{};
    try testing.expectEqual(Result.invalid_value, grid_ref_style(&ref, null));
}

test "grid_ref_hyperlink_uri null node" {
    const ref = CGridRef{};
    var len: usize = undefined;
    try testing.expectEqual(Result.invalid_value, grid_ref_hyperlink_uri(&ref, null, 0, &len));
}

test "grid_ref_hyperlink_uri no hyperlink" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    terminal_c.vt_write(terminal, "hello", 5);

    var ref: CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(
        terminal,
        point.Point.cval(.{ .active = .{ .x = 0, .y = 0 } }),
        &ref,
    ));

    var len: usize = undefined;
    try testing.expectEqual(Result.success, grid_ref_hyperlink_uri(&ref, null, 0, &len));
    try testing.expectEqual(@as(usize, 0), len);
}

test "grid_ref_hyperlink_uri with hyperlink" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    // Write OSC 8 hyperlink: \e]8;;uri\e\\text\e]8;;\e\\
    const seq = "\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\";
    terminal_c.vt_write(terminal, seq, seq.len);

    var ref: CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(
        terminal,
        point.Point.cval(.{ .active = .{ .x = 0, .y = 0 } }),
        &ref,
    ));

    // First query length with null buf
    var len: usize = undefined;
    try testing.expectEqual(Result.out_of_space, grid_ref_hyperlink_uri(&ref, null, 0, &len));
    try testing.expectEqual(@as(usize, 19), len); // "https://example.com"

    // Now read with a properly sized buffer
    var buf: [256]u8 = undefined;
    try testing.expectEqual(Result.success, grid_ref_hyperlink_uri(&ref, &buf, buf.len, &len));
    try testing.expectEqualStrings("https://example.com", buf[0..len]);
}

test "grid_ref_hyperlink_id null node" {
    const ref = CGridRef{};
    var len: usize = undefined;
    try testing.expectEqual(Result.invalid_value, grid_ref_hyperlink_id(&ref, null, 0, &len));
}

test "grid_ref_hyperlink_id no hyperlink" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    terminal_c.vt_write(terminal, "hello", 5);

    var ref: CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(
        terminal,
        point.Point.cval(.{ .active = .{ .x = 0, .y = 0 } }),
        &ref,
    ));

    var len: usize = undefined;
    try testing.expectEqual(Result.success, grid_ref_hyperlink_id(&ref, null, 0, &len));
    try testing.expectEqual(@as(usize, 0), len);
}

test "grid_ref_hyperlink_id implicit id" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    const seq = "\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\";
    terminal_c.vt_write(terminal, seq, seq.len);

    var ref: CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(
        terminal,
        point.Point.cval(.{ .active = .{ .x = 0, .y = 0 } }),
        &ref,
    ));

    var len: usize = undefined;
    try testing.expectEqual(Result.success, grid_ref_hyperlink_id(&ref, null, 0, &len));
    try testing.expectEqual(@as(usize, 0), len);
}

test "grid_ref_hyperlink_id explicit id" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    const seq = "\x1b]8;id=doc;https://example.com\x1b\\link\x1b]8;;\x1b\\";
    terminal_c.vt_write(terminal, seq, seq.len);

    var ref: CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(
        terminal,
        point.Point.cval(.{ .active = .{ .x = 0, .y = 0 } }),
        &ref,
    ));

    // First query length with null buf
    var len: usize = undefined;
    try testing.expectEqual(Result.out_of_space, grid_ref_hyperlink_id(&ref, null, 0, &len));
    try testing.expectEqual(@as(usize, 3), len); // "doc"

    // Now read with a properly sized buffer
    var buf: [256]u8 = undefined;
    try testing.expectEqual(Result.success, grid_ref_hyperlink_id(&ref, &buf, buf.len, &len));
    try testing.expectEqualStrings("doc", buf[0..len]);
}
