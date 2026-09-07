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

/// One lazily allocated cursor shape per active-screen cell.
///
/// This is a grid, not a list of positions, because the protocol
/// addresses cells. A paint is a write over a row slice, an erase is the
/// same write with `.none`, and the whole structure costs one allocation
/// the first time the protocol is used. A list would be smaller for the
/// handful of cursors a client usually has, but it would have to splice
/// sorted ranges on every update, and it is *larger* for the
/// full-screen paints this protocol makes trivial to ask for.
pub const State = struct {
    /// Row-major, `cols * rows` entries, or empty before the protocol is
    /// first used. `.none` means no cursor on that cell.
    shapes: std.ArrayListUnmanaged(Shape) = .empty,

    /// How many entries in `shapes` aren't `.none`. Readers use it to
    /// size a copy, to bound an iteration, and to skip the scan
    /// altogether when there is nothing to find.
    count: usize = 0,

    cols: size.CellCountInt = 0,
    rows: size.CellCountInt = 0,

    /// The shared colors. Unlike positions these are terminal-wide and
    /// survive a screen buffer switch, matching kitty.
    text_color: Color = .unset,
    cursor_color: Color = .unset,

    /// Monotonic mutation stamp. Render snapshots compare this instead
    /// of consuming a dirty bit, which keeps multiple readers correct
    /// and stops an unchanged frame from rescanning the grid.
    generation: u64 = 0,

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.shapes.deinit(alloc);
        self.* = undefined;
    }

    /// Remove all cursors, keeping the colors.
    pub fn clear(self: *State) void {
        if (self.count == 0) return;
        @memset(self.shapes.items, .none);
        self.count = 0;
        self.touch();
    }

    /// Remove all cursors and restore the default colors.
    pub fn reset(self: *State) void {
        const changed = self.count > 0 or
            !self.text_color.eql(.unset) or
            !self.cursor_color.eql(.unset);
        if (self.count > 0) @memset(self.shapes.items, .none);
        self.count = 0;
        self.text_color = .unset;
        self.cursor_color = .unset;
        if (changed) self.touch();
    }

    /// Resize the grid. Every cursor goes, because the cells they named
    /// are gone; the colors stay. The capacity is kept, so this needs no
    /// allocator and cannot fail.
    pub fn resize(
        self: *State,
        cols: size.CellCountInt,
        rows: size.CellCountInt,
    ) void {
        if (cols == self.cols and rows == self.rows) return;
        self.cols = cols;
        self.rows = rows;
        self.shapes.clearRetainingCapacity();
        if (self.count == 0) return;
        self.count = 0;
        self.touch();
    }

    /// Apply a state-changing command. `cursor` is the main cursor's
    /// position, which coordinate type 0 targets.
    pub fn apply(
        self: *State,
        alloc: Allocator,
        update: Update,
        cursor: Coordinate,
    ) Allocator.Error!void {
        const changed = switch (update.operation) {
            .paint => |shape| try self.applyPaint(alloc, update, shape, cursor),
            .text_color => applyColor(update, &self.text_color),
            .cursor_color => applyColor(update, &self.cursor_color),
        };
        if (changed) self.touch();
    }

    fn applyPaint(
        self: *State,
        alloc: Allocator,
        update: Update,
        shape: Shape,
        cursor: Coordinate,
    ) Allocator.Error!bool {
        const cols: usize = @intCast(self.cols);
        const rows: usize = @intCast(self.rows);
        const total_cells = cols * rows;
        if (total_cells == 0) return false;

        if (self.shapes.items.len == 0) {
            // Nothing has ever been painted, so there is nothing to
            // erase and no reason to allocate the grid yet.
            if (shape == .none) return false;

            // The only allocation in the whole apply, and it happens
            // before anything is mutated. A failure here leaves the
            // state as it was.
            try self.shapes.resize(alloc, total_cells);
            @memset(self.shapes.items, .none);
        }

        var changed = false;
        var regions = update.regions();
        while (regions.next()) |region| {
            const area = self.clipRegion(region, cursor) orelse continue;
            for (area.top..@as(usize, area.bottom) + 1) |y| {
                const row = self.shapes.items[y * cols ..];
                for (row[area.left .. @as(usize, area.right) + 1]) |*cell| {
                    // A client that redraws every frame repaints cells
                    // that already have this shape. Skipping those
                    // keeps the generation from ticking and forcing a
                    // needless render.
                    if (cell.* == shape) continue;
                    if (cell.* == .none) self.count += 1;
                    if (shape == .none) self.count -= 1;
                    cell.* = shape;
                    changed = true;
                }
            }
        }
        return changed;
    }

    fn applyColor(update: Update, slot: *Color) bool {
        var changed = false;
        var groups = update.groups();
        while (groups.next()) |group| {
            const value = Color.decode(group[0], group[1..]) orelse continue;
            if (slot.eql(value)) continue;
            slot.* = value;
            changed = true;
        }
        return changed;
    }

    /// Clip a region to the grid. Null means the region misses the
    /// screen entirely. The spec asks us to ignore those, not clamp
    /// them.
    fn clipRegion(
        self: *const State,
        region: Region,
        cursor: Coordinate,
    ) ?Bounds {
        assert(self.cols > 0 and self.rows > 0);
        return switch (region) {
            .cursor => cursor: {
                const x = @min(cursor.x, self.cols - 1);
                const y: size.CellCountInt = @intCast(@min(
                    cursor.y,
                    self.rows - 1,
                ));
                break :cursor .{ .top = y, .bottom = y, .left = x, .right = x };
            },

            // Coordinates are one-based, so zero is invalid. Everything
            // else is clipped to the screen and rejected if it comes
            // out empty. That covers an out of range origin too.
            .rect => |r| rect: {
                if (r.top == 0 or r.left == 0 or
                    r.bottom == 0 or r.right == 0) break :rect null;

                const clipped: Bounds = .{
                    .top = r.top - 1,
                    .left = r.left - 1,
                    .bottom = @min(r.bottom - 1, self.rows - 1),
                    .right = @min(r.right - 1, self.cols - 1),
                };
                break :rect if (clipped.top > clipped.bottom or
                    clipped.left > clipped.right) null else clipped;
            },
        };
    }

    /// Iterate the live cursors in row-major order. The spec leaves the
    /// set unordered, but a query response has to pick an order, and
    /// row-major is the order the grid is already in.
    pub fn iterator(self: *const State) Iterator {
        return .{ .state = self, .remaining = self.count };
    }

    /// A row-major scan of the grid that yields only the live cursors.
    pub const Iterator = struct {
        state: *const State,
        index: usize = 0,

        /// Live cursors not yet yielded. The grid has `cols * rows`
        /// entries and almost always holds a handful of cursors, so the
        /// scan stops as soon as it has found them all.
        remaining: usize,

        pub fn next(self: *Iterator) ?Cursor {
            if (self.remaining == 0) return null;
            const shapes = self.state.shapes.items;
            while (self.index < shapes.len) {
                const index = self.index;
                self.index += 1;
                if (shapes[index] == .none) continue;
                self.remaining -= 1;
                return .{
                    .x = @intCast(index % self.state.cols),
                    .y = @intCast(index / self.state.cols),
                    .shape = shapes[index],
                };
            }
            return null;
        }
    };

    /// Encode the reply to a query. Coordinates go out one-based, the
    /// same way they come in.
    pub fn writeResponse(
        self: *const State,
        query: Query,
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (query) {
            .support => try w.writeAll(support_response),

            // Every cursor as `SHAPE:2:y:x`, one-based.
            .cursors => {
                try w.writeAll("\x1b[>100");
                var it = self.iterator();
                while (it.next()) |c| try w.print(";{d}:2:{d}:{d}", .{
                    @intFromEnum(c.shape),
                    @as(u32, c.y) + 1,
                    @as(u32, c.x) + 1,
                });
                try w.writeAll(" q");
            },

            .colors => {
                try w.writeAll("\x1b[>101;30:");
                try self.text_color.encode(w);
                try w.writeAll(";40:");
                try self.cursor_color.encode(w);
                try w.writeAll(" q");
            },
        }
    }

    /// Encode a query response into memory owned by the caller. Both
    /// stream handlers need this; only how they send it differs.
    pub fn allocResponse(
        self: *const State,
        alloc: Allocator,
        query: Query,
    ) Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        errdefer aw.deinit();
        self.writeResponse(query, &aw.writer) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    /// Note a mutation. Zero is reserved to mean "never mutated", so a
    /// fresh render snapshot always disagrees with a state someone has
    /// touched, even once the counter wraps.
    fn touch(self: *State) void {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
    }
};

/// Build an `Update` over `params`, with a colon separator after every
/// parameter whose index appears in `colons`.
fn testUpdate(
    operation: Operation,
    comptime params: []const u16,
    comptime colons: []const usize,
) Update {
    const seps = comptime seps: {
        var list: Parser.Action.CSI.SepList = .initEmpty();
        for (colons) |i| list.set(i);
        break :seps list;
    };
    return .{
        .operation = operation,
        .params = params,
        .params_sep = &seps,
    };
}

test "Update: regions" {
    // `1 ; 2:1:2 ; 0 ; 4:2:2:3:3 ; 7:1 ; 4`: a point, the main cursor,
    // a rectangle, an unknown coordinate type, then a bare rectangle.
    var it = testUpdate(
        .{ .paint = .block },
        &.{ 1, 2, 1, 2, 0, 4, 2, 2, 3, 3, 7, 1, 4 },
        &.{ 1, 2, 5, 6, 7, 8, 10 },
    ).regions();

    for ([_]Region{
        .{ .rect = .{ .top = 1, .left = 2, .bottom = 1, .right = 2 } },
        .cursor,
        .{ .rect = .{ .top = 2, .left = 2, .bottom = 3, .right = 3 } },
        .{ .rect = RegionIterator.all },
    }) |expected| try testing.expectEqualDeep(expected, it.next().?);
    try testing.expect(it.next() == null);
}

test "Update: incomplete coordinates are ignored" {
    // A trailing point missing its column, then a trailing rectangle
    // missing its last edge. Neither completes, so neither is yielded.
    var it = testUpdate(
        .{ .paint = .block },
        &.{ 1, 2, 1, 1, 3, 4, 1, 1, 2, 2, 5 },
        &.{ 1, 2, 3, 5, 6, 7, 8, 9 },
    ).regions();

    try testing.expectEqualDeep(
        Region{ .rect = .{ .top = 1, .left = 1, .bottom = 1, .right = 1 } },
        it.next().?,
    );
    try testing.expectEqualDeep(
        Region{ .rect = .{ .top = 1, .left = 1, .bottom = 2, .right = 2 } },
        it.next().?,
    );
    try testing.expect(it.next() == null);
}

test "Update: only a bare rectangle type means the whole screen" {
    // `4` alone is the whole screen. `4:1:2:3` is an incomplete
    // rectangle, and the spec says to ignore those. Reading it as the
    // whole screen would paint over everything.
    var bare = testUpdate(.{ .paint = .block }, &.{ 1, 4 }, &.{}).regions();
    try testing.expectEqualDeep(
        Region{ .rect = RegionIterator.all },
        bare.next().?,
    );
    try testing.expect(bare.next() == null);

    var partial = testUpdate(
        .{ .paint = .block },
        &.{ 1, 4, 1, 2, 3 },
        &.{ 1, 2, 3 },
    ).regions();
    try testing.expect(partial.next() == null);
}

test "Command: decode" {
    const seps: Parser.Action.CSI.SepList = .initEmpty();
    const S = struct {
        fn csi(
            intermediates: []const u8,
            params: []const u16,
            final: u8,
            sep: *const Parser.Action.CSI.SepList,
        ) Parser.Action.CSI {
            return .{
                .intermediates = intermediates,
                .params = params,
                .params_sep = sep,
                .final = final,
            };
        }
    };

    try testing.expectEqual(
        Query.support,
        Command.decode(S.csi("> ", &.{}, 'q', &seps)).?.query,
    );
    try testing.expectEqual(
        Query.cursors,
        Command.decode(S.csi("> ", &.{100}, 'q', &seps)).?.query,
    );
    try testing.expectEqual(
        Query.colors,
        Command.decode(S.csi("> ", &.{101}, 'q', &seps)).?.query,
    );

    // A lone paint operation is an update, not a query.
    try testing.expectEqual(
        Operation{ .paint = .block },
        Command.decode(S.csi("> ", &.{1}, 'q', &seps)).?.update.operation,
    );
    try testing.expectEqual(
        Operation.text_color,
        Command.decode(S.csi("> ", &.{ 30, 0 }, 'q', &seps)).?.update.operation,
    );

    // ...but one with no coordinate groups targets nothing.
    var bare = Command.decode(S.csi("> ", &.{1}, 'q', &seps)).?.update.regions();
    try testing.expect(bare.next() == null);

    // Not this protocol: the wrong final byte, the wrong intermediates
    // (that one is DECSCUSR), or an operation we don't implement.
    try testing.expect(Command.decode(S.csi("> ", &.{1}, 'p', &seps)) == null);
    try testing.expect(Command.decode(S.csi(" ", &.{1}, 'q', &seps)) == null);
    try testing.expect(Command.decode(S.csi("> ", &.{99}, 'q', &seps)) == null);
}

test "Command: C value" {
    const query = (Command{ .query = .colors }).cval();
    try testing.expectEqual(Command.C.Kind.query_colors, query.kind);
    try testing.expectEqual(0, query.params_len);

    const params = [_]u16{ 29, 2, 1, 1, 2, 2, 2 };
    const update = (Command{
        .update = testUpdate(.{ .paint = .follow }, &params, &.{ 1, 2, 4, 5 }),
    }).cval();

    try testing.expectEqual(Command.C.Kind.paint, update.kind);
    try testing.expectEqual(Shape.follow, update.shape);
    try testing.expectEqualSlices(
        u16,
        &params,
        update.params[0..update.params_len],
    );

    // Parameters 1, 2, 4 and 5 are followed by ':'.
    try testing.expectEqual(@as(u8, 0b0011_0110), update.params_sep[0]);
    try testing.expect(std.mem.allEqual(u8, update.params_sep[1..], 0));
}

test "Color: decode and encode" {
    const cases = .{
        .{ @as(u16, 0), &[_]u16{}, Color.unset, "0" },
        .{ @as(u16, 1), &[_]u16{}, Color.special, "1" },
        .{
            @as(u16, 2),
            &[_]u16{ 274, 564, 854 },
            Color.rgb(0x12, 0x34, 0x56),
            "2:18:52:86",
        },
        .{
            @as(u16, 5),
            &[_]u16{263},
            Color{ .value = .{ .palette = 7 } },
            "5:7",
        },
    };

    // The payloads above are all wider than a byte. Truncate them;
    // don't reject them.
    inline for (cases) |case| {
        const decoded = Color.decode(case[0], case[1]).?;
        try testing.expect(decoded.eql(case[2]));

        var buf: [32]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try decoded.encode(&w);
        try testing.expectEqualStrings(case[3], w.buffered());
    }

    // Truncated payloads and unknown color spaces decode to nothing.
    try testing.expect(Color.decode(2, &.{ 1, 2 }) == null);
    try testing.expect(Color.decode(5, &.{}) == null);
    try testing.expect(Color.decode(9, &.{}) == null);
}
