const std = @import("std");

// Toast notification constants
pub const max_message_bytes: usize = 256;
pub const duration_frames: u64 = 180;

// Fixed-size message storage for toast notifications
pub const MessageCopy = struct {
    len: usize = 0,
    bytes: [max_message_bytes]u8 = [_]u8{0} ** max_message_bytes,

    pub fn slice(self: *const MessageCopy) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn set(self: *MessageCopy, message: []const u8) void {
        self.* = .{};
        const copy_len = @min(message.len, self.bytes.len);
        @memcpy(self.bytes[0..copy_len], message[0..copy_len]);
        self.len = copy_len;
    }
};

// Toast notification styles
pub const Style = enum {
    info,
    success,
    failure,
};

// Toast notification state
pub const Toast = struct {
    style: Style = .info,
    message: MessageCopy = .{},
    hide_after_frame: u64 = 0,

    pub fn visible(self: *const Toast, frame_number: u64) bool {
        return self.message.len != 0 and frame_number < self.hide_after_frame;
    }

    pub fn show(self: *Toast, style: Style, message: []const u8, frame_number: u64) void {
        self.style = style;
        self.message.set(message);
        self.hide_after_frame = frame_number + duration_frames;
    }

    pub fn slice(self: *const Toast) []const u8 {
        return self.message.slice();
    }
};

// Notification context for frontend operations
pub const Notifications = struct {
    toast: ?*Toast = null,
    frame_number: u64 = 0,
};

// Send a formatted notification to the frontend
pub fn notify(notifications: Notifications, style: Style, comptime fmt: []const u8, args: anytype) void {
    if (notifications.toast) |toast| {
        var buffer: [max_message_bytes]u8 = undefined;
        const message = std.fmt.bufPrint(buffer[0..], fmt, args) catch "MESSAGE TOO LONG";
        toast.show(style, message, notifications.frame_number);
    }
}
