const Z80 = @import("../cpu/z80.zig").Z80;

pub const HostReadByteFn = *const fn (ctx: ?*anyopaque, address: u32) u8;
pub const HostWriteByteFn = *const fn (ctx: ?*anyopaque, address: u32, value: u8) void;

pub const HostBridge = struct {
    ctx: ?*anyopaque,
    read_host_byte_fn: HostReadByteFn,
    write_host_byte_fn: HostWriteByteFn,

    pub fn init(read_host_byte_fn: HostReadByteFn, write_host_byte_fn: HostWriteByteFn) HostBridge {
        return .{
            .ctx = null,
            .read_host_byte_fn = read_host_byte_fn,
            .write_host_byte_fn = write_host_byte_fn,
        };
    }

    pub fn bind(self: *HostBridge, z80: *Z80, ctx: ?*anyopaque) void {
        self.ctx = ctx;
        z80.setHostCallbacks(self, readCallback, writeCallback);
    }

    fn readCallback(userdata: ?*anyopaque, address: u32) callconv(.c) u8 {
        const self: *HostBridge = @ptrCast(@alignCast(userdata orelse return 0xFF));
        const addr = address & 0xFFFFFF;
        if (addr >= 0xA00000 and addr < 0xA10000) return 0xFF;
        return self.read_host_byte_fn(self.ctx, addr);
    }

    fn writeCallback(userdata: ?*anyopaque, address: u32, value: u8) callconv(.c) void {
        const self: *HostBridge = @ptrCast(@alignCast(userdata orelse return));
        const addr = address & 0xFFFFFF;
        if (addr >= 0xA00000 and addr < 0xA10000) return;
        self.write_host_byte_fn(self.ctx, addr, value);
    }
};
