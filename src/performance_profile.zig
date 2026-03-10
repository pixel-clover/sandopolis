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
};
