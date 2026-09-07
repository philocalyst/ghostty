const std = @import("std");
const terminal = @import("../terminal/main.zig");

/// Available cursor styles for drawing that renderers must support.
/// This is a superset of terminal cursor styles since the renderer supports
/// some additional cursor states such as the hollow block.
pub const Style = enum {
    // Typical cursor input styles
    block,
    block_hollow,
    bar,
    underline,

    // Special cursor styles
    lock,

    /// Create a cursor style from the terminal style request.
    pub fn fromTerminal(term: terminal.CursorStyle) Style {
        return switch (term) {
            .bar => .bar,
            .block => .block,
            .block_hollow => .block_hollow,
            .underline => .underline,
        };
    }
};

/// The frame-level inputs that decide whether a cursor is drawn.
///
/// Resolve these once per frame and hand the same value to `style` and
/// `extrasVisible`. Then the main cursor and the extras cannot answer
/// from different states.
pub const StyleOptions = struct {
    /// Whether an input method preedit is active on the cursor cell.
    preedit: bool = false,

    /// Whether the surface has keyboard focus. Losing it stops the blink
    /// timer, freezing `blink_visible` at whatever phase it was in.
    focused: bool = false,

    /// The current phase of the blink timer.
    blink_visible: bool = false,
};

/// Returns the cursor style to use for the current render state or null
/// if a cursor should not be rendered at all.
pub fn style(
    state: *const terminal.RenderState,
    opts: StyleOptions,
) ?Style {
    // Note the order of conditionals below is important. It represents
    // a priority system of how we determine what state overrides cursor
    // visibility and style.

    // The cursor must be visible in the viewport to be rendered.
    if (state.cursor.viewport == null) return null;

    // If we are in preedit, then we always show the block cursor. We do
    // this even if the cursor is explicitly not visible because it shows
    // an important editing state to the user.
    if (opts.preedit) return .block;

    // If we're at a password input its always a lock.
    if (state.cursor.password_input) return .lock;

    // If the cursor is explicitly not visible by terminal mode, we don't render.
    if (!state.cursor.visible) return null;

    // If we're not focused, our cursor is always visible so that
    // we can show the hollow box.
    if (!opts.focused) return .block_hollow;

    // If the cursor is blinking and our blink state is not visible,
    // then we don't show the cursor.
    if (state.cursor.blinking and !opts.blink_visible) return null;

    // Otherwise, we use whatever style the terminal wants.
    return .fromTerminal(state.cursor.visual_style);
}

/// Returns whether the kitty extra cursors are drawn for the current
/// render state.
///
/// This is the same priority system as `style` above, except that the
/// protocol opts out of most of it. Extra cursors are drawn regardless
/// of DECTCEM, focus, preedit, and password input, all of which speak
/// only about the main cursor. They do share the blink phase, so a
/// blinking terminal doesn't have half its cursors winking.
///
/// The `focused` guard is here because losing focus stops the blink
/// timer and freezes `blink_visible`. `style` can ignore that: it
/// returns a hollow block before it ever reads the phase. This has to
/// exclude it by hand.
pub fn extrasVisible(
    state: *const terminal.RenderState,
    opts: StyleOptions,
) bool {
    return !(opts.focused and
        state.cursor.blinking and
        !opts.blink_visible);
}

/// A cursor resolved down to what a renderer needs: where it goes, what
/// shape it takes, and the colors it and the text beneath it are drawn
/// with.
pub const Cursor = struct {
    x: terminal.size.CellCountInt,
    y: terminal.size.CellCountInt,
    wide: bool,
    style: Style,
    colors: Colors,

    /// A cursor's glyph color, paired with the color for the text that
    /// glyph covers.
    pub const Colors = struct {
        cursor: terminal.color.RGB,
        text: terminal.color.RGB,
    };
};

/// Every cursor to draw for one frame.
///
/// The main cursor sits in `main` and stays out of the iteration. The
/// renderer treats it differently anyway, since it alone drives the
/// shader uniforms. The kitty extra cursors come out of `next`.
///
/// `init` resolves everything the extras take from the frame, so `next`
/// stays a tight loop even with a screen full of them.
pub const Cursors = struct {
    state: *const terminal.RenderState,

    /// The main cursor, or null when it isn't drawn this frame.
    main: ?Cursor,

    /// Extra cursors not yet visited by `next`.
    extras: []const terminal.kitty.cursors.Cursor,

    /// What the protocol's `follow` shape resolves to: the style the
    /// main cursor is drawn with, or the one the terminal asked for when
    /// it isn't drawn. `follow` names a shape, not a state, so extras
    /// keep their shape while the main cursor blinks.
    follow: Style,

    /// The colors shared by every extra cursor, already resolved against
    /// the palette. Only meaningful when `mode` is `.shared`. The
    /// reversing modes derive their colors per cell.
    colors: Cursor.Colors,

    /// Which coloring rule this frame uses.
    mode: Mode,

    /// How the protocol's two color operations combine. Both are
    /// terminal-wide, so `init` decides this once for the frame.
    pub const Mode = enum {
        /// Neither color is `special`. Every extra cursor takes `colors`
        /// and never looks at the cell it covers.
        shared,

        /// The text color alone is `special`. The covered text takes the
        /// cell's background, so the glyph vanishes into it.
        reverse_text,

        /// The cursor color is `special`: full reverse video, which
        /// overrides whatever the text color says.
        reverse_video,
    };

    pub const Options = struct {
        /// The colors the main cursor is drawn with. Extra cursors
        /// inherit these wherever the protocol leaves a color unset.
        colors: Cursor.Colors,

        /// The main cursor's style as `style` resolved it, or null when
        /// it isn't drawn this frame.
        style: ?Style,

        /// The options `style` was resolved with. `extrasVisible` gets
        /// the same ones, so both answer from the same frame.
        visibility: StyleOptions,
    };

    pub fn init(
        state: *const terminal.RenderState,
        opts: Options,
    ) Cursors {
        const extras = &state.extra_cursors;
        return .{
            .state = state,
            .extras = if (extrasVisible(state, opts.visibility))
                extras.list.items
            else
                &.{},

            .follow = opts.style orelse
                .fromTerminal(state.cursor.visual_style),

            .mode = if (extras.cursor_color == .special)
                .reverse_video
            else if (extras.text_color == .special)
                .reverse_text
            else
                .shared,

            .colors = .{
                .cursor = explicitColor(state, extras.cursor_color) orelse
                    opts.colors.cursor,
                .text = explicitColor(state, extras.text_color) orelse
                    opts.colors.text,
            },

            .main = main: {
                const cursor_style = opts.style orelse break :main null;
                const viewport = state.cursor.viewport orelse break :main null;
                break :main .{
                    // On the spacer tail of a wide character the cursor
                    // moves back one cell, onto the character itself.
                    // The saturating subtract guards an x of zero, which
                    // well-formed input cannot produce.
                    .x = if (viewport.wide_tail)
                        viewport.x -| 1
                    else
                        viewport.x,
                    .y = viewport.y,
                    .wide = viewport.wide_tail or
                        state.cursor.cell.wide == .wide,
                    .style = cursor_style,
                    .colors = opts.colors,
                };
            },
        };
    }

    /// The next extra cursor to draw. This never returns the main
    /// cursor; that one is `main`.
    pub fn next(self: *Cursors) ?Cursor {
        while (self.extras.len > 0) {
            const extra = self.extras[0];
            self.extras = self.extras[1..];
            if (self.resolve(extra)) |cursor| return cursor;
        }
        return null;
    }

    /// Turn one protocol cursor into a drawable one. Null if it isn't
    /// drawn at all: erased, off the grid, or under the main cursor.
    fn resolve(
        self: Cursors,
        cursor: terminal.kitty.cursors.Cursor,
    ) ?Cursor {
        // The snapshot omits cursors outside the viewport, but it can be
        // stale: a resize may land between the snapshot and the render.
        // A cursor drawn outside the grid would land in nothing.
        if (cursor.x >= self.state.cols or
            cursor.y >= self.state.rows) return null;
        if (self.coveredByMain(cursor)) return null;

        const shape: Style = switch (cursor.shape) {
            .none => return null,
            .block => .block,
            .beam => .bar,
            .underline => .underline,
            .follow => self.follow,
        };

        return .{
            .x = cursor.x,
            .y = cursor.y,
            // The protocol addresses cells, so an extra cursor is one
            // cell wide even on a wide character.
            .wide = false,
            .style = shape,
            .colors = switch (self.mode) {
                .shared => self.colors,
                .reverse_text, .reverse_video => cell: {
                    const under = self.state.paintedAt(
                        cursor.x,
                        cursor.y,
                    ) orelse return null;
                    break :cell self.reverseVideo(under);
                },
            },
        };
    }

    /// Whether the main cursor is drawn over the given cursor's cell. A
    /// main cursor on a wide character covers both of its cells.
    fn coveredByMain(
        self: Cursors,
        cursor: terminal.kitty.cursors.Cursor,
    ) bool {
        const main = self.main orelse return false;
        if (main.y != cursor.y) return false;
        return cursor.x == main.x or
            (main.wide and cursor.x == main.x + 1);
    }

    /// Resolve the extras' colors against the cell a cursor sits on.
    /// Only the two modes where a color is `special` come here.
    ///
    /// This mirrors kitty's `resolve_extra_cursor_colors` in
    /// `kitty/shaders/background.slang` and the "Changing the color of
    /// extra cursors" section of the protocol spec.
    fn reverseVideo(
        self: Cursors,
        under: terminal.color.Pair,
    ) Cursor.Colors {
        if (self.mode == .reverse_text) return .{
            .cursor = self.colors.cursor,
            .text = under.background,
        };

        // Like kitty, an unreadable cell pair falls back to the terminal
        // defaults when those read better.
        const contrast = under.foreground.contrast(under.background);
        const fg = self.state.colors.foreground;
        const bg = self.state.colors.background;
        if (contrast < min_contrast and contrast < fg.contrast(bg)) {
            return .{ .cursor = fg, .text = bg };
        }

        return .{
            .cursor = under.foreground,
            .text = under.background,
        };
    }

    /// The contrast ratio below which kitty considers a cell's own
    /// colors unreadable under a reverse video cursor.
    const min_contrast = 2.5;

    /// The concrete color the protocol asked for, or null when the
    /// extras fall back to the main cursor's. `.special` is an effect,
    /// not a color, so it is null here too. See `reverseVideo`.
    fn explicitColor(
        state: *const terminal.RenderState,
        c: terminal.kitty.cursors.Color,
    ) ?terminal.color.RGB {
        return switch (c) {
            .special => null,
            .value => |v| v.toRGB(&state.colors.palette),
        };
    }
};

test "cursor: default uses configured style" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var term: terminal.Terminal = try .init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_blinking, true);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    try testing.expect(style(&state, .{ .preedit = false, .focused = true, .blink_visible = true }) == .bar);
    try testing.expect(style(&state, .{ .preedit = false, .focused = false, .blink_visible = true }) == .block_hollow);
    try testing.expect(style(&state, .{ .preedit = false, .focused = false, .blink_visible = false }) == .block_hollow);
    try testing.expect(style(&state, .{ .preedit = false, .focused = true, .blink_visible = false }) == null);
}

test "cursor: blinking disabled" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var term = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_blinking, false);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    try testing.expect(style(&state, .{ .focused = true, .blink_visible = true }) == .bar);
    try testing.expect(style(&state, .{ .focused = true, .blink_visible = false }) == .bar);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = true }) == .block_hollow);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = false }) == .block_hollow);
}

test "cursor: explicitly not visible" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var term = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    term.screens.active.cursor.cursor_style = .bar;
    term.modes.set(.cursor_visible, false);
    term.modes.set(.cursor_blinking, false);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    try testing.expect(style(&state, .{ .focused = true, .blink_visible = true }) == null);
    try testing.expect(style(&state, .{ .focused = true, .blink_visible = false }) == null);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = true }) == null);
    try testing.expect(style(&state, .{ .focused = false, .blink_visible = false }) == null);
}

test "cursor: always block with preedit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var term = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &term);

    // In any bool state
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = false }) == .block);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = false }) == .block);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = true }) == .block);
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = true }) == .block);

    // If we're scrolled though, then we don't show the cursor.
    for (0..100) |_| try term.index();
    term.scrollViewport(.{ .top = {} });
    try state.update(alloc, &term);

    // In any bool state
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = false }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = false }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = true, .blink_visible = true }) == null);
    try testing.expect(style(&state, .{ .preedit = true, .focused = false, .blink_visible = true }) == null);
}
