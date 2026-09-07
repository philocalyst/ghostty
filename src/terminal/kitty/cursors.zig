//! Kitty multiple cursors protocol.
//!
//! Specification: https://sw.kovidgoyal.net/kitty/multiple-cursors-protocol/
//!
//! The protocol lets a program draw any number of extra,
//! non-interactive cursors with `CSI > ... SP q`. This file has two
//! halves. `Command` decodes a CSI, borrowing the parser's buffers and
//! never touching the terminal. `State` is what the terminal owns and
//! what a command is applied to.
//!
//! Extra cursors sit at fixed screen positions. The spec is explicit
//! that scrolling "must not affect the extra cursors in any way", so
//! positions live in active-area coordinates and never move with the
//! text. Only the renderer translates them into the viewport.
//!
//! ## Divergences
//!
//!   * A resize removes all extra cursors. The spec doesn't say what
//!     should happen, and the cells the cursors named are gone.
//!   * The parser drops a sequence with more than `Parser.MAX_PARAMS`
//!     parameters. kitty uses the same limit, so a client written
//!     against it can't hit this.
//!   * An extra cursor addresses one cell, so one on either half of a
//!     wide character covers only that half. The main cursor covers
//!     both, but the shader draws that one.
//!   * DECSTR does not clear this state. Ghostty has no soft reset yet,
//!     and implementing only its cursor side effect would leave the
//!     rest half-done.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const size = @import("../size.zig");
const Coordinate = @import("../point.zig").Coordinate;
const Parser = @import("../Parser.zig");
const Style = @import("../style.zig").Style;

/// The shape of an extra cursor. The values are the protocol's paint
/// operation numbers, so `none` is operation 0 (erase) and the rest are
/// the drawable shapes.
pub const Shape = enum(u8) {
    none = 0,
    block = 1,
    beam = 2,
    underline = 3,
    /// Draw whatever shape the main cursor is currently using.
    follow = 29,
};

/// A color carried by the protocol.
///
/// Every color space but `special` names an ordinary terminal color.
/// Those reuse `Style.Color`: space 0 is `.none`, space 2 is `.rgb`, and
/// space 5 is `.palette`.
pub const Color = union(enum) {
    /// Color space 1, an effect and not a color: the cursor reverses
    /// the video of the cell it is on. It depends on what is on screen,
    /// so only the renderer can resolve it.
    special,

    /// Color spaces 0, 2, and 5.
    value: Style.Color,

    /// Inherit the main cursor's color. This is the protocol's default
    /// and what color space 0 selects.
    pub const unset: Color = .{ .value = .none };

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .value = .{ .rgb = .{ .r = r, .g = g, .b = b } } };
    }

    pub fn eql(self: Color, other: Color) bool {
        return switch (self) {
            .special => other == .special,
            .value => |v| other == .value and v.eql(other.value),
        };
    }

    /// Decode one color group: the color space followed by its payload.
    /// Null for an unknown space, or a payload too short for it.
    pub fn decode(space: u16, params: []const u16) ?Color {
        return switch (space) {
            0 => .unset,
            1 => .special,

            // Components wider than a byte are truncated, as kitty does.
            2 => if (params.len >= 3) .rgb(
                @truncate(params[0]),
                @truncate(params[1]),
                @truncate(params[2]),
            ) else null,

            5 => if (params.len >= 1) .{
                .value = .{ .palette = @truncate(params[0]) },
            } else null,

            else => null,
        };
    }

    /// Encode as the color space and payload of a query response.
    pub fn encode(self: Color, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .special => try w.writeAll("1"),
            .value => |v| switch (v) {
                .none => try w.writeAll("0"),
                .palette => |i| try w.print("5:{d}", .{i}),
                .rgb => |c| try w.print("2:{d}:{d}:{d}", .{ c.r, c.g, c.b }),
            },
        }
    }
};

/// A state-changing protocol operation.
pub const Operation = union(enum) {
    /// Draw `shape`, or erase for `.none`, over the target regions.
    paint: Shape,
    text_color,
    cursor_color,

    /// The operation numbers of the two color operations. Paint
    /// operations need no constants: they are numbered by `Shape`.
    const text_color_number = 30;
    const cursor_color_number = 40;

    fn decode(value: u16) ?Operation {
        return switch (value) {
            text_color_number => .text_color,
            cursor_color_number => .cursor_color,

            // Every remaining operation number is a paint. `Shape` is
            // numbered to match.
            else => .{
                .paint = std.enums.fromInt(Shape, value) orelse return null,
            },
        };
    }
};

/// A command that reports state instead of changing it.
/// `State.writeResponse` answers all of them.
pub const Query = enum {
    /// `CSI > SP q`, the discovery query. It carries no parameters at
    /// all, so it has no operation number of its own.
    support,
    cursors,
    colors,

    /// The operation number that selects this query, or null for the
    /// bare discovery form. This is the only place the query numbers
    /// appear: `decode` inverts it, and so does `support_response`.
    pub fn number(self: Query) ?u16 {
        return switch (self) {
            .support => null,
            .cursors => 100,
            .colors => 101,
        };
    }

    /// The query an operation number selects, or null if it selects
    /// none. The inverse of `number`.
    fn decode(value: u16) ?Query {
        for (std.enums.values(Query)) |query| {
            if (query.number() == value) return query;
        }
        return null;
    }
};

/// The reply to the discovery query: every operation number this file
/// implements, in ascending order.
///
/// Built at comptime from the declarations that define those numbers.
/// Add a shape or a query and the reply follows; hardcode it and the
/// next change makes it a lie.
const support_response = response: {
    var out: []const u8 = "\x1b[>";

    // Paint operations are numbered by `Shape`. `none` is erase, which
    // every implementation has, so there is nothing to advertise.
    for (std.enums.values(Shape)) |shape| {
        if (shape == .none) continue;
        out = out ++ std.fmt.comptimePrint("{d};", .{@intFromEnum(shape)});
    }

    out = out ++ std.fmt.comptimePrint("{d};{d}", .{
        Operation.text_color_number,
        Operation.cursor_color_number,
    });

    // `.support` has no number of its own, so it drops out here.
    for (std.enums.values(Query)) |query| {
        const number = query.number() orelse continue;
        out = out ++ std.fmt.comptimePrint(";{d}", .{number});
    }

    break :response out ++ " q";
};

/// One extra cursor, in active-screen coordinates, as a renderer
/// consumes it.
pub const Cursor = struct {
    x: size.CellCountInt,
    y: size.CellCountInt,
    shape: Shape,
};
