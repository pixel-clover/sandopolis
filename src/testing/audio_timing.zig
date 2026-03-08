const std = @import("std");
const internal_timing = @import("../audio/timing.zig");

const State = struct {
    timing: internal_timing.AudioTiming = .{},
};

pub const PendingAudioFrames = internal_timing.PendingAudioFrames;

pub const AudioTiming = struct {
    handle: *State,

    pub fn init(allocator: std.mem.Allocator) !AudioTiming {
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{};
        return .{ .handle = state };
    }

    pub fn deinit(self: *AudioTiming, allocator: std.mem.Allocator) void {
        allocator.destroy(self.handle);
    }

    pub fn consumeMaster(self: *AudioTiming, master_cycles: u32) void {
        self.handle.timing.consumeMaster(master_cycles);
    }

    pub fn takePending(self: *AudioTiming) PendingAudioFrames {
        return self.handle.timing.takePending();
    }

    pub fn fmMasterRemainder(self: *const AudioTiming) u16 {
        return self.handle.timing.fm_master_remainder;
    }

    pub fn psgMasterRemainder(self: *const AudioTiming) u16 {
        return self.handle.timing.psg_master_remainder;
    }
};
