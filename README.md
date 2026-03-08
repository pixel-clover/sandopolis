<div align="center">
  <picture>
    <img alt="Sandopolis Logo" src="logo.svg" height="25%" width="25%">
  </picture>
<br>

<h2>Sandopolis</h2>

[![Tests](https://img.shields.io/github/actions/workflow/status/pixel-clover/sandopolis/tests.yml?label=tests&style=flat&labelColor=282c34&logo=github)](https://github.com/pixel-clover/sandopolis/actions/workflows/tests.yml)
[![Docs](https://img.shields.io/badge/docs-read-blue?style=flat&labelColor=282c34&logo=read-the-docs)](https://pixel-clover.github.io/sandopolis/)
[![License](https://img.shields.io/badge/license-MIT-007ec6?label=license&style=flat&labelColor=282c34&logo=open-source-initiative)](https://github.com/pixel-clover/sandopolis/blob/main/LICENSE)
[![Zig Version](https://img.shields.io/badge/Zig-0.15.2-orange?logo=zig&labelColor=282c34)](https://ziglang.org/download/)
[![Release](https://img.shields.io/github/release/pixel-clover/sandopolis.svg?label=release&style=flat&labelColor=282c34&logo=github)](https://github.com/pixel-clover/sandopolis/releases/latest)

A Sega Genesis/Mega Drive emulator written in Zig and C

</div>

---

Sandopolis is a Sega Genesis/Mega Drive emulator written in Zig and C11.

### Features

- Implemented in Zig and C with a portable core and SDL3 frontend
- Accurate Sega Genesis/Mega Drive emulation with good compatibility
- Very configurable input and rendering settings
- Debugging features including single stepping and register dumps
- Has a permissive license that allows commercial use

See [ROADMAP.md](ROADMAP.md) for the list of implemented and planned features.

> [!IMPORTANT]
> This project is still in early development, so bugs and breaking changes are expected.
> Please use the [issues page](https://github.com/pixel-clover/sandopolis/issues) to report bugs or request features.

---

### Quickstart

#### Download the latest release

You can download the latest pre-build binaries from the project's [releases page](https://github.com/pixel-clover/sandopolis/releases).

Alternatively, you can build the emulator from source by following the steps below.

#### 1. Clone the repository

```bash
git clone https://github.com/pixel-clover/sandopolis.git
cd sandopolis
```

#### 2. Build the Sandopolis binary

```bash
zig build -Doptimize=ReleaseFast
```

#### 3. Run the emulator with a ROM

```bash
# Start the emulator with a ROM
./zig-out/bin/sandopolis <path-to-rom>
```

> [!NOTE]
> To build from source, you mainly need to have Zig, Git, and GNU Make installed.
> Additionally, current version of the emulator is developed and tested using Zig 0.15.2.

---

### Documentation

To be added.

---

### Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to make a contribution.

### License

This project is licensed under the MIT License (see [LICENSE](LICENSE)).

### Acknowledgements

* The logo is from [SVG Repo](https://www.svgrepo.com/svg/519365/sonic-runners) with some modifications.
* This project uses material from the following projects and resources:
    * [Minish](https://github.com/CogitatorTech/minish) framework for property-based testing
    * [Rocket 68](https://github.com/habedi/rocket68) for the main CPU emulation
    * [jgz80](https://github.com/carmiker/jgz80) for the Z80 chip emulation
    * [SDL3](https://www.libsdl.org/) for the rendering and input (via [zsdl](https://github.com/zig-gamedev/zsdl) and [SDL](https://github.com/castholm/SDL))
    * [Test ROMs](https://techdocs.exodusemulator.com/Console/SegaMegaDrive/Software.html#test-roms)
