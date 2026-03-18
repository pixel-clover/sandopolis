const std = @import("std");
const config = @import("config.zig");
const toast = @import("toast.zig");

// Re-export path types for convenience
pub const PathCopy = config.PathCopy;
pub const MessageCopy = toast.MessageCopy;

// File dialog outcome
pub const Outcome = union(enum) {
    none,
    selected: PathCopy,
    canceled,
    failed: MessageCopy,
};

// Thread-safe file dialog state
pub const State = struct {
    mutex: std.Thread.Mutex = .{},
    in_flight: bool = false,
    selected_path: PathCopy = .{},
    failure_message: MessageCopy = .{},
    default_location_len: usize = 0,
    default_location_z: [std.fs.max_path_bytes + 1]u8 = [_]u8{0} ** (std.fs.max_path_bytes + 1),
    outcome: enum {
        idle,
        selected,
        canceled,
        failed,
    } = .idle,

    pub fn begin(self: *State, default_location: ?[]const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.in_flight) return false;
        self.in_flight = true;
        self.outcome = .idle;
        self.selected_path = .{};
        self.failure_message = .{};
        self.default_location_len = 0;
        @memset(&self.default_location_z, 0);
        if (default_location) |path| {
            const len = @min(path.len, std.fs.max_path_bytes);
            @memcpy(self.default_location_z[0..len], path[0..len]);
            self.default_location_len = len;
        }
        return true;
    }

    pub fn defaultLocation(self: *const State) ?[*:0]const u8 {
        if (self.default_location_len == 0) return null;
        return self.default_location_z[0..self.default_location_len :0].ptr;
    }

    pub fn finishSelected(self: *State, path: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (path.len > self.selected_path.bytes.len) {
            self.writeFailureLocked("SELECTED PATH TOO LONG");
            return;
        }
        self.selected_path = .{};
        @memcpy(self.selected_path.bytes[0..path.len], path);
        self.selected_path.len = path.len;
        self.outcome = .selected;
        self.in_flight = false;
    }

    pub fn finishCanceled(self: *State) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.outcome = .canceled;
        self.in_flight = false;
    }

    pub fn finishFailed(self: *State, message: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.writeFailureLocked(message);
    }

    // Must be polled every frame after begin() returns true. The dialog
    // cannot be reopened until take() has consumed the terminal outcome
    // (selected/canceled/failed), since in_flight stays true until then.
    pub fn take(self: *State) Outcome {
        self.mutex.lock();
        defer self.mutex.unlock();
        const result: Outcome = switch (self.outcome) {
            .idle => .none,
            .selected => .{ .selected = self.selected_path },
            .canceled => .canceled,
            .failed => .{ .failed = self.failure_message },
        };
        self.outcome = .idle;
        return result;
    }

    fn writeFailureLocked(self: *State, message: []const u8) void {
        self.failure_message = .{};
        const len = @min(message.len, self.failure_message.bytes.len);
        @memcpy(self.failure_message.bytes[0..len], message[0..len]);
        self.failure_message.len = len;
        self.outcome = .failed;
        self.in_flight = false;
    }
};
