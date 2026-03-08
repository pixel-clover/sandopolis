Test ROMS

The following is a collection of test ROMS for the Mega Drive which are noteworthy, interesting, or otherwise useful for examining or testing the behaviour of the hardware. This list does not attempt to be exhaustive and cover every test ROM ever produced for the system, but it does aim to include the most useful ROMS which can be used to verify the correct behaviour of emulators in particular.

Images       	Name 	Author 	Description
IO Sample Program 	Sega 	Official test ROM from Sega to demonstrate detection of I/O devices and to decode their input.
FM Test 	DevSter 	Very basic test of FM sound through the YM2612. There is no visual output, only audio.
Graphics & Joystick Sampler 	Charles Doty 	Handy minimalist ROM with simple graphics and a movable character. Useful as an early test ROM when building an emulator.
V counter test program 	Charles MacDonald 	Samples observed VDP vertical counter (VCounter) values under a variety of display modes
CRAM Flicker Test 	Nemesis 	Verifies correct placement and timing of CRAM dots in the border and active scan when CRAM is written to
VDP Test Register 	Tristan Seifert 	Interactive test ROM allowing any bits of the VDP test register to be toggled, with a variety of audio and graphical output to observe the results.
68000 Memory Test 	Charles MacDonald 	Handy test ROM that displays the results of reading from various locations in the 68000 memory address for the Mega Drive which are undefined, but don’t lockup when attempting a read as DTACK is asserted. Results will differ between different Mega Drive models.
1536 Color Test 	Charles MacDonald 	Test ROM using dynamic palette changes combined with the VDP shadow/highlight mode to demonstrate a large number of unique colors on the screen at once.
Shadow-Highlight Test Program 	Paul Lee 	Simple test ROM showing shadow highlight mode
Window Test 	Fonzie 	Useful test ROM showing the function of the VDP Window mode with a top left aligned window, and scrolling plane A and B. This ROM also demonstrates the VDP hscroll bug, which occurs when you have a left-aligned window and attempt to scroll layer A.
Overdrive 	Titan 	Technically a demo release, but serves as a good technical proof as well. Aims to push the hardware to the limits, and exploit corner cases and undocumented hardware features.
Overdrive 2 	Titan 	Follow-up to the original Overdrive demo. Requires a lot of obscure features and timing edge-cases to be implemented correctly in order to work in emulators.


Source: https://techdocs.exodusemulator.com/Console/SegaMegaDrive/Software.html#test-roms

Note that I don't own any of these ROMs, and they are provided for educational and testing purposes only. Please respect the intellectual property rights of the original creators and distributors of these ROMs.
