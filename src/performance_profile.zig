pub const CoreFrameCounters = struct {
    m68k_instructions: u64 = 0,
    z80_instructions: u64 = 0,
    transfer_slots: u64 = 0,
    access_slots: u64 = 0,
    dma_words: u64 = 0,
    render_scanlines: u64 = 0,
    render_sprite_entries: u64 = 0,
    render_sprite_pixels: u64 = 0,
    render_sprite_opaque_pixels: u64 = 0,
    // 68K time accounting in master cycles, split by stall mechanism so the
    // totals can be diffed against an instrumented Genesis Plus GX build
    // (tools/stall_diff.zig) when calibrating CPU throughput.
    m68k_executed_cycles: u64 = 0,
    m68k_refresh_wait_master: u64 = 0,
    m68k_dma_halt_master: u64 = 0,
    m68k_dataport_write_wait_master: u64 = 0,
    m68k_dataport_read_wait_master: u64 = 0,
    m68k_ctrlport_write_wait_master: u64 = 0,
    m68k_access_wait_master: u64 = 0,
    m68k_contention_wait_master: u64 = 0,
};
