const std = @import("std");
const ui = @import("ui.zig");
const zsdl3 = @import("zsdl3");
const Machine = @import("../machine.zig").Machine;
const Vdp = @import("../video/vdp.zig").Vdp;

pub const DebuggerState = struct {
    pub const max_breakpoints: usize = 16;

    active: bool = false,
    step_mode: bool = false,
    running_to_breakpoint: bool = false,
    memory_address: u32 = 0x000000,
    tab: Tab = .cpu,
    breakpoints: [max_breakpoints]u32 = [_]u32{0} ** max_breakpoints,
    breakpoint_count: u8 = 0,

    pub const Tab = enum {
        cpu,
        memory,
        vdp,
        tiles,
    };

    pub fn toggle(self: *DebuggerState) void {
        self.active = !self.active;
        if (!self.active) {
            self.running_to_breakpoint = false;
        }
    }

    pub fn stepOnce(self: *DebuggerState) void {
        self.step_mode = true;
    }

    pub fn shouldStep(self: *DebuggerState) bool {
        if (self.step_mode) {
            self.step_mode = false;
            return true;
        }
        return false;
    }

    pub fn runToBreakpoint(self: *DebuggerState) void {
        if (self.breakpoint_count > 0) {
            self.running_to_breakpoint = true;
        }
    }

    pub fn stopRunning(self: *DebuggerState) void {
        self.running_to_breakpoint = false;
    }

    pub fn hasBreakpoint(self: *const DebuggerState, address: u32) bool {
        const masked = address & 0xFFFFFF;
        for (self.breakpoints[0..self.breakpoint_count]) |bp| {
            if (bp == masked) return true;
        }
        return false;
    }

    pub fn toggleBreakpoint(self: *DebuggerState, address: u32) void {
        const masked = address & 0xFFFFFF;
        // If already set, remove it.
        for (0..self.breakpoint_count) |i| {
            if (self.breakpoints[i] == masked) {
                self.breakpoints[i] = self.breakpoints[self.breakpoint_count - 1];
                self.breakpoint_count -= 1;
                return;
            }
        }
        // Otherwise add if there is room.
        if (self.breakpoint_count < max_breakpoints) {
            self.breakpoints[self.breakpoint_count] = masked;
            self.breakpoint_count += 1;
        }
    }

    pub fn adjustMemoryAddress(self: *DebuggerState, delta: i32) void {
        if (delta < 0) {
            const sub: u32 = @intCast(-delta);
            self.memory_address -|= sub;
        } else {
            self.memory_address +|= @intCast(delta);
        }
        self.memory_address &= 0xFFFFF0;
    }

    pub fn nextTab(self: *DebuggerState) void {
        self.tab = switch (self.tab) {
            .cpu => .memory,
            .memory => .vdp,
            .vdp => .tiles,
            .tiles => .cpu,
        };
    }

    pub fn prevTab(self: *DebuggerState) void {
        self.tab = switch (self.tab) {
            .cpu => .tiles,
            .memory => .cpu,
            .vdp => .memory,
            .tiles => .vdp,
        };
    }
};

/// Compute a debugger-specific scale that fits the panel in the viewport.
/// Uses the standard overlay scale as a starting point, then shrinks if needed.
fn debuggerScale(viewport: zsdl3.Rect) f32 {
    const base = ui.overlayScale(viewport);
    const vw: f32 = @floatFromInt(viewport.w);
    const vh: f32 = @floatFromInt(viewport.h);
    // The widest content is the memory tab: "XXXXXX " + 16*"XX " = 7+48 = 55 chars
    // Panel width = 55 * 6 * scale + 2 * 10 * scale + margin
    // Panel height = ~20 lines * 10 * scale + header/footer
    const required_w = 55.0 * 6.0 * base + 30.0 * base;
    const required_h = 22.0 * 10.0 * base + 30.0 * base;
    const margin = 8.0 * base;
    if (required_w + margin <= vw and required_h + margin <= vh) return base;
    // Try smaller scales
    const scales = [_]f32{ 2.0, 1.5, 1.0 };
    for (scales) |s| {
        if (s >= base) continue;
        const rw = 55.0 * 6.0 * s + 30.0 * s;
        const rh = 22.0 * 10.0 * s + 30.0 * s;
        const m = 8.0 * s;
        if (rw + m <= vw and rh + m <= vh) return s;
    }
    return 1.0;
}

/// Compute how many memory rows fit in the available content height.
fn memoryRowCount(content_h: f32, line_h: f32) usize {
    // header (1.5 lines) + rows + nothing extra
    const available = content_h - line_h * 1.5;
    if (available <= 0) return 0;
    const rows = @as(usize, @intFromFloat(available / line_h));
    return @min(rows, 32);
}

/// Maximum bytes per row in the memory hex view. The line buffer in
/// renderMemoryTab is sized to fit this; update both if raising it.
const max_bytes_per_row: usize = 16;

/// Compute how many hex bytes per row fit in the available content width.
fn memoryBytesPerRow(content_w: f32, glyph_w: f32) usize {
    // "XXXXXX " prefix = 7 chars, then each byte = "XX " = 3 chars (last one 2)
    const prefix_w = 7.0 * glyph_w;
    const remaining = content_w - prefix_w;
    if (remaining <= 0) return 0;
    const bytes = @as(usize, @intFromFloat(remaining / (3.0 * glyph_w)));
    // Clamp to power-of-2 for clean alignment
    if (bytes >= 16) return 16;
    if (bytes >= 8) return 8;
    return 4;
}

pub fn render(
    renderer: *zsdl3.Renderer,
    viewport: zsdl3.Rect,
    machine: *const Machine,
    state: *const DebuggerState,
) !void {
    const vw: f32 = @floatFromInt(viewport.w);
    const vh: f32 = @floatFromInt(viewport.h);
    const scale = debuggerScale(viewport);
    const line_h = 10.0 * scale;
    const padding = 8.0 * scale;
    const glyph_w = 6.0 * scale;
    const margin = 4.0 * scale;

    // Measure content width based on active tab
    const tab_cols: f32 = switch (state.tab) {
        .cpu => 28.0, // "D0 XXXXXXXX  D4 XXXXXXXX" = 28 chars
        .memory => blk: {
            const bpr = memoryBytesPerRow(vw - margin * 2 - padding * 2, glyph_w);
            break :blk @as(f32, @floatFromInt(7 + bpr * 3));
        },
        .vdp => 28.0, // "MODE H40 LINE 224/224" ~ 24 chars
        .tiles => 36.0, // palette row + tile grid needs width
    };
    // Footer is the widest fixed text; ensure panel fits it
    const footer_cols: f32 = 36.0; // "F10 CLOSE  TAB TABS  PGUP/DN SCROLL"
    const content_cols = @max(tab_cols, footer_cols);
    const panel_w_raw = content_cols * glyph_w + padding * 2;
    const panel_w = @min(panel_w_raw, vw - margin * 2);

    // Measure content height based on active tab
    const tab_lines: f32 = switch (state.tab) {
        .cpu => 18.5, // PC + SP + flags + 4 D-regs + gap + 4 A-regs + gap + header + 6 disasm
        .memory => blk: {
            const rows = memoryRowCount(vh - margin * 2 - padding * 2 - line_h * 3.5, line_h);
            break :blk 1.5 + @as(f32, @floatFromInt(rows));
        },
        .vdp => 17.5, // header + 12 reg pairs + gap + mode + flags + addr + dma
        .tiles => 22.0, // palette header + palette + gap + tile header + tile grid
    };
    // tab header (1.5) + tab content + footer (1)
    const total_lines = 1.5 + tab_lines + 1.5;
    const panel_h_raw = total_lines * line_h + padding * 2;
    const panel_h = @min(panel_h_raw, vh - margin * 2);

    // Position: right-aligned, clamped to viewport
    const panel_x = @max(margin, vw - panel_w - margin);
    const panel_y = margin;

    ui.renderPanel(renderer, .{ .x = panel_x, .y = panel_y, .w = panel_w, .h = panel_h }, ui.Colors.panel_primary, ui.Colors.blue, scale) catch {};
    ui.setClipRect(renderer, .{ .x = panel_x, .y = panel_y, .w = panel_w, .h = panel_h }) catch {};
    defer ui.clearClipRect(renderer) catch {};

    const content_x = panel_x + padding;
    const content_w = panel_w - padding * 2;
    var y = panel_y + padding;

    // Tab header
    {
        const cpu_color = if (state.tab == .cpu) ui.Colors.cyan else ui.Colors.text_muted;
        const mem_color = if (state.tab == .memory) ui.Colors.cyan else ui.Colors.text_muted;
        const vdp_color = if (state.tab == .vdp) ui.Colors.cyan else ui.Colors.text_muted;
        const tile_color = if (state.tab == .tiles) ui.Colors.cyan else ui.Colors.text_muted;
        try ui.drawText(renderer, content_x, y, scale, cpu_color, "CPU");
        try ui.drawText(renderer, content_x + glyph_w * 5, y, scale, mem_color, "MEM");
        try ui.drawText(renderer, content_x + glyph_w * 10, y, scale, vdp_color, "VDP");
        try ui.drawText(renderer, content_x + glyph_w * 15, y, scale, tile_color, "TILE");
        y += line_h * 1.5;
    }

    const content_bottom = panel_y + panel_h - padding - line_h * 1.5;

    switch (state.tab) {
        .cpu => try renderCpuTab(renderer, machine, state, content_x, y, content_bottom, scale, line_h),
        .memory => try renderMemoryTab(renderer, machine, state, content_x, y, content_bottom, scale, line_h, glyph_w, content_w),
        .vdp => try renderVdpTab(renderer, machine, content_x, y, content_bottom, scale, line_h),
        .tiles => try renderTileTab(renderer, machine, content_x, y, content_bottom, scale, line_h, glyph_w),
    }

    // Footer
    const footer_y = panel_y + panel_h - padding - line_h;
    const footer_text = switch (state.tab) {
        .cpu => "[SPC] STEP [B] BRK [G] RUN [F10] CLOSE [TAB] TABS",
        .memory => "[F10] CLOSE  [TAB] TABS  [PGUP/DN] SCROLL",
        .vdp => "[F10] CLOSE  [TAB] TABS  [SPACE] STEP",
        .tiles => "[F10] CLOSE  [TAB] TABS  [PGUP/DN] PAGE",
    };
    try ui.drawText(renderer, content_x, footer_y, scale, ui.Colors.text_muted, footer_text);
}

fn renderCpuTab(
    renderer: *zsdl3.Renderer,
    machine: *const Machine,
    state: *const DebuggerState,
    x: f32,
    start_y: f32,
    max_y: f32,
    scale: f32,
    line_h: f32,
) !void {
    var y = start_y;
    var buf: [64]u8 = undefined;

    const pc = machine.programCounter();
    const sr = @as(u16, machine.cpu.core.sr);
    const sp = machine.stackPointer();

    if (y + line_h > max_y) return;
    const pc_text = std.fmt.bufPrint(&buf, "PC {X:0>8}  SR {X:0>4}", .{ pc, sr }) catch "???";
    try ui.drawText(renderer, x, y, scale, ui.Colors.gold, pc_text);
    y += line_h;

    if (y + line_h > max_y) return;
    const sp_text = std.fmt.bufPrint(&buf, "SP {X:0>8}", .{sp}) catch "???";
    try ui.drawText(renderer, x, y, scale, ui.Colors.text_primary, sp_text);
    y += line_h;

    if (y + line_h > max_y) return;
    const flags_text = std.fmt.bufPrint(&buf, "   T{d} S{d} I{d} XNZVC={d}{d}{d}{d}{d}", .{
        @as(u1, @truncate((sr >> 15) & 1)),
        @as(u1, @truncate((sr >> 13) & 1)),
        @as(u3, @truncate((sr >> 8) & 7)),
        @as(u1, @truncate((sr >> 4) & 1)),
        @as(u1, @truncate((sr >> 3) & 1)),
        @as(u1, @truncate((sr >> 2) & 1)),
        @as(u1, @truncate((sr >> 1) & 1)),
        @as(u1, @truncate(sr & 1)),
    }) catch "???";
    try ui.drawText(renderer, x, y, scale, ui.Colors.text_secondary, flags_text);
    y += line_h * 1.5;

    // Data registers
    for (0..4) |i| {
        if (y + line_h > max_y) return;
        const d_lo: u32 = machine.cpu.core.d_regs[i].l;
        const d_hi: u32 = machine.cpu.core.d_regs[i + 4].l;
        const reg_text = std.fmt.bufPrint(&buf, "D{d} {X:0>8}  D{d} {X:0>8}", .{ i, d_lo, i + 4, d_hi }) catch "???";
        try ui.drawText(renderer, x, y, scale, ui.Colors.text_primary, reg_text);
        y += line_h;
    }
    y += line_h * 0.5;

    // Address registers
    for (0..4) |i| {
        if (y + line_h > max_y) return;
        const a_lo: u32 = machine.cpu.core.a_regs[i].l;
        const a_hi: u32 = machine.cpu.core.a_regs[i + 4].l;
        const reg_text = std.fmt.bufPrint(&buf, "A{d} {X:0>8}  A{d} {X:0>8}", .{ i, a_lo, i + 4, a_hi }) catch "???";
        try ui.drawText(renderer, x, y, scale, ui.Colors.text_primary, reg_text);
        y += line_h;
    }
    y += line_h * 0.5;

    if (y + line_h > max_y) return;
    try ui.drawText(renderer, x, y, scale, ui.Colors.cyan, "DISASSEMBLY");
    y += line_h;

    for (0..6) |i| {
        if (y + line_h > max_y) return;
        const addr = pc +% @as(u32, @intCast(i * 2));
        const word = readWordSafe(machine, addr);
        const prefix: []const u8 = if (state.hasBreakpoint(addr)) "* " else "  ";
        const dis_text = std.fmt.bufPrint(&buf, "{s}{X:0>6}  {X:0>4}", .{ prefix, addr & 0xFFFFFF, word }) catch "???";
        const color = if (i == 0) ui.Colors.gold else if (state.hasBreakpoint(addr)) ui.Colors.orange else ui.Colors.text_secondary;
        try ui.drawText(renderer, x, y, scale, color, dis_text);
        y += line_h;
    }
}

fn renderMemoryTab(
    renderer: *zsdl3.Renderer,
    machine: *const Machine,
    state: *const DebuggerState,
    x: f32,
    start_y: f32,
    max_y: f32,
    scale: f32,
    line_h: f32,
    glyph_w: f32,
    content_w: f32,
) !void {
    var y = start_y;
    var buf: [80]u8 = undefined;

    const bytes_per_row = memoryBytesPerRow(content_w, glyph_w);
    const row_count = memoryRowCount(max_y - start_y, line_h);

    const addr_text = std.fmt.bufPrint(&buf, "ADDRESS {X:0>6}", .{state.memory_address & 0xFFFFFF}) catch "???";
    try ui.drawText(renderer, x, y, scale, ui.Colors.cyan, addr_text);
    y += line_h * 1.5;

    for (0..row_count) |row| {
        if (y + line_h > max_y) break;
        const row_addr = (state.memory_address +% @as(u32, @intCast(row * bytes_per_row))) & 0xFFFFFF;
        // 7 (address + space) + bytes_per_row * 3 (hex + space); 80 is enough for max_bytes_per_row=16.
        var line_buf: [7 + max_bytes_per_row * 3]u8 = undefined;
        var pos: usize = 0;

        const addr_str = std.fmt.bufPrint(line_buf[pos..], "{X:0>6} ", .{row_addr}) catch break;
        pos += addr_str.len;

        for (0..bytes_per_row) |col| {
            const byte_addr = row_addr +% @as(u32, @intCast(col));
            const byte = readByteSafe(machine, byte_addr);
            const hex = std.fmt.bufPrint(line_buf[pos..], "{X:0>2}", .{byte}) catch break;
            pos += hex.len;
            if (col < bytes_per_row - 1) {
                if (pos >= line_buf.len) break;
                line_buf[pos] = ' ';
                pos += 1;
            }
        }

        try ui.drawText(renderer, x, y, scale, ui.Colors.text_primary, line_buf[0..pos]);
        y += line_h;
    }
}

fn renderVdpTab(
    renderer: *zsdl3.Renderer,
    machine: *const Machine,
    x: f32,
    start_y: f32,
    max_y: f32,
    scale: f32,
    line_h: f32,
) !void {
    var y = start_y;
    var buf: [64]u8 = undefined;
    const vdp = &machine.bus.vdp;

    if (y + line_h > max_y) return;
    try ui.drawText(renderer, x, y, scale, ui.Colors.cyan, "VDP REGISTERS");
    y += line_h;

    for (0..12) |i| {
        if (y + line_h > max_y) return;
        const r0 = vdp.regs[i * 2];
        const r1 = vdp.regs[i * 2 + 1];
        const reg_text = std.fmt.bufPrint(&buf, "R{d:0>2} {X:0>2}  R{d:0>2} {X:0>2}", .{ i * 2, r0, i * 2 + 1, r1 }) catch "???";
        try ui.drawText(renderer, x, y, scale, ui.Colors.text_primary, reg_text);
        y += line_h;
    }
    y += line_h * 0.5;

    if (y + line_h > max_y) return;
    const mode_text = std.fmt.bufPrint(&buf, "MODE {s} LINE {d:>3}/{d:>3}", .{
        if (vdp.isH40()) "H40" else "H32",
        vdp.scanline,
        vdp.activeVisibleLines(),
    }) catch "???";
    try ui.drawText(renderer, x, y, scale, ui.Colors.text_primary, mode_text);
    y += line_h;

    if (y + line_h > max_y) return;
    const flags_text = std.fmt.bufPrint(&buf, "VBL={d} HBL={d} DMA={d} IE={d}", .{
        @as(u1, @intFromBool(vdp.vblank)),
        @as(u1, @intFromBool(vdp.hblank)),
        @as(u1, @intFromBool(vdp.dma_active)),
        @as(u1, @intFromBool(vdp.isDisplayEnabled())),
    }) catch "???";
    try ui.drawText(renderer, x, y, scale, ui.Colors.text_secondary, flags_text);
    y += line_h;

    if (y + line_h > max_y) return;
    const addr_text = std.fmt.bufPrint(&buf, "ADDR {X:0>4} CODE {X:0>2}", .{ vdp.addr, vdp.code }) catch "???";
    try ui.drawText(renderer, x, y, scale, ui.Colors.text_secondary, addr_text);
    y += line_h;

    if (vdp.dma_active) {
        if (y + line_h > max_y) return;
        const dma_text = std.fmt.bufPrint(&buf, "DMA SRC={X:0>6} REM={d}", .{ vdp.dma_source_addr & 0xFFFFFF, vdp.dma_remaining }) catch "???";
        try ui.drawText(renderer, x, y, scale, ui.Colors.orange, dma_text);
    }
}

fn renderTileTab(
    renderer: *zsdl3.Renderer,
    machine: *const Machine,
    x: f32,
    start_y: f32,
    max_y: f32,
    scale: f32,
    line_h: f32,
    glyph_w: f32,
) !void {
    var y = start_y;
    var buf: [64]u8 = undefined;
    const vdp = &machine.bus.vdp;

    // Palette viewer: show all 4 palettes (16 colors each).
    if (y + line_h > max_y) return;
    try ui.drawText(renderer, x, y, scale, ui.Colors.cyan, "CRAM PALETTE");
    y += line_h;

    const swatch_sz = @max(glyph_w, scale * 4.0);
    const swatch_gap = scale;
    for (0..4) |pal| {
        if (y + swatch_sz > max_y) break;
        // Palette label
        const pal_label = std.fmt.bufPrint(&buf, "P{d}", .{pal}) catch "?";
        try ui.drawText(renderer, x, y, scale * 0.8, ui.Colors.text_muted, pal_label);
        const swatch_x_start = x + glyph_w * 3;

        for (0..16) |color_idx| {
            const cram_idx: u8 = @intCast(pal * 16 + color_idx);
            const argb = vdp.getPaletteColor(cram_idx);
            const r: u8 = @truncate((argb >> 16) & 0xFF);
            const g: u8 = @truncate((argb >> 8) & 0xFF);
            const b: u8 = @truncate(argb & 0xFF);
            const sx = swatch_x_start + @as(f32, @floatFromInt(color_idx)) * (swatch_sz + swatch_gap);
            try zsdl3.setRenderDrawColor(renderer, .{ .r = r, .g = g, .b = b, .a = 0xFF });
            try zsdl3.renderFillRect(renderer, .{ .x = sx, .y = y, .w = swatch_sz, .h = swatch_sz });
        }
        y += swatch_sz + swatch_gap;
    }
    y += line_h * 0.5;

    // Tile grid: show VRAM patterns rendered with palette 0.
    if (y + line_h > max_y) return;
    try ui.drawText(renderer, x, y, scale, ui.Colors.cyan, "VRAM TILES (PAL 0)");
    y += line_h;

    // Each tile is 8x8 pixels; render at 1px = scale pixels.
    const px_sz = scale;
    const tile_px: f32 = 8.0 * px_sz;
    const tile_gap = scale * 0.5;

    // Compute how many tiles fit in the available width and height.
    const avail_w = @as(f32, @floatFromInt(machine.bus.vdp.screenWidth())) * scale * 1.2;
    const cols = @max(@as(usize, 1), @as(usize, @intFromFloat(avail_w / (tile_px + tile_gap))));
    const avail_h = max_y - y;
    const rows = @max(@as(usize, 1), @as(usize, @intFromFloat(avail_h / (tile_px + tile_gap))));
    const total_tiles = 64 * 1024 / 32; // 2048 tiles in 64KB VRAM
    _ = total_tiles;

    // Page offset: reuse memory_address scrolled by tile count.
    // Each PGUP/PGDN moves 256 bytes → 8 tiles.
    const tile_page_offset: usize = 0; // Could be driven by state in the future.

    for (0..rows) |tile_row| {
        const ty = y + @as(f32, @floatFromInt(tile_row)) * (tile_px + tile_gap);
        if (ty + tile_px > max_y) break;

        for (0..cols) |tile_col| {
            const tile_idx = tile_page_offset + tile_row * cols + tile_col;
            if (tile_idx >= 2048) break;

            const tx = x + @as(f32, @floatFromInt(tile_col)) * (tile_px + tile_gap);
            const pattern_base: u32 = @as(u32, @intCast(tile_idx)) * 32;

            // Render 8 rows of 8 pixels each.
            for (0..8) |row| {
                const row_addr = pattern_base + @as(u32, @intCast(row)) * 4;
                const b0 = vdp.vramReadByte(@intCast(row_addr & 0xFFFF));
                const b1 = vdp.vramReadByte(@intCast((row_addr + 1) & 0xFFFF));
                const b2 = vdp.vramReadByte(@intCast((row_addr + 2) & 0xFFFF));
                const b3 = vdp.vramReadByte(@intCast((row_addr + 3) & 0xFFFF));
                const bytes = [4]u8{ b0, b1, b2, b3 };

                for (0..8) |col| {
                    const byte_idx = col >> 1;
                    const color_idx: u8 = if ((col & 1) == 0)
                        (bytes[byte_idx] >> 4) & 0xF
                    else
                        bytes[byte_idx] & 0xF;

                    if (color_idx == 0) continue; // transparent

                    const argb = vdp.getPaletteColor(color_idx);
                    const r: u8 = @truncate((argb >> 16) & 0xFF);
                    const g: u8 = @truncate((argb >> 8) & 0xFF);
                    const b: u8 = @truncate(argb & 0xFF);
                    const px = tx + @as(f32, @floatFromInt(col)) * px_sz;
                    const py = ty + @as(f32, @floatFromInt(row)) * px_sz;
                    try zsdl3.setRenderDrawColor(renderer, .{ .r = r, .g = g, .b = b, .a = 0xFF });
                    try zsdl3.renderFillRect(renderer, .{ .x = px, .y = py, .w = px_sz, .h = px_sz });
                }
            }
        }
    }
}

fn readByteSafe(machine: *const Machine, address: u32) u8 {
    const addr = address & 0xFFFFFF;
    if (addr < machine.bus.rom.len) {
        return machine.bus.rom[addr];
    }
    if (addr >= 0xFF0000) {
        return machine.bus.ram[addr & 0xFFFF];
    }
    return 0;
}

fn readWordSafe(machine: *const Machine, address: u32) u16 {
    const hi = readByteSafe(machine, address);
    const lo = readByteSafe(machine, address +% 1);
    return (@as(u16, hi) << 8) | lo;
}

test "breakpoint toggle adds and removes addresses" {
    var state = DebuggerState{};

    state.toggleBreakpoint(0x000200);
    try std.testing.expectEqual(@as(u8, 1), state.breakpoint_count);
    try std.testing.expect(state.hasBreakpoint(0x000200));
    try std.testing.expect(!state.hasBreakpoint(0x000202));

    state.toggleBreakpoint(0x001000);
    try std.testing.expectEqual(@as(u8, 2), state.breakpoint_count);
    try std.testing.expect(state.hasBreakpoint(0x001000));

    // Toggle off the first breakpoint.
    state.toggleBreakpoint(0x000200);
    try std.testing.expectEqual(@as(u8, 1), state.breakpoint_count);
    try std.testing.expect(!state.hasBreakpoint(0x000200));
    try std.testing.expect(state.hasBreakpoint(0x001000));
}

test "breakpoint addresses are masked to 24 bits" {
    var state = DebuggerState{};

    state.toggleBreakpoint(0xFF000200);
    try std.testing.expect(state.hasBreakpoint(0x000200));
    try std.testing.expect(state.hasBreakpoint(0xFF000200));
}

test "run to breakpoint requires at least one breakpoint" {
    var state = DebuggerState{};

    state.runToBreakpoint();
    try std.testing.expect(!state.running_to_breakpoint);

    state.toggleBreakpoint(0x000200);
    state.runToBreakpoint();
    try std.testing.expect(state.running_to_breakpoint);

    state.stopRunning();
    try std.testing.expect(!state.running_to_breakpoint);
}
