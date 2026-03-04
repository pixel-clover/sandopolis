## Project Roadmap

This document outlines the features implemented in Sandopolis emulator and the future goals for the project.

> [!IMPORTANT]
> This roadmap is a work in progress and is subject to change.

### Core System

- [x] Project Scaffolding: Build system, SDL3 integration, memory bus structure.
- [x] ROM Loading: Basic loader for .bin / .md files.
- [x] M68000 CPU Integration: Rocket68 C core wired through Sandopolis bus callbacks.
- [x] M68000 CPU - Basic:
    - [x] Instruction dispatcher (hierarchical switch).
    - [x] Basic opcodes (MOVE, DI, NOP, BRA).
    - [x] Shift/Rotate (ASL, ASR, LSL, LSR, ROL, ROR) - *ROXL/ROXR pending*.
- [ ] M68000 CPU - Advanced:
    - [x] Addressing Modes (Indirect, PostInc, PreDec, Displacement, Index).
    - [x] Control Flow (Bcc, JMP, JSR, RTS, DBcc, TST).
    - [ ] System (RTE, TRAP, STOP, Interrupts).
    - [x] Full Instruction Set (Shifts, Bit Ops, MUL/DIV placeholders).
- [ ] Memory Mapping:
    - [ ] Correct mirroring (RAM/ROM).
    - [ ] Z80 Bus arbitration.

### Video Display Processor

- [x] VDP Registers: Implement mode registers, scroll data, DMA configuration.
- [x] VRAM / CRAM / VSRAM: Memory storage for tiles, palettes, and scroll data.
- [x] Pattern/Tile Rendering: Decoding 4bpp tiles.
- [ ] Plane A / Plane B: Render background layers with scrolling.
- [ ] Sprites: Sprite attribute table (SAT) parsing and rendering.
- [ ] DMA: Direct Memory Access transfers (68k -> VDP).

### Audio Subsystem

- [x] Z80 CPU Core: jgz80 integrated via C bridge.
- [ ] SN76489 (PSG): Square wave and noise generation.
- [ ] YM2612 (FM): Frequency Modulation synthesis (6 channels).
- [ ] Mixer: Audio output integration via SDL3.

### Input and Interaction

- [ ] Controller I/O: Complete 3-button and 6-button controller logic.
- [ ] Input Mapping: Configurable keyboard/gamepad binding.
- [ ] SRAM Support: Save game functionality for RPGs.

### Compatibility and Tooling

- [ ] Timing Accuracy: Cycle-accurate bus timing.
- [ ] Debugger:
    - [ ] Register views.
    - [ ] Disassembler.
    - [ ] Memory editor.
    - [ ] VDP viewer (Tile/Sprite debugger).
- [ ] Test Suite: Pass various test ROMs (e.g., acid tests).

### Future Goals

- [ ] Sega CD / 32X (Long term).
- [ ] WebAssembly Build: Run Sandopolis in the browser.
- [ ] Libretro Core: Integration with RetroArch.
