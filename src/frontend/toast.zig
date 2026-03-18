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

// Single queued toast entry
const Entry = struct {
    style: Style = .info,
    message: MessageCopy = .{},
    hide_after_frame: u64 = 0,
};

// Toast notification state with a small queue so rapid notifications
// don't silently overwrite each other.
pub const Toast = struct {
    const queue_capacity = 3;

    queue: [queue_capacity]Entry = [_]Entry{.{}} ** queue_capacity,
    head: usize = 0,
    count: usize = 0,

    pub fn visible(self: *const Toast, frame_number: u64) bool {
        if (self.count == 0) return false;
        const front = self.queue[self.head];
        return front.message.len != 0 and frame_number < front.hide_after_frame;
    }

    // Promote the next queued toast if the current one has expired.
    // Call once per frame before rendering.
    pub fn advance(self: *Toast, frame_number: u64) void {
        while (self.count > 0) {
            const front = self.queue[self.head];
            if (front.message.len != 0 and frame_number < front.hide_after_frame) break;
            // Current toast expired — discard and advance.
            self.queue[self.head] = .{};
            self.head = (self.head + 1) % queue_capacity;
            self.count -= 1;
        }
    }

    pub fn show(self: *Toast, style: Style, message: []const u8, frame_number: u64) void {
        if (self.count < queue_capacity) {
            // Space in queue — append.
            const slot = (self.head + self.count) % queue_capacity;
            self.queue[slot] = .{
                .style = style,
                .hide_after_frame = frame_number + duration_frames,
            };
            self.queue[slot].message.set(message);
            self.count += 1;
        } else {
            // Queue full — overwrite the newest entry so the user at least
            // sees the most recent notification.
            const newest = (self.head + self.count - 1) % queue_capacity;
            self.queue[newest] = .{
                .style = style,
                .hide_after_frame = frame_number + duration_frames,
            };
            self.queue[newest].message.set(message);
        }
    }

    pub fn slice(self: *const Toast) []const u8 {
        if (self.count == 0) return "";
        return self.queue[self.head].message.slice();
    }

    pub fn currentStyle(self: *const Toast) Style {
        if (self.count == 0) return .info;
        return self.queue[self.head].style;
    }
};

// Notification context for frontend operations
pub const Notifications = struct {
    toast: ?*Toast = null,
    frame_number: u64 = 0,
};

// Send a formatted notification to the frontend
pub fn notify(notifications: Notifications, comptime_style: Style, comptime fmt: []const u8, args: anytype) void {
    if (notifications.toast) |toast| {
        var buffer: [max_message_bytes]u8 = undefined;
        const message = std.fmt.bufPrint(buffer[0..], fmt, args) catch "MESSAGE TOO LONG";
        toast.show(comptime_style, message, notifications.frame_number);
    }
}
