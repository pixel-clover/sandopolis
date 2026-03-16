const std = @import("std");
const testing = std.testing;

/// Records audio output to a WAV file for debugging purposes.
/// Supports 16-bit stereo audio at configurable sample rates.
pub const WavRecorder = struct {
    file: std.fs.File,
    sample_count: u32,
    sample_rate: u32,
    channels: u16,

    out_buf: [out_buf_size]u8 = undefined,
    out_len: usize = 0,

    const out_buf_size = 64 * 1024;
    const bits_per_sample: u16 = 16;

    /// Start recording to a new WAV file.
    /// The WAV header is written with a placeholder for the data size,
    /// which is updated when `finish()` is called.
    pub fn start(path: []const u8, sample_rate: u32, channels: u16) !WavRecorder {
        if (sample_rate == 0 or channels == 0 or channels > 2) {
            return error.InvalidAudioFormat;
        }

        const file = try std.fs.cwd().createFile(path, .{});
        errdefer file.close();

        var self = WavRecorder{
            .file = file,
            .sample_count = 0,
            .sample_rate = sample_rate,
            .channels = channels,
        };

        // Write WAV header with placeholder sizes (will be updated in finish())
        try self.writeWavHeader(0);

        return self;
    }

    /// Add audio samples to the recording.
    /// Samples should be interleaved stereo (L, R, L, R, ...) for stereo recordings.
    /// Each sample is a signed 16-bit integer.
    pub fn addSamples(self: *WavRecorder, samples: []const i16) !void {
        const frame_count = samples.len / self.channels;
        if (frame_count == 0) return;

        // Write samples to buffer, flushing as needed
        for (samples) |sample| {
            if (self.out_len + 2 > out_buf_size) {
                try self.flushBuf();
            }
            // Write as little-endian
            self.out_buf[self.out_len] = @truncate(@as(u16, @bitCast(sample)));
            self.out_buf[self.out_len + 1] = @truncate(@as(u16, @bitCast(sample)) >> 8);
            self.out_len += 2;
        }

        self.sample_count += @intCast(frame_count);
    }

    /// Finish the recording and close the file.
    /// This updates the WAV header with the correct data size.
    pub fn finish(self: *WavRecorder) void {
        // Flush any remaining buffered data
        self.flushBuf() catch {};

        // Update the header with the correct sizes
        self.file.seekTo(0) catch {};
        self.writeWavHeader(self.sample_count) catch {};
        self.flushBuf() catch {};

        self.file.close();
    }

    /// Get the current duration of the recording in seconds.
    pub fn getDurationSeconds(self: *const WavRecorder) f32 {
        if (self.sample_rate == 0) return 0;
        return @as(f32, @floatFromInt(self.sample_count)) / @as(f32, @floatFromInt(self.sample_rate));
    }

    fn writeWavHeader(self: *WavRecorder, frame_count: u32) !void {
        const bytes_per_sample = bits_per_sample / 8;
        const block_align = self.channels * bytes_per_sample;
        const byte_rate = self.sample_rate * @as(u32, block_align);
        const data_size = frame_count * @as(u32, block_align);
        const file_size = 36 + data_size;

        self.out_len = 0;

        // RIFF header
        self.bufWrite("RIFF");
        self.bufWriteU32(file_size);
        self.bufWrite("WAVE");

        // Format chunk
        self.bufWrite("fmt ");
        self.bufWriteU32(16); // Chunk size
        self.bufWriteU16(1); // Audio format (1 = PCM)
        self.bufWriteU16(self.channels);
        self.bufWriteU32(self.sample_rate);
        self.bufWriteU32(byte_rate);
        self.bufWriteU16(block_align);
        self.bufWriteU16(bits_per_sample);

        // Data chunk
        self.bufWrite("data");
        self.bufWriteU32(data_size);

        try self.flushBuf();
    }

    fn bufWriteByte(self: *WavRecorder, byte: u8) void {
        self.out_buf[self.out_len] = byte;
        self.out_len += 1;
    }

    fn bufWriteU16(self: *WavRecorder, value: u16) void {
        self.out_buf[self.out_len] = @truncate(value);
        self.out_buf[self.out_len + 1] = @truncate(value >> 8);
        self.out_len += 2;
    }

    fn bufWriteU32(self: *WavRecorder, value: u32) void {
        self.out_buf[self.out_len] = @truncate(value);
        self.out_buf[self.out_len + 1] = @truncate(value >> 8);
        self.out_buf[self.out_len + 2] = @truncate(value >> 16);
        self.out_buf[self.out_len + 3] = @truncate(value >> 24);
        self.out_len += 4;
    }

    fn bufWrite(self: *WavRecorder, data: []const u8) void {
        @memcpy(self.out_buf[self.out_len..][0..data.len], data);
        self.out_len += data.len;
    }

    fn flushBuf(self: *WavRecorder) !void {
        if (self.out_len > 0) {
            try self.file.writeAll(self.out_buf[0..self.out_len]);
            self.out_len = 0;
        }
    }
};

fn tempWavPath(allocator: std.mem.Allocator, tmp: *testing.TmpDir, file_name: []const u8) ![]u8 {
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    return std.fs.path.join(allocator, &.{ dir_path, file_name });
}

test "WAV recorder creates valid stereo WAV file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tempWavPath(testing.allocator, &tmp, "test_stereo.wav");
    defer testing.allocator.free(tmp_path);

    var recorder = try WavRecorder.start(tmp_path, 48000, 2);

    // Generate a simple sine wave for testing
    var samples: [960]i16 = undefined; // 10ms at 48kHz stereo
    for (0..480) |i| {
        const t = @as(f32, @floatFromInt(i)) / 48000.0;
        const value: i16 = @intFromFloat(@sin(t * 440.0 * std.math.tau) * 16000.0);
        samples[i * 2] = value; // Left
        samples[i * 2 + 1] = value; // Right
    }

    try recorder.addSamples(&samples);
    recorder.finish();

    // Verify the file was created and has valid header
    const file = try tmp.dir.openFile("test_stereo.wav", .{});
    defer file.close();

    var header: [44]u8 = undefined;
    _ = try file.readAll(&header);

    // Check RIFF header
    try testing.expectEqualStrings("RIFF", header[0..4]);
    try testing.expectEqualStrings("WAVE", header[8..12]);
    try testing.expectEqualStrings("fmt ", header[12..16]);
    try testing.expectEqualStrings("data", header[36..40]);

    // Check format
    const channels = std.mem.readInt(u16, header[22..24], .little);
    const sample_rate = std.mem.readInt(u32, header[24..28], .little);
    const bits = std.mem.readInt(u16, header[34..36], .little);

    try testing.expectEqual(@as(u16, 2), channels);
    try testing.expectEqual(@as(u32, 48000), sample_rate);
    try testing.expectEqual(@as(u16, 16), bits);

    // Verify file size
    const stat = try file.stat();
    try testing.expectEqual(@as(u64, 44 + 960 * 2), stat.size);
}

test "WAV recorder handles mono audio" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tempWavPath(testing.allocator, &tmp, "test_mono.wav");
    defer testing.allocator.free(tmp_path);

    var recorder = try WavRecorder.start(tmp_path, 44100, 1);

    var samples: [441]i16 = undefined; // 10ms at 44.1kHz mono
    for (0..441) |i| {
        const t = @as(f32, @floatFromInt(i)) / 44100.0;
        samples[i] = @intFromFloat(@sin(t * 880.0 * std.math.tau) * 8000.0);
    }

    try recorder.addSamples(&samples);
    recorder.finish();

    const file = try tmp.dir.openFile("test_mono.wav", .{});
    defer file.close();

    var header: [44]u8 = undefined;
    _ = try file.readAll(&header);

    const channels = std.mem.readInt(u16, header[22..24], .little);
    try testing.expectEqual(@as(u16, 1), channels);
}

test "WAV recorder handles multiple addSamples calls" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tempWavPath(testing.allocator, &tmp, "test_multi.wav");
    defer testing.allocator.free(tmp_path);

    var recorder = try WavRecorder.start(tmp_path, 48000, 2);

    var samples: [100]i16 = undefined;
    @memset(&samples, 1000);

    // Add samples in multiple calls
    for (0..10) |_| {
        try recorder.addSamples(&samples);
    }
    recorder.finish();

    // 100 samples per call / 2 channels = 50 frames per call, * 10 calls = 500 frames
    try testing.expectEqual(@as(u32, 500), recorder.sample_count);

    const file = try tmp.dir.openFile("test_multi.wav", .{});
    defer file.close();
    const stat = try file.stat();
    // 100 samples * 2 bytes * 10 calls + 44 byte header = 2044 bytes
    try testing.expectEqual(@as(u64, 44 + 100 * 2 * 10), stat.size);
}

test "WAV recorder duration calculation is correct" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tempWavPath(testing.allocator, &tmp, "test_duration.wav");
    defer testing.allocator.free(tmp_path);

    var recorder = try WavRecorder.start(tmp_path, 48000, 2);

    // Add 1 second of audio (48000 frames * 2 channels)
    var samples: [9600]i16 = [_]i16{0} ** 9600; // 100ms chunks
    for (0..10) |_| {
        try recorder.addSamples(&samples);
    }

    try testing.expectApproxEqAbs(@as(f32, 1.0), recorder.getDurationSeconds(), 0.001);

    recorder.finish();
}

test "WAV recorder rejects invalid parameters" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tempWavPath(testing.allocator, &tmp, "test_invalid.wav");
    defer testing.allocator.free(tmp_path);

    // Zero sample rate should fail
    try testing.expectError(error.InvalidAudioFormat, WavRecorder.start(tmp_path, 0, 2));

    // Zero channels should fail
    try testing.expectError(error.InvalidAudioFormat, WavRecorder.start(tmp_path, 48000, 0));

    // More than 2 channels should fail
    try testing.expectError(error.InvalidAudioFormat, WavRecorder.start(tmp_path, 48000, 3));
}

test "WAV recorder handles large recordings" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tempWavPath(testing.allocator, &tmp, "test_large.wav");
    defer testing.allocator.free(tmp_path);

    var recorder = try WavRecorder.start(tmp_path, 48000, 2);

    // Write enough data to trigger multiple buffer flushes
    var samples: [8192]i16 = [_]i16{0} ** 8192;
    for (0..samples.len) |i| {
        samples[i] = @intCast(@as(i32, @intCast(i % 32768)) - 16384);
    }

    for (0..20) |_| {
        try recorder.addSamples(&samples);
    }

    recorder.finish();

    const file = try tmp.dir.openFile("test_large.wav", .{});
    defer file.close();
    const stat = try file.stat();

    // 8192 samples * 2 bytes * 20 iterations + 44 byte header
    try testing.expectEqual(@as(u64, 44 + 8192 * 2 * 20), stat.size);
}
