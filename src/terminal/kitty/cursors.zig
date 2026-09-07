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

/// A decoded command. Queries are kept apart from updates so the common
/// update path never has to think about building a response.
pub const Command = union(enum) {
    query: Query,
    update: Update,

    /// Decode a CSI dispatch, or null if it isn't this protocol.
    ///
    /// An operation with no coordinate groups behind it becomes an
    /// `Update` that targets nothing, so `CSI > 1 SP q` is accepted and
    /// paints nowhere. The protocol defines no default region, and
    /// guessing one would paint somewhere nobody asked for.
    pub fn decode(input: Parser.Action.CSI) ?Command {
        if (input.final != 'q' or
            !std.mem.eql(u8, input.intermediates, "> ")) return null;

        if (input.params.len == 0) return .{ .query = .support };
        if (input.params.len == 1) {
            if (Query.decode(input.params[0])) |query| {
                return .{ .query = query };
            }
        }

        return .{ .update = .{
            .operation = Operation.decode(input.params[0]) orelse return null,
            .params = input.params,
            .params_sep = input.params_sep,
        } };
    }

    /// The C API view of a decoded command.
    ///
    /// The Zig union nests the operation inside `update`, and a C caller
    /// can't switch on that. `kind` flattens both levels into one tag,
    /// and `shape` carries what `paint` held.
    pub const C = extern struct {
        kind: Kind,

        /// The shape to paint. Only meaningful when `kind` is `.paint`.
        shape: Shape,

        /// The CSI parameters, borrowed from the parser. Index 0 is the
        /// operation number that `kind` and `shape` decode; the rest are
        /// the coordinates or colors it applies to.
        params: [*]const u16,
        params_len: usize,

        /// One bit per parameter, set when a ':' follows that parameter
        /// instead of a ';'. Parameter i is bit `i % 8` of byte `i / 8`.
        /// A byte array, not the Zig bit set, so the layout is well
        /// defined for C.
        params_sep: [Parser.MAX_PARAMS / 8]u8,

        pub const Kind = enum(u8) {
            query_support,
            query_cursors,
            query_colors,
            paint,
            text_color,
            cursor_color,
        };
    };

    /// The C API representation. The parameters stay borrowed, so this
    /// is valid for exactly as long as the command it came from.
    pub fn cval(self: Command) C {
        var result: C = .{
            .kind = undefined,
            .shape = .none,
            .params = (&[_]u16{}).ptr,
            .params_len = 0,
            .params_sep = @splat(0),
        };

        switch (self) {
            .query => |q| result.kind = switch (q) {
                .support => .query_support,
                .cursors => .query_cursors,
                .colors => .query_colors,
            },

            .update => |u| {
                switch (u.operation) {
                    .paint => |shape| {
                        result.kind = .paint;
                        result.shape = shape;
                    },
                    .text_color => result.kind = .text_color,
                    .cursor_color => result.kind = .cursor_color,
                }

                result.params = u.params.ptr;
                result.params_len = u.params.len;
                var it = u.params_sep.iterator(.{});
                while (it.next()) |i| {
                    result.params_sep[i / 8] |= @as(u8, 1) << @intCast(i % 8);
                }
            },
        }

        return result;
    }
};

/// The borrowed payload of a state-changing command, valid only for the
/// duration of the stream callback that received it.
pub const Update = struct {
    operation: Operation,

    /// The CSI parameters, with the operation still at index 0 so the
    /// separator bits line up with them. Iterate with `groups` or
    /// `regions`; don't index this directly.
    params: []const u16,
    params_sep: *const Parser.Action.CSI.SepList,

    /// Iterate the semicolon-delimited groups after the operation. This
    /// is for the color operations; paint operations use `regions`.
    pub fn groups(self: Update) Parser.Action.CSI.GroupIterator {
        var it: Parser.Action.CSI.GroupIterator = .{
            .params = self.params,
            .params_sep = self.params_sep,
        };

        // Drop the operation, which is a group of its own. Skip a whole
        // group, not one parameter: malformed input that colon-joins
        // the operation to what follows would otherwise leave those
        // parameters behind to be read as a coordinate.
        _ = it.next();
        return it;
    }

    /// Iterate the screen regions targeted by a paint operation.
    pub fn regions(self: Update) RegionIterator {
        return .{ .groups = self.groups() };
    }
};

/// How a paint operation addresses cells. Protocol values not represented
/// here are ignored.
const CoordinateType = enum(u16) {
    cursor = 0,
    point = 2,
    rectangle = 4,
};

/// A one-based, inclusive screen rectangle exactly as it was sent.
pub const Rect = struct {
    top: u16,
    left: u16,
    bottom: u16,
    right: u16,
};

/// A zero-based, inclusive grid rectangle, already clipped to the screen
/// and so covering at least one cell. It is a separate type from `Rect`
/// because the two coordinate spaces are one apart, and mixing them up
/// is the easiest mistake this protocol offers.
const Bounds = struct {
    top: size.CellCountInt,
    left: size.CellCountInt,
    bottom: size.CellCountInt,
    right: size.CellCountInt,
};

/// A paint target. A point becomes a 1x1 rectangle, so consumers have
/// only one geometric case.
pub const Region = union(enum) {
    /// The main cursor's cell (coordinate type 0).
    cursor,
    /// Coordinate type 2 (a point) or 4 (a rectangle).
    rect: Rect,
};

/// Decodes the coordinate groups of a paint operation into regions.
///
/// Trailing coordinates that don't complete a region are ignored, as the
/// spec requires, and so are unknown coordinate types.
pub const RegionIterator = struct {
    groups: Parser.Action.CSI.GroupIterator,

    /// Coordinates of the current group not yet yielded, and how many of
    /// them each region takes: two for a point, four for a rectangle.
    rest: []const u16 = &.{},
    stride: usize = 4,

    /// A bare coordinate type 4 means the whole screen. `clipRegion`
    /// clamps this to the grid, so it needs no case of its own.
    const all: Rect = .{
        .top = 1,
        .left = 1,
        .bottom = std.math.maxInt(u16),
        .right = std.math.maxInt(u16),
    };

    pub fn next(self: *RegionIterator) ?Region {
        while (true) {
            // A point repeats its own coordinates for the far corner.
            // That is what lets both strides share one expression.
            if (self.rest.len >= self.stride) {
                const c = self.rest;
                self.rest = c[self.stride..];
                return .{ .rect = .{
                    .top = c[0],
                    .left = c[1],
                    .bottom = c[self.stride - 2],
                    .right = c[self.stride - 1],
                } };
            }

            // Whatever is left of the previous group is an incomplete
            // region, which the spec says to ignore.
            const group = self.groups.next() orelse return null;
            self.rest = &.{};

            switch (std.enums.fromInt(
                CoordinateType,
                group[0],
            ) orelse continue) {
                .cursor => return .cursor,

                .point => {
                    self.stride = 2;
                    self.rest = group[1..];
                },

                .rectangle => {
                    self.stride = 4;
                    // Only a bare coordinate type 4 is the whole
                    // screen. A type 4 with too few coordinates is just
                    // an incomplete rectangle, ignored like any other.
                    if (group.len == 1) return .{ .rect = all };
                    self.rest = group[1..];
                },
            }
        }
    }
};
