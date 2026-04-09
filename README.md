<div align="center">
  <picture>
    <img alt="Sandopolis Logo" src="logo.svg" height="25%" width="25%">
  </picture>
<br>

<h2>Sandopolis</h2>

[![Tests](https://img.shields.io/github/actions/workflow/status/pixel-clover/sandopolis/tests.yml?label=tests&style=flat&labelColor=282c34&logo=github)](https://github.com/pixel-clover/sandopolis/actions/workflows/tests.yml)
[![License](https://img.shields.io/badge/license-MIT-007ec6?style=flat&labelColor=282c34&logo=open-source-initiative)](https://github.com/pixel-clover/sandopolis/blob/main/LICENSE)
[![Release](https://img.shields.io/github/release/pixel-clover/sandopolis.svg?label=release&style=flat&labelColor=282c34&logo=github)](https://github.com/pixel-clover/sandopolis/releases/latest)
[![Play Online](https://img.shields.io/badge/play%20online-browser-007ec6?style=flat&labelColor=282c34&logo=webassembly)](https://pixel-clover.github.io/sandopolis/)
[![Zig](https://img.shields.io/badge/zig-0.15.2-F7A41D?style=flat&labelColor=282c34&logo=zig)](https://ziglang.org/download/)
[![Docker](https://img.shields.io/badge/docker-ghcr.io-007ec6?style=flat&labelColor=282c34&logo=docker)](https://github.com/orgs/pixel-clover/packages/container/package/sandopolis-web)
[![Systems](https://img.shields.io/badge/systems-Genesis%20%7C%20SMS%20%7C%20Game%20Gear-44cc11?style=flat&labelColor=282c34)](https://github.com/pixel-clover/sandopolis)
[![Platforms](https://img.shields.io/badge/platforms-Desktop%20%7C%20Web%20%7C%20Libretro-44cc11?style=flat&labelColor=282c34)](https://github.com/pixel-clover/sandopolis)

A portable multi-system Sega emulator for Genesis, Master System, and Game Gear

</div>

---

**Download the latest desktop version of Sandopolis from [here](https://github.com/pixel-clover/sandopolis/releases)
or [try Sandopolis in your web browser](https://pixel-clover.github.io/sandopolis/).**

Footage of Sandopolis running a few games:

<div align="center">

<table>
  <tr>
    <td align="center"><img alt="SK demo" src="docs/assets/gif/003_sk_optimized.gif" width="200%"><br>Sonic &amp; Knuckles</td>
    <td align="center"><img alt="ROS demo" src="docs/assets/gif/002_ros_optimized.gif" width="200%"><br>The Revenge of Shinobi</td>
  </tr>
  <tr>
    <td align="center"><img alt="GA2 demo" src="docs/assets/gif/001_ga2_optimized.gif" width="200%"><br>Golden Axe II</td>
    <td align="center"><img alt="SOR demo" src="docs/assets/gif/004_sor_optimized.gif" width="200%"><br>Streets of Rage</td>
  </tr>
</table>

</div>

### Key Features

- Accurate Sega Genesis/Mega Drive, Master System, and Game Gear emulation
- Very portable; can be built and run on any platform that Zig supports
- Very configurable, including gameplay input, frontend hotkeys, and rendering settings
- Has a permissive license that allows commercial use

See [ROADMAP.md](ROADMAP.md) for the list of implemented and planned features.

> [!IMPORTANT]
> This project is still in early development, so compatibility is not perfect.
> Bugs and breaking changes are also expected.
> Please use the [issues page](https://github.com/pixel-clover/sandopolis/issues) to report bugs or request features.

---

### Quickstart

#### Download the Latest Release

##### A. Desktop

You can download the latest pre-built binaries from the project's [release page](https://github.com/pixel-clover/sandopolis/releases).

##### B. Web

You can download and use the latest pre-built Docker image for the web version of Sandopolis from the
[GCR](https://github.com/orgs/pixel-clover/packages/container/package/sandopolis-web):

```bash
docker run -d -p 8085:80 --rm ghcr.io/pixel-clover/sandopolis-web:latest
```

Then open http://localhost:8085 in your browser.

#### Build Sandopolis from Source

Alternatively, you can build the emulator from source by following the steps below.

##### 1. Clone the repository

```bash
git clone --depth=1 https://github.com/pixel-clover/sandopolis.git
cd sandopolis
```

> [!NOTE]
> If you want to run the tests and develop Sandopolis further, you may want to clone the repository with
> `git clone --recursive https://github.com/pixel-clover/sandopolis.git`.
> Note that you also need to have `git-lfs` installed to download some of the files like test ROMs.

##### 2. Build the Sandopolis Binary

```bash
# This can take some time
zig build -Doptimize=ReleaseFast
```

If the build is successful, you can find the built binary at `zig-out/bin/`.

> [!NOTE]
> To build from source, you mainly need to have Zig and Git installed.
> The current version of the emulator is developed and tested using Zig 0.15.2.

#### Run the Emulator

Run the `sandopolis` binary to start the emulator GUI:

```bash
sandopolis
```

<div align="center">
<img alt="Sandopolis Screenshot" src="docs/assets/img/main_window_v0.1.0-alpha.5.png" width="100%">
</div>

Run `sandopolis --help` to see the list of available command-line options.

Example output:

```
A portable multi-system Sega emulator for Genesis, Master System, and Game Gear

Usage:
  sandopolis [flags] [rom_file]

Arguments:
  rom_file  Path to a ROM file (.bin, .md, .smd, .gen, .sms, .gg) or a .zip archive containing one (optional)

Flags:
  -h, --help            Shows help information for this command [Bool] (default: false)
      --audio-mode      Audio render mode: normal, ym-only, psg-only, unfiltered-mix [String] (default: "")
      --audio-queue-ms  Audio queue budget in milliseconds (40-150) before backlog recovery [String] (default: "")
      --renderer        SDL render driver override (e.g. software, opengl) [String] (default: "")
      --config          Path to the unified config file (default: SANDOPOLIS_CONFIG, platform app data, or ./sandopolis.cfg) [String] (default: "")
      --pal             Force PAL/50Hz timing and version bits [Bool] (default: false)
      --ntsc            Force NTSC/60Hz timing and version bits [Bool] (default: false)
      --version         Print version information and exit [Bool] (default: false)
```

---

### Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to make a contribution.

### License

This project is licensed under the MIT License (see [LICENSE](LICENSE)).

### Acknowledgements

* The logo is from [SVG Repo](https://www.svgrepo.com/svg/519365/sonic-runners) with some modifications.
* This project uses material from the following projects and resources:
    * [Minish](https://github.com/CogitatorTech/minish) framework for property-based testing
    * [Chilli](https://github.com/CogitatorTech/chilli) framework for CLI parsing and handling
    * [Rocket 68](https://github.com/habedi/rocket68) for the main CPU (Motorola 68000) emulation
    * [jgz80](https://github.com/carmiker/jgz80) for the Z80 chip emulation
    * [SDL3](https://www.libsdl.org/) for the emulator frontend (rendering and input; via [zsdl](https://github.com/zig-gamedev/zsdl)
      and [SDL](https://github.com/castholm/SDL))
    * [stb](https://github.com/nothings/stb/blob/master/stb_truetype.h) for the TrueType font rendering
    * [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) for the monospace font used in the frontend
    * [Test ROMs](https://techdocs.exodusemulator.com/Console/SegaMegaDrive/Software.html#test-roms) for testing
    * [Libretro overlays](https://github.com/libretro/common-overlays) for the frontend overlays

#### Reference Implementations

Sandopolis implementation logic was checked with the following implementations for finding errors and verifying correctness:

* [Genesis-Plus-GX](https://github.com/ekeeke/Genesis-Plus-GX)
* [Nuked-OPN2](https://github.com/nukeykt/Nuked-OPN2)
* [clownmdemu-core](https://github.com/Clownacy/clownmdemu-core)
* [kiwi](https://github.com/drx/kiwi)
* [jgenesis](https://github.com/jsgroth/jgenesis/tree/master/backend/genesis-core)

#### Other Resources

* [mega-drive-genesis](https://www.copetti.org/writings/consoles/mega-drive-genesis/)
* [mega-drive-architecture](https://rasterscroll.com/mdgraphics/mega-drive-architecture/)
