const std = @import("std");
const ui = @import("ui.zig");
const zsdl3 = @import("zsdl3");
const Machine = @import("../machine.zig").Machine;
const Vdp = @import("../video/vdp.zig").Vdp;

pub const DebuggerState = struct {
    active: bool = false,
    step_mode: bool = false,
    memory_address: u32 = 0x000000,
    tab: Tab = .cpu,

    pub const Tab = enum {
        cpu,
        memory,
        vdp,
    };

    pub fn toggle(self: *DebuggerState) void {
        self.active = !self.active;
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
            .vdp => .cpu,
        };
    }

    pub fn prevTab(self: *DebuggerState) void {
        self.tab = switch (self.tab) {
            .cpu => .vdp,
            .memory => .cpu,
            .vdp => .memory,
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
    };
    // tab header (1.5) + tab content + footer (1)
    const total_lines = 1.5 + tab_lines + 1.5;
    const panel_h_raw = total_lines * line_h + padding * 2;
    const panel_h = @min(panel_h_raw, vh - margin * 2);

    // Position: right-aligned, clamped to viewport
    const panel_x = @max(margin, vw - panel_w - margin);
    const panel_y = margin;

    ui.renderPanel(renderer, .{ .x = panel_x, .y = panel_y, .w = panel_w, .h = panel_h }, ui.Colors.panel_primary, ui.Colors.cyan, scale) catch {};

    const content_x = panel_x + padding;
    const content_w = panel_w - padding * 2;
    var y = panel_y + padding;

    // Tab header
    {
        const cpu_color = if (state.tab == .cpu) ui.Colors.cyan else ui.Colors.text_muted;
        const mem_color = if (state.tab == .memory) ui.Colors.cyan else ui.Colors.text_muted;
        const vdp_color = if (state.tab == .vdp) ui.Colors.cyan else ui.Colors.text_muted;
        try ui.drawText(renderer, content_x, y, scale, cpu_color, "CPU");
        try ui.drawText(renderer, content_x + glyph_w * 5, y, scale, mem_color, "MEM");
        try ui.drawText(renderer, content_x + glyph_w * 10, y, scale, vdp_color, "VDP");
        y += line_h * 1.5;
    }

    const content_bottom = panel_y + panel_h - padding - line_h * 1.5;

    switch (state.tab) {
        .cpu => try renderCpuTab(renderer, machine, content_x, y, content_bottom, scale, line_h),
        .memory => try renderMemoryTab(renderer, machine, state, content_x, y, content_bottom, scale, line_h, glyph_w, content_w),
        .vdp => try renderVdpTab(renderer, machine, content_x, y, content_bottom, scale, line_h),
    }

    // Footer
    const footer_y = panel_y + panel_h - padding - line_h;
    const footer_text = switch (state.tab) {
        .cpu => "F10 CLOSE  TAB TABS  SPACE STEP",
        .memory => "F10 CLOSE  TAB TABS  PGUP/DN SCROLL",
        .vdp => "F10 CLOSE  TAB TABS  SPACE STEP",
    };
    try ui.drawText(renderer, content_x, footer_y, scale, ui.Colors.text_muted, footer_text);
}

fn renderCpuTab(
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
        const dis_text = std.fmt.bufPrint(&buf, "  {X:0>6}  {X:0>4}", .{ addr & 0xFFFFFF, word }) catch "???";
        const color = if (i == 0) ui.Colors.gold else ui.Colors.text_secondary;
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
