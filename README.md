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

Demos of Sandopolis running a few games:

<div align="center">

<table>
  <tr>
    <td align="center"><img alt="SK demo" src="docs/assets/gif/003_sk_optimized.gif" height="300"><br>Sonic &amp; Knuckles</td>
    <td align="center"><img alt="ROS demo" src="docs/assets/gif/002_ros_optimized.gif" height="300"><br>The Revenge of Shinobi</td>
  </tr>
  <tr>
    <td align="center"><img alt="GA2 demo" src="docs/assets/gif/001_ga2_optimized.gif" height="300"><br>Golden Axe II</td>
    <td align="center"><img alt="SOR demo" src="docs/assets/gif/004_sor_optimized.gif" height="300"><br>Streets of Rage</td>
  </tr>
</table>

</div>

### Key Features

- Accurate Sega Genesis/Mega Drive emulation
- Very portable; can be built and run on any platform that Zig supports
- Very configurable input and rendering settings, with runtime ROM loading, quick states, persistent state slots, and keyboard rebinding
- Has a permissive license that allows commercial use

See [ROADMAP.md](ROADMAP.md) for the list of implemented and planned features.

> [!IMPORTANT]
> This project is still in early development, so compatibility is not perfect.
> Bugs and breaking changes are also expected.
> Please use the [issues page](https://github.com/pixel-clover/sandopolis/issues) to report bugs or request features.

---

### Quickstart

#### Download the latest release

You can download the latest pre-build binaries from the project's [releases page](https://github.com/pixel-clover/sandopolis/releases).

#### Build Sandopolis from source

Alternatively, you can build the emulator from source by following the steps below.

##### 1. Clone the repository

```bash
git clone --recursive --depth=1 https://github.com/pixel-clover/sandopolis.git
cd sandopolis
```

##### 2. Build the Sandopolis binary

```bash
zig build -Doptimize=ReleaseFast
```

##### 3. Run the emulator with a ROM

```bash
# Start the emulator with a ROM
./zig-out/bin/sandopolis <path-to-rom>
```

> [!NOTE]
> To build from source, you mainly need to have Zig and Git installed.
> The current version of the emulator is developed and tested using Zig 0.15.2.

---

### Documentation

Project documentation is available [here](https://pixel-clover.github.io/sandopolis/).

---

### Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to make a contribution.

### Acknowledgements

* The logo is from [SVG Repo](https://www.svgrepo.com/svg/519365/sonic-runners) with some modifications.
* This project uses material from the following projects and resources:
    * [Minish](https://github.com/CogitatorTech/minish) framework for property-based testing
    * [Rocket 68](https://github.com/habedi/rocket68) for the main CPU emulation
    * [jgz80](https://github.com/carmiker/jgz80) for the Z80 chip emulation
    * [SDL3](https://www.libsdl.org/) for the rendering and input (via [zsdl](https://github.com/zig-gamedev/zsdl)
      and [SDL](https://github.com/castholm/SDL))
    * [Test ROMs](https://techdocs.exodusemulator.com/Console/SegaMegaDrive/Software.html#test-roms)
    * [Nuked-OPN2](https://github.com/nukeykt/Nuked-OPN2)

> [!IMPORTANT]
> Nuked-OPN2 is mainly used for testing the output of the Zig YM2612 implementation.
> The code is not directly included in the project because its license (LGPL 2.1) is incompatible with the project's license.

### License

This project is licensed under the MIT License (see [LICENSE](LICENSE)).
