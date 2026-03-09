# Rocket 68

<p align="center">
  <img src="https://raw.githubusercontent.com/habedi/rocket68/main/logo.svg" alt="Project Logo" width="200" />
</p>

Rocket 68 is a Motorola 68000 (or m68k) CPU emulator written in pure C11.
It supports all the instructions and addressing modes of the m68k, plus system control features like supervisor mode, interrupts, and exceptions.
It tracks timing with baseline cycle accounting and optional wait states, so you get predictable scheduling and more realistic memory/bus timing.

## Why Rocket 68?

Rocket 68 is built to provide a clean, correct, and easy-to-embed Motorola 68000 core for projects that need to run m68k code.
A lot of existing 68k emulators are originally designed as full system emulators rather than reusable libraries, which can make it
hard to integrate them into other projects.
Rocket 68 focuses on correctness first: instruction behavior, exception handling, and cycle timing closely follow real hardware so projects
can rely on predictable and accurate CPU behavior.

Rocket 68 is designed to be used a portable library.
All state lives inside a single `M68kCpu` instance, with no shared global state.
This makes it relatively straightforward to run multiple CPUs or integrate the core into larger systems.
Additionally, the codebase uses modern C11 with a small and explicit API that makes the project easy to use and extend.

## Features

- Have a simple API and easy to integrate into other projects
- Supports all Motorola 68000 instructions and different addressing modes
- Baseline cycle accounting with an optional wait-state callback for bus timing
- Full hardware interrupt support (with auto-vectoring, address error traps, trace mode, and halted states)
- Built-in instruction disassembler and support for loading binary and S-record programs

## Documentation

- [Getting Started](getting-started.md)
- [Examples](examples.md)
- [API Reference](api-reference.md)
- [Compatibility Notes](compatibility.md)
- [Doxygen API Documentation](https://habedi.github.io/rocket68/doxygen/index.html)
