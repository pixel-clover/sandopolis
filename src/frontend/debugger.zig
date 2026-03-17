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
        self.memory_address &= 0xFFFFF0; // Align to 16-byte boundary
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

pub fn render(
    renderer: *zsdl3.Renderer,
    viewport: zsdl3.Rect,
    machine: *const Machine,
    state: *const DebuggerState,
) !void {
    const scale = ui.overlayScale(viewport);
    const line_h = 10.0 * scale;
    const padding = 10.0 * scale;
    const glyph_w = 6.0 * scale;

    // Panel dimensions — right-aligned
    const panel_w: f32 = glyph_w * 42 + padding * 2;
    const panel_h: f32 = line_h * 28 + padding * 2;
    const panel_x: f32 = @as(f32, @floatFromInt(viewport.w)) - panel_w - padding;
    const panel_y: f32 = padding;

    // Draw panel background
    ui.renderPanel(renderer, .{ .x = panel_x, .y = panel_y, .w = panel_w, .h = panel_h }, ui.Colors.panel_primary, ui.Colors.cyan, scale) catch {};

    const content_x = panel_x + padding;
    var y = panel_y + padding;

    // Tab header
    {
        const cpu_color = if (state.tab == .cpu) ui.Colors.cyan else ui.Colors.text_muted;
        const mem_color = if (state.tab == .memory) ui.Colors.cyan else ui.Colors.text_muted;
        const vdp_color = if (state.tab == .vdp) ui.Colors.cyan else ui.Colors.text_muted;
        try ui.drawText(renderer, content_x, y, scale, cpu_color, "CPU");
        try ui.drawText(renderer, content_x + glyph_w * 6, y, scale, mem_color, "MEMORY");
        try ui.drawText(renderer, content_x + glyph_w * 15, y, scale, vdp_color, "VDP");
        y += line_h * 1.5;
    }

    switch (state.tab) {
        .cpu => try renderCpuTab(renderer, machine, content_x, y, scale, line_h),
        .memory => try renderMemoryTab(renderer, machine, state, content_x, y, scale, line_h),
        .vdp => try renderVdpTab(renderer, machine, content_x, y, scale, line_h),
    }

    // Footer
    const footer_y = panel_y + panel_h - padding - line_h;
    try ui.drawText(renderer, content_x, footer_y, scale, ui.Colors.text_muted, "F12 CLOSE  TAB SWITCH  F10 STEP");
}

fn renderCpuTab(
    renderer: *zsdl3.Renderer,
    machine: *const Machine,
    x: f32,
    start_y: f32,
    scale: f32,
    line_h: f32,
) !void {
    var y = start_y;
    var buf: [64]u8 = undefined;

    // Program counter and status
    const pc = machine.programCounter();
    const sr = @as(u16, machine.cpu.core.sr);
    const sp = machine.stackPointer();

    const pc_text = std.fmt.bufPrint(&buf, "PC {X:0>8}  SR {X:0>4}", .{ pc, sr }) catch "???";
    try ui.drawText(renderer, x, y, scale, ui.Colors.gold, pc_text);
    y += line_h;

    const sp_text = std.fmt.bufPrint(&buf, "SP {X:0>8}", .{sp}) catch "???";
    try ui.drawText(renderer, x, y, scale, ui.Colors.text_primary, sp_text);
    y += line_h;

    // SR flags
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
        const d_lo: u32 = machine.cpu.core.d_regs[i].l;
        const d_hi: u32 = machine.cpu.core.d_regs[i + 4].l;
        const reg_text = std.fmt.bufPrint(&buf, "D{d} {X:0>8}  D{d} {X:0>8}", .{ i, d_lo, i + 4, d_hi }) catch "???";
        try ui.drawText(renderer, x, y, scale, ui.Colors.text_primary, reg_text);
        y += line_h;
    }
    y += line_h * 0.5;

    // Address registers
    for (0..4) |i| {
        const a_lo: u32 = machine.cpu.core.a_regs[i].l;
        const a_hi: u32 = machine.cpu.core.a_regs[i + 4].l;
        const reg_text = std.fmt.bufPrint(&buf, "A{d} {X:0>8}  A{d} {X:0>8}", .{ i, a_lo, i + 4, a_hi }) catch "???";
        try ui.drawText(renderer, x, y, scale, ui.Colors.text_primary, reg_text);
        y += line_h;
    }
    y += line_h * 0.5;

    // Disassembly at PC (display the current instruction text)
    try ui.drawText(renderer, x, y, scale, ui.Colors.cyan, "DISASSEMBLY");
    y += line_h;

    // We can show the PC address and a placeholder since we can't call
    // formatCurrentInstruction on a const machine. Show raw bytes instead.
    for (0..6) |i| {
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
    scale: f32,
    line_h: f32,
) !void {
    var y = start_y;
    var buf: [80]u8 = undefined;

    const addr_text = std.fmt.bufPrint(&buf, "ADDRESS {X:0>6}  PGUP/PGDN", .{state.memory_address & 0xFFFFFF}) catch "???";
    try ui.drawText(renderer, x, y, scale, ui.Colors.cyan, addr_text);
    y += line_h * 1.5;

    // 16 rows x 16 bytes hex dump
    for (0..16) |row| {
        const row_addr = (state.memory_address +% @as(u32, @intCast(row * 16))) & 0xFFFFFF;
        var line_buf: [64]u8 = undefined;
        var pos: usize = 0;

        // Address
        const addr_str = std.fmt.bufPrint(line_buf[pos..], "{X:0>6} ", .{row_addr}) catch break;
        pos += addr_str.len;

        // 16 hex bytes
        for (0..16) |col| {
            const byte_addr = row_addr +% @as(u32, @intCast(col));
            const byte = readByteSafe(machine, byte_addr);
            const hex = std.fmt.bufPrint(line_buf[pos..], "{X:0>2}", .{byte}) catch break;
            pos += hex.len;
            if (col < 15) {
                if (pos < line_buf.len) {
                    line_buf[pos] = ' ';
                    pos += 1;
                }
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
    scale: f32,
    line_h: f32,
) !void {
    var y = start_y;
    var buf: [64]u8 = undefined;
    const vdp = &machine.bus.vdp;

    try ui.drawText(renderer, x, y, scale, ui.Colors.cyan, "VDP REGISTERS");
    y += line_h;

    // Display registers in pairs
    for (0..12) |i| {
        const r0 = vdp.regs[i * 2];
        const r1 = vdp.regs[i * 2 + 1];
        const reg_text = std.fmt.bufPrint(&buf, "R{d:0>2} {X:0>2}  R{d:0>2} {X:0>2}", .{ i * 2, r0, i * 2 + 1, r1 }) catch "???";
        try ui.drawText(renderer, x, y, scale, ui.Colors.text_primary, reg_text);
        y += line_h;
    }
    y += line_h * 0.5;

    // VDP state
    const mode_text = std.fmt.bufPrint(&buf, "MODE {s} LINE {d:>3}/{d:>3}", .{
        if (vdp.isH40()) "H40" else "H32",
        vdp.scanline,
        vdp.activeVisibleLines(),
    }) catch "???";
    try ui.drawText(renderer, x, y, scale, ui.Colors.text_primary, mode_text);
    y += line_h;

    const flags_text = std.fmt.bufPrint(&buf, "VBL={d} HBL={d} DMA={d} IE={d}", .{
        @as(u1, @intFromBool(vdp.vblank)),
        @as(u1, @intFromBool(vdp.hblank)),
        @as(u1, @intFromBool(vdp.dma_active)),
        @as(u1, @intFromBool(vdp.isDisplayEnabled())),
    }) catch "???";
    try ui.drawText(renderer, x, y, scale, ui.Colors.text_secondary, flags_text);
    y += line_h;

    const addr_text = std.fmt.bufPrint(&buf, "ADDR {X:0>4} CODE {X:0>2}", .{ vdp.addr, vdp.code }) catch "???";
    try ui.drawText(renderer, x, y, scale, ui.Colors.text_secondary, addr_text);
    y += line_h;

    if (vdp.dma_active) {
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
