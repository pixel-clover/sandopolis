# Test ROMs

A collection of test ROMs for the Mega Drive which are noteworthy, interesting, or otherwise useful for examining or testing hardware behaviour.
This list does not attempt to be exhaustive, but it aims to include the most useful ROMs for verifying correct emulator behaviour.

| File                                                   | Name                          | Author            | Description                                                                                                                                                         |
|--------------------------------------------------------|-------------------------------|-------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `Multitap - IO Sample Program (U) (Nov 28 1992).gen`   | IO Sample Program             | Sega              | Official test ROM from Sega to demonstrate detection of I/O devices and to decode their input.                                                                      |
| `FM Test by DevSter (PD).bin`                          | FM Test                       | DevSter           | Very basic test of FM sound through the YM2612. There is no visual output, only audio.                                                                              |
| `Graphics & Joystick Sampler by Charles Doty (PD).bin` | Graphics & Joystick Sampler   | Charles Doty      | Handy minimalist ROM with simple graphics and a movable character. Useful as an early test ROM when building an emulator.                                           |
| `vctest.bin`                                           | V Counter Test Program        | Charles MacDonald | Samples observed VDP vertical counter (VCounter) values under a variety of display modes.                                                                           |
| `cram flicker.bin`                                     | CRAM Flicker Test             | Nemesis           | Verifies correct placement and timing of CRAM dots in the border and active scan when CRAM is written to.                                                           |
| `DisableRegTestROM.bin`                                | VDP Test Register             | Tristan Seifert   | Interactive test ROM allowing any bits of the VDP test register to be toggled, with a variety of audio and graphical output to observe the results.                 |
| `memtest_68k.bin`                                      | 68000 Memory Test             | Charles MacDonald | Displays the results of reading from various undefined locations in the 68000 memory map. Results will differ between Mega Drive models.                            |
| `TEST1536.BIN`                                         | 1536 Color Test               | Charles MacDonald | Uses dynamic palette changes combined with VDP shadow/highlight mode to demonstrate a large number of unique colors on screen at once.                              |
| `Shadow-Highlight Test Program #2 (PD).bin`            | Shadow-Highlight Test Program | Paul Lee          | Simple test ROM showing shadow highlight mode.                                                                                                                      |
| `Window Test by Fonzie (PD).bin`                       | Window Test                   | Fonzie            | Shows the function of VDP Window mode with a top-left aligned window and scrolling planes A and B. Also demonstrates the VDP hscroll bug with left-aligned windows. |
| `TiTAN - Overdrive (Rev1.1-106-Final) (Hardware).bin`  | Overdrive                     | Titan             | Demo release that pushes the hardware to the limits, exploiting corner cases and undocumented features.                                                             |
| `titan-overdrive2.bin`                                 | Overdrive 2                   | Titan             | Follow-up to Overdrive. Requires many obscure features and timing edge-cases to be implemented correctly.                                                           |

**Source: <https://techdocs.exodusemulator.com/Console/SegaMegaDrive/Software.html#test-roms>**

> [!IMPORTANT]
> Note that I don't own any of these ROMs, and they are provided for educational and testing purposes only.
> Please respect the intellectual property rights of the original creators and distributors of these ROMs.
